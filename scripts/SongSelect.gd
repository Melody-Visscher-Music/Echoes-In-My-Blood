extends Control

@onready var list: ItemList         = $Layout/SongList
@onready var info: Label            = $Layout/Info
@onready var btn_tutorial: Button   = $Layout/ModeRow/BtnTutorial
@onready var btn_seeded:   Button   = $Layout/ModeRow/BtnSeeded
@onready var btn_random:   Button   = $Layout/ModeRow/BtnRandom

# Set this in the Inspector to the scene that should run the level
@export_file("*.tscn") var level_scene_path: String = "res://scenes/GameScene.tscn"

# Each entry: {"key": String, "title": String, "song_path": String}
var beatmaps: Array[Dictionary] = []
var _current_mode: String = "run_random"

func _ready() -> void:
	# Restore saved mode from Run autoload
	var saved_mode: String = str(Run.get("runner_pattern_mode")).strip_edges()
	if saved_mode != "" and saved_mode != "null" and saved_mode != "Null":
		_current_mode = saved_mode

	_ensure_menu_input_map()
	_apply_theme()
	_load_beatmaps()
	_update_mode_buttons()

	btn_tutorial.pressed.connect(func() -> void: _set_mode("tutorial_fixed"))
	btn_seeded.pressed.connect(func() -> void:   _set_mode("song_seeded"))
	btn_random.pressed.connect(func() -> void:   _set_mode("run_random"))

	list.item_activated.connect(Callable(self, "_on_item_activated"))
	list.grab_focus()

	if list.item_count > 0:
		list.select(0)
		list.ensure_current_is_visible()
		_update_info_text()
	else:
		info.text = "No beatmaps found in res://data/beatmaps"


# ── Theme ───────────────────────────────────────────────────────────────────

func _apply_theme() -> void:
	# Song list background panel
	var list_bg := StyleBoxFlat.new()
	list_bg.bg_color              = Color(0.07, 0.07, 0.11, 1.0)
	list_bg.border_width_left     = 2
	list_bg.border_width_right    = 2
	list_bg.border_width_top      = 2
	list_bg.border_width_bottom   = 2
	list_bg.border_color          = Color(0.28, 0.12, 0.48, 1.0)
	list_bg.corner_radius_top_left     = 7
	list_bg.corner_radius_top_right    = 7
	list_bg.corner_radius_bottom_left  = 7
	list_bg.corner_radius_bottom_right = 7
	list.add_theme_stylebox_override("panel", list_bg)
	list.add_theme_color_override("font_color",          Color(0.88, 0.88, 0.92, 1.0))
	list.add_theme_color_override("font_selected_color", Color(1.0, 0.40, 0.70, 1.0))
	list.add_theme_color_override("font_hovered_color",  Color(0.95, 0.65, 0.85, 1.0))

	# Selected item highlight
	var sel_box := StyleBoxFlat.new()
	sel_box.bg_color = Color(0.22, 0.08, 0.38, 1.0)
	sel_box.corner_radius_top_left     = 5
	sel_box.corner_radius_top_right    = 5
	sel_box.corner_radius_bottom_left  = 5
	sel_box.corner_radius_bottom_right = 5
	list.add_theme_stylebox_override("selected",       sel_box)
	list.add_theme_stylebox_override("selected_focus", sel_box)

	# Initial button style (will be refreshed by _update_mode_buttons)
	for btn: Button in [btn_tutorial, btn_seeded, btn_random]:
		_style_button(btn, false)


func _style_button(btn: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	if active:
		sb.bg_color     = Color(0.48, 0.10, 0.72, 1.0)
		sb.border_color = Color(0.80, 0.40, 1.00, 1.0)
	else:
		sb.bg_color     = Color(0.10, 0.08, 0.16, 1.0)
		sb.border_color = Color(0.32, 0.18, 0.52, 1.0)

	sb.border_width_left     = 2
	sb.border_width_right    = 2
	sb.border_width_top      = 2
	sb.border_width_bottom   = 2
	sb.corner_radius_top_left     = 6
	sb.corner_radius_top_right    = 6
	sb.corner_radius_bottom_left  = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left   = 20.0
	sb.content_margin_right  = 20.0
	sb.content_margin_top    = 9.0
	sb.content_margin_bottom = 9.0
	btn.add_theme_stylebox_override("normal", sb)

	var hover_sb: StyleBoxFlat = sb.duplicate() as StyleBoxFlat
	hover_sb.bg_color = sb.bg_color.lightened(0.12)
	btn.add_theme_stylebox_override("hover", hover_sb)

	var press_sb: StyleBoxFlat = sb.duplicate() as StyleBoxFlat
	press_sb.bg_color = Color(0.60, 0.16, 0.90, 1.0)
	btn.add_theme_stylebox_override("pressed", press_sb)

	# Disabled state (same as normal to avoid default gray)
	btn.add_theme_stylebox_override("disabled", sb)

	var font_col: Color = Color(1.0, 0.45, 0.72, 1.0) if active else Color(0.62, 0.52, 0.80, 1.0)
	btn.add_theme_color_override("font_color",         font_col)
	btn.add_theme_color_override("font_hover_color",   Color(1.0, 0.68, 0.88, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0, 1.0))
	btn.add_theme_font_size_override("font_size", 15)


# ── Mode management ──────────────────────────────────────────────────────────

func _set_mode(mode: String) -> void:
	_current_mode = mode
	Run.set("runner_pattern_mode", mode)
	_update_mode_buttons()
	list.grab_focus()


func _update_mode_buttons() -> void:
	_style_button(btn_tutorial, _current_mode == "tutorial_fixed")
	_style_button(btn_seeded,   _current_mode == "song_seeded")
	_style_button(btn_random,   _current_mode == "run_random")

	if list.item_count > 0:
		_update_info_text()


func _update_info_text() -> void:
	var mode_label: String
	match _current_mode:
		"tutorial_fixed": mode_label = "Tutorial  —  fixed layout, learn the mechanics"
		"song_seeded":    mode_label = "Seeded  —  same layout every run"
		"run_random":     mode_label = "Random  —  new layout every run"
		_:                mode_label = _current_mode

	info.text = "%s   |   ↑↓/D-pad choose  ·  Enter/A start  ·  LB/RB or Q/E mode  ·  Esc/B quit" % mode_label


# ── Beatmap loading ──────────────────────────────────────────────────────────

func _load_beatmaps() -> void:
	beatmaps.clear()
	list.clear()

	var dir: DirAccess = DirAccess.open("res://data/beatmaps")
	if dir == null:
		info.text = "Folder not found: res://data/beatmaps"
		return

	dir.list_dir_begin()
	var entry_name: String = dir.get_next()
	while entry_name != "":
		if not dir.current_is_dir() and entry_name.to_lower().ends_with(".json"):
			var key: String = entry_name.substr(0, entry_name.length() - 5)
			var json_path: String = "res://data/beatmaps/%s" % entry_name

			var title: String = key
			var song_path: String = ""

			var f: FileAccess = FileAccess.open(json_path, FileAccess.READ)
			if f != null:
				var txt: String = f.get_as_text()
				f.close()
				var parsed: Variant = JSON.parse_string(txt)
				if parsed is Dictionary:
					var d: Dictionary = parsed
					song_path = String(d.get("song_path", ""))
					var explicit_title: String = String(d.get("title", ""))
					if explicit_title != "":
						title = explicit_title
					else:
						var file_name: String = song_path.get_file().get_basename()
						if file_name != "":
							title = file_name

			beatmaps.append({"key": key, "title": title, "song_path": song_path})
			var hs: Dictionary = Save.get_high_score(key)
			var hs_score: int = int(hs.get("score", 0))
			var hs_combo: int = int(hs.get("combo", 0))
			var display_title: String
			if hs_score > 0:
				display_title = "%s   |   ★ %d   (x%d)" % [title, hs_score, hs_combo]
			else:
				display_title = title
			list.add_item(display_title)

		entry_name = dir.get_next()
	dir.list_dir_end()


# ── Input ────────────────────────────────────────────────────────────────────

func _on_item_activated(_index: int) -> void:
	_start_selected()

func _just_pressed(event: InputEvent, action: String) -> bool:
	return event.is_action(action) and event.is_pressed() and not event.is_echo()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.is_pressed():
		print("Joypad button: ", event.button_index, " | is ui_accept: ", event.is_action("ui_accept"))
	# ── Keyboard-only shortcuts ──────────────────────────────────────────────
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo:
		if key_event.physical_keycode == KEY_H and key_event.ctrl_pressed and key_event.alt_pressed:
			get_viewport().set_input_as_handled()
			Save.clear_all_high_scores()
			_load_beatmaps()   # refresh list to remove ★ entries
			if list.item_count > 0:
				list.select(0)
				list.ensure_current_is_visible()
			info.text = "[DEV] All high scores cleared."
			return
		match key_event.physical_keycode:
			KEY_Q:
				get_viewport().set_input_as_handled()
				_cycle_mode(-1)
				return
			KEY_W:
				get_viewport().set_input_as_handled()
				_set_mode("song_seeded")
				return
			KEY_E:
				get_viewport().set_input_as_handled()
				_cycle_mode(1)
				return

	# ── Shared actions ───────────────────────────────────────────────────────
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton):
		return

	if _just_pressed(event, "ui_accept"):
		get_viewport().set_input_as_handled()
		_start_selected()

	elif _just_pressed(event, "ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().quit()

	elif _just_pressed(event, "ui_up"):
		get_viewport().set_input_as_handled()
		_navigate_list(-1)

	elif _just_pressed(event, "ui_down"):
		get_viewport().set_input_as_handled()
		_navigate_list(1)

	elif _just_pressed(event, "menu_mode_prev"):
		get_viewport().set_input_as_handled()
		_cycle_mode(-1)

	elif _just_pressed(event, "menu_mode_next"):
		get_viewport().set_input_as_handled()
		_cycle_mode(1)


# Navigate the song list by delta (+1 / -1), keeping it clamped and in view.
func _navigate_list(delta: int) -> void:
	if list.item_count == 0:
		return
	var selected: PackedInt32Array = list.get_selected_items()
	var cur: int = selected[0] if selected.size() > 0 else 0
	var next: int = clamp(cur + delta, 0, list.item_count - 1)
	list.select(next)
	list.ensure_current_is_visible()
	_update_info_text()


# Cycle between modes in order: tutorial → seeded → random (wraps).
func _cycle_mode(delta: int) -> void:
	var modes: Array[String] = ["tutorial_fixed", "song_seeded", "run_random"]
	var idx: int = modes.find(_current_mode)
	if idx == -1:
		idx = 0
	idx = (idx + delta + modes.size()) % modes.size()
	_set_mode(modes[idx])


# Register gamepad bindings for menu-specific actions.
func _ensure_menu_input_map() -> void:
	if not InputMap.has_action("menu_mode_prev"):
		InputMap.add_action("menu_mode_prev")
	if not InputMap.has_action("menu_mode_next"):
		InputMap.add_action("menu_mode_next")

	_menu_add_joy_button("menu_mode_prev", JOY_BUTTON_LEFT_SHOULDER)
	_menu_add_joy_button("menu_mode_next", JOY_BUTTON_RIGHT_SHOULDER)


func _menu_add_joy_button(action: String, btn: JoyButton) -> void:
	for e in InputMap.action_get_events(action):
		var jb := e as InputEventJoypadButton
		if jb != null and jb.button_index == btn:
			return
	var ev := InputEventJoypadButton.new()
	ev.button_index = btn
	InputMap.action_add_event(action, ev)


func _start_selected() -> void:
	if list.item_count == 0:
		info.text = "No beatmaps to start."
		return

	var selected: PackedInt32Array = list.get_selected_items()
	if selected.size() == 0:
		info.text = "Select a song first with ↑↓."
		return

	var i: int = selected[0]
	if i < 0 or i >= beatmaps.size():
		return

	var data: Dictionary = beatmaps[i]
	var key: String = String(data.get("key", ""))
	if key == "":
		info.text = "Invalid beatmap key."
		return

	Run.current_song_key = key
	Run.set("runner_pattern_mode", _current_mode)
	Run.run_seed = 0   # clear saved seed so run_random picks a fresh map

	var title: String = String(data.get("title", key))
	info.text = "Loading: %s …" % title
	print("[SongSelect] key=", key, " mode=", _current_mode, " → ", level_scene_path)

	var err: int = get_tree().change_scene_to_file(level_scene_path)
	if err != OK:
		info.text = "Failed to load scene:\n%s\nError code: %d" % [level_scene_path, err]
		push_error("[SongSelect] change_scene_to_file failed: code=%d path=%s" % [err, level_scene_path])
	
