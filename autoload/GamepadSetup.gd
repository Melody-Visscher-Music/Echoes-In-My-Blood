# res://autoload/GamepadSetup.gd
extends Node
# Final mapping — left-to-right across the shoulder buttons and triggers:
# lane_0 = LB (left shoulder)
# lane_1 = LT (left trigger)
# lane_2 = RT (right trigger)
# lane_3 = RB (right shoulder)
# (The lane_1/lane_2 comments used to say RT/LT, i.e. the opposite of what the
#  code below actually binds. The bindings were right; the labels were not.)

const DEADZONE_LT := 0.45
const DEADZONE_RT := 0.45

func _ready() -> void:
	# Ensure actions exist
	for a in ["lane_0", "lane_1", "lane_2", "lane_3", "rhythm_pause", "ui_cancel"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)



	_ensure_button("lane_0", JOY_BUTTON_LEFT_SHOULDER)  # LB -> lane 0
	_ensure_button("lane_3", JOY_BUTTON_RIGHT_SHOULDER) # RB -> lane 3

	# --- Triggers stay the same (just ensure they exist) ---
	_ensure_trigger("lane_1", JOY_AXIS_TRIGGER_LEFT,  DEADZONE_LT) # LT -> lane 1
	_ensure_trigger("lane_2", JOY_AXIS_TRIGGER_RIGHT, DEADZONE_RT) # RT -> lane 2

	# Back/cancel. Godot's built-in `ui_cancel` is Escape and nothing else — it
	# ships no joypad event, unlike ui_left/ui_right which do carry the D-pad.
	# So gamepad B did nothing on every menu in the game, including the pause
	# menu that already had a comment claiming B backed out of it. One binding
	# here fixes all of them at once, since every screen already asks for
	# `ui_cancel` rather than reading the button itself.
	#
	# B is also `runner_slide` during play. That is not a conflict: an event can
	# feed two actions, and no screen listens for `ui_cancel` while the player is
	# actually running — the runner only checks it on the pause, death and end
	# screens, where sliding is not happening.
	_ensure_button("ui_cancel", JOY_BUTTON_B)

	# Optional: Start -> pause
	var start_btn := InputEventJoypadButton.new()
	start_btn.button_index = JOY_BUTTON_START
	InputMap.action_add_event("rhythm_pause", start_btn)

	print("[GamepadSetup] Shoulders bound: LB/LT/RT/RB -> lanes 0/1/2/3; B -> ui_cancel")

func _ensure_button(action: String, btn: int) -> void:
	for e in InputMap.action_get_events(action):
		var jb := e as InputEventJoypadButton
		if jb and jb.button_index == btn:
			return
	var add := InputEventJoypadButton.new()
	add.button_index = btn as JoyButton
	InputMap.action_add_event(action, add)

func _remove_button(action: String, btn: int) -> void:
	for e in InputMap.action_get_events(action):
		var jb := e as InputEventJoypadButton
		if jb and jb.button_index == btn:
			InputMap.action_erase_event(action, e)

func _ensure_trigger(action: String, axis: int, dz: float) -> void:
	# check if already mapped
	for e in InputMap.action_get_events(action):
		var jm := e as InputEventJoypadMotion
		if jm and jm.axis == axis and jm.axis_value == 1.0:
			InputMap.action_set_deadzone(action, dz)
			return
	var add := InputEventJoypadMotion.new()
	add.axis = axis as JoyAxis
	add.axis_value = 1.0
	InputMap.action_add_event(action, add)
	InputMap.action_set_deadzone(action, dz)
