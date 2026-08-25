extends Control
## One-time (per warmup-version + quality-tier) shader precompilation screen.
## Warnings.tscn routes here after both content warnings; this hands off to
## Main.tscn when done — or immediately, near-instantly, if nothing needs
## rewarming since last run (see _PATH / WARMUP_VERSION below).
##
## Companion to Section_BeatRunner3d._warmup_shader_precompile(), which only
## ever covers the gates already built in the CURRENT level. This covers
## every authored piece in TrackPieceLibrary (res://assets/track) in one
## shot, before the player ever sees a level — straights, turns, rails,
## hurdles, blockers, wall-jump geometry, charge hoops, sparks, pylons,
## halos, buildings, and the player character/fur shader. Grind rail sparks
## and charge tunnel hoops are spawned dynamically mid-song by
## Section_BeatRunner3d, but they're instances of these SAME authored
## pieces, so their shaders are already compiled by the time a level
## actually spawns one.
##
## NOT covered: procedural fallback gate visuals, used only when a level
## action has no authored piece yet in TrackPieceLibrary — those still rely
## on Section_BeatRunner3d's per-level warm-up pass as a safety net.

# Bump this whenever new piece types/materials are added that should be
# rewarmed — a bumped version forces every player to redo this once more,
# even if their quality tier hasn't changed.
const WARMUP_VERSION: int = 3

const _PATH: String = "user://shader_warmup.cfg"

# Spread the compile load across frames rather than dumping it all into one —
# see feedback_max_quality_crash: a single frame doing too much GPU work at
# once is exactly what caused a real device-lost crash earlier.
const _PIECES_PER_FRAME: int = 2
const _SPACING: float        = 6.0
const _PER_ROW: int          = 10

# Canvas-item shaders behind the gameplay HUD — see _warm_ui_shaders(). The 3D
# stage below never touches these, so without warming them here they compile on
# the first frame of the first level, which is exactly the wrong moment.
const _UI_SHADERS: Array[String] = [
	"res://shaders/hud_plate.gdshader",
	"res://shaders/hud_bar.gdshader",
	"res://shaders/hud_text.gdshader",
	"res://shaders/hud_lyric.gdshader",
]

# Spatial shaders behind the gates, rails and effects. Same reasoning as above,
# but these need a mesh rather than a rect — see _warm_ui_shaders().
const _WORLD_SHADERS: Array[String] = [
	"res://shaders/world/neon_tube.gdshader",
	"res://shaders/world/neon_panel.gdshader",
	"res://shaders/world/energy_orb.gdshader",
	"res://shaders/world/fx_ring.gdshader",
]

var _bar:    ProgressBar
var _status: Label
var _stage:  Node3D


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var key: String = "%d|%s" % [WARMUP_VERSION, GraphicsQuality.tier]
	if _load_key() == key:
		_goto_main()
		return

	_build_ui()
	_build_stage()
	_run_warmup(key)


func _goto_main() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiStyle.INK_DEEP
	add_child(bg)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	# First screen on a cold launch, so it is worth looking like the game.
	var card := PlatePanel.create(34, UiStyle.VIOLET, 26.0)
	card.custom_minimum_size = Vector2(620, 0)
	centre.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.content.add_child(vb)

	var title: Label = UiStyle.label("PREPARING", UiStyle.caption(8.0), 26, Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = UiStyle.signature_color(0.1)
	vb.add_child(title)

	_status = UiStyle.label("Scanning assets…", UiStyle.body(), 14, Color(0.78, 0.72, 0.95))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_status)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value     = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 16)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.05, 0.02, 0.10, 0.9)
	track.corner_radius_top_left = 3; track.corner_radius_top_right = 3
	track.corner_radius_bottom_left = 3; track.corner_radius_bottom_right = 3
	_bar.add_theme_stylebox_override("background", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiStyle.PINK
	fill.corner_radius_top_left = 3; fill.corner_radius_top_right = 3
	fill.corner_radius_bottom_left = 3; fill.corner_radius_bottom_right = 3
	_bar.add_theme_stylebox_override("fill", fill)
	vb.add_child(_bar)

	var sub: Label = UiStyle.label(
		"ONE-TIME SETUP  \u00b7  KEEPS THE FIRST LEVEL SMOOTH",
		UiStyle.caption(2.5), 10, Color(0.55, 0.50, 0.70))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)


func _build_stage() -> void:
	_stage = Node3D.new()
	add_child(_stage)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.02, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.35, 0.28, 0.45)
	env.glow_enabled = true
	# Match the current quality tier's SSR/SSAO/SSIL/SDFGI/volumetric fog so
	# the shader permutations compiled here are the ones actually used in
	# gameplay — Section_BeatRunner3d applies these same overrides via
	# GraphicsQuality.apply_environment_overrides() on its own Environment.
	GraphicsQuality.apply_environment_overrides(env)
	we.environment = env
	_stage.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy   = 1.1
	sun.shadow_enabled  = true
	_stage.add_child(sun)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 15, 40)
	cam.rotation_degrees = Vector3(-20, 0, 0)
	cam.fov = 60.0
	cam.far = 400.0
	_stage.add_child(cam)
	cam.current = true


func _run_warmup(key: String) -> void:
	_status.text = "Scanning assets…"
	await get_tree().process_frame

	var lib := TrackPieceLibrary.new()
	lib.scan()
	var entries: Array[Dictionary] = lib.all_entries()

	var total: int = entries.size() + (1 if lib.has_character() else 0)
	if total == 0:
		lib.clear()
		_finish(key)
		return

	var done: int = 0
	var col:  int = 0
	var row:  int = 0

	for entry in entries:
		var piece: Node3D = lib.instance(entry)
		piece.position = Vector3(float(col) * _SPACING, 0.0, -float(row) * _SPACING)
		piece.process_mode = Node.PROCESS_MODE_DISABLED
		_stage.add_child(piece)
		col += 1
		if col >= _PER_ROW:
			col = 0
			row += 1

		done += 1
		_status.text = "Compiling shaders… (%d / %d)" % [done, total]
		_bar.value = float(done) / float(total)

		if done % _PIECES_PER_FRAME == 0:
			await get_tree().process_frame

	if lib.has_character():
		var ch: Node3D = lib.instance_character()
		if ch != null:
			ch.position = Vector3(float(col) * _SPACING, 0.0, -float(row) * _SPACING)
			ch.process_mode = Node.PROCESS_MODE_DISABLED
			_stage.add_child(ch)
			done += 1
			_status.text = "Compiling shaders… (%d / %d)" % [done, total]
			_bar.value = float(done) / float(total)

	lib.clear()

	await _warm_ui_shaders()

	# A few extra frames with everything now staged, so the renderer has
	# time to actually submit draw calls for all of it and the driver has
	# time to finish compiling before we tear the stage down.
	for _i in range(6):
		await get_tree().process_frame

	_finish(key)


## Stages one nearly-transparent rect per HUD shader for a couple of frames.
## The rects still get submitted as draw calls, which is what makes the driver
## compile each permutation — but at 0.4 % alpha behind the warm-up UI, nothing
## of them is visible.
func _warm_ui_shaders() -> void:
	var cl := CanvasLayer.new()
	cl.layer = -100
	add_child(cl)
	for path in _UI_SHADERS:
		var sh: Shader = load(path) as Shader
		if sh == null:
			continue
		var r := ColorRect.new()
		r.color        = Color.WHITE
		r.size         = Vector2(64, 64)
		r.modulate     = Color(1.0, 1.0, 1.0, 0.004)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = sh
		r.material = m
		cl.add_child(r)
	# Spatial shaders need real geometry in the 3D stage, not a CanvasLayer rect.
	# Tucked behind the camera's near plane and tiny, so they cost a pipeline
	# compile and nothing else.
	var world_root := Node3D.new()
	world_root.position = Vector3(0.0, -400.0, 0.0)
	_stage.add_child(world_root)
	for wpath in _WORLD_SHADERS:
		var wsh: Shader = load(wpath) as Shader
		if wsh == null:
			continue
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.2, 0.2, 0.2)
		mi.mesh = bm
		var wm := ShaderMaterial.new()
		wm.shader = wsh
		mi.material_override = wm
		world_root.add_child(mi)

	await get_tree().process_frame
	await get_tree().process_frame
	cl.queue_free()
	world_root.queue_free()


func _finish(key: String) -> void:
	_save_key(key)
	_goto_main()


func _save_key(key: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("warmup", "key", key)
	if cfg.save(_PATH) != OK:
		push_warning("[ShaderWarmup] Failed to save %s." % _PATH)


func _load_key() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_PATH) != OK:
		return ""
	return String(cfg.get_value("warmup", "key", ""))
