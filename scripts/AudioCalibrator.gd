extends CanvasLayer
## Audio latency calibrator — three-phase flow.
##
##  IDLE    → shows current device + saved offset + Bluetooth detection
##            [ENTER] start calibration   [R] reset   [ESC] close
##
##  PASS 1  → SILENT. The ring flashes on each beat; tap when you SEE it.
##  PASS 2  → DARK. A click plays on each beat; tap when you HEAR it.
##            Each pass collects COLLECT_N taps and takes a trimmed mean.
##            [ESC] back to idle without saving
##
##  WHY TWO PASSES: a single "tap when you hear it" test measures
##  reaction_time + audio_latency and cannot separate them, so it was banking
##  ~150–250 ms of human reflex into the saved offset and shifting every gate
##  in the game by it. Reaction time is present in BOTH passes and identical in
##  both, so the DIFFERENCE cancels it:
##      visual_mean = reaction + display_latency
##      audio_mean  = reaction + audio_latency
##      offset      = audio_mean - visual_mean = audio latency vs. the screen
##  which is exactly what _song_time() needs. It can also come out negative now
##  (audio ahead of video), which the old one-pass version was structurally
##  incapable of producing.
##
##  DONE    → shows measured result and consistency rating
##            [ENTER] save and close   [F] fine-tune it by eye   [ESC] discard
##
##  TUNE    → a click loops once a second and a ball bounces to it. Nudge the
##            offset until the ball lands exactly on the click. No tapping, so
##            nothing about the player's hands or reflexes is in the answer —
##            which is the one thing the tap test cannot promise: people answer
##            a sound a little faster than a flash, and that difference does
##            not cancel. Reachable from IDLE too, starting from whatever is in
##            force now.
##            [←/→] ±5 ms   [↑/↓] ±1 ms   [ENTER] save and close   [ESC] back
##
## Add as a child of any PROCESS_MODE_ALWAYS node (Section is already set to
## that while paused, so just add_child(cal) from _launch_audio_calibrator).

signal calibration_complete(offset_ms: float)
signal calibration_cancelled

# ── Config ────────────────────────────────────────────────────────────────────
const BPM:       float = 60.0
const INTERVAL:  float = 60.0 / BPM     # 1.000 s — comfortable tapping pace
const WARMUP_N:  int   = 4              # beats to run before measuring, per pass
const COLLECT_N: int   = 14             # taps collected per pass
const TRIM_N:    int   = 3              # discard this many highest + lowest, per pass
## How far BEFORE a beat a tap still belongs to that beat. At a steady 60 BPM
## people stop reacting and start predicting within a few beats, so taps land
## either side of the stimulus. The window is lopsided on purpose: a tap can be
## this early, or up to INTERVAL - EARLY_WINDOW (700 ms) late, which still covers
## the slowest Bluetooth link.
const EARLY_WINDOW: float = 0.30
## Trimmed standard deviation above which a pass is called inconsistent.
const MAX_SPREAD:   float = 0.04

# Keywords checked against the lowercased output device name.
# Broad on purpose — a false BT-positive is harmless; a miss isn't.
const BT_HINTS: PackedStringArray = [
	"bluetooth", " bt ", "a2dp", "wireless", "headset", "headphones",
	"earbuds", "airpods", "buds", "hands-free",
	"ghw3", "phreeze", "jabra", "sennheiser", "sony wh", "sony wf",
	"galaxy buds", "jbl", "beats", "hyperx", "arctis", "kraken",
	"virtuoso", "astro", "turtle beach", "logitech g",
]

# ── Phase state ───────────────────────────────────────────────────────────────
## VISUAL and AUDIO are the two measurement passes; see the header.
enum Phase { IDLE, VISUAL, AUDIO, DONE, TUNE }
var _phase: Phase = Phase.IDLE

## Trimmed means of each pass, in seconds. Both include the player's reaction
## time; subtracting one from the other is what removes it.
var _visual_mean: float = 0.0
var _audio_mean:  float = 0.0
## Spread of each pass. The result is a difference, so it is only as good as
## the worse of the two.
var _visual_sd:   float = 0.0
var _audio_sd:    float = 0.0

var _elapsed:    float        = 0.0
var _next_beat:  float        = 1.0
var _beat_count: int          = 0
var _taps:       Array[float] = []
var _pulse:      float        = 0.0
var _result_ms:  float        = 0.0
var _inconsistent: bool       = false

# High-precision timing — replaces delta accumulation to eliminate drift.
var _run_start_usec: int = 0
## Beat number of the last tap that counted, so a double-tap or a bouncing
## switch cannot vote twice for the same beat.
var _last_tap_beat:  int = 0

# ── Fine-tune by eye ──────────────────────────────────────────────────────────
## Limits of what can be dialled in. Past these something else is wrong.
const TUNE_MIN_MS: float = -300.0
const TUNE_MAX_MS: float = 600.0
## The offset being tried, in ms. Applied to the ball only — nothing is saved
## until the player says so.
var _tune_ms:    float = 0.0
## Where in the one-second loop the ball was last frame, to catch the landing.
var _tune_phase: float = 0.0
## Landing flash, 1 → 0.
var _tune_flash: float = 0.0

# ── Audio ─────────────────────────────────────────────────────────────────────
var _click: AudioStreamPlayer = null
## The fine-tune metronome: one click at the top of a looping one-second
## stream. A loop rather than a click fired from _process, because a stream has
## a playback position — so the ball can be driven by the exact clock the game
## drives its gates with, and what looks right here is right there.
var _metro: AudioStreamPlayer = null

# ── UI refs ───────────────────────────────────────────────────────────────────
var _title:      Label     = null
var _dev_lbl:    Label     = null
var _saved_lbl:  Label     = null
var _body:       Label     = null
var _circle:     ColorRect = null
var _ring_wrap:  Control   = null   # holds _circle; hidden while the stage is up
var _stage:      Control   = null   # the bouncing ball, drawn by hand
var _count_lbl:  Label     = null
var _tap_lbl:    Label     = null
var _avg_lbl:    Label     = null
var _hint:       Label     = null
var _measure_nodes: Array[Label] = []
## Phase-specific buttons. The calibrator was keyboard/gamepad only — every
## action lived behind a bracketed key hint and a mouse could do nothing but
## tap during the test itself.
var _btn_row:    HBoxContainer = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 120
	_build_click()
	_build_ui()
	_enter_idle()
	GameConfig.audio_device_changed.connect(_on_device_changed)


## Headphones unplugged or connected mid-flow. A pass measured across two
## devices means nothing, and even the idle card is now describing the wrong
## one — so whatever was on screen, go back to a fresh idle card.
func _on_device_changed(_new_device: String) -> void:
	_enter_idle()


# ── Bluetooth detection ───────────────────────────────────────────────────────

func _is_likely_bluetooth() -> bool:
	var dev := AudioServer.get_output_device().to_lower()
	for hint: String in BT_HINTS:
		if hint in dev:
			return true
	# Android: API 30+ usually names the device explicitly;
	# also check common BT audio keywords some builds report.
	if OS.get_name() == "Android":
		return "bluetooth" in dev or "a2dp" in dev or "sco" in dev
	return false


## Returns a dict:
##   is_bt        — bool
##   engine_ms    — software buffer latency Godot/WASAPI can confirm
##   suggested_ms — engine_ms + estimated BT wireless (SBC assumed when BT)
##   label        — human-readable device type string
func _auto_suggest() -> Dictionary:
	var engine_ms := AudioServer.get_output_latency() * 1000.0
	if _is_likely_bluetooth():
		# SBC (Windows default) adds ~150–280 ms on top of the engine buffer.
		# 200 ms is the centre-of-range starting point; the tap test refines from there.
		return {
			"is_bt":        true,
			"engine_ms":    engine_ms,
			"suggested_ms": engine_ms + 200.0,
			"label":        "Bluetooth (SBC ~150–280 ms typical)",
		}
	return {
		"is_bt":        false,
		"engine_ms":    engine_ms,
		"suggested_ms": engine_ms,
		"label":        "Wired / Built-in",
	}


# ── Phase transitions ─────────────────────────────────────────────────────────
func _enter_idle() -> void:
	_phase = Phase.IDLE
	_click.stop()
	_metro.stop()
	_show_stage(false)
	_elapsed    = 0.0
	_beat_count = 0
	_taps.clear()
	_set_measure_visible(false)

	var dev      := AudioServer.get_output_device()
	var suggest  := _auto_suggest()
	var calibrated: bool = GameConfig.has_audio_calibration()
	var ms_str: String = _saved_offset_text()

	_title.text     = "AUDIO LATENCY"
	_dev_lbl.text   = "Device:  %s  [%s]" % [dev, suggest.label]
	_saved_lbl.text = "Saved offset:  %s" % ms_str

	if suggest.is_bt and not calibrated:
		_body.text = (
			"⚡ Bluetooth detected.\n"
			+ "Engine buffer: %.0f ms  |  Estimated wireless: +150–280 ms\n" % suggest.engine_ms
			+ "Suggested start: ~%.0f ms — tap test will dial it in." % suggest.suggested_ms
		)
	elif suggest.is_bt:
		_body.text = (
			"⚡ Bluetooth — tap test to confirm or refine.\n"
			+ "Engine buffer: %.0f ms" % suggest.engine_ms
		)
	else:
		_body.text = "Two quick steps: tap what you SEE, then tap what you HEAR.\nThe gap between them is your audio delay. Headphones on."

	_hint.text    = "[ENTER]  Calibrate (2 steps)     [F]  Fine-tune by eye     [R]  Reset     [ESC]  Close"
	_set_buttons([
		["CALIBRATE",   _enter_running, UiStyle.CYAN],
		["FINE-TUNE",   _enter_tune_from_saved, UiStyle.CYAN],
		["RESET",       _do_reset,      UiStyle.VIOLET],
		["CLOSE",       _do_cancel,     UiStyle.VIOLET],
	])
	_set_circle_color(Color(0.35, 0.20, 0.70, 1.0))


## Starts the visual pass. The audio pass follows automatically once it fills.
func _enter_running() -> void:
	_visual_mean = 0.0
	_audio_mean  = 0.0
	_enter_pass(Phase.VISUAL)


## Runs one measurement pass. VISUAL flashes the ring in silence; AUDIO clicks
## with the ring held still, so each pass has exactly one stimulus to react to.
## Mixing them would let the player anticipate on the wrong channel and the
## subtraction in _compute_result() would stop meaning anything.
func _enter_pass(pass_phase: Phase) -> void:
	_phase      = pass_phase
	_elapsed    = 0.0
	_next_beat  = 1.0
	_beat_count = 0
	_taps.clear()
	_last_tap_beat  = 0
	_run_start_usec = Time.get_ticks_usec()   # anchor to monotonic clock
	_set_measure_visible(true)

	var is_audio: bool = (pass_phase == Phase.AUDIO)
	_title.text     = "GET READY…"
	_dev_lbl.text   = "STEP %d OF 2  ·  %s" % [2 if is_audio else 1, "SOUND" if is_audio else "SIGHT"]
	_saved_lbl.text = ""
	_body.text      = ("Eyes anywhere — tap each time you HEAR the click"
		if is_audio else
		"Sound off for this step — tap each time you SEE the ring flash")
	_count_lbl.text = "0 / %d" % COLLECT_N
	_tap_lbl.text   = ""
	_avg_lbl.text   = ""
	_hint.text      = "[ESC]  Cancel     ·     tap with any key, pad button or a click"
	_set_buttons([["CANCEL", _enter_idle, UiStyle.VIOLET]])
	# Sight pass = violet ring, sound pass = dim so it reads as "not this one".
	_set_circle_color(Color(0.35, 0.20, 0.70, 1.0) if not is_audio
		else Color(0.10, 0.08, 0.16, 1.0))


func _enter_done() -> void:
	_phase = Phase.DONE
	_click.stop()
	_set_measure_visible(false)

	var sgn: String = "+" if _result_ms >= 0.0 else ""
	var ms_str: String = _saved_offset_text()

	_title.text     = "RESULT"
	_dev_lbl.text   = ""
	_saved_lbl.text = "Previously saved:  %s" % ms_str
	# Both pass means are shown, not just the result — the number is a difference,
	# and seeing where it came from is what makes it believable.
	_body.text = ("Measured audio latency:  %s%.0f ms\n" % [sgn, _result_ms]
		+ "sight %.0f ms  ·  sound %.0f ms  — the gap between them is your\n" % [
			_visual_mean * 1000.0, _audio_mean * 1000.0]
		+ "headphone delay; your reaction time is in both and cancels out.")
	if _inconsistent:
		_body.text += "\n⚠  Inconsistent taps — consider redoing calibration"
	_hint.text      = "[ENTER]  Save & close     [F]  Fine-tune by eye     [ESC]  Discard"
	_set_buttons([
		["SAVE & CLOSE", _do_save,   UiStyle.CYAN],
		["FINE-TUNE",    _enter_tune_from_result, UiStyle.CYAN],
		["DISCARD",      _enter_idle, UiStyle.VIOLET],
	])


## Fine-tune, starting from what the game is using right now.
func _enter_tune_from_saved() -> void:
	_enter_tune(GameConfig.get_audio_offset_ms())


## Fine-tune, starting from the tap test that has just finished.
func _enter_tune_from_result() -> void:
	_enter_tune(_result_ms)


func _enter_tune(start_ms: float) -> void:
	_phase = Phase.TUNE
	_click.stop()
	_set_measure_visible(false)
	_show_stage(true)
	_tune_ms    = clampf(roundf(start_ms), TUNE_MIN_MS, TUNE_MAX_MS)
	_tune_phase = 0.0
	_tune_flash = 0.0
	_metro.play()

	_title.text     = "FINE-TUNE"
	_dev_lbl.text   = "Device:  %s" % AudioServer.get_output_device()
	_body.text      = ("Watch the ball, listen to the click.\n"
		+ "Nudge until it LANDS exactly on the click.")
	_hint.text      = "[←/→]  5 ms     [↑/↓]  1 ms     [ENTER]  Save & close     [ESC]  Back"
	_set_buttons([
		["-5", _nudge_tune.bind(-5.0), UiStyle.VIOLET],
		["-1", _nudge_tune.bind(-1.0), UiStyle.VIOLET],
		["+1", _nudge_tune.bind(1.0),  UiStyle.VIOLET],
		["+5", _nudge_tune.bind(5.0),  UiStyle.VIOLET],
		["SAVE & CLOSE", _do_save_tune, UiStyle.CYAN],
		["BACK",         _enter_idle,   UiStyle.VIOLET],
	], 104.0)
	_refresh_tune_label()


func _nudge_tune(by_ms: float) -> void:
	_tune_ms = clampf(_tune_ms + by_ms, TUNE_MIN_MS, TUNE_MAX_MS)
	_refresh_tune_label()


## Says which way the number moves the ball, because "+" on its own means
## nothing to someone who has not read the code.
func _refresh_tune_label() -> void:
	_saved_lbl.text = "%s%.0f ms" % ["+" if _tune_ms >= 0.0 else "", _tune_ms]
	_saved_lbl.text += "     ball lands early?  go +     ·     lands late?  go -"


func _do_save_tune() -> void:
	_result_ms = _tune_ms
	_do_save()


## The fine-tune ball: where it is in its one-second bounce, 0..1, with 0 the
## instant it touches down. This is GameConfig.song_clock()'s formula with the
## trial offset in place of the saved one — on purpose, so a value that looks
## right here is the value that is right in a level.
func _tune_bounce_phase() -> float:
	var t: float = _metro.get_playback_position() + AudioServer.get_time_since_last_mix() \
		- _tune_ms / 1000.0
	return fposmod(t, INTERVAL) / INTERVAL


func _draw_stage() -> void:
	var w: float = _stage.size.x
	var h: float = _stage.size.y
	var floor_y: float = h - 34.0
	var r: float = 20.0
	var p: float = _tune_phase
	# A thrown-ball arc: fastest at the floor, so the landing is a sharp event
	# the eye can time, not a slow approach it has to guess the end of.
	var lift: float = (h - 80.0) * 4.0 * p * (1.0 - p)
	var flash: float = _tune_flash * GameConfig.flash_scale()
	var line_col: Color = UiStyle.VIOLET.lerp(Color.WHITE, flash * 0.8)
	_stage.draw_line(Vector2(w * 0.5 - 150.0, floor_y), Vector2(w * 0.5 + 150.0, floor_y),
		line_col, 3.0 + flash * 3.0, true)
	var c := Vector2(w * 0.5, floor_y - r - lift)
	_stage.draw_circle(c, r + 7.0, Color(UiStyle.CYAN, 0.18 + flash * 0.25))
	_stage.draw_circle(c, r, UiStyle.CYAN.lerp(Color.WHITE, flash * 0.7))


# ── Update loop ───────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_pulse = maxf(0.0, _pulse - delta * 6.0)

	if _phase == Phase.TUNE:
		var p: float = _tune_bounce_phase()
		# Wrapped past the top of the loop since last frame = it just landed.
		# (Not a nudge: those move the phase by a few thousandths, not most of 1.)
		if p < _tune_phase - 0.5:
			_tune_flash = 1.0
		_tune_phase = p
		_tune_flash = maxf(0.0, _tune_flash - delta * 7.0)
		_stage.queue_redraw()
		return

	var in_pass: bool  = _phase == Phase.VISUAL or _phase == Phase.AUDIO
	var is_audio: bool = _phase == Phase.AUDIO

	if in_pass:
		# Recompute _elapsed from the monotonic clock every frame.
		# This eliminates the floating-point drift that builds up
		# when accumulating delta over many beats.
		var now_usec := Time.get_ticks_usec()
		_elapsed = float(now_usec - _run_start_usec) / 1_000_000.0

		if _elapsed >= _next_beat:
			_next_beat  += INTERVAL
			_beat_count += 1
			# Exactly one stimulus per pass: the sight pass must stay silent and
			# the sound pass must stay visually still, or the player reacts to
			# the wrong channel and the two means stop being comparable.
			if is_audio:
				_click.play()
			else:
				_pulse = 1.0
			if _beat_count > WARMUP_N:
				_title.text = "TAP!"
			else:
				_title.text = "GET READY  (%d)" % maxi(0, WARMUP_N - _beat_count + 1)

	# Pulse circle — driven only when the ring IS the stimulus, or when idling
	# on the menu. During the sound pass it holds its dim colour and fixed size.
	if not is_audio:
		var br: float = 0.12 + _pulse * 0.70
		_set_circle_color(Color(br * 0.55, br * 0.35, br, 1.0))
		var sz: float = 140.0 + _pulse * 120.0
		_circle.custom_minimum_size = Vector2(sz, sz)


# ── Input ─────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	var pressed: bool = _is_press(event)

	# Outside the tap test the mouse belongs to the on-card buttons: consuming
	# clicks here would leave them unclickable.
	var is_mouse: bool = event is InputEventMouseButton

	match _phase:

		Phase.IDLE:
			if not pressed or is_mouse:
				return
			get_viewport().set_input_as_handled()
			if event.is_action_pressed("ui_cancel"):
				_do_cancel()
			elif event is InputEventKey and \
					(event as InputEventKey).keycode == KEY_R:
				_do_reset()
			elif event is InputEventKey and \
					(event as InputEventKey).keycode == KEY_F:
				_enter_tune_from_saved()
			elif event.is_action_pressed("ui_accept") or \
					(event is InputEventKey and
					(event as InputEventKey).keycode == KEY_SPACE):
				_enter_running()

		Phase.VISUAL, Phase.AUDIO:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_enter_idle()
				return
			if not pressed:
				return
			if is_mouse and _over_buttons(event):
				return   # that click is CANCEL, not a tap
			get_viewport().set_input_as_handled()
			_record_tap()

		Phase.DONE:
			if not pressed or is_mouse:
				return
			get_viewport().set_input_as_handled()
			if event.is_action_pressed("ui_cancel"):
				_enter_idle()
			elif event is InputEventKey and \
					(event as InputEventKey).keycode == KEY_F:
				_enter_tune_from_result()
			elif event.is_action_pressed("ui_accept") or \
					(event is InputEventKey and
					(event as InputEventKey).keycode == KEY_SPACE):
				_do_save()

		Phase.TUNE:
			if is_mouse:
				return   # the mouse belongs to the nudge buttons
			# allow_echo on the nudges: holding an arrow should keep walking.
			if event.is_action_pressed("ui_left", true):
				_nudge_tune(-5.0)
			elif event.is_action_pressed("ui_right", true):
				_nudge_tune(5.0)
			elif event.is_action_pressed("ui_down", true):
				_nudge_tune(-1.0)
			elif event.is_action_pressed("ui_up", true):
				_nudge_tune(1.0)
			elif event.is_action_pressed("ui_cancel"):
				_enter_idle()
			elif event.is_action_pressed("ui_accept"):
				_do_save_tune()
			else:
				return
			get_viewport().set_input_as_handled()


# ── Tap handling ──────────────────────────────────────────────────────────────
## Which beat a tap at `elapsed` seconds into a pass belongs to, and how far
## off it was: [beat_number, lag_seconds]. Beat k is scheduled at k * INTERVAL.
## Negative lag = tapped before the beat.
##
## Pure and static so the dev harness can check it without a window. It works
## from the SCHEDULE, not from the beats that have already fired: the old code
## only looked back, so a tap 150 ms ahead of a beat was filed as 850 ms behind
## the previous one and dragged the average up by most of a second.
static func beat_for_tap(elapsed: float) -> Array:
	var k: int = int(floor((elapsed + EARLY_WINDOW) / INTERVAL))
	return [k, elapsed - float(k) * INTERVAL]


func _record_tap() -> void:
	var tap_usec := Time.get_ticks_usec()
	var hit: Array = beat_for_tap(float(tap_usec - _run_start_usec) / 1_000_000.0)
	var beat: int  = hit[0]
	var lag: float = hit[1]

	# Warm-up beats are for finding the pulse, and one beat gets one vote.
	if beat <= WARMUP_N or beat == _last_tap_beat:
		return
	_last_tap_beat = beat

	_taps.append(lag)

	# Live feedback — sign-aware to avoid displaying "+-12 ms" on early taps
	var ms:  int    = int(lag * 1000.0)
	var sgn: String = "+" if ms >= 0 else ""
	_tap_lbl.text   = "Last tap:  %s%d ms" % [sgn, ms]
	_count_lbl.text = "%d / %d" % [_taps.size(), COLLECT_N]

	if _taps.size() >= 2:
		var raw_avg: float = 0.0
		for v: float in _taps: raw_avg += v
		raw_avg /= float(_taps.size())
		var avg_sgn: String = "+" if raw_avg >= 0.0 else ""
		_avg_lbl.text = "Running avg:  %s%d ms" % [avg_sgn, int(raw_avg * 1000.0)]

	if _taps.size() >= COLLECT_N:
		if _phase == Phase.VISUAL:
			_visual_mean = _trimmed_mean(_taps)
			_visual_sd   = _trimmed_stddev(_taps)
			_enter_pass(Phase.AUDIO)
		else:
			_audio_mean = _trimmed_mean(_taps)
			_audio_sd   = _trimmed_stddev(_taps)
			_compute_result()
			_enter_done()


# ── Result math ───────────────────────────────────────────────────────────────
## Mean of `samples` with the TRIM_N highest and lowest discarded, in seconds.
## Falls back to a plain mean if there are too few samples to trim.
static func _trimmed_mean(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var trimmed: Array[float] = sorted
	if sorted.size() > TRIM_N * 2:
		trimmed = sorted.slice(TRIM_N, sorted.size() - TRIM_N)
	var avg: float = 0.0
	for v: float in trimmed:
		avg += v
	return avg / float(trimmed.size())


## Population std-dev of the trimmed set, in seconds — the consistency warning.
static func _trimmed_stddev(samples: Array[float]) -> float:
	if samples.size() < 2:
		return 0.0
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var trimmed: Array[float] = sorted
	if sorted.size() > TRIM_N * 2:
		trimmed = sorted.slice(TRIM_N, sorted.size() - TRIM_N)
	var avg: float = _trimmed_mean(samples)
	var variance: float = 0.0
	for v: float in trimmed:
		variance += (v - avg) * (v - avg)
	return sqrt(variance / float(trimmed.size()))


## Audio latency = audio pass mean - visual pass mean. Reaction time sits in
## both terms and cancels, which is the whole reason for the second pass; see
## the header. A positive result means sound arrives AFTER the picture.
func _compute_result() -> void:
	# Either pass being loose spoils the difference — this used to look at the
	# sound pass alone, so a wild sight pass saved without a word.
	_inconsistent = maxf(_visual_sd, _audio_sd) > MAX_SPREAD
	_result_ms = (_audio_mean - _visual_mean) * 1000.0


# ── Actions ───────────────────────────────────────────────────────────────────
func _do_save() -> void:
	GameConfig.set_audio_offset_for_current_device(_result_ms)
	emit_signal("calibration_complete", _result_ms)
	queue_free()


func _do_reset() -> void:
	GameConfig.clear_audio_offset_for_current_device()
	_enter_idle()


## The idle and result cards' "saved" line. "Not calibrated" is the absence of a
## saved value, not a saved value of zero.
func _saved_offset_text() -> String:
	if not GameConfig.has_audio_calibration():
		return "not calibrated  (engine estimate %.0f ms)" % GameConfig.get_audio_offset_ms()
	var ms: float = GameConfig.get_audio_offset_ms()
	return "%s%.0f ms" % ["+" if ms >= 0.0 else "", ms]


func _do_cancel() -> void:
	emit_signal("calibration_cancelled")
	queue_free()


# ── Click sound ───────────────────────────────────────────────────────────────
func _build_click() -> void:
	var sr:   int             = 22050
	var n:    int             = int(0.012 * float(sr))
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t:   float = float(i) / float(sr)
		var env: float = exp(-t * 90.0)
		var s:   int   = int(clamp(sin(t * 2800.0 * TAU) * env * 0.85, -1.0, 1.0) * 32767.0)
		data[i * 2]     = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.data = data; wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sr; wav.stereo = false
	_click = AudioStreamPlayer.new()
	# Master, not SFX: a player who has turned effects down still has to hear this.
	_click.stream = wav; _click.bus = "Master"
	_click.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_click)

	# The same click at the head of INTERVAL seconds of silence, looped.
	var loop_n: int = int(INTERVAL * float(sr))
	var loop_data: PackedByteArray = PackedByteArray()
	loop_data.resize(loop_n * 2)   # zero-filled = silence
	for i in range(n * 2):
		loop_data[i] = data[i]
	var loop := AudioStreamWAV.new()
	loop.data = loop_data; loop.format = AudioStreamWAV.FORMAT_16_BITS
	loop.mix_rate = sr; loop.stereo = false
	loop.loop_mode  = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end   = loop_n
	_metro = AudioStreamPlayer.new()
	_metro.stream = loop; _metro.bus = "Master"
	_metro.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_metro)


# ── UI ────────────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.015, 0.008, 0.045, 0.94)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	# This opens over the paused game, so it sits directly next to the pause
	# plate and has to be built from the same chassis.
	var card := PlatePanel.create(34, UiStyle.CYAN, 26.0)
	card.custom_minimum_size = Vector2(720, 0)
	centre.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	card.content.add_child(col)

	_title = _lbl("", 30, Color(1.0, 0.80, 1.0), UiStyle.caption(7.0))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)

	_dev_lbl = _lbl("", 12, Color(0.55, 0.50, 0.68), UiStyle.caption(2.0))
	_dev_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_dev_lbl)

	_saved_lbl = _lbl("", 15, UiStyle.CYAN, UiStyle.display(700))
	_saved_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_saved_lbl)

	_body = _lbl("", 18, Color(0.85, 0.85, 1.0))
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # handles multi-line BT info
	col.add_child(_body)

	# Pulsing circle
	var cw := CenterContainer.new()
	cw.custom_minimum_size = Vector2(0, 250)
	col.add_child(cw)
	# A diamond rather than a plain square: all four corners chamfered by more
	# than half the size collapses the plate SDF into one.
	_circle = ColorRect.new()
	_circle.custom_minimum_size = Vector2(150, 150)
	var cm := ShaderMaterial.new()
	cm.shader = load("res://shaders/hud_plate.gdshader") as Shader
	cm.set_shader_parameter("cut_size", 999.0)
	cm.set_shader_parameter("cut_tl", 1.0); cm.set_shader_parameter("cut_tr", 1.0)
	cm.set_shader_parameter("cut_br", 1.0); cm.set_shader_parameter("cut_bl", 1.0)
	cm.set_shader_parameter("grid_amount", 0.0)
	cm.set_shader_parameter("scan_amount", 0.0)
	cm.set_shader_parameter("glow_px", 26.0)
	cm.set_shader_parameter("edge_px", 2.4)
	_circle.material = cm
	_circle.resized.connect(func() -> void:
		cm.set_shader_parameter("rect_size", _circle.size))
	cw.add_child(_circle)
	_ring_wrap = cw

	# Fine-tune stage: takes the ring's place while that phase is up.
	_stage = Control.new()
	_stage.custom_minimum_size = Vector2(0, 250)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.visible = false
	_stage.draw.connect(_draw_stage)
	col.add_child(_stage)

	# Measurement labels (visible only during RUNNING phase)
	_count_lbl = _lbl("", 30, Color(0.55, 1.00, 0.70), UiStyle.display(800))
	_count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_count_lbl)
	_measure_nodes.append(_count_lbl)

	_tap_lbl = _lbl("", 17, UiStyle.GOLD, UiStyle.display(700))
	_tap_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_tap_lbl)
	_measure_nodes.append(_tap_lbl)

	_avg_lbl = _lbl("", 17, Color(0.55, 1.00, 0.70), UiStyle.display(700))
	_avg_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_avg_lbl)
	_measure_nodes.append(_avg_lbl)

	_btn_row = HBoxContainer.new()
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_btn_row.add_theme_constant_override("separation", 14)
	col.add_child(_btn_row)

	_hint = _lbl("", 11, Color(0.55, 0.50, 0.68), UiStyle.caption(2.0))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_hint)


## Swaps the button row for the current phase. Each spec is
## [label, on_pressed, accent].
func _set_buttons(specs: Array, min_width: float = 190.0) -> void:
	if _btn_row == null:
		return
	for c in _btn_row.get_children():
		_btn_row.remove_child(c)
		c.queue_free()
	for spec: Array in specs:
		var b := PlateButton.create(String(spec[0]), spec[1], 14, spec[2])
		b.custom_minimum_size = Vector2(min_width, 44)
		b.set_padding(16.0, 9.0)
		# The phase machine already answers ui_accept and ui_cancel directly, so
		# a focusable button here would be a second, competing way to fire the
		# same action — and would steal Enter from the tap test.
		b.focus_mode = Control.FOCUS_NONE
		_btn_row.add_child(b)


## True when a click landed on the button row. During the tap test every click
## counts as a tap, which would otherwise make CANCEL impossible to press.
func _over_buttons(event: InputEvent) -> bool:
	if _btn_row == null or not _btn_row.is_visible_in_tree():
		return false
	var mb := event as InputEventMouseButton
	return mb != null and _btn_row.get_global_rect().has_point(mb.position)


## The pulse used to drive ColorRect.color, which the plate shader ignores — it
## paints every pixel itself. Route it to the edge colour instead.
func _set_circle_color(c: Color) -> void:
	if _circle == null:
		return
	var m := _circle.material as ShaderMaterial
	if m != null:
		m.set_shader_parameter("edge_color", c)
		m.set_shader_parameter("edge_color2", c.lightened(0.25))
		m.set_shader_parameter("fill_color", Color(c.r * 0.18, c.g * 0.12, c.b * 0.30, 0.85))


## Swaps the pulsing ring for the fine-tune stage, or back.
func _show_stage(on: bool) -> void:
	if _stage != null:
		_stage.visible = on
	if _ring_wrap != null:
		_ring_wrap.visible = not on


func _set_measure_visible(v: bool) -> void:
	for lbl: Label in _measure_nodes:
		lbl.visible = v


func _is_press(event: InputEvent) -> bool:
	if event is InputEventKey:
		return (event as InputEventKey).is_pressed() and \
			   not (event as InputEventKey).is_echo()
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).is_pressed()
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).is_pressed()
	if event is InputEventScreenTouch:                          # Android tap support
		return (event as InputEventScreenTouch).is_pressed()
	return false


## `font` picks the face: tracked caps for headings and hints, Orbitron for the
## millisecond readouts, body for prose.
func _lbl(text: String, size: int, col: Color, font: Font = null) -> Label:
	if font == null:
		font = UiStyle.body()
	return UiStyle.label(text, font, size, col)
