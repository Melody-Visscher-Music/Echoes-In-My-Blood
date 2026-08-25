extends Node
## Persistent gameplay & appearance settings.
## All values are applied at game-scene start (BeatRunnerPlayer, Section_BeatRunner3d).
## Call save() to write to disk; load_from_disk() is called from Main._ready().

## Emitted when the OS switches to a different audio output device.
## Section_BeatRunner3d listens to this to auto-apply the saved offset.
signal audio_device_changed(new_device: String)

# ── Player appearance ──────────────────────────────────────────────────────────
var jacket_color: Color = Color(0.75, 0.112, 0.123, 1.0)  # red leather
var fur_color:    Color = Color(0.09, 0.08,  0.11,  1.0)  # dark charcoal
var hair_color:   Color = Color(0.90, 0.74,  0.10,  1.0)  # golden-blonde

# ── Level colors ───────────────────────────────────────────────────────────────
var level_color_a:       Color = Color(1.00, 0.45, 0.70, 1.0)    # pink  (left gates)
var level_color_b:       Color = Color(0.45, 0.82, 1.00, 1.0)    # cyan  (right gates)
var level_color_jump:    Color = Color(0.30, 1.00, 0.55, 1.0)    # green (jump gates)
var level_color_slide:   Color = Color(0.0,  0.821, 0.729, 1.0)  # teal  (slide gates)
var level_color_rail:    Color = Color(1.00, 0.55, 0.10, 1.0)    # orange (grind rail)
var floor_color:         Color = Color(0.103, 0.113, 0.121, 1.0) # light grey floor
var color_cycle_enabled:         bool  = true
# Seconds per random-color stop while Color Cycle is on — player-tunable,
# 5.0 (slowest) down to 0.2 (fastest / strobe-fast, deliberately harsh —
# player has been warned at boot, their call).
var color_cycle_period_s:        float = 5.0
var color_cycle_affects_gates:   bool  = true   # gates tinted by cycle colour
var color_cycle_affects_halos:   bool  = true   # halo rings follow cycle colour
var color_cycle_affects_floor:   bool  = true   # floor pulses with cycle colour
var color_cycle_affects_world:   bool  = true   # strips / gems / arches / floor-edge rails
var color_cycle_affects_rail:    bool  = true   # grind-rail gameplay hazard

# ── Gameplay ───────────────────────────────────────────────────────────────────
var wall_jumps_enabled:  bool  = true
var lives_per_song:      int   = 3

## Laser fixtures in the trackside rig. -1 means AUTO: follow the graphics
## quality tier, which is what keeps a weak machine on 0 unless the player
## deliberately asks for more. 0..LASER_COUNT_MAX overrides the tier outright.
const LASER_COUNT_AUTO: int = -1
const LASER_COUNT_MAX:  int = 100
var laser_count:         int   = LASER_COUNT_AUTO

## Screen-space reflections, ambient occlusion, indirect lighting and SDFGI, per
## the graphics tier. OFF by default and deliberately so: the tier's environment
## pass was dead code until the WorldEnvironment fix (see
## Section_BeatRunner3d._setup_world_environment), so every hour the game has
## ever been played was played without it. Measured at ~35-40 % of the frame
## rate on ultra, so switching it on is the player's call, not a silent upgrade.
var advanced_lighting:   bool  = false
var gate_preview_beats:  float = 8.0   # how many beats ahead gates become visible
var halo_preview_beats:  float = 2.2   # how many beats ahead halo rings spawn

# ── Halo ───────────────────────────────────────────────────────────────────────
var halo_shape:       String = "circle"  # one of: circle triangle square pentagon hexagon star diamond cross heart
var halo_size:        float  = 4.2    # radius of the halo ring
var halo_dual_color:  bool   = true  # second colour on alternating segments
var halo_color_a:     Color  = Color(1.00, 0.45, 0.70, 1.0)  # primary colour (used when cycle is off)
var halo_color_b:     Color  = Color(0.45, 0.82, 1.0,  1.0)  # secondary / dual colour

# ── Audio latency (per-device) ─────────────────────────────────────────────────
## Per output-device audio offset in milliseconds.
## Positive = gates arrive later (compensates for audio that's heard late).
## Negative = gates arrive earlier (rare; only needed if audio is ahead of visual).
var _audio_offsets:         Dictionary = {}   # device_name -> float (ms)
var _current_audio_device:  String     = ""   # last known device name
var _device_poll_t:         float      = 0.0  # accumulator for 1-second polling
## Offset for the CURRENT device, in seconds, kept in sync by _refresh_audio_offset_cache().
## _song_time() in Section_BeatRunner3d calls get_audio_offset_s() several times a frame; it
## used to go through AudioServer.get_output_device() plus a string-keyed dictionary lookup
## every single time, for a value that can only change when the device itself changes — and
## this file already polls for exactly that once a second.
var _audio_offset_s_cache:  float      = 0.0

const _PATH:        String = "user://gameconfig.cfg"
const _AUDIO_PATH:  String = "user://audio_offsets.cfg"


## Poll audio device once per second; emit audio_device_changed if it switches.
func _process(delta: float) -> void:
	_device_poll_t += delta
	if _device_poll_t < 1.0:
		return
	_device_poll_t = 0.0
	var dev: String = AudioServer.get_output_device()
	if dev != _current_audio_device:
		_current_audio_device = dev
		_refresh_audio_offset_cache()
		emit_signal("audio_device_changed", dev)


## Recomputes _audio_offset_s_cache from the current device. Call after anything that
## can change either the active output device or the stored per-device offsets.
func _refresh_audio_offset_cache() -> void:
	_audio_offset_s_cache = float(_audio_offsets.get(AudioServer.get_output_device(), 0.0)) / 1000.0


## Returns the calibrated offset for the current output device, in seconds.
## Returned value is added directly to _song_time() in Section_BeatRunner3d.
func get_audio_offset_s() -> float:
	return _audio_offset_s_cache


## Returns the calibrated offset for the current device in milliseconds.
func get_audio_offset_ms() -> float:
	return _audio_offsets.get(AudioServer.get_output_device(), 0.0)


## Saves a calibrated offset (ms) for the device that is currently active.
func set_audio_offset_for_current_device(ms: float) -> void:
	var dev: String = AudioServer.get_output_device()
	_audio_offsets[dev] = ms
	_refresh_audio_offset_cache()
	_save_audio_offsets()


func _save_audio_offsets() -> void:
	var cfg := ConfigFile.new()
	for dev in _audio_offsets:
		cfg.set_value("offsets", dev, _audio_offsets[dev])
	if cfg.save(_AUDIO_PATH) != OK:
		push_warning("[GameConfig] Failed to save audio offsets.")


func _load_audio_offsets() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_AUDIO_PATH) != OK:
		return   # first launch — no saved offsets yet
	if not cfg.has_section("offsets"):
		return
	for key in cfg.get_section_keys("offsets"):
		_audio_offsets[key] = cfg.get_value("offsets", key, 0.0)
	_refresh_audio_offset_cache()


# ── Controls (rebindable, keyboard + gamepad) ──────────────────────────────────
## Single source of truth for the runner's rebindable actions — read by the
## Options > Controls tab, applied to the live InputMap, and displayed by both
## How To Play screens, so all three are always in sync.
##
## Each action has a set of hardcoded default events (may be several, e.g.
## Space/W/Up all jump out of the box). Overriding an action via the Controls
## tab REPLACES its full default set with the single key/button the player
## chose — standard rebind-menu behaviour. Resetting clears the override and
## restores the original multi-key defaults exactly.
##
## Analog stick (left/right) and left-trigger (grind) are fixed secondary
## inputs, always present, never touched by rebinding.
const REBINDABLE_ACTIONS: Array[String] = [
	"runner_left", "runner_right", "runner_jump", "runner_slide",
	"runner_lb", "runner_rb", "runner_grind",
]

const ACTION_LABELS: Dictionary = {
	"runner_left":  "Move Left",
	"runner_right": "Move Right",
	"runner_jump":  "Jump",
	"runner_slide": "Slide",
	"runner_lb":    "Wall Jump ←",
	"runner_rb":    "Wall Jump →",
	"runner_grind": "Grind",
}

const DEFAULT_KEYS: Dictionary = {
	"runner_left":  [KEY_A, KEY_LEFT],
	"runner_right": [KEY_D, KEY_RIGHT],
	"runner_jump":  [KEY_SPACE, KEY_W, KEY_UP],
	"runner_slide": [KEY_S, KEY_DOWN, KEY_CTRL],
	"runner_lb":    [KEY_I],
	"runner_rb":    [KEY_O],
	"runner_grind": [KEY_G],
}

const DEFAULT_JOY_BUTTONS: Dictionary = {
	"runner_left":  [JOY_BUTTON_DPAD_LEFT],
	"runner_right": [JOY_BUTTON_DPAD_RIGHT],
	"runner_jump":  [JOY_BUTTON_A],
	"runner_slide": [JOY_BUTTON_B],
	"runner_lb":    [JOY_BUTTON_LEFT_SHOULDER],
	"runner_rb":    [JOY_BUTTON_RIGHT_SHOULDER],
	"runner_grind": [],   # left-trigger axis only by default
}

const _JOY_BUTTON_NAMES: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L-Stick Click", JOY_BUTTON_RIGHT_STICK: "R-Stick Click",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_START: "Start", JOY_BUTTON_GUIDE: "Guide",
	JOY_BUTTON_DPAD_UP: "D-Pad ↑", JOY_BUTTON_DPAD_DOWN: "D-Pad ↓",
	JOY_BUTTON_DPAD_LEFT: "D-Pad ←", JOY_BUTTON_DPAD_RIGHT: "D-Pad →",
	JOY_BUTTON_MISC1: "Misc1",
	JOY_BUTTON_PADDLE1: "Paddle 1", JOY_BUTTON_PADDLE2: "Paddle 2",
	JOY_BUTTON_PADDLE3: "Paddle 3", JOY_BUTTON_PADDLE4: "Paddle 4",
	JOY_BUTTON_TOUCHPAD: "Touchpad",
}

var control_key_overrides: Dictionary = {}   # action -> Key (single value; replaces all defaults)
var control_joy_overrides: Dictionary = {}   # action -> JoyButton (single value; replaces all defaults)

const _CONTROLS_PATH: String = "user://control_bindings.cfg"


## Every key currently bound to this action (override if set, else the full default set).
func get_control_key_events(action: String) -> Array:
	if control_key_overrides.has(action):
		return [control_key_overrides[action]]
	return DEFAULT_KEYS.get(action, [])


## Every gamepad button currently bound to this action (override if set, else defaults).
func get_control_joy_button_events(action: String) -> Array:
	if control_joy_overrides.has(action):
		return [control_joy_overrides[action]]
	return DEFAULT_JOY_BUTTONS.get(action, [])


## Human-readable primary keyboard binding, e.g. "A", "Space", "Ctrl".
func key_name(action: String) -> String:
	var evs: Array = get_control_key_events(action)
	return OS.get_keycode_string(evs[0]) if evs.size() > 0 else "—"


## Human-readable primary gamepad binding, e.g. "LB", "D-Pad ←".
func joy_button_name(action: String) -> String:
	var evs: Array = get_control_joy_button_events(action)
	if evs.is_empty():
		return "—"
	return _JOY_BUTTON_NAMES.get(evs[0], "Btn %d" % evs[0])


## Sets the keyboard binding for action, replacing its default(s). Applies immediately.
func set_control_key(action: String, keycode: int) -> void:
	control_key_overrides[action] = keycode
	apply_all_control_bindings()
	_save_controls()


## Sets the gamepad-button binding for action, replacing its default(s). Applies immediately.
func set_control_joy_button(action: String, btn: int) -> void:
	control_joy_overrides[action] = btn
	apply_all_control_bindings()
	_save_controls()


## Clears all overrides and restores the original hardcoded defaults.
func reset_controls_to_default() -> void:
	control_key_overrides.clear()
	control_joy_overrides.clear()
	apply_all_control_bindings()
	_save_controls()


## Rebuilds the InputMap for every rebindable action from the current
## overrides/defaults. Safe to call with or without a runner scene loaded —
## this is the only place that writes these actions into the InputMap, so
## the Options > Controls tab (main menu, no player instance) and the actual
## gameplay (BeatRunnerPlayer) always agree.
func apply_all_control_bindings() -> void:
	for action: String in REBINDABLE_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for e in InputMap.action_get_events(action):
			if e is InputEventKey or e is InputEventJoypadButton:
				InputMap.action_erase_event(action, e)
		for k in get_control_key_events(action):
			var ke := InputEventKey.new()
			ke.physical_keycode = k
			InputMap.action_add_event(action, ke)
		for b in get_control_joy_button_events(action):
			var be := InputEventJoypadButton.new()
			be.button_index = b
			InputMap.action_add_event(action, be)

	# Fixed secondary analog inputs — always present, never cleared or rebound.
	_ensure_joy_axis("runner_left", JOY_AXIS_LEFT_X, -1.0, 0.42)
	_ensure_joy_axis("runner_right", JOY_AXIS_LEFT_X, 1.0, 0.42)
	_ensure_joy_axis("runner_grind", JOY_AXIS_TRIGGER_LEFT, 1.0, 0.15)


func _ensure_joy_axis(action: String, axis: int, axis_value: float, deadzone: float) -> void:
	for e in InputMap.action_get_events(action):
		var jm := e as InputEventJoypadMotion
		if jm != null and jm.axis == axis and absf(jm.axis_value - axis_value) < 0.001:
			InputMap.action_set_deadzone(action, deadzone)
			return
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = axis_value
	InputMap.action_add_event(action, ev)
	InputMap.action_set_deadzone(action, deadzone)


func _save_controls() -> void:
	var cfg := ConfigFile.new()
	for action in control_key_overrides:
		cfg.set_value("keys", action, control_key_overrides[action])
	for action in control_joy_overrides:
		cfg.set_value("joy", action, control_joy_overrides[action])
	if cfg.save(_CONTROLS_PATH) != OK:
		push_warning("[GameConfig] Failed to save control bindings.")


func _load_controls() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_CONTROLS_PATH) != OK:
		return   # first launch — no custom bindings yet
	if cfg.has_section("keys"):
		for k in cfg.get_section_keys("keys"):
			control_key_overrides[k] = int(cfg.get_value("keys", k))
	if cfg.has_section("joy"):
		for k in cfg.get_section_keys("joy"):
			control_joy_overrides[k] = int(cfg.get_value("joy", k))


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("appearance", "jacket_color",    jacket_color)
	cfg.set_value("appearance", "fur_color",       fur_color)
	cfg.set_value("appearance", "hair_color",      hair_color)
	cfg.set_value("level",      "color_a",         level_color_a)
	cfg.set_value("level",      "color_b",         level_color_b)
	cfg.set_value("level",      "color_jump",      level_color_jump)
	cfg.set_value("level",      "color_slide",     level_color_slide)
	cfg.set_value("level",      "color_rail",      level_color_rail)
	cfg.set_value("level",      "floor_color",     floor_color)
	cfg.set_value("level",      "color_cycle",              color_cycle_enabled)
	cfg.set_value("level",      "color_cycle_period_s",     color_cycle_period_s)
	cfg.set_value("level",      "cycle_affects_gates",      color_cycle_affects_gates)
	cfg.set_value("level",      "cycle_affects_halos",      color_cycle_affects_halos)
	cfg.set_value("level",      "cycle_affects_floor",      color_cycle_affects_floor)
	cfg.set_value("level",      "cycle_affects_world",      color_cycle_affects_world)
	cfg.set_value("level",      "cycle_affects_rail",       color_cycle_affects_rail)
	cfg.set_value("gameplay",   "wall_jumps",           wall_jumps_enabled)
	cfg.set_value("gameplay",   "lives_per_song",       lives_per_song)
	cfg.set_value("display",    "laser_count",          laser_count)
	cfg.set_value("display",    "advanced_lighting",    advanced_lighting)
	cfg.set_value("gameplay",   "gate_preview_beats",   gate_preview_beats)
	cfg.set_value("gameplay",   "halo_preview_beats",   halo_preview_beats)
	cfg.set_value("halo",       "shape",        halo_shape)
	cfg.set_value("halo",       "size",         halo_size)
	cfg.set_value("halo",       "dual_color",   halo_dual_color)
	cfg.set_value("halo",       "color_a",      halo_color_a)
	cfg.set_value("halo",       "color_b",      halo_color_b)
	if cfg.save(_PATH) != OK:
		push_warning("[GameConfig] Failed to save settings.")


func load_from_disk() -> void:
	_current_audio_device = AudioServer.get_output_device()   # baseline for change detection
	_refresh_audio_offset_cache()
	_load_audio_offsets()
	_load_controls()
	apply_all_control_bindings()

	var cfg := ConfigFile.new()
	if cfg.load(_PATH) != OK:
		return  # first launch — keep defaults
	jacket_color        = cfg.get_value("appearance", "jacket_color",    jacket_color)
	fur_color           = cfg.get_value("appearance", "fur_color",       fur_color)
	hair_color          = cfg.get_value("appearance", "hair_color",      hair_color)
	level_color_a       = cfg.get_value("level",      "color_a",         level_color_a)
	level_color_b       = cfg.get_value("level",      "color_b",         level_color_b)
	level_color_jump    = cfg.get_value("level",      "color_jump",      level_color_jump)
	level_color_slide   = cfg.get_value("level",      "color_slide",     level_color_slide)
	level_color_rail    = cfg.get_value("level",      "color_rail",      level_color_rail)
	floor_color         = cfg.get_value("level",      "floor_color",     floor_color)
	color_cycle_enabled          = cfg.get_value("level", "color_cycle",              color_cycle_enabled)
	color_cycle_period_s         = cfg.get_value("level", "color_cycle_period_s",     color_cycle_period_s)
	color_cycle_affects_gates    = cfg.get_value("level", "cycle_affects_gates",      color_cycle_affects_gates)
	color_cycle_affects_halos    = cfg.get_value("level", "cycle_affects_halos",      color_cycle_affects_halos)
	color_cycle_affects_floor    = cfg.get_value("level", "cycle_affects_floor",      color_cycle_affects_floor)
	color_cycle_affects_world    = cfg.get_value("level", "cycle_affects_world",      color_cycle_affects_world)
	color_cycle_affects_rail     = cfg.get_value("level", "cycle_affects_rail",       color_cycle_affects_rail)
	wall_jumps_enabled  = cfg.get_value("gameplay",   "wall_jumps",           wall_jumps_enabled)
	lives_per_song      = cfg.get_value("gameplay",   "lives_per_song",       lives_per_song)
	advanced_lighting   = bool(cfg.get_value("display", "advanced_lighting", advanced_lighting))
	laser_count         = clampi(int(cfg.get_value("display", "laser_count", laser_count)),
		LASER_COUNT_AUTO, LASER_COUNT_MAX)
	gate_preview_beats  = cfg.get_value("gameplay",   "gate_preview_beats",   gate_preview_beats)
	halo_preview_beats  = cfg.get_value("gameplay",   "halo_preview_beats",   halo_preview_beats)
	halo_shape          = cfg.get_value("halo",  "shape",       halo_shape)
	halo_size           = cfg.get_value("halo",  "size",        halo_size)
	halo_dual_color     = cfg.get_value("halo",  "dual_color",  halo_dual_color)
	halo_color_a        = cfg.get_value("halo",  "color_a",     halo_color_a)
	halo_color_b        = cfg.get_value("halo",  "color_b",     halo_color_b)
	Run.song_lives      = lives_per_song


func reset_defaults() -> void:
	jacket_color        = Color(0.75, 0.112, 0.123, 1.0)
	fur_color           = Color(0.09, 0.08,  0.11,  1.0)
	hair_color          = Color(0.90, 0.74,  0.10,  1.0)
	level_color_a       = Color(1.00, 0.45,  0.70,  1.0)
	level_color_b       = Color(0.45, 0.82,  1.00,  1.0)
	level_color_jump    = Color(0.30, 1.00,  0.55,  1.0)
	level_color_slide   = Color(0.0,  0.821, 0.729, 1.0)
	level_color_rail    = Color(1.00, 0.55,  0.10,  1.0)
	floor_color         = Color(0.943, 0.948, 0.952, 1.0)
	color_cycle_enabled          = true
	color_cycle_period_s         = 5.0
	color_cycle_affects_gates    = true
	color_cycle_affects_halos    = true
	color_cycle_affects_floor    = true
	color_cycle_affects_world    = true
	color_cycle_affects_rail     = true
	wall_jumps_enabled  = true
	lives_per_song      = 3
	laser_count         = LASER_COUNT_AUTO
	advanced_lighting   = false
	gate_preview_beats  = 2.5
	halo_preview_beats  = 2.2
	halo_shape          = "circle"
	halo_size           = 4.2
	halo_dual_color     = true
	halo_color_a        = Color(1.00, 0.45, 0.70, 1.0)
	halo_color_b        = Color(0.45, 0.82, 1.0,  1.0)
	Run.song_lives      = lives_per_song
