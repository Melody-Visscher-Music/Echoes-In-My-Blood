extends Node

## TEMPORARY testing console. Remove before release:
##   1. delete this file, scripts/dev/AutoPilot.gd and their .uid files
##   2. drop the DevTools line from [autoload] in project.godot
##   3. grep the project for "DEVTOOLS" and delete each tagged hook
##
## Open it from the main menu with Ctrl+Shift+Alt+O+P (hold O and P together).
## Settings last for the session only — nothing is written to the save.

## Health never drops, falls put him back on the track.
var no_death: bool = false
## The game plays itself: lanes, jumps, slides, wall jumps, the charge tunnel.
## Skill is autoplay_skill. Does NOT turn on no_death by itself.
var autoplay: bool = false
## The whole song is one electric zone — for working on the zone's looks.
var all_electric: bool = false
## Hides the HUD during play (it comes back for pause and the results screen).
var hide_hud: bool = false
## Small readout in the corner: fps, song time, zone state, hits/misses.
var overlay: bool = false
## Mutes the Music bus — for listening to the SFX on their own.
var mute_music: bool = false
## Always put a wall-jump climb in the song, if it has a phrase that can hold
## one (slow songs and songs with no fitting phrase still get none).
var force_wall_jump: bool = false

## Whether a run played with any gameplay-changing dev option (no death,
## autoplay, whole song electric) may write its score to the save. Off by
## default so testing never overwrites a real high score.
var save_dev_scores: bool = false

## How well autoplay plays. 0 = God (perfect) ... 4 = Noob. See AutoPilot.
var autoplay_skill: int = 0
const SKILL_NAMES: PackedStringArray = ["God (perfect)", "Pro", "Average", "Beginner", "Noob"]


## True when this run's score is allowed into the save.
## Ticked = always saves, whatever else is on (autoplay, no death, anything).
## Unticked = only runs with no gameplay-changing dev option save.
func may_save_score() -> bool:
	if save_dev_scores:
		return true
	var assisted: bool = no_death or autoplay or all_electric or force_wall_jump
	return not assisted

var _section: Node = null
var _console: CanvasLayer = null
var _overlay_layer: CanvasLayer = null
var _overlay_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ── Hotkey ───────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.is_echo():
		return
	if _console != null and k.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_console()
		return
	if k.physical_keycode != KEY_O and k.physical_keycode != KEY_P:
		return
	if not (k.ctrl_pressed and k.shift_pressed and k.alt_pressed):
		return
	if not (Input.is_physical_key_pressed(KEY_O) and Input.is_physical_key_pressed(KEY_P)):
		return
	# Main menu only.
	var scene: Node = get_tree().current_scene
	if scene == null or scene.get_script() == null \
			or (scene.get_script() as Script).resource_path != "res://scenes/Main.gd":
		return
	get_viewport().set_input_as_handled()
	if _console == null:
		open_console()
	else:
		close_console()


# ── Console ──────────────────────────────────────────────────────────────────

func open_console() -> void:
	if _console != null:
		return
	_console = CanvasLayer.new()
	_console.layer = 120
	add_child(_console)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_console.add_child(dim)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.09, 0.96)
	sb.border_color = Color(1.0, 0.75, 0.2)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(560, 0)
	_console.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "TESTING CONSOLE  (temporary)"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
	box.add_child(title)

	var sub := Label.new()
	sub.text = "Session only. Esc or Ctrl+Shift+Alt+O+P to close."
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	box.add_child(sub)
	box.add_child(HSeparator.new())

	var first: CheckBox = _toggle(box, "no_death", "No death",
		"Health never drops; a fall puts him back on the track.")
	_toggle(box, "autoplay", "Autoplay",
		"The game plays itself. Tick No death too if the run must reach the end.")
	var skill_row := HBoxContainer.new()
	skill_row.add_theme_constant_override("separation", 12)
	box.add_child(skill_row)
	var skill_lbl := Label.new()
	skill_lbl.text = "      Autoplay skill"
	skill_lbl.add_theme_font_size_override("font_size", 18)
	skill_row.add_child(skill_lbl)
	var skill := OptionButton.new()
	skill.add_theme_font_size_override("font_size", 18)
	for n: String in SKILL_NAMES:
		skill.add_item(n)
	skill.select(autoplay_skill)
	skill.item_selected.connect(func(idx: int) -> void: autoplay_skill = idx)
	skill_row.add_child(skill)
	_toggle(box, "all_electric", "Whole song electric",
		"Every song is one long electric zone.")
	_toggle(box, "force_wall_jump", "Force a wall jump",
		"Every song gets a wall-jump climb, if its tempo and phrases allow one.")
	_toggle(box, "hide_hud", "Hide HUD",
		"HUD hidden while playing; still shows on pause and results.")
	_toggle(box, "overlay", "Debug overlay",
		"FPS, song time, zone state and hit counts in the corner.")
	_toggle(box, "mute_music", "Mute music",
		"Silences the Music bus so only the SFX play.")
	_toggle(box, "save_dev_scores", "Save scores from dev runs",
		"On: every run saves, autoplay and no death included. Off: dev-assisted runs never save.")

	box.add_child(HSeparator.new())
	var close := Button.new()
	close.text = "CLOSE"
	close.add_theme_font_size_override("font_size", 18)
	close.pressed.connect(close_console)
	box.add_child(close)
	first.grab_focus.call_deferred()


func close_console() -> void:
	if _console != null:
		_console.queue_free()
		_console = null


func _toggle(parent: Node, prop: String, label: String, hint: String) -> CheckBox:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	parent.add_child(row)
	var cb := CheckBox.new()
	cb.text = label
	cb.button_pressed = bool(get(prop))
	cb.add_theme_font_size_override("font_size", 20)
	cb.toggled.connect(func(on: bool) -> void:
		set(prop, on)
		if prop == "mute_music":
			_apply_mute())
	row.add_child(cb)
	var h := Label.new()
	h.text = "      " + hint
	h.add_theme_font_size_override("font_size", 14)
	h.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
	row.add_child(h)
	return cb


func _apply_mute() -> void:
	var bus: int = AudioServer.get_bus_index("Music")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, mute_music)


# ── In-game ──────────────────────────────────────────────────────────────────

## Called by the runner section first thing in _ready (DEVTOOLS hook there).
func attach(section: Node) -> void:
	_section = section
	if no_death:
		section.set("dev_no_death", true)
	if autoplay:
		var pilot: Node = load("res://scripts/dev/AutoPilot.gd").new()
		pilot.set("section", section)
		section.add_child(pilot)
	if mute_music:
		_apply_mute()


func _process(_delta: float) -> void:
	var s: Node = _section if _section != null and is_instance_valid(_section) else null
	if s == null:
		_section = null
		if _overlay_layer != null:
			_overlay_layer.visible = false
		return

	if hide_hud:
		var hud: CanvasLayer = s.get("_hud") as CanvasLayer
		if hud != null:
			var show: bool = bool(s.get("_paused")) or bool(s.get("_song_finish_pending")) \
				or not bool(s.get("_level_started"))
			hud.visible = show

	if not overlay:
		if _overlay_layer != null:
			_overlay_layer.visible = false
		return
	if _overlay_layer == null:
		_overlay_layer = CanvasLayer.new()
		_overlay_layer.layer = 110
		add_child(_overlay_layer)
		_overlay_label = Label.new()
		# Bottom-left, clear of the HP bar (top-left) and score (top-right).
		_overlay_label.anchor_top = 1.0
		_overlay_label.anchor_bottom = 1.0
		_overlay_label.offset_left = 18
		_overlay_label.offset_top = -130
		_overlay_label.offset_bottom = -18
		_overlay_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_overlay_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_overlay_label.add_theme_font_size_override("font_size", 16)
		_overlay_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		_overlay_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_overlay_label.add_theme_constant_override("outline_size", 5)
		_overlay_layer.add_child(_overlay_label)
	_overlay_layer.visible = true
	var t: float = float(s.call("_song_time")) if s.has_method("_song_time") else 0.0
	var zone: bool = bool(s.call("_is_electric_at", t)) if s.has_method("_is_electric_at") else false
	var flags: PackedStringArray = PackedStringArray()
	if autoplay: flags.append("AUTOPLAY " + SKILL_NAMES[autoplay_skill].get_slice(" ", 0).to_upper())
	if no_death: flags.append("NO DEATH")
	if all_electric: flags.append("ALL ELECTRIC")
	_overlay_label.text = "DEV  %s\nfps %d   t %.2fs   path %.0fm\nzone %s   dark %.2f\nhits %d   misses %d   combo %d   hp %d%%" % [
		" · ".join(flags),
		Engine.get_frames_per_second(), t, float(s.get("_player_path_dist")),
		"ELECTRIC" if zone else "city", float(s.get("_elec_dark")),
		int(s.get("_gates_hit")), int(s.get("_gates_missed")), int(s.get("_combo")),
		int(float(s.get("_health_pct")) * 100.0)]
