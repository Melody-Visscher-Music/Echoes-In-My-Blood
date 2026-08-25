class_name PlatePanel
extends Control

## A chamfered neon card. The menu-side counterpart to the gameplay HUD's
## plates: same shader, same silhouette, same colour band.
##
## Add children to `content` (a MarginContainer), not to the panel itself — the
## plate is a sibling that must stay full-rect and unmanaged.
##
## Sizing: the panel takes its height from `content`, so a card grows with its
## own text rather than needing a hardcoded height per use site.

var content: MarginContainer = null
var accent: Color = UiStyle.VIOLET

var _plate: ColorRect = null
var _margin: int = 20
var _cut: float = 20.0


## Builds immediately rather than waiting for _ready(), so callers can fill in
## `content` straight after creating the panel and before adding it to the tree.
static func create(margin_px: int = 20, accent_col: Color = UiStyle.VIOLET,
		cut_size: float = 20.0) -> PlatePanel:
	var p := PlatePanel.new()
	p._margin = margin_px
	p.accent  = accent_col
	p._cut    = cut_size
	p._build()
	return p


func _ready() -> void:
	_build()   # covers a bare PlatePanel.new() that skipped the factory


func _build() -> void:
	if content != null:
		return
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Not show_behind_parent here: a plain Control draws nothing of its own, so
	# normal sibling order already puts the plate under the content.
	_plate = PlateChassis.make_plate(_cut, false)
	add_child(_plate)

	content = MarginContainer.new()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("margin_left",   _margin)
	content.add_theme_constant_override("margin_right",  _margin)
	content.add_theme_constant_override("margin_top",    _margin)
	content.add_theme_constant_override("margin_bottom", _margin)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(content)

	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	_on_resized()
	set_accent(accent)


func _on_resized() -> void:
	PlateChassis.resize(_plate, size)


## The panel is a bare Control, so it has no minimum size of its own — without
## this a card in a VBoxContainer would collapse to zero height and the plate
## would draw as a sliver.
func _get_minimum_size() -> Vector2:
	if content == null:
		return Vector2.ZERO
	return content.get_combined_minimum_size()


func set_accent(col: Color) -> void:
	accent = col
	PlateChassis.apply_state(_plate, PlateChassis.State.NORMAL, accent)


## Lit state, for a selected song card or the active mode in a row.
func set_selected(sel: bool) -> void:
	PlateChassis.apply_state(_plate,
		PlateChassis.State.HOVER if sel else PlateChassis.State.NORMAL, accent)


func set_cuts(tl: float, tr: float, br: float, bl: float) -> void:
	PlateChassis.set_param(_plate, "cut_tl", tl)
	PlateChassis.set_param(_plate, "cut_tr", tr)
	PlateChassis.set_param(_plate, "cut_br", br)
	PlateChassis.set_param(_plate, "cut_bl", bl)


func set_param(name: String, value: Variant) -> void:
	PlateChassis.set_param(_plate, name, value)
