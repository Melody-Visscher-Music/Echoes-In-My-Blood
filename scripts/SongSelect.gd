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

	var prac := PlateButton.create("◎  PRACTICE", _open_practice, int(14 * s), UiStyle.CYAN)
	prac.custom_minimum_size = Vector2(220 * s, 44 * s)
	prac.focus_mode = Control.FOCUS_NONE
	back_row.add_child(prac)
	back_row.add_theme_constant_override("separation", int(14 * s))

	var back := PlateButton.create("↩  BACK", _go_back, int(14 * s), UiStyle.VIOLET)
	back.custom_minimum_size = Vector2(220 * s, 44 * s)
	back.focus_mode = Control.FOCUS_NONE   # clickable; Esc / B is the key+pad route
	back_row.add_child(back)


## One song card: title, plus best score and combo when the song has been played.
func _make_card(title: String, key: String, bpm: float = 0.0) -> PlatePanel:
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
	# Stat line and BPM share a row: the tempo is reference information, not a
	# score, so it sits to the right in a muted colour and the card keeps its
	# height whether or not a chart has a BPM recorded.
	var stat_row := HBoxContainer.new()
	stat_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(stat_row)

	var stat_lbl: Label = UiStyle.label(stat_text, UiStyle.display(700), int(14 * s), Color.WHITE)
	stat_lbl.self_modulate = stat_col
	stat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stat_row.add_child(stat_lbl)

	if bpm > 0.0:
		var bpm_lbl: Label = UiStyle.label("%d BPM" % roundi(bpm), UiStyle.display(700), int(14 * s), Color.WHITE)
		bpm_lbl.self_modulate = Color(0.62, 0.55, 0.78)
		bpm_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stat_row.add_child(bpm_lbl)

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
	if _prac_open:
		var pv: int = _stick_v.step(MenuNav.stick(JOY_AXIS_LEFT_Y), delta)
		if pv != 0:
			_prac_row = posmod(_prac_row + pv, 4)
			_prac_refresh()
		var ph: int = _stick_h.step(MenuNav.stick(JOY_AXIS_LEFT_X), delta)
		if ph != 0:
			_prac_change(ph)
		return
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
	_info.text = "%s     ↑↓ CHOOSE  ·  ENTER / A START  ·  P / Y PRACTICE  ·  ←→ / LB-RB / Q-E MODE  ·  ESC / B BACK" % blurb


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
			var bpm: float = 0.0
			var f: FileAccess = FileAccess.open(json_path, FileAccess.READ)
			if f != null:
				var txt: String = f.get_as_text()
				f.close()
				var parsed: Variant = JSON.parse_string(txt)
				if parsed is Dictionary:
					song_path = String((parsed as Dictionary).get("song_path", ""))
					order = int((parsed as Dictionary).get("song_order", 0))
					var bv: Variant = (parsed as Dictionary).get("bpm", 0)
					if bv is float or bv is int:
						bpm = float(bv)

			pending.append({"key": key, "title": title, "song_path": song_path,
				"song_order": order, "bpm": bpm})

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

		var card := _make_card(title, key, float(entry.get("bpm", 0.0)))
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
	if _practice_input(event):
		return
	# P / gamepad Y: practice the selected song.
	var pk := event as InputEventKey
	var pj := event as InputEventJoypadButton
	if (pk != null and pk.pressed and not pk.echo and pk.physical_keycode == KEY_P) 			or (pj != null and pj.pressed and pj.button_index == JOY_BUTTON_Y):
		get_viewport().set_input_as_handled()
		_open_practice()
		return
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
	Run.practice = {}

	var title: String = String(data.get("title", key))
	_info.text = "LOADING: %s …" % title.to_upper()
	print("[SongSelect] key=", key, " mode=", _current_mode, " → ", level_scene_path)

	var err: int = get_tree().change_scene_to_file(level_scene_path)
	if err != OK:
		_info.text = "FAILED TO LOAD SCENE: %s (code %d)" % [level_scene_path, err]
		push_error("[SongSelect] change_scene_to_file failed: code=%d path=%s" % [err, level_scene_path])


# ── Practice ─────────────────────────────────────────────────────────────────
# P / Y on a song opens this panel: pick a part of the song, a speed and
# whether it loops. Each feature (grind rail, charge tunnel, smash gate,
# electric zone) is offered as its own part with a few seconds of run-up, and
# the whole song is also split into 32-beat parts. Wall-jump climbs are placed
# when the level is built, so they cannot be listed here — a part that would
# start inside one starts just before it instead (see the level's
# _practice_setup()). Practice never saves a score.

const PRAC_SPEEDS: Array[float] = [1.0, 0.9, 0.8, 0.75, 0.6, 0.5]
var _prac_open: bool = false
var _prac_root: Control = null
var _prac_parts: Array[Dictionary] = []    # {name, t0, t1, tags}
var _prac_part: int = 0
var _prac_speed_i: int = 0
var _prac_loop: bool = true
var _prac_row: int = 0                     # 0 part, 1 speed, 2 loop, 3 start
var _prac_rows: Array[PlatePanel] = []
var _prac_vals: Array[Label] = []
var _prac_sub: Label = null


static func _mmss(t: float) -> String:
	var ti: int = maxi(0, int(t))
	return "%d:%02d" % [ti / 60, ti % 60]


func _practice_parts(key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var f: FileAccess = FileAccess.open("res://data/beatmaps/%s.json" % key, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return out
	var d: Dictionary = parsed
	var length: float = 0.0
	var sp: String = String(d.get("song_path", ""))
	if sp != "" and ResourceLoader.exists(sp):
		var st: AudioStream = load(sp) as AudioStream
		if st != null:
			length = st.get_length()
	var evs: Array = d.get("events", []) as Array
	for e in evs:
		if e is Dictionary:
			length = maxf(length, float((e as Dictionary).get("t", 0.0)) + 2.0)
	if length <= 1.0:
		return out
	var feats: Array[Dictionary] = []
	for seg in (d.get("rap_segments", []) as Array):
		if seg is Dictionary:
			feats.append({"name": "GRIND RAIL", "tag": "GRIND",
				"t0": float(seg.get("start_t", 0.0)) - 3.0, "t1": float(seg.get("end_t", 0.0)) + 3.0})
	for seg in (d.get("drop_buildups", []) as Array):
		if seg is Dictionary:
			feats.append({"name": "CHARGE TUNNEL", "tag": "CHARGE",
				"t0": float(seg.get("start_t", 0.0)) - 4.5, "t1": float(seg.get("end_t", 0.0)) + 4.0})
	for e in evs:
		if e is Dictionary and String(e.get("type", "")) == "hold" \
				and String(e.get("capture_pass", "")) == "beats" and float(e.get("dur", 0.0)) >= 0.35:
			var t: float = float(e.get("t", 0.0))
			feats.append({"name": "SMASH GATE", "tag": "SMASH",
				"t0": t - 4.0, "t1": t + float(e.get("dur", 0.0)) + 4.0})
	for z in (d.get("electric_zones", []) as Array):
		if z is Dictionary:
			feats.append({"name": "ELECTRIC ZONE", "tag": "DARK",
				"t0": float(z.get("start_t", 0.0)) - 3.0, "t1": float(z.get("end_t", 0.0)) + 2.0})
	for ft in feats:
		ft["t0"] = clampf(float(ft["t0"]), 0.0, length)
		ft["t1"] = clampf(float(ft["t1"]), float(ft["t0"]) + 2.0, length)
		out.append({"name": "%s  ·  %s – %s" % [ft["name"], _mmss(ft["t0"]), _mmss(ft["t1"])],
			"t0": ft["t0"], "t1": ft["t1"], "tags": ""})
	var bpm: float = float(d.get("bpm", 0.0))
	var chunk: float = 32.0 * 60.0 / bpm if bpm > 0.0 else 16.0
	var n: int = int(ceil(length / chunk))
	for k in n:
		var a: float = float(k) * chunk
		var b: float = minf(length, a + chunk)
		if b - a < 3.0:
			continue
		var tags: PackedStringArray = []
		for ft in feats:
			if float(ft["t1"]) > a and float(ft["t0"]) < b and not tags.has(String(ft["tag"])):
				tags.append(String(ft["tag"]))
		out.append({"name": "PART %d  ·  %s – %s" % [k + 1, _mmss(a), _mmss(b)],
			"t0": a, "t1": b, "tags": " · ".join(tags)})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["t0"]) < float(y["t0"]))
	return out


func _open_practice() -> void:
	if beatmaps.is_empty() or _prac_open:
		return
	var key: String = String(beatmaps[_sel_idx].get("key", ""))
	_prac_parts = _practice_parts(key)
	if _prac_parts.is_empty():
		_info.text = "NO PARTS FOUND FOR THIS SONG."
		return
	_prac_part = clampi(_prac_part, 0, _prac_parts.size() - 1)
	_prac_row = 0
	var s: float = _s
	_prac_root = Control.new()
	_prac_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_prac_root)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.01, 0.005, 0.03, 0.82)
	_prac_root.add_child(dim)
	var card := PlatePanel.create(int(28 * s), UiStyle.CYAN, 26.0 * s)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(760 * s, 0)
	_prac_root.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(10 * s))
	card.content.add_child(box)
	var title: Label = UiStyle.label("PRACTICE", UiStyle.caption(8.0), int(28 * s), Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = UiStyle.CYAN
	box.add_child(title)
	var song: Label = UiStyle.label(String(beatmaps[_sel_idx].get("title", key)).to_upper(),
		UiStyle.caption(3.0), int(13 * s), Color.WHITE)
	song.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	song.self_modulate = Color(0.70, 0.62, 0.90)
	box.add_child(song)
	_prac_rows.clear()
	_prac_vals.clear()
	for i in 4:
		var row := PlatePanel.create(int(12 * s), UiStyle.VIOLET, 14.0 * s)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var hb := HBoxContainer.new()
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.content.add_child(hb)
		var key_lbl: Label = UiStyle.label(["PART", "SPEED", "LOOP", ""][i], UiStyle.caption(3.0),
			int(13 * s), Color.WHITE)
		key_lbl.custom_minimum_size = Vector2(110 * s, 0)
		key_lbl.self_modulate = Color(0.62, 0.55, 0.80)
		hb.add_child(key_lbl)
		var val: Label = UiStyle.label("", UiStyle.display(800), int(17 * s), Color.WHITE)
		val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hb.add_child(val)
		box.add_child(row)
		var idx: int = i
		row.mouse_entered.connect(func() -> void:
			_prac_row = idx
			_prac_refresh())
		row.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed:
				if mb.button_index == MOUSE_BUTTON_LEFT:
					if idx == 3:
						_start_practice()
					else:
						_prac_change(1)
				elif mb.button_index == MOUSE_BUTTON_RIGHT:
					_prac_change(-1))
		_prac_rows.append(row)
		_prac_vals.append(val)
		if i == 0:
			_prac_sub = UiStyle.label("", UiStyle.caption(2.0), int(11 * s), Color.WHITE)
			_prac_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_prac_sub.self_modulate = Color(0.55, 0.95, 1.0, 0.85)
			box.add_child(_prac_sub)
	var hint: Label = UiStyle.label(
		"↑↓ CHOOSE  ·  ←→ CHANGE  ·  ENTER / A START  ·  ESC / B CLOSE\nNO SCORE IS SAVED IN PRACTICE  ·  YOU CANNOT FAIL",
		UiStyle.caption(2.0), int(11 * s), Color.WHITE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.self_modulate = Color(0.55, 0.50, 0.70, 0.80)
	box.add_child(hint)
	_prac_open = true
	_prac_refresh()


func _prac_refresh() -> void:
	if _prac_vals.size() < 4:
		return
	var part: Dictionary = _prac_parts[_prac_part]
	_prac_vals[0].text = "◀  %s  ▶" % String(part["name"])
	_prac_vals[1].text = "◀  %d%%  ▶" % roundi(PRAC_SPEEDS[_prac_speed_i] * 100.0)
	_prac_vals[2].text = "◀  %s  ▶" % ("ON" if _prac_loop else "OFF")
	_prac_vals[3].text = "▶  START PRACTICE"
	var tags: String = String(part.get("tags", ""))
	_prac_sub.text = "%d / %d%s" % [_prac_part + 1, _prac_parts.size(),
		("   ·   " + tags) if tags != "" else ""]
	for i in _prac_rows.size():
		_prac_rows[i].set_selected(i == _prac_row)


func _prac_change(dir: int) -> void:
	match _prac_row:
		0: _prac_part = posmod(_prac_part + dir, _prac_parts.size())
		1: _prac_speed_i = posmod(_prac_speed_i - dir, PRAC_SPEEDS.size())
		2: _prac_loop = not _prac_loop
	_prac_refresh()


func _close_practice() -> void:
	if _prac_root != null:
		_prac_root.queue_free()
	_prac_root = null
	_prac_open = false
	_prac_rows.clear()
	_prac_vals.clear()


func _start_practice() -> void:
	var data: Dictionary = beatmaps[_sel_idx]
	var key: String = String(data.get("key", ""))
	var part: Dictionary = _prac_parts[_prac_part]
	Run.current_song_key = key
	Run.set("runner_pattern_mode", _current_mode)
	Run.run_seed = 0   # a fresh layout now; loops then keep it
	Run.practice = {"song": key, "t0": float(part["t0"]), "t1": float(part["t1"]),
		"speed": PRAC_SPEEDS[_prac_speed_i], "loop": _prac_loop, "label": String(part["name"])}
	_info.text = "LOADING PRACTICE …"
	get_tree().change_scene_to_file(level_scene_path)


## Input while the practice panel is up. Returns true when it used the event.
func _practice_input(event: InputEvent) -> bool:
	if not _prac_open:
		return false
	if not (event is InputEventKey or event is InputEventJoypadButton):
		return true
	if _just_pressed(event, "ui_cancel"):
		_close_practice()
	elif _just_pressed(event, "ui_accept"):
		_start_practice()
	elif _just_pressed(event, "ui_up"):
		_prac_row = posmod(_prac_row - 1, 4)
		_prac_refresh()
	elif _just_pressed(event, "ui_down"):
		_prac_row = posmod(_prac_row + 1, 4)
		_prac_refresh()
	elif _just_pressed(event, "ui_left"):
		_prac_change(-1)
	elif _just_pressed(event, "ui_right"):
		_prac_change(1)
	get_viewport().set_input_as_handled()
	return true
