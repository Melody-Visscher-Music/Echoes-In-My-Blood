extends Control
class_name Main

var _center_container: Control
var _options_panel: Control
var _gameplay_panel: Control
var _howtoplay_panel: Control
var _controls_panel: Control
var _menu_box: VBoxContainer

# Rebind capture state — set while waiting for the next key/button press.
# {"action": String, "device": "key"|"joy", "btn": Button}
var _awaiting_bind: Dictionary = {}

# Hidden dev entry point into the chart-authoring tool — Ctrl+Alt+D reveals
# a MAPPER button in the main menu (session-only; doesn't persist).
var _dev_unlocked: bool = false
var _mapper_btn: Button = null


func _ready() -> void:
	Save.load_from_disk(0)
	GameConfig.load_from_disk()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


# ── Responsive helpers ─────────────────────────────────────────────────────────

## UI scale factor relative to 1920×1080 reference.
## All hardcoded pixel sizes are multiplied by this value.
func _ui_s() -> float:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return clampf(minf(vp.x / 1920.0, vp.y / 1080.0), 0.5, 2.0)


## Width for panel cards — 40 % of viewport width, clamped to a scaled range.
func _panel_w() -> float:
	var s  := _ui_s()
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return clampf(vp.x * 0.40, 420.0 * s, 860.0 * s)


## Width for the wide HOW TO PLAY panel (two side-by-side columns).
func _panel_w_wide() -> float:
	var s  := _ui_s()
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return clampf(vp.x * 0.55, 560.0 * s, 1120.0 * s)


## Builds a full-screen dimmed backdrop with a scrollable CenterContainer inside.
## Returns [bg_node, wrapper_node] — add your PanelContainer to wrapper_node,
## then add bg_node to the scene.  The scroller activates automatically when
## content is taller than the viewport.
func _panel_bg(color: Color) -> Array:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = color

	var scroller := ScrollContainer.new()
	scroller.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(scroller)

	# CenterContainer must be at least as tall as the viewport so the card
	# is centred; if content is taller it grows and the scroller kicks in.
	var vp_h := get_viewport().get_visible_rect().size.y if get_viewport() else 1080.0
	var wrapper := CenterContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	wrapper.custom_minimum_size   = Vector2(0.0, vp_h)
	scroller.add_child(wrapper)

	return [bg, wrapper]


## Shared StyleBoxFlat for every panel card.
func _panel_style() -> StyleBoxFlat:
	var ps := StyleBoxFlat.new()
	ps.bg_color           = Color(0.04, 0.03, 0.12, 0.97)
	ps.border_color       = Color(0.50, 0.15, 0.75, 1.0)
	ps.border_width_left  = 2;  ps.border_width_right  = 2
	ps.border_width_top   = 2;  ps.border_width_bottom = 2
	ps.corner_radius_top_left     = 12;  ps.corner_radius_top_right    = 12
	ps.corner_radius_bottom_left  = 12;  ps.corner_radius_bottom_right = 12
	return ps


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var s := _ui_s()

	# Background image
	var bg := TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.texture = load("res://Graphics/ChatGPT Image Apr 17, 2026, 07_26_59 PM.png")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	add_child(bg)

	# Dark tint overlay (mouse events pass through so buttons underneath still work)
	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.02, 0.01, 0.08, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	# Left-aligned layout: scaled left pad + vertically-centred menu column
	var outer := HBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.alignment = BoxContainer.ALIGNMENT_BEGIN
	_center_container = outer
	add_child(_center_container)

	var left_pad := Control.new()
	left_pad.custom_minimum_size = Vector2(140.0 * s, 0)
	outer.add_child(left_pad)

	var vert_center := CenterContainer.new()
	vert_center.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vert_center.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	outer.add_child(vert_center)

	var menu_box := VBoxContainer.new()
	menu_box.custom_minimum_size = Vector2(320.0 * s, 0)
	menu_box.add_theme_constant_override("separation", int(14 * s))
	vert_center.add_child(menu_box)
	_menu_box = menu_box

	var new_btn := _menu_btn("NEW GAME", _on_new_game, s)
	menu_box.add_child(new_btn)
	new_btn.grab_focus()

	var cont_btn := _menu_btn("CONTINUE", _on_continue, s)
	cont_btn.disabled = true
	menu_box.add_child(cont_btn)

	menu_box.add_child(_menu_btn("OPTIONS", _on_options, s))
	menu_box.add_child(_menu_btn("QUIT",    _on_quit,    s))

	# Version label (bottom-right corner)
	var ver := Label.new()
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.text = "v0.01"
	ver.offset_left = -60.0 * s
	ver.offset_top  = -30.0 * s
	ver.add_theme_font_size_override("font_size", int(13 * s))
	ver.add_theme_color_override("font_color", Color(0.40, 0.35, 0.55, 0.70))
	add_child(ver)

	# Panels (hidden until triggered)
	_options_panel = _build_options_panel()
	_options_panel.visible = false
	add_child(_options_panel)

	_howtoplay_panel = _build_howtoplay_panel()
	_howtoplay_panel.visible = false
	add_child(_howtoplay_panel)


# ── Button factory ─────────────────────────────────────────────────────────────

func _menu_btn(text: String, callback: Callable, s: float = 1.0) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(320.0 * s, 56.0 * s)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(btn, s)
	btn.pressed.connect(callback)
	return btn


func _style_btn(btn: Button, s: float = 1.0) -> void:
	var mk := func(bg: Color, brd: Color) -> StyleBoxFlat:
		var sf := StyleBoxFlat.new()
		sf.bg_color     = bg
		sf.border_color = brd
		sf.border_width_left   = 2
		sf.border_width_right  = 2
		sf.border_width_top    = 2
		sf.border_width_bottom = 2
		sf.corner_radius_top_left     = int(8 * s)
		sf.corner_radius_top_right    = int(8 * s)
		sf.corner_radius_bottom_left  = int(8 * s)
		sf.corner_radius_bottom_right = int(8 * s)
		sf.content_margin_left   = int(24 * s)
		sf.content_margin_right  = int(24 * s)
		sf.content_margin_top    = int(12 * s)
		sf.content_margin_bottom = int(12 * s)
		return sf

	btn.add_theme_stylebox_override("normal",   mk.call(Color(0.06, 0.03, 0.14, 0.88), Color(0.55, 0.15, 0.80, 1.0)))
	btn.add_theme_stylebox_override("hover",    mk.call(Color(0.22, 0.08, 0.40, 0.95), Color(1.00, 0.45, 0.85, 1.0)))
	btn.add_theme_stylebox_override("pressed",  mk.call(Color(0.45, 0.10, 0.72, 1.00), Color(1.00, 0.70, 1.00, 1.0)))
	btn.add_theme_stylebox_override("disabled", mk.call(Color(0.04, 0.02, 0.08, 0.50), Color(0.22, 0.10, 0.32, 0.40)))
	btn.add_theme_stylebox_override("focus",    mk.call(Color(0.06, 0.03, 0.14, 0.88), Color(1.00, 0.65, 1.00, 1.0)))
	btn.add_theme_color_override("font_color",          Color(0.92, 0.78, 1.00, 1.0))
	btn.add_theme_color_override("font_hover_color",    Color(1.00, 0.65, 0.90, 1.0))
	btn.add_theme_color_override("font_pressed_color",  Color(1.00, 1.00, 1.00, 1.0))
	btn.add_theme_color_override("font_disabled_color", Color(0.38, 0.32, 0.50, 0.55))
	btn.add_theme_font_size_override("font_size", int(22 * s))


# ── Options panel ──────────────────────────────────────────────────────────────

func _build_options_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	wrapper.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   int(44 * s))
	margin.add_theme_constant_override("margin_right",  int(44 * s))
	margin.add_theme_constant_override("margin_top",    int(36 * s))
	margin.add_theme_constant_override("margin_bottom", int(36 * s))
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	margin.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "OPTIONS"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", int(32 * s))
	ttl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.7, 1.0))
	vbox.add_child(ttl)
	vbox.add_child(HSeparator.new())

	# ── AUDIO ─────────────────────────────────────────────────────────────────
	_opt_section(vbox, "AUDIO", s)

	var master_init := db_to_linear(AudioServer.get_bus_volume_db(0))
	var master_val  := Label.new()
	master_val.text  = "%d%%" % int(master_init * 100)
	_opt_slider(vbox, "Master Volume", 0.0, 1.0, 0.01, master_init, master_val,
		func(v: float) -> void:
			AudioServer.set_bus_volume_db(0, linear_to_db(v) if v > 0.001 else -80.0)
			master_val.text = "%d%%" % int(v * 100), s)

	# ── DISPLAY ───────────────────────────────────────────────────────────────
	_opt_section(vbox, "DISPLAY", s)

	var fs_on := DisplayServer.window_get_mode() >= DisplayServer.WINDOW_MODE_FULLSCREEN
	_opt_toggle(vbox, "Fullscreen", fs_on,
		func(on: bool) -> void:
			DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_FULLSCREEN if on
				else DisplayServer.WINDOW_MODE_WINDOWED), s)

	var vs_on := DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	_opt_toggle(vbox, "V-Sync", vs_on,
		func(on: bool) -> void:
			DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if on
				else DisplayServer.VSYNC_DISABLED), s)

	var fps_row := _opt_row(vbox, "Max FPS", s)
	var fps_opt := OptionButton.new()
	fps_opt.add_item("30");  fps_opt.add_item("60")
	fps_opt.add_item("120"); fps_opt.add_item("Unlimited")
	var fps_vals: Array[int] = [30, 60, 120, 0]
	var fi := fps_vals.find(Engine.max_fps)
	fps_opt.selected = fi if fi >= 0 else 1
	fps_opt.item_selected.connect(func(idx: int) -> void: Engine.max_fps = fps_vals[idx])
	fps_row.add_child(fps_opt)

	var quality_row := _opt_row(vbox, "Quality", s)
	var quality_opt := OptionButton.new()
	var quality_ids: Array[String] = GraphicsQuality.TIERS   # ["low","medium","high","ultra"]
	for qid: String in quality_ids:
		quality_opt.add_item(qid.capitalize())
	var qi := quality_ids.find(GraphicsQuality.tier)
	quality_opt.selected = qi if qi >= 0 else 1
	quality_opt.item_selected.connect(func(idx: int) -> void: GraphicsQuality.set_tier(quality_ids[idx]))
	quality_row.add_child(quality_opt)

	var quality_note := Label.new()
	quality_note.text = "Auto-picked from your hardware on first launch — change it here anytime."
	quality_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quality_note.add_theme_font_size_override("font_size", int(12 * s))
	quality_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.62, 1.0))
	vbox.add_child(quality_note)

	# ── Bottom buttons ────────────────────────────────────────────────────────
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(btn_row)

	var save_btn := Button.new()
	save_btn.text = "SAVE & BACK"
	save_btn.custom_minimum_size = Vector2(int(170 * s), int(48 * s))
	_style_btn(save_btn, s)
	save_btn.pressed.connect(_on_save_back)
	btn_row.add_child(save_btn)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(int(170 * s), int(48 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_options_back)
	btn_row.add_child(back_btn)

	# ── Navigation to second settings pages ───────────────────────────────────
	var nav_gap := Control.new()
	nav_gap.custom_minimum_size = Vector2(0, int(4 * s))
	vbox.add_child(nav_gap)

	var nav_btn := Button.new()
	nav_btn.text = "GAMEPLAY  &  APPEARANCE  →"
	nav_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	nav_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(nav_btn, s)
	nav_btn.pressed.connect(_on_show_gameplay)
	vbox.add_child(nav_btn)

	var controls_btn := Button.new()
	controls_btn.text = "CONTROLS  →"
	controls_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	controls_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(controls_btn, s)
	controls_btn.pressed.connect(_on_show_controls)
	vbox.add_child(controls_btn)

	var htp_btn := Button.new()
	htp_btn.text = "HOW TO PLAY  →"
	htp_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	htp_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(htp_btn, s)
	htp_btn.pressed.connect(_on_show_howtoplay)
	vbox.add_child(htp_btn)

	return bg


# ── Options helpers ────────────────────────────────────────────────────────────

func _opt_section(parent: Node, text: String, s: float = 1.0) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, int(2 * s))
	parent.add_child(gap)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.65, 0.42, 0.92, 1.0))
	parent.add_child(lbl)


func _opt_row(parent: Node, label_text: String, s: float = 1.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", int(12 * s))
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(210.0 * s, 0)
	lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", int(17 * s))
	lbl.add_theme_color_override("font_color", Color(0.88, 0.88, 0.96, 1.0))
	row.add_child(lbl)
	return row


func _opt_slider(parent: Node, label_text: String,
		min_v: float, max_v: float, step_v: float,
		init_v: float, val_lbl: Label, on_change: Callable,
		s: float = 1.0) -> void:
	var row := _opt_row(parent, label_text, s)
	var slider := HSlider.new()
	slider.min_value = min_v;  slider.max_value = max_v
	slider.step      = step_v; slider.value     = init_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size   = Vector2(160.0 * s, 0)
	slider.value_changed.connect(on_change)
	val_lbl.custom_minimum_size  = Vector2(70.0 * s, 0)
	val_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", int(15 * s))
	val_lbl.add_theme_color_override("font_color", Color(0.72, 0.72, 0.88, 1.0))
	row.add_child(slider)
	row.add_child(val_lbl)


func _opt_toggle(parent: Node, label_text: String,
		init_state: bool, on_toggle: Callable,
		s: float = 1.0) -> void:
	var row := _opt_row(parent, label_text, s)
	var chk := CheckButton.new()
	chk.button_pressed = init_state
	chk.toggled.connect(on_toggle)
	row.add_child(chk)


func _opt_color(parent: Node, label_text: String,
		init_color: Color, on_change: Callable,
		s: float = 1.0) -> void:
	var row := _opt_row(parent, label_text, s)
	var cpb := ColorPickerButton.new()
	cpb.color = init_color
	cpb.custom_minimum_size = Vector2(int(80 * s), int(34 * s))
	cpb.color_changed.connect(on_change)
	row.add_child(cpb)


# ── Gameplay & Appearance panel ────────────────────────────────────────────────

func _build_gameplay_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	wrapper.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   int(44 * s))
	margin.add_theme_constant_override("margin_right",  int(44 * s))
	margin.add_theme_constant_override("margin_top",    int(36 * s))
	margin.add_theme_constant_override("margin_bottom", int(36 * s))
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	margin.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "GAMEPLAY  &  APPEARANCE"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", int(28 * s))
	ttl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.7, 1.0))
	vbox.add_child(ttl)
	vbox.add_child(HSeparator.new())

	# ── PLAYER APPEARANCE ─────────────────────────────────────────────────────
	_opt_section(vbox, "PLAYER APPEARANCE", s)
	_opt_color(vbox, "Jacket Color", GameConfig.jacket_color,
		func(c: Color) -> void: GameConfig.jacket_color = c, s)
	_opt_color(vbox, "Fur Color", GameConfig.fur_color,
		func(c: Color) -> void: GameConfig.fur_color = c, s)
	_opt_color(vbox, "Hair Color", GameConfig.hair_color,
		func(c: Color) -> void: GameConfig.hair_color = c, s)

	# ── LEVEL COLORS ──────────────────────────────────────────────────────────
	_opt_section(vbox, "LEVEL COLORS", s)
	_opt_color(vbox, "Left Gate Color  (pink)", GameConfig.level_color_a,
		func(c: Color) -> void: GameConfig.level_color_a = c, s)
	_opt_color(vbox, "Right Gate Color  (blue)", GameConfig.level_color_b,
		func(c: Color) -> void: GameConfig.level_color_b = c, s)
	_opt_color(vbox, "Jump Gate Color  (green)", GameConfig.level_color_jump,
		func(c: Color) -> void: GameConfig.level_color_jump = c, s)
	_opt_color(vbox, "Slide Gate Color  (teal)", GameConfig.level_color_slide,
		func(c: Color) -> void: GameConfig.level_color_slide = c, s)
	_opt_color(vbox, "Grind Rail Color  (orange)", GameConfig.level_color_rail,
		func(c: Color) -> void: GameConfig.level_color_rail = c, s)
	_opt_color(vbox, "Floor Color", GameConfig.floor_color,
		func(c: Color) -> void: GameConfig.floor_color = c, s)
	_opt_toggle(vbox, "Color Cycle", GameConfig.color_cycle_enabled,
		func(on: bool) -> void: GameConfig.color_cycle_enabled = on, s)

	var cycle_speed_val := Label.new()
	cycle_speed_val.text = "%.1fs" % GameConfig.color_cycle_period_s
	_opt_slider(vbox, "Color Cycle Speed  (sec/color — lower = faster)",
		0.1, 5.0, 0.1, GameConfig.color_cycle_period_s, cycle_speed_val,
		func(v: float) -> void:
			GameConfig.color_cycle_period_s = v
			cycle_speed_val.text = "%.1fs" % v, s)

	# ── CYCLE AFFECTS ─────────────────────────────────────────────────────────
	_opt_section(vbox, "COLOR CYCLE AFFECTS", s)
	_opt_toggle(vbox, "Gates",      GameConfig.color_cycle_affects_gates,
		func(on: bool) -> void: GameConfig.color_cycle_affects_gates  = on, s)
	_opt_toggle(vbox, "Halos",      GameConfig.color_cycle_affects_halos,
		func(on: bool) -> void: GameConfig.color_cycle_affects_halos  = on, s)
	_opt_toggle(vbox, "Floor",      GameConfig.color_cycle_affects_floor,
		func(on: bool) -> void: GameConfig.color_cycle_affects_floor  = on, s)
	_opt_toggle(vbox, "World Deco", GameConfig.color_cycle_affects_world,
		func(on: bool) -> void: GameConfig.color_cycle_affects_world  = on, s)
	_opt_toggle(vbox, "Grind Rail", GameConfig.color_cycle_affects_rail,
		func(on: bool) -> void: GameConfig.color_cycle_affects_rail   = on, s)

	# ── GAMEPLAY ──────────────────────────────────────────────────────────────
	_opt_section(vbox, "GAMEPLAY", s)
	_opt_toggle(vbox, "Wall Jumps", GameConfig.wall_jumps_enabled,
		func(on: bool) -> void: GameConfig.wall_jumps_enabled = on, s)

	var lives_val := Label.new()
	lives_val.text = "%d" % GameConfig.lives_per_song
	_opt_slider(vbox, "Lives per Song", 1.0, 5.0, 1.0,
		float(GameConfig.lives_per_song), lives_val,
		func(v: float) -> void:
			GameConfig.lives_per_song = int(v)
			Run.song_lives = int(v)
			lives_val.text = "%d" % int(v), s)

	var gate_val := Label.new()
	gate_val.text = "%.1f" % GameConfig.gate_preview_beats
	_opt_slider(vbox, "Gate Preview (beats)", 1.0, 20.0, 0.5,
		GameConfig.gate_preview_beats, gate_val,
		func(v: float) -> void:
			GameConfig.gate_preview_beats = v
			gate_val.text = "%.1f" % v, s)

	# ── HALO ─────────────────────────────────────────────────────────────────
	_opt_section(vbox, "HALO", s)

	var shape_row := _opt_row(vbox, "Shape", s)
	var shape_opt := OptionButton.new()
	var halo_shape_ids: Array[String] = [
		"circle", "triangle", "square", "pentagon",
		"hexagon", "star", "diamond", "cross", "heart",
	]
	for sid: String in halo_shape_ids:
		shape_opt.add_item(sid.capitalize())
	var cur_shape_idx: int = halo_shape_ids.find(GameConfig.halo_shape)
	shape_opt.selected = cur_shape_idx if cur_shape_idx >= 0 else 5
	shape_opt.item_selected.connect(func(idx: int) -> void:
		var _ids := ["circle","triangle","square","pentagon","hexagon","star","diamond","cross","heart"]
		GameConfig.halo_shape = _ids[idx])
	shape_row.add_child(shape_opt)

	var halo_val := Label.new()
	halo_val.text = "%.1f" % GameConfig.halo_size
	_opt_slider(vbox, "Size", 2.0, 12.0, 0.2,
		GameConfig.halo_size, halo_val,
		func(v: float) -> void:
			GameConfig.halo_size = v
			halo_val.text = "%.1f" % v, s)

	_opt_toggle(vbox, "Dual Color", GameConfig.halo_dual_color,
		func(on: bool) -> void: GameConfig.halo_dual_color = on, s)
	_opt_color(vbox, "Halo Color A", GameConfig.halo_color_a,
		func(c: Color) -> void: GameConfig.halo_color_a = c, s)
	_opt_color(vbox, "Halo Color B", GameConfig.halo_color_b,
		func(c: Color) -> void: GameConfig.halo_color_b = c, s)

	# ── Buttons ───────────────────────────────────────────────────────────────
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(btn_row)

	var reset_btn := Button.new()
	reset_btn.text = "RESET DEFAULTS"
	reset_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(reset_btn, s)
	reset_btn.pressed.connect(_on_gameplay_reset)
	btn_row.add_child(reset_btn)

	var back_btn := Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_gameplay_back)
	btn_row.add_child(back_btn)

	return bg


# ── Controls panel ─────────────────────────────────────────────────────────────
# Rebinds live in GameConfig (keyboard + gamepad, per action) so this tab, the
# actual gameplay InputMap, and both How To Play screens all read the exact
# same source of truth. See GameConfig.apply_all_control_bindings().

func _build_controls_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	wrapper.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   int(44 * s))
	margin.add_theme_constant_override("margin_right",  int(44 * s))
	margin.add_theme_constant_override("margin_top",    int(36 * s))
	margin.add_theme_constant_override("margin_bottom", int(36 * s))
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	margin.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "CONTROLS"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", int(32 * s))
	ttl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.7, 1.0))
	vbox.add_child(ttl)
	vbox.add_child(HSeparator.new())

	var note := Label.new()
	note.text = "Click a key or button, then press the new one. Escape cancels. Changes apply immediately and How To Play updates to match."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", int(13 * s))
	note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.72, 1.0))
	vbox.add_child(note)

	_opt_section(vbox, "KEYBOARD  /  GAMEPAD", s)

	for action: String in GameConfig.REBINDABLE_ACTIONS:
		var row := _opt_row(vbox, GameConfig.ACTION_LABELS.get(action, action), s)

		var key_btn := Button.new()
		key_btn.custom_minimum_size = Vector2(int(120 * s), int(36 * s))
		key_btn.text = GameConfig.key_name(action)
		_style_btn(key_btn, s)
		key_btn.pressed.connect(func() -> void: _start_bind_capture(action, "key", key_btn))
		row.add_child(key_btn)

		var joy_btn := Button.new()
		joy_btn.custom_minimum_size = Vector2(int(140 * s), int(36 * s))
		joy_btn.text = GameConfig.joy_button_name(action)
		_style_btn(joy_btn, s)
		joy_btn.pressed.connect(func() -> void: _start_bind_capture(action, "joy", joy_btn))
		row.add_child(joy_btn)

	var axis_note := Label.new()
	axis_note.text = "Left stick (move) and left trigger (grind) always work alongside whatever's bound above."
	axis_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	axis_note.add_theme_font_size_override("font_size", int(12 * s))
	axis_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.62, 1.0))
	vbox.add_child(axis_note)

	# ── Buttons ───────────────────────────────────────────────────────────────
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(btn_row)

	var reset_btn := Button.new()
	reset_btn.text = "RESET DEFAULTS"
	reset_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(reset_btn, s)
	reset_btn.pressed.connect(_on_controls_reset)
	btn_row.add_child(reset_btn)

	var back_btn := Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_controls_back)
	btn_row.add_child(back_btn)

	return bg


## Begins listening for the next key press (device == "key") or gamepad
## button press (device == "joy") to bind to `action`. Cancels any capture
## already in progress first, restoring that button's label.
func _start_bind_capture(action: String, device: String, btn: Button) -> void:
	if not _awaiting_bind.is_empty():
		var prev_btn: Button = _awaiting_bind.get("btn")
		if is_instance_valid(prev_btn):
			_refresh_bind_button(prev_btn, _awaiting_bind.get("action"), _awaiting_bind.get("device"))
	_awaiting_bind = {"action": action, "device": device, "btn": btn}
	btn.text = "Press a key…" if device == "key" else "Press a button…"


func _refresh_bind_button(btn: Button, action: String, device: String) -> void:
	btn.text = GameConfig.key_name(action) if device == "key" else GameConfig.joy_button_name(action)


func _handle_bind_capture(event: InputEvent) -> void:
	var action: String = _awaiting_bind.get("action", "")
	var device: String = _awaiting_bind.get("device", "")
	var btn: Button     = _awaiting_bind.get("btn")

	# Any keyboard key ends the capture: binds it if we're capturing a keyboard
	# action (unless it's Escape, which just cancels); always cancels a
	# gamepad capture, since a stray key press isn't a valid gamepad bind.
	if event is InputEventKey and event.pressed and not (event as InputEventKey).is_echo():
		get_viewport().set_input_as_handled()
		var keycode: int = (event as InputEventKey).physical_keycode
		if device == "key" and keycode != KEY_ESCAPE:
			GameConfig.set_control_key(action, keycode)
		_awaiting_bind = {}
		if is_instance_valid(btn):
			_refresh_bind_button(btn, action, device)
		return

	if device == "joy" and event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		get_viewport().set_input_as_handled()
		GameConfig.set_control_joy_button(action, (event as InputEventJoypadButton).button_index)
		_awaiting_bind = {}
		if is_instance_valid(btn):
			_refresh_bind_button(btn, action, device)
		return

	# Swallow stray mouse/joy-motion input while capturing so it doesn't leak
	# through to whatever's behind the panel.
	if event is InputEventMouseButton or event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()


func _on_controls_reset() -> void:
	GameConfig.reset_controls_to_default()
	_controls_panel.queue_free()
	_controls_panel = _build_controls_panel()
	_controls_panel.visible = true
	add_child(_controls_panel)


# ── How To Play panel ─────────────────────────────────────────────────────────

func _build_howtoplay_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_panel_w_wide(), 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
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

	# Title
	var ttl := Label.new()
	ttl.text = "HOW TO PLAY"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_size_override("font_size", int(32 * s))
	ttl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.7, 1.0))
	vbox.add_child(ttl)
	vbox.add_child(HSeparator.new())

	# Controls — both columns always visible
	_htp_section(vbox, "CONTROLS", s)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", int(32 * s))
	vbox.add_child(cols)

	var kb := _htp_col(cols, "⌨  KEYBOARD", s)
	_htp_row(kb, GameConfig.key_name("runner_left"),  "Move left (left lane gate)",  s)
	_htp_row(kb, GameConfig.key_name("runner_right"), "Move right (right lane gate)", s)
	_htp_row(kb, GameConfig.key_name("runner_jump"),  "Jump (jump gate)",             s)
	_htp_row(kb, GameConfig.key_name("runner_slide"), "Slide (slide gate)",           s)
	_htp_row(kb, "%s / %s" % [GameConfig.key_name("runner_lb"), GameConfig.key_name("runner_rb")],
		"Wall jump section", s)
	_htp_row(kb, GameConfig.key_name("runner_grind"), "Grind rail (hold)",            s)
	_htp_row(kb, "↑ ↓  +  Enter",    "Navigate & confirm menus",          s)
	_htp_row(kb, "Escape",            "Pause / back",                      s)

	var gp := _htp_col(cols, "🎮  GAMEPAD", s)
	_htp_row(gp, "Left Joystick",                          "Move Left / Move Right",  s)
	_htp_row(gp, GameConfig.joy_button_name("runner_rb"),  "Wall jump →",             s)
	_htp_row(gp, GameConfig.joy_button_name("runner_lb"),  "Wall jump ←",             s)
	_htp_row(gp, GameConfig.joy_button_name("runner_jump"), "Confirm / Jump",         s)
	_htp_row(gp, GameConfig.joy_button_name("runner_slide"), "Back / Slide",          s)
	_htp_row(gp, _grind_gp_label(),                        "Grind rail (hold)",       s)
	_htp_row(gp, "D-pad",         "Navigate menus  |  LB/RB change mode", s)

	# Charge Tunnel / Overdrive
	_htp_section(vbox, "⚡  CHARGE TUNNEL  →  ×100 OVERDRIVE", s)
	var ct := VBoxContainer.new()
	ct.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(ct)
	_htp_row(ct, "Hold " + GameConfig.key_name("runner_grind") + " / " + _grind_gp_label(),
		"Free-slide — steer with Move Left/Right to weave through the hoops", s)
	_htp_row(ct, "Stay threaded",  "Aligned with the hoop = charge fills; clip the rim = it bleeds", s)
	_htp_row(ct, "Let go early",   "Charge bleeds away — don't release before the drop",  s)
	_htp_row(ct, "Release on the drop", "Pops ×100 OVERDRIVE — bigger fill = longer window", s)

	# Scoring
	_htp_section(vbox, "SCORING & HEALTH", s)
	var sc := VBoxContainer.new()
	sc.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(sc)
	_htp_row(sc, "Gate hit",             "+500 pts × combo multiplier",              s)
	_htp_row(sc, "Combo multiplier",     "×2 at 10 streak  ·  ×3 at 20  ·  ×4 at 30", s)
	_htp_row(sc, "Health (starts 50 %)", "+2 % per hit    –2 % per miss    → 0 % = fail", s)
	_htp_row(sc, "Letter grade",         "S / A / B / C / D / F  based on accuracy %", s)

	# Back button
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var back_btn := Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_howtoplay_back)
	vbox.add_child(back_btn)

	return bg


## Grind's gamepad label — left trigger is a fixed always-on default, plus
## whatever custom button (if any) the player also bound to it.
func _grind_gp_label() -> String:
	var custom: String = GameConfig.joy_button_name("runner_grind")
	return "Left Trigger" if custom == "—" else "Left Trigger / %s" % custom


func _htp_section(parent: Node, text: String, s: float = 1.0) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.65, 0.42, 0.92, 1.0))
	parent.add_child(lbl)


func _htp_col(parent: Node, heading: String, s: float = 1.0) -> VBoxContainer:
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


func _htp_row(parent: Node, key: String, desc: String, s: float = 1.0) -> void:
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


# ── Button handlers ────────────────────────────────────────────────────────────

func _on_new_game() -> void:
	# Tutorial is a one-time, first-launch-only screen: once any song has a
	# registered high score, the player has already played, so skip straight
	# to song select on every later launch.
	if Save.has_any_high_score():
		get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/HowToPlay.tscn")

func _on_continue() -> void:
	pass  # Not yet implemented

func _on_options() -> void:
	_center_container.visible = false
	_options_panel.visible    = true

func _on_quit() -> void:
	get_tree().quit()

## Ctrl+Alt+D — reveals (or re-hides) the MAPPER entry in the main menu.
## Session-only; doesn't persist to disk. Only affects visibility of the
## button itself, nothing else in the menu.
func _toggle_dev_mapper_entry() -> void:
	_dev_unlocked = not _dev_unlocked
	if _dev_unlocked:
		if _mapper_btn == null and _menu_box != null:
			var s := _ui_s()
			_mapper_btn = _menu_btn("MAPPER", _on_open_mapper, s)
			_menu_box.add_child(_mapper_btn)
			_menu_box.move_child(_mapper_btn, _menu_box.get_child_count() - 2)   # just above QUIT
	elif _mapper_btn != null:
		_mapper_btn.queue_free()
		_mapper_btn = null

func _on_open_mapper() -> void:
	get_tree().change_scene_to_file("res://tools/ManualMapper.tscn")

func _on_save_back() -> void:
	Save.save_to_disk(0)
	GameConfig.save()
	_on_options_back()

func _on_options_back() -> void:
	_options_panel.visible    = false
	if _gameplay_panel != null:
		_gameplay_panel.visible = false
	_howtoplay_panel.visible  = false
	_center_container.visible = true

func _on_show_gameplay() -> void:
	_options_panel.visible = false
	if _gameplay_panel == null:
		_gameplay_panel = _build_gameplay_panel()
		add_child(_gameplay_panel)
	_gameplay_panel.visible = true

func _on_gameplay_back() -> void:
	_gameplay_panel.visible = false
	_options_panel.visible  = true

func _on_show_controls() -> void:
	_options_panel.visible = false
	if _controls_panel == null:
		_controls_panel = _build_controls_panel()
		add_child(_controls_panel)
	_controls_panel.visible = true

func _on_controls_back() -> void:
	_awaiting_bind = {}
	_controls_panel.visible = false
	_options_panel.visible  = true

func _on_show_howtoplay() -> void:
	_options_panel.visible = false
	# Rebuilt on every open so it always reflects the latest control bindings
	# (the player may have just rebound something in the Controls tab).
	_howtoplay_panel.queue_free()
	_howtoplay_panel = _build_howtoplay_panel()
	_howtoplay_panel.visible = true
	add_child(_howtoplay_panel)

func _on_howtoplay_back() -> void:
	_howtoplay_panel.visible = false
	_options_panel.visible   = true

func _on_gameplay_reset() -> void:
	GameConfig.reset_defaults()
	# Rebuild panel so colour swatches reflect the new values
	_gameplay_panel.queue_free()
	_gameplay_panel = _build_gameplay_panel()
	_gameplay_panel.visible = true
	add_child(_gameplay_panel)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).is_echo():
		var k := event as InputEventKey
		if k.physical_keycode == KEY_D and k.ctrl_pressed and k.alt_pressed:
			get_viewport().set_input_as_handled()
			_toggle_dev_mapper_entry()
			return

	if not _awaiting_bind.is_empty():
		_handle_bind_capture(event)
		return
	if not event.is_action_pressed("ui_cancel"):
		return
	if _howtoplay_panel != null and _howtoplay_panel.visible:
		get_viewport().set_input_as_handled()
		_on_howtoplay_back()
	elif _controls_panel != null and _controls_panel.visible:
		get_viewport().set_input_as_handled()
		_on_controls_back()
	elif _gameplay_panel != null and _gameplay_panel.visible:
		get_viewport().set_input_as_handled()
		_on_gameplay_back()
	elif _options_panel != null and _options_panel.visible:
		get_viewport().set_input_as_handled()
		_on_options_back()
