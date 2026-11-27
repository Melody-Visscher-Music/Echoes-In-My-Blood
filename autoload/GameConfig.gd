extends Node
## Persistent gameplay & appearance settings.
## All values are applied at game-scene start (BeatRunnerPlayer, Section_BeatRunner3d).
## Call save() to write to disk; load_from_disk() is called from Main._ready().

## Emitted when the OS switches to a different audio output device. The offset
## cache below is already refreshed by the time this fires, so gameplay needs no
## listener; AudioCalibrator uses it to abandon a measurement taken half on one
## device and half on another.
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
## Gamepad rumble on the beat, hits, catches, smash impacts and the overdrive
## drop. Has no effect without a controller.
var controller_rumble:   bool  = true
var lives_per_song:      int   = 3

## Laser fixtures in the trackside rig. -1 means AUTO: follow the graphics
## quality tier, which is what keeps a weak machine on 0 unless the player
## deliberately asks for more. 0..LASER_COUNT_MAX overrides the tier outright.
const LASER_COUNT_AUTO: int = -1
const LASER_COUNT_MAX:  int = 500
var laser_count:         int   = LASER_COUNT_AUTO

## Screen-space reflections, ambient occlusion, indirect lighting and SDFGI, per
## the graphics tier. OFF by default and deliberately so: the tier's environment
## pass was dead code until the WorldEnvironment fix (see
## Section_BeatRunner3d._setup_world_environment), so every hour the game has
## ever been played was played without it. Measured at ~35-40 % of the frame
## rate on ultra, so switching it on is the player's call, not a silent upgrade.
var advanced_lighting:   bool  = false
var gate_preview_beats:  float = 2.5   # how many beats ahead gates become visible

# ── Halo ───────────────────────────────────────────────────────────────────────
var halo_size:        float  = 4.2    # radius of the halo ring
var halo_dual_color:  bool   = true  # second colour on alternating segments
var halo_color_a:     Color  = Color(1.00, 0.45, 0.70, 1.0)  # primary colour (used when cycle is off)
var halo_color_b:     Color  = Color(0.45, 0.82, 1.0,  1.0)  # secondary / dual colour

# ── Display & audio output ─────────────────────────────────────────────────────
## Options > Display and Options > Audio used to write straight to AudioServer /
## DisplayServer / Engine and nothing else — applied live, never written to disk,
## never read back. Every launch reset the player's volume to 100 %, dropped them
## back to the project's window mode and re-read run/max_fps from project.godot.
## These four live here now so save()/load_from_disk() cover them like everything
## else; apply_display_and_audio() is what actually pushes them to the servers.
## Defaults match project.godot (fullscreen, 120 fps) so a first launch is unchanged.
var master_volume: float = 1.0     # 0.0 – 1.0, linear
var music_volume:  float = 1.0     # Music bus, relative to Master
var sfx_volume:    float = 1.0     # SFX bus, relative to Master
var fullscreen:    bool  = true
var vsync_enabled: bool  = true

## Photosensitivity. The game opens on an epilepsy warning and then flashes hard
## on every beat; this is the setting that warning implies should exist. It does
## not change what the player has to do — gates are read by lane and by shape,
## never by colour — it only takes the punch out of the per-beat spike, the HUD
## hit flashes and the strobing lasers.
var reduced_flashing: bool = false

## Frame-rate readout on the HUD, off by default. The quality tiers span 593 fps
## to 87 on the same machine, and a tier the machine cannot hold reads as the
## game being wrong rather than the setting being too high.
var show_fps: bool = false

## How much of the on-beat flash to keep. One number, so everything that pulses
## stays in step with everything else instead of each effect picking its own
## reduction.
const REDUCED_FLASH_SCALE: float = 0.22


func flash_scale() -> float:
	return REDUCED_FLASH_SCALE if reduced_flashing else 1.0


## Rumble every connected gamepad. weak = the high-frequency motor, strong = the
## low thump (0..1 each). Does nothing when the option is off or no pad is in.
func rumble(weak: float, strong: float, duration: float) -> void:
	if not controller_rumble:
		return
	for dev: int in Input.get_connected_joypads():
		Input.start_joy_vibration(dev, clampf(weak, 0.0, 1.0), clampf(strong, 0.0, 1.0), duration)
var max_fps:       int   = 120     # 0 = unlimited


## Pushes the four settings above to AudioServer / DisplayServer / Engine.
## Called from load_from_disk() and from each Options control as it changes.
func apply_display_and_audio() -> void:
	_set_bus_volume("Master", master_volume)
	_set_bus_volume("Music",  music_volume)
	_set_bus_volume("SFX",    sfx_volume)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync_enabled
		else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = max_fps


## linear 0..1 onto a named bus. Silently ignores a bus that is not in the
## layout, so a missing default_bus_layout.tres degrades to "Master only"
## instead of throwing on every settings change.
func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(linear) if linear > 0.001 else -80.0)


# ── Audio latency (per-device) ─────────────────────────────────────────────────
## Per output-device audio offset in milliseconds: how much later the sound
## reaches the ear than the matching frame reaches the eye.
## Positive = sound is late (the usual case; Bluetooth is +150..300).
## Negative = sound is ahead of the picture (rare; a slow TV on a fast DAC).
##
## A device with NO entry is "not calibrated", which is not the same thing as a
## device calibrated to 0 ms — see has_audio_calibration(). An uncalibrated
## device falls back to the one part of the delay the engine can measure itself,
## AudioServer.get_output_latency(). That is also what tools/ManualMapper has
## always subtracted while charting, so an uncalibrated player now hears a chart
## the way it was authored instead of one mix buffer early.
var _audio_offsets:         Dictionary = {}   # device_name -> float (ms)
var _current_audio_device:  String     = ""   # last known device name
var _device_poll_t:         float      = 0.0  # accumulator for 1-second polling
## Offset for the CURRENT device, in seconds, kept in sync by _refresh_audio_offset_cache().
## The song clock is read several times a frame; it used to go through
## AudioServer.get_output_device() plus a string-keyed dictionary lookup every
## single time, for a value that can only change when the device itself changes —
## and this file already polls for exactly that once a second.
var _audio_offset_s_cache:  float      = 0.0
## Dev-harness seam: when set, replaces the offset outright and nothing is
## written to disk. See dev_override_audio_offset_ms().
var _dev_audio_offset_ms:   Variant    = null

const _PATH:        String = "user://gameconfig.cfg"
const _AUDIO_PATH:  String = "user://audio_offsets.cfg"
var _audio_path:    String = _AUDIO_PATH


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
	elif not has_audio_calibration():
		# The uncalibrated fallback is the engine's own buffer latency, which the
		# driver can renegotiate without the device name changing.
		_refresh_audio_offset_cache()


## Recomputes _audio_offset_s_cache from the current device. Call after anything that
## can change either the active output device or the stored per-device offsets.
func _refresh_audio_offset_cache() -> void:
	_audio_offset_s_cache = get_audio_offset_ms() / 1000.0


## True once the current output device has been through the calibrator (even if
## the answer was 0 ms).
func has_audio_calibration() -> bool:
	return _audio_offsets.has(AudioServer.get_output_device())


## The offset in force for the current output device, in seconds: the calibrated
## value if there is one, otherwise the engine's reported output latency.
func get_audio_offset_s() -> float:
	return _audio_offset_s_cache


## Same, in milliseconds, uncached.
func get_audio_offset_ms() -> float:
	if _dev_audio_offset_ms != null:
		return float(_dev_audio_offset_ms)
	var dev: String = AudioServer.get_output_device()
	if _audio_offsets.has(dev):
		return float(_audio_offsets[dev])
	return AudioServer.get_output_latency() * 1000.0


## THE song clock: where in `player`'s stream the listener is right now, in
## seconds, as it lines up with the frame being drawn. The game and the mapper
## both read this one function so a chart is authored and played on the same
## clock. Not clamped — it runs negative for the first `offset` seconds of a
## song, which is what lets the level hold the runner until the sound arrives.
func song_clock(player: AudioStreamPlayer) -> float:
	return player.get_playback_position() + AudioServer.get_time_since_last_mix() \
		- _audio_offset_s_cache


## Saves a calibrated offset (ms) for the device that is currently active.
func set_audio_offset_for_current_device(ms: float) -> void:
	var dev: String = AudioServer.get_output_device()
	_audio_offsets[dev] = ms
	_refresh_audio_offset_cache()
	_save_audio_offsets()


## Forgets the current device's calibration, putting it back on the engine
## fallback. This is what "reset" means — writing 0 would claim the device had
## been measured and found to have no delay at all.
func clear_audio_offset_for_current_device() -> void:
	_audio_offsets.erase(AudioServer.get_output_device())
	_refresh_audio_offset_cache()
	_save_audio_offsets()


## Dev harness only: force the offset for this run without touching the
## player's file. Pass null to hand control back to the stored values.
func dev_override_audio_offset_ms(ms: Variant) -> void:
	_dev_audio_offset_ms = ms
	_refresh_audio_offset_cache()


## Dev harness only: point the offset store at another file and reload it, so a
## round-trip test never writes the player's own calibration.
func dev_use_audio_path(path: String) -> void:
	_audio_path = path
	_audio_offsets.clear()
	_load_audio_offsets()
	_refresh_audio_offset_cache()


func _save_audio_offsets() -> void:
	var cfg := ConfigFile.new()
	for dev in _audio_offsets:
		cfg.set_value("offsets", dev, _audio_offsets[dev])
	if cfg.save(_audio_path) != OK:
		push_warning("[GameConfig] Failed to save audio offsets.")


func _load_audio_offsets() -> void:
	var cfg := ConfigFile.new()
	# Start clean: this is re-run by the mapper to pick up what the game saved,
	# and a device the game has since reset must not survive in memory here.
	_audio_offsets.clear()
	if cfg.load(_audio_path) == OK and cfg.has_section("offsets"):
		for key in cfg.get_section_keys("offsets"):
			var ms: float = float(cfg.get_value("offsets", key, 0.0))
			# Older builds wrote exactly 0.0 for "reset" and read it back as "not
			# calibrated". A measured result is a difference of two averages and
			# never lands on exactly zero, so 0.0 in a file is always that marker.
			if ms != 0.0:
				_audio_offsets[key] = ms
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
	cfg.set_value("gameplay",   "controller_rumble",    controller_rumble)
	cfg.set_value("gameplay",   "lives_per_song",       lives_per_song)
	cfg.set_value("display",    "laser_count",          laser_count)
	cfg.set_value("display",    "fullscreen",           fullscreen)
	cfg.set_value("display",    "vsync",                vsync_enabled)
	cfg.set_value("display",    "reduced_flashing",     reduced_flashing)
	cfg.set_value("display",    "show_fps",             show_fps)
	cfg.set_value("display",    "max_fps",              max_fps)
	cfg.set_value("audio",      "master_volume",        master_volume)
	cfg.set_value("audio",      "music_volume",         music_volume)
	cfg.set_value("audio",      "sfx_volume",           sfx_volume)
	cfg.set_value("display",    "advanced_lighting",    advanced_lighting)
	cfg.set_value("gameplay",   "gate_preview_beats",   gate_preview_beats)
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
	controller_rumble   = bool(cfg.get_value("gameplay", "controller_rumble", controller_rumble))
	lives_per_song      = cfg.get_value("gameplay",   "lives_per_song",       lives_per_song)
	advanced_lighting   = bool(cfg.get_value("display", "advanced_lighting", advanced_lighting))
	fullscreen          = bool(cfg.get_value("display", "fullscreen", fullscreen))
	vsync_enabled       = bool(cfg.get_value("display", "vsync",      vsync_enabled))
	reduced_flashing    = bool(cfg.get_value("display", "reduced_flashing", reduced_flashing))
	show_fps            = bool(cfg.get_value("display", "show_fps", show_fps))
	max_fps             = maxi(0, int(cfg.get_value("display", "max_fps", max_fps)))
	master_volume       = clampf(float(cfg.get_value("audio", "master_volume", master_volume)), 0.0, 1.0)
	music_volume        = clampf(float(cfg.get_value("audio", "music_volume",  music_volume)),  0.0, 1.0)
	sfx_volume          = clampf(float(cfg.get_value("audio", "sfx_volume",    sfx_volume)),    0.0, 1.0)
	apply_display_and_audio()   # push the freshly-loaded values to the servers
	laser_count         = clampi(int(cfg.get_value("display", "laser_count", laser_count)),
		LASER_COUNT_AUTO, LASER_COUNT_MAX)
	gate_preview_beats  = cfg.get_value("gameplay",   "gate_preview_beats",   gate_preview_beats)
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
	controller_rumble   = true
	lives_per_song      = 3
	laser_count         = LASER_COUNT_AUTO
	advanced_lighting   = false
	master_volume       = 1.0
	music_volume        = 1.0
	sfx_volume          = 1.0
	fullscreen          = true
	vsync_enabled       = true
	reduced_flashing    = false
	show_fps            = false
	max_fps             = 120
	gate_preview_beats  = 2.5
	halo_size           = 4.2
	halo_dual_color     = true
	halo_color_a        = Color(1.00, 0.45, 0.70, 1.0)
	halo_color_b        = Color(0.45, 0.82, 1.0,  1.0)
	Run.song_lives      = lives_per_song
