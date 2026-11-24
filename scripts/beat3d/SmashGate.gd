extends Node3D
class_name SmashGate

## Smash gates: a wall across all three lanes that can only be broken, not
## dodged. They come from HOLD events on the beats pass of a chart (the manual
## mapper's beat holds) — melody and fx holds stay what they were.
##
##   hold start  t0 ── mash window ──▶ hold end  t1 = impact
##
## For the length of the hold, any button counts as a mash press (Esc and
## Start still pause). Meeko is locked to the middle lane, charges, and hits
## the wall at t1 — author the hold so its end sits on the drop, and start an
## electric zone there in the mapper: the gate does not make the zone, it only
## lines up with one.
##
## The wall always breaks at t1. What the mash decides is what it costs:
##   * beat the target (more presses than it asks for)  →  0 HP
##   * meet it exactly                                   →  2 HP
##   * fall short                                        →  up to 50 HP
## The target is set per wall in the manual mapper (💥 Smash Gates); left
## unset, it scales with the hold's length (MASH_RATE presses per second).
##
## The cracks spread and the wall charges as the presses come in, so the
## player can see how they are doing. From story level 5 on (and always in
## freeplay) Meeko glows rainbow for the charge — spending echo energy, which
## is why it only ever happens here.
##
## The section owns this node: setup() once, add() per smash, build_visual()
## when a gate's body is built, update() every frame, press() per mash input.

## Presses per second the target asks for. Six is a steady, comfortable mash;
## beating it takes a real effort.
const MASH_RATE: float = 6.0
const MIN_TARGET: int = 4
const HP_MET: float = 2.0
const HP_WORST: float = 50.0
## Below this fraction of the target the cost is already the full 50 HP.
const WORST_RATIO: float = 0.2

const CRACKS: int = 14

var section: Node = null
var rainbow: bool = false

## One per smash, in time order:
## {gi, t0, t1, target, presses, state (0 waiting, 1 mashing, 2 done), vis}
var _smashes: Array[Dictionary] = []
var _active: int = -1
var _fx_root: Node3D = null
var _fx_light: OmniLight3D = null
var _fx_sparks: CPUParticles3D = null
var _spark_mat: StandardMaterial3D = null
var _prev_input_disabled: bool = false
var _prev_lean: float = 0.0
var _t: float = 0.0

var _crack_mesh: BoxMesh = null


func _init() -> void:
	name = "SmashGates"


func setup(p_section: Node, p_rainbow: bool) -> void:
	section = p_section
	rainbow = p_rainbow
	_crack_mesh = BoxMesh.new()
	_crack_mesh.size = Vector3(1.0, 0.06, 0.06)
	_thump = _sfx(_gen_thump(), -10.0)
	_crash = _sfx(_gen_crash(), -2.0)


var _thump: AudioStreamPlayer = null
var _crash: AudioStreamPlayer = null
const SR: int = 22050


func _sfx(stream: AudioStreamWAV, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	p.max_polyphony = 4
	add_child(p)
	return p


func _wav(s: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	return w


## A dull knock on the wall, one per press.
func _gen_thump() -> AudioStreamWAV:
	var n: int = int(0.09 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = sin(TAU * 95.0 * t) * exp(-t * 45.0) * 0.8 \
			+ randf_range(-1.0, 1.0) * exp(-t * 250.0) * 0.35
	return _wav(s)


## The wall going: a low boom under a long spray of breaking noise.
func _gen_crash() -> AudioStreamWAV:
	var n: int = int(0.9 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var prev: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var noise: float = randf_range(-1.0, 1.0)
		var bright: float = noise - prev * 0.6
		prev = noise
		var boom: float = sin(TAU * (60.0 - 25.0 * t) * t) * exp(-t * 6.0) * 0.8
		var shatter: float = bright * exp(-t * 4.5) * 0.55
		# Debris: sparse clicks thinning out over the tail.
		var debris: float = (randf_range(-1.0, 1.0) if randf() < 0.02 * exp(-t * 3.0) else 0.0) * 0.6
		s[i] = boom + shatter + debris
	return _wav(s)


## `target` is the press count set in the manual mapper (the hold's
## "mash_target"); 0 means use the recommended amount for the hold's length.
func add(gate_index: int, t0: float, t1: float, target: int = 0) -> void:
	_smashes.append({
		"gi": gate_index, "t0": t0, "t1": t1,
		"target": target if target > 0 else recommended_target(t1 - t0),
		"presses": 0, "state": 0, "vis": {},
	})


## Recommended presses for a hold this long. The manual mapper shows the same
## number (ManualMapper.SMASH_MASH_RATE / SMASH_MIN_TARGET must match).
static func recommended_target(dur: float) -> int:
	return maxi(MIN_TARGET, int(round(maxf(dur, 0.1) * MASH_RATE)))


func is_mashing() -> bool:
	return _active >= 0


## The active smash's window and target, for the autopilot. Empty when none.
func active_info() -> Dictionary:
	if _active < 0:
		return {}
	var s: Dictionary = _smashes[_active]
	return {"t0": s["t0"], "t1": s["t1"], "target": s["target"], "presses": s["presses"]}


## Mash progress of the active smash, 0..1+ (over 1 = beating the target).
func progress() -> float:
	if _active < 0:
		return 0.0
	var s: Dictionary = _smashes[_active]
	return float(s["presses"]) / float(s["target"])


## One mash press. Returns true if it counted.
func press() -> bool:
	if _active < 0:
		return false
	var s: Dictionary = _smashes[_active]
	s["presses"] = int(s["presses"]) + 1
	_on_press(s)
	return true


# ══════════════════════════════════════════════════════════════════════════════
#  The wall
# ══════════════════════════════════════════════════════════════════════════════

## The smash gate's own colour. Like every other gate it goes through the
## neon kit, so the colour cycle can still take it over when that is on.
const TINT: Color = Color(1.0, 0.22, 0.62)

## Builds the wall into a gate's VisRoot out of the same kit as every other
## gate (GatePieces): one building facade per lane — a lane gate with every
## lane blocked — a neon arch spanning the whole track, the floor's approach
## marks aimed at the middle lane where he hits, and neon-tube cracks that stay
## hidden until the mash reveals them.
func build_visual(vis_root: Node3D, gate_index: int, track_width: float,
		height: float, pieces: GatePieces, lane_xs: PackedFloat32Array,
		blocker_w: float, depth: float) -> void:
	var s: Dictionary = {}
	for sm: Dictionary in _smashes:
		if int(sm["gi"]) == gate_index:
			s = sm
			break
	if s.is_empty() or pieces == null:
		return
	var lanes: int = maxi(lane_xs.size(), 1)
	var cell_w: float = track_width / float(lanes)
	var gap: float = 0.08

	# ── One facade per lane ─────────────────────────────────────────────────
	var blocks: Array[Node3D] = []
	var glow_mats: Array[Material] = []
	for l in lanes:
		var cx: float = -track_width * 0.5 + cell_w * (float(l) + 0.5)
		var f: Node3D = pieces.facade(Vector3(cx, height * 0.5, 0.0),
			Vector3(cell_w - gap, height, depth), TINT, 0.12, 0.42)
		vis_root.add_child(f)
		blocks.append(f)
		# Every neon surface on it, so the mash can charge them all up.
		var stack: Array[Node] = [f]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			var g3 := n as GeometryInstance3D
			if g3 != null and g3.material_override is ShaderMaterial \
					and not glow_mats.has(g3.material_override):
				glow_mats.append(g3.material_override)
			for c in n.get_children():
				stack.append(c)

	# ── Arch round the whole span: not a way past, the door itself ──────────
	pieces.arch(vis_root, 0.0, track_width + 0.12, 0.0, height + 0.25, TINT)

	# ── Approach marks: the runway points at the middle, where he goes in ───
	@warning_ignore("integer_division")
	var mid_x: float = lane_xs[lanes / 2] if lane_xs.size() > 0 else 0.0
	pieces.approach_marks(vis_root, mid_x, blocker_w * 0.80, TINT)

	# ── Cracks ──────────────────────────────────────────────────────────────
	# Neon tubes, white-hot, over the front faces. Revealed one by one as the
	# presses come in, nearest the middle first — the wall gives from where
	# he hits it. Seeded per gate so they do not shuffle between builds.
	var crack_mat: ShaderMaterial = NeonMat.tube(Color(1.0, 0.9, 0.97), 0.0)
	crack_mat.set_shader_parameter("box_size", Vector3(1.0, 0.07, 0.07))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9173 + gate_index * 31
	var cracks: Array[MeshInstance3D] = []
	var centre := Vector2(mid_x, height * 0.5)
	var front_z: float = -depth * 0.5 - 0.09
	for k in CRACKS:
		var reach: float = lerpf(0.15, 1.0, float(k) / float(CRACKS - 1))
		var ang: float = rng.randf() * TAU
		var a: Vector2 = centre + Vector2(cos(ang) * track_width * 0.5,
			sin(ang) * height * 0.5) * reach * rng.randf_range(0.25, 0.7)
		var turn: float = ang + rng.randf_range(-0.7, 0.7)
		var b: Vector2 = a + Vector2(cos(turn), sin(turn)) * rng.randf_range(0.5, 1.3)
		var cm := MeshInstance3D.new()
		cm.mesh = _crack_mesh
		cm.material_override = crack_mat
		cm.set_meta("no_cycle", true)
		var d: Vector2 = b - a
		cm.scale = Vector3(d.length(), 1.0, 1.0)
		cm.rotation.z = atan2(d.y, d.x)
		cm.position = Vector3((a.x + b.x) * 0.5,
			clampf((a.y + b.y) * 0.5, 0.15, height - 0.15), front_z)
		cm.visible = false
		vis_root.add_child(cm)
		cracks.append(cm)

	s["vis"] = {"root": vis_root, "blocks": blocks, "cracks": cracks,
		"glow_mats": glow_mats, "crack_mat": crack_mat, "charge": 0.0,
		"base_x": vis_root.position.x, "height": height, "pieces": pieces}


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(t_s: float, delta: float) -> void:
	_t += delta
	if _active < 0:
		for i in _smashes.size():
			var s: Dictionary = _smashes[i]
			if int(s["state"]) == 0 and t_s >= float(s["t0"]) and t_s < float(s["t1"]):
				_begin(i)
				break
			# A smash whose whole window slipped past (a seek, a long hitch):
			# resolve it as if no presses came, so the wall still breaks.
			if int(s["state"]) == 0 and t_s >= float(s["t1"]):
				_active = i
				s["state"] = 1
				_resolve(s)
	if _active < 0:
		return
	var s2: Dictionary = _smashes[_active]
	_hold_player()
	_update_wall(s2, delta)
	_update_fx(s2)
	var hud: Object = section.get("_hud")
	if hud != null:
		var label: String = "SMASH!  %d / %d" % [int(s2["presses"]), int(s2["target"])]
		hud.call("set_charge", clampf(progress(), 0.0, 1.0), label, true)
	if t_s >= float(s2["t1"]):
		_resolve(s2)


func _begin(i: int) -> void:
	_active = i
	var s: Dictionary = _smashes[i]
	s["state"] = 1
	var p: Node = section.get("player")
	_prev_input_disabled = bool(p.get("input_disabled"))
	p.set("input_disabled", true)
	_ensure_fx(p as Node3D)
	_fx_root.visible = true
	_fx_sparks.emitting = true
	var model: Node3D = p.get("_char_model") as Node3D
	if model != null:
		_prev_lean = model.rotation.x


## Locked to the middle lane, head down.
func _hold_player() -> void:
	var p: Node = section.get("player")
	var lanes: PackedFloat32Array = p.get("lane_xs")
	p.set("target_lane", lanes.size() / 2)
	var model: Node3D = p.get("_char_model") as Node3D
	if model != null:
		model.rotation.x = lerpf(model.rotation.x, deg_to_rad(12.0), 0.25)


func _on_press(s: Dictionary) -> void:
	if _thump != null:
		_thump.pitch_scale = lerpf(0.85, 1.35, clampf(progress(), 0.0, 1.2)) * randf_range(0.96, 1.04)
		_thump.play()
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	# A thump on the wall per press: a quick kick of its charge glow.
	vis["charge"] = minf(float(vis["charge"]) + 0.6, 4.0)


func _update_wall(s: Dictionary, delta: float) -> void:
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	var prog: float = clampf(float(s["presses"]) / float(s["target"]), 0.0, 1.0)
	var cracks: Array = vis["cracks"]
	var shown: int = int(ceil(prog * float(cracks.size())))
	for k in cracks.size():
		(cracks[k] as Node3D).visible = k < shown
	NeonMat.set_energy(vis["crack_mat"],
		lerpf(3.0, 9.0, prog) * (0.85 + 0.15 * sin(_t * 30.0)))
	# The wall's own neon charges up: a kick per press that settles back
	# toward a floor rising with progress.
	var floor_e: float = lerpf(0.0, 2.0, prog)
	vis["charge"] = maxf(floor_e, float(vis["charge"]) - delta * 5.0)
	var boost: float = 1.0 + float(vis["charge"])
	for m: Material in (vis["glow_mats"] as Array):
		if not m.has_meta("base_energy"):
			m.set_meta("base_energy", NeonMat.get_energy(m))
		NeonMat.set_energy(m, float(m.get_meta("base_energy")) * boost)
	# And it shakes harder the closer it is to giving.
	var root: Node3D = vis["root"]
	var shake: float = prog * 0.06 * GameConfig.flash_scale()
	root.position.x = float(vis["base_x"]) + randf_range(-shake, shake)


func _ensure_fx(p: Node3D) -> void:
	if _fx_root != null and is_instance_valid(_fx_root):
		return
	_fx_root = Node3D.new()
	_fx_root.name = "SmashChargeFX"
	p.add_child(_fx_root)
	_fx_light = OmniLight3D.new()
	_fx_light.light_color = Color(0.6, 0.85, 1.0)
	_fx_light.light_energy = 0.0
	_fx_light.omni_range = 4.0
	_fx_light.position = Vector3(0.0, 1.0, 0.0)
	_fx_root.add_child(_fx_light)
	var sp := CPUParticles3D.new()
	sp.amount = 40
	sp.lifetime = 0.45
	sp.local_coords = false
	sp.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sp.emission_sphere_radius = 0.55
	sp.direction = Vector3(0, 0, -1)   # streaming back past him as he charges
	sp.spread = 25.0
	sp.initial_velocity_min = 4.0
	sp.initial_velocity_max = 8.0
	sp.gravity = Vector3.ZERO
	sp.scale_amount_min = 0.6
	sp.scale_amount_max = 1.2
	var m := BoxMesh.new()
	m.size = Vector3(0.03, 0.03, 0.22)
	_spark_mat = StandardMaterial3D.new()
	_spark_mat.albedo_color = Color.BLACK
	_spark_mat.emission_enabled = true
	_spark_mat.emission = Color(0.6, 0.85, 1.0)
	_spark_mat.emission_energy_multiplier = 6.0
	m.material = _spark_mat
	sp.mesh = m
	sp.particle_flag_align_y = true
	sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sp.position = Vector3(0.0, 0.9, 0.0)
	sp.emitting = false
	_fx_root.add_child(sp)
	_fx_sparks = sp


func _update_fx(s: Dictionary) -> void:
	if _fx_root == null:
		return
	var prog: float = clampf(float(s["presses"]) / float(s["target"]), 0.0, 1.0)
	var col: Color = Color(0.6, 0.85, 1.0)
	if rainbow:
		# Echo energy: the whole spectrum, cycling fast, brighter with the charge.
		col = Color.from_hsv(fposmod(_t * 0.9, 1.0), 0.85, 1.0)
	_fx_light.light_color = col
	_fx_light.light_energy = lerpf(0.8, 3.5, prog) * (1.0 if rainbow else 0.6)
	_spark_mat.emission = col


# ══════════════════════════════════════════════════════════════════════════════
#  Impact
# ══════════════════════════════════════════════════════════════════════════════

func _hp_cost(presses: int, target: int) -> float:
	if presses > target:
		return 0.0
	if presses >= target:
		return HP_MET
	var r: float = float(presses) / float(target)
	var k: float = clampf((r - WORST_RATIO) / (1.0 - WORST_RATIO), 0.0, 1.0)
	return lerpf(HP_WORST, HP_MET, k)


func _resolve(s: Dictionary) -> void:
	s["state"] = 2
	_active = -1
	var p: Node = section.get("player")
	p.set("input_disabled", _prev_input_disabled)
	var model: Node3D = p.get("_char_model") as Node3D
	if model != null:
		model.rotation.x = _prev_lean
	if _fx_root != null:
		_fx_sparks.emitting = false
		_fx_light.light_energy = 0.0
	var hud: Object = section.get("_hud")
	if hud != null:
		hud.call("set_charge", 0.0, "", false)

	var presses: int = int(s["presses"])
	var target: int = int(s["target"])
	var cost: float = _hp_cost(presses, target)
	if _crash != null:
		_crash.play()
	section.call("_on_smash_resolved", int(s["gi"]), presses, target, cost)
	_shatter(s)


## The wall comes apart: the facades are thrown outward and forward,
## tumbling, with a burst of neon debris from where he hit; the cracks flash
## out. The arch stays — the door frame he just came through.
func _shatter(s: Dictionary) -> void:
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	var root: Node3D = vis["root"]
	root.position.x = float(vis["base_x"])
	for c: Node3D in (vis["cracks"] as Array):
		c.visible = false
	var blocks: Array = vis["blocks"]
	var tw: Tween = root.create_tween()
	tw.set_parallel(true)
	for b: Node3D in blocks:
		var side: float = signf(b.position.x)
		var dir := Vector3(side * randf_range(3.0, 6.0) + randf_range(-1.0, 1.0),
			randf_range(1.0, 3.0), randf_range(6.0, 12.0))
		tw.tween_property(b, "position", b.position + dir, 0.75) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(b, "rotation",
			Vector3(randf_range(-2.5, 2.5), randf_range(-3.0, 3.0), side * randf_range(1.0, 3.0)), 0.75)
		tw.tween_property(b, "scale", Vector3.ONE * 0.15, 0.75).set_delay(0.2)
	# Neon debris: small bright bars out of the impact point.
	var pieces: GatePieces = vis["pieces"]
	var h: float = float(vis["height"])
	var debris: Array[Node3D] = []
	for k in 18:
		var bar: MeshInstance3D = pieces.box_mesh(
			Vector3(randf_range(0.08, 0.16), randf_range(0.25, 0.7), 0.08),
			TINT.lightened(randf_range(0.0, 0.5)), NeonMat.TUBE, 6.0)
		bar.set_meta("no_cycle", true)
		bar.position = Vector3(randf_range(-0.6, 0.6), h * 0.5 + randf_range(-0.6, 0.6), -0.3)
		root.add_child(bar)
		debris.append(bar)
		var d := Vector3(randf_range(-5.0, 5.0), randf_range(-0.5, 4.0), randf_range(4.0, 10.0))
		tw.tween_property(bar, "position", bar.position + d, 0.6) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(bar, "rotation",
			Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)), 0.6)
		tw.tween_property(bar, "scale", Vector3.ONE * 0.05, 0.6).set_delay(0.15)
	tw.chain().tween_callback(func() -> void:
		for b2: Node3D in blocks:
			b2.visible = false
		for d2: Node3D in debris:
			d2.queue_free())
