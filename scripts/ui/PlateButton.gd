class_name PlateButton
extends Button

## A menu button wearing the same chamfered neon chassis as the gameplay HUD.
##
## Deliberately a Button subclass rather than a wrapper Control: it drops into
## every container the old plain Buttons lived in and keeps `text`, `pressed`,
## `disabled`, focus traversal and keyboard/gamepad navigation for free, so no
## call site has to change shape.
##
## The chassis is a ColorRect child running hud_plate.gdshader with
## show_behind_parent set — see PlateChassis.make_plate(). The Button's own five
## styleboxes are replaced with StyleBoxEmpty so only the shader draws; content
## margins move onto that empty box, since the shader has no concept of padding.

## Accent colour for the resting edge. Set before the node enters the tree, or
## call refresh() afterwards.
var accent: Color = UiStyle.PINK

var _plate: ColorRect = null
var _hovered: bool = false
## Forced lit state, for menus that drive their own selection index instead of
## using Godot's focus system (the pause, death and results overlays all do —
## they handle ui_up/ui_down themselves, so real focus would move twice).
var _highlight: bool = false
var _pad_h: float = 26.0
var _pad_v: float = 13.0


func _init(btn_text: String = "") -> void:
	text = btn_text


static func create(btn_text: String, on_pressed: Callable = Callable(),
		font_size: int = 22, accent_col: Color = UiStyle.PINK) -> PlateButton:
	var b := PlateButton.new(btn_text)
	b.accent = accent_col
	b.add_theme_font_size_override("font_size", font_size)
	if on_pressed.is_valid():
		b.pressed.connect(on_pressed)
	return b


func _ready() -> void:
	_plate = PlateChassis.make_plate(14.0, true)
	add_child(_plate)

	_clear_styleboxes()
	add_theme_color_override("font_color",          UiStyle.TEXT_DIM)
	add_theme_color_override("font_hover_color",    Color(1.00, 0.92, 1.00))
	add_theme_color_override("font_focus_color",    Color(1.00, 0.92, 1.00))
	add_theme_color_override("font_pressed_color",  Color.WHITE)
	add_theme_color_override("font_disabled_color", Color(0.45, 0.40, 0.58, 0.60))
	add_theme_font_override("font", UiStyle.caption(2.5))

	mouse_entered.connect(func() -> void: _hovered = true;  refresh())
	mouse_exited.connect(func() -> void:  _hovered = false; refresh())
	focus_entered.connect(refresh)
	focus_exited.connect(refresh)
	button_down.connect(refresh)
	button_up.connect(refresh)
	resized.connect(_on_resized)

	_on_resized()
	refresh()


## Empty boxes rather than transparent flat ones: a StyleBoxFlat would still cost
## a draw call and could bleed a 1px edge over the shader's own outline. The
## content margins have to live here because the shader draws no padding.
func _clear_styleboxes() -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxEmpty.new()
		sb.content_margin_left   = _pad_h
		sb.content_margin_right  = _pad_h
		sb.content_margin_top    = _pad_v
		sb.content_margin_bottom = _pad_v
		add_theme_stylebox_override(state, sb)


## Content padding. Needed because the shader draws no padding of its own, so
## the empty styleboxes are the only thing holding the label off the chamfer.
## Small in-panel controls (key rebind chips) want much less than a menu entry.
func set_padding(h: float, v: float) -> void:
	_pad_h = h
	_pad_v = v
	if _plate != null:
		_clear_styleboxes()


func _on_resized() -> void:
	PlateChassis.resize(_plate, size)


## Recomputes the chassis state. Safe to call at any time — used by callers that
## drive a button's look from something other than input, e.g. song select's
## mode row marking the active mode.
func refresh() -> void:
	if _plate == null:
		return
	var state: int = PlateChassis.State.NORMAL
	if disabled:
		state = PlateChassis.State.DISABLED
	elif is_pressed():
		state = PlateChassis.State.PRESSED
	elif _highlight or _hovered or has_focus():
		state = PlateChassis.State.HOVER
	PlateChassis.apply_state(_plate, state, accent)
	# The label has to brighten with the plate; font_hover_color only applies to
	# real mouse hover, which a driven selection never triggers.
	self_modulate = Color(1.25, 1.15, 1.30) if state == PlateChassis.State.HOVER else Color.WHITE


func set_accent(col: Color) -> void:
	accent = col
	refresh()


## Drive the lit state directly. Pair with `focus_mode = FOCUS_NONE` so Godot's
## own focus navigation doesn't fight the caller's selection index.
func set_highlight(on: bool) -> void:
	if _highlight == on:
		return
	_highlight = on
	refresh()


## Which corners are chamfered, as [top-left, top-right, bottom-right,
## bottom-left]. Lets a row of buttons vary its silhouette instead of repeating
## one shape five times down a column.
func set_cuts(tl: float, tr: float, br: float, bl: float) -> void:
	PlateChassis.set_param(_plate, "cut_tl", tl)
	PlateChassis.set_param(_plate, "cut_tr", tr)
	PlateChassis.set_param(_plate, "cut_br", br)
	PlateChassis.set_param(_plate, "cut_bl", bl)
