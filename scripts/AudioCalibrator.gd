extends CanvasLayer
## Audio latency calibrator — three-phase flow.
##
##  IDLE    → shows current device + saved offset + Bluetooth detection
##            [ENTER] start calibration   [R] reset to 0   [ESC] close
##
##  RUNNING → 60 BPM click track; tap any button when you HEAR each click.
##            Collects 20 taps, discards the 4 highest + 4 lowest outliers,
##            averages the remaining 12 (trimmed mean).  Shows live per-tap
##            feedback and a running average so you can see consistency.
##            [ESC] back to idle without saving
##
##  DONE    → shows measured result and consistency rating
##            [ENTER] save and close   [ESC] discard and go back
##
## Add as a child of any PROCESS_MODE_ALWAYS node (Section is already set to
## that while paused, so just add_child(cal) from _launch_audio_calibrator).

signal calibration_complete(offset_ms: float)
signal calibration_cancelled

# ── Config ────────────────────────────────────────────────────────────────────
const BPM:       float = 60.0
const INTERVAL:  float = 60.0 / BPM     # 1.000 s — comfortable tapping pace
const WARMUP_N:  int   = 4              # beats to play before measuring
const COLLECT_N: int   = 20             # total taps to collect
const TRIM_N:    int   = 4              # discard this many highest + lowest
# Max lag accepted per tap — 88 % of interval covers ~880 ms (worst Bluetooth).
const MAX_LAG:   float = INTERVAL * 0.88

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
enum Phase { IDLE, RUNNING, DONE }
var _phase: Phase = Phase.IDLE

var _elapsed:    float        = 0.0
var _next_beat:  float        = 1.0
var _beat_count: int          = 0
var _taps:       Array[float] = []
var _pulse:      float        = 0.0
var _result_ms:  float        = 0.0
var _inconsistent: bool       = false

# High-precision timing — replaces delta accumulation to eliminate drift.
var _run_start_usec: int       = 0
var _beat_usec_log:  Array[int] = []   # exact usec timestamp of each post-warmup beat

# ── Audio ─────────────────────────────────────────────────────────────────────
var _click: AudioStreamPlayer = null

# ── UI refs ───────────────────────────────────────────────────────────────────
var _title:      Label     = null
var _dev_lbl:    Label     = null
var _saved_lbl:  Label     = null
var _body:       Label     = null
var _circle:     ColorRect = null
var _count_lbl:  Label     = null
var _tap_lbl:    Label     = null
var _avg_lbl:    Label     = null
var _hint:       Label     = null
var _measure_nodes: Array[Label] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 120
	_build_click()
	_build_ui()
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
	_elapsed    = 0.0
	_beat_count = 0
	_taps.clear()
	_beat_usec_log.clear()
	_set_measure_visible(false)

	var dev      := AudioServer.get_output_device()
	var saved_ms := GameConfig.get_audio_offset_ms()
	var suggest  := _auto_suggest()

	var ms_str: String = ("not calibrated" if saved_ms == 0.0
		else ("%s%.0f ms" % ["+" if saved_ms >= 0.0 else "", saved_ms]))

	_title.text     = "AUDIO LATENCY"
	_dev_lbl.text   = "Device:  %s  [%s]" % [dev, suggest.label]
	_saved_lbl.text = "Saved offset:  %s" % ms_str

	if suggest.is_bt and saved_ms == 0.0:
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
		_body.text = "Tap in sync with what you HEAR — not what you see.\nWorks best with headphones on and eyes closed."

	_hint.text    = "[ENTER]  Calibrate     [R]  Reset to 0     [ESC]  Close"
	_set_circle_color(Color(0.35, 0.20, 0.70, 1.0))


func _enter_running() -> void:
	_phase      = Phase.RUNNING
	_elapsed    = 0.0
	_next_beat  = 1.0
	_beat_count = 0
	_taps.clear()
	_beat_usec_log.clear()
	_run_start_usec = Time.get_ticks_usec()   # anchor to monotonic clock
	_set_measure_visible(true)

	_title.text     = "GET READY…"
	_dev_lbl.text   = ""
	_saved_lbl.text = ""
	_body.text      = "Tap any button each time you HEAR the click"
	_count_lbl.text = "0 / %d" % COLLECT_N
	_tap_lbl.text   = ""
	_avg_lbl.text   = ""
	_hint.text      = "[ESC]  Cancel"


func _enter_done() -> void:
	_phase = Phase.DONE
	_click.stop()
	_set_measure_visible(false)

	var sign: String = "+" if _result_ms >= 0.0 else ""
	var ms:   float  = GameConfig.get_audio_offset_ms()
	var ms_str: String = ("not calibrated" if ms == 0.0
		else ("%s%.0f ms" % ["+" if ms >= 0.0 else "", ms]))

	_title.text     = "RESULT"
	_dev_lbl.text   = ""
	_saved_lbl.text = "Previously saved:  %s" % ms_str
	_body.text      = ("Measured offset:  %s%.0f ms" % [sign, _result_ms])
	if _inconsistent:
		_body.text += "\n⚠  Inconsistent taps — consider redoing calibration"
	_hint.text      = "[ENTER]  Save & close     [ESC]  Discard"


# ── Update loop ───────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_pulse = maxf(0.0, _pulse - delta * 6.0)

	if _phase == Phase.RUNNING:
		# Recompute _elapsed from the monotonic clock every frame.
		# This eliminates the floating-point drift that builds up
		# when accumulating delta over 20+ beats.
		var now_usec := Time.get_ticks_usec()
		_elapsed = float(now_usec - _run_start_usec) / 1_000_000.0

		if _elapsed >= _next_beat:
			_next_beat  += INTERVAL
			_beat_count += 1
			_click.play()
			_pulse = 1.0
			var measuring := _beat_count > WARMUP_N
			if measuring:
				_beat_usec_log.append(now_usec)   # log exact usec for this beat
				_title.text = "TAP!"
			else:
				_title.text = "GET READY  (%d)" % maxi(0, WARMUP_N - _beat_count + 1)

	# Pulse circle
	var br: float = 0.12 + _pulse * 0.70
	_set_circle_color(Color(br * 0.55, br * 0.35, br, 1.0))
	var sz: float = 140.0 + _pulse * 120.0
	_circle.custom_minimum_size = Vector2(sz, sz)


# ── Input ─────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	var pressed: bool = _is_press(event)

	match _phase:

		Phase.IDLE:
			if not pressed:
				return
			get_viewport().set_input_as_handled()
			if event.is_action_pressed("ui_cancel"):
				_do_cancel()
			elif event is InputEventKey and \
					(event as InputEventKey).keycode == KEY_R:
				_do_reset()
			elif event.is_action_pressed("ui_accept") or \
					(event is InputEventKey and
					(event as InputEventKey).keycode == KEY_SPACE):
				_enter_running()

		Phase.RUNNING:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_enter_idle()
				return
			if not pressed or _beat_count <= WARMUP_N:
				return
			get_viewport().set_input_as_handled()
			_record_tap()

		Phase.DONE:
			if not pressed:
				return
			get_viewport().set_input_as_handled()
			if event.is_action_pressed("ui_cancel"):
				_enter_idle()
			elif event.is_action_pressed("ui_accept") or \
					(event is InputEventKey and
					(event as InputEventKey).keycode == KEY_SPACE):
				_do_save()


# ── Tap handling ──────────────────────────────────────────────────────────────
func _record_tap() -> void:
	if _beat_usec_log.is_empty():
		return   # tapped before any measuring beat fired

	var tap_usec := Time.get_ticks_usec()

	# Find which logged beat is nearest to this tap.
	# Only need to check the last two — taps always land close to the most recent beat.
	var nearest_usec := _beat_usec_log[_beat_usec_log.size() - 1]
	if _beat_usec_log.size() >= 2:
		var prev_usec := _beat_usec_log[_beat_usec_log.size() - 2]
		if absi(tap_usec - prev_usec) < absi(tap_usec - nearest_usec):
			nearest_usec = prev_usec

	# Positive = tapped after the beat fired = audio is delayed. Expected for BT.
	var lag := float(tap_usec - nearest_usec) / 1_000_000.0

	if absf(lag) > MAX_LAG:
		return   # wild tap, ignore

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
		_compute_result()
		_enter_done()


# ── Result math ───────────────────────────────────────────────────────────────
func _compute_result() -> void:
	var sorted: Array[float] = _taps.duplicate()
	sorted.sort()
	var trimmed: Array[float] = sorted.slice(TRIM_N, sorted.size() - TRIM_N)

	var avg: float = 0.0
	for v: float in trimmed: avg += v
	avg /= float(trimmed.size())

	# Warn if std-dev of trimmed set > 40 ms
	var variance: float = 0.0
	for v: float in trimmed: variance += (v - avg) * (v - avg)
	variance /= float(trimmed.size())
	_inconsistent = sqrt(variance) > 0.04

	# Positive avg = tapped late = audio is delayed.
	# Add to song_time() to shift visuals forward to match.
	_result_ms = avg * 1000.0


# ── Actions ───────────────────────────────────────────────────────────────────
func _do_save() -> void:
	GameConfig.set_audio_offset_for_current_device(_result_ms)
	emit_signal("calibration_complete", _result_ms)
	queue_free()


func _do_reset() -> void:
	GameConfig.set_audio_offset_for_current_device(0.0)
	_enter_idle()


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
	_click.stream = wav; _click.bus = "Master"
	_click.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_click)


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

	_hint = _lbl("", 11, Color(0.55, 0.50, 0.68), UiStyle.caption(2.0))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_hint)


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
