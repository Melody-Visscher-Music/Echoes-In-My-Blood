extends Node3D
class_name GateTells

## Gates with a little personality, both halves of it telling the player
## something:
##
##   inhale  a beat or so before a hard stretch (a dense run of gates), the
##           gates of that run draw a breath — swell slightly and brighten —
##           and let it out as the run begins. "Here it comes."
##   glyphs  each gate coming up carries a small sign of the move AFTER it,
##           floating over the spot he will pass through: an arrow for a lane
##           change, a chevron up for a jump, down for a slide. Reading one
##           gate ahead is the skill; this gives a beginner a second gate.
##
## Glyphs stay out of electric zones: seeing only a gate or two ahead is the
## whole difficulty of a zone. RunnerFlair asks inhale(i) for the scale of gate
## i; update() does the rest.

const GLYPH_POOL: int = 6
const GLYPH_AHEAD_M: float = 48.0
const GLYPH_MAX_GAP_S: float = 1.6     # no sign when the next move is far off
const DENSE_N: int = 5
const DENSE_WINDOW_S: float = 2.4
const INHALE_LEAD_S: float = 1.4

var section: Node = null
var player: Node3D = null
var _run_of: Dictionary = {}           # gate index -> run start time
var _runs: Array[float] = []
var _glyphs: Array[Dictionary] = []    # {root, shapes: {kind: Node3D}, mat, gate}
var _beat_s: float = 0.5


func _init() -> void:
	name = "GateTells"


func setup(p_section: Node) -> void:
	section = p_section
	player = section.get("player") as Node3D
	_beat_s = maxf(float(section.get("_runner_avg_beat_s")), 0.2)
	_find_runs()
	_build_glyphs(section.get("world_fx_root") as Node3D)


func _find_runs() -> void:
	var plan: Array = section.get("runner_plan")
	var idx: Array[int] = []
	for i in plan.size():
		if String(plan[i].get("action", "")) in ["left", "right", "jump", "slide"]:
			idx.append(i)
	var j: int = 0
	for n in idx.size():
		while float(plan[idx[n]]["t"]) - float(plan[idx[j]]["t"]) > DENSE_WINDOW_S:
			j += 1
		if n - j + 1 >= DENSE_N:
			var t0: float = float(plan[idx[j]]["t"])
			# Fold overlapping windows into the run that started first.
			var start: float = t0
			if _run_of.has(idx[j]):
				start = float(_run_of[idx[j]])
			elif _runs.is_empty() or t0 - _runs[_runs.size() - 1] > DENSE_WINDOW_S:
				_runs.append(t0)
			else:
				start = _runs[_runs.size() - 1]
			for m in range(j, n + 1):
				if not _run_of.has(idx[m]):
					_run_of[idx[m]] = start


## Scale factor for gate i right now: 1 normally, up to ~1.1 while its run is
## drawing breath.
func inhale(i: int, t_s: float) -> float:
	if not _run_of.has(i):
		return 1.0
	var start: float = float(_run_of[i])
	var u: float = (t_s - (start - INHALE_LEAD_S)) / INHALE_LEAD_S
	if u <= 0.0 or u >= 1.15:
		return 1.0
	# In slowly, out fast: a swell that peaks just before the run.
	var k: float = sin(clampf(u / 0.85, 0.0, 1.0) * PI * 0.5) if u < 0.85 \
		else clampf(1.0 - (u - 0.85) / 0.3, 0.0, 1.0)
	return 1.0 + 0.10 * k * GameConfig.flash_scale()


## How much brighter gate i burns while inhaling (multiplier on energy).
func glow(i: int, t_s: float) -> float:
	var s: float = inhale(i, t_s)
	return 1.0 + (s - 1.0) * 6.0


# ── Glyphs ───────────────────────────────────────────────────────────────────

func _build_glyphs(world: Node3D) -> void:
	for k in GLYPH_POOL:
		var root := Node3D.new()
		root.visible = false
		world.add_child(root)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color.WHITE
		mat.emission_enabled = true
		mat.emission = Color.WHITE
		mat.emission_energy_multiplier = 3.0
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var shapes: Dictionary = {}
		for kind: String in ["left", "right", "jump", "slide"]:
			var sh := Node3D.new()
			root.add_child(sh)
			_shape(sh, kind, mat)
			shapes[kind] = sh
		_glyphs.append({"root": root, "shapes": shapes, "mat": mat, "gate": -1})


## Built from two or three bars. Drawn in the glyph's own plane (x right,
## y up), facing back down the track at him.
func _shape(parent: Node3D, kind: String, mat: Material) -> void:
	var bars: Array = []
	const L: float = 0.26
	const T: float = 0.065
	match kind:
		"left", "right":
			var sgn: float = -1.0 if kind == "left" else 1.0
			bars = [[Vector3(0, 0, 0), L * 1.5, 0.0],                        # shaft
				[Vector3(sgn * L * 0.52, L * 0.22, 0), L * 0.7, -sgn * 40.0],  # head
				[Vector3(sgn * L * 0.52, -L * 0.22, 0), L * 0.7, sgn * 40.0]]
		"jump":
			bars = [[Vector3(-L * 0.25, 0, 0), L * 0.8, 45.0], [Vector3(L * 0.25, 0, 0), L * 0.8, -45.0]]
		"slide":
			bars = [[Vector3(-L * 0.25, 0, 0), L * 0.8, -45.0], [Vector3(L * 0.25, 0, 0), L * 0.8, 45.0]]
	for b: Array in bars:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(float(b[1]), T, T)
		mi.mesh = bm
		mi.material_override = mat
		mi.position = b[0]
		mi.rotation_degrees.z = float(b[2])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("no_cycle", true)
		parent.add_child(mi)


func update(t_s: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var pd: float = float(section.get("_player_path_dist"))
	var zs: Array = section.get("gate_world_zs")
	var judged: Array = section.get("gate_judged")
	var acts: Array = section.get("gate_actions")
	var plan: Array = section.get("runner_plan")
	var lanes: PackedFloat32Array = player.get("lane_xs")
	var start: int = int(section.get("_judge_index"))
	var used: int = 0
	var dark: float = float(section.get("_elec_dark"))
	for i in range(start, zs.size()):
		if used >= _glyphs.size():
			break
		var dz: float = float(zs[i]) - pd
		if dz > GLYPH_AHEAD_M:
			break
		if dz < 1.5 or (i < judged.size() and bool(judged[i])):
			continue
		var a: String = String(acts[i]) if i < acts.size() else ""
		if not a in ["left", "right", "jump", "slide"] or i + 1 >= plan.size():
			continue
		var gt: float = float(plan[i].get("t", 0.0))
		if bool(section.call("_is_electric_at", gt)) or bool(section.call("_is_in_rap_segment", gt)):
			continue
		var nxt: String = String(plan[i + 1].get("action", ""))
		if not nxt in ["left", "right", "jump", "slide"]:
			continue
		if float(plan[i + 1].get("t", 0.0)) - gt > GLYPH_MAX_GAP_S:
			continue
		var g: Dictionary = _glyphs[used]
		used += 1
		var root: Node3D = g["root"]
		for kind: String in g["shapes"]:
			(g["shapes"][kind] as Node3D).visible = kind == nxt
		# Over where he will be when he passes this gate.
		var lane: int = clampi(int(plan[i].get("post_lane", 1)), 0, lanes.size() - 1)
		var h: float = float(section.get("lane_blocker_height")) * 1.15 + 0.55
		if a == "slide":
			h += 0.3
		var gate_pd: float = float(zs[i])
		root.global_position = section.call("_path_world_pos", gate_pd, lanes[lane], h)
		root.rotation_degrees = Vector3(0.0, float(section.call("_path_y_rot_at", gate_pd)) + 180.0, 0.0)
		var col: Color = section.call("_action_color", nxt)
		# Fades in from far, and out in the last few metres so it never sits in
		# his face as he goes through.
		var near: float = clampf((dz - 1.5) / 5.0, 0.0, 1.0)
		var far: float = clampf((GLYPH_AHEAD_M - dz) / 10.0, 0.0, 1.0)
		var mat: StandardMaterial3D = g["mat"]
		col.a = near * far * (1.0 - dark)
		mat.albedo_color = col
		mat.emission = col
		root.scale = Vector3.ONE * lerpf(1.0, 1.6, clampf(dz / GLYPH_AHEAD_M, 0.0, 1.0))
		root.visible = col.a > 0.01
	for k in range(used, _glyphs.size()):
		(_glyphs[k]["root"] as Node3D).visible = false
