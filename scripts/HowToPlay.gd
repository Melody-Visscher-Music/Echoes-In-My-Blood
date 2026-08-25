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

## UI scale factor relative to the 1920×1080 reference — shared with every other
## screen. This file used to carry its own copy of the formula.
func _ui_s() -> float:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return UiStyle.scale_for(vp)


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

	var panel := PlatePanel.create(int(50 * s), UiStyle.VIOLET, 30.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(18 * s))
	panel.content.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var title: Label = UiStyle.label("HOW TO PLAY", UiStyle.caption(8.0), int(27 * s), Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = UiStyle.signature_color(0.1)
	vbox.add_child(title)
	var trule := ColorRect.new()
	trule.color = Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.45)
	trule.custom_minimum_size = Vector2(0, maxf(1.0, 2.0 * s))
	trule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(trule)

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
	_row(sc, "Health (starts 25 %)", "+1 % per hit    –10 % per miss    → 0 % = fail", s)
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

	var back_btn := PlateButton.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(170 * s), int(52 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/Main.tscn"))
	btn_row.add_child(back_btn)

	var play_btn := PlateButton.new()
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

## (The card is a PlatePanel now — see _build_ui.)


## Grind's gamepad label — left trigger is a fixed always-on default, plus
## whatever custom button (if any) the player also bound to it.
func _grind_gp_label() -> String:
	var custom: String = GameConfig.joy_button_name("runner_grind")
	return "Left Trigger" if custom == "—" else "Left Trigger / %s" % custom


func _section(parent: Node, text: String, s: float = 1.0) -> void:
	var lbl: Label = UiStyle.label(text, UiStyle.caption(5.0), int(13 * s), Color.WHITE)
	lbl.self_modulate = Color(0.72, 0.50, 1.00)
	parent.add_child(lbl)


func _col(parent: Node, heading: String, s: float = 1.0) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", int(8 * s))
	parent.add_child(col)
	var lbl: Label = UiStyle.label(heading, UiStyle.caption(3.0), int(14 * s), Color.WHITE)
	lbl.self_modulate = Color(0.92, 0.88, 1.00)
	col.add_child(lbl)
	return col


func _row(parent: Node, key: String, desc: String, s: float = 1.0) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(10 * s))
	parent.add_child(row)
	var kl: Label = UiStyle.label(key, UiStyle.caption(1.5), int(13 * s), Color.WHITE)
	kl.custom_minimum_size = Vector2(185.0 * s, 0)
	kl.self_modulate = UiStyle.GOLD
	row.add_child(kl)
	var dl: Label = UiStyle.label(desc, UiStyle.body(), int(15 * s), Color(0.80, 0.78, 0.92))
	dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(dl)


## PlateButton brings its own chassis, font and state colours; only sizing is
## left. Kept as a function so the call sites stay unchanged.
func _style_btn(btn: Button, s: float = 1.0) -> void:
	btn.add_theme_font_size_override("font_size", int(19 * s))
	var pb := btn as PlateButton
	if pb != null:
		pb.set_padding(22.0 * s, 11.0 * s)


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
