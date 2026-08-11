extends Control
## Pre-game warning screens — photosensitivity, then headset recommendation.
## Boot.gd routes here before Main.tscn. Each screen is locked for LOCK_S
## seconds (no way to skip — click/key/auto-advance all do nothing until
## then), then a click, Enter/Space, or gamepad confirm advances early;
## otherwise it auto-advances at AUTO_S seconds. The last screen hands off
## to Main.tscn. Full-bleed image, same cover-fit treatment as Main's
## background — no card, no button, the image is the whole screen.

const LOCK_S: float = 3.0
const AUTO_S: float = 7.0

var _screens: Array[String] = [
	"res://Graphics/Epilepsy_warning.png",
	"res://Graphics/Headset_recommended.jpg",
]

var _idx: int = 0
var _t: float = 0.0
var _can_continue: bool = false

var _img_rect: TextureRect


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_show_screen(0)


func _process(delta: float) -> void:
	_t += delta
	if not _can_continue and _t >= LOCK_S:
		_can_continue = true
	if _t >= AUTO_S:
		_advance()


func _unhandled_input(event: InputEvent) -> void:
	if not _can_continue:
		return
	if event.is_action_pressed("ui_accept") or (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		get_viewport().set_input_as_handled()
		_advance()


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Same full-bleed cover-fit treatment as Main.tscn's background image.
	_img_rect = TextureRect.new()
	_img_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_img_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	add_child(_img_rect)


func _show_screen(i: int) -> void:
	_idx          = i
	_t            = 0.0
	_can_continue = false
	_img_rect.texture = load(_screens[i])


func _advance() -> void:
	if _idx + 1 < _screens.size():
		_show_screen(_idx + 1)
	else:
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
