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
## How far down the track the wall's body stands from its gate. The wall
## breaks on the beat (t1), and on the beat his body is right at the gate —
## with the wall centred there he had already run half a metre into it, plus
## the reach of his shoulder, before it gave. Standing it this far on puts its
## front face at his shoulder on the beat: he touches it, and it goes.
const WALL_SHIFT: float = 1.0
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
## Whether the active smash has taken his lane and controls yet. Not until he
## is on solid track (Section._smash_lane_lock_ok): forcing the middle lane on
## a wall-jump platform or the descent ramp drops him into the void.
var _locked: bool = false
var _prev_lean: float = 0.0
var _lean_kick: float = 0.0
var _t: float = 0.0

# ── Charge stages (I sparks, II flame trail + afterimages, III energy shell) ─
const STAGE_NAMES: PackedStringArray = ["", "CHARGE II", "CHARGE III"]
var _fx_flame: CPUParticles3D = null
var _fx_ghost: CPUParticles3D = null
var _fx_shell: MeshInstance3D = null
var _shell_mat: ShaderMaterial = null
var _flame_mat: ShaderMaterial = null
var _ghost_mat: ShaderMaterial = null
var _shell_kick: float = 0.0
var _cur_col: Color = TINT
var _cur_level: float = 0.0

# ── Footstep cracks: a small pool reused press after press ──────────────────
const STEP_POOL: int = 20
var _steps: Array[Dictionary] = []     # {node, mat, life}
var _step_i: int = 0

# ── Camera moves on long rolls ──────────────────────────────────────────────
## Shortest roll that gets the camera moves; shorter ones stay behind him.
const CAM_MOVE_MIN_S: float = 2.0
const CAM_SWING_DEG: float = 38.0
var _cam: Camera3D = null
var _cam_pivot: Node3D = null
var _cam_base: Transform3D = Transform3D.IDENTITY
var _cam_low: float = 0.0
var _cam_swing: float = 0.0
var _cam_side: float = 1.0
var _cam_moving: bool = false

# ── Impact aftermath ────────────────────────────────────────────────────────
var _punch: float = 0.0
var _shock_pd: float = 0.0
var _shock_t: float = -1.0
var _shock_ring: MeshInstance3D = null
var _shock_mat: ShaderMaterial = null
const SHOCK_SPEED: float = 70.0
const SHOCK_RANGE_M: float = 95.0
var _wreck: Array[Dictionary] = []     # lingering debris beside the track

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
	var cam: Camera3D = section.get("_camera")
	if cam != null:
		_cam = cam
		_cam_pivot = cam.get_parent() as Node3D
		if _cam_pivot != null:
			_cam_base = _cam_pivot.transform
	# The music is at its busiest during a roll: the press is a soft tick under
	# it, not a thump on top of it. The big sound is saved for the crash.
	_thump = _sfx(_gen_tick(), -21.0)
	_crash = _sfx(_gen_crash(), -2.0)
	_boom = _sfx(_gen_boom(), -1.0)


## `target`: the press count set in the manual mapper (0 = recommended).
## `roll`: times of the roll's hits inside the hold.
## `melody`: times of the melody notes under the hold (they fire the pylons).
func add(gate_index: int, t0: float, t1: float, target: int = 0,
		roll: PackedFloat32Array = PackedFloat32Array(),
		melody: PackedFloat32Array = PackedFloat32Array()) -> void:
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
		"melody": melody, "runway": null, "stage": 0,
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
	# Everything that is the wall lives in a body shifted down the track (see
	# WALL_SHIFT); the runway marks stay on the gate.
	var gate_root: Node3D = vis_root
	vis_root = Node3D.new()
	vis_root.name = "WallBody"
	vis_root.position.z = WALL_SHIFT
	# Processing on its own, whatever the gate does. A gate inside an electric
	# zone starts with its VisRoot DISABLED (Section._build_gate_node) and only
	# electric gates are switched back on — and a smash that opens a zone has
	# its impact right on the zone's start, so it counted as inside it. Its
	# shatter tween never ran: the wall stood there whole and the camera drove
	# straight through it.
	vis_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	gate_root.add_child(vis_root)

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
	pieces.approach_marks(gate_root, mid_x, blocker_w * 0.80, TINT)

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

	# ── The run-up: tunnel, edge light and melody pylons ────────────────────
	if s["runway"] == null:
		var rw := SmashRunway.new()
		rw.build(section, float(s["t0"]), float(s["t1"]), s["melody"], pieces,
			track_width, height, TINT, beat_s)
		s["runway"] = rw

	s["vis"] = {"root": vis_root, "blocks": blocks, "block_mats": block_mats,
		"kick": PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]).slice(0, lanes),
		"cracks": cracks, "cracks_shown": 0, "crack_mat": crack_mat,
		"charge": 0.0, "leak": leak, "base_x": vis_root.position.x, "gate_root": gate_root,
		"height": height, "pieces": pieces}


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(t_s: float, delta: float) -> void:
	_t += delta
	_update_runways(t_s, delta)
	_update_camera(t_s, delta)
	_update_aftermath(t_s, delta)
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
	# His lane and controls are taken in _hold_player, once it is safe.
	_locked = false
	_ensure_fx(p as Node3D)
	_fx_root.visible = true
	_fx_sparks.emitting = true
	s["stage"] = 0
	_cam_side = 1.0 if i % 2 == 0 else -1.0
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
	var p: Node = section.get("player")
	if p.has_method("smash_hit"):
		p.call("smash_hit")
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
	_lean_kick = maxf(0.0, _lean_kick - delta * 9.0)
	# Only take his lane and controls on solid track. Still on a wall-jump
	# platform, the descent ramp, a rail or in the air, he keeps full control
	# (presses still count toward the mash) until he is safely down.
	if not _locked:
		if not bool(section.call("_smash_lane_lock_ok")):
			return
		_locked = true
		p.set("input_disabled", true)
	var lanes: PackedFloat32Array = p.get("lane_xs")
	@warning_ignore("integer_division")
	p.set("target_lane", lanes.size() / 2)
	var to_impact: float = float(s["t1"]) - t_s
	# The rigged model has its own smash clips (BeatRunnerPlayer.set_smash):
	# the head-down sprint, then the shoulder charge for the last beat.
	if bool(p.get("_using_glb_character")) and p.has_method("set_smash"):
		var sh: float = clampf(1.0 - to_impact / beat_s, 0.0, 1.0)
		p.call("set_smash", 2 if to_impact < beat_s else 1, _build(s, t_s), sh)
		return
	# Fallback rig: just lean him into it.
	var model: Node3D = p.get("_char_model") as Node3D
	if model == null:
		return
	var lean: float = 12.0 + 7.0 * _lean_kick
	if to_impact < beat_s:
		lean = lerpf(lean, 26.0, clampf(1.0 - to_impact / beat_s, 0.0, 1.0))
	model.rotation.x = lerpf(model.rotation.x, deg_to_rad(lean), 0.35)


func _on_press(s: Dictionary) -> void:
	# Rumble builds with the mash.
	GameConfig.rumble(0.25 + 0.3 * clampf(progress(), 0.0, 1.0), 0.1 * clampf(progress(), 0.0, 1.0), 0.05)
	if _thump != null:
		_thump.pitch_scale = lerpf(0.9, 1.4, clampf(progress(), 0.0, 1.3)) * randf_range(0.96, 1.04)
		_thump.play()
	var vis: Dictionary = s["vis"]
	if not vis.is_empty():
		vis["charge"] = minf(float(vis["charge"]) + 0.35, 4.0)
	_footstep_crack(_cur_col)
	_shell_kick = maxf(_shell_kick, 0.45)


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
	_build_stage_fx()


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
	_cur_col = col if rainbow else TINT.lerp(Color(1.0, 0.85, 0.95), level * 0.5)
	_cur_level = level
	_update_stage(s, float(s["presses"]) / float(s["target"]), _cur_col)
	# Faster, denser streaks as the roll speeds up.
	_fx_sparks.speed_scale = 1.0 + dens * 1.5 + build * 0.5


## Charge stages: I is the sparks he always has; II adds a flame trail and
## afterimages; III wraps him in an energy shell. Each step up is announced.
func _update_stage(s: Dictionary, prog: float, col: Color) -> void:
	if _fx_flame == null:
		return
	var stage: int = 2 if prog >= 2.0 / 3.0 else (1 if prog >= 1.0 / 3.0 else 0)
	if stage > int(s["stage"]):
		s["stage"] = stage
		_shell_kick = 1.0
		var hud: Object = section.get("_hud")
		if hud != null and stage < STAGE_NAMES.size():
			hud.call("show_callout", STAGE_NAMES[stage], col, 0.40)
		if _fx_burst != null:
			_fx_burst.restart()
			_fx_burst.emitting = true
	var st: int = int(s["stage"])
	_fx_flame.emitting = st >= 1
	_fx_ghost.emitting = st >= 1
	_fx_shell.visible = st >= 2
	NeonMat.set_tint(_flame_mat, col)
	NeonMat.set_tint(_ghost_mat, col)
	NeonMat.set_tint(_shell_mat, col)
	_shell_kick = maxf(0.0, _shell_kick - get_process_delta_time() * 4.0)
	if st >= 2:
		var over: float = clampf(prog - 1.0, 0.0, 1.0)
		_fx_shell.scale = Vector3.ONE * (1.0 + 0.16 * _shell_kick + 0.04 * sin(_t * 22.0) + 0.12 * over)
		NeonMat.set_energy(_shell_mat, (2.2 + 2.5 * _shell_kick + 1.5 * over) * GameConfig.flash_scale())


func _build_stage_fx() -> void:
	# Flame trail: hot blobs streaming up and back off him.
	var fm := SphereMesh.new()
	fm.radius = 0.13
	fm.height = 0.26
	fm.radial_segments = 8
	fm.rings = 4
	_flame_mat = NeonMat.orb(TINT, 7.0)
	fm.material = _flame_mat
	_fx_flame = CPUParticles3D.new()
	_fx_flame.amount = 40
	_fx_flame.lifetime = 0.38
	_fx_flame.local_coords = false
	_fx_flame.mesh = fm
	_fx_flame.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_fx_flame.emission_sphere_radius = 0.35
	_fx_flame.direction = Vector3(0.0, 0.7, -1.0)
	_fx_flame.spread = 22.0
	_fx_flame.initial_velocity_min = 1.5
	_fx_flame.initial_velocity_max = 3.5
	_fx_flame.gravity = Vector3(0.0, 2.5, 0.0)
	_fx_flame.scale_amount_curve = _fade_curve()
	_fx_flame.position = Vector3(0.0, 0.7, -0.2)
	_fx_flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_flame.emitting = false
	_fx_root.add_child(_fx_flame)
	# Afterimages: ghosts of him left hanging where he just was.
	var gm := CapsuleMesh.new()
	gm.radius = 0.34
	gm.height = 1.3
	gm.radial_segments = 12
	gm.rings = 4
	_ghost_mat = NeonMat.ring(TINT, 1.6)
	_ghost_mat.set_shader_parameter("alpha", 0.45)
	_ghost_mat.set_shader_parameter("band_amount", 0.0)
	gm.material = _ghost_mat
	_fx_ghost = CPUParticles3D.new()
	_fx_ghost.amount = 7
	_fx_ghost.lifetime = 0.22
	_fx_ghost.local_coords = false
	_fx_ghost.mesh = gm
	_fx_ghost.direction = Vector3(0.0, 0.0, -1.0)
	_fx_ghost.spread = 0.0
	_fx_ghost.initial_velocity_min = 0.0
	_fx_ghost.initial_velocity_max = 0.0
	_fx_ghost.gravity = Vector3.ZERO
	_fx_ghost.scale_amount_curve = _fade_curve()
	_fx_ghost.position = Vector3(0.0, 0.75, 0.0)
	_fx_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_ghost.emitting = false
	_fx_root.add_child(_fx_ghost)
	# Energy shell round him at stage III.
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 24
	sm.rings = 12
	_shell_mat = NeonMat.ring(TINT, 1.4)
	_shell_mat.set_shader_parameter("alpha", 0.32)
	_shell_mat.set_shader_parameter("band_amount", 0.6)
	_fx_shell = MeshInstance3D.new()
	_fx_shell.mesh = sm
	_fx_shell.material_override = _shell_mat
	_fx_shell.set_meta("no_cycle", true)
	_fx_shell.position = Vector3(0.0, 0.85, 0.0)
	_fx_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_shell.visible = false
	_fx_root.add_child(_fx_shell)


func _fade_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	return c


## A press stamps a small crack into the floor under his feet; they trail
## behind him down the run-up and fade.
func _footstep_crack(col: Color) -> void:
	var p: Node3D = section.get("player") as Node3D
	var world: Node3D = section.get("world_fx_root") as Node3D
	if p == null or world == null:
		return
	if _steps.is_empty():
		for k in STEP_POOL:
			var n := Node3D.new()
			n.visible = false
			world.add_child(n)
			var m: ShaderMaterial = NeonMat.tube(col, 0.0)
			m.set_shader_parameter("box_size", Vector3(1.0, 0.07, 0.07))
			for b in 3:
				var bar := MeshInstance3D.new()
				bar.mesh = _crack_mesh
				bar.material_override = m
				bar.set_meta("no_cycle", true)
				bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				n.add_child(bar)
			_steps.append({"node": n, "mat": m, "life": 0.0})
	var st: Dictionary = _steps[_step_i]
	_step_i = (_step_i + 1) % _steps.size()
	var node: Node3D = st["node"]
	var pd: float = float(section.get("_player_path_dist"))
	var ground: Vector3 = section.call("_path_world_pos", pd, 0.0, 0.0)
	node.global_position = Vector3(p.global_position.x, ground.y + 0.035, p.global_position.z)
	node.rotation = Vector3(0.0, randf() * TAU, 0.0)
	node.visible = true
	var ang: float = 0.0
	for bar: MeshInstance3D in node.get_children():
		var ln: float = randf_range(0.3, 0.75)
		ang += randf_range(1.6, 2.6)
		bar.scale = Vector3(ln, 1.0, 1.0)
		bar.rotation = Vector3(0.0, ang, 0.0)
		bar.position = Vector3(cos(-ang), 0.0, sin(-ang)) * ln * 0.5
	NeonMat.set_tint(st["mat"], col)
	st["life"] = 1.0


func _update_runways(t_s: float, delta: float) -> void:
	for i in _smashes.size():
		var s: Dictionary = _smashes[i]
		var rw: SmashRunway = s["runway"]
		if rw == null:
			continue
		if rw.root == null:
			s["runway"] = null
			continue
		if t_s < float(s["t0"]) - 8.0:
			continue
		var prog: float = float(s["presses"]) / float(s["target"])
		var mine: bool = i == _active
		rw.update(t_s, delta, prog, _cur_col if mine else TINT, _cur_level if mine else 0.0)


## Long rolls get camera moves: a low chase at the start, a swing out to the
## side through the middle, and a snap back behind him for the last beat, so
## the shoulder charge is seen from where the player always sees him.
func _update_camera(t_s: float, delta: float) -> void:
	if _cam_pivot == null or not is_instance_valid(_cam_pivot):
		var cam: Camera3D = section.get("_camera")
		if cam == null:
			return
		_cam = cam
		_cam_pivot = cam.get_parent() as Node3D
		if _cam_pivot == null:
			return
		_cam_base = _cam_pivot.transform
	var low_t: float = 0.0
	var swing_t: float = 0.0
	var rate: float = 2.6
	if _active >= 0:
		var s: Dictionary = _smashes[_active]
		var t0: float = float(s["t0"])
		var t1: float = float(s["t1"])
		var dur: float = t1 - t0
		if dur >= CAM_MOVE_MIN_S:
			var k: float = clampf((t_s - t0) / dur, 0.0, 1.0)
			if t1 - t_s < beat_s:
				rate = 14.0   # the snap back
			else:
				swing_t = smoothstep(0.22, 0.45, k)
				low_t = 1.0 - swing_t
				rate = 3.2
	var a: float = minf(1.0, delta * rate)
	_cam_low = lerpf(_cam_low, low_t, a)
	_cam_swing = lerpf(_cam_swing, swing_t, a)
	if _cam_low < 0.002 and _cam_swing < 0.002:
		if _cam_moving:
			_cam_moving = false
			_cam_low = 0.0
			_cam_swing = 0.0
			_cam_pivot.transform = _cam_base
		return
	if not _cam_moving:
		_cam_moving = true
		_cam_base = _cam_pivot.transform
	var o: Vector3 = _cam_base.origin
	o.y *= lerpf(1.0, 0.5, _cam_low)
	o.z *= lerpf(1.0, 0.72, _cam_low)
	var tr := Transform3D(_cam_base.basis, o)
	tr = Transform3D(Basis(Vector3.UP, deg_to_rad(CAM_SWING_DEG * _cam_side * _cam_swing)),
		Vector3.ZERO) * tr
	_cam_pivot.transform = tr


## After the break: the camera punch and shake, the shockwave running down
## the track, footstep cracks fading, and the wreckage tumbling beside the track.
func _update_aftermath(t_s: float, delta: float) -> void:
	# Footstep cracks fade.
	for st: Dictionary in _steps:
		var life: float = float(st["life"])
		if life <= 0.0:
			continue
		life = maxf(0.0, life - delta * 1.7)
		st["life"] = life
		NeonMat.set_energy(st["mat"], 7.0 * life * life * GameConfig.flash_scale() + 0.2 * life)
		if life <= 0.0:
			(st["node"] as Node3D).visible = false

	# Punch: FOV kick (the section reads _smash_punch) and a shake.
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * 3.2)
		section.set("_smash_punch", _punch)
		if _cam != null:
			var sh: float = _punch * _punch * 0.42 * GameConfig.flash_scale()
			_cam.h_offset = randf_range(-sh, sh)
			_cam.v_offset = randf_range(-sh, sh)

	# Shockwave down the track.
	if _shock_t >= 0.0:
		var front: float = _shock_pd + (t_s - _shock_t) * SHOCK_SPEED
		var k: float = (front - _shock_pd) / SHOCK_RANGE_M
		if k >= 1.0:
			_shock_t = -1.0
			section.set("_smash_shock", Vector2(0.0, -1.0))
			if _shock_ring != null:
				_shock_ring.visible = false
		else:
			section.set("_smash_shock", Vector2(_shock_pd, front))
			if _shock_ring != null:
				_shock_ring.visible = true
				_shock_ring.global_position = section.call("_path_world_pos", front, 0.0, 1.6)
				_shock_ring.global_rotation = Vector3(0.0, deg_to_rad(float(section.call("_path_y_rot_at", front))), 0.0)
				_shock_ring.rotate_object_local(Vector3.RIGHT, PI * 0.5)
				var r: float = lerpf(1.0, 2.2, k)
				_shock_ring.scale = Vector3(r, 1.0, r)
				NeonMat.set_energy(_shock_mat, lerpf(9.0, 0.0, k) * GameConfig.flash_scale() + 0.5 * (1.0 - k))

	# Wreckage: simple tumbling physics, then shrink away.
	var i: int = 0
	while i < _wreck.size():
		var w: Dictionary = _wreck[i]
		var n: Node3D = w["node"]
		var life: float = float(w["life"]) - delta
		w["life"] = life
		if life <= 0.0 or not is_instance_valid(n):
			if is_instance_valid(n):
				n.queue_free()
			_wreck.remove_at(i)
			continue
		var wait: float = float(w.get("wait", 0.0))
		if wait > 0.0:
			w["wait"] = wait - delta
			i += 1
			continue
		var vel: Vector3 = w["vel"]
		var spin: Vector3 = w["spin"]
		vel.y -= 16.0 * delta
		var pos: Vector3 = n.global_position + vel * delta
		var floor_y: float = float(w["floor"])
		if pos.y < floor_y and bool(w["bounce"]):
			pos.y = floor_y
			vel.y = absf(vel.y) * 0.38
			vel.x *= 0.75
			vel.z *= 0.75
			spin *= 0.7
		n.global_position = pos
		n.rotation += spin * delta
		w["vel"] = vel
		w["spin"] = spin
		var fade_s: float = float(w["fade"])
		if life < fade_s:
			n.scale = Vector3.ONE * float(w["size"]) * (life / fade_s)
		i += 1


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


## Practice mode: walls whose window ends before `t` are already behind him.
## Mark them done without breaking them or touching the score.
func skip_before(t: float) -> void:
	for s: Dictionary in _smashes:
		if float(s["t1"]) < t and int(s["state"]) == 0:
			s["state"] = 2
			var vis: Dictionary = s["vis"]
			if not vis.is_empty() and vis.get("root") != null and is_instance_valid(vis["root"]):
				(vis["root"] as Node3D).visible = false


func _resolve(s: Dictionary) -> void:
	s["state"] = 2
	_active = -1
	var p: Node = section.get("player")
	p.set("input_disabled", _prev_input_disabled)
	var model: Node3D = p.get("_char_model") as Node3D
	if model != null:
		model.rotation.x = _prev_lean
	# Through the hole: the burst clip.
	if p.has_method("smash_burst"):
		p.call("smash_burst")
	if _fx_root != null:
		_fx_sparks.emitting = false
		_fx_light.light_energy = 0.0
		if _fx_flame != null:
			_fx_flame.emitting = false
			_fx_ghost.emitting = false
			_fx_shell.visible = false
	var rw: SmashRunway = s["runway"]
	if rw != null:
		rw.finish()
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


## The wall comes apart under a white frame and a camera punch: the facades
## are thrown outward and forward, tumbling, with a burst of neon debris from where he hit — more and
## faster with overcharge. Shards whip past the lens, a shockwave runs down the
## track and knocks the lamps into flickering one after another, and chunks of
## the wall rain down beside the track and keep tumbling for a few seconds.
## The arch stays — the door frame he just came through.
func _shatter(s: Dictionary, over: float) -> void:
	GameConfig.rumble(1.0, 1.0, 0.6)
	var vis: Dictionary = s["vis"]
	if vis.is_empty():
		return
	var flash: float = GameConfig.flash_scale()
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
		leak.light_energy = 9.0 * flash + 2.0
		tw.tween_property(leak, "light_energy", 0.0, 0.6)
	for b: Node3D in blocks:
		# Thrown clear of the track: the camera comes through this spot about
		# half a second after the impact, so nothing may still hang in the
		# lanes by then. The middle block (no side to go to) is the one he hit:
		# it is punched straight down the track, faster than he runs, so the
		# camera never catches it up.
		var side: float = signf(b.position.x)
		var dir: Vector3
		if absf(b.position.x) < 0.3:
			dir = Vector3(randf_range(-1.5, 1.5), randf_range(2.0, 3.5), randf_range(28.0, 34.0)) * force
		else:
			dir = Vector3(side * randf_range(6.0, 9.0), randf_range(1.0, 3.0),
				randf_range(4.0, 9.0)) * force
		tw.tween_property(b, "position", b.position + dir, 0.75) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(b, "rotation",
			Vector3(randf_range(-2.5, 2.5), randf_range(-3.0, 3.0), side * randf_range(1.0, 3.0)),
			0.75)
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
			Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)),
			0.6)
		tw.tween_property(bar, "scale", Vector3.ONE * 0.05, 0.6).set_delay(0.15)
	tw.chain().tween_callback(func() -> void:
		for b2: Node3D in blocks:
			b2.visible = false
		for d2: Node3D in debris:
			d2.queue_free())

	# White frame and camera punch.
	var hud: Object = section.get("_hud")
	if hud != null:
		# Softer when the impact frame is playing: the frame is the flash.
		hud.call("flash", Color(1.0, 1.0, 1.0, 0.2 if flash >= 0.99 else 0.55 * flash), 0.28)
	_punch = 1.35 + 0.4 * over

	var zs: PackedFloat32Array = section.get("gate_world_zs")
	var gi: int = int(s["gi"])
	var v: float = float(section.get("player").get("forward_speed"))
	var wall_pd: float = (zs[gi] if gi < zs.size() else float(s["t1"]) * v) + WALL_SHIFT
	_launch_shards(pieces, wall_pd, h, debris_col, over)
	_spawn_wreck(pieces, wall_pd, h, debris_col, over)
	_impact(pieces, blocks, wall_pd, h, debris_col, over)

	# Shockwave down the track.
	_shock_pd = wall_pd
	_shock_t = float(s["t1"])
	if _shock_ring == null:
		var tm := TorusMesh.new()
		tm.inner_radius = 2.9
		tm.outer_radius = 3.15
		tm.rings = 48
		tm.ring_segments = 8
		_shock_mat = NeonMat.ring(debris_col, 8.0)
		_shock_ring = MeshInstance3D.new()
		_shock_ring.mesh = tm
		_shock_ring.material_override = _shock_mat
		_shock_ring.set_meta("no_cycle", true)
		_shock_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(section.get("world_fx_root") as Node3D).add_child(_shock_ring)
	NeonMat.set_tint(_shock_mat, debris_col.lightened(0.3))
	_shock_ring.visible = false


## The moment of contact, on top of the facades flying and the shockwave:
##   * an impact frame — two or three frames of the picture punched to a hard,
##     inverted, speed-lined still, then a radial blast blur that settles out
##   * a flash of light at the wall that lights him and the whole street
##   * a ring of dust and light racing out across the ground from his feet
##   * the facades blowing apart into chunks that fly, land and tumble
##   * a fountain of sparks, and a deep boom under the crash
## Reduced flashing keeps the chunks, the ring and the boom, and drops the
## impact frame and most of the light.
func _impact(pieces: GatePieces, blocks: Array, wall_pd: float, h: float, col: Color,
		over: float) -> void:
	var flash: float = GameConfig.flash_scale()
	var world: Node3D = section.get("world_fx_root") as Node3D
	var fwd: Vector3 = section.call("_path_forward_at", wall_pd)
	var right: Vector3 = section.call("_path_right_at", wall_pd)
	var ground: Vector3 = section.call("_path_world_pos", wall_pd, 0.0, 0.0)
	var hit: Vector3 = ground + Vector3(0.0, h * 0.5, 0.0)

	# Impact frame and blast blur.
	_impact_overlay(flash)

	# Light.
	var l := OmniLight3D.new()
	l.light_color = col.lerp(Color.WHITE, 0.5)
	l.light_energy = (6.0 + 26.0 * flash) * (1.0 + 0.4 * over)
	l.omni_range = 26.0
	world.add_child(l)
	l.global_position = hit - fwd * 1.5
	var lt: Tween = l.create_tween()
	lt.tween_property(l, "light_energy", 0.0, 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	lt.tween_callback(l.queue_free)

	# Ground ring.
	var tm := TorusMesh.new()
	tm.inner_radius = 0.92
	tm.outer_radius = 1.0
	tm.rings = 48
	tm.ring_segments = 6
	var rm: ShaderMaterial = NeonMat.ring(col.lerp(Color.WHITE, 0.35), 0.0)
	var ring := MeshInstance3D.new()
	ring.mesh = tm
	ring.material_override = rm
	ring.set_meta("no_cycle", true)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(ring)
	ring.global_position = ground + Vector3(0.0, 0.06, 0.0)
	var rt: Tween = ring.create_tween()
	rt.set_parallel(true)
	rt.tween_method(func(k: float) -> void:
		var r: float = lerpf(0.6, 14.0, 1.0 - pow(1.0 - k, 3.0))
		ring.scale = Vector3(r, 1.0, r)
		NeonMat.set_energy(rm, (1.0 - k) * (7.0 * maxf(flash, 0.35))), 0.0, 1.0, 0.6)
	rt.chain().tween_callback(ring.queue_free)

	# The facades blowing apart into chunks.
	for b: Node3D in blocks:
		var bx: float = b.position.x
		for k in int(7 + 5 * over):
			var sz: float = randf_range(0.2, 0.5)
			var chunk: MeshInstance3D = pieces.box_mesh(
				Vector3(randf_range(0.3, 0.8), randf_range(0.25, 0.7), randf_range(0.2, 0.45)) * sz * 1.6,
				TINT.lerp(col, randf()).darkened(randf_range(0.0, 0.35)), NeonMat.PANEL, 3.0)
			chunk.set_meta("no_cycle", true)
			chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			world.add_child(chunk)
			var start: Vector3 = ground + right * (bx + randf_range(-0.7, 0.7)) \
				+ Vector3(0.0, randf_range(0.3, h - 0.2), 0.0)
			chunk.global_position = start
			chunk.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
			# Clear of the lens, like the facades: the camera comes through this
			# spot a fifth of a second after the impact, so every chunk is thrown
			# hard out to the side, and the ones from the middle — right in his
			# path — are punched down the track faster than he runs as well.
			var mid: bool = absf(bx) <= 0.3
			var out: float = signf(bx) if not mid else (-1.0 if k % 2 == 0 else 1.0)
			var vel: Vector3 = right * out * randf_range(9.0, 16.0) \
				+ fwd * (randf_range(24.0, 32.0) if mid else randf_range(3.0, 10.0)) \
				+ Vector3(0.0, randf_range(2.0, 7.0), 0.0)
			vel *= 1.0 + 0.5 * over
			_wreck.append({"node": chunk, "vel": vel,
				"spin": Vector3(randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12)),
				"life": randf_range(2.2, 3.4), "fade": 0.6, "size": 1.0,
				"floor": ground.y + 0.15 * sz, "bounce": true})

	# Sparks.
	if _impact_sparks == null:
		var sm := SphereMesh.new()
		sm.radius = 0.045
		sm.height = 0.09
		sm.radial_segments = 6
		sm.rings = 3
		var spm := StandardMaterial3D.new()
		spm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		spm.vertex_color_use_as_albedo = true
		spm.emission_enabled = true
		spm.emission = Color(1.0, 0.85, 0.7)
		spm.emission_energy_multiplier = 6.0
		sm.material = spm
		_impact_sparks = CPUParticles3D.new()
		_impact_sparks.one_shot = true
		_impact_sparks.emitting = false
		_impact_sparks.amount = 140
		_impact_sparks.lifetime = 0.9
		_impact_sparks.explosiveness = 0.95
		_impact_sparks.local_coords = false
		_impact_sparks.mesh = sm
		_impact_sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		_impact_sparks.emission_sphere_radius = 0.6
		_impact_sparks.spread = 75.0
		_impact_sparks.initial_velocity_min = 6.0
		_impact_sparks.initial_velocity_max = 18.0
		_impact_sparks.gravity = Vector3(0, -14, 0)
		_impact_sparks.damping_min = 1.0
		_impact_sparks.damping_max = 3.0
		var shrink := Curve.new()
		shrink.add_point(Vector2(0, 1))
		shrink.add_point(Vector2(1, 0))
		_impact_sparks.scale_amount_curve = shrink
		_impact_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(_impact_sparks)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1))
	grad.set_color(1, col.lerp(TINT, 0.5))
	_impact_sparks.color_ramp = grad
	_impact_sparks.global_position = hit
	_impact_sparks.global_basis = Basis.looking_at(fwd, Vector3.UP)
	_impact_sparks.direction = Vector3(0, 0.35, -1)   # forward, along the track
	_impact_sparks.restart()
	_impact_sparks.emitting = true

	if _boom != null:
		_boom.play()


var _impact_sparks: CPUParticles3D = null
var _boom: AudioStreamPlayer = null
var _imp_rect: ColorRect = null
var _imp_mat: ShaderMaterial = null

const IMPACT_SHADER: String = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float frame_k = 0.0;   // 1 for the impact frame itself
uniform float blur = 0.0;      // the blast blur after it
uniform vec2 centre = vec2(0.5, 0.48);
uniform vec4 tint : source_color = vec4(1.0, 0.3, 0.7, 1.0);
float h(float n) { return fract(sin(n) * 43758.5453); }
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - centre;
	vec3 c = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		c += texture(screen_tex, uv - d * blur * float(i) / 7.0).rgb;
	}
	c /= 8.0;
	if (frame_k > 0.0) {
		// The still: luminance pushed hard, inverted, with speed lines.
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		// Only the hottest neon goes to ink, so he stays a pale shape on it.
		float ink = smoothstep(0.62, 0.85, l);
		vec3 still = mix(vec3(1.0), tint.rgb * 0.15, ink);
		float ang = atan(d.y, d.x);
		float line = step(0.82, h(floor(ang * 70.0)));
		float r = length(d * vec2(1.6, 1.0));
		still = mix(still, tint.rgb * 0.15, line * smoothstep(0.18, 0.6, r));
		c = mix(c, still, frame_k);
	}
	COLOR = vec4(c, 1.0);
}
"""


func _impact_overlay(flash: float) -> void:
	var hud: Object = section.get("_hud")
	if hud == null:
		return
	if _imp_rect == null:
		var root: Control = hud.call("overlay_root") as Control
		if root == null:
			return
		_imp_rect = ColorRect.new()
		_imp_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_imp_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = IMPACT_SHADER
		_imp_mat = ShaderMaterial.new()
		_imp_mat.shader = sh
		_imp_rect.material = _imp_mat
		root.add_child(_imp_rect)
		root.move_child(_imp_rect, 0)
	_imp_mat.set_shader_parameter("tint", TINT)
	_imp_rect.visible = true
	var tw: Tween = _imp_rect.create_tween()
	if flash >= 0.99:
		# Three frames of the still, then the blur takes over.
		_imp_mat.set_shader_parameter("frame_k", 1.0)
		_imp_mat.set_shader_parameter("blur", 0.0)
		tw.tween_interval(0.055)
		tw.tween_callback(func() -> void: _imp_mat.set_shader_parameter("frame_k", 0.0))
	else:
		_imp_mat.set_shader_parameter("frame_k", 0.0)
	tw.tween_method(func(b: float) -> void: _imp_mat.set_shader_parameter("blur", b),
		0.09 * maxf(flash, 0.35), 0.0, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func() -> void: _imp_rect.visible = false)


## A deep boom under the crash: a falling sub sweep with a hard transient.
func _gen_boom() -> AudioStreamWAV:
	var n: int = int(1.2 * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = lerpf(95.0, 32.0, minf(1.0, t / 0.6))
		ph += TAU * f / float(SR)
		var body: float = sin(ph) * exp(-t * 3.2)
		var click: float = randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.8
		out[i] = clampf((body * 1.4 + click) * minf(1.0, t * 600.0), -1.0, 1.0) * 0.9
	return _wav(out)


## Shards that come back at the lens: they leave the wall slower than he runs,
## so the camera overtakes them and they whip past the screen.
func _launch_shards(pieces: GatePieces, wall_pd: float, h: float, col: Color,
		over: float) -> void:
	var fwd: Vector3 = section.call("_path_forward_at", wall_pd)
	var right: Vector3 = section.call("_path_right_at", wall_pd)
	var ground: Vector3 = section.call("_path_world_pos", wall_pd, 0.0, 0.0)
	for k in int(12 + 8 * over):
		var size := Vector3(randf_range(0.12, 0.3), randf_range(0.04, 0.08), randf_range(0.2, 0.5))
		var shard: MeshInstance3D = pieces.box_mesh(size,
			(TINT if k % 2 == 0 else col).lightened(randf_range(0.1, 0.6)), NeonMat.TUBE, 7.0)
		shard.set_meta("no_cycle", true)
		shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(section.get("world_fx_root") as Node3D).add_child(shard)
		# Past the lens, not into it: each one heads out to its own side, so
		# they whip by the edges of the screen rather than filling it.
		var sd: float = -1.0 if k % 2 == 0 else 1.0
		shard.global_position = ground + right * sd * randf_range(0.5, 1.6) \
			+ Vector3(0.0, randf_range(1.0, h + 0.4), 0.0) + fwd * 0.3
		var vel: Vector3 = fwd * randf_range(0.0, 6.0) + right * sd * randf_range(3.5, 7.0) \
			+ Vector3(0.0, randf_range(0.5, 4.0), 0.0)
		_wreck.append({"node": shard, "vel": vel,
			"spin": Vector3(randf_range(-14, 14), randf_range(-14, 14), randf_range(-14, 14)),
			"life": 1.1, "fade": 0.4, "size": 1.0, "floor": ground.y - 50.0,
			"bounce": false})


## Chunks of the wall beside the track: some knocked out to the sides from the
## wall itself, more raining down ahead of him where the blast threw them.
## They land, bounce and tumble on for a few seconds, glowing, then shrink away.
func _spawn_wreck(pieces: GatePieces, wall_pd: float, h: float, col: Color, over: float) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	var tw_full: float = float(section.call("_track_full_width"))
	var n: int = int(12 + 6 * over)
	for k in n:
		var ahead: bool = k >= 4
		var side: float = -1.0 if k % 2 == 0 else 1.0
		var pd: float = wall_pd + (randf_range(1.0, 3.0) if not ahead else randf_range(6.0, 55.0))
		var lat: float = side * (tw_full * 0.5 + randf_range(0.5, 3.2))
		var fwd: Vector3 = section.call("_path_forward_at", pd)
		var right: Vector3 = section.call("_path_right_at", pd)
		var ground: Vector3 = section.call("_path_world_pos", pd, lat, 0.0)
		var sz: float = randf_range(0.45, 1.0)
		var chunk: MeshInstance3D = pieces.box_mesh(
			Vector3(randf_range(0.6, 1.3), randf_range(0.4, 1.0), randf_range(0.35, 0.8)) * sz,
			(TINT if k % 3 != 0 else col).darkened(randf_range(0.0, 0.3)), NeonMat.PANEL, 2.4)
		chunk.set_meta("no_cycle", true)
		world.add_child(chunk)
		var start: Vector3 = ground + Vector3(0.0, randf_range(0.8, h), 0.0)
		var vel: Vector3
		var wait: float = 0.0
		if ahead:
			# Thrown high by the blast: drops in from above as he gets there.
			start = ground + Vector3(0.0, randf_range(9.0, 16.0), 0.0)
			vel = fwd * randf_range(1.0, 5.0) + right * side * randf_range(0.0, 1.5)
			wait = randf_range(0.0, 0.9)
		else:
			vel = fwd * randf_range(3.0, 8.0) + right * side * randf_range(2.0, 5.0) \
				+ Vector3(0.0, randf_range(3.0, 6.0), 0.0)
		chunk.global_position = start
		chunk.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		_wreck.append({"node": chunk, "vel": vel,
			"spin": Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)),
			"life": randf_range(3.2, 4.6), "fade": 0.8, "size": 1.0,
			"floor": ground.y + 0.25 * sz, "bounce": true, "wait": wait})


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
