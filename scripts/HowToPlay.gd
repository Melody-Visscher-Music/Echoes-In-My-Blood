extends Control

var _kb_col:   Control  # keyboard VBox (shown when keyboard active)
var _gp_col:   Control  # gamepad VBox  (shown when gamepad active)
var _hint_lbl: Label    # small note telling the player which mode is active

var _is_gamepad: bool = false

# ── Scroll-gated confirm ─────────────────────────────────────────────────────
var _scroller:   ScrollContainer  # the page's scroll view
var _confirm_cb: CheckBox         # "I've read this" — locked until scrolled to bottom
var _play_btn:   Button           # Continue/SELECT SONG — locked until checkbox is checked


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_detect_initial_device()
	_apply_device()
	get_viewport().size_changed.connect(_update_scroll_gate)
	# Layout/scroll extents aren't final until after the first frame, so defer
	# the initial check (also covers the case where content fits without any
	# scrolling being needed at all — the gate opens immediately then).
	call_deferred("_update_scroll_gate")


# Switch column when the player uses a different input device.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if not _is_gamepad:
			_is_gamepad = true
			_apply_device()
	elif event is InputEventKey or event is InputEventMouseButton:
		if _is_gamepad:
			_is_gamepad = false
			_apply_device()


func _detect_initial_device() -> void:
	_is_gamepad = Input.get_connected_joypads().size() > 0


func _apply_device() -> void:
	if _kb_col == null or _gp_col == null:
		return
	_kb_col.visible = not _is_gamepad
	_gp_col.visible = _is_gamepad
	if _hint_lbl != null:
		if _is_gamepad:
			_hint_lbl.text = "🎮  Showing gamepad controls  ·  press a key to switch"
		else:
			_hint_lbl.text = "⌨  Showing keyboard controls  ·  press a button to switch"


# ── Responsive helpers ─────────────────────────────────────────────────────────

## UI scale factor relative to 1920×1080 reference.
func _ui_s() -> float:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return clampf(minf(vp.x / 1920.0, vp.y / 1080.0), 0.5, 2.0)


## Panel card width — 55 % of viewport, clamped to a scaled range.
func _panel_w() -> float:
	var s  := _ui_s()
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return clampf(vp.x * 0.55, 560.0 * s, 1120.0 * s)


func _build_ui() -> void:
	var s := _ui_s()

	# ── Background ────────────────────────────────────────────────────────────
	var bg := TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.texture      = load("res://Graphics/ChatGPT Image Apr 17, 2026, 07_26_59 PM.png")
	bg.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	add_child(bg)

	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color        = Color(0.02, 0.01, 0.08, 0.70)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	# ── Scrollable centred card ───────────────────────────────────────────────
	# ScrollContainer fills the screen; CenterContainer inside is at least
	# viewport-height tall so the card sits centred — grows and scrolls if
	# the content is taller than the screen.
	var scroller := ScrollContainer.new()
	scroller.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroller)

	var vp_h := get_viewport().get_visible_rect().size.y if get_viewport() else 1080.0
	var wrapper := CenterContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	wrapper.custom_minimum_size   = Vector2(0.0, vp_h)
	scroller.add_child(wrapper)

	_scroller = scroller
	scroller.get_v_scroll_bar().changed.connect(_update_scroll_gate)
	scroller.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _update_scroll_gate())

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	panel.add_theme_stylebox_override("panel", _card_style())
	wrapper.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   int(52 * s))
	margin.add_theme_constant_override("margin_right",  int(52 * s))
	margin.add_theme_constant_override("margin_top",    int(40 * s))
	margin.add_theme_constant_override("margin_bottom", int(40 * s))
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(18 * s))
	margin.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var title := Label.new()
	title.text = "HOW TO PLAY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(34 * s))
	title.add_theme_color_override("font_color", Color(1.0, 0.4, 0.7, 1.0))
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# ── About ─────────────────────────────────────────────────────────────────
	_section(vbox, "THE GAME", s)
	var about := Label.new()
	about.text = (
		"Echoes in my Blood is a rhythm runner. You auto-run through procedurally "
		+ "generated tracks while gates spawn in time with the music. "
		+ "Hit each gate correctly — in the left, middle or right lane, airborne for jumps, "
		+ "crouching for slides — to build your combo and keep your health up. "
		+ "if you encounter wall jumps and you succeed at them you get a X2 bonus of your score. "
		+ "Wall jumps wont always spawn in a level. "
		+ "Drain your health or miss too many and it's game over. "
		+ "Each song gives you 3 attempts. After three wipes a new seed is rolled "
		+ "and you can try a fresh layout."
	)
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.add_theme_font_size_override("font_size", int(16 * s))
	about.add_theme_color_override("font_color", Color(0.82, 0.82, 0.92, 1.0))
	vbox.add_child(about)

	# ── Controls ──────────────────────────────────────────────────────────────
	_section(vbox, "CONTROLS", s)

	_hint_lbl = Label.new()
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_lbl.add_theme_font_size_override("font_size", int(13 * s))
	_hint_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.70, 1.0))
	vbox.add_child(_hint_lbl)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", int(32 * s))
	vbox.add_child(cols)

	# Control names are read live from GameConfig — the same rebind store the
	# Options > Controls tab and actual gameplay use, so this always matches.
	_kb_col = _col(cols, "⌨  KEYBOARD", s)
	_row(_kb_col, GameConfig.key_name("runner_left"),  "Move left",          s)
	_row(_kb_col, GameConfig.key_name("runner_right"), "Move right",         s)
	_row(_kb_col, GameConfig.key_name("runner_jump"),  "Jump (jump gate)",   s)
	_row(_kb_col, GameConfig.key_name("runner_slide"), "Slide (slide gate)", s)
	_row(_kb_col, GameConfig.key_name("runner_rb"),    "Wall jump →",        s)
	_row(_kb_col, GameConfig.key_name("runner_lb"),    "Wall jump ←",        s)
	_row(_kb_col, GameConfig.key_name("runner_grind"), "Grind rail (hold)",  s)
	_row(_kb_col, "Escape", "Pause",          s)

	_gp_col = _col(cols, "🎮  GAMEPAD", s)
	_row(_gp_col, "Left Joystick ←", "Move Left",  s)
	_row(_gp_col, "Left Joystick →", "Move Right", s)
	_row(_gp_col, GameConfig.joy_button_name("runner_rb"),    "Wall jump →", s)
	_row(_gp_col, GameConfig.joy_button_name("runner_lb"),    "Wall jump ←", s)
	_row(_gp_col, GameConfig.joy_button_name("runner_jump"),  "Jump",        s)
	_row(_gp_col, GameConfig.joy_button_name("runner_slide"), "Slide",       s)
	_row(_gp_col, _grind_gp_label(),                          "Grind rail (hold)", s)
	_row(_gp_col, "Start",           "Pause",       s)

	# ── Charge Tunnel / Overdrive ────────────────────────────────────────────
	_section(vbox, "⚡  CHARGE TUNNEL  →  ×100 OVERDRIVE", s)
	var ct := VBoxContainer.new()
	ct.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(ct)
	_row(ct, "Hold " + GameConfig.key_name("runner_grind") + " / " + _grind_gp_label(),
		"Free-slide — steer with Move Left/Right to weave through the hoops", s)
	_row(ct, "Stay threaded",  "Aligned with the hoop = charge fills; clip the rim = it bleeds", s)
	_row(ct, "Let go early",   "Charge bleeds away — don't release before the drop",  s)
	_row(ct, "Release on the drop", "Pops ×100 OVERDRIVE — bigger fill = longer window", s)

	# ── Scoring ───────────────────────────────────────────────────────────────
	_section(vbox, "SCORING & HEALTH", s)

	var sc := VBoxContainer.new()
	sc.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(sc)
	_row(sc, "Gate hit",             "+500 pts × combo multiplier",              s)
	_row(sc, "Combo multiplier",     "×2 at 10 streak  ·  ×3 at 20  ·  ×4 at 30", s)
	_row(sc, "Health (starts 50 %)", "+1 % per hit    –10 % per miss    → 0 % = fail", s)
	_row(sc, "Near-miss bonus",      "+25 pts if you were close — keep trying!", s)
	_row(sc, "Letter grade",         "S / A / B / C / D / F  based on notes hit.", s)

	# ── Song Modes ────────────────────────────────────────────────────────────
	_section(vbox, "SONG MODES", s)

	var md := VBoxContainer.new()
	md.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(md)
	_row(md, "Tutorial", "Fixed hand-crafted layout — learn the mechanics",  s)
	_row(md, "Seeded",   "Same gate layout every run for a given song",      s)
	_row(md, "Random",   "Fresh layout every attempt — maximum replayability", s)

	# ── Scroll-gated confirm checkbox ────────────────────────────────────────
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var confirm_row := HBoxContainer.new()
	confirm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	confirm_row.add_theme_constant_override("separation", int(10 * s))
	vbox.add_child(confirm_row)

	_confirm_cb = CheckBox.new()
	_confirm_cb.text = "I've read through the tutorial"
	_confirm_cb.disabled = true   # unlocked once the page has been scrolled to the bottom
	_confirm_cb.add_theme_font_size_override("font_size", int(15 * s))
	_confirm_cb.toggled.connect(func(_pressed: bool) -> void: _update_continue_btn())
	confirm_row.add_child(_confirm_cb)

	# ── Button row ────────────────────────────────────────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(btn_row)

	var back_btn := Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(170 * s), int(52 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/Main.tscn"))
	btn_row.add_child(back_btn)

	var play_btn := Button.new()
	play_btn.text = "SELECT SONG →"
	play_btn.custom_minimum_size = Vector2(int(220 * s), int(52 * s))
	_style_btn(play_btn, s)
	play_btn.disabled = true   # unlocked once the confirm checkbox is checked
	play_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/SongSelect.tscn"))
	btn_row.add_child(play_btn)
	_play_btn = play_btn
	back_btn.call_deferred("grab_focus")   # play_btn starts disabled, so focus BACK instead


# ── Layout helpers ─────────────────────────────────────────────────────────────

func _card_style() -> StyleBoxFlat:
	var sf := StyleBoxFlat.new()
	sf.bg_color           = Color(0.04, 0.03, 0.12, 0.97)
	sf.border_color       = Color(0.50, 0.15, 0.75, 1.0)
	sf.border_width_left  = 2;  sf.border_width_right  = 2
	sf.border_width_top   = 2;  sf.border_width_bottom = 2
	sf.corner_radius_top_left     = 12;  sf.corner_radius_top_right    = 12
	sf.corner_radius_bottom_left  = 12;  sf.corner_radius_bottom_right = 12
	return sf


## Grind's gamepad label — left trigger is a fixed always-on default, plus
## whatever custom button (if any) the player also bound to it.
func _grind_gp_label() -> String:
	var custom: String = GameConfig.joy_button_name("runner_grind")
	return "Left Trigger" if custom == "—" else "Left Trigger / %s" % custom


func _section(parent: Node, text: String, s: float = 1.0) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.65, 0.42, 0.92, 1.0))
	parent.add_child(lbl)


func _col(parent: Node, heading: String, s: float = 1.0) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", int(8 * s))
	parent.add_child(col)
	var lbl := Label.new()
	lbl.text = heading
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.88, 0.88, 0.96, 1.0))
	col.add_child(lbl)
	return col


func _row(parent: Node, key: String, desc: String, s: float = 1.0) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(10 * s))
	parent.add_child(row)
	var kl := Label.new()
	kl.text = key
	kl.custom_minimum_size = Vector2(175.0 * s, 0)
	kl.add_theme_font_size_override("font_size", int(15 * s))
	kl.add_theme_color_override("font_color", Color(1.0, 0.78, 0.38, 1.0))
	row.add_child(kl)
	var dl := Label.new()
	dl.text = desc
	dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dl.add_theme_font_size_override("font_size", int(15 * s))
	dl.add_theme_color_override("font_color", Color(0.78, 0.78, 0.90, 1.0))
	row.add_child(dl)


func _style_btn(btn: Button, s: float = 1.0) -> void:
	var mk := func(bg: Color, brd: Color) -> StyleBoxFlat:
		var sf := StyleBoxFlat.new()
		sf.bg_color = bg;  sf.border_color = brd
		sf.border_width_left = 2;  sf.border_width_right  = 2
		sf.border_width_top  = 2;  sf.border_width_bottom = 2
		sf.corner_radius_top_left     = int(8 * s);  sf.corner_radius_top_right    = int(8 * s)
		sf.corner_radius_bottom_left  = int(8 * s);  sf.corner_radius_bottom_right = int(8 * s)
		sf.content_margin_left   = int(24 * s);  sf.content_margin_right  = int(24 * s)
		sf.content_margin_top    = int(12 * s);  sf.content_margin_bottom = int(12 * s)
		return sf
	btn.add_theme_stylebox_override("normal",  mk.call(Color(0.06, 0.03, 0.14, 0.88), Color(0.55, 0.15, 0.80, 1.0)))
	btn.add_theme_stylebox_override("hover",   mk.call(Color(0.22, 0.08, 0.40, 0.95), Color(1.00, 0.45, 0.85, 1.0)))
	btn.add_theme_stylebox_override("pressed", mk.call(Color(0.45, 0.10, 0.72, 1.00), Color(1.00, 0.70, 1.00, 1.0)))
	btn.add_theme_stylebox_override("focus",   mk.call(Color(0.06, 0.03, 0.14, 0.88), Color(1.00, 0.65, 1.00, 1.0)))
	btn.add_theme_color_override("font_color",         Color(0.92, 0.78, 1.00, 1.0))
	btn.add_theme_color_override("font_hover_color",   Color(1.00, 0.65, 0.90, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(1.00, 1.00, 1.00, 1.0))
	btn.add_theme_font_size_override("font_size", int(20 * s))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file("res://scenes/Main.tscn")


# ── Scroll-gated confirm ─────────────────────────────────────────────────────

## Unlocks the confirm checkbox once the tutorial has been scrolled to the
## bottom. One-way: once unlocked it stays unlocked (scrolling back up to
## re-read shouldn't re-lock progress the player already earned). Also
## unlocks immediately if the content is short enough that no scrolling is
## needed at all, on any screen size.
func _update_scroll_gate() -> void:
	if _scroller == null or _confirm_cb == null or not _confirm_cb.disabled:
		_update_continue_btn()
		return
	var vbar := _scroller.get_v_scroll_bar()
	var nothing_to_scroll: bool = vbar.max_value <= vbar.page + 0.5
	var reached_bottom: bool    = vbar.value >= vbar.max_value - vbar.page - 1.0
	if nothing_to_scroll or reached_bottom:
		_confirm_cb.disabled = false
	_update_continue_btn()


## Continue is only clickable once the (unlocked) confirm checkbox is checked.
func _update_continue_btn() -> void:
	if _play_btn == null:
		return
	_play_btn.disabled = _confirm_cb == null or not _confirm_cb.button_pressed
