extends Node3D
class_name SmashGate

## Smash gates: a wall across all three lanes that can only be broken, not
## dodged. They come from HOLD events on the beats pass of a chart (the manual
## mapper's beat holds) — melody and fx holds stay what they were.
##
## They exist for the stretches where the beats come too fast to tap: a roll
## or build-up into a drop. The mash IS playing that roll, so most of what
## happens here is tied to the roll's own hits (the beats inside the hold,
## which the game no longer turns into gates):
##
##   * the target is worked out from how many hits the roll has
##   * the wall's neon sweeps on every hit, and the cracks land on the hits
##   * the world pulses on the hits, the view tightens and Meeko lunges with
##     them as the roll builds
##
##   prompt (t0 − 1 beat) ── grace ──┬── mash window ──▶ t1 = impact
##                                   t0 − GRACE_S
##
## Any button counts (Esc and Start still pause). Meeko is locked to the middle
## lane and hits the wall at t1 — author the hold so its end sits on the drop,
## and start an electric zone there in the mapper: the gate does not make the
## zone, but when one starts at the impact the zone is visibly waiting behind
## the wall (the section runs its blackout early and light leaks through the
## cracks).
##
## The wall always breaks at t1. What the mash decides is what it costs:
##   * beat the target   →  0 HP, and every press over it is overcharge
##                          (bonus score, a little health, a bigger blast)
##   * meet it exactly   →  2 HP
##   * fall short        →  up to 50 HP, gentler on long rolls
##
## The section owns this node: setup() once, add() per smash, build_visual()
## when a gate's body is built, update() every frame, press() per mash input.

# ── Target ───────────────────────────────────────────────────────────────────
## Presses asked per roll hit. A person cannot mash a 16th-note roll note for
## note, so the target is a share of it.
const ROLL_FACTOR: float = 0.7
## Ceiling on presses per second, however dense the roll. Above this it stops
## being a mash and becomes a hand cramp.
const MAX_RATE: float = 10.0
## Fallback when a hold has no hits inside it (nothing to measure).
const MASH_RATE: float = 6.0
const MIN_TARGET: int = 4

# ── Cost ─────────────────────────────────────────────────────────────────────
const HP_MET: float = 2.0
const HP_WORST: float = 50.0
## Below this fraction of the target the cost is already the full 50 HP.
const WORST_RATIO: float = 0.2
## Long rolls tire the hand: from LONG_ROLL_S on, the shortfall counts for less,
## up to LONG_LENIENCY less at LONG_ROLL_FULL_S and beyond.
const LONG_ROLL_S: float = 2.0
const LONG_ROLL_FULL_S: float = 8.0
const LONG_LENIENCY: float = 0.45

# ── Overcharge ───────────────────────────────────────────────────────────────
## Presses over the target, as a share of it, at which the overcharge maxes.
const OVER_MAX: float = 0.5
## Health the full overcharge gives back.
const OVER_HEAL_HP: float = 5.0

# ── Timing ───────────────────────────────────────────────────────────────────
## Presses count from this long before the hold starts — fast rolls start
## abruptly, and the first presses should not be lost to reaction time.
const GRACE_S: float = 0.2

const CRACKS: int = 18
## The smash gate's own colour. Like every other gate it goes through the
## neon kit, so the colour cycle can still take it over when that is on.
const TINT: Color = Color(1.0, 0.22, 0.62)
## What leaks through the cracks when an electric zone waits behind the wall.
const ZONE_LEAK: Color = Color(0.35, 0.75, 1.0)

var section: Node = null
var rainbow: bool = false
var beat_s: float = 0.5

## One per smash, in time order. Keys:
##   gi, t0, t1, target, presses, state (0 waiting, 1 mashing, 2 done),
##   roll (hit times), roll_i (next hit), prompted, zone_after, vis
var _smashes: Array[Dictionary] = []
var _active: int = -1
var _fx_root: Node3D = null
var _fx_light: OmniLight3D = null
var _fx_sparks: CPUParticles3D = null
var _fx_burst: CPUParticles3D = null
var _spark_mat: StandardMaterial3D = null
var _prev_input_disabled: bool = false
var _prev_lean: float = 0.0
var _lean_kick: float = 0.0
var _t: float = 0.0

var _crack_mesh: BoxMesh = null
var _thump: AudioStreamPlayer = null
var _crash: AudioStreamPlayer = null
const SR: int = 22050


func _init() -> void:
	name = "SmashGates"


func setup(p_section: Node, p_rainbow: bool, p_beat_s: float) -> void:
	section = p_section
	rainbow = p_rainbow
	beat_s = maxf(p_beat_s, 0.15)
	_crack_mesh = BoxMesh.new()
	_crack_mesh.size = Vector3(1.0, 0.06, 0.06)
	# The music is at its busiest during a roll: the press is a soft tick under
	# it, not a thump on top of it. The big sound is saved for the crash.
	_thump = _sfx(_gen_tick(), -21.0)
	_crash = _sfx(_gen_crash(), -2.0)


## `target`: the press count set in the manual mapper (0 = recommended).
## `roll`: times of the roll's hits inside the hold.
func add(gate_index: int, t0: float, t1: float, target: int = 0,
		roll: PackedFloat32Array = PackedFloat32Array()) -> void:
	var hits: PackedFloat32Array = roll
	if hits.is_empty():
		# Nothing to play along to: invent a steady pulse so the wall, the
		# cracks and the world still move with something.
		var step: float = beat_s * 0.5
		var tt: float = t0 + step
		while tt < t1 - 0.01:
			hits.append(tt)
			tt += step
	_smashes.append({
		"gi": gate_index, "t0": t0, "t1": t1,
		"target": target if target > 0 else recommended_target(t1 - t0, roll.size()),
		"presses": 0, "state": 0, "roll": hits, "roll_i": 0,
		"prompted": false, "zone_after": false, "vis": {},
	})


## Marks the smash whose impact opens an electric zone (set by the section
## once the zones are parsed).
func set_zone_after(t1: float) -> void:
	for s: Dictionary in _smashes:
		if absf(float(s["t1"]) - t1) < 0.01:
			s["zone_after"] = true


## Recommended presses: a share of the roll's hits, capped at what a hand can
## do in the time. The manual mapper shows the same number — keep
## ManualMapper.SMASH_* in step with these constants.
static func recommended_target(dur: float, hits: int) -> int:
	var d: float = maxf(dur, 0.1)
	var cap: int = maxi(MIN_TARGET, int(round(d * MAX_RATE)))
	if hits <= 0:
		return maxi(MIN_TARGET, int(round(d * MASH_RATE)))
	return clampi(int(round(float(hits) * ROLL_FACTOR)), MIN_TARGET, cap)


func is_mashing() -> bool:
	return _active >= 0


## The active smash's window and target, for the autopilot. Empty when none.
func active_info() -> Dictionary:
	if _active < 0:
		return {}
	var s: Dictionary = _smashes[_active]
	return {"t0": float(s["t0"]) - GRACE_S, "t1": s["t1"], "target": s["target"],
		"presses": s["presses"]}


## Mash progress of the active smash, 0..1+ (over 1 = overcharging).
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

## Builds the wall into a gate's VisRoot out of the same kit as every other
## gate (GatePieces): one building facade per lane — a lane gate with every
## lane blocked — a neon arch spanning the whole track, the floor's approach
## marks aimed at the middle lane where he hits, and neon-tube cracks that stay
## hidden until the mash reveals them. With a zone behind it, a light waits on
## the far side to come through the cracks.
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

	# ── One facade per lane, each with its own neon so the roll can sweep ───
	var blocks: Array[Node3D] = []
	var block_mats: Array = []          # per block: Array[Material]
	for l in lanes:
		var cx: float = -track_width * 0.5 + cell_w * (float(l) + 0.5)
		var f: Node3D = pieces.facade(Vector3(cx, height * 0.5, 0.0),
			Vector3(cell_w - gap, height, depth), TINT, 0.12, 0.42)
		vis_root.add_child(f)
		blocks.append(f)
		var mats: Array[Material] = []
		var stack: Array[Node] = [f]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			var g3 := n as GeometryInstance3D
			if g3 != null and g3.material_override is ShaderMaterial:
				# Each facade gets its own copies, or one sweep would light
				# all three (facades share cached materials between gates).
				var own: Material = g3.material_override.duplicate()
				g3.material_override = own
				own.set_meta("base_energy", NeonMat.get_energy(own))
				mats.append(own)
			for c in n.get_children():
				stack.append(c)
		block_mats.append(mats)

	# ── Arch round the whole span: not a way past, the door itself ──────────
	pieces.arch(vis_root, 0.0, track_width + 0.12, 0.0, height + 0.25, TINT)

	# ── Approach marks: the runway points at the middle, where he goes in ───
	@warning_ignore("integer_division")
	var mid_x: float = lane_xs[lanes / 2] if lane_xs.size() > 0 else 0.0
	pieces.approach_marks(vis_root, mid_x, blocker_w * 0.80, TINT)

	# ── Cracks ──────────────────────────────────────────────────────────────
	# Neon tubes over the front faces, revealed nearest the middle first — the
	# wall gives from where he hits it. Each new crack branches off the end of
	# an earlier one, so the damage webs out instead of popping in at random.
	var crack_mat: ShaderMaterial = NeonMat.tube(Color(1.0, 0.9, 0.97), 0.0)
	crack_mat.set_shader_parameter("box_size", Vector3(1.0, 0.07, 0.07))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9173 + gate_index * 31
	var cracks: Array[MeshInstance3D] = []
	var centre := Vector2(mid_x, height * 0.55)
	var ends: Array[Vector2] = []
	var front_z: float = -depth * 0.5 - 0.09
	for k in CRACKS:
		var a: Vector2 = centre
		if k >= 4 and not ends.is_empty():
			a = ends[rng.randi() % ends.size()]
		var ang: float = rng.randf() * TAU
		if a != centre:
			# Keep growing outward from the impact point.
			ang = (a - centre).angle() + rng.randf_range(-0.9, 0.9)
		var b: Vector2 = a + Vector2(cos(ang), sin(ang)) * rng.randf_range(0.45, 1.1)
		b.x = clampf(b.x, -track_width * 0.5 + 0.1, track_width * 0.5 - 0.1)
		b.y = clampf(b.y, 0.15, height - 0.15)
		ends.append(b)
		var cm := MeshInstance3D.new()
		cm.mesh = _crack_mesh
		cm.material_override = crack_mat
		cm.set_meta("no_cycle", true)
		var d: Vector2 = b - a
		cm.scale = Vector3(maxf(d.length(), 0.05), 1.0, 1.0)
		cm.rotation.z = atan2(d.y, d.x)
		cm.position = Vector3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, front_z)
		cm.visible = false
		vis_root.add_child(cm)
		cracks.append(cm)

	# ── The zone, waiting on the other side ─────────────────────────────────
	var leak: OmniLight3D = null
	if bool(s["zone_after"]):
		leak = OmniLight3D.new()
		leak.light_color = ZONE_LEAK
		leak.light_energy = 0.0
		leak.omni_range = 9.0
		leak.position = Vector3(mid_x, height * 0.5, depth * 0.5 + 1.2)
		vis_root.add_child(leak)

	s["vis"] = {"root": vis_root, "blocks": blocks, "block_mats": block_mats,
		"kick": PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]).slice(0, lanes),
		"cracks": cracks, "cracks_shown": 0, "crack_mat": crack_mat,
		"charge": 0.0, "leak": leak, "base_x": vis_root.position.x,
		"height": height, "pieces": pieces}


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(t_s: float, delta: float) -> void:
	_t += delta
	if _active < 0:
		for i in _smashes.size():
			var s: Dictionary = _smashes[i]
			if int(s["state"]) != 0:
				continue
			var t0: float = float(s["t0"])
			var t1: float = float(s["t1"])
			# One beat ahead: the prompt and a flash of the wall, so the start
			# of a fast roll never comes out of nowhere.
			if not bool(s["prompted"]) and t_s >= t0 - beat_s and t_s < t1:
				s["prompted"] = true
				var vis: Dictionary = s["vis"]
				if not vis.is_empty():
					vis["charge"] = 2.5
			if t_s >= t0 - GRACE_S and t_s < t1:
				_begin(i)
				break
			# A smash whose whole window slipped past (a seek, a long hitch):
			# resolve it as if no presses came, so the wall still breaks.
			if t_s >= t1:
				_active = i
				s["state"] = 1
				_resolve(s)
				break
			if bool(s["prompted"]):
				_show_meter("GET READY", 0.0)
				_update_wall(s, delta, 0.0)
	if _active < 0:
		return
	var s2: Dictionary = _smashes[_active]
	_play_roll(s2, t_s)
	var build: float = _build(s2, t_s)
	_hold_player(s2, t_s, delta)
	_update_wall(s2, delta, build)
	_update_fx(s2, t_s, build)
	section.set("_smash_squeeze", build)
	var over: bool = int(s2["presses"]) > int(s2["target"])
	_show_meter(("OVERCHARGE  +%d" % (int(s2["presses"]) - int(s2["target"]))) if over
		else ("SMASH!  %d / %d" % [int(s2["presses"]), int(s2["target"])]),
		clampf(progress(), 0.0, 1.0))
	if t_s >= float(s2["t1"]):
		_resolve(s2)


func _show_meter(label: String, fill: float) -> void:
	var hud: Object = section.get("_hud")
	if hud != null:
		hud.call("set_charge", fill, label, true)


## How far into the roll we are, 0..1, weighted toward the end: the build-up.
func _build(s: Dictionary, t_s: float) -> float:
	var t0: float = float(s["t0"])
	var t1: float = float(s["t1"])
	var k: float = clampf((t_s - t0) / maxf(t1 - t0, 0.05), 0.0, 1.0)
	return k * k


## Hits per second over the last half-second of the roll, as 0..1.
func _density(s: Dictionary, t_s: float) -> float:
	var roll: PackedFloat32Array = s["roll"]
	var n: int = 0
	for i in range(int(s["roll_i"]) - 1, -1, -1):
		if roll[i] < t_s - 0.5:
			break
		n += 1
	return clampf(float(n) / 0.5 / 14.0, 0.0, 1.0)


func _begin(i: int) -> void:
	_active = i
	var s: Dictionary = _smashes[i]
	s["state"] = 1
	# Hits that fell in the prompt/grace moment are already behind us.
	var roll: PackedFloat32Array = s["roll"]
	var ri: int = 0
	var now: float = float(s["t0"]) - GRACE_S
	while ri < roll.size() and roll[ri] < now:
		ri += 1
	s["roll_i"] = ri
	var p: Node = section.get("player")
	_prev_input_disabled = bool(p.get("input_disabled"))
	p.set("input_disabled", true)
	_ensure_fx(p as Node3D)
	_fx_root.visible = true
	_fx_sparks.emitting = true
	var model: Node3D = p.get("_char_model") as Node3D
	if model != null:
		_prev_lean = model.rotation.x


## Everything that happens on a roll hit: the wall sweeps, a crack lands if
## the mash has earned one, the world pulses, and Meeko lunges.
func _play_roll(s: Dictionary, t_s: float) -> void:
	var roll: PackedFloat32Array = s["roll"]
	var ri: int = int(s["roll_i"])
	while ri < roll.size() and t_s >= roll[ri]:
		_on_roll_hit(s, ri)
		ri += 1
	s["roll_i"] = ri


func _on_roll_hit(s: Dictionary, idx: int) -> void:
	var vis: Dictionary = s["vis"]
	if not vis.is_empty():
		# Sweep across the facades like an equaliser, bouncing end to end.
		var kick: PackedFloat32Array = vis["kick"]
		var n: int = kick.size()
		if n > 0:
			var period: int = maxi(1, n * 2 - 2)
			var pos: int = idx % period
			var b: int = pos if pos < n else period - pos
			kick[b] = 2.2
			vis["kick"] = kick
		# The cracks land on the music: reveal up to what the presses earned.
		var cracks: Array = vis["cracks"]
		var earned: int = int(ceil(clampf(progress(), 0.0, 1.0) * float(cracks.size())))
		var shown: int = int(vis["cracks_shown"])
		if shown < earned:
			shown += maxi(1, (earned - shown) / 2)
			vis["cracks_shown"] = mini(shown, cracks.size())
	_lean_kick = 1.0
	if _fx_burst != null:
		_fx_burst.restart()
		_fx_burst.emitting = true
	# Reduced flashing: the world pulses on every other hit only.
	if GameConfig.flash_scale() >= 1.0 or idx % 2 == 0:
		section.call("_smash_roll_pulse")


## Locked to the middle lane, head down; lunging with the roll, and dropping
## into the shoulder charge for the last beat before impact.
func _hold_player(s: Dictionary, t_s: float, delta: float) -> void:
	var p: Node = section.get("player")
	var lanes: PackedFloat32Array = p.get("lane_xs")
	@warning_ignore("integer_division")
	p.set("target_lane", lanes.size() / 2)
	_lean_kick = maxf(0.0, _lean_kick - delta * 9.0)
	var model: Node3D = p.get("_char_model") as Node3D
	if model == null:
		return
	var to_impact: float = float(s["t1"]) - t_s
	var lean: float = 12.0 + 7.0 * _lean_kick
	if to_impact < beat_s:
		lean = lerpf(lean, 26.0, clampf(1.0 - to_impact / beat_s, 0.0, 1.0))
	model.rotation.x = lerpf(model.rotation.x, deg_to_rad(lean), 0.35)


func _on_press(s: Dictionary) -> void:
	if _thump != null:
		_thump.pitch_scale = lerpf(0.9, 1.4, clampf(progress(), 0.0, 1.3)) * randf_range(0.96, 1.04)
		_thump.play()
	var vis: Dictionary = s["vis"]
	if not vis.is_empty():
		vis["charge"] = minf(float(vis["charge"]) + 0.35, 4.0)


func _update_wall(s: Dictionary, delta: float, build: float) -> void:
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	var prog: float = clampf(float(s["presses"]) / float(s["target"]), 0.0, 1.0)
	var over: float = clampf((float(s["presses"]) / float(s["target"]) - 1.0) / OVER_MAX, 0.0, 1.0)
	var cracks: Array = vis["cracks"]
	var shown: int = int(vis["cracks_shown"])
	for k in cracks.size():
		(cracks[k] as Node3D).visible = k < shown
	# The cracks run hotter with progress; with a zone behind the wall they
	# turn the zone's blue, as if its light is coming through them.
	var cmat: ShaderMaterial = vis["crack_mat"]
	NeonMat.set_energy(cmat, lerpf(3.0, 9.0, prog) * (1.0 + 0.6 * over)
		* (0.85 + 0.15 * sin(_t * 30.0)))
	if bool(s["zone_after"]):
		NeonMat.set_tint(cmat, Color(1.0, 0.9, 0.97).lerp(ZONE_LEAK, prog))
		var leak: OmniLight3D = vis["leak"]
		if leak != null:
			leak.light_energy = lerpf(0.0, 5.0, prog) * (1.0 + over) * GameConfig.flash_scale() \
				+ 0.6 * build
	# The wall's own neon: a floor that rises with progress (higher still when
	# overcharging), a kick per press, and the roll's sweep on top per facade.
	var floor_e: float = lerpf(0.0, 1.6, prog) + 1.2 * over
	vis["charge"] = maxf(floor_e, float(vis["charge"]) - delta * 5.0)
	var kick: PackedFloat32Array = vis["kick"]
	var block_mats: Array = vis["block_mats"]
	for b in block_mats.size():
		kick[b] = maxf(0.0, kick[b] - delta * 12.0)
		var boost: float = 1.0 + float(vis["charge"]) + kick[b]
		for m: Material in (block_mats[b] as Array):
			NeonMat.set_energy(m, float(m.get_meta("base_energy")) * boost)
	vis["kick"] = kick
	# And it shakes harder the closer it is to giving.
	var root: Node3D = vis["root"]
	var shake: float = (prog * 0.06 + over * 0.04) * GameConfig.flash_scale()
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
	var m := BoxMesh.new()
	m.size = Vector3(0.03, 0.03, 0.22)
	_spark_mat = StandardMaterial3D.new()
	_spark_mat.albedo_color = Color.BLACK
	_spark_mat.emission_enabled = true
	_spark_mat.emission = Color(0.6, 0.85, 1.0)
	_spark_mat.emission_energy_multiplier = 6.0
	m.material = _spark_mat
	# Steady speed lines streaming back past him while he charges...
	_fx_sparks = _streak_emitter(m, 40, 0.45, false)
	_fx_root.add_child(_fx_sparks)
	# ...and a burst of them on every roll hit.
	_fx_burst = _streak_emitter(m, 14, 0.3, true)
	_fx_root.add_child(_fx_burst)


func _streak_emitter(mesh: Mesh, amount: int, life: float, one_shot: bool) -> CPUParticles3D:
	var sp := CPUParticles3D.new()
	sp.amount = amount
	sp.lifetime = life
	sp.one_shot = one_shot
	sp.explosiveness = 0.9 if one_shot else 0.0
	sp.local_coords = false
	sp.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sp.emission_sphere_radius = 0.55
	sp.direction = Vector3(0, 0, -1)
	sp.spread = 25.0
	sp.initial_velocity_min = 4.0 if not one_shot else 7.0
	sp.initial_velocity_max = 8.0 if not one_shot else 12.0
	sp.gravity = Vector3.ZERO
	sp.scale_amount_min = 0.6
	sp.scale_amount_max = 1.2
	sp.mesh = mesh
	sp.particle_flag_align_y = true
	sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sp.position = Vector3(0.0, 0.9, 0.0)
	sp.emitting = false
	return sp


func _update_fx(s: Dictionary, t_s: float, build: float) -> void:
	if _fx_root == null:
		return
	var prog: float = clampf(float(s["presses"]) / float(s["target"]), 0.0, 1.0)
	var dens: float = _density(s, t_s)
	# Builds with the roll: how far in, how fast the hits are coming, and how
	# well the mash is going — peaking at the impact.
	var level: float = clampf(maxf(build, prog * 0.7) + dens * 0.3, 0.0, 1.0)
	var col: Color = Color(0.6, 0.85, 1.0)
	if rainbow:
		# Echo energy: faint and washed-out at the start of the roll, the full
		# spectrum cycling fast at the impact.
		col = Color.from_hsv(fposmod(_t * lerpf(0.4, 1.4, level), 1.0),
			lerpf(0.25, 0.95, level), 1.0)
		_fx_light.light_energy = lerpf(0.3, 4.5, level)
	else:
		_fx_light.light_energy = lerpf(0.4, 2.2, level)
	_fx_light.light_color = col
	_spark_mat.emission = col
	# Faster, denser streaks as the roll speeds up.
	_fx_sparks.speed_scale = 1.0 + dens * 1.5 + build * 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  Impact
# ══════════════════════════════════════════════════════════════════════════════

func _hp_cost(presses: int, target: int, dur: float) -> float:
	if presses > target:
		return 0.0
	if presses >= target:
		return HP_MET
	var r: float = float(presses) / float(target)
	# Long rolls: the shortfall counts for less.
	var lenient: float = clampf((dur - LONG_ROLL_S) / (LONG_ROLL_FULL_S - LONG_ROLL_S), 0.0, 1.0)
	r = 1.0 - (1.0 - r) * (1.0 - LONG_LENIENCY * lenient)
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
	# Let the view open back out over a moment rather than snapping.
	var tw: Tween = create_tween()
	tw.tween_method(func(v: float) -> void: section.set("_smash_squeeze", v),
		float(section.get("_smash_squeeze")), 0.0, 0.35)

	var presses: int = int(s["presses"])
	var target: int = int(s["target"])
	var cost: float = _hp_cost(presses, target, float(s["t1"]) - float(s["t0"]))
	var over: float = clampf((float(presses) / float(target) - 1.0) / OVER_MAX, 0.0, 1.0)
	if _crash != null:
		_crash.play()
	section.call("_on_smash_resolved", int(s["gi"]), presses, target, cost,
		over * OVER_HEAL_HP)
	_shatter(s, over)


## The wall comes apart: the facades are thrown outward and forward,
## tumbling, with a burst of neon debris from where he hit — more and faster
## with overcharge. The arch stays — the door frame he just came through.
func _shatter(s: Dictionary, over: float) -> void:
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	var root: Node3D = vis["root"]
	root.position.x = float(vis["base_x"])
	for c: Node3D in (vis["cracks"] as Array):
		c.visible = false
	var leak: OmniLight3D = vis["leak"]
	var blocks: Array = vis["blocks"]
	var force: float = 1.0 + over * 0.8
	var tw: Tween = root.create_tween()
	tw.set_parallel(true)
	if leak != null:
		# The zone's light floods through the hole, then the zone takes over.
		leak.light_energy = 9.0 * GameConfig.flash_scale() + 2.0
		tw.tween_property(leak, "light_energy", 0.0, 0.6)
	for b: Node3D in blocks:
		var side: float = signf(b.position.x)
		var dir := Vector3(side * randf_range(3.0, 6.0) + randf_range(-1.0, 1.0),
			randf_range(1.0, 3.0), randf_range(6.0, 12.0)) * force
		tw.tween_property(b, "position", b.position + dir, 0.75) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(b, "rotation",
			Vector3(randf_range(-2.5, 2.5), randf_range(-3.0, 3.0), side * randf_range(1.0, 3.0)), 0.75)
		tw.tween_property(b, "scale", Vector3.ONE * 0.15, 0.75).set_delay(0.2)
	var pieces: GatePieces = vis["pieces"]
	var h: float = float(vis["height"])
	var debris: Array[Node3D] = []
	var debris_col: Color = ZONE_LEAK if bool(s["zone_after"]) else TINT
	for k in int(18 + 14 * over):
		var bar: MeshInstance3D = pieces.box_mesh(
			Vector3(randf_range(0.08, 0.16), randf_range(0.25, 0.7), 0.08),
			(TINT if k % 2 == 0 else debris_col).lightened(randf_range(0.0, 0.5)),
			NeonMat.TUBE, 6.0)
		bar.set_meta("no_cycle", true)
		bar.position = Vector3(randf_range(-0.6, 0.6), h * 0.5 + randf_range(-0.6, 0.6), -0.3)
		root.add_child(bar)
		debris.append(bar)
		var d := Vector3(randf_range(-5.0, 5.0), randf_range(-0.5, 4.0), randf_range(4.0, 10.0)) * force
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


# ══════════════════════════════════════════════════════════════════════════════
#  Sound
# ══════════════════════════════════════════════════════════════════════════════

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


## A short, soft tick per press — present, but under the roll, not over it.
func _gen_tick() -> AudioStreamWAV:
	var n: int = int(0.045 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = sin(TAU * 180.0 * t) * exp(-t * 90.0) * 0.6 \
			+ randf_range(-1.0, 1.0) * exp(-t * 400.0) * 0.25
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
		var debris: float = (randf_range(-1.0, 1.0) if randf() < 0.02 * exp(-t * 3.0) else 0.0) * 0.6
		s[i] = boom + shatter + debris
	return _wav(s)
