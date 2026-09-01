extends Control

## Song select.
##
## The list used to be a Godot ItemList — one flat stylebox, one font, one line
## of text per row. No amount of theming makes that stop reading as a file
## listing, so it is a column of chamfered PlatePanel cards now, each showing
## the song's own best score and combo in the same typography the HUD uses.

# Set this in the Inspector to the scene that should run the level
@export_file("*.tscn") var level_scene_path: String = "res://scenes/GameScene.tscn"

const MODES: Array[String] = ["tutorial_fixed", "song_seeded", "run_random"]
const MODE_LABELS: Array[String] = ["TUTORIAL", "SEEDED", "RANDOM"]
const MODE_BLURBS: Array[String] = [
	"FIXED LAYOUT  ·  LEARN THE MECHANICS",
	"SAME LAYOUT EVERY RUN",
	"NEW LAYOUT EVERY RUN",
]

# Each entry: {"key": String, "title": String, "song_path": String}
var beatmaps: Array[Dictionary] = []

var _current_mode: String = "run_random"
var _sel_idx: int = 0

var _s: float = 1.0
var _list_box: VBoxContainer = null
var _scroller: ScrollContainer = null
var _cards: Array[PlatePanel] = []
var _mode_buttons: Array[PlateButton] = []
var _info: Label = null

# Left stick. The card list reads discrete key/D-pad events in _unhandled_input;
# a stick never produces those, so it is polled per frame instead.
var _stick_v := MenuNav.AxisRepeat.new()
var _stick_h := MenuNav.AxisRepeat.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var saved_mode: String = str(Run.get("runner_pattern_mode")).strip_edges()
	if saved_mode != "" and saved_mode != "null" and saved_mode != "Null":
		_current_mode = saved_mode

	_ensure_menu_input_map()
	_s = UiStyle.scale_for(get_viewport().get_visible_rect().size)
	_build_ui()
	_load_beatmaps()
	_update_mode_buttons()
	_select(0)


# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	var s: float = _s

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiStyle.INK_DEEP
	add_child(bg)

	# A soft signature-band wash so the screen is not a flat rectangle of ink.
	var wash := ColorRect.new()
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grad := Gradient.new()
	grad.set_color(0, Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.18))
	grad.set_color(1, Color(0, 0, 0, 0))
	var tex := GradientTexture2D.new()
	tex.gradient  = grad
	tex.fill      = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.32)
	tex.fill_to   = Vector2(1.05, 0.32)
	tex.width = 256; tex.height = 256
	var wash_tex := TextureRect.new()
	wash_tex.texture = tex
	wash_tex.stretch_mode = TextureRect.STRETCH_SCALE
	wash_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash_tex)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   int(120 * s))
	margin.add_theme_constant_override("margin_right",  int(120 * s))
	margin.add_theme_constant_override("margin_top",    int(44 * s))
	margin.add_theme_constant_override("margin_bottom", int(40 * s))
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(16 * s))
	margin.add_child(col)

	var title: Label = UiStyle.label("SELECT A SONG", UiStyle.caption(9.0), int(34 * s), Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = UiStyle.signature_color(0.1)
	col.add_child(title)

	var sub: Label = UiStyle.label("ECHOES IN MY BLOOD", UiStyle.caption(4.0), int(12 * s), Color.WHITE)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.self_modulate = Color(0.60, 0.54, 0.78, 0.85)
	col.add_child(sub)

	# ── Song cards ───────────────────────────────────────────────────────────
	_scroller = ScrollContainer.new()
	_scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_scroller)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Fill the scroller and centre within it, so a short list sits in the middle
	# of the screen instead of clinging to the top with a gap underneath. The
	# VBox minimum still grows with content, so a long list scrolls as normal.
	_list_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_list_box.add_theme_constant_override("separation", int(10 * s))
	_scroller.add_child(_list_box)

	# ── Mode row ─────────────────────────────────────────────────────────────
	var mode_row := HBoxContainer.new()
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_row.add_theme_constant_override("separation", int(12 * s))
	col.add_child(mode_row)

	_mode_buttons.clear()
	for i in MODES.size():
		var idx: int = i
		var btn := PlateButton.create(MODE_LABELS[i], func() -> void: _set_mode(MODES[idx]),
			int(15 * s), UiStyle.PINK)
		btn.custom_minimum_size = Vector2(200 * s, 48 * s)
		# The song list drives its own selection index, so nothing on this screen
		# may take Godot focus: one mouse click on a mode pill used to park focus
		# here and up/down stopped moving through the songs entirely.
		# Mouse still works (PlateButton keeps hover + pressed); keyboard and
		# gamepad reach the modes with left/right, Q/E or LB/RB.
		btn.focus_mode = Control.FOCUS_NONE
		mode_row.add_child(btn)
		_mode_buttons.append(btn)

	_info = UiStyle.label("", UiStyle.caption(2.0), int(11 * s), Color.WHITE)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.self_modulate = Color(0.56, 0.50, 0.72, 0.85)
	col.add_child(_info)

	# ── Back ─────────────────────────────────────────────────────────────────
	# Esc used to be the only way out of this screen, and it called quit().
	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(back_row)

	var back := PlateButton.create("↩  BACK", _go_back, int(14 * s), UiStyle.VIOLET)
	back.custom_minimum_size = Vector2(220 * s, 44 * s)
	back.focus_mode = Control.FOCUS_NONE   # clickable; Esc / B is the key+pad route
	back_row.add_child(back)


## One song card: title, plus best score and combo when the song has been played.
func _make_card(title: String, key: String) -> PlatePanel:
	var s: float = _s
	var card := PlatePanel.create(int(18 * s), UiStyle.VIOLET, 18.0 * s)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(2 * s))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.content.add_child(box)

	var name_lbl: Label = UiStyle.label(title.to_upper(), UiStyle.caption(3.5), int(20 * s), Color.WHITE)
	name_lbl.self_modulate = Color(1.00, 0.88, 1.00)
	box.add_child(name_lbl)

	var hs: Dictionary = Save.get_high_score(key)
	var hs_score: int = int(hs.get("score", 0))
	var hs_combo: int = int(hs.get("combo", 0))
	var stat_text: String
	var stat_col: Color
	if hs_score > 0:
		stat_text = "BEST  %s   ×%d" % [UiStyle.group_digits(hs_score), hs_combo]
		stat_col  = UiStyle.CYAN
	else:
		stat_text = "NOT YET PLAYED"
		stat_col  = Color(0.52, 0.47, 0.65)
	var stat_lbl: Label = UiStyle.label(stat_text, UiStyle.display(700), int(14 * s), Color.WHITE)
	stat_lbl.self_modulate = stat_col
	box.add_child(stat_lbl)

	return card


# ── Selection ────────────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if _cards.is_empty():
		return
	_sel_idx = clampi(idx, 0, _cards.size() - 1)
	for i in _cards.size():
		_cards[i].set_selected(i == _sel_idx)
	if _scroller != null:
		_scroller.ensure_control_visible(_cards[_sel_idx])
	_update_info_text()


func _navigate_list(delta: int) -> void:
	if _cards.is_empty():
		return
	_select(posmod(_sel_idx + delta, _cards.size()))


func _process(delta: float) -> void:
	var v: int = _stick_v.step(MenuNav.stick(JOY_AXIS_LEFT_Y), delta)
	if v != 0:
		_navigate_list(v)
	var h: int = _stick_h.step(MenuNav.stick(JOY_AXIS_LEFT_X), delta)
	if h != 0:
		_cycle_mode(h)


# ── Mode management ──────────────────────────────────────────────────────────

func _set_mode(mode: String) -> void:
	_current_mode = mode
	Run.set("runner_pattern_mode", mode)
	_update_mode_buttons()


func _update_mode_buttons() -> void:
	for i in _mode_buttons.size():
		var active: bool = MODES[i] == _current_mode
		_mode_buttons[i].set_accent(UiStyle.CYAN if active else UiStyle.VIOLET)
		_mode_buttons[i].set_highlight(active)
	_update_info_text()


func _update_info_text() -> void:
	if _info == null:
		return
	var idx: int = MODES.find(_current_mode)
	var blurb: String = MODE_BLURBS[idx] if idx >= 0 else _current_mode
	_info.text = "%s     ↑↓ CHOOSE  ·  ENTER / A START  ·  ←→ / LB-RB / Q-E MODE  ·  ESC / B BACK" % blurb


func _cycle_mode(delta: int) -> void:
	var idx: int = MODES.find(_current_mode)
	if idx == -1:
		idx = 0
	_set_mode(MODES[posmod(idx + delta, MODES.size())])


# ── Beatmap loading ──────────────────────────────────────────────────────────

func _load_beatmaps() -> void:
	beatmaps.clear()
	for c in _list_box.get_children():
		c.queue_free()
	_cards.clear()

	var dir: DirAccess = DirAccess.open("res://data/beatmaps")
	if dir == null:
		_info.text = "FOLDER NOT FOUND: res://data/beatmaps"
		return

	var pending: Array[Dictionary] = []

	dir.list_dir_begin()
	var entry_name: String = dir.get_next()
	while entry_name != "":
		if not dir.current_is_dir() and entry_name.to_lower().ends_with(".json"):
			var key: String = entry_name.substr(0, entry_name.length() - 5)
			var json_path: String = "res://data/beatmaps/%s" % entry_name

			# Title is ALWAYS the beatmap key with underscores turned back into
			# spaces. It used to fall back to the audio filename, which put
			# "This Is Me v2 (for shits and giggles)" in front of players, and it
			# disagreed with the in-level countdown (which already derived its
			# title from the key) — so the same song had two different names.
			var title: String = key.replace("_", " ")
			var song_path: String = ""

			var order: int = 0
			var f: FileAccess = FileAccess.open(json_path, FileAccess.READ)
			if f != null:
				var txt: String = f.get_as_text()
				f.close()
				var parsed: Variant = JSON.parse_string(txt)
				if parsed is Dictionary:
					song_path = String((parsed as Dictionary).get("song_path", ""))
					order = int((parsed as Dictionary).get("song_order", 0))

			pending.append({"key": key, "title": title, "song_path": song_path,
				"song_order": order})

		entry_name = dir.get_next()
	dir.list_dir_end()

	# Sort before building anything: numbered songs first in their given order,
	# then anything unnumbered, alphabetically. Cards used to be built inside
	# the scan loop, so the running order was whatever the directory happened to
	# return -- effectively alphabetical, with no way to author a play order.
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var oa: int = int(a.get("song_order", 0))
		var ob: int = int(b.get("song_order", 0))
		var ka: int = oa if oa > 0 else 0x7FFFFFFF
		var kb: int = ob if ob > 0 else 0x7FFFFFFF
		if ka != kb:
			return ka < kb
		return String(a.get("title", "")).naturalnocasecmp_to(String(b.get("title", ""))) < 0)

	for entry in pending:
		var key: String = String(entry.get("key", ""))
		var title: String = String(entry.get("title", ""))
		beatmaps.append(entry)

		var card := _make_card(title, key)
		_list_box.add_child(card)
		# Cards are clickable as well as keyboard-navigable; PlatePanel
		# ignores the mouse by default so this has to be re-enabled.
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx: int = _cards.size()
		# Hovering moves the selection so the mouse and the keyboard agree on
		# what "selected" means — otherwise the lit card and the card you are
		# about to click could be two different songs.
		card.mouse_entered.connect(func() -> void: _select(idx))
		card.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				if idx == _sel_idx:
					_start_selected()
				else:
					_select(idx))
		_cards.append(card)

	if _cards.is_empty():
		_info.text = "NO BEATMAPS FOUND IN res://data/beatmaps"


# ── Input ────────────────────────────────────────────────────────────────────

func _just_pressed(event: InputEvent, action: String) -> bool:
	return event.is_action(action) and event.is_pressed() and not event.is_echo()


func _unhandled_input(event: InputEvent) -> void:
	# ── Keyboard-only shortcuts ──────────────────────────────────────────────
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo:
		if key_event.physical_keycode == KEY_H and key_event.ctrl_pressed and key_event.alt_pressed:
			get_viewport().set_input_as_handled()
			Save.clear_all_high_scores()
			_load_beatmaps()   # rebuild cards so the best-score lines clear
			_select(0)
			_info.text = "[DEV] ALL HIGH SCORES CLEARED."
			return
		match key_event.physical_keycode:
			KEY_Q:
				get_viewport().set_input_as_handled()
				_cycle_mode(-1)
				return
			KEY_E:
				get_viewport().set_input_as_handled()
				_cycle_mode(1)
				return

	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton):
		return

	if _just_pressed(event, "ui_accept"):
		get_viewport().set_input_as_handled()
		_start_selected()

	elif _just_pressed(event, "ui_cancel"):
		# Back to the main menu. This used to call get_tree().quit(), so pressing
		# Esc on the song list killed the game outright — every other screen
		# treats Esc as "back".
		get_viewport().set_input_as_handled()
		_go_back()

	elif _just_pressed(event, "ui_up"):
		get_viewport().set_input_as_handled()
		_navigate_list(-1)

	elif _just_pressed(event, "ui_down"):
		get_viewport().set_input_as_handled()
		_navigate_list(1)

	elif _just_pressed(event, "ui_left") or _just_pressed(event, "menu_mode_prev"):
		get_viewport().set_input_as_handled()
		_cycle_mode(-1)

	elif _just_pressed(event, "ui_right") or _just_pressed(event, "menu_mode_next"):
		get_viewport().set_input_as_handled()
		_cycle_mode(1)


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


# ── Transitions ──────────────────────────────────────────────────────────────

## Leave without starting anything. Also clears the run state, so whatever is
## picked next starts from a clean slate rather than inheriting the seed and
## life count of a song the player backed out of.
func _go_back() -> void:
	Run.run_seed   = 0
	Run.song_lives = GameConfig.lives_per_song
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _start_selected() -> void:
	if beatmaps.is_empty():
		_info.text = "NO BEATMAPS TO START."
		return
	if _sel_idx < 0 or _sel_idx >= beatmaps.size():
		return

	var data: Dictionary = beatmaps[_sel_idx]
	var key: String = String(data.get("key", ""))
	if key == "":
		_info.text = "INVALID BEATMAP KEY."
		return

	Run.current_song_key = key
	Run.set("runner_pattern_mode", _current_mode)
	Run.run_seed = 0   # clear saved seed so run_random picks a fresh map

	var title: String = String(data.get("title", key))
	_info.text = "LOADING: %s …" % title.to_upper()
	print("[SongSelect] key=", key, " mode=", _current_mode, " → ", level_scene_path)

	var err: int = get_tree().change_scene_to_file(level_scene_path)
	if err != OK:
		_info.text = "FAILED TO LOAD SCENE: %s (code %d)" % [level_scene_path, err]
		push_error("[SongSelect] change_scene_to_file failed: code=%d path=%s" % [err, level_scene_path])
