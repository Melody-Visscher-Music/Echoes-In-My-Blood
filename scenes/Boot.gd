extends Node
class_name Boot
func _ready():
	_init_input_map()
	if Run.run_seed == 0:
		Run.start_new_run(Time.get_ticks_msec(), "Runner")
	call_deferred("_goto_main")
func _goto_main():
	# Warnings.tscn shows the photosensitivity + headset screens first,
	# then hands off to Main.tscn itself once both have been seen.
	get_tree().change_scene_to_file("res://scenes/Warnings.tscn")
func _init_input_map():
	_add_action_once("dash", KEY_SHIFT)
	_add_action_once("interact", KEY_E)
	_add_move_map()
	_add_action_once("toggle_mouse", KEY_TAB)
	_add_action_once("pause", KEY_ESCAPE)
	_add_action_once("lane_0", KEY_A)
	_add_action_once("lane_1", KEY_S)
	_add_action_once("lane_2", KEY_K)
	_add_action_once("lane_3", KEY_L)
func _add_move_map():
	_add_action_once("move_forward", KEY_W)
	_add_action_once("move_back", KEY_S)
	_add_action_once("move_left", KEY_A)
	_add_action_once("move_right", KEY_D)
	_add_action_once("jump", KEY_SPACE)
func _add_action_once(action_name, keycode):
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	var ev = InputEventKey.new()
	ev.physical_keycode = keycode
	var list = InputMap.action_get_events(action_name)
	var exists = false
	for e in list:
		var k = e as InputEventKey
		if k != null and k.physical_keycode == keycode:
			exists = true
	if not exists:
		InputMap.action_add_event(action_name, ev)
