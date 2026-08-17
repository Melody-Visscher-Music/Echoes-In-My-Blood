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
const WARMUP_VERSION: int = 1

const _PATH: String = "user://shader_warmup.cfg"

# Spread the compile load across frames rather than dumping it all into one —
# see feedback_max_quality_crash: a single frame doing too much GPU work at
# once is exactly what caused a real device-lost crash earlier.
const _PIECES_PER_FRAME: int = 2
const _SPACING: float        = 6.0
const _PER_ROW: int          = 10

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
	bg.color = Color(0.05, 0.02, 0.09, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(480, 0)
	center.add_child(vb)

	var title := Label.new()
	title.text = "Optimizing for your system…"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.00, 0.45, 0.72, 1.0))
	vb.add_child(title)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value     = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 18)
	vb.add_child(_bar)

	_status = Label.new()
	_status.text = "Preparing…"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color(0.80, 0.70, 1.00, 0.85))
	vb.add_child(_status)

	var sub := Label.new()
	sub.text = "One-time setup — this won't run again unless graphics settings change."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65, 0.85))
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

	# A few extra frames with everything now staged, so the renderer has
	# time to actually submit draw calls for all of it and the driver has
	# time to finish compiling before we tear the stage down.
	for _i in range(6):
		await get_tree().process_frame

	_finish(key)


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
