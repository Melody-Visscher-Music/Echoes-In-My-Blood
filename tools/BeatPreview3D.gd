## BeatPreview3D.gd
## 3D beat preview window for ManualMapper.
## Generates the actual runner plan by calling Section_BeatRunner3d's own
## _build_runner_plan_from_beats on a minimal off-tree stub instance —
## so what you see here IS what the game will generate.
extends VBoxContainer

var mapper: Node = null

const FWD_SPEED : float = 18.0

# ── loaded scripts ─────────────────────────────────────────────────────────────
const _SECTION_SCR = preload("res://scripts/beat3d/Section_BeatRunner3d.gd")
const _PLAYER_SCR  = preload("res://scripts/beat3d/BeatRunnerPlayer.gd")

# ── scene refs ─────────────────────────────────────────────────────────────────
var _vp         : SubViewport    = null
var _cam        : Camera3D       = null
var _meeko      : MeshInstance3D = null
var _gate_root  : Node3D         = null
var _floor_root : Node3D         = null
var _info_lbl   : Label          = null

# ── state ──────────────────────────────────────────────────────────────────────
var _plan          : Array[Dictionary] = []   # result of _build_runner_plan_from_beats
var _last_evt_count: int  = -1
var _meeko_x       : float = 0.0   # smoothed lateral position

# ── colours matching game's city-theme gate visuals ───────────────────────────
const COL_LANE_BLOCK : Color = Color(0.70, 0.15, 1.00)   # blocker panel (purple)
const COL_LANE_SAFE  : Color = Color(0.20, 1.00, 0.55)   # safe-lane arch (green)
const COL_JUMP       : Color = Color(1.00, 0.55, 0.05)   # hurdle (orange)
const COL_SLIDE      : Color = Color(0.10, 0.75, 1.00)   # slide bar (cyan)
const COL_WALL       : Color = Color(1.00, 0.20, 0.20)   # wall-jump plate (red)
const COL_FLOOR      : Array[Color] = [
	Color(0.18, 0.08, 0.30),
	Color(0.22, 0.10, 0.35),
	Color(0.18, 0.08, 0.30),
]

# ── public ──────────────────────────────────────────────────────────────────────

func setup(mapper_node: Node) -> void:
	mapper = mapper_node
	_build_ui()
	_build_3d_scene()
	rebuild()

func rebuild() -> void:
	if mapper == null:
		return
	_plan = _generate_plan(mapper.events)
	_rebuild_gates()
	_last_evt_count = mapper.events.size()

# ── lifecycle ───────────────────────────────────────────────────────────────────

func _process(dt: float) -> void:
	if mapper == null or _vp == null:
		return

	if mapper.events.size() != _last_evt_count:
		rebuild()

	var t  : float = mapper._play_time()
	var z  : float = t * FWD_SPEED

	# Find current lane from plan
	var cur_lane : int = 1
	for entry in _plan:
		if float(entry.get("t", 0.0)) <= t:
			cur_lane = int(entry.get("post_lane", 1))
		else:
			break

	var lane_xs : PackedFloat32Array = PackedFloat32Array([-2.4, 0.0, 2.4])
	var target_x : float = lane_xs[clamp(cur_lane, 0, 2)]
	_meeko_x = lerpf(_meeko_x, target_x, minf(1.0, dt * 12.0))
	_meeko.position = Vector3(_meeko_x, 0.55, z)

	_cam.position = Vector3(_meeko_x * 0.4, 3.4, z - 9.5)
	_cam.look_at(Vector3(_meeko_x * 0.2, 0.9, z + 20.0), Vector3.UP)

	if _info_lbl != null:
		var action_now : String = ""
		for entry in _plan:
			if float(entry.get("t", 0.0)) <= t:
				action_now = String(entry.get("action", ""))
		_info_lbl.text = "t=%.2fs  lane%d  %s" % [t, cur_lane, action_now]

# ── UI build ────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	add_child(toolbar)

	var btn := Button.new()
	btn.text = "⟳ Rebuild"
	btn.tooltip_text = "Regenerate the runner plan from current events"
	toolbar.add_child(btn)
	btn.pressed.connect(rebuild)

	_info_lbl = Label.new()
	_info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_lbl.add_theme_font_size_override("font_size", 11)
	_info_lbl.add_theme_color_override("font_color", Color(0.55, 0.52, 0.70))
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toolbar.add_child(_info_lbl)

	var vpc := SubViewportContainer.new()
	vpc.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.stretch = true
	add_child(vpc)

	_vp = SubViewport.new()
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.handle_input_locally = false
	vpc.add_child(_vp)

# ── 3-D scene ───────────────────────────────────────────────────────────────────

func _build_3d_scene() -> void:
	var root := Node3D.new()
	_vp.add_child(root)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.light_energy     = 1.3
	sun.shadow_enabled   = false
	root.add_child(sun)

	var fill := OmniLight3D.new()
	fill.light_energy = 0.35
	fill.omni_range   = 140.0
	fill.position     = Vector3(0.0, 8.0, 0.0)
	root.add_child(fill)

	var env := Environment.new()
	env.background_mode          = Environment.BG_COLOR
	env.background_color         = Color(0.04, 0.02, 0.08)
	env.ambient_light_source     = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color      = Color(0.15, 0.08, 0.28)
	env.ambient_light_energy     = 0.7
	env.tonemap_mode             = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	_floor_root = Node3D.new()
	root.add_child(_floor_root)

	_gate_root = Node3D.new()
	root.add_child(_gate_root)

	# Meeko sphere
	var sph := SphereMesh.new()
	sph.radius = 0.40
	sph.height = 0.80
	var smat := StandardMaterial3D.new()
	smat.albedo_color               = Color(0.0, 1.0, 0.88)
	smat.emission_enabled           = true
	smat.emission                   = Color(0.0, 1.0, 0.88)
	smat.emission_energy_multiplier = 3.5
	_meeko = MeshInstance3D.new()
	_meeko.mesh              = sph
	_meeko.material_override = smat
	_meeko.position          = Vector3(0.0, 0.55, 0.0)
	root.add_child(_meeko)

	_cam = Camera3D.new()
	_cam.fov      = 72.0
	_cam.near     = 0.2
	_cam.far      = 600.0
	root.add_child(_cam)

# ── plan generation ─────────────────────────────────────────────────────────────

func _generate_plan(events: Array) -> Array[Dictionary]:
	if events.is_empty():
		return []

	# Minimal off-tree Section_BeatRunner3d instance — no _ready(), no scene deps.
	var sec = _SECTION_SCR.new()

	# Stub player so lane_xs / physics values are available
	var fake_player = _PLAYER_SCR.new()
	sec.player = fake_player

	# Compute average beat spacing from events
	var times: Array[float] = []
	for e in events:
		times.append(float(e.get("t", 0.0)))
	times.sort()
	var total : float = 0.0
	var cnt   : int   = 0
	for i in range(1, times.size()):
		var dt : float = times[i] - times[i - 1]
		if dt > 0.04 and dt < 2.5:
			total += dt; cnt += 1
	sec._runner_avg_beat_s = (total / float(cnt)) if cnt > 0 else 0.5

	# Deterministic seed so the preview is stable while you edit
	sec._runner_rng.seed = 99999

	# Only beats become gates — mirror what Section_BeatRunner3d._load_chart_and_build_plan does
	var typed_events: Array[Dictionary] = []
	for e in events:
		if e is Dictionary and String((e as Dictionary).get("capture_pass", "")) == "beats":
			typed_events.append(e as Dictionary)

	var result: Array[Dictionary] = sec._build_runner_plan_from_beats(typed_events)

	# Clean up the stubs
	fake_player.free()
	sec.free()

	return result

# ── gate + floor rebuild ────────────────────────────────────────────────────────

func _rebuild_gates() -> void:
	for c in _gate_root.get_children():   c.queue_free()
	for c in _floor_root.get_children():  c.queue_free()

	if _plan.is_empty():
		return

	var lane_xs : PackedFloat32Array = PackedFloat32Array([-2.4, 0.0, 2.4])
	var lw      : float = 2.0   # lane strip width
	var tw      : float = abs(lane_xs[0]) * 2.0 + lw   # total track width

	# Song length
	var last_t : float = 0.0
	for e in _plan:
		last_t = maxf(last_t, float(e.get("t", 0.0)))
	var song_z : float = (last_t + 4.0) * FWD_SPEED

	# ── Floor strips ─────────────────────────────────────────────────────────
	for ln in range(3):
		var lx   : float = lane_xs[ln]
		var fc   : Color = COL_FLOOR[ln]
		var fm   := BoxMesh.new()
		fm.size  = Vector3(lw, 0.10, song_z)
		var fmat := StandardMaterial3D.new()
		fmat.albedo_color               = fc
		fmat.emission_enabled           = true
		fmat.emission                   = fc.lightened(0.3)
		fmat.emission_energy_multiplier = 0.15
		var fmi  := MeshInstance3D.new()
		fmi.mesh              = fm
		fmi.material_override = fmat
		fmi.position          = Vector3(lx, -0.05, song_z * 0.5)
		_floor_root.add_child(fmi)

		# Edge glow line
		for side in [-1, 1]:
			var em  := BoxMesh.new()
			em.size = Vector3(0.05, 0.12, song_z)
			var emat := StandardMaterial3D.new()
			emat.albedo_color               = fc.lightened(0.5)
			emat.emission_enabled           = true
			emat.emission                   = fc.lightened(0.5)
			emat.emission_energy_multiplier = 1.5
			var emi := MeshInstance3D.new()
			emi.mesh              = em
			emi.material_override = emat
			emi.position          = Vector3(lx + float(side) * (lw * 0.5), 0.0, song_z * 0.5)
			_floor_root.add_child(emi)

	# ── Gate markers ──────────────────────────────────────────────────────────
	for entry in _plan:
		var t          : float  = float(entry.get("t",         0.0))
		var action     : String = String(entry.get("action",   "left"))
		var post_lane  : int    = clamp(int(entry.get("post_lane", 1)), 0, 2)
		var pre_lane   : int    = clamp(int(entry.get("pre_lane",  1)), 0, 2)
		var gz         : float  = t * FWD_SPEED

		match action:
			"jump":
				# Low hurdle spanning the whole track
				_add_box(_gate_root, Vector3(0.0, 0.38, gz),
						 Vector3(tw, 0.55, 0.22), COL_JUMP, 2.5)

			"slide":
				# High bar — duck under it
				_add_box(_gate_root, Vector3(0.0, 1.62, gz),
						 Vector3(tw, 0.40, 0.22), COL_SLIDE, 2.5)

			"wall_left", "wall_right":
				# Side plate
				var wx : float = lane_xs[0] - lw if action == "wall_left" else lane_xs[2] + lw
				_add_box(_gate_root, Vector3(wx, 1.4, gz),
						 Vector3(0.30, 2.0, 0.80), COL_WALL, 3.0)

			_:   # "left" / "right" — lane gate
				# Blocker panels on non-safe lanes + bright arch on safe lane
				for ln in range(3):
					var lx : float = lane_xs[ln]
					if ln == post_lane:
						# Safe lane — open arch outline
						_add_box(_gate_root, Vector3(lx, 0.06, gz),
								 Vector3(lw - 0.15, 0.10, 0.12), COL_LANE_SAFE, 3.0)
						_add_box(_gate_root, Vector3(lx, 2.55, gz),
								 Vector3(lw - 0.15, 0.10, 0.12), COL_LANE_SAFE, 3.0)
						_add_box(_gate_root, Vector3(lx - lw * 0.47, 1.3, gz),
								 Vector3(0.10, 2.5, 0.12), COL_LANE_SAFE, 3.0)
						_add_box(_gate_root, Vector3(lx + lw * 0.47, 1.3, gz),
								 Vector3(0.10, 2.5, 0.12), COL_LANE_SAFE, 3.0)
					else:
						# Blocked lane — solid panel
						_add_box(_gate_root, Vector3(lx, 1.3, gz),
								 Vector3(lw - 0.15, 2.5, 0.18), COL_LANE_BLOCK, 2.0)

# ── helpers ────────────────────────────────────────────────────────────────────

func _add_box(parent: Node3D, pos: Vector3, size: Vector3, col: Color, glow: float) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat  := StandardMaterial3D.new()
	mat.albedo_color               = col.darkened(0.30)
	mat.emission_enabled           = true
	mat.emission                   = col
	mat.emission_energy_multiplier = glow
	var mi := MeshInstance3D.new()
	mi.mesh              = mesh
	mi.material_override = mat
	mi.position          = pos
	parent.add_child(mi)
