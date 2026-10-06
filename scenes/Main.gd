extends Control
class_name Main

var _center_container: Control
var _options_panel: Control
var _gameplay_panel: Control
var _howtoplay_panel: Control
var _play_panel: Control
var _controls_panel: Control
var _menu_box: VBoxContainer

# Rebind capture state — set while waiting for the next key/button press.
# {"action": String, "device": "key"|"joy", "btn": Button}
var _awaiting_bind: Dictionary = {}

# Hidden dev entry points — Ctrl+Alt+D reveals a MAPPER button (chart-authoring
# tool) and a STORY MAP button (the story level-select prototype) in the main
# menu (session-only; doesn't persist).
var _dev_unlocked: bool = false
var _mapper_btn: Button = null
var _story_map_btn: Button = null

# Where keyboard/gamepad focus should go when a panel closes. Pushed on the way
# in, popped on the way out — hiding a Control silently drops the focus owner,
# and without this the menu came back with nothing selected and up/down dead.
var _focus_stack: Array[Control] = []

# Set by every Options/Gameplay control that writes to GameConfig, cleared by
# SAVE & BACK. Backing out with changes pending pops a confirm instead of
# silently throwing the edits away — GameConfig only reaches disk via save().
var _settings_dirty: bool = false
var _confirm_panel: Control = null


func _ready() -> void:
	Save.sync_to_run()
	GameConfig.load_from_disk()
	# Reaching the main menu ends any story run that was in progress. Without
	# this, quitting a story level to the menu and then starting a Freeplay song
	# would leave the story context set, and that song's exit would send the
	# player to the story map instead of back to the song list.
	Run.end_story_context()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


# ── Responsive helpers ─────────────────────────────────────────────────────────

## UI scale factor relative to the 1920×1080 reference. Shared with the HUD and
## every other screen — this used to be a third private copy of the same formula.
func _ui_s() -> float:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	return UiStyle.scale_for(vp)


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
	# Options panels are taller than the screen on small windows. Without this
	# a gamepad could move focus onto a row that stayed scrolled out of sight.
	scroller.follow_focus = true
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


## Thin signature-band rule. HSeparator's theme colour is one flat line with no
## way to carry the palette.
func _rule(s: float = 1.0) -> Control:
	var r := ColorRect.new()
	r.color = Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.45)
	r.custom_minimum_size = Vector2(0, maxf(1.0, 2.0 * s))
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


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

	# Scrim behind the menu column. The background art is bright on the left,
	# which is exactly where the plates sit — without this their neon edges and
	# glow have nothing to read against. Fades out to the right so the artwork
	# is still the artwork. (Mouse events pass through.)
	var scrim := TextureRect.new()
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.stretch_mode = TextureRect.STRETCH_SCALE
	var sgrad := Gradient.new()
	sgrad.set_color(0, Color(0.015, 0.008, 0.045, 0.94))
	sgrad.set_color(1, Color(0.015, 0.008, 0.045, 0.0))
	var stex := GradientTexture2D.new()
	stex.gradient  = sgrad
	stex.fill_from = Vector2(0.0, 0.0)
	stex.fill_to   = Vector2(0.42, 0.0)
	stex.width = 256; stex.height = 8
	scrim.texture = stex
	add_child(scrim)

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
	menu_box.custom_minimum_size = Vector2(340.0 * s, 0)
	menu_box.add_theme_constant_override("separation", int(12 * s))
	vert_center.add_child(menu_box)
	_menu_box = menu_box

	# No wordmark here: the background art already carries the title and the
	# author credit, so a second one just competes with it.
	var play_btn := _menu_btn("PLAY", _on_play, s)
	menu_box.add_child(play_btn)
	play_btn.grab_focus()

	menu_box.add_child(_menu_btn("OPTIONS", _on_options, s))
	menu_box.add_child(_menu_btn("QUIT",    _on_quit,    s))

	# Version label (bottom-right corner)
	var ver := Label.new()
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.text = "v0.03-Beta"
	ver.offset_left = -60.0 * s
	ver.offset_top  = -30.0 * s
	ver.add_theme_font_override("font", UiStyle.display(600, 2.0))
	ver.add_theme_font_size_override("font_size", int(12 * s))
	ver.add_theme_color_override("font_color", Color(0.45, 0.40, 0.62, 0.75))
	add_child(ver)

	# Panels (hidden until triggered)
	_options_panel = _build_options_panel()
	_options_panel.visible = false
	add_child(_options_panel)

	_howtoplay_panel = _build_howtoplay_panel()
	_howtoplay_panel.visible = false
	add_child(_howtoplay_panel)

	_play_panel = _build_play_panel()
	_play_panel.visible = false
	add_child(_play_panel)

	_rewrap_menu.call_deferred()


# ── Focus plumbing ─────────────────────────────────────────────────────────────
# Every panel here is shown by flipping `visible`, and hiding the Control that
# owns focus leaves the viewport with no focus owner at all — which is what made
# the keyboard and the gamepad go dead the moment OPTIONS opened. Each open
# pushes the caller's button, each back pops it.

func _rewrap_menu() -> void:
	if _menu_box != null:
		MenuNav.wrap_column(_menu_box.get_children())


## Deferred so it runs after the panel is in the tree and laid out — grabbing
## focus on a node that is not inside the tree yet is a silent no-op.
func _focus_panel(root: Node) -> void:
	MenuNav.focus_first(root)


## The picker's R/G/B sliders are internal children, so the ordinary walk cannot
## see them. Landing on the first one makes left/right adjust the channel.
func _focus_picker(picker: Node) -> void:
	MenuNav.focus_first(picker, true)


func _push_focus() -> void:
	var vp := get_viewport()
	_focus_stack.append(vp.gui_get_focus_owner() if vp != null else null)


func _pop_focus(fallback: Node) -> void:
	var prev: Control = null
	if not _focus_stack.is_empty():
		prev = _focus_stack.pop_back()
	if _can_focus(prev):
		prev.grab_focus()
	else:
		MenuNav.focus_first(fallback)


## The remembered control may have been freed by a panel rebuild, hidden, or
## disabled since it was pushed.
func _can_focus(c: Control) -> bool:
	if not is_instance_valid(c) or not c.is_visible_in_tree():
		return false
	return c.focus_mode == Control.FOCUS_ALL and not MenuNav.is_disabled(c)


# ── Button factory ─────────────────────────────────────────────────────────────

func _menu_btn(text: String, callback: Callable, s: float = 1.0) -> PlateButton:
	var btn := PlateButton.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(320.0 * s, 56.0 * s)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(btn, s)
	btn.pressed.connect(callback)
	return btn


## PlateButton brings its own chassis, font and state colours; all that is left
## here is sizing. Kept as a function so the ~10 call sites stay unchanged.
func _style_btn(btn: Button, s: float = 1.0) -> void:
	btn.add_theme_font_size_override("font_size", int(19 * s))
	var pb := btn as PlateButton
	if pb != null:
		pb.set_padding(22.0 * s, 11.0 * s)


# ── Options panel ──────────────────────────────────────────────────────────────

func _build_options_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PlatePanel.create(int(42 * s), UiStyle.VIOLET, 26.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	panel.content.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "OPTIONS"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_override("font", UiStyle.caption(7.0))
	ttl.add_theme_font_size_override("font_size", int(26 * s))
	ttl.add_theme_color_override("font_color", Color.WHITE)
	ttl.self_modulate = UiStyle.signature_color(0.1)
	vbox.add_child(ttl)
	vbox.add_child(_rule(s))

	# ── AUDIO ─────────────────────────────────────────────────────────────────
	_opt_section(vbox, "AUDIO", s)

	# All three write to GameConfig and then re-apply, so they persist. They used
	# to poke AudioServer directly and were lost on every quit.
	var master_val := Label.new()
	master_val.text = "%d%%" % int(GameConfig.master_volume * 100)
	_opt_slider(vbox, "Master Volume", 0.0, 1.0, 0.01, GameConfig.master_volume, master_val,
		func(v: float) -> void:
			GameConfig.master_volume = v
			GameConfig.apply_display_and_audio()
			master_val.text = "%d%%" % int(v * 100)
			_mark_dirty(), s)

	var music_val := Label.new()
	music_val.text = "%d%%" % int(GameConfig.music_volume * 100)
	_opt_slider(vbox, "Music Volume", 0.0, 1.0, 0.01, GameConfig.music_volume, music_val,
		func(v: float) -> void:
			GameConfig.music_volume = v
			GameConfig.apply_display_and_audio()
			music_val.text = "%d%%" % int(v * 100)
			_mark_dirty(), s)

	var sfx_val := Label.new()
	sfx_val.text = "%d%%" % int(GameConfig.sfx_volume * 100)
	_opt_slider(vbox, "SFX Volume", 0.0, 1.0, 0.01, GameConfig.sfx_volume, sfx_val,
		func(v: float) -> void:
			GameConfig.sfx_volume = v
			GameConfig.apply_display_and_audio()
			sfx_val.text = "%d%%" % int(v * 100)
			_mark_dirty(), s)

	# Calibration used to be reachable only from the in-game pause menu, so a
	# player who never paused never found the one setting that makes Bluetooth
	# playable. It belongs next to the volume sliders.
	var cal_btn := PlateButton.new()
	cal_btn.text = "CALIBRATE AUDIO LATENCY"
	cal_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	cal_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(cal_btn, s)
	cal_btn.pressed.connect(_on_calibrate_audio)
	vbox.add_child(cal_btn)

	var cal_note := Label.new()
	cal_note.text = "Measures your headphones' audio delay so gates line up with the beat. Worth running once on Bluetooth."
	cal_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cal_note.add_theme_font_size_override("font_size", int(12 * s))
	cal_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.62, 1.0))
	vbox.add_child(cal_note)

	# ── DISPLAY ───────────────────────────────────────────────────────────────
	_opt_section(vbox, "DISPLAY", s)

	_opt_toggle(vbox, "Fullscreen", GameConfig.fullscreen,
		func(on: bool) -> void:
			GameConfig.fullscreen = on
			GameConfig.apply_display_and_audio()
			_mark_dirty(), s)

	_opt_toggle(vbox, "V-Sync", GameConfig.vsync_enabled,
		func(on: bool) -> void:
			GameConfig.vsync_enabled = on
			GameConfig.apply_display_and_audio()
			_mark_dirty(), s)

	# The setting the epilepsy warning implies. Nothing it changes is load
	# bearing: gates are read by lane and by shape, never by how hard the world
	# flashes on the beat.
	_opt_toggle(vbox, "Reduced Flashing", GameConfig.reduced_flashing,
		func(on: bool) -> void:
			GameConfig.reduced_flashing = on
			_mark_dirty(), s)

	_opt_toggle(vbox, "Show FPS", GameConfig.show_fps,
		func(on: bool) -> void:
			GameConfig.show_fps = on
			_mark_dirty(), s)

	var fps_row := _opt_row(vbox, "Max FPS", s)
	var fps_opt := OptionButton.new()
	UiStyle.style_option(fps_opt, s)
	fps_opt.add_item("30");  fps_opt.add_item("60")
	fps_opt.add_item("120"); fps_opt.add_item("Unlimited")
	var fps_vals: Array[int] = [30, 60, 120, 0]
	var fi := fps_vals.find(GameConfig.max_fps)
	fps_opt.selected = fi if fi >= 0 else 2
	fps_opt.item_selected.connect(func(idx: int) -> void:
		GameConfig.max_fps = fps_vals[idx]
		GameConfig.apply_display_and_audio()
		_mark_dirty())
	fps_row.add_child(fps_opt)

	var quality_row := _opt_row(vbox, "Quality", s)
	var quality_opt := OptionButton.new()
	UiStyle.style_option(quality_opt, s)
	var quality_ids: Array[String] = GraphicsQuality.TIERS   # ["low","medium","high","ultra","max"]
	for qid: String in quality_ids:
		quality_opt.add_item(qid.capitalize())
	var qi := quality_ids.find(GraphicsQuality.tier)
	quality_opt.selected = qi if qi >= 0 else 1
	quality_opt.item_selected.connect(func(idx: int) -> void: GraphicsQuality.set_tier(quality_ids[idx]))
	quality_row.add_child(quality_opt)

	# ── Lasers ────────────────────────────────────────────────────────────────
	# The slider runs one notch below zero, and that notch is AUTO: it follows
	# the quality tier, so a weak machine stays at the tier's count (0 on low)
	# unless the player deliberately asks for more. 0 is fully off.
	var laser_val := Label.new()
	var laser_text := func(v: int) -> String:
		if v < 0:
			return "Auto (%d)" % int(GraphicsQuality.get_setting("laser_fixtures", 14))
		return "Off" if v == 0 else str(v)
	laser_val.text = laser_text.call(GameConfig.laser_count)
	_opt_slider(vbox, "Trackside Lasers",
		float(GameConfig.LASER_COUNT_AUTO), float(GameConfig.LASER_COUNT_MAX), 1.0,
		float(GameConfig.laser_count), laser_val,
		func(v: float) -> void:
			GameConfig.laser_count = int(v)
			laser_val.text = laser_text.call(int(v))
			_mark_dirty(),
		s)

	_opt_toggle(vbox, "Advanced Lighting", GameConfig.advanced_lighting,
		func(on: bool) -> void: GameConfig.advanced_lighting = on; _mark_dirty(), s)

	var adv_note := Label.new()
	adv_note.text = "Reflections, ambient occlusion and indirect light, following the quality tier. Costs roughly a third of the frame rate on Ultra."
	adv_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	adv_note.add_theme_font_size_override("font_size", int(12 * s))
	adv_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.62, 1.0))
	vbox.add_child(adv_note)

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

	var save_btn := PlateButton.new()
	save_btn.text = "SAVE & BACK"
	save_btn.custom_minimum_size = Vector2(int(170 * s), int(48 * s))
	_style_btn(save_btn, s)
	save_btn.pressed.connect(_on_save_back)
	btn_row.add_child(save_btn)

	var back_btn := PlateButton.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(int(170 * s), int(48 * s))
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_options_back)
	btn_row.add_child(back_btn)

	# ── Navigation to second settings pages ───────────────────────────────────
	var nav_gap := Control.new()
	nav_gap.custom_minimum_size = Vector2(0, int(4 * s))
	vbox.add_child(nav_gap)

	var nav_btn := PlateButton.new()
	nav_btn.text = "GAMEPLAY  &  APPEARANCE  →"
	nav_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	nav_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(nav_btn, s)
	nav_btn.pressed.connect(_on_show_gameplay)
	vbox.add_child(nav_btn)

	var controls_btn := PlateButton.new()
	controls_btn.text = "CONTROLS  →"
	controls_btn.custom_minimum_size = Vector2(int(360 * s), int(46 * s))
	controls_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(controls_btn, s)
	controls_btn.pressed.connect(_on_show_controls)
	vbox.add_child(controls_btn)

	var htp_btn := PlateButton.new()
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
	gap.custom_minimum_size = Vector2(0, int(8 * s))
	parent.add_child(gap)
	var lbl: Label = UiStyle.label(text, UiStyle.caption(5.0), int(13 * s), Color.WHITE)
	lbl.self_modulate = Color(0.72, 0.50, 1.00)
	parent.add_child(lbl)


func _opt_row(parent: Node, label_text: String, s: float = 1.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", int(12 * s))
	parent.add_child(row)
	var lbl: Label = UiStyle.label(label_text, UiStyle.body(), int(16 * s), UiStyle.TEXT_DIM)
	lbl.custom_minimum_size = Vector2(210.0 * s, 0)
	lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
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
	UiStyle.style_slider(slider, s)
	val_lbl.custom_minimum_size  = Vector2(70.0 * s, 0)
	val_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_override("font", UiStyle.display(700))
	val_lbl.add_theme_font_size_override("font_size", int(14 * s))
	val_lbl.add_theme_color_override("font_color", UiStyle.CYAN)
	row.add_child(slider)
	row.add_child(val_lbl)


func _opt_toggle(parent: Node, label_text: String,
		init_state: bool, on_toggle: Callable,
		s: float = 1.0) -> void:
	var row := _opt_row(parent, label_text, s)
	var chk := PlateButton.new()
	chk.toggle_mode = true
	chk.button_pressed = init_state
	chk.custom_minimum_size = Vector2(96 * s, 0)
	chk.add_theme_font_size_override("font_size", int(13 * s))
	chk.set_padding(14.0 * s, 7.0 * s)
	var apply := func(on: bool) -> void:
		chk.text = "ON" if on else "OFF"
		chk.set_accent(UiStyle.CYAN if on else UiStyle.VIOLET)
		chk.set_highlight(on)
	apply.call(init_state)
	chk.toggled.connect(func(on: bool) -> void:
		apply.call(on)
		on_toggle.call(on))
	row.add_child(chk)


func _opt_color(parent: Node, label_text: String,
		init_color: Color, on_change: Callable,
		s: float = 1.0) -> void:
	var row := _opt_row(parent, label_text, s)
	var cpb := ColorPickerButton.new()
	cpb.color = init_color
	cpb.custom_minimum_size = Vector2(int(80 * s), int(34 * s))
	cpb.color_changed.connect(on_change)
	# The picker popup opens with no focus owner, so on keyboard or gamepad it
	# was a dead window you could only close again. Hand focus to its first
	# slider on open (left/right then adjust it) and back to the swatch on close.
	var pop: Popup = cpb.get_popup()
	if pop != null:
		pop.about_to_popup.connect(func() -> void:
			_focus_picker.call_deferred(cpb.get_picker()))
		pop.popup_hide.connect(func() -> void:
			if cpb.is_inside_tree():
				cpb.grab_focus())
	row.add_child(cpb)


# ── Gameplay & Appearance panel ────────────────────────────────────────────────

func _build_gameplay_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PlatePanel.create(int(42 * s), UiStyle.VIOLET, 26.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	panel.content.add_child(vbox)

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
		func(c: Color) -> void: GameConfig.jacket_color = c; _mark_dirty(), s)
	_opt_color(vbox, "Fur Color", GameConfig.fur_color,
		func(c: Color) -> void: GameConfig.fur_color = c; _mark_dirty(), s)
	_opt_color(vbox, "Hair Color", GameConfig.hair_color,
		func(c: Color) -> void: GameConfig.hair_color = c; _mark_dirty(), s)

	# ── LEVEL COLORS ──────────────────────────────────────────────────────────
	_opt_section(vbox, "LEVEL COLORS", s)
	_opt_color(vbox, "Left Gate Color  (pink)", GameConfig.level_color_a,
		func(c: Color) -> void: GameConfig.level_color_a = c; _mark_dirty(), s)
	_opt_color(vbox, "Right Gate Color  (blue)", GameConfig.level_color_b,
		func(c: Color) -> void: GameConfig.level_color_b = c; _mark_dirty(), s)
	_opt_color(vbox, "Jump Gate Color  (green)", GameConfig.level_color_jump,
		func(c: Color) -> void: GameConfig.level_color_jump = c; _mark_dirty(), s)
	_opt_color(vbox, "Slide Gate Color  (teal)", GameConfig.level_color_slide,
		func(c: Color) -> void: GameConfig.level_color_slide = c; _mark_dirty(), s)
	_opt_color(vbox, "Grind Rail Color  (orange)", GameConfig.level_color_rail,
		func(c: Color) -> void: GameConfig.level_color_rail = c; _mark_dirty(), s)
	_opt_color(vbox, "Floor Color", GameConfig.floor_color,
		func(c: Color) -> void: GameConfig.floor_color = c; _mark_dirty(), s)
	_opt_toggle(vbox, "Color Cycle", GameConfig.color_cycle_enabled,
		func(on: bool) -> void: GameConfig.color_cycle_enabled = on; _mark_dirty(), s)

	var cycle_speed_val := Label.new()
	cycle_speed_val.text = "%.1fs" % GameConfig.color_cycle_period_s
	_opt_slider(vbox, "Color Cycle Speed  (sec/color — lower = faster)",
		0.2, 5.0, 0.1, GameConfig.color_cycle_period_s, cycle_speed_val,
		func(v: float) -> void:
			GameConfig.color_cycle_period_s = v
			cycle_speed_val.text = "%.1fs" % v
			_mark_dirty(), s)

	# ── CYCLE AFFECTS ─────────────────────────────────────────────────────────
	_opt_section(vbox, "COLOR CYCLE AFFECTS", s)
	_opt_toggle(vbox, "Gates",      GameConfig.color_cycle_affects_gates,
		func(on: bool) -> void: GameConfig.color_cycle_affects_gates  = on; _mark_dirty(), s)
	_opt_toggle(vbox, "Halos",      GameConfig.color_cycle_affects_halos,
		func(on: bool) -> void: GameConfig.color_cycle_affects_halos  = on; _mark_dirty(), s)
	_opt_toggle(vbox, "Floor",      GameConfig.color_cycle_affects_floor,
		func(on: bool) -> void: GameConfig.color_cycle_affects_floor  = on; _mark_dirty(), s)
	_opt_toggle(vbox, "World Deco", GameConfig.color_cycle_affects_world,
		func(on: bool) -> void: GameConfig.color_cycle_affects_world  = on; _mark_dirty(), s)
	_opt_toggle(vbox, "Grind Rail", GameConfig.color_cycle_affects_rail,
		func(on: bool) -> void: GameConfig.color_cycle_affects_rail   = on; _mark_dirty(), s)

	# ── GAMEPLAY ──────────────────────────────────────────────────────────────
	_opt_section(vbox, "GAMEPLAY", s)
	_opt_toggle(vbox, "Wall Jumps", GameConfig.wall_jumps_enabled,
		func(on: bool) -> void: GameConfig.wall_jumps_enabled = on; _mark_dirty(), s)

	var lives_val := Label.new()
	lives_val.text = "%d" % GameConfig.lives_per_song
	_opt_slider(vbox, "Lives per Song", 1.0, 5.0, 1.0,
		float(GameConfig.lives_per_song), lives_val,
		func(v: float) -> void:
			GameConfig.lives_per_song = int(v)
			Run.song_lives = int(v)
			lives_val.text = "%d" % int(v)
			_mark_dirty(), s)

	var gate_val := Label.new()
	gate_val.text = "%.1f" % GameConfig.gate_preview_beats
	_opt_slider(vbox, "Gate Preview (beats)", 1.0, 20.0, 0.5,
		GameConfig.gate_preview_beats, gate_val,
		func(v: float) -> void:
			GameConfig.gate_preview_beats = v
			gate_val.text = "%.1f" % v
			_mark_dirty(), s)

	# ── HALO ─────────────────────────────────────────────────────────────────
	_opt_section(vbox, "HALO", s)

	# Halo shape picker removed — circle is the only shape that was ever finished,
	# and the dropdown's fallback selected "Star" while the config still said
	# "circle", so it reported a shape the game was not drawing.

	var halo_val := Label.new()
	halo_val.text = "%.1f" % GameConfig.halo_size
	_opt_slider(vbox, "Size", 2.0, 12.0, 0.2,
		GameConfig.halo_size, halo_val,
		func(v: float) -> void:
			GameConfig.halo_size = v
			halo_val.text = "%.1f" % v
			_mark_dirty(), s)

	_opt_toggle(vbox, "Dual Color", GameConfig.halo_dual_color,
		func(on: bool) -> void: GameConfig.halo_dual_color = on; _mark_dirty(), s)
	_opt_color(vbox, "Halo Color A", GameConfig.halo_color_a,
		func(c: Color) -> void: GameConfig.halo_color_a = c; _mark_dirty(), s)
	_opt_color(vbox, "Halo Color B", GameConfig.halo_color_b,
		func(c: Color) -> void: GameConfig.halo_color_b = c; _mark_dirty(), s)

	# ── Buttons ───────────────────────────────────────────────────────────────
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(btn_row)

	var reset_btn := PlateButton.new()
	reset_btn.text = "RESET DEFAULTS"
	reset_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(reset_btn, s)
	reset_btn.pressed.connect(_on_gameplay_reset)
	btn_row.add_child(reset_btn)

	var back_btn := PlateButton.new()
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

	var panel := PlatePanel.create(int(42 * s), UiStyle.VIOLET, 26.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(16 * s))
	panel.content.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "CONTROLS"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_override("font", UiStyle.caption(7.0))
	ttl.add_theme_font_size_override("font_size", int(26 * s))
	ttl.add_theme_color_override("font_color", Color.WHITE)
	ttl.self_modulate = UiStyle.signature_color(0.1)
	vbox.add_child(ttl)
	vbox.add_child(_rule(s))

	var note := Label.new()
	note.text = "Click a key or button, then press the new one. Escape cancels. Changes apply immediately and How To Play updates to match."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", int(13 * s))
	note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.72, 1.0))
	vbox.add_child(note)

	_opt_section(vbox, "KEYBOARD  /  GAMEPAD", s)

	for action: String in GameConfig.REBINDABLE_ACTIONS:
		var row := _opt_row(vbox, GameConfig.ACTION_LABELS.get(action, action), s)

		var key_btn := PlateButton.new()
		key_btn.custom_minimum_size = Vector2(int(120 * s), int(36 * s))
		key_btn.text = GameConfig.key_name(action)
		_style_btn(key_btn, s)
		key_btn.pressed.connect(func() -> void: _start_bind_capture(action, "key", key_btn))
		row.add_child(key_btn)

		var joy_btn := PlateButton.new()
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

	var reset_btn := PlateButton.new()
	reset_btn.text = "RESET DEFAULTS"
	reset_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	_style_btn(reset_btn, s)
	reset_btn.pressed.connect(_on_controls_reset)
	btn_row.add_child(reset_btn)

	var back_btn := PlateButton.new()
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

	# Stick and trigger wobble is not a bind — swallow it so a resting thumb
	# doesn't scroll the panel out from under the capture. Mouse clicks are
	# deliberately left alone: clicking another chip retargets the capture and
	# clicking BACK cancels it, which is the only way out without a keyboard.
	if event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()


func _on_controls_reset() -> void:
	GameConfig.reset_controls_to_default()
	_controls_panel.queue_free()
	_controls_panel = _build_controls_panel()
	_controls_panel.visible = true
	add_child(_controls_panel)
	_focus_panel.call_deferred(_controls_panel)


# ── How To Play panel ─────────────────────────────────────────────────────────

func _build_howtoplay_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PlatePanel.create(int(50 * s), UiStyle.VIOLET, 30.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w_wide(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(18 * s))
	panel.content.add_child(vbox)

	# Title
	var ttl := Label.new()
	ttl.text = "HOW TO PLAY"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_override("font", UiStyle.caption(7.0))
	ttl.add_theme_font_size_override("font_size", int(26 * s))
	ttl.add_theme_color_override("font_color", Color.WHITE)
	ttl.self_modulate = UiStyle.signature_color(0.1)
	vbox.add_child(ttl)
	vbox.add_child(_rule(s))

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
	_htp_row(sc, "Gate hit",             "+500 pts × combo multiplier  (+1000 in electric zones)", s)
	_htp_row(sc, "Combo multiplier",     "×2 at 10 streak  ·  ×3 at 20  ·  ×4 at 30", s)
	_htp_row(sc, "Health (starts 25 %)", "+1 % per hit    –10 % per miss    → 0 % = fail", s)
	_htp_row(sc, "Letter grade",         "S / A / B / C / D / F  based on accuracy %", s)

	# Back button
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var back_btn := PlateButton.new()
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


# ── Play panel ─────────────────────────────────────────────────────────────────

## NEW GAME / CONTINUE are the story-mode entries and stay locked until story
## mode exists; FREEPLAY is the one live route and goes to song select.
func _build_play_panel() -> Control:
	var s   := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.92))
	var bg:      Control = arr[0]
	var wrapper: Control = arr[1]

	var panel := PlatePanel.create(int(42 * s), UiStyle.VIOLET, 26.0 * s)
	panel.custom_minimum_size = Vector2(_panel_w(), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(14 * s))
	panel.content.add_child(vbox)

	var ttl := Label.new()
	ttl.text = "PLAY"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_override("font", UiStyle.caption(7.0))
	ttl.add_theme_font_size_override("font_size", int(26 * s))
	ttl.add_theme_color_override("font_color", Color.WHITE)
	ttl.self_modulate = UiStyle.signature_color(0.1)
	vbox.add_child(ttl)
	vbox.add_child(_rule(s))

	var new_btn := _menu_btn("NEW GAME", _on_new_game, s)
	new_btn.disabled = true
	vbox.add_child(new_btn)

	var cont_btn := _menu_btn("CONTINUE", _on_continue, s)
	cont_btn.disabled = true
	vbox.add_child(cont_btn)

	var lock := Label.new()
	lock.text = "🔒  Story mode is still in development — it lands in a later update."
	lock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lock.add_theme_font_size_override("font_size", int(15 * s))
	lock.add_theme_color_override("font_color", Color(0.78, 0.70, 0.95, 0.85))
	vbox.add_child(lock)

	vbox.add_child(_rule(s))

	vbox.add_child(_menu_btn("FREEPLAY", _on_freeplay, s))

	var free_note := Label.new()
	free_note.text = "Pick any track and play it straight."
	free_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	free_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	free_note.add_theme_font_size_override("font_size", int(15 * s))
	free_note.add_theme_color_override("font_color", Color(0.78, 0.78, 0.90, 1.0))
	vbox.add_child(free_note)

	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, int(6 * s))
	vbox.add_child(sp)

	var back_btn := PlateButton.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(int(185 * s), int(48 * s))
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_btn(back_btn, s)
	back_btn.pressed.connect(_on_play_back)
	vbox.add_child(back_btn)

	return bg


# ── Button handlers ────────────────────────────────────────────────────────────

func _on_play() -> void:
	_push_focus()
	_center_container.visible = false
	_play_panel.visible       = true
	_focus_panel.call_deferred(_play_panel)

func _on_play_back() -> void:
	_play_panel.visible       = false
	_center_container.visible = true
	_pop_focus(_center_container)

func _on_freeplay() -> void:
	# Tutorial is a one-time, first-launch-only screen: once any song has a
	# registered high score, the player has already played, so skip straight
	# to song select on every later launch.
	if Save.has_any_high_score():
		get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/HowToPlay.tscn")

func _on_new_game() -> void:
	pass  # Story mode — locked until it exists

func _on_continue() -> void:
	pass  # Story mode — locked until it exists

func _on_options() -> void:
	_push_focus()
	_center_container.visible = false
	_options_panel.visible    = true
	_focus_panel.call_deferred(_options_panel)

func _on_quit() -> void:
	get_tree().quit()

## Ctrl+Alt+D — reveals (or re-hides) the dev entries in the main menu: the
## chart-authoring MAPPER, and the Story Mode map prototype. Session-only;
## doesn't persist to disk. Only affects visibility of the buttons themselves,
## nothing else in the menu.
##
## The story map lives here rather than on PLAY > NEW GAME on purpose: NEW GAME
## and CONTINUE stay disabled until story mode actually exists, and this is a
## prototype of the level-select screen, not a way into a story run.
func _toggle_dev_mapper_entry() -> void:
	_dev_unlocked = not _dev_unlocked
	if _dev_unlocked:
		if _mapper_btn == null and _menu_box != null:
			var s := _ui_s()
			_mapper_btn = _menu_btn("MAPPER", _on_open_mapper, s)
			_menu_box.add_child(_mapper_btn)
			_menu_box.move_child(_mapper_btn, _menu_box.get_child_count() - 2)   # just above QUIT
			_story_map_btn = _menu_btn("STORY MAP (WIP)", _on_open_story_map, s)
			_menu_box.add_child(_story_map_btn)
			_menu_box.move_child(_story_map_btn, _menu_box.get_child_count() - 2)
			_rewrap_menu()
	else:
		if _mapper_btn != null:
			_mapper_btn.queue_free()
			_mapper_btn = null
		if _story_map_btn != null:
			_story_map_btn.queue_free()
			_story_map_btn = null
		_rewrap_menu.call_deferred()   # after queue_free actually removes it

func _on_open_mapper() -> void:
	get_tree().change_scene_to_file("res://tools/ManualMapper.tscn")

func _on_open_story_map() -> void:
	get_tree().change_scene_to_file("res://scenes/story/StoryMap.tscn")

func _on_save_back() -> void:
	Save.sync_from_run()
	GameConfig.save()
	_settings_dirty = false
	_close_options()


## Any control that writes to GameConfig calls this. GameConfig only reaches disk
## through save(), so without a flag the player could edit half the options page,
## press Escape, and lose the lot with no indication anything had happened.
func _mark_dirty() -> void:
	_settings_dirty = true


## Leaving the options tree. With pending edits this asks first; SAVE & BACK
## clears the flag, so the prompt only ever appears when there is really
## something to lose.
func _on_options_back() -> void:
	if _settings_dirty:
		_show_unsaved_prompt()
		return
	_close_options()


## The actual teardown, once the unsaved question (if any) is answered.
func _close_options() -> void:
	_options_panel.visible    = false
	if _gameplay_panel != null:
		_gameplay_panel.visible = false
	if _controls_panel != null:
		_controls_panel.visible = false
	_howtoplay_panel.visible  = false
	_center_container.visible = true
	_pop_focus(_menu_box)


## "You have unsaved changes" — Save / Discard / Cancel, built on the same
## plate kit as everything else rather than a themeless ConfirmationDialog.
func _show_unsaved_prompt() -> void:
	if _confirm_panel != null:
		return
	var s := _ui_s()
	var arr := _panel_bg(Color(0.02, 0.01, 0.10, 0.96))
	_confirm_panel = arr[0]
	var wrapper: Control = arr[1]

	var panel := PlatePanel.create(int(34 * s), Color(1.00, 0.52, 0.16), 26.0 * s)
	panel.custom_minimum_size = Vector2(int(560 * s), 0)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	panel.content.add_child(vbox)

	var ttl := Label.new()
	ttl.text = "UNSAVED CHANGES"
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.add_theme_font_override("font", UiStyle.caption(6.0))
	ttl.add_theme_font_size_override("font_size", int(26 * s))
	ttl.add_theme_color_override("font_color", Color(1.00, 0.72, 0.30))
	vbox.add_child(ttl)

	var body := Label.new()
	body.text = "Your settings changes have not been written to disk yet. Leaving now discards them."
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_theme_font_size_override("font_size", int(14 * s))
	body.add_theme_color_override("font_color", Color(0.72, 0.68, 0.86))
	vbox.add_child(body)

	vbox.add_child(_rule(s))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(14 * s))
	vbox.add_child(row)

	var save_btn := PlateButton.new()
	save_btn.text = "SAVE & LEAVE"
	save_btn.custom_minimum_size = Vector2(int(190 * s), int(48 * s))
	_style_btn(save_btn, s)
	save_btn.pressed.connect(func() -> void:
		_dismiss_unsaved_prompt()
		_on_save_back())
	row.add_child(save_btn)

	var discard_btn := PlateButton.new()
	discard_btn.text = "DISCARD"
	discard_btn.custom_minimum_size = Vector2(int(160 * s), int(48 * s))
	_style_btn(discard_btn, s)
	discard_btn.pressed.connect(func() -> void:
		# Re-read from disk so the in-memory config actually goes back to the
		# saved state — the live values were already mutated on every keystroke.
		GameConfig.load_from_disk()
		_settings_dirty = false
		_rebuild_settings_panels()
		_dismiss_unsaved_prompt()
		_close_options())
	row.add_child(discard_btn)

	var cancel_btn := PlateButton.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(int(160 * s), int(48 * s))
	_style_btn(cancel_btn, s)
	cancel_btn.pressed.connect(_dismiss_unsaved_prompt)
	row.add_child(cancel_btn)

	add_child(_confirm_panel)
	_focus_panel.call_deferred(_confirm_panel)


func _dismiss_unsaved_prompt() -> void:
	if _confirm_panel == null:
		return
	_confirm_panel.queue_free()
	_confirm_panel = null
	_focus_panel.call_deferred(_options_panel)


## Throws away the cached settings pages so they rebuild against whatever
## GameConfig now holds. Used after a DISCARD reloads the saved values.
func _rebuild_settings_panels() -> void:
	if _gameplay_panel != null:
		_gameplay_panel.queue_free()
		_gameplay_panel = null
	if _controls_panel != null:
		_controls_panel.queue_free()
		_controls_panel = null
	_options_panel.queue_free()
	_options_panel = _build_options_panel()
	_options_panel.visible = false
	add_child(_options_panel)


## Opens the latency calibrator over the main menu. Same component the pause
## menu uses; Main is not paused, so nothing needs process-mode juggling.
func _on_calibrate_audio() -> void:
	if _options_panel != null:
		_options_panel.visible = false
	var cal: Node = load("res://scripts/AudioCalibrator.gd").new()
	var reopen := func(_a: Variant = null) -> void:
		if _options_panel != null:
			_options_panel.visible = true
			_focus_panel.call_deferred(_options_panel)
	cal.calibration_complete.connect(reopen)
	cal.calibration_cancelled.connect(reopen)
	add_child(cal)

func _on_show_gameplay() -> void:
	_push_focus()
	_options_panel.visible = false
	if _gameplay_panel == null:
		_gameplay_panel = _build_gameplay_panel()
		add_child(_gameplay_panel)
	_gameplay_panel.visible = true
	_focus_panel.call_deferred(_gameplay_panel)

func _on_gameplay_back() -> void:
	_gameplay_panel.visible = false
	_options_panel.visible  = true
	_pop_focus(_options_panel)

func _on_show_controls() -> void:
	_push_focus()
	_options_panel.visible = false
	if _controls_panel == null:
		_controls_panel = _build_controls_panel()
		add_child(_controls_panel)
	_controls_panel.visible = true
	_focus_panel.call_deferred(_controls_panel)

func _on_controls_back() -> void:
	_awaiting_bind = {}
	_controls_panel.visible = false
	_options_panel.visible  = true
	_pop_focus(_options_panel)

func _on_show_howtoplay() -> void:
	_push_focus()
	_options_panel.visible = false
	# Rebuilt on every open so it always reflects the latest control bindings
	# (the player may have just rebound something in the Controls tab).
	_howtoplay_panel.queue_free()
	_howtoplay_panel = _build_howtoplay_panel()
	_howtoplay_panel.visible = true
	add_child(_howtoplay_panel)
	_focus_panel.call_deferred(_howtoplay_panel)

func _on_howtoplay_back() -> void:
	_howtoplay_panel.visible = false
	_options_panel.visible   = true
	_pop_focus(_options_panel)

func _on_gameplay_reset() -> void:
	GameConfig.reset_defaults()
	GameConfig.apply_display_and_audio()
	_mark_dirty()
	# Rebuild panel so colour swatches reflect the new values
	_gameplay_panel.queue_free()
	_gameplay_panel = _build_gameplay_panel()
	_gameplay_panel.visible = true
	add_child(_gameplay_panel)
	# The old panel (and the focused button on it) is gone — put focus back on
	# the fresh one or up/down stops responding.
	_focus_panel.call_deferred(_gameplay_panel)


## Rebind capture runs here, ahead of the GUI, because `_unhandled_input` only
## sees what focus traversal did not eat: arrow keys, Enter and the gamepad face
## buttons were all being swallowed by the focused rebind button, so those keys
## could never actually be bound.
func _input(event: InputEvent) -> void:
	if _awaiting_bind.is_empty():
		return
	_handle_bind_capture(event)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).is_echo():
		var k := event as InputEventKey
		if k.physical_keycode == KEY_D and k.ctrl_pressed and k.alt_pressed:
			get_viewport().set_input_as_handled()
			_toggle_dev_mapper_entry()
			return

	if not _awaiting_bind.is_empty():
		return
	if not event.is_action_pressed("ui_cancel"):
		return
	if _confirm_panel != null:
		get_viewport().set_input_as_handled()
		_dismiss_unsaved_prompt()
	elif _howtoplay_panel != null and _howtoplay_panel.visible:
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
	elif _play_panel != null and _play_panel.visible:
		get_viewport().set_input_as_handled()
		_on_play_back()
