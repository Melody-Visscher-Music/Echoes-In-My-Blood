extends Control

# ============================================================
# Multi-pass tap capture (Ctrl+-)
# ============================================================
var capture_popup: PopupPanel
var capture_status_label: Label
var capture_pass_label: Label

var cap_cb_beats: CheckBox
var cap_cb_melody: CheckBox
var cap_cb_fx: CheckBox
var cap_cb_clear_first: CheckBox
var cap_cb_use_analysis: CheckBox

var cap_sb_lane_gap_ms: SpinBox
var cap_sb_global_gap_ms: SpinBox
var cap_sb_beat_snap_ms: SpinBox
var cap_sb_onset_snap_ms: SpinBox

var capture_active: bool = false
var capture_passes: Array[Dictionary] = []
var capture_pass_index: int = -1
var capture_taps_by_pass: Dictionary = {}     # pass_id -> Array[float]
var capture_started_song: bool = false
var capture_last_playing_state: bool = false

var capture_lane_gap_ms: int = 100
var capture_global_gap_ms: int = 45
var capture_beat_snap_ms: int = 40
var capture_onset_snap_ms: int = 28
var capture_use_analysis: bool = true
var capture_clear_first: bool = true

var cap_beats_lane_cbs: Array[CheckBox] = []
var cap_melody_lane_cbs: Array[CheckBox] = []
var cap_fx_lane_cbs: Array[CheckBox] = []
var capture_saved_data: Dictionary = {}

var capture_pass_lane_config: Dictionary = {
	"beats": [0, 2],
	"melody": [1, 3],
	"fx": [0, 1, 2, 3],
}
# ============================================================
# debug
# ============================================================
var analyzer_debug_log: bool = true
var _analyzer_dbg_last_progress_print_ms: int = -999999
var _analyzer_dbg_last_progress_key: String = ""

# ============================================================
# Scene refs
# ============================================================
@onready var song_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var info: Label = $Info
@onready var key_edit: LineEdit = $Top/BeatmapKey
@onready var bpm_edit: LineEdit = $Top/BPM
@onready var offset_edit: LineEdit = $Top/Offset
@onready var path_edit: LineEdit = $Top/Path
@onready var top_bar: Control = $Top

# ============================================================
# External tools
# ============================================================
@export var python_executable: String = ProjectSettings.globalize_path("res://tools/.venv-fusion/Scripts/pythonw.exe")
@export var analyzer_script_path: String = "res://tools/BeatmapAnalyzer.py"
@export var analysis_output_dir: String = "res://data/Analysis/" # auto-fallback to user://analysis/ if not writable

# ============================================================
# Analyzer settings (configurable CLI args)
# ============================================================
var analyzer_settings_popup: PopupPanel

# --- BeatNet + Librosa fusion analyzer settings ---
# BeatNet supplies the macro grid (tempo + bar phase); librosa does the
# band-split onset work and the sample-accurate placement.
# Auto mode lets the analyzer derive the tempo window, per-band onset
# thresholds and snap window from the audio itself. On by default -- the manual
# values below are only a fallback for when it is switched off.
var analyzer_auto: bool = true
var analyzer_use_beatnet: bool = true
var analyzer_min_bpm: float = 120.0
var analyzer_max_bpm: float = 200.0
var analyzer_ts: int = 4
var analyzer_snap_ms: float = 18.0
var analyzer_onset_delta: float = 0.055
var analyzer_quick_seconds: int = 0

# MapGen (mixed-lane beatmap generation)
var analyzer_mapgen: bool = true
var analyzer_map_diff: int = 5 # 1..10
var analyzer_map_lanes: int = 2 # 2 = beats lane + melody lane
var analyzer_map_min_gap_ms: int = 85
var analyzer_map_allow_chords: bool = false

# ============================================================
# Analyzer runtime (async process + popup progress UI)
# ============================================================
var _analyzer_pid: int = -1
var _analyzer_out_path: String = ""              # user:// or res:// path we intended
var _analyzer_progress_path: String = ""         # progress JSON path (user:// / res://)
var _analyzer_cancel_path: String = ""           # cancel-file path (user:// / res://)
var _analyzer_cancel_requested: bool = false

var _analyzer_reported_out_abs: String = ""      # absolute output path reported by analyzer progress JSON
var _analyzer_poll_accum: float = 0.0
var _analyzer_last_msg: String = ""
var _analyzer_hide_seq: int = 0
var _analyzer_start_unix: int = 0
var _analyzer_finalize_tries_left: int = 0
var _analyzer_finalize_exit_code: int = 0
var _analyzer_audio_stem: String = ""
var _analyzer_expected_out_abs: String = ""
var _analyzer_expected_dir_abs: String = ""
var _analyzer_last_pct: float = 0.0

var analyzer_progress_popup: PopupPanel
var analyzer_progress_label: Label
var analyzer_progress_bar
var analyzer_progress_cancel_btn: Button

class RainbowSheenBar extends Control:
	var value: float = 0.0
	var message: String = ""
	var _phase: float = 0.0

	func _ready() -> void:
		clip_contents = true
		set_process(false)

	func start() -> void:
		_phase = 0.0
		set_process(true)
		queue_redraw()

	func stop() -> void:
		set_process(false)

	func set_progress(pct: float, msg: String = "") -> void:
		value = clamp(pct, 0.0, 100.0)
		message = msg
		queue_redraw()

	func _process(delta: float) -> void:
		_phase += delta
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < 2.0 or h < 2.0:
			return

		# background
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.531, 0.583, 0.684, 0.95), true)

		# fill (rainbow)
		var fill_w: float = w * (value / 100.0)
		var stripe_w: float = 2.0
		var hue_shift: float = fposmod(_phase * 0.18, 1.0)

		var x: float = 0.0
		while x < fill_w:
			var hue: float = fposmod((x / max(1.0, w)) + hue_shift, 1.0)
			var col: Color = Color.from_hsv(hue, 0.85, 1.0, 1.0)
			draw_rect(Rect2(x, 0.0, min(stripe_w, fill_w - x), h), col, true)
			x += stripe_w

		# glossy top tint
		if fill_w > 0.0:
			draw_rect(Rect2(0.0, 0.0, fill_w, h * 0.45), Color(1, 1, 1, 0.10), true)

		# white "installing" sheen sweep over the filled region
		var sheen_w: float = 86.0
		var center: float = fposmod(_phase * 240.0, w + sheen_w) - sheen_w * 0.5
		var sx0: int = int(max(0.0, center - sheen_w))
		var sx1: int = int(min(fill_w, center + sheen_w))
		for xi in range(sx0, sx1):
			var d: float = abs(float(xi) - center) / sheen_w
			var a: float = (1.0 - d) * 0.35
			if a > 0.001:
				draw_rect(Rect2(float(xi), 0.0, 1.0, h), Color(1, 1, 1, a), true)

		# border
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.18), false, 2.0)

		# centered percent text
		var pct_txt: String = "%d%%" % int(round(value))
		var fnt: Font = get_theme_default_font()
		var fs: int = get_theme_default_font_size()
		if fnt != null:
			var ts: Vector2 = fnt.get_string_size(pct_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var pos: Vector2 = Vector2((w - ts.x) * 0.5, (h + ts.y) * 0.5 - 3.0)
			draw_string(fnt, pos + Vector2(0, 1), pct_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.35))
			draw_string(fnt, pos, pct_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.92))

# ============================================================
# Top UI styling (happy colors)
# ============================================================
@export var ui_top_bg: Color = Color(0.10, 0.12, 0.18, 0.95)
@export var ui_text: Color = Color(0.95, 0.97, 1.00, 1.0)
@export var ui_accent_a: Color = Color(0.20, 0.90, 0.70, 1.0) # mint
@export var ui_accent_b: Color = Color(0.35, 0.70, 1.00, 1.0) # sky
@export var ui_accent_c: Color = Color(1.00, 0.62, 0.30, 1.0) # orange
@export var ui_accent_d: Color = Color(0.95, 0.45, 0.85, 1.0) # pink

var _top_bg_panel: Panel = null

# ============================================================
# AutoFinish (Ctrl+U popup)
# ============================================================
var autofinish_popup: PopupPanel
var af_cb_clear_first: CheckBox
var af_cb_quantize: CheckBox
var af_cb_beats: CheckBox
var af_cb_downbeats: CheckBox
var af_cb_onsets: CheckBox
var af_cb_mapgen: CheckBox # use analyzer map_notes
var af_cb_two_lane: CheckBox # lane 0 = beats (pink), lane 1 = melody (blue)
var af_cb_refine_align: CheckBox
var af_cb_refine_fill: CheckBox
var af_cb_refine_rolls: CheckBox
var af_sb_refine_max: SpinBox

var af_sb_beats_every: SpinBox
var af_sb_lane_sep_ms: SpinBox
var af_sb_onset_avoid_beat_ms: SpinBox
var af_sl_onset_strength: HSlider
var af_lbl_onset_strength: Label

var af_lane_opts: Array[OptionButton] = []
var autofinish_lane_map: Array[String] = [] # len lane_count, values: "off","beats","downbeats","onsets"

var autofinish_apply_quantize: bool = true
var autofinish_use_mapgen: bool = true # NEW: default on
# Two-lane charting: lane 0 = beats (pink), lane 1 = melody (blue). The
# analyzer already classifies every note, so with this on there is nothing
# left to configure -- no per-lane beats/downbeats/onsets decisions.
var autofinish_two_lane: bool = true

# --- Refine mode (AutoFinish with "clear" unchecked on an existing chart) ---
# The existing chart is treated as the style oracle: it decides which windows
# are meant to be quiet, how dense they are, and where rolls belong. The
# analyzer only supplies the timing truth and the candidates.
var autofinish_refine_max_ms: int = 55          # per-note snap window
var autofinish_refine_align_true: bool = true   # strip the chart's own latency
var autofinish_refine_fill_gaps: bool = true
var autofinish_refine_complete_rolls: bool = true

# ============================================================
# Beatmap data
# ============================================================
var events: Array[Dictionary] = [] # each event has id,t,type,lane,dur,category,role,...
var _next_event_id: int = 1

# Sorted cache for drawing (perf)
var _events_dirty: bool = true
var _events_sorted: Array[Dictionary] = []

# ============================================================
# Categories / roles
# ============================================================
const CATEGORY_LIST: Array = ["generic", "enemy", "world", "fx"]
const ROLES_BY_CATEGORY := {
	"generic": ["generic"],
	"enemy": ["melee", "ranged", "charger", "aoe"],
	"world": ["gap", "wall", "hazard", "platform"],
	"fx": ["light", "screen", "camera", "env"]
}

# Category base colors (primary identity)
const CAT_BASE := {
	"generic": Color(0.90, 0.90, 0.90, 1.0),
	"enemy":   Color(1.00, 0.28, 0.28, 1.0),
	"world":   Color(0.20, 1.00, 0.50, 1.0),
	"fx":      Color(0.30, 0.65, 1.00, 1.0),
}

# Border emphasis per category
const CAT_BORDER_ALPHA := {
	"generic": 0.20,
	"enemy":   0.55,
	"world":   0.40,
	"fx":      0.45,
}

# Role patterns per category (same base color, different overlay texture)
# kind: "none", "stripes", "dots", "grid", "scan", "chevron", "cross"
const ROLE_PATTERNS := {
	"generic": {
		"generic": {"kind":"none"},
	},
	"enemy": {
		"melee":   {"kind":"stripes", "step":10.0, "thickness":2.0, "alpha":0.35},
		"ranged":  {"kind":"dots",    "step":12.0, "radius":2.0,    "alpha":0.35},
		"charger": {"kind":"chevron", "step":14.0, "thickness":2.0, "alpha":0.40},
		"aoe":     {"kind":"cross",   "step":12.0, "thickness":2.0, "alpha":0.38},
	},
	"world": {
		"gap":      {"kind":"scan",    "step":10.0, "thickness":2.0, "alpha":0.32},
		"wall":     {"kind":"grid",    "step":12.0, "thickness":2.0, "alpha":0.30},
		"hazard":   {"kind":"stripes", "step":8.0,  "thickness":3.0, "alpha":0.45},
		"platform": {"kind":"dots",    "step":14.0, "radius":2.0,    "alpha":0.28},
	},
	"fx": {
		"light":  {"kind":"dots",  "step":10.0, "radius":1.8, "alpha":0.35},
		"screen": {"kind":"scan",  "step":6.0,  "thickness":1.5, "alpha":0.35},
		"camera": {"kind":"grid",  "step":16.0, "thickness":1.5, "alpha":0.30},
		"env":    {"kind":"cross", "step":16.0, "thickness":1.5, "alpha":0.28},
	},
}

# Tagging: what new events are created as
var current_category: String = "generic"
var current_role: String = "generic"

# Holds: disabled by default so you don't create them by accident
var holds_enabled: bool = false
const HOLD_MIN: float = 0.18

# ============================================================
# Lane meaning editor (schema)
# ============================================================
var lane_count: int = 4
var lane_schema: Array[Dictionary] = [
	{"category":"any","role":"any","label":"Lane 0","comment":""},
	{"category":"any","role":"any","label":"Lane 1","comment":""},
	{"category":"any","role":"any","label":"Lane 2","comment":""},
	{"category":"any","role":"any","label":"Lane 3","comment":""},
]

# ============================================================
# Popups
# ============================================================
var tag_popup: PopupPanel
var tag_category_opt: OptionButton
var tag_role_opt: OptionButton

var lint_popup: PopupPanel
var lint_results: RichTextLabel
var lint_btn_sort: Button
var lint_btn_normalize: Button

var schema_popup: PopupPanel
var _schema_cat_opts: Array[OptionButton] = []
var _schema_role_opts: Array[OptionButton] = []
var _schema_label_edits: Array[LineEdit] = []
var _schema_comment_edits: Array[LineEdit] = []

# Analysis popup
var analysis_popup: PopupPanel
var analysis_label: RichTextLabel

# Rap segments popup
var rap_popup: Window
var _rap_seg_container: VBoxContainer     # parent for per-segment rows
var _rap_seg_rows: Array[Dictionary] = [] # [{hbox, start_sb, end_sb}]
var _drop_seg_container: VBoxContainer     # parent for charge-tunnel buildup rows
var _drop_seg_rows: Array[Dictionary] = [] # [{hbox, start_sb, end_sb, idx_lbl}]
var _rap_taps_edit: TextEdit
var _rap_words_edit: TextEdit               # rap lyrics — words pair 1:1 with the taps above
var _sung_lines_edit: TextEdit              # sung lines (not orbs): "<time>  whole sentence" per row
var lyrics_data: Array[Dictionary] = []     # built on OK / loaded; exported as "lyrics"
var lyric_font_choice: String        = "random"  # "random" or a filename in res://fonts/
var _available_fonts:  Array[String] = []
var _font_picker_popup: PopupPanel   = null
var _font_opt:          OptionButton = null
var _font_preview_lbl:  Label        = null
var electric_zones:      Array[Dictionary] = []   # [{start_t, end_t}] seconds
var _elec_popup:         PopupPanel        = null
var _preview_win:        Window            = null
var _preview_3d:         Node              = null
var _audio_calib_win:    Window            = null   # audio latency calibration — same GameConfig backend as the game
var _audio_calib_dev_lbl:    Label         = null
var _audio_calib_offset_lbl: Label         = null
var _audio_calib_engine_lbl: Label         = null
var _audio_calib_active_node: Node         = null   # live res://scripts/AudioCalibrator.gd instance, if calibration is running
var _main_menu_confirm: ConfirmationDialog = null
var _elec_seg_container: VBoxContainer     = null
var _elec_seg_rows:      Array[Dictionary] = []   # [{hbox, start_sb, end_sb, idx_lbl}]
# Sung-line tap-timing state (tap B at each sentence's start, then its end)
var _sung_status: Label
var _sung_timing: bool      = false
var _sung_lines_text: Array = []            # sentences being timed (stripped of any times)
var _sung_starts: Array     = []            # parallel start times (null = unset)
var _sung_ends: Array       = []            # parallel end times
var _sung_idx: int          = 0
var _sung_have_start: bool  = false
# Live box-resize drag (drag a grip under a TextEdit to make it taller)
var _resize_target: TextEdit = null
var _resize_anchor_y: float  = 0.0
var _resize_start_h: float   = 0.0

# ============================================================
# Rap data (saved to / loaded from beatmap JSON)
# ============================================================
var rap_segments: Array[Dictionary] = []  # [{start_t, end_t}]
var rap_taps:     Array[float]      = []  # tap times in seconds

# Charge-tunnel "drop buildups" — [{start_t, end_t}] (seconds). Engine: _parse_drop_buildups.
var drop_buildups: Array[Dictionary] = []

# ============================================================
# Meta
# ============================================================
var beatmap_key: String = ""
var bpm: float = 150.0
var offset_ms: int = 0

# ============================================================
# Playback / speed UI
# ============================================================
var speed_value: float = 1.0
var speed_slider: HSlider
var speed_readout: Label

# ============================================================
# Lanes / geometry
# ============================================================
var hit_y: float = 620.0
var spawn_y: float = 80.0

# approach_time controls "zoom" (seconds from spawn to hit line)
var approach_time: float = 1.00
var pps: float = 540.0

const NOTE_H: float = 18.0
const NOTE_PAD_X: float = 6.0

# ============================================================
# Quantize / latency / preview
# ============================================================
var quantize_on: bool = false
var quantize_div: int = 16
var latency_ms: int = 0
var preview_enabled: bool = false
var show_minimap: bool = true
var show_grid: bool = true
var show_help: bool = true

# Smart quantize using analysis beats
var smart_quantize: bool = true
var smart_quantize_window_ms: int = 90

# ============================================================
# Analysis data (loaded from BeatmapAnalyzer.py JSON)
# ============================================================
var analysis_path: String = ""
var analysis_data: Dictionary = {}
var analysis_beats_ms: Array[int] = []
var analysis_downbeats_ms: Array[int] = []
var analysis_onsets: Array[Dictionary] = [] # {t_ms,strength,band,src?}
var analysis_rms_t_ms: Array[int] = []
var analysis_rms_v: Array[float] = []
var analysis_onsetenv_t_ms: Array[int] = []
var analysis_onsetenv_v: Array[float] = []

# NEW: MapGen notes (mixed-lane beatmap)
var analysis_map_notes: Array[Dictionary] = [] # [{t,lane,kind,basis,intensity,...}]
var analysis_bars: Array[Dictionary] = []      # v3: per-bar features + tags
var analysis_sections: Array[Dictionary] = []  # v3: drop / breakdown / buildup / fake_drop

var show_analysis_guides: bool = true
var show_analysis_envelopes: bool = true

# Assist mode (step through suggestions)
var assist_enabled: bool = true
var assist_source: String = "beats" # beats | onsets
var assist_index: int = 0

# ============================================================
# AutoFinish (Ctrl+U) settings
# ============================================================
var autofinish_include_beats: bool = true
var autofinish_include_downbeats: bool = true
var autofinish_include_onsets: bool = true

# Map density controls
var autofinish_beats_every: int = 1 # 1=every beat, 2=every other beat, 4=quarter notes only, etc.
# Per-lane minimum spacing. Kept just under a 1/16 note at hard-dance tempo
# (~97 ms at 154 BPM) so it removes genuine duplicates without deleting the
# kick rolls and triplets the analyzer went to the trouble of finding.
var autofinish_lane_min_sep_ms: int = 90

# Onset filtering
var autofinish_onset_strength_min: float = 0.72
var autofinish_onset_avoid_near_beat_ms: int = 40 # skip onsets within this window of a detected beat

# ============================================================
# Follow playhead vs editor view time
# ============================================================
var follow_playhead: bool = true
var view_time: float = 0.0

# ============================================================
# Gamepad polling
# ============================================================
const JOY_DZ: float = 0.45
var _prev_strength: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _press_started_at: Array[float] = [-1.0, -1.0, -1.0, -1.0]

# ============================================================
# Visuals (existing lane colors)
# ============================================================
const MINIMAP_H: float = 96.0
const MINIMAP_PAD: float = 8.0
var LANE_COLS: Array[Color] = [
	Color(0.00, 0.85, 1.00, 1.0),
	Color(0.20, 1.00, 0.40, 1.0),
	Color(1.00, 0.90, 0.10, 1.0),
	Color(1.00, 0.25, 0.55, 1.0)
]
var GRID_COL: Color  = Color(1,1,1,0.16)
var GRID_MAIN: Color = Color(1,1,1,0.30)
var HIT_OK: Color    = Color(0.40,1.00,0.60,0.75)
var HIT_BAD: Color   = Color(1.00,0.35,0.35,0.75)

var _flash_ok_until: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _flash_bad_until: Array[float] = [0.0, 0.0, 0.0, 0.0]

const CAPTURE_PASS_COLORS := {
	"beats": Color(1.0, 0.0, 0.667, 1.0),    # pink
	"melody": Color(0.20, 0.85, 1.00, 1.0),  # blue
	"fx": Color(0.0, 1.0, 0.167, 1.0),       # green
}

# Analyzer role classes, coloured to match the capture passes above so the two
# systems read the same way: pink is the pulse, blue is the tune.
const ROLE_CLASS_COLORS := {
	"beat": Color(1.00, 0.00, 0.667, 1.0),   # pink  -- kick / gated kick / hats
	"melody": Color(0.20, 0.85, 1.00, 1.0),  # blue  -- screech / lead
}

# Which editor lane each analyzer role class owns in a two-lane chart.
const ROLE_CLASS_LANE := {"beat": 0, "melody": 1}

# Role class -> capture_pass. The game runtime keys off capture_pass alone:
# "beats" become tapped gameplay events, "melody" and "fx" become world FX.
const ROLE_CLASS_PASS := {"beat": "beats", "melody": "melody"}

# ============================================================
# Mouse hover / ghost preview
# ============================================================
var _mouse_pos: Vector2 = Vector2.ZERO
var _mouse_in_track: bool = false
var _mouse_in_minimap: bool = false
var _mouse_lane: int = 0
var _mouse_time: float = 0.0

# ============================================================
# Selection system (stable IDs)
# ============================================================
var selected_ids: Array[int] = []
var _selected_set: Dictionary = {}

var _marquee_active: bool = false
var _marquee_start: Vector2 = Vector2.ZERO
var _marquee_end: Vector2 = Vector2.ZERO

var _scrub_active: bool = false

var _move_active: bool = false
var _move_start_pos: Vector2 = Vector2.ZERO
var _move_start_snapshot: Dictionary = {}

var _clipboard_events: Array[Dictionary] = []
var _clipboard_min_t: float = 0.0

# ============================================================
# Undo/Redo
# ============================================================
const UNDO_LIMIT: int = 120
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _action_temp: Dictionary = {}

# Wheel behavior:
const ZOOM_STEP: float = 0.90
const ZOOM_FINE_STEP: float = 0.96

# Lint thresholds
var lint_min_sep_s: float = 0.06

# ============================================================
# Gamepad editor cursor / editing
# ============================================================
var gp_editor_enabled: bool = true
var gp_cursor_initialized: bool = false
var gp_cursor_lane: int = 0
var gp_cursor_time: float = 0.0

const GP_CURSOR_STEP_FREE: float = 0.050
const GP_NAV_FIRST_DELAY: float = 0.24
const GP_NAV_REPEAT_RATE: float = 0.08

var _gp_repeat_next: Dictionary = {}

# ============================================================
# End Vars
# ============================================================
func _ready() -> void:
	GameConfig.load_from_disk()   # same call Main._ready() makes — picks up saved audio calibration, same as the actual game
	_ensure_input_map()
	_setup_ui()
	_build_speed_ui()
	_build_tools_ui()
	_build_tag_popup()
	_build_lint_popup()
	_build_schema_popup()
	_build_analysis_popup()
	_build_analyzer_progress_popup()
	_build_autofinish_popup()
	_build_capture_popup()
	_build_rap_popup()
	_build_font_picker_popup()
	_build_elec_popup()
	_build_preview_window()
	_build_audio_calib_window()
	_build_main_menu_confirm()
	_apply_happy_top_ui()
	_finalize_topbar_layout()
	_update_help_text()

	var load_btn: Button = $Buttons.get_node_or_null("LoadChart") as Button
	if load_btn != null:
		var cb := Callable(self, "_on_load_chart")
		if not load_btn.pressed.is_connected(cb):
			load_btn.pressed.connect(cb)

func _ensure_topbar_bg_panel() -> void:
	if top_bar == null:
		return
	if _top_bg_panel != null:
		return
	_top_bg_panel = Panel.new()
	_top_bg_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bg_panel.anchor_left = 0.0
	_top_bg_panel.anchor_top = 0.0
	_top_bg_panel.anchor_right = 1.0
	_top_bg_panel.anchor_bottom = 1.0
	_top_bg_panel.offset_left = 0.0
	_top_bg_panel.offset_top = 0.0
	_top_bg_panel.offset_right = 0.0
	_top_bg_panel.offset_bottom = 0.0

	var sb := StyleBoxFlat.new()
	sb.bg_color = ui_top_bg
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_top_bg_panel.add_theme_stylebox_override("panel", sb)

	top_bar.add_child(_top_bg_panel)
	top_bar.move_child(_top_bg_panel, 0)

func _style_button(btn: Button) -> void:
	if btn == null:
		return

	var accent: Color = ui_accent_b
	var t: String = btn.text.to_lower()
	if t.find("analy") >= 0:
		accent = ui_accent_b
	elif t.find("export") >= 0:
		accent = ui_accent_c
	elif t.find("autofinish") >= 0:
		accent = ui_accent_a
	elif t.find("lint") >= 0:
		accent = ui_accent_d
	elif t.find("guides") >= 0:
		accent = ui_accent_a

	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = ui_top_bg.lerp(accent, 0.22)
	sb_n.corner_radius_top_left = 10
	sb_n.corner_radius_top_right = 10
	sb_n.corner_radius_bottom_left = 10
	sb_n.corner_radius_bottom_right = 10
	sb_n.content_margin_left = 10
	sb_n.content_margin_right = 10
	sb_n.content_margin_top = 6
	sb_n.content_margin_bottom = 6
	sb_n.border_width_left = 2
	sb_n.border_width_right = 2
	sb_n.border_width_top = 2
	sb_n.border_width_bottom = 2
	sb_n.border_color = accent.lerp(Color.WHITE, 0.15)

	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color = sb_n.bg_color.lightened(0.10)

	var sb_p := sb_n.duplicate() as StyleBoxFlat
	sb_p.bg_color = sb_n.bg_color.darkened(0.12)

	btn.add_theme_stylebox_override("normal", sb_n)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_p)
	btn.add_theme_color_override("font_color", ui_text)
	btn.add_theme_color_override("font_hover_color", ui_text)
	btn.add_theme_color_override("font_pressed_color", ui_text)
	btn.focus_mode = Control.FOCUS_NONE

func _style_line_edit(le: LineEdit) -> void:
	if le == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = ui_top_bg.lightened(0.06)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = ui_accent_b.lerp(Color.WHITE, 0.10)

	le.add_theme_stylebox_override("normal", sb)
	le.add_theme_color_override("font_color", ui_text)
	le.add_theme_color_override("caret_color", ui_text)
	le.add_theme_color_override("placeholder_color", Color(ui_text.r, ui_text.g, ui_text.b, 0.45))

func _style_top_tree(n: Node) -> void:
	for c in n.get_children():
		if c is Button:
			_style_button(c as Button)
		elif c is LineEdit:
			_style_line_edit(c as LineEdit)
		elif c is Label:
			(c as Label).add_theme_color_override("font_color", ui_text)
		_style_top_tree(c)

func _apply_happy_top_ui() -> void:
	_ensure_topbar_bg_panel()
	_style_top_tree(top_bar)


## Keeps the top bar usable regardless of window width: shrinks the tool
## buttons' font/padding a bit, then wraps the whole bar in a horizontal
## ScrollContainer so nothing ever gets cut off past the edge of the window —
## a scrollbar (or Shift+Wheel) reaches anything that still doesn't fit.
## Only touches "Top" — the separate Buttons/Info rows below it keep their
## own fixed position untouched, so nothing else in the layout shifts.
func _finalize_topbar_layout() -> void:
	_compact_topbar_buttons()
	_wrap_topbar_in_scroll()


func _compact_topbar_buttons() -> void:
	if top_bar == null:
		return
	for child in top_bar.get_children():
		var btn := child as Button
		if btn == null:
			continue
		btn.add_theme_font_size_override("font_size", 14)
		# Only shrink styleboxes _style_button() actually gave this button a
		# per-instance override for — never touch a shared/default theme resource.
		for sb_name in ["normal", "hover", "pressed"]:
			if not btn.has_theme_stylebox_override(sb_name):
				continue
			var sbf := btn.get_theme_stylebox(sb_name) as StyleBoxFlat
			if sbf == null:
				continue
			sbf.content_margin_left   = minf(sbf.content_margin_left,   7.0)
			sbf.content_margin_right  = minf(sbf.content_margin_right,  7.0)
			sbf.content_margin_top    = minf(sbf.content_margin_top,    4.0)
			sbf.content_margin_bottom = minf(sbf.content_margin_bottom, 4.0)


func _wrap_topbar_in_scroll() -> void:
	if top_bar == null:
		return
	var parent: Node = top_bar.get_parent()
	if parent == null or parent is ScrollContainer:
		return
	var idx: int = top_bar.get_index()

	var scroll := ScrollContainer.new()
	scroll.name = "TopScroll"
	scroll.anchor_left    = top_bar.anchor_left
	scroll.anchor_top     = top_bar.anchor_top
	scroll.anchor_right   = top_bar.anchor_right
	scroll.anchor_bottom  = top_bar.anchor_bottom
	scroll.offset_left    = top_bar.offset_left
	scroll.offset_top     = top_bar.offset_top
	scroll.offset_right   = top_bar.offset_right
	scroll.offset_bottom  = top_bar.offset_bottom
	scroll.grow_horizontal = top_bar.grow_horizontal
	scroll.grow_vertical   = top_bar.grow_vertical
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED

	parent.remove_child(top_bar)
	parent.add_child(scroll)
	parent.move_child(scroll, idx)
	scroll.add_child(top_bar)

	# Anchors only made sense relative to the old parent — inside the
	# ScrollContainer the bar should just take its natural (unclamped) width
	# so there's something to scroll to when it doesn't fit.
	top_bar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	top_bar.offset_left   = 0.0
	top_bar.offset_top    = 0.0
	top_bar.offset_right  = 0.0
	top_bar.offset_bottom = 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

# ============================================================
# Global input capture (SPACE fix)
# ============================================================

func _input(ev: InputEvent) -> void:
	# Controller: A = tap (rap orbs / sung start-end), shoulders = slow / speed up.
	var jb := ev as InputEventJoypadButton
	if jb != null and jb.pressed:   # NOTE: InputEventJoypadButton has no `echo` (key-only)
		if jb.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_nudge_speed(-0.05)
		elif jb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_nudge_speed(0.05)
		elif jb.button_index == JOY_BUTTON_A:
			_handle_pad_tap()
		return

	var k: InputEventKey = ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return

	# Ctrl+- opens/closes multi-pass capture popup/session
	if k.ctrl_pressed and k.physical_keycode == KEY_MINUS:
		if capture_active:
			_capture_stop_session(false)
		else:
			_open_capture_popup()
		get_viewport().set_input_as_handled()
		return

	# While capture is active, block normal shortcut behavior here.
	# Taps themselves are handled in _process() via Input actions.
	if capture_active:
		get_viewport().set_input_as_handled()
		return

	if k.physical_keycode == KEY_F8 and not _is_text_entry_focused():
		_open_rap_popup()
		get_viewport().set_input_as_handled()
		return

	# Sung-line tap-timing: B stamps the current line's start, then its end.
	if _sung_timing and rap_popup != null and rap_popup.visible \
			and k.physical_keycode == KEY_B and not _is_text_entry_focused():
		_sung_tap()
		get_viewport().set_input_as_handled()
		return

	if k.physical_keycode == KEY_SPACE and not _is_text_entry_focused():
		_toggle_play()
		get_viewport().set_input_as_handled()
		return

	if k.physical_keycode == KEY_BRACKETLEFT and not _is_text_entry_focused():
		_nudge_speed(-0.05)
		get_viewport().set_input_as_handled()
		return
	if k.physical_keycode == KEY_BRACKETRIGHT and not _is_text_entry_focused():
		_nudge_speed(0.05)
		get_viewport().set_input_as_handled()
		return

# ============================================================
# Per-frame
# ============================================================

func _process(_delta: float) -> void:
	_poll_analyzer_process(_delta)

	# Live box resize: while a grip is held, track the mouse to set the box's height.
	if _resize_target != null:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_resize_target.custom_minimum_size.y = clampf(
				_resize_start_h + (get_global_mouse_position().y - _resize_anchor_y), 50.0, 1400.0)
		else:
			_resize_target = null

	# ----------------------------
	# Multi-pass capture mode takes priority
	# ----------------------------
	if capture_active:
		_gp_repeat_next.clear()
		_capture_poll_generic_tap_inputs()
		_capture_update_pass_flow()

		approach_time = clamp(approach_time, 0.15, 6.0)
		pps = (hit_y - spawn_y) / approach_time

		if song_player.playing and not song_player.stream_paused:
			queue_redraw()
		elif _mouse_in_track or _mouse_in_minimap or _marquee_active or _move_active or _scrub_active:
			queue_redraw()
		return

	approach_time = clamp(approach_time, 0.15, 6.0)
	pps = (hit_y - spawn_y) / approach_time

	if Input.is_key_pressed(KEY_CTRL) or _should_block_mapping():
		_gp_repeat_next.clear()
		for ln in range(lane_count):
			_prev_strength[ln] = Input.get_action_strength("lane_%d" % ln)
		if song_player.playing and not song_player.stream_paused:
			queue_redraw()
		return

	# Gamepad editor cursor / selection / delete / move
	_poll_editor_gamepad()

	# Existing shoulder/trigger lane tapping still works
	_poll_lane_action(0, "lane_0")
	_poll_lane_action(1, "lane_1")
	_poll_lane_action(2, "lane_2")
	_poll_lane_action(3, "lane_3")

	if song_player.playing and not song_player.stream_paused:
		queue_redraw()
	elif _mouse_in_track or _mouse_in_minimap or _marquee_active or _move_active or _scrub_active or gp_cursor_initialized:
		queue_redraw()

# ============================================================
# UI BUILD
# ============================================================

func _build_speed_ui() -> void:
	var lbl: Label = Label.new()
	lbl.text = "Speed"
	top_bar.add_child(lbl)

	speed_slider = HSlider.new()
	speed_slider.min_value = 0.10
	speed_slider.max_value = 2.00
	speed_slider.step = 0.01
	speed_slider.value = speed_value
	speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_slider.custom_minimum_size = Vector2(160, 0)
	top_bar.add_child(speed_slider)

	speed_readout = Label.new()
	speed_readout.text = "x%.2f" % speed_value
	top_bar.add_child(speed_readout)

	speed_slider.value_changed.connect(Callable(self, "_on_speed_changed"))
	_apply_speed()

func _build_tools_ui() -> void:
	var spacer: Label = Label.new()
	spacer.text = "  "
	top_bar.add_child(spacer)

	var btn_lint: Button = Button.new()
	btn_lint.text = "Lint (F6)"
	top_bar.add_child(btn_lint)
	btn_lint.pressed.connect(Callable(self, "_open_lint_popup"))

	var btn_lanes: Button = Button.new()
	btn_lanes.text = "Lanes (F7)"
	top_bar.add_child(btn_lanes)
	btn_lanes.pressed.connect(Callable(self, "_open_schema_popup"))

	var btn_export: Button = Button.new()
	btn_export.text = "Export (F9)"
	top_bar.add_child(btn_export)
	btn_export.pressed.connect(Callable(self, "_export_compiled"))

	var btn_analyze: Button = Button.new()
	btn_analyze.text = "Analyze (F12)"
	top_bar.add_child(btn_analyze)
	btn_analyze.pressed.connect(Callable(self, "_analyze_current_song"))

	var btn_guides: Button = Button.new()
	btn_guides.text = "Guides (F10)"
	top_bar.add_child(btn_guides)
	btn_guides.pressed.connect(Callable(self, "_toggle_guides"))

	var btn_analysis: Button = Button.new()
	btn_analysis.text = "Analysis (F11)"
	top_bar.add_child(btn_analysis)
	btn_analysis.pressed.connect(Callable(self, "_open_analysis_popup"))

	var btn_autofinish: Button = Button.new()
	btn_autofinish.text = "AutoFinish (Ctrl+U)"
	top_bar.add_child(btn_autofinish)
	btn_autofinish.pressed.connect(Callable(self, "_open_autofinish_popup").bind(false))

	var btn_rap: Button = Button.new()
	btn_rap.text = "Rap (F8)"
	top_bar.add_child(btn_rap)
	btn_rap.pressed.connect(Callable(self, "_open_rap_popup"))

	var btn_font: Button = Button.new()
	btn_font.text = "Font"
	top_bar.add_child(btn_font)
	btn_font.pressed.connect(Callable(self, "_open_font_picker"))

	var btn_elec_zones: Button = Button.new()
	btn_elec_zones.text = "⚡ Elec Zones"
	top_bar.add_child(btn_elec_zones)
	btn_elec_zones.pressed.connect(Callable(self, "_open_elec_popup"))

	var btn_preview: Button = Button.new()
	btn_preview.text = "▶ Preview"
	top_bar.add_child(btn_preview)
	btn_preview.pressed.connect(Callable(self, "_open_preview"))

	var btn_audio_calib: Button = Button.new()
	btn_audio_calib.text = "🎧 Audio Calib (F5)"
	top_bar.add_child(btn_audio_calib)
	btn_audio_calib.pressed.connect(Callable(self, "_open_audio_calib"))

	var btn_main_menu: Button = Button.new()
	btn_main_menu.text = "🏠 Main Menu (Ctrl+Alt+D)"
	top_bar.add_child(btn_main_menu)
	btn_main_menu.pressed.connect(Callable(self, "_confirm_return_to_main_menu"))

func _open_font_picker() -> void:
	if _font_picker_popup != null:
		_font_picker_popup.popup_centered()

func _build_preview_window() -> void:
	_preview_win = Window.new()
	_preview_win.title = "3D Beat Preview"
	_preview_win.size  = Vector2i(1100, 480)
	_preview_win.min_size = Vector2i(600, 300)
	_preview_win.wrap_controls = true
	_preview_win.close_requested.connect(_preview_win.hide)
	add_child(_preview_win)
	_preview_win.hide()

	var preview: Node = (load("res://tools/BeatPreview3D.gd") as GDScript).new()
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_win.add_child(preview)
	_preview_3d = preview
	# setup() is called on first open so mapper data is ready

func _open_preview() -> void:
	if _preview_win == null:
		return
	if _preview_win.visible:
		_preview_win.hide()
		return
	if _preview_3d != null and _preview_3d.mapper == null:
		_preview_3d.setup(self)
	elif _preview_3d != null:
		_preview_3d.rebuild()
	_preview_win.popup_centered(Vector2i(1100, 480))

# ============================================================
# Audio Latency Calibration tab (F5)
#
# This reuses res://scripts/AudioCalibrator.gd directly — the exact same
# tap-test scene the game launches from its pause menu — instead of
# reimplementing the tap logic here. Both read/write through the GameConfig
# autoload (user://audio_offsets.cfg, keyed by AudioServer.get_output_device()),
# so a calibration run from either place is immediately visible in the other.
#
# This is intentionally separate from this tool's own "Offset ms" chart field
# and the Q/[ ] latency_ms preview nudge — those shift a chart's authored
# timing; this tab calibrates YOUR hardware's audio delay, same as in-game.
# ============================================================
func _build_audio_calib_window() -> void:
	_audio_calib_win = Window.new()
	_audio_calib_win.title = "Audio Latency Calibration (same as in-game)"
	_audio_calib_win.size = Vector2i(560, 340)
	_audio_calib_win.min_size = Vector2i(480, 300)
	_audio_calib_win.wrap_controls = true
	_audio_calib_win.close_requested.connect(_audio_calib_win.hide)
	add_child(_audio_calib_win)
	_audio_calib_win.hide()

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_audio_calib_win.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	var note := Label.new()
	note.text = "Reads/writes the exact same GameConfig audio-offset store the game uses (user://audio_offsets.cfg, keyed by output device). Separate from this tool's own chart Offset / [ ] latency_ms fields."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 13)
	note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.72))
	vb.add_child(note)

	_audio_calib_dev_lbl = Label.new()
	_audio_calib_dev_lbl.add_theme_font_size_override("font_size", 16)
	vb.add_child(_audio_calib_dev_lbl)

	_audio_calib_offset_lbl = Label.new()
	_audio_calib_offset_lbl.add_theme_font_size_override("font_size", 20)
	_audio_calib_offset_lbl.add_theme_color_override("font_color", Color(0.70, 1.00, 0.75))
	vb.add_child(_audio_calib_offset_lbl)

	_audio_calib_engine_lbl = Label.new()
	_audio_calib_engine_lbl.add_theme_font_size_override("font_size", 13)
	_audio_calib_engine_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.72))
	vb.add_child(_audio_calib_engine_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vb.add_child(btn_row)

	var btn_run := Button.new()
	btn_run.text = "🎧 Run Calibration (same tap-test as in-game)"
	btn_run.pressed.connect(_run_audio_calibration)
	btn_row.add_child(btn_run)

	var btn_reset := Button.new()
	btn_reset.text = "Reset to 0"
	btn_reset.pressed.connect(func() -> void:
		GameConfig.set_audio_offset_for_current_device(0.0)
		_refresh_audio_calib_labels()
	)
	btn_row.add_child(btn_reset)

	var btn_reload := Button.new()
	btn_reload.text = "Reload from disk"
	btn_reload.tooltip_text = "Re-reads user://audio_offsets.cfg — use this if you calibrated in the actual game after opening this window."
	btn_reload.pressed.connect(func() -> void:
		GameConfig.load_from_disk()
		_refresh_audio_calib_labels()
	)
	btn_row.add_child(btn_reload)


func _refresh_audio_calib_labels() -> void:
	if _audio_calib_dev_lbl == null:
		return
	var dev: String = AudioServer.get_output_device()
	var ms: float = GameConfig.get_audio_offset_ms()
	var ms_str: String = ("not calibrated" if ms == 0.0
		else ("%s%.0f ms" % ["+" if ms >= 0.0 else "", ms]))
	_audio_calib_dev_lbl.text = "Output device:  %s" % dev
	_audio_calib_offset_lbl.text = "Saved offset (GameConfig):  %s" % ms_str
	_audio_calib_engine_lbl.text = "Raw engine buffer latency:  %.0f ms" % (AudioServer.get_output_latency() * 1000.0)


func _open_audio_calib() -> void:
	if _audio_calib_win == null:
		return
	if _audio_calib_win.visible:
		_audio_calib_win.hide()
		return
	GameConfig.load_from_disk()   # pick up any calibration saved by the actual game since we started
	_refresh_audio_calib_labels()
	_audio_calib_win.popup_centered(Vector2i(560, 340))


func _run_audio_calibration() -> void:
	if _audio_calib_active_node != null and is_instance_valid(_audio_calib_active_node):
		return   # already running
	# Instantiates the real game script — identical tap logic, identical
	# GameConfig storage — so a pass/fail here is proof it works in-game too.
	var cal: Node = load("res://scripts/AudioCalibrator.gd").new()
	_audio_calib_active_node = cal
	cal.calibration_complete.connect(func(_ms: float) -> void:
		_audio_calib_active_node = null
		_refresh_audio_calib_labels()
	)
	cal.calibration_cancelled.connect(func() -> void:
		_audio_calib_active_node = null
		_refresh_audio_calib_labels()
	)
	# Add to the calibration window itself (its own Viewport) so the overlay
	# renders inside that window rather than on top of the whole editor tool.
	_audio_calib_win.add_child(cal)


# ============================================================
# Return to Main Menu (Ctrl+Alt+D, or the top-bar button)
# ============================================================
func _build_main_menu_confirm() -> void:
	_main_menu_confirm = ConfirmationDialog.new()
	_main_menu_confirm.title = "Return to Main Menu?"
	_main_menu_confirm.dialog_text = "Any unsaved chart changes will be lost.\nSave first with Ctrl+S (or Ctrl+B to back up) if you need to keep them."
	_main_menu_confirm.ok_button_text = "Return to Main Menu"
	_main_menu_confirm.confirmed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
	)
	add_child(_main_menu_confirm)


func _confirm_return_to_main_menu() -> void:
	if _main_menu_confirm != null:
		_main_menu_confirm.popup_centered()


func _open_elec_popup() -> void:
	if _elec_popup == null:
		return
	# Rebuild rows from current electric_zones data
	for row in _elec_seg_rows:
		var hb: Node = row.get("hbox")
		if is_instance_valid(hb):
			hb.queue_free()
	_elec_seg_rows.clear()
	for zone in electric_zones:
		_elec_add_seg_row(float(zone.get("start_t", 0.0)), float(zone.get("end_t", 0.0)))
	_elec_popup.popup_centered(Vector2i(480, 400))

func _build_elec_popup() -> void:
	_elec_popup = PopupPanel.new()
	add_child(_elec_popup)
	_elec_popup.hide()

	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(460, 360)
	_elec_popup.add_child(vb)

	var title := Label.new()
	title.text = "⚡ Electric Zones"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	var desc := Label.new()
	desc.text = "Mark time ranges that use the electric environment (pylons + fence obstacles).\nThe rest of the song uses city buildings."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(desc)

	vb.add_child(HSeparator.new())

	# Column header
	var hdr := HBoxContainer.new()
	vb.add_child(hdr)
	for col in ["  #", "  Start (s)", "  End (s)", ""]:
		var hl := Label.new(); hl.text = col
		if col == "  Start (s)" or col == "  End (s)":
			hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hdr.add_child(hl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_elec_seg_container = VBoxContainer.new()
	_elec_seg_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_elec_seg_container)

	var add_row := HBoxContainer.new()
	vb.add_child(add_row)
	var btn_add := Button.new()
	btn_add.text = "+ Add Zone"
	add_row.add_child(btn_add)
	btn_add.pressed.connect(func() -> void:
		_elec_add_seg_row(snappedf(_play_time(), 0.01), snappedf(_play_time() + 30.0, 0.01))
	)

	vb.add_child(HSeparator.new())

	var bottom := HBoxContainer.new()
	vb.add_child(bottom)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	var btn_ok := Button.new()
	btn_ok.text = "OK"
	bottom.add_child(btn_ok)
	btn_ok.pressed.connect(_on_elec_popup_ok)

func _on_elec_popup_ok() -> void:
	electric_zones.clear()
	for row in _elec_seg_rows:
		var s_sb: SpinBox = row.get("start_sb") as SpinBox
		var e_sb: SpinBox = row.get("end_sb")   as SpinBox
		if s_sb == null or e_sb == null:
			continue
		var st := snappedf(s_sb.value, 0.001)
		var et := snappedf(e_sb.value, 0.001)
		if et > st:
			electric_zones.append({"start_t": st, "end_t": et})
	electric_zones.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("start_t", 0.0)) < float(b.get("start_t", 0.0)))
	_elec_popup.hide()

func _elec_add_seg_row(start_t: float, end_t: float) -> void:
	var idx := _elec_seg_rows.size()

	var hb := HBoxContainer.new()
	_elec_seg_container.add_child(hb)

	var idx_lbl := Label.new()
	idx_lbl.text = "  %d" % (idx + 1)
	idx_lbl.custom_minimum_size = Vector2(28, 0)
	hb.add_child(idx_lbl)

	var start_sb := SpinBox.new()
	start_sb.min_value = 0.0
	start_sb.max_value = 9999.0
	start_sb.step = 0.01
	start_sb.value = start_t
	start_sb.suffix = "s"
	start_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(start_sb)

	var btn_mark_start := Button.new()
	btn_mark_start.text = "▶"
	btn_mark_start.tooltip_text = "Set start to current playback time"
	hb.add_child(btn_mark_start)
	btn_mark_start.pressed.connect(func() -> void:
		start_sb.value = snappedf(_play_time(), 0.01)
	)

	var end_sb := SpinBox.new()
	end_sb.min_value = 0.0
	end_sb.max_value = 9999.0
	end_sb.step = 0.01
	end_sb.value = end_t
	end_sb.suffix = "s"
	end_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(end_sb)

	var btn_mark_end := Button.new()
	btn_mark_end.text = "▶"
	btn_mark_end.tooltip_text = "Set end of electric zone to current playback time"
	hb.add_child(btn_mark_end)
	btn_mark_end.pressed.connect(func() -> void:
		end_sb.value = snappedf(_play_time(), 0.01)
	)

	var btn_remove := Button.new()
	btn_remove.text = "✕"
	btn_remove.tooltip_text = "Remove this zone"
	hb.add_child(btn_remove)
	btn_remove.pressed.connect(func() -> void:
		for i in range(_elec_seg_rows.size()):
			if _elec_seg_rows[i].get("hbox") == hb:
				_elec_seg_rows.remove_at(i)
				hb.queue_free()
				_elec_renumber_rows()
				return
	)

	_elec_seg_rows.append({"hbox": hb, "start_sb": start_sb, "end_sb": end_sb, "idx_lbl": idx_lbl})

func _elec_renumber_rows() -> void:
	for i in range(_elec_seg_rows.size()):
		var lbl: Label = _elec_seg_rows[i].get("idx_lbl") as Label
		if lbl != null:
			lbl.text = "  %d" % (i + 1)

func _scan_fonts() -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open("res://fonts/")
	if dir == null:
		return result
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".ttf") or f.ends_with(".otf"):
			result.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

func _build_font_picker_popup() -> void:
	_available_fonts = _scan_fonts()
	_font_picker_popup = PopupPanel.new()
	add_child(_font_picker_popup)
	_font_picker_popup.hide()

	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(460, 220)
	_font_picker_popup.add_child(vb)

	var title := Label.new()
	title.text = "Lyric Font"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	_font_opt = OptionButton.new()
	_font_opt.add_item("Random (changes each run)", 0)
	for i: int in range(_available_fonts.size()):
		_font_opt.add_item(_available_fonts[i].get_basename(), i + 1)
	vb.add_child(_font_opt)
	_font_opt.item_selected.connect(Callable(self, "_on_lyric_font_selected"))

	var sep := HSeparator.new()
	vb.add_child(sep)

	var preview_lbl := Label.new()
	preview_lbl.text = "Preview:"
	vb.add_child(preview_lbl)

	_font_preview_lbl = Label.new()
	_font_preview_lbl.text = "The city skips a beat\n(different font each run)"
	_font_preview_lbl.add_theme_font_size_override("font_size", 26)
	_font_preview_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	vb.add_child(_font_preview_lbl)

	var btn_close := Button.new()
	btn_close.text = "Close"
	btn_close.pressed.connect(_font_picker_popup.hide)
	vb.add_child(btn_close)

func _on_lyric_font_selected(idx: int) -> void:
	if idx == 0:
		lyric_font_choice = "random"
		_font_preview_lbl.remove_theme_font_override("font")
		_font_preview_lbl.text = "The city skips a beat\n(different font each run)"
	else:
		var fname: String = _available_fonts[idx - 1]
		lyric_font_choice = fname
		var fnt: Font = load("res://fonts/" + fname)
		if fnt != null:
			_font_preview_lbl.add_theme_font_override("font", fnt)
		_font_preview_lbl.text = "The city skips a beat"

func _sync_font_opt_to_choice() -> void:
	if _font_opt == null:
		return
	if lyric_font_choice == "" or lyric_font_choice == "random":
		_font_opt.select(0)
		if _font_preview_lbl != null:
			_font_preview_lbl.remove_theme_font_override("font")
			_font_preview_lbl.text = "The city skips a beat\n(different font each run)"
	else:
		var fi: int = _available_fonts.find(lyric_font_choice)
		_font_opt.select(fi + 1 if fi >= 0 else 0)
		if fi >= 0 and _font_preview_lbl != null:
			var fnt: Font = load("res://fonts/" + lyric_font_choice)
			if fnt != null:
				_font_preview_lbl.add_theme_font_override("font", fnt)
			_font_preview_lbl.text = "The city skips a beat"

func _build_tag_popup() -> void:
	tag_popup = PopupPanel.new()
	add_child(tag_popup)
	tag_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	tag_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Event Tag"
	vb.add_child(title)

	var lbl_cat: Label = Label.new()
	lbl_cat.text = "Category"
	vb.add_child(lbl_cat)

	tag_category_opt = OptionButton.new()
	for cat in CATEGORY_LIST:
		tag_category_opt.add_item(cat)
	vb.add_child(tag_category_opt)

	var lbl_role: Label = Label.new()
	lbl_role.text = "Role"
	vb.add_child(lbl_role)

	tag_role_opt = OptionButton.new()
	vb.add_child(tag_role_opt)

	var hb: HBoxContainer = HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb)

	var btn_ok: Button = Button.new()
	btn_ok.text = "OK"
	hb.add_child(btn_ok)

	var btn_cancel: Button = Button.new()
	btn_cancel.text = "Cancel"
	hb.add_child(btn_cancel)

	btn_ok.pressed.connect(Callable(self, "_on_tag_popup_ok"))
	btn_cancel.pressed.connect(Callable(self, "_on_tag_popup_cancel"))
	tag_category_opt.item_selected.connect(Callable(self, "_on_tag_category_changed"))

	_refresh_role_options(current_category, current_role)

func _build_lint_popup() -> void:
	lint_popup = PopupPanel.new()
	add_child(lint_popup)
	lint_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	lint_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Lint / Validation"
	vb.add_child(title)

	var hb: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb)

	var btn_run: Button = Button.new()
	btn_run.text = "Run"
	hb.add_child(btn_run)
	btn_run.pressed.connect(Callable(self, "_run_lint"))

	lint_btn_sort = Button.new()
	lint_btn_sort.text = "Sort by time"
	hb.add_child(lint_btn_sort)
	lint_btn_sort.pressed.connect(Callable(self, "_fix_sort_by_time"))

	lint_btn_normalize = Button.new()
	lint_btn_normalize.text = "Normalize fields"
	hb.add_child(lint_btn_normalize)
	lint_btn_normalize.pressed.connect(Callable(self, "_fix_normalize_fields"))

	var btn_close: Button = Button.new()
	btn_close.text = "Close"
	hb.add_child(btn_close)
	btn_close.pressed.connect(Callable(self, "_close_lint_popup"))

	lint_results = RichTextLabel.new()
	lint_results.bbcode_enabled = true
	lint_results.fit_content = true
	lint_results.scroll_active = true
	lint_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lint_results.custom_minimum_size = Vector2(720, 420)
	vb.add_child(lint_results)

func _build_schema_popup() -> void:
	schema_popup = PopupPanel.new()
	add_child(schema_popup)
	schema_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	schema_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Lane Meaning / Constraints"
	vb.add_child(title)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 4
	vb.add_child(grid)

	var h0: Label = Label.new(); h0.text = "Lane"
	var h1: Label = Label.new(); h1.text = "Category"
	var h2: Label = Label.new(); h2.text = "Role"
	var h3: Label = Label.new(); h3.text = "Label / Comment"
	grid.add_child(h0); grid.add_child(h1); grid.add_child(h2); grid.add_child(h3)

	_schema_cat_opts.clear()
	_schema_role_opts.clear()
	_schema_label_edits.clear()
	_schema_comment_edits.clear()

	for i in range(lane_count):
		var lane_lbl: Label = Label.new()
		lane_lbl.text = "Lane %d" % i
		grid.add_child(lane_lbl)

		var cat_opt: OptionButton = OptionButton.new()
		cat_opt.add_item("any")
		for cat in CATEGORY_LIST:
			cat_opt.add_item(cat)
		grid.add_child(cat_opt)

		var role_opt: OptionButton = OptionButton.new()
		role_opt.add_item("any")
		grid.add_child(role_opt)

		var row_box: VBoxContainer = VBoxContainer.new()
		var label_edit: LineEdit = LineEdit.new()
		label_edit.placeholder_text = "Label (optional)"
		row_box.add_child(label_edit)

		var comment_edit: LineEdit = LineEdit.new()
		comment_edit.placeholder_text = "Comment (optional)"
		row_box.add_child(comment_edit)

		grid.add_child(row_box)

		_schema_cat_opts.append(cat_opt)
		_schema_role_opts.append(role_opt)
		_schema_label_edits.append(label_edit)
		_schema_comment_edits.append(comment_edit)

		cat_opt.item_selected.connect(Callable(self, "_on_schema_cat_changed").bind(i))

	var hb: HBoxContainer = HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb)

	var btn_apply: Button = Button.new()
	btn_apply.text = "Apply"
	hb.add_child(btn_apply)
	btn_apply.pressed.connect(Callable(self, "_apply_schema_popup"))

	var btn_cancel: Button = Button.new()
	btn_cancel.text = "Cancel"
	hb.add_child(btn_cancel)
	btn_cancel.pressed.connect(Callable(self, "_close_schema_popup"))

func _analyzer_dbg(msg: String) -> void:
	if not analyzer_debug_log:
		return
	print("[AnalyzerDBG] " + msg)

func _build_analysis_popup() -> void:
	analysis_popup = PopupPanel.new()
	add_child(analysis_popup)
	analysis_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	analysis_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Analysis"
	vb.add_child(title)

	var hb: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb)

	var btn_reload: Button = Button.new()
	btn_reload.text = "Reload JSON"
	hb.add_child(btn_reload)
	btn_reload.pressed.connect(Callable(self, "_reload_analysis"))

	var btn_import: Button = Button.new()
	btn_import.text = "Import JSON..."
	hb.add_child(btn_import)
	btn_import.pressed.connect(Callable(self, "_import_analysis_json"))

	var btn_unload: Button = Button.new()
	btn_unload.text = "Unload"
	hb.add_child(btn_unload)
	btn_unload.pressed.connect(Callable(self, "_unload_analysis"))

	var btn_remake: Button = Button.new()
	btn_remake.text = "Remake (Delete+Analyze)"
	hb.add_child(btn_remake)
	btn_remake.pressed.connect(Callable(self, "_remake_analysis"))

	var btn_close: Button = Button.new()
	btn_close.text = "Close"
	hb.add_child(btn_close)
	btn_close.pressed.connect(Callable(self, "_close_analysis_popup"))

	analysis_label = RichTextLabel.new()
	analysis_label.bbcode_enabled = true
	analysis_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	analysis_label.custom_minimum_size = Vector2(720, 420)
	vb.add_child(analysis_label)

# ============================================================
# Analyzer Progress Helpers (KEEP ONLY ONE COPY OF THIS BLOCK)
# ============================================================

func _show_analyzer_progress(pct: float, msg: String) -> void:
	_analyzer_hide_seq += 1 # cancel any pending delayed hide from a previous run
	if analyzer_progress_popup == null:
		return
	if analyzer_progress_bar != null:
		analyzer_progress_bar.start()
		analyzer_progress_bar.set_progress(pct, msg)
	if analyzer_progress_label != null:
		analyzer_progress_label.text = msg
	analyzer_progress_popup.popup_centered(Vector2(660, 170))


func _hide_analyzer_progress() -> void:
	if analyzer_progress_bar != null:
		analyzer_progress_bar.stop()
	if analyzer_progress_popup != null:
		analyzer_progress_popup.hide()


func _hide_analyzer_progress_after(seconds: float) -> void:
	_analyzer_hide_seq += 1
	var my_seq := _analyzer_hide_seq
	var t := get_tree().create_timer(seconds)
	t.timeout.connect(func():
		if my_seq == _analyzer_hide_seq:
			_hide_analyzer_progress()
	)


func _set_analyzer_progress(pct: float, msg: String) -> void:
	if analyzer_progress_popup != null and not analyzer_progress_popup.visible:
		analyzer_progress_popup.popup_centered(Vector2(660, 170))
	if analyzer_progress_bar != null:
		analyzer_progress_bar.set_progress(pct, msg)
	if analyzer_progress_label != null and msg != "":
		analyzer_progress_label.text = msg

func _build_analyzer_progress_popup() -> void:
	analyzer_progress_popup = PopupPanel.new()
	add_child(analyzer_progress_popup)
	analyzer_progress_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	analyzer_progress_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Analyzing…"
	vb.add_child(title)

	# ✅ Use your custom bar (matches start/stop/set_progress)
	analyzer_progress_bar = RainbowSheenBar.new()
	analyzer_progress_bar.custom_minimum_size = Vector2(620, 26)
	vb.add_child(analyzer_progress_bar)

	analyzer_progress_label = Label.new()
	analyzer_progress_label.text = "Starting…"
	vb.add_child(analyzer_progress_label)

	var hb: HBoxContainer = HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb)

	analyzer_progress_cancel_btn = Button.new()
	analyzer_progress_cancel_btn.text = "Cancel"
	hb.add_child(analyzer_progress_cancel_btn)
	analyzer_progress_cancel_btn.pressed.connect(Callable(self, "_request_cancel_analyzer"))

	# build settings popup too
	_build_analyzer_settings_popup()

func _build_analyzer_settings_popup() -> void:
	analyzer_settings_popup = PopupPanel.new()
	add_child(analyzer_settings_popup)
	analyzer_settings_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	analyzer_settings_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Analyzer Settings — BeatNet + Librosa fusion"
	vb.add_child(title)

	var sub: Label = Label.new()
	sub.text = "BeatNet locks tempo and bar phase; librosa splits the bands and places notes on real transients."
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.modulate = Color(1, 1, 1, 0.65)
	vb.add_child(sub)

	var hb_flags := HBoxContainer.new()
	vb.add_child(hb_flags)

	var cb_auto := CheckBox.new()
	cb_auto.text = "Auto settings (recommended)"
	cb_auto.tooltip_text = "Work the tempo window, onset thresholds and snap window out from the audio. Leave this on and ignore everything below."
	hb_flags.add_child(cb_auto)

	var cb_beatnet := CheckBox.new()
	cb_beatnet.text = "Use BeatNet grid"
	cb_beatnet.tooltip_text = "Off = librosa-only. BeatNet supplies the tempo seed and downbeat phase."
	hb_flags.add_child(cb_beatnet)

	var grid := GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)

	var add_spin = func(lbl: String, minv: float, maxv: float, step: float, tip: String) -> SpinBox:
		var l := Label.new()
		l.text = lbl
		l.tooltip_text = tip
		grid.add_child(l)

		var sb := SpinBox.new()
		sb.min_value = minv
		sb.max_value = maxv
		sb.step = step
		sb.tooltip_text = tip
		sb.custom_minimum_size = Vector2(160, 0)
		grid.add_child(sb)
		return sb

	var sb_min_bpm: SpinBox = add_spin.call("Min BPM", 60, 300, 1,
		"Lower bound of the tempo search.")
	var sb_max_bpm: SpinBox = add_spin.call("Max BPM", 60, 320, 1,
		"Upper bound of the tempo search. Keep the window tight for hard dance.")
	var sb_ts: SpinBox = add_spin.call("Time Sig (3/4)", 3, 4, 1,
		"Beats per bar.")
	var sb_snap: SpinBox = add_spin.call("Snap window (ms)", 0, 60, 1,
		"How far a beat may move onto a kick transient. Small is safer: a wide window grabs the loudest neighbour, not the right one.")
	var sb_delta: SpinBox = add_spin.call("Onset threshold", 0.005, 0.400, 0.005,
		"Peak-pick threshold per band. Lower finds more onsets (and more noise).")
	var sb_quick: SpinBox = add_spin.call("Quick seconds (0=full)", 0, 300, 1,
		"Analyze only the first N seconds. Use for a fast preview.")

	var sep := HSeparator.new()
	vb.add_child(sep)

	var lbl_map := Label.new()
	lbl_map.text = "MapGen (mixed lanes)"
	vb.add_child(lbl_map)

	var hb_map := HBoxContainer.new()
	vb.add_child(hb_map)

	var cb_mapgen := CheckBox.new()
	cb_mapgen.text = "Enable"
	hb_map.add_child(cb_mapgen)

	var lbl_diff := Label.new()
	lbl_diff.text = "Difficulty:"
	hb_map.add_child(lbl_diff)

	var sl_diff := HSlider.new()
	sl_diff.min_value = 1
	sl_diff.max_value = 10
	sl_diff.step = 1
	sl_diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb_map.add_child(sl_diff)

	var lbl_diff_v := Label.new()
	lbl_diff_v.text = "5"
	hb_map.add_child(lbl_diff_v)
	sl_diff.value_changed.connect(func(v: float) -> void:
		lbl_diff_v.text = str(int(v))
	)

	var hb_map2 := HBoxContainer.new()
	vb.add_child(hb_map2)

	var lbl_gap := Label.new()
	lbl_gap.text = "Min gap (ms):"
	hb_map2.add_child(lbl_gap)

	var sb_gap := SpinBox.new()
	sb_gap.min_value = 20
	sb_gap.max_value = 400
	sb_gap.step = 1
	sb_gap.custom_minimum_size = Vector2(120, 0)
	hb_map2.add_child(sb_gap)

	var lbl_lanes := Label.new()
	lbl_lanes.text = "Lanes:"
	hb_map2.add_child(lbl_lanes)

	var sb_lanes := SpinBox.new()
	sb_lanes.min_value = 1
	sb_lanes.max_value = 8
	sb_lanes.step = 1
	sb_lanes.custom_minimum_size = Vector2(90, 0)
	hb_map2.add_child(sb_lanes)

	var cb_chords := CheckBox.new()
	cb_chords.text = "Allow chords (rare)"
	hb_map2.add_child(cb_chords)

	var hb_btn := HBoxContainer.new()
	hb_btn.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb_btn)

	var btn_run := Button.new()
	btn_run.text = "Analyze"
	hb_btn.add_child(btn_run)

	var btn_close := Button.new()
	btn_close.text = "Close"
	hb_btn.add_child(btn_close)
	btn_close.pressed.connect(func() -> void:
		analyzer_settings_popup.hide()
	)

	# store refs
	# When auto is on these are derived from the audio, so showing them as
	# editable would invite tweaking values that get overwritten anyway.
	var _sync_auto := func(on: bool) -> void:
		sb_min_bpm.editable = not on
		sb_max_bpm.editable = not on
		sb_snap.editable = not on
		sb_delta.editable = not on
		var dim: float = 0.45 if on else 1.0
		sb_min_bpm.modulate.a = dim
		sb_max_bpm.modulate.a = dim
		sb_snap.modulate.a = dim
		sb_delta.modulate.a = dim
	cb_auto.toggled.connect(_sync_auto)
	analyzer_settings_popup.set_meta("sync_auto", _sync_auto)

	analyzer_settings_popup.set_meta("cb_auto", cb_auto)
	analyzer_settings_popup.set_meta("cb_beatnet", cb_beatnet)
	analyzer_settings_popup.set_meta("sb_min_bpm", sb_min_bpm)
	analyzer_settings_popup.set_meta("sb_max_bpm", sb_max_bpm)
	analyzer_settings_popup.set_meta("sb_ts", sb_ts)
	analyzer_settings_popup.set_meta("sb_snap", sb_snap)
	analyzer_settings_popup.set_meta("sb_delta", sb_delta)
	analyzer_settings_popup.set_meta("sb_quick", sb_quick)
	analyzer_settings_popup.set_meta("cb_mapgen", cb_mapgen)
	analyzer_settings_popup.set_meta("sl_diff", sl_diff)
	analyzer_settings_popup.set_meta("sb_gap", sb_gap)
	analyzer_settings_popup.set_meta("sb_lanes", sb_lanes)
	analyzer_settings_popup.set_meta("cb_chords", cb_chords)

	btn_run.pressed.connect(Callable(self, "_on_analyzer_settings_run"))

	_sync_auto.call(analyzer_auto)


func _read_analyzer_progress_file() -> void:
	if _analyzer_progress_path == "" or not FileAccess.file_exists(_analyzer_progress_path):
		return
	var f: FileAccess = FileAccess.open(_analyzer_progress_path, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		var d: Dictionary = parsed as Dictionary
		var pct: float = float(d.get("pct", 0))
		_analyzer_last_pct = pct
		var msg: String = String(d.get("msg", "Working…"))
		_analyzer_last_msg = msg

		var out_abs: String = String(d.get("out", ""))
		if out_abs != "":
			_analyzer_reported_out_abs = out_abs.replace("\\", "/")

		_set_analyzer_progress(pct, msg)

		var key := "%d|%s" % [int(round(pct)), msg]
		if key != _analyzer_dbg_last_progress_key:
			_analyzer_dbg_last_progress_key = key
			_analyzer_dbg("PROGRESS %d%% | %s" % [int(round(pct)), msg])

func _poll_analyzer_process(delta: float) -> void:
	if _analyzer_pid == -1:
		return

	_analyzer_poll_accum += delta
	if _analyzer_poll_accum >= 0.06:
		_analyzer_poll_accum = 0.0
		_read_analyzer_progress_file()

	if not OS.is_process_running(_analyzer_pid):
		# One last read (sometimes final 100% lands right at the end)
		_read_analyzer_progress_file()

		var exit_code: int = OS.get_process_exit_code(_analyzer_pid)

		# Stop tracking the PID immediately, but DON'T decide success/fail instantly.
		_analyzer_pid = -1
		_start_analyzer_finalize(exit_code)

func _start_analyzer_finalize(exit_code: int) -> void:
	_analyzer_finalize_exit_code = exit_code
	_analyzer_finalize_tries_left = 20  # ~20 * 0.12s = ~2.4s finalize window

	_set_analyzer_progress(99.0, "Finalizing… (saving results)")
	_analyzer_finalize_tick()

func _analyzer_finalize_tick() -> void:
	var found_path: String = _resolve_analyzer_output_path()

	if found_path != "":
		_on_analyzer_success(found_path)
		return

	_analyzer_finalize_tries_left -= 1
	if _analyzer_finalize_tries_left > 0:
		var t := get_tree().create_timer(0.12)
		t.timeout.connect(func():
			_analyzer_finalize_tick()
		)
		return

	_on_analyzer_fail()

func _on_analyzer_success(found_path: String) -> void:
	_analyzer_dbg("DONE success → " + found_path)
	_analyzer_dbg(" beats=%d downbeats=%d onsets=%d map_notes=%d" % [
		analysis_beats_ms.size(),
		analysis_downbeats_ms.size(),
		analysis_onsets.size(),
		analysis_map_notes.size()
	])
	analysis_path = found_path
	_load_analysis_json(analysis_path)
	_analyzer_dbg("schema=" + String(analysis_data.get("schema","")))
	_analyzer_dbg("map_notes key exists? " + str(analysis_data.has("map_notes")))
	_analyzer_dbg("map_notes loaded=" + str(analysis_map_notes.size()))

	# extra safety: must actually be analysis schema
	if analysis_data.is_empty() or not _looks_like_analysis_json(analysis_path):
		_set_analyzer_progress(0.0, "Failed ✖")
		_hide_analyzer_progress_after(0.6)
		info.text = "Analyzer output found, but it isn't a valid analysis JSON: %s" % analysis_path
		_dump_analyzer_debug()
		return

	info.text = "Analyzed → %s | Beats: %d | Onsets: %d" % [analysis_path, analysis_beats_ms.size(), analysis_onsets.size()]
	queue_redraw()

	_set_analyzer_progress(100.0, "Done! ✨")
	_hide_analyzer_progress_after(0.6)

func _on_analyzer_fail() -> void:
	_analyzer_dbg("DONE fail | last_pct=%d msg=%s" % [int(round(_analyzer_last_pct)), _analyzer_last_msg])
	if _analyzer_cancel_requested:
		_set_analyzer_progress(_analyzer_last_pct, "Canceled.")
		_hide_analyzer_progress_after(0.6)
		info.text = "Analyze canceled."
		return

	_set_analyzer_progress(0.0, "Failed ✖")
	_hide_analyzer_progress_after(0.6)
	info.text = "Analyze failed: analyzer exited at %.0f%%. %s" % [_analyzer_last_pct, _analyzer_last_msg]
	_dump_analyzer_debug()

func _is_progress_json_path(p: String) -> bool:
	var n := p.to_lower()
	return n.ends_with(".progress.json") or n.find(".progress.") != -1 or n.find("progress") != -1

func _looks_like_analysis_json(vpath: String) -> bool:
	if vpath == "" or _is_progress_json_path(vpath):
		return false
	if not FileAccess.file_exists(vpath):
		return false

	var f := FileAccess.open(vpath, FileAccess.READ)
	if f == null:
		return false
	var txt := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		return false
	var d := parsed as Dictionary

	# Reject progress schema
	if d.has("pct") and d.has("msg"):
		return false

	# Accept fusion (v3) and legacy v2 schemas
	if _is_supported_schema(String(d.get("schema", ""))):
		return true

	# Accept older schema style
	if d.has("analysis_version"):
		return true
	if d.has("tempo") or d.has("beats") or d.has("onsets"):
		# looser accept for your older analyzer outputs
		return true

	return false

func _resolve_analyzer_output_path() -> String:
	# 1) Intended virtual path (user:// or res://)
	if _analyzer_out_path != "" and not _is_progress_json_path(_analyzer_out_path):
		if _file_exists_any(_analyzer_out_path) and _looks_like_analysis_json(_analyzer_out_path):
			return _analyzer_out_path

	# 2) Absolute path reported by progress JSON
	if _analyzer_reported_out_abs != "":
		var v := _abs_to_vpath(_analyzer_reported_out_abs)
		if not _is_progress_json_path(v) and _file_exists_any(_analyzer_reported_out_abs) and _looks_like_analysis_json(v):
			return v

	# 3) Absolute path we expected
	if _analyzer_expected_out_abs != "":
		var v2 := _abs_to_vpath(_analyzer_expected_out_abs)
		if not _is_progress_json_path(v2) and _file_exists_any(_analyzer_expected_out_abs) and _looks_like_analysis_json(v2):
			return v2

	# 4) Globalized abs of intended vpath
	if _analyzer_out_path != "":
		var guess_abs := ProjectSettings.globalize_path(_analyzer_out_path).replace("\\", "/")
		if _file_exists_any(guess_abs):
			var vg := _abs_to_vpath(guess_abs)
			if not _is_progress_json_path(vg) and _looks_like_analysis_json(vg):
				return vg

	# 5) Directory scan: look for freshest *analysis* JSON near expected dir
	var candidates: Array[String] = []

	if _analyzer_expected_dir_abs != "":
		var best := _scan_recent_analysis_json(_analyzer_expected_dir_abs)
		if best != "":
			candidates.append(best)

	if _analyzer_reported_out_abs != "":
		var od := _analyzer_reported_out_abs.get_base_dir()
		if od != "" and od != _analyzer_expected_dir_abs:
			var best2 := _scan_recent_analysis_json(od)
			if best2 != "":
				candidates.append(best2)

	if candidates.size() > 0:
		return _abs_to_vpath(candidates[0])

	return ""

func _scan_recent_analysis_json(dir_abs: String) -> String:
	var d := DirAccess.open(dir_abs)
	if d == null:
		return ""

	var now_unix: int = int(Time.get_unix_time_from_system())
	var min_time: int = max(0, _analyzer_start_unix - 2)

	var best_path: String = ""
	var best_t: int = min_time

	d.list_dir_begin()
	while true:
		var fn := d.get_next()
		if fn == "":
			break
		if d.current_is_dir():
			continue

		var fn_l := fn.to_lower()
		if not fn_l.ends_with(".json"):
			continue
		# 🚫 IMPORTANT: skip progress files
		if fn_l.ends_with(".progress.json") or fn_l.find("progress") != -1:
			continue

		var full := (dir_abs.path_join(fn)).replace("\\", "/")
		var mt: int = int(FileAccess.get_modified_time(full))
		if mt < min_time or mt > now_unix + 5:
			continue

		var ok := false
		if fn_l.find("analysis") >= 0:
			ok = true
		if not ok and beatmap_key != "" and fn_l.find(beatmap_key.to_lower()) >= 0:
			ok = true
		if not ok and _analyzer_audio_stem != "" and fn_l.find(_analyzer_audio_stem.to_lower()) >= 0:
			ok = true
		if not ok:
			continue

		# ✅ Verify content looks like real analysis JSON
		var vpath := _abs_to_vpath(full)
		if not _looks_like_analysis_json(vpath):
			continue

		if mt >= best_t:
			best_t = mt
			best_path = full

	d.list_dir_end()
	return best_path

func _file_exists_any(path: String) -> bool:
	# FileAccess.file_exists should handle user://, res:// and absolute,
	# but on some setups absolute checks can be flaky; add a directory fallback.
	if path == "":
		return false

	var p := path.replace("\\", "/")
	if FileAccess.file_exists(p):
		return true

	# If absolute, try directory listing
	if p.find(":/") != -1 or p.begins_with("/"):
		var dir := p.get_base_dir()
		var file := p.get_file()
		var d := DirAccess.open(dir)
		if d == null:
			return false
		d.list_dir_begin()
		while true:
			var fn := d.get_next()
			if fn == "":
				break
			if not d.current_is_dir() and fn == file:
				d.list_dir_end()
				return true
		d.list_dir_end()

	return false

func _abs_to_vpath(abs_path: String) -> String:
	var p := abs_path.replace("\\", "/")

	var user_root := ProjectSettings.globalize_path("user://").replace("\\", "/")
	if not user_root.ends_with("/"):
		user_root += "/"

	var res_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if not res_root.ends_with("/"):
		res_root += "/"

	if p.begins_with(user_root):
		return "user://" + p.substr(user_root.length())
	if p.begins_with(res_root):
		return "res://" + p.substr(res_root.length())

	return p

func _dump_analyzer_debug() -> void:
	print("=== Analyzer Debug ===")
	print("exit_code:", _analyzer_finalize_exit_code)
	print("out vpath:", _analyzer_out_path)
	print("out abs expected:", _analyzer_expected_out_abs)
	print("out dir abs:", _analyzer_expected_dir_abs)
	print("progress vpath:", _analyzer_progress_path, " exists=", FileAccess.file_exists(_analyzer_progress_path))
	print("reported out abs:", _analyzer_reported_out_abs)
	print("last msg:", _analyzer_last_msg)

	if _analyzer_progress_path != "" and FileAccess.file_exists(_analyzer_progress_path):
		var f := FileAccess.open(_analyzer_progress_path, FileAccess.READ)
		if f != null:
			var txt := f.get_as_text()
			f.close()
			print("progress json text:")
			print(txt)
	print("======================")

func _build_autofinish_popup() -> void:
	autofinish_popup = PopupPanel.new()
	add_child(autofinish_popup)
	autofinish_popup.hide()

	# defaults for lane mapping
	if autofinish_lane_map.size() != lane_count:
		autofinish_lane_map.clear()
		for i in range(lane_count):
			autofinish_lane_map.append("beats" if (i % 2 == 0) else "onsets")

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	autofinish_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "AutoFinish"
	vb.add_child(title)

	af_cb_clear_first = CheckBox.new()
	af_cb_clear_first.text = "Clear existing events first"
	vb.add_child(af_cb_clear_first)

	af_cb_quantize = CheckBox.new()
	af_cb_quantize.text = "Quantize placed notes (uses current quantize settings)"
	af_cb_quantize.button_pressed = true
	vb.add_child(af_cb_quantize)

	# Analyzer MapGen mode
	af_cb_mapgen = CheckBox.new()
	af_cb_mapgen.text = "Use Analyzer notes (recommended)"
	af_cb_mapgen.tooltip_text = "Place the notes the analyzer generated, instead of raw beats/onsets."
	af_cb_mapgen.button_pressed = true
	vb.add_child(af_cb_mapgen)

	af_cb_two_lane = CheckBox.new()
	af_cb_two_lane.text = "Two lanes: beats (pink) / melody (blue)"
	af_cb_two_lane.tooltip_text = "The analyzer classifies every note, so lane 0 gets the kick and lane 1 gets the screeches and leads. Nothing to configure below."
	af_cb_two_lane.button_pressed = true
	vb.add_child(af_cb_two_lane)

	var lbl_auto: Label = Label.new()
	lbl_auto.text = "Analyzer notes already carry their own meaning — the source and lane options below only apply when \"Use Analyzer notes\" is off."
	lbl_auto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_auto.modulate = Color(1, 1, 1, 0.6)
	vb.add_child(lbl_auto)

	var hb_src: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb_src)

	# The manual source/lane pickers are meaningless in analyzer mode, so they
	# are disabled rather than left inviting a decision that has no effect.
	var _sync_af_mode := func(on: bool) -> void:
		if af_cb_quantize != null:
			if on:
				af_cb_quantize.button_pressed = false
			af_cb_quantize.disabled = on
		if af_cb_two_lane != null:
			af_cb_two_lane.disabled = not on
		if af_cb_beats != null:
			af_cb_beats.disabled = on
		if af_cb_downbeats != null:
			af_cb_downbeats.disabled = on
		if af_cb_onsets != null:
			af_cb_onsets.disabled = on
		for ob in af_lane_opts:
			if ob != null:
				ob.disabled = on

	af_cb_mapgen.toggled.connect(_sync_af_mode)
	autofinish_popup.set_meta("sync_af_mode", _sync_af_mode)

	af_cb_beats = CheckBox.new()
	af_cb_beats.text = "Beats"
	af_cb_beats.button_pressed = true
	hb_src.add_child(af_cb_beats)

	af_cb_downbeats = CheckBox.new()
	af_cb_downbeats.text = "Downbeats"
	af_cb_downbeats.button_pressed = true
	hb_src.add_child(af_cb_downbeats)

	af_cb_onsets = CheckBox.new()
	af_cb_onsets.text = "Onsets"
	af_cb_onsets.button_pressed = true
	hb_src.add_child(af_cb_onsets)

	var sep: HSeparator = HSeparator.new()
	vb.add_child(sep)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)

	af_lane_opts.clear()
	for i in range(lane_count):
		var l: Label = Label.new()
		l.text = "Lane %d maps:" % i
		grid.add_child(l)

		var ob: OptionButton = OptionButton.new()
		ob.add_item("off")
		ob.add_item("beats")
		ob.add_item("downbeats")
		ob.add_item("onsets")
		grid.add_child(ob)

		af_lane_opts.append(ob)

		var want: String = autofinish_lane_map[i]
		for k in range(ob.item_count):
			if ob.get_item_text(k) == want:
				ob.selected = k

	var sep2: HSeparator = HSeparator.new()
	vb.add_child(sep2)

	var hb_params: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb_params)

	var lbl_every: Label = Label.new()
	lbl_every.text = "Beats every:"
	hb_params.add_child(lbl_every)

	af_sb_beats_every = SpinBox.new()
	af_sb_beats_every.min_value = 1
	af_sb_beats_every.max_value = 16
	af_sb_beats_every.step = 1
	af_sb_beats_every.value = 1
	af_sb_beats_every.custom_minimum_size = Vector2(70, 0)
	hb_params.add_child(af_sb_beats_every)

	var lbl_sep: Label = Label.new()
	lbl_sep.text = "Min lane gap (ms):"
	hb_params.add_child(lbl_sep)

	af_sb_lane_sep_ms = SpinBox.new()
	af_sb_lane_sep_ms.min_value = 20
	af_sb_lane_sep_ms.max_value = 250
	af_sb_lane_sep_ms.step = 1
	af_sb_lane_sep_ms.value = autofinish_lane_min_sep_ms
	af_sb_lane_sep_ms.custom_minimum_size = Vector2(90, 0)
	hb_params.add_child(af_sb_lane_sep_ms)

	var hb_on: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb_on)

	var lbl_str: Label = Label.new()
	lbl_str.text = "Onset strength ≥"
	hb_on.add_child(lbl_str)

	af_sl_onset_strength = HSlider.new()
	af_sl_onset_strength.min_value = 0.0
	af_sl_onset_strength.max_value = 1.0
	af_sl_onset_strength.step = 0.01
	af_sl_onset_strength.value = 0.72
	af_sl_onset_strength.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb_on.add_child(af_sl_onset_strength)

	af_lbl_onset_strength = Label.new()
	af_lbl_onset_strength.text = "%.2f" % float(af_sl_onset_strength.value)
	hb_on.add_child(af_lbl_onset_strength)

	af_sl_onset_strength.value_changed.connect(func(v: float) -> void:
		if af_lbl_onset_strength != null:
			af_lbl_onset_strength.text = "%.2f" % v
	)

	var hb_avoid: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb_avoid)

	var lbl_avoid: Label = Label.new()
	lbl_avoid.text = "Skip onsets near beats (ms):"
	hb_avoid.add_child(lbl_avoid)

	af_sb_onset_avoid_beat_ms = SpinBox.new()
	af_sb_onset_avoid_beat_ms.min_value = 0
	af_sb_onset_avoid_beat_ms.max_value = 120
	af_sb_onset_avoid_beat_ms.step = 1
	af_sb_onset_avoid_beat_ms.value = 40
	af_sb_onset_avoid_beat_ms.custom_minimum_size = Vector2(90, 0)
	hb_avoid.add_child(af_sb_onset_avoid_beat_ms)

	var sep_rf: HSeparator = HSeparator.new()
	vb.add_child(sep_rf)

	var lbl_rf: Label = Label.new()
	lbl_rf.text = "Refine existing chart (used when \"Clear\" above is OFF)"
	vb.add_child(lbl_rf)

	var lbl_rf2: Label = Label.new()
	lbl_rf2.text = "Corrects the notes already there instead of adding a second chart on top. Your chart decides which windows stay quiet and where rolls belong."
	lbl_rf2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_rf2.modulate = Color(1, 1, 1, 0.6)
	vb.add_child(lbl_rf2)

	var hb_rf: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb_rf)

	af_cb_refine_align = CheckBox.new()
	af_cb_refine_align.text = "Remove tap latency"
	af_cb_refine_align.tooltip_text = "Measure how far the whole chart sits from the real transients and shift it onto them, then fix the leftover jitter per note."
	af_cb_refine_align.button_pressed = autofinish_refine_align_true
	hb_rf.add_child(af_cb_refine_align)

	af_cb_refine_fill = CheckBox.new()
	af_cb_refine_fill.text = "Fill gaps"
	af_cb_refine_fill.tooltip_text = "Add notes only in windows you already charted, and only where the gap is wider than your own spacing there."
	af_cb_refine_fill.button_pressed = autofinish_refine_fill_gaps
	hb_rf.add_child(af_cb_refine_fill)

	af_cb_refine_rolls = CheckBox.new()
	af_cb_refine_rolls.text = "Complete rolls"
	af_cb_refine_rolls.tooltip_text = "Finish double/triple kicks, but only in windows where you already use them."
	af_cb_refine_rolls.button_pressed = autofinish_refine_complete_rolls
	hb_rf.add_child(af_cb_refine_rolls)

	var lbl_rfc: Label = Label.new()
	lbl_rfc.text = "Max correction (ms):"
	hb_rf.add_child(lbl_rfc)

	af_sb_refine_max = SpinBox.new()
	af_sb_refine_max.min_value = 10
	af_sb_refine_max.max_value = 200
	af_sb_refine_max.step = 1
	af_sb_refine_max.value = autofinish_refine_max_ms
	af_sb_refine_max.tooltip_text = "A note further than this from any detected event is treated as deliberate and left alone."
	af_sb_refine_max.custom_minimum_size = Vector2(90, 0)
	hb_rf.add_child(af_sb_refine_max)
	var hb_btn: HBoxContainer = HBoxContainer.new()
	hb_btn.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb_btn)

	var btn_apply: Button = Button.new()
	btn_apply.text = "Apply"
	hb_btn.add_child(btn_apply)
	btn_apply.pressed.connect(Callable(self, "_on_autofinish_apply"))

	var btn_cancel: Button = Button.new()
	btn_cancel.text = "Cancel"
	hb_btn.add_child(btn_cancel)
	btn_cancel.pressed.connect(func() -> void:
		if autofinish_popup != null:
			autofinish_popup.hide()
	)

	# Apply the initial enabled/disabled state now that every control exists.
	_sync_af_mode.call(af_cb_mapgen.button_pressed)

# ============================================================
# RAP SECTIONS POPUP
# ============================================================

func _build_rap_popup() -> void:
	# A Window (not a PopupPanel) so it does NOT close on click-out or alt-tab —
	# only OK / Cancel / the X dismiss it, so in-progress text is never lost by accident.
	rap_popup = Window.new()
	rap_popup.title = "Rap & Lyrics"
	rap_popup.exclusive = false          # non-modal: main window stays usable (play/tap)
	rap_popup.unresizable = false
	rap_popup.min_size = Vector2i(520, 420)
	add_child(rap_popup)
	rap_popup.hide()
	rap_popup.close_requested.connect(func() -> void: rap_popup.hide())   # X = cancel
	# A Window is transparent by default — give it an opaque background.
	var rap_bg := Panel.new()
	rap_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rap_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rap_popup.add_child(rap_bg)

	# Scroll the whole popup so boxes can be dragged taller without clipping content.
	var scroll_root := ScrollContainer.new()
	scroll_root.anchor_left = 0.0; scroll_root.anchor_top = 0.0
	scroll_root.anchor_right = 1.0; scroll_root.anchor_bottom = 1.0
	scroll_root.offset_left = 14.0; scroll_root.offset_top = 14.0
	scroll_root.offset_right = -14.0; scroll_root.offset_bottom = -14.0
	scroll_root.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rap_popup.add_child(scroll_root)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_root.add_child(vb)

	var title := Label.new()
	title.text = "Rap Sections (F8)"
	title.add_theme_font_size_override("font_size", 15)
	vb.add_child(title)

	var note := Label.new()
	note.text = "Segments tell the game where the rap rail spawns.\nTaps control the spark orb positions (leave empty → auto 8th-note grid)."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(note)

	# ── Segments ──────────────────────────────────────────────
	var seg_title := Label.new()
	seg_title.text = "Rap Segments"
	vb.add_child(seg_title)

	var header := HBoxContainer.new()
	vb.add_child(header)
	for hdr in ["  #", "  Start (s)", "  End (s)", "  Trick", ""]:
		var hl := Label.new(); hl.text = hdr
		if hdr == "  Start (s)" or hdr == "  End (s)":
			hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(hl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 170)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_rap_seg_container = VBoxContainer.new()
	_rap_seg_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rap_seg_container)

	var hb_add := HBoxContainer.new()
	vb.add_child(hb_add)

	var btn_add_seg := Button.new()
	btn_add_seg.text = "+ Add Segment"
	hb_add.add_child(btn_add_seg)
	btn_add_seg.pressed.connect(func() -> void:
		_rap_add_seg_row(0.0, 0.0)
	)

	var sep := HSeparator.new()
	vb.add_child(sep)

	# ── Taps ──────────────────────────────────────────────────
	var tap_hdr := HBoxContainer.new()
	vb.add_child(tap_hdr)

	var tap_title := Label.new()
	tap_title.text = "Rap Taps (seconds, one per line — empty = auto grid)"
	tap_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tap_hdr.add_child(tap_title)

	var btn_tap_now := Button.new()
	btn_tap_now.text = "Tap +"
	btn_tap_now.tooltip_text = "Add the current playback position as a tap"
	tap_hdr.add_child(btn_tap_now)
	btn_tap_now.pressed.connect(Callable(self, "_rap_tap_now"))

	var btn_sort_taps := Button.new()
	btn_sort_taps.text = "Sort"
	tap_hdr.add_child(btn_sort_taps)
	btn_sort_taps.pressed.connect(func() -> void:
		if _rap_taps_edit == null:
			return
		var lines := _rap_taps_edit.text.split("\n", false)
		var vals: Array[float] = []
		for ln in lines:
			var s := ln.strip_edges()
			if s != "" and s.is_valid_float():
				vals.append(float(s))
		vals.sort()
		var out := ""
		for v in vals:
			if out != "":
				out += "\n"
			out += "%.4f" % v
		_rap_taps_edit.text = out
	)

	var btn_clear_taps := Button.new()
	btn_clear_taps.text = "Clear"
	tap_hdr.add_child(btn_clear_taps)
	btn_clear_taps.pressed.connect(func() -> void:
		if _rap_taps_edit != null:
			_rap_taps_edit.text = ""
	)

	_rap_taps_edit = TextEdit.new()
	_rap_taps_edit.custom_minimum_size = Vector2(0, 120)
	_rap_taps_edit.placeholder_text = "e.g.\n32.150\n32.450\n32.750\n(or leave empty for automatic 8th-note spacing)"
	vb.add_child(_rap_taps_edit)
	_add_resize_grip(vb, _rap_taps_edit)

	# ── Lyrics (reuses the taps above) ────────────────────────────
	var lyr_sep := HSeparator.new()
	vb.add_child(lyr_sep)

	var rap_words_title := Label.new()
	rap_words_title.text = "Rap Words — paste the verse; each word pairs with a tap (in order). Line breaks = on-screen lines."
	rap_words_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(rap_words_title)

	_rap_words_edit = TextEdit.new()
	_rap_words_edit.custom_minimum_size = Vector2(0, 90)
	_rap_words_edit.placeholder_text = "Meeko on the run gone before the morning\nFeet hit the ground like a code in my chest"
	vb.add_child(_rap_words_edit)
	_add_resize_grip(vb, _rap_words_edit)

	var sung_title := Label.new()
	sung_title.text = "Sung Lines (not orbs) — one per row:  <start>  whole sentence  <stop>   (stop optional)"
	vb.add_child(sung_title)

	_sung_lines_edit = TextEdit.new()
	_sung_lines_edit.custom_minimum_size = Vector2(0, 70)
	_sung_lines_edit.placeholder_text = "98.5  Feel it in the marrow  101.2\n101.5  He was never alone  104.0"
	vb.add_child(_sung_lines_edit)
	_add_resize_grip(vb, _sung_lines_edit)

	# Tap-timing: type the sung sentences (one per row, no times needed), press ▶, play
	# the song (Space), and tap B at the start and end of each line.
	var sung_tap_row := HBoxContainer.new()
	vb.add_child(sung_tap_row)
	var btn_sung_time := Button.new()
	btn_sung_time.text = "▶ Time Sung Lines"
	btn_sung_time.tooltip_text = "Parse the sentences above, then tap B at each line's start and end as it plays"
	sung_tap_row.add_child(btn_sung_time)
	btn_sung_time.pressed.connect(Callable(self, "_sung_start_timing"))
	var btn_sung_tap := Button.new()
	btn_sung_tap.text = "Tap (B)"
	sung_tap_row.add_child(btn_sung_tap)
	btn_sung_tap.pressed.connect(Callable(self, "_sung_tap"))
	_sung_status = Label.new()
	_sung_status.text = ""
	_sung_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sung_tap_row.add_child(_sung_status)

	# ── Drop Buildups (Charge Tunnel) ─────────────────────────
	var drop_sep := HSeparator.new()
	vb.add_child(drop_sep)

	var drop_title := Label.new()
	drop_title.text = "Drop Buildups (Charge Tunnel)"
	drop_title.add_theme_font_size_override("font_size", 15)
	vb.add_child(drop_title)

	var drop_note := Label.new()
	drop_note.text = "Each buildup is a riser where lanes drop away and Meeko free-slides to thread a hoop tunnel.\nHold the grind trigger + steer to charge; release on the drop (end) → ×100 overdrive."
	drop_note.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(drop_note)

	var drop_header := HBoxContainer.new()
	vb.add_child(drop_header)
	for hdr in ["  #", "  Start (s)", "  End / drop (s)", ""]:
		var hl := Label.new(); hl.text = hdr
		if hdr == "  Start (s)" or hdr == "  End / drop (s)":
			hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		drop_header.add_child(hl)

	var drop_scroll := ScrollContainer.new()
	drop_scroll.custom_minimum_size = Vector2(0, 120)
	drop_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(drop_scroll)

	_drop_seg_container = VBoxContainer.new()
	_drop_seg_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drop_scroll.add_child(_drop_seg_container)

	var drop_add_row := HBoxContainer.new()
	vb.add_child(drop_add_row)
	var btn_add_drop := Button.new()
	btn_add_drop.text = "+ Add Buildup"
	drop_add_row.add_child(btn_add_drop)
	btn_add_drop.pressed.connect(func() -> void:
		_drop_add_seg_row(0.0, 0.0)
	)

	# ── Buttons ───────────────────────────────────────────────
	var hb_btn := HBoxContainer.new()
	hb_btn.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb_btn)

	var btn_ok := Button.new()
	btn_ok.text = "OK"
	hb_btn.add_child(btn_ok)
	btn_ok.pressed.connect(Callable(self, "_on_rap_popup_ok"))

	var btn_cancel := Button.new()
	btn_cancel.text = "Cancel"
	hb_btn.add_child(btn_cancel)
	btn_cancel.pressed.connect(func() -> void:
		rap_popup.hide()
	)


func _rap_add_seg_row(start_t: float, end_t: float, trick: String = "random") -> void:
	var idx := _rap_seg_rows.size()

	var hb := HBoxContainer.new()
	_rap_seg_container.add_child(hb)

	var idx_lbl := Label.new()
	idx_lbl.text = "  %d" % (idx + 1)
	idx_lbl.custom_minimum_size = Vector2(28, 0)
	hb.add_child(idx_lbl)

	# Start time
	var start_sb := SpinBox.new()
	start_sb.min_value = 0.0
	start_sb.max_value = 9999.0
	start_sb.step = 0.01
	start_sb.value = start_t
	start_sb.suffix = "s"
	start_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(start_sb)

	var btn_mark_start := Button.new()
	btn_mark_start.text = "▶"
	btn_mark_start.tooltip_text = "Set start to current playback time"
	hb.add_child(btn_mark_start)
	btn_mark_start.pressed.connect(func() -> void:
		start_sb.value = snappedf(_play_time(), 0.01)
	)

	# End time
	var end_sb := SpinBox.new()
	end_sb.min_value = 0.0
	end_sb.max_value = 9999.0
	end_sb.step = 0.01
	end_sb.value = end_t
	end_sb.suffix = "s"
	end_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(end_sb)

	var btn_mark_end := Button.new()
	btn_mark_end.text = "▶"
	btn_mark_end.tooltip_text = "Set end to current playback time"
	hb.add_child(btn_mark_end)
	btn_mark_end.pressed.connect(func() -> void:
		end_sb.value = snappedf(_play_time(), 0.01)
	)

	# Trick dropdown — 'random' rolls per run seed; any named trick pins this rail.
	var trick_opt := OptionButton.new()
	trick_opt.custom_minimum_size = Vector2(116, 0)
	for tname in ["random", "sweep", "cross_over", "cross_under", "corkscrew", "wander", "loop"]:
		trick_opt.add_item(tname)
	var tsel := 0
	for ti in range(trick_opt.item_count):
		if trick_opt.get_item_text(ti) == trick:
			tsel = ti
			break
	trick_opt.select(tsel)
	trick_opt.tooltip_text = "Rail trick for this grind. 'random' = roll per run seed; otherwise pinned."
	hb.add_child(trick_opt)

	# Remove button — stores captured row_idx so closure is correct
	var row_idx := idx
	var btn_remove := Button.new()
	btn_remove.text = "✕"
	btn_remove.tooltip_text = "Remove this segment"
	hb.add_child(btn_remove)
	btn_remove.pressed.connect(func() -> void:
		# Find and remove this hbox from container and rows array
		for i in range(_rap_seg_rows.size()):
			if _rap_seg_rows[i].get("hbox") == hb:
				_rap_seg_rows.remove_at(i)
				hb.queue_free()
				_rap_renumber_rows()
				return
	)

	_rap_seg_rows.append({"hbox": hb, "start_sb": start_sb, "end_sb": end_sb, "idx_lbl": idx_lbl, "trick_opt": trick_opt})


func _rap_renumber_rows() -> void:
	for i in range(_rap_seg_rows.size()):
		var lbl: Label = _rap_seg_rows[i].get("idx_lbl") as Label
		if lbl != null:
			lbl.text = "  %d" % (i + 1)


# Charge-tunnel buildup row: start + end spinboxes (with ▶ "set to playhead"), remove.
func _drop_add_seg_row(start_t: float, end_t: float) -> void:
	var idx := _drop_seg_rows.size()

	var hb := HBoxContainer.new()
	_drop_seg_container.add_child(hb)

	var idx_lbl := Label.new()
	idx_lbl.text = "  %d" % (idx + 1)
	idx_lbl.custom_minimum_size = Vector2(28, 0)
	hb.add_child(idx_lbl)

	var start_sb := SpinBox.new()
	start_sb.min_value = 0.0
	start_sb.max_value = 9999.0
	start_sb.step = 0.01
	start_sb.value = start_t
	start_sb.suffix = "s"
	start_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(start_sb)

	var btn_mark_start := Button.new()
	btn_mark_start.text = "▶"
	btn_mark_start.tooltip_text = "Set start to current playback time"
	hb.add_child(btn_mark_start)
	btn_mark_start.pressed.connect(func() -> void:
		start_sb.value = snappedf(_play_time(), 0.01)
	)

	var end_sb := SpinBox.new()
	end_sb.min_value = 0.0
	end_sb.max_value = 9999.0
	end_sb.step = 0.01
	end_sb.value = end_t
	end_sb.suffix = "s"
	end_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(end_sb)

	var btn_mark_end := Button.new()
	btn_mark_end.text = "▶"
	btn_mark_end.tooltip_text = "Set end (the drop downbeat) to current playback time"
	hb.add_child(btn_mark_end)
	btn_mark_end.pressed.connect(func() -> void:
		end_sb.value = snappedf(_play_time(), 0.01)
	)

	var btn_remove := Button.new()
	btn_remove.text = "✕"
	btn_remove.tooltip_text = "Remove this buildup"
	hb.add_child(btn_remove)
	btn_remove.pressed.connect(func() -> void:
		for i in range(_drop_seg_rows.size()):
			if _drop_seg_rows[i].get("hbox") == hb:
				_drop_seg_rows.remove_at(i)
				hb.queue_free()
				_drop_renumber_rows()
				return
	)

	_drop_seg_rows.append({"hbox": hb, "start_sb": start_sb, "end_sb": end_sb, "idx_lbl": idx_lbl})


func _drop_renumber_rows() -> void:
	for i in range(_drop_seg_rows.size()):
		var lbl: Label = _drop_seg_rows[i].get("idx_lbl") as Label
		if lbl != null:
			lbl.text = "  %d" % (i + 1)


func _open_rap_popup() -> void:
	if rap_popup == null:
		return

	# Clear existing rows
	for row in _rap_seg_rows:
		var hb: Node = row.get("hbox")
		if is_instance_valid(hb):
			hb.queue_free()
	_rap_seg_rows.clear()

	# Populate from current data
	for seg in rap_segments:
		_rap_add_seg_row(float(seg.get("start_t", 0.0)), float(seg.get("end_t", 0.0)), String(seg.get("trick", "random")))

	# Charge-tunnel buildups
	for row in _drop_seg_rows:
		var dhb: Node = row.get("hbox")
		if is_instance_valid(dhb):
			dhb.queue_free()
	_drop_seg_rows.clear()
	for seg in drop_buildups:
		_drop_add_seg_row(float(seg.get("start_t", 0.0)), float(seg.get("end_t", 0.0)))

	# Populate taps TextEdit
	if _rap_taps_edit != null:
		var lines := ""
		for t in rap_taps:
			if lines != "":
				lines += "\n"
			lines += "%.4f" % t
		_rap_taps_edit.text = lines

	# (Lyric boxes keep whatever text they already hold — pasted-but-not-yet-timed
	# lyrics are remembered across open/close and save/load. The boxes are filled from
	# the chart in _on_load_chart, not rebuilt here.)

	rap_popup.popup_centered(Vector2i(700, 760))


func _on_rap_popup_ok() -> void:
	# Read segments
	rap_segments.clear()
	for row in _rap_seg_rows:
		var start_sb: SpinBox = row.get("start_sb") as SpinBox
		var end_sb:   SpinBox = row.get("end_sb")   as SpinBox
		if start_sb == null or end_sb == null:
			continue
		var st := snappedf(start_sb.value, 0.001)
		var et := snappedf(end_sb.value,   0.001)
		if et > st:
			var seg := {"start_t": st, "end_t": et}
			var trick_opt: OptionButton = row.get("trick_opt") as OptionButton
			if trick_opt != null and trick_opt.selected > 0:
				seg["trick"] = trick_opt.get_item_text(trick_opt.selected)
			rap_segments.append(seg)

	# Read charge-tunnel buildups
	drop_buildups.clear()
	for row in _drop_seg_rows:
		var d_start: SpinBox = row.get("start_sb") as SpinBox
		var d_end:   SpinBox = row.get("end_sb")   as SpinBox
		if d_start == null or d_end == null:
			continue
		var dst := snappedf(d_start.value, 0.001)
		var det := snappedf(d_end.value,   0.001)
		if det > dst:
			drop_buildups.append({"start_t": dst, "end_t": det})

	# Read taps
	rap_taps.clear()
	if _rap_taps_edit != null:
		var lines := _rap_taps_edit.text.split("\n", false)
		for ln in lines:
			var s := ln.strip_edges()
			if s != "" and s.is_valid_float():
				rap_taps.append(float(s))
		rap_taps.sort()

	# Build lyrics: pair the rap words to the (sorted) taps, plus the sung lines.
	_rap_build_lyrics()

	rap_popup.hide()

	var tap_note: String = " (%d taps)" % rap_taps.size() if rap_taps.size() > 0 else " (auto grid)"
	info.text = "Rap saved: %d segment(s)%s, %d lyric line(s), %d drop buildup(s)" % [rap_segments.size(), tap_note, lyrics_data.size(), drop_buildups.size()]


# Parse the sung sentences (stripping any existing times), reset, and begin tap-timing.
func _sung_start_timing() -> void:
	_sung_lines_text = []
	if _sung_lines_edit != null:
		for raw in _sung_lines_edit.text.split("\n"):
			var s := raw.strip_edges()
			if s == "" or s.begins_with("["):
				continue
			var parts := s.split(" ", false)
			var lo := 0
			var hi := parts.size()
			if lo < hi and String(parts[lo]).is_valid_float():
				lo += 1
			if hi - 1 > lo and String(parts[hi - 1]).is_valid_float():
				hi -= 1
			var sentence := ""
			for i in range(lo, hi):
				sentence += (" " if sentence != "" else "") + String(parts[i])
			if sentence != "":
				_sung_lines_text.append(sentence)
	_sung_starts = []
	_sung_ends = []
	for _i in _sung_lines_text:
		_sung_starts.append(null)
		_sung_ends.append(null)
	_sung_idx = 0
	_sung_have_start = false
	_sung_timing = _sung_lines_text.size() > 0
	if _sung_lines_edit != null:
		_sung_lines_edit.release_focus()
	_sung_refresh_text()
	_sung_update_status()


# One tap: first stamps the current line's START, the next stamps its END and advances.
func _sung_tap() -> void:
	if not _sung_timing or _sung_idx >= _sung_lines_text.size():
		return
	var t := snappedf(_play_time(), 0.001)
	if not _sung_have_start:
		_sung_starts[_sung_idx] = t
		_sung_have_start = true
	else:
		_sung_ends[_sung_idx] = t
		_sung_have_start = false
		_sung_idx += 1
		if _sung_idx >= _sung_lines_text.size():
			_sung_timing = false
	_sung_refresh_text()
	_sung_update_status()


# Rewrite the sung-lines box: timed rows as "<start>  sentence  <end>", untimed as-is.
func _sung_refresh_text() -> void:
	if _sung_lines_edit == null:
		return
	var out := ""
	for i in range(_sung_lines_text.size()):
		var row := String(_sung_lines_text[i])
		if _sung_starts[i] != null:
			row = "%.3f  %s" % [float(_sung_starts[i]), _sung_lines_text[i]]
			if _sung_ends[i] != null:
				row += "  %.3f" % float(_sung_ends[i])
		out += ("\n" if out != "" else "") + row
	_sung_lines_edit.text = out


func _sung_update_status() -> void:
	if _sung_status == null:
		return
	if not _sung_timing or _sung_idx >= _sung_lines_text.size():
		_sung_status.text = "Sung timing done — %d line(s)." % _sung_lines_text.size()
		return
	var phase := "tap END" if _sung_have_start else "tap START"
	_sung_status.text = "[%d/%d] %s — \"%s\"" % [_sung_idx + 1, _sung_lines_text.size(), phase, _sung_lines_text[_sung_idx]]


# Adds a thin drag handle under `target`; dragging it up/down resizes that box live.
func _add_resize_grip(parent: Control, target: TextEdit) -> void:
	var grip := Button.new()
	grip.text = "⋯⋯  drag to resize  ⋯⋯"
	grip.flat = true
	grip.focus_mode = Control.FOCUS_NONE
	grip.custom_minimum_size = Vector2(0, 13)
	grip.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	grip.add_theme_font_size_override("font_size", 9)
	parent.add_child(grip)
	grip.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_resize_target   = target
			_resize_anchor_y = get_global_mouse_position().y
			_resize_start_h  = target.custom_minimum_size.y
	)


# TextEdit text or "" (boxes exist after _build_rap_popup, but guard anyway).
func _te_text(te: TextEdit) -> String:
	return te.text if te != null else ""


# Backward-compat: rebuild the editable lyric boxes from timed lyrics_data — used on load
# only when a chart has no saved raw draft text.
func _lyrics_rebuild_boxes_from_data() -> void:
	if _rap_words_edit == null or _sung_lines_edit == null:
		return
	var rap_lines := ""
	var sung_lines := ""
	for e in lyrics_data:
		var ed: Dictionary = e
		if String(ed.get("mode", "line")) == "rap":
			var ws := ""
			for w in (ed.get("words", []) as Array):
				ws += (" " if ws != "" else "") + String((w as Dictionary).get("w", ""))
			rap_lines += ("\n" if rap_lines != "" else "") + ws
		else:
			var srow := "%.3f  %s" % [float(ed.get("t", 0.0)), String(ed.get("text", ""))]
			if ed.has("t_end"):
				srow += "  %.3f" % float(ed.get("t_end", 0.0))
			sung_lines += ("\n" if sung_lines != "" else "") + srow
	_rap_words_edit.text = rap_lines
	_sung_lines_edit.text = sung_lines


# Adds one rap orb tap at the current play position (shared by the Tap+ button + the
# A/keyboard tap). Slowed playback still stamps the correct SONG time.
func _rap_tap_now() -> void:
	if _rap_taps_edit == null:
		return
	var t := _play_time()
	var existing := _rap_taps_edit.text.strip_edges()
	_rap_taps_edit.text = ("%.4f" % t) if existing == "" else (existing + "\n" + ("%.4f" % t))


# Controller A / unified tap: sung start-then-end while timing, otherwise a rap orb tap.
func _handle_pad_tap() -> void:
	if rap_popup == null or not rap_popup.visible:
		return
	if _sung_timing:
		_sung_tap()
	elif not _is_text_entry_focused():
		_rap_tap_now()


# Nudge playback speed (slow the song to tap rap more accurately). Works anywhere.
func _nudge_speed(delta: float) -> void:
	var nv := clampf(speed_value + delta, 0.10, 2.00)
	if speed_slider != null:
		speed_slider.value = nv   # fires value_changed → _on_speed_changed (applies + readout)
	else:
		_on_speed_changed(nv)


# Pairs each rap word with a tap time (in order; line breaks = on-screen lines) and parses
# the sung lines ("<time>  sentence"), producing the exported "lyrics" array.
func _rap_build_lyrics() -> void:
	lyrics_data.clear()
	# Rap words → per-word entries paired positionally with the sorted taps.
	if _rap_words_edit != null:
		var wi: int = 0
		for raw in _rap_words_edit.text.split("\n"):
			var s := raw.strip_edges()
			if s == "" or s.begins_with("["):
				continue
			var words: Array = []
			for w in s.split(" ", false):
				var t_word: float
				if wi < rap_taps.size():
					t_word = float(rap_taps[wi])
				elif rap_taps.size() > 0:
					t_word = float(rap_taps[rap_taps.size() - 1]) + 0.2 * float(wi - rap_taps.size() + 1)
				else:
					t_word = 0.0
				words.append({"t": snappedf(t_word, 0.001), "w": w})
				wi += 1
			if not words.is_empty():
				lyrics_data.append({"mode": "rap", "words": words})
	# Sung lines: "<time>  whole sentence".
	if _sung_lines_edit != null:
		for raw in _sung_lines_edit.text.split("\n"):
			var s := raw.strip_edges()
			if s == "":
				continue
			var parts := s.split(" ", false)
			if parts.size() < 2 or not String(parts[0]).is_valid_float():
				continue
			# "<start>  sentence  [<stop>]" — first token = start, optional last token = stop.
			var last_i := parts.size() - 1
			var has_stop := parts.size() >= 3 and String(parts[last_i]).is_valid_float()
			var end_idx := (last_i - 1) if has_stop else last_i
			var sentence := ""
			for i in range(1, end_idx + 1):
				sentence += (" " if sentence != "" else "") + String(parts[i])
			var entry := {"mode": "line", "t": float(parts[0]), "text": sentence}
			if has_stop:
				entry["t_end"] = float(parts[last_i])
			lyrics_data.append(entry)


func _open_autofinish_popup(clear_default: bool) -> void:
	if autofinish_popup == null:
		return
	if analysis_data.is_empty():
		info.text = "AutoFinish: run Analyze first (F12)."
		return

	af_cb_clear_first.button_pressed = clear_default
	autofinish_popup.popup_centered(Vector2(720, 520))

func _on_autofinish_apply() -> void:
	autofinish_apply_quantize = (af_cb_quantize != null and af_cb_quantize.button_pressed)
	autofinish_use_mapgen = (af_cb_mapgen != null and af_cb_mapgen.button_pressed)
	autofinish_two_lane = (af_cb_two_lane != null and af_cb_two_lane.button_pressed)

	autofinish_refine_align_true = (af_cb_refine_align != null and af_cb_refine_align.button_pressed)
	autofinish_refine_fill_gaps = (af_cb_refine_fill != null and af_cb_refine_fill.button_pressed)
	autofinish_refine_complete_rolls = (af_cb_refine_rolls != null and af_cb_refine_rolls.button_pressed)
	if af_sb_refine_max != null:
		autofinish_refine_max_ms = int(round(af_sb_refine_max.value))

	var include_beats: bool = (af_cb_beats != null and af_cb_beats.button_pressed)
	var include_down: bool = (af_cb_downbeats != null and af_cb_downbeats.button_pressed)
	var include_on: bool = (af_cb_onsets != null and af_cb_onsets.button_pressed)

	var clear_first: bool = (af_cb_clear_first != null and af_cb_clear_first.button_pressed)

	var beats_every: int = int(round(af_sb_beats_every.value)) if af_sb_beats_every != null else 1
	var lane_sep_ms: int = int(round(af_sb_lane_sep_ms.value)) if af_sb_lane_sep_ms != null else 85
	var onset_str: float = float(af_sl_onset_strength.value) if af_sl_onset_strength != null else 0.72
	var avoid_ms: int = int(round(af_sb_onset_avoid_beat_ms.value)) if af_sb_onset_avoid_beat_ms != null else 40

	if autofinish_lane_map.size() != lane_count:
		autofinish_lane_map.resize(lane_count)
	for i in range(lane_count):
		var ob: OptionButton = af_lane_opts[i]
		var v: String = ob.get_item_text(ob.selected)
		autofinish_lane_map[i] = v

	autofinish_include_beats = include_beats
	autofinish_include_downbeats = include_down
	autofinish_include_onsets = include_on

	autofinish_beats_every = beats_every
	autofinish_lane_min_sep_ms = lane_sep_ms
	autofinish_onset_strength_min = onset_str
	autofinish_onset_avoid_near_beat_ms = avoid_ms

	if autofinish_popup != null:
		autofinish_popup.hide()

	_autofinish(clear_first)

# ============================================================
# HELP TEXT
# ============================================================

func _update_help_text() -> void:
	if show_help:
		info.text = "P: Pick song | Space: Play/Pause | Home/Ctrl+Bk : Select | LMB-drag: Marquee | Ctrl+LMB: Toggle | Alt+LMB-drag: Move | Ctrl+C/V: Copy/Paste | Del: Delete | /: Category/Role | H: Holds | F5: Audio Calib | F6: Lint | F7: Lanes | F12: Analyze | F10: Guides | F11: Analysis | N/M: Next/Prev Assist | G: Assist source | Enter: Place at assist | Wheel: Zoom | Shift+Wheel: Pan | Ctrl+U: AutoFinish | Ctrl+Alt+D: Main Menu || Gamepad: D-Pad/Left Stick move cursor | A place | X select | B toggle select | Y delete nearest / selection | Back clear selection | Right Stick nudges selection | Start play/pause | LB/LT/RT/RB still lane-tap notes"
	else:
		info.text = ""

# ============================================================
# Multi-pass capture popup + session logic
# ============================================================

func _build_capture_popup() -> void:
	capture_popup = PopupPanel.new()
	add_child(capture_popup)
	capture_popup.hide()

	var vb: VBoxContainer = VBoxContainer.new()
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12.0
	vb.offset_top = 12.0
	vb.offset_right = -12.0
	vb.offset_bottom = -12.0
	capture_popup.add_child(vb)

	var title: Label = Label.new()
	title.text = "Multi-Pass Tap Capture (Ctrl+-)"
	vb.add_child(title)

	capture_status_label = Label.new()
	capture_status_label.text = "Tap one generic button; the system assigns lanes later."
	vb.add_child(capture_status_label)

	capture_pass_label = Label.new()
	capture_pass_label.text = "Pass: idle"
	vb.add_child(capture_pass_label)

	var sep0: HSeparator = HSeparator.new()
	vb.add_child(sep0)

	cap_cb_beats = CheckBox.new()
	cap_cb_beats.text = "Pass 1: Beats / Kick / Bass"
	cap_cb_beats.button_pressed = true
	vb.add_child(cap_cb_beats)

	cap_beats_lane_cbs = _build_capture_lane_row(vb, "Beats uses lanes:", [0, 2])

	cap_cb_melody = CheckBox.new()
	cap_cb_melody.text = "Pass 2: Melody / Main musical line"
	cap_cb_melody.button_pressed = true
	vb.add_child(cap_cb_melody)

	cap_melody_lane_cbs = _build_capture_lane_row(vb, "Melody uses lanes:", [1, 3])

	cap_cb_fx = CheckBox.new()
	cap_cb_fx.text = "Pass 3: FX / Other small sounds"
	cap_cb_fx.button_pressed = true
	vb.add_child(cap_cb_fx)

	var all_fx_defaults: Array[int] = []
	for i in range(lane_count):
		all_fx_defaults.append(i)
	cap_fx_lane_cbs = _build_capture_lane_row(vb, "FX uses lanes:", all_fx_defaults)

	var sep1: HSeparator = HSeparator.new()
	vb.add_child(sep1)

	cap_cb_clear_first = CheckBox.new()
	cap_cb_clear_first.text = "Clear existing events before merge"
	cap_cb_clear_first.button_pressed = true
	vb.add_child(cap_cb_clear_first)

	cap_cb_use_analysis = CheckBox.new()
	cap_cb_use_analysis.text = "Use analysis as optional snap assist (if loaded)"
	cap_cb_use_analysis.button_pressed = true
	vb.add_child(cap_cb_use_analysis)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)

	var l1: Label = Label.new()
	l1.text = "Per-lane min gap (ms)"
	grid.add_child(l1)
	cap_sb_lane_gap_ms = SpinBox.new()
	cap_sb_lane_gap_ms.min_value = 40
	cap_sb_lane_gap_ms.max_value = 400
	cap_sb_lane_gap_ms.step = 1
	cap_sb_lane_gap_ms.value = 100
	cap_sb_lane_gap_ms.custom_minimum_size = Vector2(120, 0)
	grid.add_child(cap_sb_lane_gap_ms)

	var l2: Label = Label.new()
	l2.text = "Global min gap (ms)"
	grid.add_child(l2)
	cap_sb_global_gap_ms = SpinBox.new()
	cap_sb_global_gap_ms.min_value = 0
	cap_sb_global_gap_ms.max_value = 250
	cap_sb_global_gap_ms.step = 1
	cap_sb_global_gap_ms.value = 45
	cap_sb_global_gap_ms.custom_minimum_size = Vector2(120, 0)
	grid.add_child(cap_sb_global_gap_ms)

	var l3: Label = Label.new()
	l3.text = "Beat snap window (ms)"
	grid.add_child(l3)
	cap_sb_beat_snap_ms = SpinBox.new()
	cap_sb_beat_snap_ms.min_value = 0
	cap_sb_beat_snap_ms.max_value = 120
	cap_sb_beat_snap_ms.step = 1
	cap_sb_beat_snap_ms.value = 40
	cap_sb_beat_snap_ms.custom_minimum_size = Vector2(120, 0)
	grid.add_child(cap_sb_beat_snap_ms)

	var l4: Label = Label.new()
	l4.text = "Onset snap window (ms)"
	grid.add_child(l4)
	cap_sb_onset_snap_ms = SpinBox.new()
	cap_sb_onset_snap_ms.min_value = 0
	cap_sb_onset_snap_ms.max_value = 120
	cap_sb_onset_snap_ms.step = 1
	cap_sb_onset_snap_ms.value = 28
	cap_sb_onset_snap_ms.custom_minimum_size = Vector2(120, 0)
	grid.add_child(cap_sb_onset_snap_ms)

	var tips: Label = Label.new()
	tips.text = "Use A/S/K/L or controller lane buttons or Enter. The song replays once for each enabled pass. You can choose exactly which lanes each pass may use."
	vb.add_child(tips)

	var hb: HBoxContainer = HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END as BoxContainer.AlignmentMode
	vb.add_child(hb)

	var btn_start: Button = Button.new()
	btn_start.text = "Start"
	hb.add_child(btn_start)
	btn_start.pressed.connect(Callable(self, "_capture_start_from_popup"))

	var btn_stop: Button = Button.new()
	btn_stop.text = "Stop"
	hb.add_child(btn_stop)
	btn_stop.pressed.connect(Callable(self, "_capture_stop_from_popup"))

	var btn_close: Button = Button.new()
	btn_close.text = "Close"
	hb.add_child(btn_close)
	btn_close.pressed.connect(Callable(self, "_capture_close_popup"))


func _open_capture_popup() -> void:
	if capture_popup == null:
		return
	capture_popup.popup_centered(Vector2(760, 500))
	_capture_refresh_popup_labels()


func _capture_close_popup() -> void:
	if capture_popup != null:
		capture_popup.hide()


func _capture_start_from_popup() -> void:
	if song_player.stream == null:
		info.text = "Capture: load a song first."
		return

	capture_lane_gap_ms = int(round(cap_sb_lane_gap_ms.value))
	capture_global_gap_ms = int(round(cap_sb_global_gap_ms.value))
	capture_beat_snap_ms = int(round(cap_sb_beat_snap_ms.value))
	capture_onset_snap_ms = int(round(cap_sb_onset_snap_ms.value))
	capture_use_analysis = (cap_cb_use_analysis != null and cap_cb_use_analysis.button_pressed)
	capture_clear_first = (cap_cb_clear_first != null and cap_cb_clear_first.button_pressed)

	# Save selected lane config per pass
	var all_lanes: Array[int] = []
	for i in range(lane_count):
		all_lanes.append(i)

	capture_pass_lane_config["beats"] = _capture_get_checked_lanes(cap_beats_lane_cbs, [0, 2])
	capture_pass_lane_config["melody"] = _capture_get_checked_lanes(cap_melody_lane_cbs, [1, 3])
	capture_pass_lane_config["fx"] = _capture_get_checked_lanes(cap_fx_lane_cbs, all_lanes)

	capture_passes.clear()
	if cap_cb_beats != null and cap_cb_beats.button_pressed:
		capture_passes.append({
			"id": "beats",
			"label": "Beats / Kick / Bass",
			"hint": "Tap the main pulse, kick, bass hits."
		})
	if cap_cb_melody != null and cap_cb_melody.button_pressed:
		capture_passes.append({
			"id": "melody",
			"label": "Melody",
			"hint": "Tap the lead melody / main musical line."
		})
	if cap_cb_fx != null and cap_cb_fx.button_pressed:
		capture_passes.append({
			"id": "fx",
			"label": "FX / Other",
			"hint": "Tap small sounds, fills, accents, FX."
		})

	if capture_passes.is_empty():
		info.text = "Capture: enable at least one pass."
		return

	capture_taps_by_pass.clear()
	for p in capture_passes:
		capture_taps_by_pass[String(p.get("id", ""))] = []

	capture_active = true
	capture_pass_index = -1
	capture_started_song = false
	capture_last_playing_state = false

	if capture_popup != null and not capture_popup.visible:
		capture_popup.popup_centered(Vector2(760, 560))

	print("[CaptureDBG] lane_config=", capture_pass_lane_config)
	_capture_begin_next_pass()

func _capture_stop_from_popup() -> void:
	_capture_stop_session(false)

func _capture_stop_session(finalize_map: bool) -> void:
	if not capture_active:
		if capture_popup != null and capture_popup.visible:
			capture_popup.hide()
		return

	capture_active = false
	song_player.stop()
	song_player.stream_paused = false
	follow_playhead = false
	view_time = 0.0

	if finalize_map:
		_capture_finalize_into_events()

	_capture_refresh_popup_labels()

	if capture_popup != null:
		capture_popup.hide()


func _capture_begin_next_pass() -> void:
	capture_pass_index += 1

	if capture_pass_index >= capture_passes.size():
		capture_active = false
		_capture_finalize_into_events()
		_capture_refresh_popup_labels()
		if capture_popup != null:
			capture_popup.hide()
		return

	var p: Dictionary = capture_passes[capture_pass_index]
	var pid: String = String(p.get("id", ""))
	var plabel: String = String(p.get("label", pid))
	var hint: String = String(p.get("hint", ""))

	song_player.stop()
	song_player.play(0.0)
	song_player.stream_paused = false
	follow_playhead = true
	view_time = 0.0

	capture_started_song = true
	capture_last_playing_state = true

	if capture_status_label != null:
		capture_status_label.text = "Now recording: %s" % plabel
	if capture_pass_label != null:
		capture_pass_label.text = "Pass %d/%d — %s\n%s" % [capture_pass_index + 1, capture_passes.size(), plabel, hint]

	info.text = "Capture %d/%d: %s" % [capture_pass_index + 1, capture_passes.size(), plabel]
	print("[CaptureDBG] START pass=", pid, " label=", plabel)


func _capture_refresh_popup_labels() -> void:
	if capture_status_label == null or capture_pass_label == null:
		return

	if capture_active and capture_pass_index >= 0 and capture_pass_index < capture_passes.size():
		var p: Dictionary = capture_passes[capture_pass_index]
		capture_status_label.text = "Recording..."
		capture_pass_label.text = "Pass %d/%d — %s" % [
			capture_pass_index + 1,
			capture_passes.size(),
			String(p.get("label", ""))
		]
	else:
		capture_status_label.text = "Tap one generic button; the system assigns lanes later."
		capture_pass_label.text = "Pass: idle"


func _capture_poll_generic_tap_inputs() -> void:
	if not capture_active:
		return
	if _is_text_entry_focused():
		return
	if song_player.stream == null:
		return
	if not song_player.playing or song_player.stream_paused:
		return

	# Any of these count as a generic tap while capturing
	var tapped: bool = false
	if Input.is_action_just_pressed("lane_0"):
		tapped = true
	elif Input.is_action_just_pressed("lane_1"):
		tapped = true
	elif Input.is_action_just_pressed("lane_2"):
		tapped = true
	elif Input.is_action_just_pressed("lane_3"):
		tapped = true
	elif Input.is_action_just_pressed("ui_accept"):
		tapped = true

	if tapped:
		_capture_register_tap()


func _capture_update_pass_flow() -> void:
	if not capture_active:
		return
	if not capture_started_song:
		return

	var playing_now: bool = song_player.playing and not song_player.stream_paused

	# Song just ended -> advance to next pass
	if capture_last_playing_state and not playing_now:
		var p: Dictionary = capture_passes[capture_pass_index]
		print("[CaptureDBG] END pass=", String(p.get("id", "")), " taps=", (capture_taps_by_pass.get(String(p.get("id", "")), []) as Array).size())
		_capture_begin_next_pass()
		return

	capture_last_playing_state = playing_now


func _build_capture_lane_row(parent: VBoxContainer, title: String, defaults: Array[int]) -> Array[CheckBox]:
	var lbl: Label = Label.new()
	lbl.text = title
	parent.add_child(lbl)

	var hb: HBoxContainer = HBoxContainer.new()
	parent.add_child(hb)

	var out: Array[CheckBox] = []
	for i in range(lane_count):
		var cb: CheckBox = CheckBox.new()
		cb.text = "Lane %d" % i
		cb.button_pressed = defaults.has(i)
		hb.add_child(cb)
		out.append(cb)

	return out


func _capture_get_checked_lanes(boxes: Array[CheckBox], fallback: Array[int]) -> Array[int]:
	var out: Array[int] = []
	for i in range(min(boxes.size(), lane_count)):
		if boxes[i] != null and boxes[i].button_pressed:
			out.append(i)

	if out.is_empty():
		for v in fallback:
			out.append(int(v))

	return out


func _capture_register_tap() -> void:
	if capture_pass_index < 0 or capture_pass_index >= capture_passes.size():
		return

	var p: Dictionary = capture_passes[capture_pass_index]
	var pid: String = String(p.get("id", ""))

	var t_s: float = _play_time()
	t_s = _capture_maybe_snap_tap_time(pid, t_s)

	var arr: Array = capture_taps_by_pass.get(pid, [])
	if not arr.is_empty():
		var prev_t: float = float(arr[arr.size() - 1])
		if abs(t_s - prev_t) < 0.055:
			return # de-bounce accidental double tap

	arr.append(t_s)
	capture_taps_by_pass[pid] = arr

	if capture_status_label != null:
		capture_status_label.text = "Recording: %s | taps=%d | last=%.3fs" % [String(p.get("label", pid)), arr.size(), t_s]


func _capture_maybe_snap_tap_time(pass_id: String, t_s: float) -> float:
	if not capture_use_analysis:
		return t_s
	if analysis_data.is_empty():
		return t_s

	var ms: int = int(round(t_s * 1000.0))

	if pass_id == "beats":
		if analysis_downbeats_ms.size() > 0 and capture_beat_snap_ms > 0:
			var db: int = _snap_ms_to_list(ms, analysis_downbeats_ms, capture_beat_snap_ms)
			if db != ms:
				return float(db) / 1000.0

		if analysis_beats_ms.size() > 0 and capture_beat_snap_ms > 0:
			var b: int = _snap_ms_to_list(ms, analysis_beats_ms, capture_beat_snap_ms)
			if b != ms:
				return float(b) / 1000.0

		return t_s

	# melody / fx prefer onsets if available
	if analysis_onsets.size() > 0 and capture_onset_snap_ms > 0:
		var best_ms: int = ms
		var best_d: int = capture_onset_snap_ms + 1

		for o in analysis_onsets:
			var oms: int = int(o.get("t_ms", 0))
			var d: int = abs(oms - ms)
			if d < best_d:
				best_d = d
				best_ms = oms

		if best_d <= capture_onset_snap_ms:
			return float(best_ms) / 1000.0

	return t_s


func _capture_finalize_into_events() -> void:
	if capture_passes.is_empty():
		return

	var merged: Array[Dictionary] = []
	for p in capture_passes:
		var pid: String = String(p.get("id", ""))
		var arr: Array = capture_taps_by_pass.get(pid, [])
		for t_any in arr:
			merged.append({
				"t": float(t_any),
				"pass_id": pid
			})

	if merged.is_empty():
		info.text = "Capture finished, but no taps were recorded."
		return

	merged.sort_custom(Callable(self, "_sort_capture_entry_by_t"))

	_begin_action("Finalize capture")

	if capture_clear_first:
		events.clear()
		_clear_selection()
		_events_dirty = true
		_next_event_id = 1

	var lane_last_t: Array[float] = []
	lane_last_t.resize(lane_count)
	for i in range(lane_count):
		lane_last_t[i] = -1e9

	var pass_rot: Dictionary = {
		"beats": 0,
		"melody": 0,
		"fx": 0
	}

	var global_last_t: float = -1e9
	var lane_counts: Array[int] = []
	lane_counts.resize(lane_count)
	for i in range(lane_count):
		lane_counts[i] = 0

	var added: int = 0
	var skipped_global: int = 0
	var skipped_lane: int = 0

	var lane_gap_s: float = float(capture_lane_gap_ms) / 1000.0
	var global_gap_s: float = float(capture_global_gap_ms) / 1000.0

	for item in merged:
		var t_s: float = float(item.get("t", 0.0))
		var pid: String = String(item.get("pass_id", ""))

		if global_gap_s > 0.0 and (t_s - global_last_t) < global_gap_s:
			skipped_global += 1
			continue

		var lane: int = _capture_pick_lane_for_pass(pid, pass_rot, lane_last_t)

		if lane < 0 or lane >= lane_count:
			continue

		if (t_s - lane_last_t[lane]) < lane_gap_s:
			var lane_alt: int = _capture_pick_lane_for_pass(pid, pass_rot, lane_last_t)
			if lane_alt >= 0 and lane_alt < lane_count and (t_s - lane_last_t[lane_alt]) >= lane_gap_s:
				lane = lane_alt
			else:
				skipped_lane += 1
				continue

		var e: Dictionary = _make_event(lane, t_s, "lane", 0.10)
		e["src"] = "capture"
		e["capture_pass"] = pid
		e["auto_kind"] = pid
		e["category"] = "generic"
		e["role"] = "generic"

		events.append(e)
		lane_last_t[lane] = t_s
		global_last_t = t_s
		lane_counts[lane] += 1
		added += 1

	_events_dirty = true
	_commit_action()

	# Persist the raw capture source data too
	capture_saved_data = _build_capture_save_data(true)

	print("[CaptureDBG] FINAL added=", added, " lane_counts=", lane_counts, " skip_global=", skipped_global, " skip_lane=", skipped_lane)
	info.text = "Capture merged: +%d | lanes=%s | skipG=%d | skipL=%d" % [added, str(lane_counts), skipped_global, skipped_lane]
	queue_redraw()

func _capture_pick_lane_for_pass(pass_id: String, pass_rot: Dictionary, lane_last_t: Array[float]) -> int:
	var lanes_any: Variant = capture_pass_lane_config.get(pass_id, [])
	var lanes: Array[int] = []

	if lanes_any is Array:
		for v in (lanes_any as Array):
			lanes.append(int(v))

	if lanes.is_empty():
		for i in range(lane_count):
			lanes.append(i)

	# beats / melody: rotate through chosen lanes
	if pass_id == "beats" or pass_id == "melody":
		var ri: int = int(pass_rot.get(pass_id, 0))
		var lane: int = lanes[ri % lanes.size()]
		pass_rot[pass_id] = ri + 1
		return lane

	# fx / other: choose least recently used among chosen lanes
	var best_lane: int = lanes[0]
	var best_t: float = 1e9
	for ln in lanes:
		var lt: float = lane_last_t[ln]
		if lt < best_t:
			best_t = lt
			best_lane = ln
	return best_lane

func _sort_capture_entry_by_t(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("t", 0.0)) < float(b.get("t", 0.0))

func _capture_current_has_taps() -> bool:
	for k in capture_taps_by_pass.keys():
		var v: Variant = capture_taps_by_pass[k]
		if v is Array and (v as Array).size() > 0:
			return true
	return false


func _build_capture_save_data(force_current: bool = false) -> Dictionary:
	var has_current: bool = _capture_current_has_taps()

	# If we don't currently have fresh taps, keep already-loaded saved data
	if not force_current and not has_current and not capture_saved_data.is_empty():
		return capture_saved_data.duplicate(true)

	var passes_out: Array[Dictionary] = []
	for p in capture_passes:
		if p is Dictionary:
			passes_out.append((p as Dictionary).duplicate(true))

	var taps_out: Dictionary = {}
	for k in capture_taps_by_pass.keys():
		var arr_out: Array = []
		var v: Variant = capture_taps_by_pass[k]
		if v is Array:
			for t in (v as Array):
				arr_out.append(float(t))
		taps_out[String(k)] = arr_out

	var lane_cfg_out: Dictionary = {}
	for k in capture_pass_lane_config.keys():
		var arr_out: Array = []
		var v: Variant = capture_pass_lane_config[k]
		if v is Array:
			for ln in (v as Array):
				arr_out.append(int(ln))
		lane_cfg_out[String(k)] = arr_out

	var out: Dictionary = {
		"version": 1,
		"passes": passes_out,
		"taps_by_pass": taps_out,
		"lane_config": lane_cfg_out,
		"settings": {
			"lane_gap_ms": capture_lane_gap_ms,
			"global_gap_ms": capture_global_gap_ms,
			"beat_snap_ms": capture_beat_snap_ms,
			"onset_snap_ms": capture_onset_snap_ms,
			"use_analysis": capture_use_analysis,
			"clear_first": capture_clear_first,
		}
	}

	capture_saved_data = out.duplicate(true)
	return out


func _load_capture_save_data(v: Variant) -> void:
	capture_saved_data.clear()
	capture_passes.clear()
	capture_taps_by_pass.clear()

	# keep sane defaults if nothing is present
	capture_pass_lane_config = {
		"beats": [0, 2],
		"melody": [1, 3],
		"fx": [0, 1, 2, 3],
	}

	if v is not Dictionary:
		return

	var d: Dictionary = (v as Dictionary).duplicate(true)
	if d.is_empty():
		return

	capture_saved_data = d.duplicate(true)

	var pv: Variant = d.get("passes", [])
	if pv is Array:
		for item in (pv as Array):
			if item is Dictionary:
				capture_passes.append((item as Dictionary).duplicate(true))

	var tv: Variant = d.get("taps_by_pass", {})
	if tv is Dictionary:
		for k in (tv as Dictionary).keys():
			var arr_out: Array = []
			var vv: Variant = (tv as Dictionary)[k]
			if vv is Array:
				for t in (vv as Array):
					arr_out.append(float(t))
			capture_taps_by_pass[String(k)] = arr_out

	var lv: Variant = d.get("lane_config", {})
	if lv is Dictionary:
		for k in (lv as Dictionary).keys():
			var arr_out: Array = []
			var vv: Variant = (lv as Dictionary)[k]
			if vv is Array:
				for ln in (vv as Array):
					arr_out.append(int(ln))
			capture_pass_lane_config[String(k)] = arr_out

	var sv: Variant = d.get("settings", {})
	if sv is Dictionary:
		var s: Dictionary = sv as Dictionary
		capture_lane_gap_ms = int(s.get("lane_gap_ms", capture_lane_gap_ms))
		capture_global_gap_ms = int(s.get("global_gap_ms", capture_global_gap_ms))
		capture_beat_snap_ms = int(s.get("beat_snap_ms", capture_beat_snap_ms))
		capture_onset_snap_ms = int(s.get("onset_snap_ms", capture_onset_snap_ms))
		capture_use_analysis = bool(s.get("use_analysis", capture_use_analysis))
		capture_clear_first = bool(s.get("clear_first", capture_clear_first))

	print("[CaptureDBG] loaded capture_data passes=", capture_passes.size(), " tap_keys=", capture_taps_by_pass.keys())

# ============================================================
# BASIC UI/SETUP
# ============================================================

func _setup_ui() -> void:
	if bpm_edit.text == "":
		bpm_edit.text = str(int(bpm))
	if offset_edit.text == "":
		offset_edit.text = str(offset_ms)

func _on_speed_changed(v: float) -> void:
	speed_value = clamp(v, 0.10, 2.00)
	_apply_speed()
	if speed_readout != null:
		speed_readout.text = "x%.2f" % speed_value
	info.text = "Speed x%.2f | Latency %d ms | Zoom %.2fs" % [speed_value, latency_ms, approach_time]

func _apply_speed() -> void:
	song_player.pitch_scale = speed_value

# ============================================================
# TAG POPUP
# ============================================================

func _refresh_role_options(cat: String, desired_role: String) -> void:
	if tag_role_opt == null:
		return
	tag_role_opt.clear()

	var roles: Array = []
	if ROLES_BY_CATEGORY.has(cat):
		roles = ROLES_BY_CATEGORY[cat]
	else:
		roles = ["generic"]

	for r in roles:
		tag_role_opt.add_item(str(r))

	var target := desired_role
	if target == "" or not roles.has(target):
		target = roles[0]

	_select_option_button_by_text(tag_role_opt, target)

func _show_tag_popup() -> void:
	if tag_popup == null:
		return
	_select_option_button_by_text(tag_category_opt, current_category)
	_refresh_role_options(current_category, current_role)
	tag_popup.popup_centered(Vector2(320, 240))

func _select_option_button_by_text(ob: OptionButton, text: String) -> void:
	if ob == null:
		return
	for i in range(ob.item_count):
		if ob.get_item_text(i) == text:
			ob.selected = i
			return

func _on_tag_popup_ok() -> void:
	if tag_category_opt != null and tag_category_opt.item_count > 0:
		current_category = tag_category_opt.get_item_text(tag_category_opt.selected)
	if tag_role_opt != null and tag_role_opt.item_count > 0:
		current_role = tag_role_opt.get_item_text(tag_role_opt.selected)

	info.text = "Category=%s, role=%s" % [current_category, current_role]
	tag_popup.hide()

func _on_tag_popup_cancel() -> void:
	tag_popup.hide()

func _on_tag_category_changed(index: int) -> void:
	if tag_category_opt == null:
		return
	var new_cat := tag_category_opt.get_item_text(index)
	var roles: Array = ROLES_BY_CATEGORY.get(new_cat, ["generic"])
	var default_role: String = String(roles[0])
	_refresh_role_options(new_cat, default_role)

# ============================================================
# TIME / TRANSPORT
# ============================================================

func _play_time() -> float:
	var tplay: float = song_player.get_playback_position()
	tplay += AudioServer.get_time_since_last_mix()
	tplay -= AudioServer.get_output_latency()

	var comp: float = float(latency_ms) / 1000.0
	return max(0.0, tplay - comp)

func _tbase() -> float:
	if song_player.stream == null:
		return 0.0

	if song_player.playing and not song_player.stream_paused:
		follow_playhead = true
		view_time = _play_time()
		return view_time

	if follow_playhead:
		view_time = _play_time()
		return view_time

	return view_time

func _toggle_play() -> void:
	if song_player.stream == null:
		info.text = "No song loaded. Press P to pick a WAV/MP3/OGG."
		return

	if not song_player.playing and not song_player.stream_paused:
		song_player.play()
		song_player.stream_paused = false
		follow_playhead = true
		info.text = "Play"
		return

	song_player.stream_paused = not song_player.stream_paused
	if song_player.stream_paused:
		follow_playhead = false
		view_time = _play_time()
		info.text = "Paused"
	else:
		follow_playhead = true
		info.text = "Resume"

func _reset_song() -> void:
	if song_player.stream == null:
		return
	song_player.stop()
	song_player.play(0.0)
	song_player.stream_paused = false
	follow_playhead = true
	view_time = 0.0
	info.text = "Reset → 0.00s | Speed x%.2f" % speed_value

func _seek_abs(t: float) -> void:
	if song_player.stream == null:
		return
	var total: float = _get_song_length()
	var tt: float = clamp(t, 0.0, total)
	song_player.seek(tt)
	view_time = max(0.0, tt - float(latency_ms)/1000.0)
	follow_playhead = false

func _seek_rel(dt: float) -> void:
	if song_player.stream == null:
		return
	var t: float = song_player.get_playback_position() + dt
	_seek_abs(t)
	info.text = "Seek: %.2fs" % song_player.get_playback_position()

func beat_duration() -> float:
	return 60.0 / max(1.0, bpm)

func _q(t: float) -> float:
	if not quantize_on:
		return t

	# Smart quantize to analysis beats (if available)
	if smart_quantize and analysis_beats_ms.size() > 0:
		var ms: int = int(round(t * 1000.0))
		var snapped_ms: int = _snap_ms_to_list(ms, analysis_beats_ms, smart_quantize_window_ms)
		return float(snapped_ms) / 1000.0

	# Grid quantize
	var off: float = float(offset_ms) / 1000.0
	var step: float = beat_duration() / float(max(1, quantize_div))
	var rel: float = t - off
	var steps: float = round(rel / step)
	return off + steps * step


func _snap_ms_to_list(ms: int, arr: Array[int], window_ms: int) -> int:
	if arr.is_empty():
		return ms
	var i: int = _lower_bound_int(arr, ms)
	var best: int = ms
	var best_d: int = window_ms + 1

	if i < arr.size():
		var d0: int = abs(arr[i] - ms)
		if d0 < best_d:
			best_d = d0
			best = arr[i]
	if i > 0:
		var d1: int = abs(arr[i-1] - ms)
		if d1 < best_d:
			best_d = d1
			best = arr[i-1]

	return best if best_d <= window_ms else ms

func _lower_bound_int(arr: Array[int], x: int) -> int:
	var lo := 0
	var hi := arr.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if arr[mid] < x:
			lo = mid + 1
		else:
			hi = mid
	return lo

# ============================================================
# INPUT HANDLING (keys + mouse)
# ============================================================

func _is_text_entry_focused() -> bool:
	var foc := get_viewport().gui_get_focus_owner()
	if foc == null:
		return false
	return (foc is LineEdit) or (foc is TextEdit)

func _should_block_mapping() -> bool:
	if _is_text_entry_focused():
		return true
	if tag_popup != null and tag_popup.visible:
		return true
	if schema_popup != null and schema_popup.visible:
		return true
	if lint_popup != null and lint_popup.visible:
		return true
	if analysis_popup != null and analysis_popup.visible:
		return true
	if autofinish_popup != null and autofinish_popup.visible:
		return true
	return false
	

func _unhandled_input(ev: InputEvent) -> void:
	var k: InputEventKey = ev as InputEventKey
	if k != null and k.pressed and not k.echo:
		if _is_text_entry_focused():
			if k.physical_keycode == KEY_H and k.alt_pressed and k.shift_pressed:
				show_help = not show_help
				_update_help_text()
			return

		var ctrl: bool = k.ctrl_pressed

		match k.physical_keycode:
			KEY_D:
				if ctrl and k.alt_pressed:
					_confirm_return_to_main_menu(); return

			KEY_HOME, KEY_0:
				_reset_song(); return
			KEY_BACKSPACE:
				if ctrl:
					_reset_song(); return
				else:
					_delete_selection(); return
			KEY_DELETE:
				_delete_selection(); return

			KEY_Q:
				var step_q: float = 0.01 if ctrl else 0.05
				speed_value = clamp(speed_value - step_q, 0.10, 2.00)
				speed_slider.value = speed_value
				info.text = "Speed x%.2f | Latency %d ms" % [speed_value, latency_ms]
				return

			KEY_E:
				var step_e: float = 0.01 if ctrl else 0.05
				speed_value = clamp(speed_value + step_e, 0.10, 2.00)
				speed_slider.value = speed_value
				info.text = "Speed x%.2f | Latency %d ms" % [speed_value, latency_ms]
				return

			KEY_LEFT:
				if not song_player.playing:
					_seek_rel(-0.10); return
			KEY_RIGHT:
				if not song_player.playing:
					_seek_rel(0.10); return

			KEY_R:
				_seek_rel(-2.0); return
			KEY_T:
				_seek_rel(2.0); return

			KEY_M:
				if ctrl and not k.shift_pressed:
					_save_chart(); return
				if ctrl and k.shift_pressed:
					_export_compiled(); return
				_assist_step(-1); return

			KEY_B:
				if ctrl:
					_save_backup(); return

			KEY_P:
				_pick_song(); return

			KEY_U:
				if ctrl:
					var clear_first: bool = k.shift_pressed
					_open_autofinish_popup(clear_first)
					return

			KEY_F1:
				_toggle_preview(); return
			KEY_F2:
				show_minimap = not show_minimap; queue_redraw(); return
			KEY_F3:
				show_grid = not show_grid; queue_redraw(); return
			KEY_F4:
				if ctrl:
					smart_quantize = not smart_quantize
					info.text = "SmartQuant: %s" % ("ON" if smart_quantize else "OFF")
				else:
					quantize_on = not quantize_on
					info.text = "Quantize: %s" % ("ON" if quantize_on else "OFF")
				queue_redraw()
				return

			KEY_F5:
				_open_audio_calib(); return

			KEY_F6:
				_open_lint_popup(); return
			KEY_F7:
				_open_schema_popup(); return
			KEY_F12:
				_analyze_current_song(); return
			KEY_F9:
				_export_compiled(); return
			KEY_F10:
				_toggle_guides(); return
			KEY_F11:
				_open_analysis_popup(); return

			KEY_BRACKETLEFT:
				latency_ms = max(-200, latency_ms - 5)
				info.text = "Latency %d ms | Speed x%.2f" % [latency_ms, speed_value]
				return

			KEY_BRACKETRIGHT:
				latency_ms = min(200, latency_ms + 5)
				info.text = "Latency %d ms | Speed x%.2f" % [latency_ms, speed_value]
				return

			KEY_SLASH:
				_show_tag_popup(); return

			KEY_H:
				if k.alt_pressed and k.shift_pressed:
					show_help = not show_help
					_update_help_text()
				else:
					holds_enabled = not holds_enabled
					var holds_label := "ON" if holds_enabled else "OFF"
					info.text = "Holds: %s | Category=%s role=%s" % [holds_label, current_category, current_role]
				return

			KEY_N:
				_assist_step(1); return

			KEY_G:
				_assist_toggle_source(); return
			KEY_ENTER, KEY_KP_ENTER:
				_assist_place_at_current(); return

			KEY_Z:
				if ctrl and k.shift_pressed:
					_redo(); return
				if ctrl:
					_undo(); return
				_undo(); return
			KEY_Y:
				if ctrl:
					_redo(); return

			KEY_C:
				if ctrl:
					_copy_selection(); return
			KEY_V:
				if ctrl:
					_paste_clipboard(); return
					
			KEY_1:
				if ctrl:
					_convert_selected_to_capture_pass("beats")
					return

			KEY_2:
				if ctrl:
					_convert_selected_to_capture_pass("melody")
					return

			KEY_3:
				if ctrl:
					_convert_selected_to_capture_pass("fx")
					return

			KEY_4:
				if ctrl:
					_convert_selected_to_generic()
					return

	if Input.is_action_just_pressed("rhythm_pause"):
		_toggle_play()

# ----------------------------
# Mouse actions
# ----------------------------

func _on_left_down(mb: InputEventMouseButton) -> void:
	if _mouse_in_minimap:
		_scrub_active = true
		_scrub_from_mouse(mb.position)
		return

	if not _mouse_in_track:
		return

	if mb.shift_pressed:
		_begin_action("Add note")
		var t_place: float = _mouse_time
		# If assist enabled and using analysis guides, shift-click uses current assist time (super fast mapping)
		if assist_enabled:
			var at := _assist_current_time_s()
			if at >= 0.0:
				t_place = at
		_place_at(_mouse_lane, t_place)
		_commit_action()
		return

	if mb.alt_pressed and selected_ids.size() > 0:
		_move_active = true
		_move_start_pos = mb.position
		_move_start_snapshot = _snapshot()
		return

	_marquee_active = true
	_marquee_start = mb.position
	_marquee_end = mb.position

func _on_left_up(mb: InputEventMouseButton) -> void:
	if _scrub_active:
		_scrub_active = false
		return

	if _move_active:
		_move_active = false
		_finish_move_selection()
		return

	if _marquee_active:
		_marquee_active = false
		var drag_dist: float = _marquee_start.distance_to(_marquee_end)

		if drag_dist < 6.0:
			_select_nearest_at_mouse(mb.ctrl_pressed)
		else:
			_select_in_marquee(mb.ctrl_pressed)

func _on_right_down(mb: InputEventMouseButton) -> void:
	if not _mouse_in_track:
		return

	# First try exact clicked note under mouse
	var id: int = _find_event_id_at_mouse(mb.position)

	# Fallback: nearest note in hovered lane/time
	if id <= 0:
		id = _find_nearest_event_id(_mouse_lane, _mouse_time, 0.180)

	if id <= 0:
		info.text = "Delete: no note under cursor."
		return

	_begin_action("Delete note")

	var keep: Array[Dictionary] = []
	for e in events:
		if int(e.get("id", 0)) != id:
			keep.append(e)
	events = keep

	_events_dirty = true
	_set_selected(id, false)
	_commit_action()

	info.text = "Deleted note."

func _handle_wheel(mw: InputEventMouseButton) -> void:
	_update_mouse_hover_state()

	if not _mouse_in_track and not _mouse_in_minimap:
		return

	var up: bool = (mw.button_index == MOUSE_BUTTON_WHEEL_UP)
	var dir: float = -1.0 if up else 1.0

	if mw.shift_pressed:
		if song_player.stream == null:
			return
		var step: float = 0.25
		if mw.ctrl_pressed:
			step = 0.06
		_seek_rel(dir * step)
		queue_redraw()
		return

	var step_mul: float = ZOOM_STEP
	if mw.ctrl_pressed:
		step_mul = ZOOM_FINE_STEP

	if up:
		approach_time *= step_mul
	else:
		approach_time /= step_mul

	approach_time = clamp(approach_time, 0.15, 6.0)
	info.text = "Zoom: %.2fs (Wheel) | Shift+Wheel = pan" % approach_time

# ============================================================
# Mouse hover / ghost preview
# ============================================================

func _update_mouse_hover_state() -> void:
	var track_r: Rect2 = _track_rect()
	var mini_r: Rect2 = _minimap_rect()

	_mouse_in_track = track_r.has_point(_mouse_pos)
	_mouse_in_minimap = show_minimap and mini_r.has_point(_mouse_pos)

	if _mouse_in_track:
		_mouse_lane = _lane_from_x(_mouse_pos.x, track_r)
		var t_raw: float = _time_from_y(_mouse_pos.y)
		_mouse_time = _q(t_raw)
	else:
		_mouse_lane = 0
		_mouse_time = 0.0

func _scrub_from_mouse(pos: Vector2) -> void:
	if not show_minimap:
		return
	var r: Rect2 = _minimap_rect()
	if not r.has_point(pos):
		return
	var total: float = _get_song_length()
	if total <= 0.01:
		return

	var px_per_s: float = r.size.x / total
	var t_seek: float = clamp((pos.x - r.position.x) / px_per_s, 0.0, total)
	_seek_abs(t_seek)
	info.text = "Scrub: %.2fs" % t_seek

func _find_event_id_at_mouse(pos: Vector2) -> int:
	if not _mouse_in_track:
		return -1

	var track_r: Rect2 = _track_rect()
	var lane_w: float = track_r.size.x / float(lane_count)
	var tbase: float = _tbase()

	var time_range: Array[float] = _visible_time_range(track_r, tbase, 0.8)
	var vis: Array[Dictionary] = _get_events_in_time_range(time_range[0], time_range[1])

	var best_id: int = -1
	var best_d2: float = 1e20

	for e in vis:
		var id: int = int(e.get("id", 0))
		var typ: String = String(e.get("type", "lane"))
		var lane: int = int(e.get("lane", 0))
		if lane < 0 or lane >= lane_count:
			continue

		var t0: float = float(e.get("t", 0.0))
		var y0: float = _note_y_for_time(t0, tbase)
		var x0: float = track_r.position.x + float(lane) * lane_w + NOTE_PAD_X
		var x1: float = track_r.position.x + float(lane + 1) * lane_w - NOTE_PAD_X

		var rr: Rect2
		if typ == "hold":
			var dur: float = float(e.get("dur", 0.0))
			var y1: float = _note_y_for_time(t0 + dur, tbase)
			var y_top: float = min(y0, y1)
			var h: float = max(8.0, abs(y1 - y0))
			rr = Rect2(Vector2(x0, y_top), Vector2(x1 - x0, h))
		else:
			rr = Rect2(Vector2(x0, y0 - NOTE_H * 0.5), Vector2(x1 - x0, NOTE_H))

		var hit_rr: Rect2 = rr.grow(4.0)
		if hit_rr.has_point(pos):
			var d2: float = pos.distance_squared_to(rr.get_center())
			if d2 < best_d2:
				best_d2 = d2
				best_id = id

	return best_id

# ============================================================
# Gamepad editor cursor helpers
# ============================================================

func _poll_editor_gamepad() -> void:
	if not gp_editor_enabled:
		return
	if _should_block_mapping():
		_gp_repeat_next.clear()
		return

	if not gp_cursor_initialized:
		gp_cursor_lane = clamp(gp_cursor_lane, 0, lane_count - 1)
		gp_cursor_time = _q(_tbase())
		gp_cursor_initialized = true

	var moved_cursor: bool = false
	var step_t: float = _gamepad_cursor_step()

	if _gp_repeat_pressed("editor_gp_lane_left", "lane_left"):
		_gamepad_move_cursor_lane(-1)
		moved_cursor = true

	if _gp_repeat_pressed("editor_gp_lane_right", "lane_right"):
		_gamepad_move_cursor_lane(1)
		moved_cursor = true

	if _gp_repeat_pressed("editor_gp_time_forward", "time_forward"):
		_gamepad_move_cursor_time(step_t)
		moved_cursor = true

	if _gp_repeat_pressed("editor_gp_time_back", "time_back"):
		_gamepad_move_cursor_time(-step_t)
		moved_cursor = true

	if moved_cursor:
		follow_playhead = false
		view_time = gp_cursor_time
		info.text = "GP Cursor → lane %d | %.3fs" % [gp_cursor_lane, gp_cursor_time]

	if Input.is_action_just_pressed("editor_gp_select"):
		_gamepad_select_at_cursor(false)

	if Input.is_action_just_pressed("editor_gp_toggle_select"):
		_gamepad_select_at_cursor(true)

	if Input.is_action_just_pressed("editor_gp_clear_selection"):
		_clear_selection()
		info.text = "Selection cleared."

	if Input.is_action_just_pressed("editor_gp_place"):
		_gamepad_place_at_cursor()

	if Input.is_action_just_pressed("editor_gp_delete"):
		if not selected_ids.is_empty():
			_delete_selection()
		else:
			_gamepad_delete_at_cursor()

	if _selection_count() > 0:
		var nudge_t: float = _gamepad_nudge_step()

		if _gp_repeat_pressed("editor_gp_nudge_left", "nudge_left"):
			_gamepad_nudge_selection(-1, 0.0)
		elif _gp_repeat_pressed("editor_gp_nudge_right", "nudge_right"):
			_gamepad_nudge_selection(1, 0.0)
		elif _gp_repeat_pressed("editor_gp_nudge_up", "nudge_up"):
			_gamepad_nudge_selection(0, nudge_t)
		elif _gp_repeat_pressed("editor_gp_nudge_down", "nudge_down"):
			_gamepad_nudge_selection(0, -nudge_t)

func _gp_repeat_pressed(action: String, key: String) -> bool:
	var now_s: float = float(Time.get_ticks_msec()) / 1000.0

	if Input.is_action_just_pressed(action):
		_gp_repeat_next[key] = now_s + GP_NAV_FIRST_DELAY
		return true

	if Input.is_action_pressed(action):
		var next_s: float = float(_gp_repeat_next.get(key, 0.0))
		if next_s > 0.0 and now_s >= next_s:
			_gp_repeat_next[key] = now_s + GP_NAV_REPEAT_RATE
			return true
	else:
		if _gp_repeat_next.has(key):
			_gp_repeat_next.erase(key)

	return false

func _gamepad_cursor_step() -> float:
	if quantize_on:
		return max(beat_duration() / float(max(1, quantize_div)), 0.01)
	return GP_CURSOR_STEP_FREE

func _gamepad_nudge_step() -> float:
	if quantize_on:
		return max(beat_duration() / float(max(1, quantize_div)), 0.01)
	return GP_CURSOR_STEP_FREE

func _gamepad_move_cursor_lane(delta: int) -> void:
	gp_cursor_lane = clamp(gp_cursor_lane + delta, 0, lane_count - 1)

func _gamepad_move_cursor_time(delta_t: float) -> void:
	var total: float = _get_song_length()
	var t_new: float = clamp(gp_cursor_time + delta_t, 0.0, total)
	gp_cursor_time = _q(t_new) if quantize_on else t_new

func _gamepad_place_at_cursor() -> void:
	_begin_action("Gamepad place")
	_place_at(gp_cursor_lane, gp_cursor_time)
	_commit_action()
	info.text = "Placed note → lane %d | %.3fs" % [gp_cursor_lane, gp_cursor_time]

func _gamepad_select_at_cursor(toggle_mode: bool) -> void:
	var id: int = _find_nearest_event_id(gp_cursor_lane, gp_cursor_time, 0.180)
	if id <= 0:
		if not toggle_mode:
			_clear_selection()
			info.text = "Select: no note near cursor."
		return

	if toggle_mode:
		_toggle_selected(id)
	else:
		_clear_selection()
		_set_selected(id, true)

	info.text = "Selected: %d" % _selection_count()

func _gamepad_delete_at_cursor() -> void:
	var id: int = _find_nearest_event_id(gp_cursor_lane, gp_cursor_time, 0.180)
	if id <= 0:
		info.text = "Delete: no note near cursor."
		return

	_begin_action("Gamepad delete note")

	var keep: Array[Dictionary] = []
	for e in events:
		if int(e.get("id", 0)) != id:
			keep.append(e)
	events = keep

	_events_dirty = true
	_set_selected(id, false)
	_commit_action()

	info.text = "Deleted note."

func _gamepad_nudge_selection(delta_lane: int, delta_t: float) -> void:
	if selected_ids.is_empty():
		return

	_begin_action("Gamepad move selection")

	for e in events:
		var id: int = int(e.get("id", 0))
		if not _selected_set.has(id):
			continue

		if delta_lane != 0:
			var lane: int = int(e.get("lane", 0))
			e["lane"] = clamp(lane + delta_lane, 0, lane_count - 1)

		if abs(delta_t) > 0.000001:
			var t0: float = float(e.get("t", 0.0))
			var t1: float = max(0.0, t0 + delta_t)
			e["t"] = _q(t1) if quantize_on else t1

	_events_dirty = true
	_commit_action()

	info.text = "Moved selection (%d)." % _selection_count()

func _draw_gamepad_cursor(track_r: Rect2, lane_w: float, tbase: float) -> void:
	if not gp_editor_enabled or not gp_cursor_initialized:
		return
	if _should_block_mapping():
		return

	var lane: int = clamp(gp_cursor_lane, 0, lane_count - 1)
	var t0: float = clamp(gp_cursor_time, 0.0, _get_song_length())
	var y0: float = _note_y_for_time(t0, tbase)

	var x0: float = track_r.position.x + float(lane) * lane_w + NOTE_PAD_X
	var x1: float = track_r.position.x + float(lane + 1) * lane_w - NOTE_PAD_X

	var base_fill: Color = _cat_base(current_category)
	var lane_col: Color = LANE_COLS[clamp(lane, 0, LANE_COLS.size() - 1)]
	var fill: Color = base_fill.lerp(lane_col, 0.10)
	fill.a = 0.16

	var outline: Color = Color(1.0, 0.95, 0.35, 0.95)
	var rr: Rect2 = Rect2(Vector2(x0, y0 - NOTE_H * 0.5), Vector2(x1 - x0, NOTE_H))

	draw_rect(rr, fill, true)
	_draw_role_pattern(rr, current_category, current_role)
	draw_rect(rr.grow(2.0), outline, false, 2.0)

	draw_line(
		Vector2(track_r.position.x + float(lane) * lane_w, y0),
		Vector2(track_r.position.x + float(lane + 1) * lane_w, y0),
		Color(1.0, 0.95, 0.35, 0.70),
		1.5
	)

	draw_string(
		get_theme_default_font(),
		Vector2(x0 + 6.0, y0 - 12.0),
		"GP",
		HORIZONTAL_ALIGNMENT_LEFT as HorizontalAlignment,
		-1,
		12,
		Color(1.0, 0.95, 0.35, 0.95)
	)

# ============================================================
# Selection helpers
# ============================================================

func _clear_selection() -> void:
	selected_ids.clear()
	_selected_set.clear()

func _set_selected(id: int, value: bool) -> void:
	if value:
		if not _selected_set.has(id):
			_selected_set[id] = true
			selected_ids.append(id)
	else:
		if _selected_set.has(id):
			_selected_set.erase(id)
			for i in range(selected_ids.size()):
				if selected_ids[i] == id:
					selected_ids.remove_at(i)
					break

func _toggle_selected(id: int) -> void:
	_set_selected(id, not _selected_set.has(id))

func _selection_count() -> int:
	return selected_ids.size()

func _select_nearest_at_mouse(ctrl_toggle: bool) -> void:
	if not _mouse_in_track:
		return

	# Use exact rect hit first — correctly picks up hold note bodies.
	# Fall back to time-based search for normal notes that are close but not pixel-perfect.
	var id: int = _find_event_id_at_mouse(_mouse_pos)
	if id <= 0:
		id = _find_nearest_event_id(_mouse_lane, _mouse_time, 0.180)

	if id <= 0:
		if not ctrl_toggle:
			_clear_selection()
		return

	if ctrl_toggle:
		_toggle_selected(id)
	else:
		_clear_selection()
		_set_selected(id, true)

	info.text = "Selected: %d" % _selection_count()

func _select_in_marquee(ctrl_add_toggle: bool) -> void:
	var rect := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
	var ids_in_box: Array[int] = _event_ids_in_screen_rect(rect)

	if not ctrl_add_toggle:
		_clear_selection()

	for id in ids_in_box:
		_set_selected(id, true)

	info.text = "Selected: %d (marquee)" % _selection_count()

func _event_ids_in_screen_rect(r: Rect2) -> Array[int]:
	var out: Array[int] = []
	var track_r: Rect2 = _track_rect()
	var lane_w: float = track_r.size.x / float(lane_count)
	var tbase: float = _tbase()

	# PERF: only check visible events
	var time_range: Array[float] = _visible_time_range(track_r, tbase, 0.6)
	var vis: Array[Dictionary] = _get_events_in_time_range(time_range[0], time_range[1])

	for e in vis:
		var id: int = int(e.get("id", 0))
		var typ: String = String(e.get("type", "lane"))
		var lane: int = int(e.get("lane", 0))
		if lane < 0 or lane >= lane_count:
			continue

		var t0: float = float(e.get("t", 0.0))
		var y0: float = _note_y_for_time(t0, tbase)
		var x0: float = track_r.position.x + float(lane) * lane_w + NOTE_PAD_X
		var x1: float = track_r.position.x + float(lane + 1) * lane_w - NOTE_PAD_X

		var rr: Rect2
		if typ == "hold":
			var dur: float = float(e.get("dur", 0.0))
			var y1: float = _note_y_for_time(t0 + dur, tbase)
			var y_top: float = min(y0, y1)
			var h: float = max(8.0, abs(y1 - y0))
			rr = Rect2(Vector2(x0, y_top), Vector2(x1 - x0, h))
		else:
			rr = Rect2(Vector2(x0, y0 - NOTE_H * 0.5), Vector2(x1 - x0, NOTE_H))

		if rr.intersects(r):
			out.append(id)

	return out

func _delete_selection() -> void:
	if selected_ids.is_empty():
		return

	_begin_action("Delete selection")
	var keep: Array[Dictionary] = []
	for e in events:
		var id: int = int(e.get("id", 0))
		if not _selected_set.has(id):
			keep.append(e)
	events = keep
	_events_dirty = true
	_clear_selection()
	_commit_action()
	info.text = "Deleted selection."

func _copy_selection() -> void:
	if selected_ids.is_empty():
		info.text = "Copy: nothing selected."
		return
	_clipboard_events.clear()

	var min_t: float = 1e9
	for e in events:
		var id: int = int(e.get("id", 0))
		if _selected_set.has(id):
			var c: Dictionary = e.duplicate(true)
			_clipboard_events.append(c)
			min_t = min(min_t, float(c.get("t", 0.0)))

	_clipboard_events.sort_custom(Callable(self, "_sort_ev_by_t_then_lane"))
	_clipboard_min_t = min_t
	info.text = "Copied %d event(s)." % _clipboard_events.size()

func _paste_clipboard() -> void:
	if _clipboard_events.is_empty():
		info.text = "Paste: clipboard empty."
		return
	if song_player.stream == null:
		info.text = "Paste: load a song first."
		return

	var target_t: float
	if _mouse_in_track:
		target_t = _mouse_time
	else:
		target_t = _q(_tbase())

	var dt: float = target_t - _clipboard_min_t

	_begin_action("Paste")
	var new_ids: Array[int] = []

	for c in _clipboard_events:
		var e: Dictionary = c.duplicate(true)
		e["id"] = _alloc_event_id()
		e["t"] = float(e.get("t", 0.0)) + dt
		new_ids.append(int(e["id"]))
		events.append(e)

	_events_dirty = true
	_clear_selection()
	for id in new_ids:
		_set_selected(id, true)

	_commit_action()
	info.text = "Pasted %d event(s)." % new_ids.size()

# ============================================================
# Moving selection (Alt+drag)
# ============================================================

func _move_selection_preview(mouse_pos: Vector2) -> void:
	if _move_start_snapshot.is_empty():
		return

	var dy: float = mouse_pos.y - _move_start_pos.y
	var dt: float = (-dy) / pps

	var track_r: Rect2 = _track_rect()
	var lane_w: float = track_r.size.x / float(lane_count)
	var dx: float = mouse_pos.x - _move_start_pos.x
	var dl: int = int(round(dx / lane_w))

	_apply_snapshot(_move_start_snapshot, false)

	for i in range(events.size()):
		var e: Dictionary = events[i]
		var id: int = int(e.get("id", 0))
		if _selected_set.has(id):
			var lane: int = int(e.get("lane", 0))
			var t0: float = float(e.get("t", 0.0))
			e["t"] = _q(max(0.0, t0 + dt))
			e["lane"] = clamp(lane + dl, 0, lane_count - 1)

	_events_dirty = true

func _finish_move_selection() -> void:
	if _move_start_snapshot.is_empty():
		return
	_begin_action("Move selection", _move_start_snapshot)
	_commit_action()
	_move_start_snapshot = {}
	_events_dirty = true
	info.text = "Moved selection (%d)." % _selection_count()

# ============================================================
# Gamepad lane events
# ============================================================

func _poll_lane_action(lane: int, action: String) -> void:
	var s: float = Input.get_action_strength(action)
	var was: float = _prev_strength[lane]
	var just_down: bool = (was < 0.5 and s >= 0.5)
	var just_up: bool = (was >= 0.5 and s < 0.5)
	_prev_strength[lane] = s
	if just_down:
		_on_lane_down(lane)
	if just_up:
		_on_lane_up(lane)

func _on_lane_down(lane: int) -> void:
	if song_player.stream == null:
		return
	if _should_block_mapping():
		return
	var t: float = _tbase()
	_press_started_at[lane] = t
	if preview_enabled:
		var idx: int = _find_match_for_tap(lane, t, 0.080)
		if idx >= 0:
			_flash_ok_until[lane] = float(Time.get_ticks_msec()) / 1000.0 + 0.12
		else:
			_flash_bad_until[lane] = float(Time.get_ticks_msec()) / 1000.0 + 0.18

func _on_lane_up(lane: int) -> void:
	if song_player.stream == null:
		return
	if _should_block_mapping():
		_press_started_at[lane] = -1.0
		return

	var start_t: float = _press_started_at[lane]
	if start_t < 0.0:
		return
	var end_t: float = _tbase()
	var dur: float = max(0.0, end_t - start_t)
	_press_started_at[lane] = -1.0

	_begin_action("Add (gamepad)")
	if not holds_enabled:
		var tt: float = _q(start_t)
		events.append(_make_event(lane, tt, "lane", 0.10))
	else:
		if dur >= HOLD_MIN:
			var t0: float = _q(start_t)
			var t1: float = _q(start_t + dur)
			var min_hold: float = (beat_duration() / float(max(1, quantize_div))) if quantize_on else 0.0
			var dur_q: float = max(min_hold, t1 - t0)
			events.append(_make_event(lane, t0, "hold", dur_q))
		else:
			var tt2: float = _q(start_t)
			events.append(_make_event(lane, tt2, "lane", 0.10))

	_events_dirty = true
	_commit_action()

# ============================================================
# Event creation / normalization
# ============================================================

func _alloc_event_id() -> int:
	var id: int = _next_event_id
	_next_event_id += 1
	return id

func _make_event(lane: int, t: float, kind: String, dur: float) -> Dictionary:
	return {
		"id": _alloc_event_id(),
		"t": t,
		"type": kind,
		"lane": lane,
		"dur": dur,
		"judgement": ("tap" if kind == "lane" else "hold"),
		"category": current_category,
		"role": current_role,
	}

func _ensure_event_ids_and_fields() -> void:
	var used: Dictionary = {}
	var max_id: int = 0

	for e in events:
		if not e.has("id"):
			e["id"] = _alloc_event_id()
		var id: int = int(e.get("id", 0))
		if id <= 0 or used.has(id):
			e["id"] = _alloc_event_id()
			id = int(e["id"])
		used[id] = true
		max_id = max(max_id, id)

		if not e.has("t"): e["t"] = 0.0
		if not e.has("type"): e["type"] = "lane"
		if not e.has("lane"): e["lane"] = 0
		if not e.has("dur"): e["dur"] = 0.10
		if not e.has("category"): e["category"] = "generic"
		if not e.has("role"): e["role"] = String(ROLES_BY_CATEGORY["generic"][0])

		# The runtime drops any event without a capture_pass it recognises, so a
		# chart missing it loads as an empty level. Backfill from role_class if
		# the note has one, otherwise from the lane it sits in.
		if String(e.get("capture_pass", "")) == "":
			var rc_e: String = String(e.get("role_class", ""))
			if ROLE_CLASS_PASS.has(rc_e):
				e["capture_pass"] = ROLE_CLASS_PASS[rc_e]
			else:
				e["capture_pass"] = "melody" if int(e.get("lane", 0)) == 1 else "beats"

	_next_event_id = max(_next_event_id, max_id + 1)
	_events_dirty = true

# ============================================================
# Save / Load
# ============================================================

func _variant_array_to_dict_array(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if v is Array:
		for item in (v as Array):
			if item is Dictionary:
				out.append((item as Dictionary).duplicate(true))
	return out

func _save_chart() -> void:
	if beatmap_key == "":
		if path_edit.text.strip_edges() != "":
			beatmap_key = _beatmap_key_from_song_path(path_edit.text.strip_edges())
		else:
			beatmap_key = "beatmap"

	key_edit.text = beatmap_key

	bpm = float(bpm_edit.text)
	offset_ms = int(offset_edit.text)
	var song_path: String = _normalize_song_path(path_edit.text)
	if song_path == "":
		info.text = "No song path set."
		return

	_ensure_event_ids_and_fields()

	var bm: Dictionary = {
		"song_path": song_path,
		"bpm": roundi(bpm),
		"offset_ms": offset_ms,
		"lane_schema": lane_schema,
		"analysis_path": analysis_path,
		"capture_data": _build_capture_save_data(),
		"rap_segments": rap_segments,
		"rap_taps": rap_taps,
		"lyrics": lyrics_data,
		"lyric_font": lyric_font_choice,
		"electric_zones": electric_zones,
		"lyrics_rap_words": _te_text(_rap_words_edit),
		"lyrics_sung_lines": _te_text(_sung_lines_edit),
		"drop_buildups": drop_buildups,
		"events": events
	}

	var rel: String = "res://data/beatmaps/%s.json" % beatmap_key
	var f: FileAccess = FileAccess.open(rel, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(bm, "	"))
		f.close()
		info.text = "Saved %d events → %s" % [events.size(), rel]
	else:
		var alt: String = "user://%s.json" % beatmap_key
		var f2: FileAccess = FileAccess.open(alt, FileAccess.WRITE)
		if f2 != null:
			f2.store_string(JSON.stringify(bm, "	"))
			f2.close()
			info.text = "Saved %d events → %s (fallback)" % [events.size(), alt]
		else:
			info.text = "Failed to save chart."

func _save_backup() -> void:
	var dir: String = "user://beatmaps/backups/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var key_for_name := beatmap_key if beatmap_key != "" else "beatmap"
	var outp: String = "%s%s_%s.json" % [dir, key_for_name, ts]

	_ensure_event_ids_and_fields()

	var bm: Dictionary = {
		"song_path": _normalize_song_path(path_edit.text),
		"bpm": int(float(bpm_edit.text)),
		"offset_ms": int(offset_edit.text),
		"lane_schema": lane_schema,
		"analysis_path": analysis_path,
		"capture_data": _build_capture_save_data(),
		"rap_segments": rap_segments,
		"rap_taps": rap_taps,
		"lyrics": lyrics_data,
		"lyric_font": lyric_font_choice,
		"electric_zones": electric_zones,
		"lyrics_rap_words": _te_text(_rap_words_edit),
		"lyrics_sung_lines": _te_text(_sung_lines_edit),
		"drop_buildups": drop_buildups,
		"events": events
	}

	var f: FileAccess = FileAccess.open(outp, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(bm, "	"))
		f.close()
		info.text = "Backup saved → %s" % outp
	else:
		info.text = "Backup failed."

func _normalize_song_path(p: String) -> String:
	var s := p.strip_edges()
	if s == "":
		return s
	# Already a Godot-style path — leave it alone
	if s.begins_with("res://") or s.begins_with("user://"):
		return s
	# Absolute path inside the project → convert to res://
	var localized := ProjectSettings.localize_path(s)
	if localized.begins_with("res://"):
		return localized
	# Outside the project — can't convert, return as-is
	return s


func _beatmap_key_from_song_path(p: String) -> String:
	var base := p.get_file().get_basename()
	base = base.strip_edges().to_lower()
	base = base.replace(" ", "_")
	base = base.replace("-", "_")
	base = base.replace("(", "").replace(")", "")
	base = base.replace("[", "").replace("]", "")
	base = base.replace(".", "_")
	if base == "":
		base = "beatmap"
	return base

func _auto_chart_for_current_key() -> void:
	if beatmap_key == "":
		return
	var rel: String = "res://data/beatmaps/%s.json" % beatmap_key
	if FileAccess.file_exists(rel):
		_on_load_chart()
	else:
		_begin_action("New chart")
		events.clear()
		_events_dirty = true
		_clear_selection()
		_commit_action()
		info.text = "New chart: %s (no existing beatmap)" % beatmap_key

func _pick_song() -> void:
	var fd: FileDialog = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE as FileDialog.FileMode
	fd.access = FileDialog.ACCESS_FILESYSTEM as FileDialog.Access
	fd.filters = PackedStringArray(["*.wav ; WAV","*.mp3 ; MP3","*.ogg ; OGG"])
	add_child(fd)
	fd.file_selected.connect(Callable(self, "_load_song"))
	fd.popup_centered()

func _load_song(p: String) -> void:
	path_edit.text = p
	var stream: Resource = load(p)
	if stream == null:
		info.text = "Failed to load: %s" % p
		return
	song_player.stream = stream

	beatmap_key = _beatmap_key_from_song_path(p)
	key_edit.text = beatmap_key

	_auto_chart_for_current_key()
	_try_autoload_analysis()

	info.text = "Loaded song: %s | Beatmap: %s" % [p.get_file(), beatmap_key]
	queue_redraw()

func _on_load_chart() -> void:
	beatmap_key = key_edit.text.strip_edges()
	if beatmap_key == "":
		info.text = "No beatmap key set."
		return

	var rel: String = "res://data/beatmaps/%s.json" % beatmap_key
	if not FileAccess.file_exists(rel):
		info.text = "No existing chart at %s" % rel
		return

	var f: FileAccess = FileAccess.open(rel, FileAccess.READ)
	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		info.text = "Failed to parse chart."
		return

	_begin_action("Load chart")
	var d: Dictionary = parsed as Dictionary

	events = _variant_array_to_dict_array(d.get("events", []))
	var ls_candidate: Array[Dictionary] = _variant_array_to_dict_array(d.get("lane_schema", []))
	if ls_candidate.size() == lane_count:
		lane_schema = ls_candidate

	var bpm_v: Variant = d.get("bpm", int(bpm))
	bpm_edit.text = str(bpm_v)
	var off_v: Variant = d.get("offset_ms", 0)
	offset_edit.text = str(off_v)
	var path_v: Variant = d.get("song_path", "")
	if str(path_v) != "":
		path_edit.text = str(path_v)

	analysis_path = String(d.get("analysis_path", analysis_path))

	# Load capture source data
	_load_capture_save_data(d.get("capture_data", {}))

	# Load rap data
	rap_segments.clear()
	var rs_raw: Variant = d.get("rap_segments", [])
	if rs_raw is Array:
		for item in (rs_raw as Array):
			if item is Dictionary:
				var itd: Dictionary = item
				var lseg: Dictionary = {"start_t": float(itd.get("start_t", 0.0)), "end_t": float(itd.get("end_t", 0.0))}
				if itd.has("trick"):
					lseg["trick"] = String(itd.get("trick", "random"))
				for k in ["height", "lat", "turns"]:
					if itd.has(k):
						lseg[k] = float(itd.get(k, 0.0))
				rap_segments.append(lseg)
	rap_taps.clear()
	var rt_raw: Variant = d.get("rap_taps", [])
	if rt_raw is Array:
		for t in (rt_raw as Array):
			rap_taps.append(float(t))

	# Charge-tunnel buildups
	drop_buildups.clear()
	var db_raw: Variant = d.get("drop_buildups", [])
	if db_raw is Array:
		for item in (db_raw as Array):
			if item is Dictionary:
				var itd: Dictionary = item
				var dseg: Dictionary = {"start_t": float(itd.get("start_t", 0.0)), "end_t": float(itd.get("end_t", 0.0))}
				if dseg["end_t"] > dseg["start_t"]:
					drop_buildups.append(dseg)

	# Lyric font choice
	lyric_font_choice = String(d.get("lyric_font", "random"))
	_sync_font_opt_to_choice()
	electric_zones.clear()
	var ez_raw: Variant = d.get("electric_zones", [])
	if ez_raw is Array:
		for item in (ez_raw as Array):
			if item is Dictionary:
				var st := float(item.get("start_t", 0.0))
				var et := float(item.get("end_t", 0.0))
				if et > st:
					electric_zones.append({"start_t": st, "end_t": et})
	# Backward compat: old maps with "theme": "electric"
	if electric_zones.is_empty():
		var legacy := String(d.get("theme", "city")).strip_edges()
		if legacy == "electric":
			electric_zones.append({"start_t": 0.0, "end_t": 99999.0})

	# Lyrics: timed data for the engine + the raw editable text (kept even if the user
	# pasted lyrics in advance without timing them).
	lyrics_data.clear()
	var ly_raw: Variant = d.get("lyrics", [])
	if ly_raw is Array:
		for item in (ly_raw as Array):
			if item is Dictionary:
				lyrics_data.append(item)
	var draft_rap := String(d.get("lyrics_rap_words", ""))
	var draft_sung := String(d.get("lyrics_sung_lines", ""))
	if draft_rap == "" and draft_sung == "" and not lyrics_data.is_empty():
		_lyrics_rebuild_boxes_from_data()   # older chart: rebuild editable text from timed lyrics
	else:
		if _rap_words_edit != null:  _rap_words_edit.text  = draft_rap
		if _sung_lines_edit != null: _sung_lines_edit.text = draft_sung

	_clear_selection()
	_ensure_event_ids_and_fields()
	_commit_action()

	_events_dirty = true
	_try_autoload_analysis()

	info.text = "Loaded %d events from %s" % [events.size(), rel]
	queue_redraw()

# ============================================================
# Analysis: run Python + load JSON
# ============================================================

func _analysis_default_out_path() -> String:
	var dir: String = analysis_output_dir.strip_edges()

	# In exported builds, prefer user:// for runtime-generated files
	if dir == "" or (not Engine.is_editor_hint() and dir.begins_with("res://")):
		dir = "user://analysis/"

	if not dir.ends_with("/"):
		dir += "/"

	# Try to create the directory (res:// works in-editor, not in exported builds)
	var abs_dir: String = ProjectSettings.globalize_path(dir)
	var err: int = DirAccess.make_dir_recursive_absolute(abs_dir)
	if err != OK:
		# Fallback
		dir = "user://analysis/"
		abs_dir = ProjectSettings.globalize_path(dir)
		DirAccess.make_dir_recursive_absolute(abs_dir)

	var key_for_name: String = beatmap_key if beatmap_key != "" else "beatmap"
	return "%s%s.analysis.v2.json" % [dir, key_for_name]

func _analyze_current_song() -> void:
	# Shift = quick-run, otherwise show settings popup
	if Input.is_key_pressed(KEY_SHIFT):
		_analyze_current_song_with_settings()
	else:
		_open_analyzer_settings_popup()

func _open_analyzer_settings_popup() -> void:
	if analyzer_settings_popup == null:
		return

	# Sync UI from vars
	(analyzer_settings_popup.get_meta("cb_auto") as CheckBox).button_pressed = analyzer_auto
	(analyzer_settings_popup.get_meta("cb_beatnet") as CheckBox).button_pressed = analyzer_use_beatnet
	var sync_auto: Callable = analyzer_settings_popup.get_meta("sync_auto")
	if sync_auto.is_valid():
		sync_auto.call(analyzer_auto)

	(analyzer_settings_popup.get_meta("sb_min_bpm") as SpinBox).value = analyzer_min_bpm
	(analyzer_settings_popup.get_meta("sb_max_bpm") as SpinBox).value = analyzer_max_bpm
	(analyzer_settings_popup.get_meta("sb_ts") as SpinBox).value = analyzer_ts
	(analyzer_settings_popup.get_meta("sb_snap") as SpinBox).value = analyzer_snap_ms
	(analyzer_settings_popup.get_meta("sb_delta") as SpinBox).value = analyzer_onset_delta
	(analyzer_settings_popup.get_meta("sb_quick") as SpinBox).value = analyzer_quick_seconds

	(analyzer_settings_popup.get_meta("cb_mapgen") as CheckBox).button_pressed = analyzer_mapgen
	(analyzer_settings_popup.get_meta("sl_diff") as HSlider).value = analyzer_map_diff
	(analyzer_settings_popup.get_meta("sb_gap") as SpinBox).value = analyzer_map_min_gap_ms
	(analyzer_settings_popup.get_meta("sb_lanes") as SpinBox).value = analyzer_map_lanes
	(analyzer_settings_popup.get_meta("cb_chords") as CheckBox).button_pressed = analyzer_map_allow_chords

	analyzer_settings_popup.popup_centered(Vector2(760, 560))


func _on_analyzer_settings_run() -> void:
	if analyzer_settings_popup == null:
		return

	analyzer_auto = (analyzer_settings_popup.get_meta("cb_auto") as CheckBox).button_pressed
	analyzer_use_beatnet = (analyzer_settings_popup.get_meta("cb_beatnet") as CheckBox).button_pressed

	analyzer_min_bpm = float((analyzer_settings_popup.get_meta("sb_min_bpm") as SpinBox).value)
	analyzer_max_bpm = float((analyzer_settings_popup.get_meta("sb_max_bpm") as SpinBox).value)
	analyzer_ts = int((analyzer_settings_popup.get_meta("sb_ts") as SpinBox).value)
	analyzer_snap_ms = float((analyzer_settings_popup.get_meta("sb_snap") as SpinBox).value)
	analyzer_onset_delta = float((analyzer_settings_popup.get_meta("sb_delta") as SpinBox).value)
	analyzer_quick_seconds = int((analyzer_settings_popup.get_meta("sb_quick") as SpinBox).value)

	analyzer_mapgen = (analyzer_settings_popup.get_meta("cb_mapgen") as CheckBox).button_pressed
	analyzer_map_diff = int((analyzer_settings_popup.get_meta("sl_diff") as HSlider).value)
	analyzer_map_min_gap_ms = int((analyzer_settings_popup.get_meta("sb_gap") as SpinBox).value)
	analyzer_map_lanes = int((analyzer_settings_popup.get_meta("sb_lanes") as SpinBox).value)
	analyzer_map_allow_chords = (analyzer_settings_popup.get_meta("cb_chords") as CheckBox).button_pressed

	analyzer_settings_popup.hide()
	_analyze_current_song_with_settings()

func _request_cancel_analyzer() -> void:
	if _analyzer_pid == -1 or (not OS.is_process_running(_analyzer_pid)):
		return

	_analyzer_cancel_requested = true
	_set_analyzer_progress(_analyzer_last_pct, "Canceling…")

	if _analyzer_cancel_path != "" and (not FileAccess.file_exists(_analyzer_cancel_path)):
		var f := FileAccess.open(_analyzer_cancel_path, FileAccess.WRITE)
		if f != null:
			f.store_string("{\"cancel\":true}\n")
			f.close()
	_analyzer_dbg("CANCEL requested")

func _analyze_current_song_with_settings() -> void:
	var song_path: String = path_edit.text.strip_edges()
	if song_path == "":
		info.text = "Analyze: load a song first (P)."
		return

	if _analyzer_pid != -1 and OS.is_process_running(_analyzer_pid):
		info.text = "Analyze: already running…"
		return

	var script_abs: String = ProjectSettings.globalize_path(analyzer_script_path).replace("\\", "/")

	# Output path (auto user:// fallback handled inside helper)
	var outp: String = _analysis_default_out_path()
	var out_abs: String = ProjectSettings.globalize_path(outp).replace("\\", "/")

	# Progress + cancel files next to output
	var key_for_name: String = beatmap_key if beatmap_key != "" else "beatmap"
	var prog_p: String = outp.get_base_dir().path_join("%s.analysis.progress.json" % key_for_name)
	var prog_abs: String = ProjectSettings.globalize_path(prog_p).replace("\\", "/")

	_analyzer_cancel_path = outp.get_base_dir().path_join("%s.analysis.cancel.json" % key_for_name)
	var cancel_abs: String = ProjectSettings.globalize_path(_analyzer_cancel_path).replace("\\", "/")

	# Clean stale files (ignore errors)
	if FileAccess.file_exists(prog_p):
		DirAccess.remove_absolute(prog_abs)
	if FileAccess.file_exists(outp):
		DirAccess.remove_absolute(out_abs)
	if FileAccess.file_exists(_analyzer_cancel_path):
		DirAccess.remove_absolute(cancel_abs)

	# Ensure python gets real filesystem paths
	var audio_abs: String = song_path
	if song_path.begins_with("res://") or song_path.begins_with("user://"):
		audio_abs = ProjectSettings.globalize_path(song_path)
	audio_abs = audio_abs.replace("\\", "/")

	# Track run metadata for finalize scan
	_analyzer_start_unix = int(Time.get_unix_time_from_system())
	_analyzer_audio_stem = audio_abs.get_file().get_basename()
	_analyzer_expected_out_abs = out_abs
	_analyzer_expected_dir_abs = out_abs.get_base_dir()

	# Reset runtime state
	_analyzer_out_path = outp
	_analyzer_progress_path = prog_p
	_analyzer_reported_out_abs = ""
	_analyzer_last_msg = ""
	_analyzer_last_pct = 0.0
	_analyzer_poll_accum = 0.0
	_analyzer_cancel_requested = false
	_analyzer_dbg_last_progress_print_ms = -999999

	# Build CLI args for the BeatNet + Librosa fusion analyzer
	var args: Array[String] = [
		"-u",
		script_abs,
		"--cli",
		"--audio", audio_abs,
		"--out", out_abs,
		"--progress-file", prog_abs,
		"--cancel-file", cancel_abs,

		"--min-bpm", str(analyzer_min_bpm),
		"--max-bpm", str(analyzer_max_bpm),
		"--ts", str(analyzer_ts),
		"--snap-ms", str(analyzer_snap_ms),
		"--onset-delta", str(analyzer_onset_delta),
		"--quick-seconds", str(analyzer_quick_seconds),
	]

	if analyzer_auto:
		args.append("--auto")
	else:
		args.append("--no-auto")

	if not analyzer_use_beatnet:
		args.append("--no-beatnet")

	# MapGen
	if analyzer_mapgen:
		args.append("--mapgen")
		args.append("--map-diff")
		args.append(str(analyzer_map_diff))
		args.append("--map-lanes")
		args.append(str(analyzer_map_lanes))
		args.append("--map-min-gap-ms")
		args.append(str(analyzer_map_min_gap_ms))
		if analyzer_map_allow_chords:
			args.append("--map-allow-chords")
	else:
		args.append("--no-mapgen")

	# ✅ DEBUG START PRINT
	_analyzer_dbg("START")
	_analyzer_dbg(" python=" + python_executable)
	_analyzer_dbg(" script=" + script_abs)
	_analyzer_dbg(" audio=" + audio_abs)
	_analyzer_dbg(" out(vpath)=" + outp)
	_analyzer_dbg(" out(abs)=" + out_abs)
	_analyzer_dbg(" progress=" + prog_abs)
	_analyzer_dbg(" cancel=" + cancel_abs)
	_analyzer_dbg(" settings beatnet=%s bpm=%.0f-%.0f ts=%d snap=%.0fms delta=%.3f mapgen=%s diff=%d lanes=%d gap=%d" % [
		str(analyzer_use_beatnet),
		analyzer_min_bpm,
		analyzer_max_bpm,
		analyzer_ts,
		analyzer_snap_ms,
		analyzer_onset_delta,
		str(analyzer_mapgen),
		analyzer_map_diff,
		analyzer_map_lanes,
		analyzer_map_min_gap_ms
	])

	info.text = "Analyzing…"
	call_deferred("_show_analyzer_progress", 0.0, "Starting Beatmap Analyzer…")

	var pid: int = OS.create_process(python_executable, PackedStringArray(args), true)
	if pid <= 0:
		_analyzer_dbg("FAILED to start process (pid<=0)")
		_set_analyzer_progress(0.0, "Failed ✖")
		_hide_analyzer_progress_after(0.6)
		info.text = "Analyze failed: couldn't start python process. Check python_executable + script path."
		_analyzer_out_path = ""
		_analyzer_progress_path = ""
		_analyzer_reported_out_abs = ""
		return

	_analyzer_pid = pid
	_analyzer_dbg("PID=" + str(_analyzer_pid))

func _try_autoload_analysis() -> void:
	# Priority: analysis_path saved in beatmap json, else default path
	if analysis_path != "" and FileAccess.file_exists(analysis_path):
		_load_analysis_json(analysis_path)
		return

	var guess: String = _analysis_default_out_path()
	if FileAccess.file_exists(guess):
		analysis_path = guess
		_load_analysis_json(analysis_path)

func _reload_analysis() -> void:
	if analysis_path == "" or not FileAccess.file_exists(analysis_path):
		info.text = "No analysis json found."
		return
	_load_analysis_json(analysis_path)
	_update_analysis_popup_text()
	info.text = "Reloaded analysis."

func _unload_analysis() -> void:
	analysis_path = ""
	analysis_data.clear()
	analysis_beats_ms.clear()
	analysis_downbeats_ms.clear()
	analysis_onsets.clear()
	analysis_rms_t_ms.clear()
	analysis_rms_v.clear()
	analysis_onsetenv_t_ms.clear()
	analysis_onsetenv_v.clear()
	analysis_map_notes.clear()
	analysis_bars.clear()
	analysis_sections.clear()

	assist_index = 0
	info.text = "Analysis unloaded."
	_update_analysis_popup_text()
	queue_redraw()

func _remake_analysis() -> void:
	# Delete the current analysis file (if possible), then re-run analyze.
	if analysis_path != "" and FileAccess.file_exists(analysis_path):
		var abs_path := ProjectSettings.globalize_path(analysis_path)
		var err := DirAccess.remove_absolute(abs_path)
		if err != OK:
			# Not fatal (res:// may fail in exported builds, or permissions may block delete)
			print("Remake: could not delete analysis file:", abs_path, " err=", err)

	analysis_path = ""
	_analyze_current_song()

func _import_analysis_json() -> void:
	var fd: FileDialog = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE as FileDialog.FileMode
	fd.access = FileDialog.ACCESS_FILESYSTEM as FileDialog.Access
	fd.filters = PackedStringArray(["*.json ; JSON"])
	add_child(fd)
	fd.file_selected.connect(Callable(self, "_on_analysis_file_selected"))
	fd.popup_centered()

func _on_analysis_file_selected(p: String) -> void:
	analysis_path = p
	_load_analysis_json(p)
	_update_analysis_popup_text()
	info.text = "Loaded analysis: %s" % p.get_file()
	queue_redraw()

func _load_analysis_json(p: String) -> void:
	analysis_map_notes.clear()
	analysis_data.clear()
	analysis_beats_ms.clear()
	analysis_downbeats_ms.clear()
	analysis_onsets.clear()
	analysis_rms_t_ms.clear()
	analysis_rms_v.clear()
	analysis_onsetenv_t_ms.clear()
	analysis_onsetenv_v.clear()

	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		info.text = "Failed to read analysis: %s" % p
		return
	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		info.text = "Analysis JSON parse failed."
		return
	analysis_data = parsed as Dictionary

	# ------------------------------------------------------------
	# Beatmap Analyzer schema (seconds-based arrays)
	#   "beatmap_analyzer_v3" -- BeatNet + Librosa fusion (current)
	#   "beatmap_analyzer_v2" -- legacy, same array layout
	# beats/downbeats are arrays of seconds; onsets are dicts in v3.
	# ------------------------------------------------------------
	# A cancelled or failed run still writes a well-formed file, complete with
	# schema and empty arrays, so it loads as a perfectly valid "analysis" that
	# simply has nothing in it -- and Analyze/AutoFinish then appear to do
	# nothing for no visible reason. Treat it as no analysis and say why.
	if analysis_data.has("ok") and not bool(analysis_data.get("ok", true)):
		var why: String = String(analysis_data.get("error", "")).strip_edges()
		if why == "":
			why = "analysis did not complete"
		analysis_data.clear()
		info.text = "Analysis not usable: %s — re-run Analyze (F12)." % why.replace("\n", " ").substr(0, 120)
		_update_analysis_popup_text()
		return

	var schema: String = String(analysis_data.get("schema", ""))
	if _is_supported_schema(schema):
		var beats_s: Variant = analysis_data.get("beats", [])
		if beats_s is Array:
			for t in (beats_s as Array):
				analysis_beats_ms.append(int(round(float(t) * 1000.0)))

		var down_s: Variant = analysis_data.get("downbeats", [])
		if down_s is Array:
			for t in (down_s as Array):
				analysis_downbeats_ms.append(int(round(float(t) * 1000.0)))

		var on_s: Variant = analysis_data.get("onsets", [])
		if on_s is Array:
			for it in (on_s as Array):
				# v3 onsets are dicts carrying band/role/section as well as time.
				# Keep every field: the extra ones drive role-aware mapping.
				if it is Dictionary:
					var d: Dictionary = (it as Dictionary).duplicate(true)
					if not d.has("t_ms"):
						d["t_ms"] = int(round(float(d.get("t", 0.0)) * 1000.0))
					if not d.has("strength"):
						d["strength"] = 1.0
					if not d.has("band"):
						d["band"] = "all"
					if not d.has("src"):
						d["src"] = "analyzer"
					analysis_onsets.append(d)
				else:
					# legacy: bare float seconds
					analysis_onsets.append({
						"t_ms": int(round(float(it) * 1000.0)),
						"t": float(it),
						"strength": 1.0,
						"band": "all",
						"src": "analyzer",
					})

		# Structural read (v3): bars carry tags, sections name drop/breakdown/etc.
		analysis_bars.clear()
		var bl: Variant = analysis_data.get("bars", [])
		if bl is Array:
			for it3 in (bl as Array):
				if it3 is Dictionary:
					analysis_bars.append((it3 as Dictionary).duplicate(true))

		analysis_sections.clear()
		var sl: Variant = analysis_data.get("sections", [])
		if sl is Array:
			for it4 in (sl as Array):
				if it4 is Dictionary:
					analysis_sections.append((it4 as Dictionary).duplicate(true))

		# Adopt the detected tempo. Leaving the editor on its 150 default meant
		# every analyzed chart saved a BPM that was simply wrong, and the value
		# is written into the beatmap the game loads.
		var det_bpm: float = _json_num(analysis_data.get("bpm", null))
		if det_bpm > 20.0 and det_bpm < 400.0:
			bpm = det_bpm
			if bpm_edit != null:
				bpm_edit.text = "%.2f" % det_bpm

			# MapGen notes (if present)
		var mn: Variant = analysis_data.get("map_notes", [])
		if mn is Array:
			for it in (mn as Array):
				if it is Dictionary:
					var nd: Dictionary = (it as Dictionary).duplicate(true)
					# normalize to seconds in "t"
					if nd.has("t_ms") and not nd.has("t"):
						nd["t"] = float(nd.get("t_ms", 0)) / 1000.0
					analysis_map_notes.append(nd)

		analysis_beats_ms.sort()
		analysis_downbeats_ms.sort()
		analysis_onsets.sort_custom(Callable(self, "_sort_onsets_by_t"))

		assist_index = 0
		_seek_assist_to_time(_tbase())

		_update_analysis_popup_text()
		return

	# ----------------------------
	# Legacy schema (your older analyzer JSON)
	# ----------------------------

	# Beats (support both key styles)
	var beats: Dictionary = (analysis_data.get("beats", {}) as Dictionary)

	var bms: Variant = beats.get("beat_ms", null)
	if bms == null:
		bms = beats.get("beats_ms", [])
	if bms is Array:
		for v in (bms as Array):
			analysis_beats_ms.append(int(v))

	var db: Variant = beats.get("downbeat_ms", null)
	if db == null:
		db = beats.get("downbeats_ms", [])
	if db is Array:
		for v in (db as Array):
			analysis_downbeats_ms.append(int(v))

	# Onsets list: [{t_ms,strength,band,src?}, ...]
	var onl: Variant = analysis_data.get("onsets", [])
	if onl is Array:
		for it in (onl as Array):
			if it is Dictionary:
				analysis_onsets.append((it as Dictionary).duplicate(true))

	# Envelopes (support both key styles)
	var envs: Dictionary = (analysis_data.get("envelopes", {}) as Dictionary)

	var rms: Dictionary = (envs.get("rms", {}) as Dictionary)
	var rms_t: Variant = rms.get("t_ms", null)
	if rms_t == null:
		rms_t = rms.get("times_ms", [])
	var rms_vv: Variant = rms.get("v", null)
	if rms_vv == null:
		rms_vv = rms.get("values", [])

	if rms_t is Array and rms_vv is Array:
		var at: Array = rms_t as Array
		var av: Array = rms_vv as Array
		for i in range(min(at.size(), av.size())):
			analysis_rms_t_ms.append(int(at[i]))
			analysis_rms_v.append(float(av[i]))

	var oe: Dictionary = (envs.get("onset_env", {}) as Dictionary)
	var oe_t: Variant = oe.get("t_ms", null)
	if oe_t == null:
		oe_t = oe.get("times_ms", [])
	var oe_v: Variant = oe.get("v", null)
	if oe_v == null:
		oe_v = oe.get("values", [])

		# MapGen notes (legacy / optional)
	var mn2: Variant = analysis_data.get("map_notes", [])
	if mn2 is Array:
		for it2 in (mn2 as Array):
			if it2 is Dictionary:
				var nd2: Dictionary = (it2 as Dictionary).duplicate(true)
				if nd2.has("t_ms") and not nd2.has("t"):
					nd2["t"] = float(nd2.get("t_ms", 0)) / 1000.0
				analysis_map_notes.append(nd2)

	if oe_t is Array and oe_v is Array:
		var bt: Array = oe_t as Array
		var bv: Array = oe_v as Array
		for i in range(min(bt.size(), bv.size())):
			analysis_onsetenv_t_ms.append(int(bt[i]))
			analysis_onsetenv_v.append(float(bv[i]))

	analysis_beats_ms.sort()
	analysis_downbeats_ms.sort()
	analysis_onsets.sort_custom(Callable(self, "_sort_onsets_by_t"))

	assist_index = 0
	_seek_assist_to_time(_tbase())

	_update_analysis_popup_text()

## Safe number read for anything coming out of analysis JSON.
## Dictionary.get(key, default) returns the STORED value when the key exists,
## so a JSON null comes back as null and float(null) is a hard error in
## GDScript -- the default never gets a chance to apply. The analyzer writes
## null for bpm on a failed run and for beatnet.bpm when BeatNet is
## unavailable, so every number read from it goes through here.
func _json_num(v: Variant, def: float = 0.0) -> float:
	if v is float or v is int:
		return float(v)
	return def

func _is_supported_schema(s: String) -> bool:
	return s == "beatmap_analyzer_v3" or s == "beatmap_analyzer_v2"

func _sort_onsets_by_t(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("t_ms", 0)) < int(b.get("t_ms", 0))
	
func _sort_autofinish_candidate(a: Dictionary, b: Dictionary) -> bool:
	var ta: float = float(a.get("t", 0.0))
	var tb: float = float(b.get("t", 0.0))
	if ta == tb:
		return int(a.get("lane", 0)) < int(b.get("lane", 0))
	return ta < tb

func _sort_map_note_by_t(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("t", 0.0)) < float(b.get("t", 0.0))

func _role_class_fallback(basis: String, band: String) -> String:
	# Older analyses (schema v2) have no role_class, so derive one from
	# whatever they do carry rather than dropping the note on the floor.
	var bs: String = basis.to_lower()
	if bs.begins_with("kick") or bs.begins_with("gated") or bs == "hat":
		return "beat"
	if bs.begins_with("screech") or bs.begins_with("lead"):
		return "melody"
	var bd: String = band.to_lower()
	if bd == "mid":
		return "melody"
	return "beat"

func _autofinish_lane_for_onset_band(band: String) -> int:
	var b: String = band.to_lower()
	if lane_count <= 1:
		return 0
	match b:
		"low":
			return 0
		"mid":
			return clamp(1, 0, lane_count - 1)
		"high":
			return clamp(2, 0, lane_count - 1)
		_:
			return lane_count - 1

func _autofinish_add_event_from_candidate(
	c: Dictionary,
	used_lane_ms: Dictionary,
	last_lane_t: Array[float],
	min_sep_s: float
) -> bool:
	var lane: int = int(c.get("lane", 0))
	if lane < 0 or lane >= lane_count:
		return false

	var t: float = float(c.get("t", 0.0))
	if t < 0.0:
		return false

	var ms: int = int(round(t * 1000.0))
	var key: String = "%d:%d" % [lane, ms]
	if used_lane_ms.has(key):
		return false

	var last_t: float = last_lane_t[lane]
	if last_t > -1e8 and (t - last_t) < min_sep_s:
		return false

	var src: String = String(c.get("src", "auto"))
	var meta: Dictionary = c.get("meta", {}) as Dictionary

	var e: Dictionary = _make_event(lane, t, "lane", 0.10)
	e["category"] = "generic"
	e["role"] = "generic"
	e["src"] = src
	e.merge(meta, true)

	events.append(e)

	used_lane_ms[key] = true
	last_lane_t[lane] = t
	return true

# ============================================================
# Refine mode helpers
# ============================================================

func _refine_class_of(e: Dictionary) -> String:
	# capture_pass is authoritative because it is what the game routes on.
	var cp: String = String(e.get("capture_pass", ""))
	if cp == "beats":
		return "beat"
	if cp == "melody" or cp == "fx":
		return "melody"
	var rc: String = String(e.get("role_class", ""))
	if rc == "beat" or rc == "melody":
		return rc
	return "melody" if int(e.get("lane", 0)) == 1 else "beat"

func _refine_period() -> float:
	var b: float = _json_num(analysis_data.get("bpm", null))
	return 60.0 / b if b > 20.0 else 0.4

func _refine_sorted_onsets(band: String) -> Array[float]:
	var out: Array[float] = []
	for o in analysis_onsets:
		if String(o.get("band", "")) == band:
			out.append(float(o.get("t_ms", 0)) / 1000.0)
	out.sort()
	return out

func _refine_beat_grid() -> Array[float]:
	var out: Array[float] = []
	for ms in analysis_beats_ms:
		out.append(float(ms) / 1000.0)
	out.sort()
	return out

func _refine_eighth_grid() -> Array[float]:
	# Melody sits on eighths in this game's charts, so a note with no mid onset
	# nearby still has a sensible place to land.
	var b: Array[float] = _refine_beat_grid()
	var out: Array[float] = []
	for i in range(b.size()):
		out.append(b[i])
		if i + 1 < b.size():
			out.append((b[i] + b[i + 1]) * 0.5)
	out.sort()
	return out

## Signed distance from t to the closest entry in a sorted list.
## Returns INF when the list is empty so callers can test with is_inf().
func _refine_signed_dev(sorted_t: Array[float], t: float) -> float:
	var n: int = sorted_t.size()
	if n == 0:
		return INF
	var lo: int = 0
	var hi: int = n - 1
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if sorted_t[mid] < t:
			lo = mid + 1
		else:
			hi = mid
	var best: float = sorted_t[lo] - t
	if lo > 0:
		var alt: float = sorted_t[lo - 1] - t
		if abs(alt) < abs(best):
			best = alt
	return best

func _refine_median(vals: Array[float]) -> float:
	if vals.is_empty():
		return 0.0
	var v: Array[float] = vals.duplicate()
	v.sort()
	var n: int = v.size()
	if n % 2 == 1:
		return v[n / 2]
	return (v[n / 2 - 1] + v[n / 2]) * 0.5

## Reads the existing chart, two bars at a time, and records what the author
## did there. Everything the refine pass is allowed to change is gated on this:
## a window the author left empty stays empty, and rolls are only completed
## where the author already rolls.
func _refine_windows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var period: float = _refine_period()

	# Window edges come from bars when the analysis has them, so a window is
	# musically meaningful rather than an arbitrary slice of seconds.
	var edges: Array[float] = []
	if analysis_bars.size() >= 2:
		for i in range(0, analysis_bars.size(), 2):
			edges.append(float(analysis_bars[i].get("t", 0.0)))
		var last_bar: Dictionary = analysis_bars[analysis_bars.size() - 1]
		edges.append(float(last_bar.get("t_end", 0.0)))
	else:
		var span: float = period * 8.0
		var end_t: float = 0.0
		for e in events:
			end_t = maxf(end_t, float(e.get("t", 0.0)))
		var t: float = 0.0
		while t <= end_t + span:
			edges.append(t)
			t += span

	for i in range(edges.size() - 1):
		out.append({
			"t0": edges[i],
			"t1": edges[i + 1],
			"beat_t": [] as Array[float],
			"melody_t": [] as Array[float],
			"has_rolls": false,
			"beat_gap": period,
			"melody_gap": period * 0.5,
			"added": 0,
			"cap": 0,
		})
	if out.is_empty():
		return out

	# Bucket the existing notes.
	for e in events:
		var t: float = float(e.get("t", 0.0))
		var wi: int = _refine_window_index(out, t)
		if wi < 0:
			continue
		if _refine_class_of(e) == "beat":
			(out[wi]["beat_t"] as Array[float]).append(t)
		else:
			(out[wi]["melody_t"] as Array[float]).append(t)

	for w in out:
		var bt: Array[float] = w["beat_t"]
		var mt: Array[float] = w["melody_t"]
		bt.sort()
		mt.sort()

		# A window already using sub-beat spacing on the beat lane is one where
		# the author plays rolls; that is the only place we may complete them.
		var gaps_b: Array[float] = []
		for i in range(1, bt.size()):
			var g: float = bt[i] - bt[i - 1]
			gaps_b.append(g)
			if g < period * 0.72:
				w["has_rolls"] = true
		var gaps_m: Array[float] = []
		for i in range(1, mt.size()):
			gaps_m.append(mt[i] - mt[i - 1])

		w["beat_gap"] = _refine_median(gaps_b) if not gaps_b.is_empty() else period
		w["melody_gap"] = _refine_median(gaps_m) if not gaps_m.is_empty() else period * 0.5

		# A refine pass is meant to correct, not to re-chart. No window may grow
		# by more than a fifth of what the author already put there.
		w["cap"] = int(ceil(float(bt.size() + mt.size()) * 0.20))

	return out

func _refine_window_index(wins: Array[Dictionary], t: float) -> int:
	var lo: int = 0
	var hi: int = wins.size() - 1
	if hi < 0 or t < float(wins[0]["t0"]):
		return -1
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if float(wins[mid]["t0"]) <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo

## Refine an existing chart instead of appending a second one on top of it.
## Runs when AutoFinish is applied with "Clear existing events first" unchecked
## and the chart already has notes.
func _autofinish_refine() -> void:
	var period: float = _refine_period()
	if period <= 0.0:
		info.text = "Refine: analysis has no usable tempo."
		return

	var kick_on: Array[float] = _refine_sorted_onsets("kick")
	var mid_on: Array[float] = _refine_sorted_onsets("mid")
	var beat_grid: Array[float] = _refine_beat_grid()
	var eighth_grid: Array[float] = _refine_eighth_grid()
	if kick_on.is_empty() and beat_grid.is_empty():
		info.text = "Refine: analysis has no beats or onsets to align to."
		return

	_begin_action("AutoFinish (refine)")

	# ------------------------------------------------------------------
	# Stage 1 - strip the chart's systematic latency.
	#
	# Hand-tapped charts carry a constant offset (this one sat ~100 ms ahead of
	# the kick). That is wider than a safe per-note snap window, so correcting
	# it note by note would let each note reach past its own transient and grab
	# a neighbouring roll hit. Measuring it once and shifting everything
	# together cannot mis-assign anything, and it leaves only jitter behind.
	# ------------------------------------------------------------------
	# Measured against the BEAT GRID, not the onset pool. Onsets run about
	# 4-5 per second, so whatever the offset is there is always one nearby and
	# the systematic error averages away to nothing. The grid is sparse and
	# perfectly regular, so a constant lead or lag shows up in it cleanly.
	# Only beat-lane notes vote: the latency is a property of the capture, so
	# one clean estimate beats mixing in the denser melody lane.
	var devs: Array[float] = []
	var wide: float = period * 0.35
	for e in events:
		if _refine_class_of(e) != "beat":
			continue
		var d: float = _refine_signed_dev(beat_grid, float(e.get("t", 0.0)))
		if not is_inf(d) and absf(d) <= wide:
			devs.append(d)

	var global_shift: float = 0.0
	if autofinish_refine_align_true and devs.size() >= 8:
		global_shift = _refine_median(devs)
		if absf(global_shift) > 0.004:
			for e in events:
				e["t"] = maxf(0.0, float(e.get("t", 0.0)) + global_shift)
		else:
			global_shift = 0.0

	# ------------------------------------------------------------------
	# Stage 2 - snap out the residual jitter, one note at a time.
	# A real transient is preferred; the grid is the fallback. Anything further
	# away than the correction window is a deliberate placement, not an error,
	# so it is left exactly where the author put it.
	# ------------------------------------------------------------------
	var max_corr: float = float(autofinish_refine_max_ms) / 1000.0
	var moved: int = 0
	var move_sizes: Array[float] = []
	for e in events:
		var rc2: String = _refine_class_of(e)
		var t2: float = float(e.get("t", 0.0))
		var d2: float = _refine_signed_dev(kick_on if rc2 == "beat" else mid_on, t2)
		if is_inf(d2) or absf(d2) > max_corr:
			var dg: float = _refine_signed_dev(beat_grid if rc2 == "beat" else eighth_grid, t2)
			if not is_inf(dg) and absf(dg) <= max_corr:
				d2 = dg
			else:
				continue
		if absf(d2) < 0.0005:
			continue
		e["t"] = maxf(0.0, t2 + d2)
		move_sizes.append(absf(d2))
		moved += 1

	events.sort_custom(Callable(self, "_sort_autofinish_candidate"))

	# ------------------------------------------------------------------
	# Stage 3 - fill genuine holes, using the author's own density as the cap.
	# A candidate only lands if the window is one the author actually charted,
	# nothing of theirs is already there, and it sits in a gap noticeably wider
	# than their own spacing in that window. Windows left deliberately empty
	# stay empty.
	# ------------------------------------------------------------------
	var wins: Array[Dictionary] = _refine_windows()
	var merge_w: float = maxf(0.045, float(autofinish_lane_min_sep_ms) / 1000.0 * 0.8)
	var added: int = 0

	if autofinish_refine_fill_gaps and not analysis_map_notes.is_empty() and not wins.is_empty():
		for n in analysis_map_notes:
			var t3: float = float(n.get("t", 0.0)) 
			var rc3: String = String(n.get("role_class", ""))
			if rc3 == "":
				rc3 = _role_class_fallback(String(n.get("basis", "")), String(n.get("band", "")))
			var wi: int = _refine_window_index(wins, t3)
			if wi < 0:
				continue
			var w: Dictionary = wins[wi]
			var existing: Array[float] = w["beat_t"] if rc3 == "beat" else w["melody_t"]
			if existing.is_empty():
				continue  # the author left this window silent on purpose
			var typical: float = float(w["beat_gap"] if rc3 == "beat" else w["melody_gap"])
			var dv: float = _refine_signed_dev(existing, t3)
			if is_inf(dv) or absf(dv) < merge_w:
				continue  # already covered
			if absf(dv) < typical * 1.15:
				continue  # not a hole -- just normal spacing for this window
			if int(w["added"]) >= int(w["cap"]):
				continue
			if _refine_add_note(t3, rc3, n, existing):
				w["added"] = int(w["added"]) + 1
				added += 1

	# ------------------------------------------------------------------
	# Stage 4 - complete rolls, but only where the author already rolls.
	# The analyzer knows which bars are gated; the chart decides whether a roll
	# belongs there at all. That keeps double and triple kicks out of sections
	# the author deliberately kept simple.
	# ------------------------------------------------------------------
	var rolls_added: int = 0
	if autofinish_refine_complete_rolls and not wins.is_empty():
		for bar in analysis_bars:
			var tags: Array = bar.get("tags", []) as Array
			if not (tags.has("gated_kick") or tags.has("kick_roll")):
				continue
			var b0: float = float(bar.get("t", 0.0))
			var b1: float = float(bar.get("t_end", b0 + period * 4.0))
			var wi2: int = _refine_window_index(wins, b0)
			if wi2 < 0 or not bool(wins[wi2]["has_rolls"]):
				continue
			var bt2: Array[float] = wins[wi2]["beat_t"]
			if bt2.is_empty():
				continue
			for i in range(beat_grid.size()):
				var g0: float = beat_grid[i]
				if g0 < b0 or g0 >= b1 or i + 1 >= beat_grid.size():
					continue
				var g1: float = beat_grid[i + 1]

				# Only COMPLETE a roll the author already started in this very
				# beat. Unlocking rolls for a whole two-bar window let one hit
				# spawn a run of invented doubles everywhere else in it.
				var off_beat_here: int = 0
				for bt_t in bt2:
					if bt_t > g0 + period * 0.08 and bt_t < g1 - period * 0.08:
						off_beat_here += 1
				if off_beat_here < 1:
					continue
				if int(wins[wi2]["added"]) >= int(wins[wi2]["cap"]):
					continue

				# Match the subdivision the author is already using here.
				var d: int = 4 if off_beat_here >= 2 else 2
				var step: float = (g1 - g0) / float(d)
				for k in range(1, d):
					var st: float = g0 + step * float(k)
					# only where a real kick transient backs it up
					var dk: float = _refine_signed_dev(kick_on, st)
					if is_inf(dk) or absf(dk) > period * 0.10:
						continue
					var dex: float = _refine_signed_dev(bt2, st)
					if is_inf(dex) or absf(dex) < merge_w:
						continue
					if int(wins[wi2]["added"]) >= int(wins[wi2]["cap"]):
						break
					if _refine_add_note(st + dk, "beat", {"basis": "gated_kick", "band": "kick", "div": d}, bt2):
						wins[wi2]["added"] = int(wins[wi2]["added"]) + 1
						rolls_added += 1

	_events_dirty = true
	_commit_action()

	var med_move: float = _refine_median(move_sizes) * 1000.0
	print("[RefineDBG] shift=%.1fms moved=%d (median %.0fms) filled=%d rolls=%d total=%d"
		% [global_shift * 1000.0, moved, med_move, added, rolls_added, events.size()])
	info.text = "Refine: latency %+.0fms removed | moved %d (med %.0fms) | filled %d | rolls +%d | %d notes" % [
		-global_shift * 1000.0, moved, med_move, added, rolls_added, events.size()
	]
	queue_redraw()

## Inserts one refined note and keeps the window's bookkeeping in step, so
## later candidates see it and don't stack on top of it.
func _refine_add_note(t: float, rc: String, meta: Dictionary, window_list: Array[float]) -> bool:
	if t < 0.0:
		return false
	var lane: int = int(ROLE_CLASS_LANE.get(rc, 0))
	lane = clampi(lane, 0, lane_count - 1)

	var e: Dictionary = _make_event(lane, t, "lane", 0.10)
	e["category"] = "generic"
	e["role"] = "generic"
	e["src"] = "refine"
	e["role_class"] = rc
	e["capture_pass"] = ROLE_CLASS_PASS.get(rc, "beats")
	e["basis"] = String(meta.get("basis", "kick"))
	e["band"] = String(meta.get("band", "kick"))
	e["div"] = int(meta.get("div", 1))
	if meta.has("section"):
		e["section"] = String(meta.get("section", ""))
	if meta.has("intensity"):
		e["intensity"] = float(meta.get("intensity", 0.5))

	events.append(e)
	window_list.append(t)
	window_list.sort()
	return true

func _autofinish(clear_first: bool) -> void:
	if analysis_data.is_empty():
		info.text = "AutoFinish: load analysis first (F12)."
		return
	if song_player.stream == null:
		info.text = "AutoFinish: load a song first."
		return

	# With "clear" unchecked on a chart that already has notes, the useful job
	# is correcting what is there -- not stacking a second chart on top of it.
	if not clear_first and not events.is_empty():
		_autofinish_refine()
		return

	var mode_label: String = "replace" if clear_first else "append"
	_begin_action("AutoFinish (%s)" % mode_label)

	if clear_first:
		events.clear()
		_clear_selection()
		_events_dirty = true
		_next_event_id = 1

	# ============================================================
	# ✅ MapGen path (preferred)
	# ============================================================
	if autofinish_use_mapgen:
		if analysis_map_notes.is_empty():
			_commit_action()
			info.text = "AutoFinish: no map_notes in the analysis. Re-run Analyze (F12) with MapGen enabled."
			return

		var min_sep_s: float = float(autofinish_lane_min_sep_ms) / 1000.0
		var corr_s: float = _json_num(analysis_data.get("offset_correction_s", null))
		var snap_ms: int = 18

		var used_lane_ms: Dictionary = {}
		var last_lane_t: Array[float] = []
		last_lane_t.resize(lane_count)
		for i in range(lane_count):
			last_lane_t[i] = -1e9

		var placed_lane_counts: Array[int] = []
		placed_lane_counts.resize(lane_count)
		for i in range(lane_count):
			placed_lane_counts[i] = 0

		var class_counts: Dictionary = {}
		var added: int = 0
		var snapped: int = 0
		var skip_lane: int = 0
		var no_class: int = 0

		# Sort by time so the per-lane separation check sees notes in order.
		var ordered: Array[Dictionary] = analysis_map_notes.duplicate()
		ordered.sort_custom(Callable(self, "_sort_map_note_by_t"))

		for n in ordered:
			# The analyzer already decided what each note IS. In two-lane mode
			# that decision is the lane, so there is nothing left to configure:
			# beats go left, melody goes right.
			var rc: String = String(n.get("role_class", ""))
			if rc == "":
				rc = _role_class_fallback(String(n.get("basis", "")), String(n.get("band", "")))
				no_class += 1

			var lane2: int
			if autofinish_two_lane:
				lane2 = int(ROLE_CLASS_LANE.get(rc, 0))
			else:
				lane2 = int(n.get("lane", 0))
			if lane2 < 0 or lane2 >= lane_count:
				lane2 = clamp(lane2, 0, lane_count - 1)

			var t_raw2: float = float(n.get("t", 0.0)) + corr_s

			# optional micro-snap to detected beats
			if analysis_beats_ms.size() > 0 and snap_ms > 0:
				var ms_raw: int = int(round(t_raw2 * 1000.0))
				var ms_snap: int = _snap_ms_to_list(ms_raw, analysis_beats_ms, snap_ms)
				if ms_snap != ms_raw:
					t_raw2 = float(ms_snap) / 1000.0
					snapped += 1

			var t_place: float = _q(t_raw2) if autofinish_apply_quantize else t_raw2
			if t_place < 0.0:
				continue

			var ms: int = int(round(t_place * 1000.0))
			var key: String = "%d:%d" % [lane2, ms]
			if used_lane_ms.has(key):
				continue

			if last_lane_t[lane2] > -1e8 and (t_place - last_lane_t[lane2]) < min_sep_s:
				skip_lane += 1
				continue

			var e: Dictionary = _make_event(lane2, t_place, "lane", 0.10)
			e["category"] = "generic"
			e["role"] = "generic"
			e["src"] = "mapgen"

			# IMPORTANT: don't let meta overwrite lane/t
			var meta: Dictionary = n.duplicate(true)
			meta.erase("lane")
			meta.erase("t")
			meta.erase("t_ms")
			e.merge(meta, true)

			# role_class drives both the lane and the note colour, so make sure
			# it survives the merge even for legacy notes that lacked one.
			e["role_class"] = rc

			# capture_pass is what the RUNTIME routes on: Section_BeatRunner3d
			# sends "beats" to gameplay and "melody"/"fx" to world FX, and
			# silently drops anything else. Without it an analyzer chart loads
			# as a completely empty level, so it is written for every note.
			e["capture_pass"] = ROLE_CLASS_PASS.get(rc, "beats")

			e["lane"] = lane2
			e["t"] = t_place

			events.append(e)
			used_lane_ms[key] = true
			last_lane_t[lane2] = t_place
			placed_lane_counts[lane2] += 1
			class_counts[rc] = int(class_counts.get(rc, 0)) + 1
			added += 1

		_events_dirty = true
		_commit_action()

		print("[AutoFinishDBG] mapgen placed=%d two_lane=%s lanes=%s classes=%s corr=%.3fs snapped=%d skip_lane=%d inferred_class=%d"
			% [added, str(autofinish_two_lane), str(placed_lane_counts), str(class_counts), corr_s, snapped, skip_lane, no_class])

		var beats_n: int = int(class_counts.get("beat", 0))
		var mel_n: int = int(class_counts.get("melody", 0))
		if autofinish_two_lane:
			info.text = "AutoFinish (%s): +%d — lane 0 beats %d (pink), lane 1 melody %d (blue)" % [
				mode_label, added, beats_n, mel_n
			]
		else:
			info.text = "AutoFinish (%s): +%d | lanes=%s | beats %d / melody %d" % [
				mode_label, added, str(placed_lane_counts), beats_n, mel_n
			]
		queue_redraw()
		return
	# ============================================================
	# Legacy beats/downbeats/onsets path (your existing behavior)
	# ============================================================

	if autofinish_lane_map.size() != lane_count:
		autofinish_lane_map.clear()
		for i in range(lane_count):
			autofinish_lane_map.append("beats")

	var lanes_beats: Array[int] = []
	var lanes_down: Array[int] = []
	var lanes_on: Array[int] = []

	for ln in range(lane_count):
		var src: String = String(autofinish_lane_map[ln])
		match src:
			"beats":
				lanes_beats.append(ln)
			"downbeats":
				lanes_down.append(ln)
			"onsets":
				lanes_on.append(ln)
			_:
				pass

	if autofinish_include_beats and lanes_beats.is_empty():
		_commit_action()
		info.text = "AutoFinish: Beats enabled but no lanes are set to 'beats'."
		return
	if autofinish_include_downbeats and lanes_down.is_empty():
		_commit_action()
		info.text = "AutoFinish: Downbeats enabled but no lanes are set to 'downbeats'."
		return
	if autofinish_include_onsets and lanes_on.is_empty():
		_commit_action()
		info.text = "AutoFinish: Onsets enabled but no lanes are set to 'onsets'."
		return

	var candidates2: Array[Dictionary] = []
	var beat_every: int = max(1, autofinish_beats_every)

	if autofinish_include_beats and analysis_beats_ms.size() > 0:
		var bi: int = 0
		for ms_any in analysis_beats_ms:
			var ms: int = int(ms_any)
			if (bi % beat_every) != 0:
				bi += 1
				continue
			if lanes_beats.is_empty():
				break
			var lane: int = lanes_beats[bi % lanes_beats.size()]
			candidates2.append({
				"t": float(ms) / 1000.0,
				"lane": lane,
				"src": "beat",
				"meta": {"auto_kind":"beat", "t_ms": ms}
			})
			bi += 1

	if autofinish_include_downbeats and analysis_downbeats_ms.size() > 0:
		var di: int = 0
		for msd_any in analysis_downbeats_ms:
			if lanes_down.is_empty():
				break
			var msd: int = int(msd_any)
			var lane_d: int = lanes_down[di % lanes_down.size()]
			candidates2.append({
				"t": float(msd) / 1000.0,
				"lane": lane_d,
				"src": "downbeat",
				"meta": {"auto_kind":"downbeat", "t_ms": msd}
			})
			di += 1

	if autofinish_include_onsets and analysis_onsets.size() > 0:
		for o in analysis_onsets:
			var oms: int = int(o.get("t_ms", 0))
			var strength: float = float(o.get("strength", 0.0))
			if strength < autofinish_onset_strength_min:
				continue

			if analysis_beats_ms.size() > 0 and autofinish_onset_avoid_near_beat_ms > 0:
				var snapped_ms: int = _snap_ms_to_list(oms, analysis_beats_ms, autofinish_onset_avoid_near_beat_ms)
				if snapped_ms != oms:
					continue

			var lane_o: int
			if lanes_on.size() == 1:
				lane_o = lanes_on[0]
			else:
				var band: String = String(o.get("band", "full")).to_lower()
				if band == "low":
					lane_o = lanes_on[0]
				elif band == "high":
					lane_o = lanes_on[lanes_on.size() - 1]
				else:
					lane_o = lanes_on[int(floor(float(lanes_on.size()) * 0.5))]

			candidates2.append({
				"t": float(oms) / 1000.0,
				"lane": lane_o,
				"src": "onset",
				"meta": {
					"auto_kind":"onset",
					"t_ms": oms,
					"strength": strength,
					"band": String(o.get("band",""))
				}
			})

	if candidates2.is_empty():
		_commit_action()
		info.text = "AutoFinish: nothing to place."
		return

	candidates2.sort_custom(Callable(self, "_sort_autofinish_candidate"))

	var used_lane_ms2: Dictionary = {}
	var last_lane_t2: Array[float] = []
	last_lane_t2.resize(lane_count)
	for i in range(lane_count):
		last_lane_t2[i] = -1e9

	var min_sep_s2: float = float(autofinish_lane_min_sep_ms) / 1000.0
	var added2: int = 0

	for c in candidates2:
		var lane3: int = int(c.get("lane", 0))
		var t_raw2: float = float(c.get("t", 0.0))
		var t_place2: float = _q(t_raw2) if autofinish_apply_quantize else t_raw2

		var ms2: int = int(round(t_place2 * 1000.0))
		var key2: String = "%d:%d" % [lane3, ms2]
		if used_lane_ms2.has(key2):
			continue
		if last_lane_t2[lane3] > -1e8 and (t_place2 - last_lane_t2[lane3]) < min_sep_s2:
			continue

		var e2: Dictionary = _make_event(lane3, t_place2, "lane", 0.10)
		e2["category"] = "generic"
		e2["role"] = "generic"
		e2["src"] = String(c.get("src","auto"))
		e2.merge(c.get("meta", {}) as Dictionary, true)

		events.append(e2)
		used_lane_ms2[key2] = true
		last_lane_t2[lane3] = t_place2
		added2 += 1

	_events_dirty = true
	_commit_action()
	info.text = "AutoFinish (%s): +%d" % [mode_label, added2]
	queue_redraw()

# ============================================================
# Assist helpers
# ============================================================

func _assist_list_ms() -> Array[int]:
	var out: Array[int] = []
	if assist_source == "onsets":
		for o in analysis_onsets:
			out.append(int(o.get("t_ms", 0)))
	else:
		out = analysis_beats_ms.duplicate()
	return out

func _assist_current_time_s() -> float:
	var arr: Array[int] = _assist_list_ms()
	if arr.is_empty():
		return -1.0
	assist_index = clamp(assist_index, 0, arr.size() - 1)
	return float(arr[assist_index]) / 1000.0

func _assist_step(dir: int) -> void:
	if analysis_data.is_empty():
		info.text = "Assist: load analysis first (F12)."
		return
	assist_enabled = true
	var arr: Array[int] = _assist_list_ms()
	if arr.is_empty():
		return
	assist_index = clamp(assist_index + dir, 0, arr.size() - 1)
	var t := _assist_current_time_s()
	if not song_player.playing or song_player.stream_paused:
		_seek_abs(t)
	info.text = "Assist %s %d/%d (%.3fs)" % [assist_source, assist_index+1, arr.size(), t]
	queue_redraw()

func _assist_toggle_source() -> void:
	if analysis_data.is_empty():
		return
	assist_source = "onsets" if assist_source == "beats" else "beats"
	assist_index = 0
	_seek_assist_to_time(_tbase())
	assist_enabled = true
	info.text = "Assist source: %s" % assist_source
	queue_redraw()

func _seek_assist_to_time(t_s: float) -> void:
	var arr := _assist_list_ms()
	if arr.is_empty():
		assist_index = 0
		return
	var ms := int(round(t_s * 1000.0))
	var i := _lower_bound_int(arr, ms)
	assist_index = clamp(i, 0, arr.size() - 1)

func _assist_place_at_current() -> void:
	var t := _assist_current_time_s()
	if t < 0.0:
		return
	if not _mouse_in_track:
		info.text = "Move mouse over track to pick lane."
		return
	_begin_action("Assist place")
	_place_at(_mouse_lane, t)
	_events_dirty = true
	_commit_action()
	_assist_step(1)

# ============================================================
# Map helpers
# ============================================================

func _place_at(lane: int, t: float) -> void:
	if lane < 0 or lane >= lane_count:
		return
	var tt: float = _q(t)
	events.append(_make_event(lane, tt, "lane", 0.10))
	_events_dirty = true

func _delete_nearest(lane: int, t: float, within_s: float) -> void:
	var id: int = _find_nearest_event_id(lane, t, within_s)
	if id <= 0:
		info.text = "Delete nearest: none."
		return

	var keep: Array[Dictionary] = []
	for e in events:
		if int(e.get("id", 0)) != id:
			keep.append(e)
	events = keep
	_events_dirty = true
	_set_selected(id, false)

func _find_nearest_event_id(lane: int, t: float, window: float) -> int:
	var best_id: int = -1
	var best_d: float = window
	for e in events:
		if int(e.get("lane", -1)) != lane:
			continue
		var typ: String = String(e.get("type","lane"))
		if typ != "lane" and typ != "hold":
			continue
		var et: float = float(e.get("t", 0.0))
		var d: float
		if typ == "hold":
			var dur: float = float(e.get("dur", 0.0))
			if t >= et and t <= et + dur:
				d = 0.0  # cursor is inside the hold body — perfect match
			else:
				d = minf(abs(et - t), abs(et + dur - t))
		else:
			d = abs(et - t)
		if d <= best_d:
			best_d = d
			best_id = int(e.get("id", 0))
	return best_id

func _find_match_for_tap(lane: int, now_t: float, window: float) -> int:
	var best_i: int = -1
	var best_d: float = window
	for i in range(events.size()):
		var e: Dictionary = events[i]
		if String(e.get("type","")) != "lane":
			continue
		if int(e.get("lane", -1)) != lane:
			continue
		var et: float = float(e.get("t", 0.0))
		var d: float = abs(et - now_t)
		if d <= best_d:
			best_d = d
			best_i = i
	return best_i

# ============================================================
# Drawing / geometry
# ============================================================

func _get_song_length() -> float:
	if song_player.stream != null and song_player.stream.has_method("get_length"):
		var L_v_any: Variant = song_player.stream.call("get_length")
		return float(L_v_any)

	var last_t: float = 0.0
	for e in events:
		var t0: float = float(e.get("t", 0.0))
		var d0: float = float(e.get("dur", 0.0))
		last_t = max(last_t, t0 + d0)
	return max(60.0, last_t + 5.0)

func _track_rect() -> Rect2:
	var w: float = size.x
	var h: float = size.y
	var bottom: float = h - (MINIMAP_H + MINIMAP_PAD * 2.0) if show_minimap else h
	return Rect2(0.0, 0.0, w, bottom)

func _minimap_rect() -> Rect2:
	var w: float = size.x
	var h: float = size.y
	var x0: float = MINIMAP_PAD
	var y0: float = h - MINIMAP_H - MINIMAP_PAD
	var ww: float = max(64.0, w - MINIMAP_PAD * 2.0)
	return Rect2(x0, y0, ww, MINIMAP_H)

func _time_from_y(y: float) -> float:
	var t_play: float = _tbase()
	var dt: float = (hit_y - y) / pps
	return t_play + dt

func _lane_from_x(x: float, track_r: Rect2) -> int:
	var lane_w: float = track_r.size.x / float(lane_count)
	var idx: int = int(floor((x - track_r.position.x) / lane_w))
	return clamp(idx, 0, lane_count - 1)

func _note_y_for_time(t_event: float, t_base: float) -> float:
	return hit_y - (t_event - t_base) * pps

func _visible_time_range(track_r: Rect2, tbase: float, margin_mult: float = 0.8) -> Array[float]:
	# top y -> future, bottom y -> past
	var y_top: float = track_r.position.y
	var y_bot: float = track_r.position.y + track_r.size.y

	# Use the passed-in base time (do NOT call _tbase() here)
	var t_top: float = tbase + (hit_y - y_top) / pps
	var t_bot: float = tbase + (hit_y - y_bot) / pps

	var t_min: float = min(t_top, t_bot)
	var t_max: float = max(t_top, t_bot)

	var margin: float = approach_time * margin_mult
	return [t_min - margin, t_max + margin]

# --- category/role visual helpers ---
func _cat_base(cat: String) -> Color:
	return CAT_BASE.get(cat, CAT_BASE["generic"])

func _pattern_spec(cat: String, role: String) -> Dictionary:
	if ROLE_PATTERNS.has(cat):
		var m: Dictionary = ROLE_PATTERNS[cat]
		if m.has(role):
			return m[role]
	return {"kind":"none"}

# --- line clipping (Liang–Barsky) ---
func _clip_test(p: float, q: float, t: Array) -> bool:
	var t0: float = float(t[0])
	var t1: float = float(t[1])
	if abs(p) < 0.0000001:
		return q >= 0.0
	var r: float = q / p
	if p < 0.0:
		if r > t1:
			return false
		if r > t0:
			t0 = r
	else:
		if r < t0:
			return false
		if r < t1:
			t1 = r
	t[0] = t0
	t[1] = t1
	return true

func _draw_line_clipped(rr: Rect2, a: Vector2, b: Vector2, col: Color, thickness: float) -> void:
	var t: Array = [0.0, 1.0]
	var x_min: float = rr.position.x
	var x_max: float = rr.position.x + rr.size.x
	var y_min: float = rr.position.y
	var y_max: float = rr.position.y + rr.size.y

	var dx: float = b.x - a.x
	var dy: float = b.y - a.y

	if not _clip_test(-dx, a.x - x_min, t): return
	if not _clip_test(dx,  x_max - a.x, t): return
	if not _clip_test(-dy, a.y - y_min, t): return
	if not _clip_test(dy,  y_max - a.y, t): return

	var t0: float = float(t[0])
	var t1: float = float(t[1])
	var p0: Vector2 = a + (b - a) * t0
	var p1: Vector2 = a + (b - a) * t1
	draw_line(p0, p1, col, thickness)

func _draw_role_pattern(rr: Rect2, cat: String, role: String) -> void:
	var spec: Dictionary = _pattern_spec(cat, role)
	var kind: String = String(spec.get("kind", "none"))
	if kind == "none":
		return

	# Zoomed out? skip patterns (perf + clarity)
	if approach_time > 2.2:
		return

	if rr.size.x < 10.0 or rr.size.y < 10.0:
		return

	var base: Color = _cat_base(cat)
	var overlay: Color = base.lightened(0.45)
	overlay.a = float(spec.get("alpha", 0.32))

	var step: float = float(spec.get("step", 12.0))
	var thickness: float = float(spec.get("thickness", 2.0))
	var radius: float = float(spec.get("radius", 2.0))

	match kind:
		"stripes":
			var w := rr.size.x
			var h := rr.size.y
			var start := rr.position
			var x := -h
			while x < w + h:
				var p0 := start + Vector2(x, 0.0)
				var p1 := start + Vector2(x + h, h)
				_draw_line_clipped(rr, p0, p1, overlay, thickness)
				x += step

		"dots":
			var x0 := rr.position.x + step * 0.5
			var y0 := rr.position.y + step * 0.5
			var x := x0
			while x < rr.position.x + rr.size.x - radius:
				var y := y0
				while y < rr.position.y + rr.size.y - radius:
					if x > rr.position.x + radius and y > rr.position.y + radius:
						draw_circle(Vector2(x, y), radius, overlay)
					y += step
				x += step

		"grid":
			var x := rr.position.x
			while x <= rr.position.x + rr.size.x:
				draw_line(Vector2(x, rr.position.y), Vector2(x, rr.position.y + rr.size.y), overlay, thickness)
				x += step
			var y := rr.position.y
			while y <= rr.position.y + rr.size.y:
				draw_line(Vector2(rr.position.x, y), Vector2(rr.position.x + rr.size.x, y), overlay, thickness)
				y += step

		"scan":
			var y := rr.position.y
			while y <= rr.position.y + rr.size.y:
				draw_line(Vector2(rr.position.x, y), Vector2(rr.position.x + rr.size.x, y), overlay, thickness)
				y += step

		"chevron":
			var w := rr.size.x
			var h := rr.size.y
			var midy := rr.position.y + h * 0.5
			var x := rr.position.x - step
			while x < rr.position.x + w + step:
				var a := Vector2(x, midy - h * 0.35)
				var b := Vector2(x + step * 0.5, midy + h * 0.35)
				var c := Vector2(x + step, midy - h * 0.35)
				_draw_line_clipped(rr, a, b, overlay, thickness)
				_draw_line_clipped(rr, b, c, overlay, thickness)
				x += step

		"cross":
			var w := rr.size.x
			var h := rr.size.y
			var start := rr.position

			var x := -h
			while x < w + h:
				_draw_line_clipped(rr, start + Vector2(x, 0.0), start + Vector2(x + h, h), overlay, thickness)
				x += step

			var x2 := 0.0
			while x2 < w + h:
				_draw_line_clipped(rr, start + Vector2(x2, 0.0), start + Vector2(x2 - h, h), overlay, thickness)
				x2 += step

func _color_for_event(e: Dictionary) -> Color:
	# Capture pass colors override normal category/lane coloring
	if String(e.get("src", "")) == "capture":
		var pass_id: String = String(e.get("capture_pass", ""))
		if CAPTURE_PASS_COLORS.has(pass_id):
			var pass_col: Color = CAPTURE_PASS_COLORS[pass_id]
			var lane: int = int(e.get("lane", 0))
			var lane_col: Color = LANE_COLS[clamp(lane, 0, LANE_COLS.size() - 1)]
			return pass_col.lerp(lane_col, 0.18)

	# Analyzer notes carry their own meaning, so colour by what the note IS
	# (beat or melody) rather than by which lane it happens to sit in.
	var rc: String = String(e.get("role_class", ""))
	if ROLE_CLASS_COLORS.has(rc):
		return ROLE_CLASS_COLORS[rc]

	var cat: String = String(e.get("category", "generic"))
	var fill: Color = _cat_base(cat)
	var lane2: int = int(e.get("lane", 0))
	var lane_col2: Color = LANE_COLS[clamp(lane2, 0, LANE_COLS.size() - 1)]
	return fill.lerp(lane_col2, 0.10)

func _border_color_for_event(e: Dictionary) -> Color:
	# Capture pass borders match their pass color a bit darker/stronger
	if String(e.get("src", "")) == "capture":
		var pass_id: String = String(e.get("capture_pass", ""))
		if CAPTURE_PASS_COLORS.has(pass_id):
			var b: Color = CAPTURE_PASS_COLORS[pass_id].darkened(0.18)
			b.a = 0.85
			return b

	var rc2: String = String(e.get("role_class", ""))
	if ROLE_CLASS_COLORS.has(rc2):
		var rb: Color = (ROLE_CLASS_COLORS[rc2] as Color).darkened(0.20)
		rb.a = 0.90
		return rb

	var cat: String = String(e.get("category","generic"))
	var c: Color = _cat_base(cat).darkened(0.15)
	c.a = float(CAT_BORDER_ALPHA.get(cat, 0.30))
	return c

func _sort_ev_by_t_then_lane(a: Dictionary, b: Dictionary) -> bool:
	var ta: float = float(a.get("t", 0.0))
	var tb: float = float(b.get("t", 0.0))
	if ta == tb:
		return int(a.get("lane", 0)) < int(b.get("lane", 0))
	return ta < tb

func _rebuild_sorted_cache_if_needed() -> void:
	if not _events_dirty:
		return
	_events_sorted = events.duplicate(false)
	_events_sorted.sort_custom(Callable(self, "_sort_ev_by_t_then_lane"))
	_events_dirty = false

func _lower_bound_event_time(arr: Array[Dictionary], t: float) -> int:
	var lo := 0
	var hi := arr.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		var mt := float(arr[mid].get("t", 0.0))
		if mt < t:
			lo = mid + 1
		else:
			hi = mid
	return lo

func _get_events_in_time_range(t_min: float, t_max: float) -> Array[Dictionary]:
	_rebuild_sorted_cache_if_needed()
	var out: Array[Dictionary] = []
	if _events_sorted.is_empty():
		return out
	var i0 := _lower_bound_event_time(_events_sorted, t_min)
	var i := i0
	while i < _events_sorted.size():
		var e := _events_sorted[i]
		var t0 := float(e.get("t", 0.0))
		if t0 > t_max:
			break
		out.append(e)
		i += 1
	return out

func _draw() -> void:
	var track_r: Rect2 = _track_rect()
	var lane_w: float = track_r.size.x / float(lane_count)
	var tbase: float = _tbase()

	# Lane dividers
	for ln in range(lane_count + 1):
		var lx: float = track_r.position.x + float(ln) * lane_w
		draw_line(Vector2(lx, track_r.position.y), Vector2(lx, track_r.position.y + track_r.size.y), Color(1,1,1,0.10), 1.0)

	# Analysis guides (beats / downbeats / onsets)
	if show_analysis_guides and analysis_beats_ms.size() > 0:
		_draw_analysis_guides(track_r, tbase)

	# Grid (bpm)
	if show_grid:
		if bpm_edit.text != "":
			bpm = float(bpm_edit.text)
		if offset_edit.text != "":
			offset_ms = int(offset_edit.text)

		var total: float = _get_song_length()
		var beat: float = beat_duration()
		var off_s: float = float(offset_ms) / 1000.0

		var start_t: float = max(0.0, tbase - 2.0 * approach_time)
		var end_t: float = min(total, tbase + 3.0 * approach_time)
		var i_beats: int = int(floor((start_t - off_s) / beat)) - 1
		var t_line: float = off_s + float(i_beats) * beat
		var bar_n: int = 0

		while t_line < end_t + 1e-6:
			if t_line >= start_t - 1e-6:
				var y_line: float = _note_y_for_time(t_line, tbase)
				var col: Color = GRID_MAIN if (bar_n % 4 == 0) else GRID_COL
				draw_line(Vector2(track_r.position.x, y_line), Vector2(track_r.position.x + track_r.size.x, y_line), col, 1.0)
			t_line += beat
			bar_n += 1

	# Draw visible events only (perf)
	var time_range: Array[float] = _visible_time_range(track_r, tbase, 1.0)
	var vis: Array[Dictionary] = _get_events_in_time_range(time_range[0], time_range[1])

	for e in vis:
		var lane: int = int(e.get("lane", 0))
		if lane < 0 or lane >= lane_count:
			continue

		var typ: String = String(e.get("type","lane"))
		var t0: float = float(e.get("t", 0.0))
		var col_n: Color = _color_for_event(e)
		var border: Color = _border_color_for_event(e)

		var x0: float = track_r.position.x + float(lane) * lane_w + NOTE_PAD_X
		var x1: float = track_r.position.x + float(lane + 1) * lane_w - NOTE_PAD_X
		var y0: float = _note_y_for_time(t0, tbase)

		if typ == "hold":
			var dur: float = float(e.get("dur", 0.0))
			var y1: float = _note_y_for_time(t0 + dur, tbase)
			var y_top: float = min(y0, y1)
			var hh: float = max(8.0, abs(y1 - y0))
			var rr: Rect2 = Rect2(Vector2(x0, y_top), Vector2(x1 - x0, hh))
			draw_rect(rr, col_n, true)
			_draw_role_pattern(rr, String(e.get("category","generic")), String(e.get("role","generic")))
			draw_rect(rr, border, false, 2.0)
		else:
			var rr2: Rect2 = Rect2(Vector2(x0, y0 - NOTE_H * 0.5), Vector2(x1 - x0, NOTE_H))
			draw_rect(rr2, col_n, true)
			_draw_role_pattern(rr2, String(e.get("category","generic")), String(e.get("role","generic")))
			draw_rect(rr2, border, false, 2.0)

		var id: int = int(e.get("id", 0))
		if _selected_set.has(id):
			var out_col: Color = Color(1, 1, 1, 0.95)
			if typ == "hold":
				var dur_s: float = float(e.get("dur", 0.0))
				var yy1: float = _note_y_for_time(t0 + dur_s, tbase)
				var y_top2: float = min(y0, yy1)
				var hh2: float = max(8.0, abs(yy1 - y0))
				draw_rect(Rect2(Vector2(x0-2, y_top2-2), Vector2((x1-x0)+4, hh2+4)), out_col, false, 2.0)
			else:
				draw_rect(Rect2(Vector2(x0-2, y0 - NOTE_H*0.5 - 2), Vector2((x1-x0)+4, NOTE_H+4)), out_col, false, 2.0)

	# Hit line
	draw_line(Vector2(track_r.position.x, hit_y), Vector2(track_r.position.x + track_r.size.x, hit_y), Color(0.95,0.95,1,0.95), 2.0)

	# Preview flashes
	var now_s: float = float(Time.get_ticks_msec()) / 1000.0
	for ln2 in range(lane_count):
		var lx2: float = track_r.position.x + float(ln2) * lane_w
		if _flash_ok_until[ln2] > now_s:
			draw_rect(Rect2(Vector2(lx2, hit_y - 18.0), Vector2(lane_w, 36.0)), HIT_OK, true)
		elif _flash_bad_until[ln2] > now_s:
			draw_rect(Rect2(Vector2(lx2, hit_y - 18.0), Vector2(lane_w, 36.0)), HIT_BAD, true)

	_draw_ghost_preview(track_r, lane_w, tbase)
	_draw_gamepad_cursor(track_r, lane_w, tbase)

	# Assist line
	if assist_enabled:
		var at := _assist_current_time_s()
		if at >= 0.0:
			var y_assist := _note_y_for_time(at, tbase)
			draw_line(Vector2(track_r.position.x, y_assist), Vector2(track_r.position.x + track_r.size.x, y_assist), Color(1,1,1,0.55), 1.5)

	if _marquee_active:
		var mr := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
		draw_rect(mr, Color(1,1,1,0.10), true)
		draw_rect(mr, Color(1,1,1,0.60), false, 1.5)

	if show_minimap:
		_draw_minimap()

func _draw_analysis_guides(track_r: Rect2, tbase: float) -> void:
	var time_range: Array[float] = _visible_time_range(track_r, tbase, 1.0)
	var t_min_s: float = time_range[0]
	var t_max_s: float = time_range[1]


	var ms_min: int = int(floor(t_min_s * 1000.0))
	var ms_max: int = int(ceil(t_max_s * 1000.0))

	# Beats
	var i0 := _lower_bound_int(analysis_beats_ms, ms_min)
	var i := i0
	while i < analysis_beats_ms.size():
		var ms := analysis_beats_ms[i]
		if ms > ms_max:
			break
		var t := float(ms) / 1000.0
		var y := _note_y_for_time(t, tbase)
		draw_line(Vector2(track_r.position.x, y), Vector2(track_r.position.x + track_r.size.x, y), Color(1,1,1,0.10), 1.0)
		i += 1

	# Downbeats (stronger)
	if analysis_downbeats_ms.size() > 0:
		var d0 := _lower_bound_int(analysis_downbeats_ms, ms_min)
		var d := d0
		while d < analysis_downbeats_ms.size():
			var msd := analysis_downbeats_ms[d]
			if msd > ms_max:
				break
			var td := float(msd) / 1000.0
			var yd := _note_y_for_time(td, tbase)
			draw_line(Vector2(track_r.position.x, yd), Vector2(track_r.position.x + track_r.size.x, yd), Color(1,1,1,0.25), 1.8)
			d += 1

	# Onsets (small right-edge ticks)
	if analysis_onsets.size() > 0:
		for o in analysis_onsets:
			var oms: int = int(o.get("t_ms", 0))
			if oms < ms_min or oms > ms_max:
				continue

			var ot: float = float(oms) / 1000.0
			var oy: float = _note_y_for_time(ot, tbase)

			var s: float = clampf(float(o.get("strength", 0.0)), 0.0, 1.0)
			var w: float = 6.0 + 14.0 * s

			draw_line(
			Vector2(track_r.position.x + track_r.size.x - w, oy),
			Vector2(track_r.position.x + track_r.size.x, oy),
			Color(1, 1, 1, 0.18),
			2.0
		)


func _draw_ghost_preview(track_r: Rect2, lane_w: float, tbase: float) -> void:
	if not _mouse_in_track:
		return
	if song_player.stream == null:
		return
	if _marquee_active or _move_active:
		return

	var lane: int = _mouse_lane
	var t0: float = _mouse_time
	var y0: float = _note_y_for_time(t0, tbase)

	var x0: float = track_r.position.x + float(lane) * lane_w + NOTE_PAD_X
	var x1: float = track_r.position.x + float(lane + 1) * lane_w - NOTE_PAD_X

	var base_fill: Color = _cat_base(current_category)
	var lane_col: Color = LANE_COLS[clamp(lane,0,LANE_COLS.size()-1)]
	var fill: Color = base_fill.lerp(lane_col, 0.10)
	fill.a = 0.22

	var outline: Color = base_fill.darkened(0.10)
	outline.a = 0.70

	var rr: Rect2 = Rect2(Vector2(x0, y0 - NOTE_H * 0.5), Vector2(x1 - x0, NOTE_H))
	draw_rect(rr, fill, true)
	_draw_role_pattern(rr, current_category, current_role)
	draw_rect(rr, outline, false, 2.0)

	draw_string(
		get_theme_default_font(),
		Vector2(x0 + 6, y0 - 10),
		"%s/%s" % [current_category, current_role],
		HORIZONTAL_ALIGNMENT_LEFT as HorizontalAlignment,
		-1,
		12,
		Color(1,1,1,0.85)
	)

func _draw_minimap() -> void:
	var r: Rect2 = _minimap_rect()
	draw_rect(r, Color(0,0,0,0.45), true)
	draw_rect(r, Color(1,1,1,0.20), false, 1.0)

	var total: float = _get_song_length()
	if total <= 0.01:
		return
	var px: float = r.size.x / total

	# Envelope overlays (RMS or onset env)
	if show_analysis_envelopes and analysis_rms_t_ms.size() > 1:
		_draw_minimap_envelope(r, px, analysis_rms_t_ms, analysis_rms_v, Color(1,1,1,0.18))
	if show_analysis_envelopes and analysis_onsetenv_t_ms.size() > 1:
		_draw_minimap_envelope(r, px, analysis_onsetenv_t_ms, analysis_onsetenv_v, Color(1,1,1,0.22))

	# Beat grid on minimap
	if show_grid:
		var off_s: float = float(offset_ms) / 1000.0
		var beat: float = beat_duration()
		var t: float = off_s
		var step_i: int = 0
		while t <= total + 1e-6:
			var x: float = r.position.x + t * px
			var col: Color = GRID_MAIN if (step_i % 4 == 0) else GRID_COL
			draw_line(Vector2(x, r.position.y + 2.0), Vector2(x, r.position.y + r.size.y - 2.0), col, 1.0)
			t += beat
			step_i += 1

	# Lanes separator
	var row_h: float = (r.size.y - 10.0) / float(lane_count)
	for ln in range(lane_count):
		var y: float = r.position.y + 5.0 + float(ln) * row_h
		draw_line(Vector2(r.position.x, y + row_h), Vector2(r.position.x + r.size.x, y + row_h), Color(1,1,1,0.10), 1.0)

	# Events as bars
	for e in events:
		var lane: int = int(e.get("lane", 0))
		if lane < 0 or lane >= lane_count:
			continue
		var cat: String = String(e.get("category","generic"))
		var col_e: Color = _cat_base(cat)
		col_e.a = 0.90

		var t0: float = float(e.get("t", 0.0))
		var x0: float = r.position.x + t0 * px
		var y0: float = r.position.y + 5.0 + float(lane) * row_h + 4.0

		if String(e.get("type","")) == "hold":
			var dur: float = float(e.get("dur", 0.0))
			var x1: float = r.position.x + (t0 + dur) * px
			draw_rect(Rect2(Vector2(min(x0, x1), y0), Vector2(abs(x1 - x0), row_h - 8.0)), col_e, true)
		else:
			draw_rect(Rect2(Vector2(x0 - 2.0, y0), Vector2(4.0, row_h - 8.0)), col_e, true)

	# Playhead
	var tplay: float = _tbase()
	var xp: float = r.position.x + clamp(tplay, 0.0, total) * px
	draw_line(Vector2(xp, r.position.y), Vector2(xp, r.position.y + r.size.y), Color(1,1,1,0.95), 2.0)

func _draw_minimap_envelope(r: Rect2, px: float, t_ms: Array[int], v: Array[float], col: Color) -> void:
	var n: int = int(min(t_ms.size(), v.size()))
	if n < 2:
		return

	# normalize values
	var vmax: float = 0.0001
	for i in range(n):
		vmax = max(vmax, v[i])

	var yb: float = r.position.y + r.size.y - 4.0
	var yt: float = r.position.y + 4.0

	var prev: Vector2 = Vector2.ZERO
	for i in range(n):
		var x: float = r.position.x + (float(t_ms[i]) / 1000.0) * px
		var vv: float = clampf(v[i] / vmax, 0.0, 1.0)
		var y: float = lerpf(yb, yt, vv)
		var p: Vector2 = Vector2(x, y)
		if i > 0:
			draw_line(prev, p, col, 1.0)
		prev = p


# ============================================================
# Preview toggle
# ============================================================

func _toggle_preview() -> void:
	preview_enabled = not preview_enabled
	info.text = "Preview: %s" % ("ON" if preview_enabled else "OFF")

# ============================================================
# Undo / Redo system
# ============================================================

func _snapshot() -> Dictionary:
	return {
		"events": events.duplicate(true),
		"selected_ids": selected_ids.duplicate(),
		"lane_schema": lane_schema.duplicate(true),
		"next_id": _next_event_id,
		"beatmap_key": beatmap_key,
		"analysis_path": analysis_path,
	}

func _apply_snapshot(snap: Dictionary, restore_selection: bool = true) -> void:
	events = _variant_array_to_dict_array(snap.get("events", []))
	var ls_candidate: Array[Dictionary] = _variant_array_to_dict_array(snap.get("lane_schema", lane_schema))
	if ls_candidate.size() == lane_count:
		lane_schema = ls_candidate

	_next_event_id = int(snap.get("next_id", _next_event_id))
	beatmap_key = String(snap.get("beatmap_key", beatmap_key))
	analysis_path = String(snap.get("analysis_path", analysis_path))

	_ensure_event_ids_and_fields()

	_selected_set.clear()
	selected_ids.clear()
	if restore_selection:
		var sel: Variant = snap.get("selected_ids", [])
		if sel is Array:
			for id in (sel as Array):
				_set_selected(int(id), true)

	_events_dirty = true

func _begin_action(action_name: String, before_override: Dictionary = {}) -> void:
	var before: Dictionary = before_override if not before_override.is_empty() else _snapshot()
	_action_temp = {"name": action_name, "before": before}

func _commit_action() -> void:
	if _action_temp.is_empty():
		return
	var after: Dictionary = _snapshot()
	var cmd: Dictionary = {
		"name": String(_action_temp.get("name","Action")),
		"before": _action_temp.get("before", {}),
		"after": after,
	}
	_undo_stack.append(cmd)
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_action_temp = {}
	_events_dirty = true

func _undo() -> void:
	if _undo_stack.is_empty():
		info.text = "Undo: nothing."
		return
	var cmd: Dictionary = _undo_stack.pop_back()
	_redo_stack.append(cmd)
	_apply_snapshot(cmd.get("before", {}))
	info.text = "Undo: %s" % String(cmd.get("name","Action"))

func _redo() -> void:
	if _redo_stack.is_empty():
		info.text = "Redo: nothing."
		return
	var cmd: Dictionary = _redo_stack.pop_back()
	_undo_stack.append(cmd)
	_apply_snapshot(cmd.get("after", {}))
	info.text = "Redo: %s" % String(cmd.get("name","Action"))

# ============================================================
# Lint / Validation
# ============================================================

func _open_lint_popup() -> void:
	if lint_popup == null:
		return
	_run_lint()
	lint_popup.popup_centered(Vector2(820, 560))

func _close_lint_popup() -> void:
	if lint_popup != null:
		lint_popup.hide()

func _run_lint() -> void:
	_ensure_event_ids_and_fields()

	var issues: Array[Dictionary] = []

	var last_t: float = -1.0
	for e in _get_events_in_time_range(-1e9, 1e9): # sorted by time
		var t0: float = float(e.get("t", 0.0))
		if t0 < last_t - 1e-6:
			issues.append({"sev":"warn","msg":"Events are not sorted by time. (Not fatal, but makes life harder.)"})
			break
		last_t = t0

	for e in events:
		var cat: String = String(e.get("category","generic"))
		var role: String = String(e.get("role","generic"))
		var typ: String = String(e.get("type","lane"))
		var lane: int = int(e.get("lane", 0))

		if not CATEGORY_LIST.has(cat):
			issues.append({"sev":"err","msg":"Invalid category '%s' on event id=%d" % [cat, int(e.get("id",0))]})
		else:
			var roles: Array = ROLES_BY_CATEGORY.get(cat, [])
			if roles.size() > 0 and not roles.has(role):
				issues.append({"sev":"warn","msg":"Role '%s' not valid for category '%s' (id=%d)" % [role, cat, int(e.get("id",0))]})

		if typ != "lane" and typ != "hold":
			issues.append({"sev":"warn","msg":"Unknown type '%s' (id=%d)" % [typ, int(e.get("id",0))]})

		if lane < 0 or lane >= lane_count:
			issues.append({"sev":"err","msg":"Lane out of range (%d) id=%d" % [lane, int(e.get("id",0))]})

	for ln in range(lane_count):
		var ts: Array[float] = []
		for e in events:
			if int(e.get("lane", -1)) == ln and String(e.get("type","lane")) == "lane":
				ts.append(float(e.get("t", 0.0)))
		ts.sort()
		for i in range(1, ts.size()):
			var d: float = ts[i] - ts[i-1]
			if d < lint_min_sep_s:
				issues.append({"sev":"warn","msg":"Lane %d has taps too close: %.3fs apart (< %.3fs)." % [ln, d, lint_min_sep_s]})
				break

	for e in events:
		var lane: int = int(e.get("lane", 0))
		if lane < 0 or lane >= lane_schema.size():
			continue
		var sch: Dictionary = lane_schema[lane]
		var need_cat: String = String(sch.get("category","any"))
		var need_role: String = String(sch.get("role","any"))
		var cat: String = String(e.get("category","generic"))
		var role: String = String(e.get("role","generic"))
		var id: int = int(e.get("id",0))

		if need_cat != "any" and cat != need_cat:
			issues.append({"sev":"warn","msg":"Lane %d expects category '%s' but event id=%d is '%s'." % [lane, need_cat, id, cat]})
		if need_role != "any" and role != need_role:
			issues.append({"sev":"warn","msg":"Lane %d expects role '%s' but event id=%d is '%s'." % [lane, need_role, id, role]})

	if lint_results == null:
		return
	lint_results.clear()
	lint_results.append_text("Events: %d | Selected: %d\n" % [events.size(), _selection_count()])
	lint_results.append_text("Min tap spacing threshold: %.3fs\n\n" % lint_min_sep_s)

	if issues.is_empty():
		lint_results.append_text("[color=lightgreen]No issues found. Your map is suspiciously well-behaved.[/color]\n")
	else:
		for it in issues:
			var sev: String = String(it.get("sev","warn"))
			var msg: String = String(it.get("msg",""))
			var c: String = "khaki"
			if sev == "err":
				c = "tomato"
			elif sev == "warn":
				c = "khaki"
			lint_results.append_text("[color=%s]• %s[/color]\n" % [c, msg])

func _fix_sort_by_time() -> void:
	if events.size() <= 1:
		return
	_begin_action("Sort events")
	events.sort_custom(Callable(self, "_sort_ev_by_t_then_lane"))
	_events_dirty = true
	_commit_action()
	_run_lint()
	info.text = "Sorted events by time."

func _fix_normalize_fields() -> void:
	_begin_action("Normalize fields")
	_ensure_event_ids_and_fields()
	_commit_action()
	_run_lint()
	info.text = "Normalized event fields."

# ============================================================
# Lane schema popup
# ============================================================

func _open_schema_popup() -> void:
	if schema_popup == null:
		return

	for i in range(lane_count):
		var sch: Dictionary = lane_schema[i]
		var cat: String = String(sch.get("category","any"))
		var role: String = String(sch.get("role","any"))
		var label: String = String(sch.get("label","Lane %d" % i))
		var comment: String = String(sch.get("comment",""))

		_select_option_button_by_text(_schema_cat_opts[i], cat)
		_refresh_schema_role_options(i, cat, role)

		_schema_label_edits[i].text = label
		_schema_comment_edits[i].text = comment

	schema_popup.popup_centered(Vector2(760, 420))

func _close_schema_popup() -> void:
	if schema_popup != null:
		schema_popup.hide()

func _on_schema_cat_changed(index: int, lane_i: int) -> void:
	var cat: String = _schema_cat_opts[lane_i].get_item_text(index)
	_refresh_schema_role_options(lane_i, cat, "any")

func _refresh_schema_role_options(lane_i: int, cat: String, desired: String) -> void:
	var ob: OptionButton = _schema_role_opts[lane_i]
	ob.clear()
	ob.add_item("any")

	if cat != "any":
		var roles: Array = ROLES_BY_CATEGORY.get(cat, [])
		for r in roles:
			ob.add_item(String(r))

	_select_option_button_by_text(ob, desired)

func _apply_schema_popup() -> void:
	_begin_action("Edit lane schema")

	for i in range(lane_count):
		var cat_opt: OptionButton = _schema_cat_opts[i]
		var role_opt: OptionButton = _schema_role_opts[i]

		var cat: String = cat_opt.get_item_text(cat_opt.selected)
		var role: String = role_opt.get_item_text(role_opt.selected)
		var label: String = _schema_label_edits[i].text.strip_edges()
		var comment: String = _schema_comment_edits[i].text.strip_edges()

		lane_schema[i] = {
			"category": cat,
			"role": role,
			"label": label if label != "" else ("Lane %d" % i),
			"comment": comment,
		}

	_commit_action()
	_close_schema_popup()
	info.text = "Lane schema updated."

# ============================================================
# Analysis popup
# ============================================================

func _open_analysis_popup() -> void:
	if analysis_popup == null:
		return
	_update_analysis_popup_text()
	analysis_popup.popup_centered(Vector2(820, 560))

func _close_analysis_popup() -> void:
	if analysis_popup != null:
		analysis_popup.hide()

func _update_analysis_popup_text() -> void:
	if analysis_label == null:
		return
	analysis_label.clear()

	if analysis_data.is_empty():
		analysis_label.append_text("[color=khaki]No analysis loaded.[/color]\n\n")
		analysis_label.append_text("Pleas Analyze or Import JSON.\n")
		return

	var schema: String = String(analysis_data.get("schema", ""))

	if _is_supported_schema(schema):
		var app: Dictionary = analysis_data.get("app", {}) as Dictionary
		if not app.is_empty():
			analysis_label.append_text("%s %s\n" % [String(app.get("name", "Beatmap Analyzer")), String(app.get("version", ""))])
		analysis_label.append_text("schema: %s\n" % schema)

		analysis_label.append_text("bpm: %.3f\n" % _json_num(analysis_data.get("bpm", null)))
		analysis_label.append_text("offset_correction_s: %.4f\n" % _json_num(analysis_data.get("offset_correction_s", null)))

		var backend: String = String(analysis_data.get("backend", ""))
		if backend != "":
			analysis_label.append_text("backend: %s\n" % backend)

		var elapsed: float = _json_num(analysis_data.get("elapsed_s", null))
		if elapsed > 0.0:
			analysis_label.append_text("elapsed_s: %.2f\n" % elapsed)

		var ap: String = String(analysis_data.get("audio", ""))
		if ap != "":
			analysis_label.append_text("audio: %s\n" % ap.get_file())

		var notes: String = String(analysis_data.get("notes", ""))
		if notes != "":
			analysis_label.append_text("notes: %s\n" % notes)

		# --- fusion detail (v3) ---
		var ex: Dictionary = analysis_data.get("extra", {}) as Dictionary
		if not ex.is_empty():
			var au: Dictionary = ex.get("auto", {}) as Dictionary
			if not au.is_empty() and bool(au.get("applied", false)):
				var win: Array = au.get("bpm_window", []) as Array
				if win.size() == 2:
					analysis_label.append_text("[color=lightgreen]auto settings:[/color] tempo window %.1f-%.1f BPM, snap %.1f ms\n" % [
						_json_num(win[0]), _json_num(win[1]), _json_num(au.get("snap_window_ms", null))])
				var bd: Dictionary = au.get("band_deltas", {}) as Dictionary
				if not bd.is_empty():
					var bp: Array[String] = []
					for bk in bd.keys():
						bp.append("%s %.3f" % [String(bk), float(bd[bk])])
					analysis_label.append_text("auto onset thresholds: %s\n" % ", ".join(bp))
			else:
				analysis_label.append_text("[color=khaki]auto settings: off (manual values used)[/color]\n")

			var tp: Dictionary = ex.get("tempo", {}) as Dictionary
			if not tp.is_empty():
				analysis_label.append_text("tempo lock: %.4f BPM via %s (strength %.4f)\n" % [
					_json_num(tp.get("bpm", null)), String(tp.get("source", "?")), _json_num(tp.get("strength", null))])

			var bnn: Dictionary = ex.get("beatnet", {}) as Dictionary
			if not bnn.is_empty():
				if bool(bnn.get("ok", false)):
					analysis_label.append_text("BeatNet: ok, %d beats, seed %.2f BPM\n" % [
						int(bnn.get("beats", 0)), _json_num(bnn.get("bpm", null))])
				else:
					analysis_label.append_text("[color=khaki]BeatNet: unavailable (librosa-only grid)[/color]\n")

			var gr: Dictionary = ex.get("grid", {}) as Dictionary
			if not gr.is_empty():
				analysis_label.append_text("grid: tightness %s, snapped %s, score %.3f\n" % [
					str(gr.get("chosen_tightness", 0)), str(gr.get("chosen_snapped", false)),
					_json_num(gr.get("chosen_score", null))])

			var roles: Dictionary = ex.get("onset_roles", {}) as Dictionary
			if not roles.is_empty():
				var parts: Array[String] = []
				for k in roles.keys():
					parts.append("%s %d" % [String(k), int(roles[k])])
				analysis_label.append_text("onset roles: %s\n" % ", ".join(parts))

			var secs: Dictionary = ex.get("section_counts", {}) as Dictionary
			if not secs.is_empty():
				var sp: Array[String] = []
				for k2 in secs.keys():
					sp.append("%s %d" % [String(k2), int(secs[k2])])
				analysis_label.append_text("sections: %s\n" % ", ".join(sp))

			analysis_label.append_text("frame resolution: %.2f ms\n" % _json_num(ex.get("resolution_ms", null)))

		if analysis_bars.size() > 0:
			analysis_label.append_text("bars: %d | map_notes: %d\n" % [analysis_bars.size(), analysis_map_notes.size()])
	else:
		var ver := int(analysis_data.get("analysis_version", 0))
		analysis_label.append_text("analysis_version: %d\n" % ver)

		var tempo: Dictionary = analysis_data.get("tempo", {}) as Dictionary
		if not tempo.is_empty():
			analysis_label.append_text("bpm: %.3f (conf %.2f)\n" % [float(tempo.get("bpm", 0.0)), float(tempo.get("confidence", 0.0))])
			analysis_label.append_text("bpm range: %.2f .. %.2f\n" % [float(tempo.get("bpm_min", 0.0)), float(tempo.get("bpm_max", 0.0))])

		var audio: Dictionary = analysis_data.get("audio", {}) as Dictionary
		if not audio.is_empty():
			analysis_label.append_text("duration_s: %.2f | sr: %d\n" % [float(audio.get("duration_s", 0.0)), int(audio.get("sr", 0))])

	analysis_label.append_text("\nbeats: %d | downbeats: %d | onsets: %d\n" % [analysis_beats_ms.size(), analysis_downbeats_ms.size(), analysis_onsets.size()])
	analysis_label.append_text("guides: %s | envelopes: %s | smart_quantize: %s\n" % [str(show_analysis_guides), str(show_analysis_envelopes), str(smart_quantize)])
	analysis_label.append_text("assist: %s (%s)\n" % [str(assist_enabled), assist_source])

	analysis_label.append_text("\nHotkeys:\n")
	analysis_label.append_text("  F10 toggles guides, Ctrl+F4 toggles smart quantize\n")
	analysis_label.append_text("  N/M step assist, G switcs assist source, Enheter places note at assist time\n")

# ============================================================
# Export compiled runtime format
# ============================================================

func _export_compiled() -> void:
	if beatmap_key == "":
		if path_edit.text.strip_edges() != "":
			beatmap_key = _beatmap_key_from_song_path(path_edit.text.strip_edges())
		else:
			beatmap_key = "beatmap"
	key_edit.text = beatmap_key

	_ensure_event_ids_and_fields()

	var cat_to_id: Dictionary = {}
	for i in range(CATEGORY_LIST.size()):
		cat_to_id[CATEGORY_LIST[i]] = i

	var role_to_id: Dictionary = {}
	var role_list: Array[String] = []
	var rid: int = 0
	for cat in CATEGORY_LIST:
		var roles: Array = ROLES_BY_CATEGORY.get(cat, [])
		for r in roles:
			var key: String = "%s:%s" % [cat, String(r)]
			if not role_to_id.has(key):
				role_to_id[key] = rid
				role_list.append(key)
				rid += 1

	var type_to_id := {"lane": 0, "hold": 1}

	var ev_comp: Array = []
	var sorted: Array = events.duplicate(false)
	sorted.sort_custom(Callable(self, "_sort_ev_by_t_then_lane"))

	for e in sorted:
		var t_ms: int = int(round(float(e.get("t", 0.0)) * 1000.0))
		var dur_ms: int = int(round(float(e.get("dur", 0.0)) * 1000.0))
		var lane: int = int(e.get("lane", 0))
		var typ: String = String(e.get("type","lane"))
		var cat: String = String(e.get("category","generic"))
		var role: String = String(e.get("role","generic"))
		var id: int = int(e.get("id", 0))

		var cat_id: int = int(cat_to_id.get(cat, 0))
		var role_key: String = "%s:%s" % [cat, role]
		var role_id: int = int(role_to_id.get(role_key, 0))
		var type_id: int = int(type_to_id.get(typ, 0))

		ev_comp.append([t_ms, lane, type_id, dur_ms, cat_id, role_id, id])

	var compiled: Dictionary = {
		"version": 1,
		"key": beatmap_key,
		"song_path": _normalize_song_path(path_edit.text),
		"analysis_path": analysis_path,
		"bpm": int(float(bpm_edit.text)),
		"offset_ms": int(offset_edit.text),
		"lane_schema": lane_schema,
		"rap_segments": rap_segments,
		"rap_taps": rap_taps,
		"lyrics": lyrics_data,
		"lyric_font": lyric_font_choice,
		"electric_zones": electric_zones,
		"lyrics_rap_words": _te_text(_rap_words_edit),
		"lyrics_sung_lines": _te_text(_sung_lines_edit),
		"drop_buildups": drop_buildups,
		"defs": {
			"categories": CATEGORY_LIST,
			"roles_by_category": ROLES_BY_CATEGORY,
			"role_keys": role_list,
			"type_ids": type_to_id,
			"format": "[t_ms,lane,type_id,dur_ms,cat_id,role_id,id]"
		},
		"events": ev_comp
	}

	var out_rel: String = "res://data/beatmaps_compiled/%s.compiled.json" % beatmap_key
	var f: FileAccess = FileAccess.open(out_rel, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(compiled, "	"))
		f.close()
		info.text = "Exported compiled → %s" % out_rel
	else:
		var out_alt: String = "user://%s.compiled.json" % beatmap_key
		var f2: FileAccess = FileAccess.open(out_alt, FileAccess.WRITE)
		if f2 != null:
			f2.store_string(JSON.stringify(compiled, "	"))
			f2.close()
			info.text = "Exported compiled → %s (fallback)" % out_alt
		else:
			info.text = "Export failed."

# ============================================================
# Misc
# ============================================================

func _convert_selected_to_capture_pass(pass_id: String) -> void:
	if selected_ids.is_empty():
		info.text = "Convert: select note(s) first."
		return

	if not CAPTURE_PASS_COLORS.has(pass_id):
		info.text = "Convert: invalid pass '%s'." % pass_id
		return

	_begin_action("Convert selection to %s" % pass_id)

	var changed: int = 0
	for e in events:
		var id: int = int(e.get("id", 0))
		if not _selected_set.has(id):
			continue

		e["src"] = "capture"
		e["capture_pass"] = pass_id
		e["auto_kind"] = pass_id

		# keep these generic unless you later want a separate gameplay category system
		e["category"] = "generic"
		e["role"] = "generic"

		changed += 1

	_events_dirty = true
	_commit_action()
	info.text = "Converted %d note(s) to %s." % [changed, pass_id]


func _convert_selected_to_generic() -> void:
	if selected_ids.is_empty():
		info.text = "Convert: select note(s) first."
		return

	_begin_action("Convert selection to generic")

	var changed: int = 0
	for e in events:
		var id: int = int(e.get("id", 0))
		if not _selected_set.has(id):
			continue

		e.erase("capture_pass")
		e.erase("auto_kind")

		# reset source so it stops using capture colors
		e["src"] = "manual"
		e["category"] = "generic"
		e["role"] = "generic"

		changed += 1

	_events_dirty = true
	_commit_action()
	info.text = "Converted %d note(s) to generic/manual." % changed

func _toggle_guides() -> void:
	show_analysis_guides = not show_analysis_guides
	show_analysis_envelopes = show_analysis_guides
	info.text = "Guides: %s" % ("ON" if show_analysis_guides else "OFF")
	queue_redraw()

func _gui_input(ev: InputEvent) -> void:
	var mm: InputEventMouseMotion = ev as InputEventMouseMotion
	if mm != null:
		_mouse_pos = mm.position
		_update_mouse_hover_state()

		if _scrub_active:
			_scrub_from_mouse(_mouse_pos)
			accept_event()
		elif _marquee_active:
			_marquee_end = _mouse_pos
			accept_event()
		elif _move_active:
			_move_selection_preview(_mouse_pos)
			accept_event()

		queue_redraw()
		return

	var mb: InputEventMouseButton = ev as InputEventMouseButton
	if mb == null:
		return

	_mouse_pos = mb.position
	_update_mouse_hover_state()

	if mb.pressed:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_handle_wheel(mb)
			accept_event()
			queue_redraw()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			_on_left_down(mb)
			accept_event()
			queue_redraw()
			return

		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_on_right_down(mb)
			accept_event()
			queue_redraw()
			return
	else:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_on_left_up(mb)
			accept_event()
			queue_redraw()
			return

# ============================================================
# Input map setup (full block, lint-clean enum casting)
# ============================================================

func _ensure_input_map() -> void:
	var base: Dictionary = {
		"lane_0": KEY_A,
		"lane_1": KEY_S,
		"lane_2": KEY_K,
		"lane_3": KEY_L
	}

	for a_key in base.keys():
		var action: String = String(a_key)
		if not InputMap.has_action(action):
			InputMap.add_action(action)

		var keycode: Key = base[a_key] as Key

		var evk := InputEventKey.new()
		evk.physical_keycode = keycode

		var exists := false
		for e_event in InputMap.action_get_events(action):
			var ek := e_event as InputEventKey
			if ek != null and ek.physical_keycode == keycode:
				exists = true
				break

		if not exists:
			InputMap.action_add_event(action, evk)

	# ----------------------------
	# Existing lane gamepad bindings
	# ----------------------------

	# lane_0 = LB
	var lb: InputEventJoypadButton = InputEventJoypadButton.new()
	var lb_btn: JoyButton = JOY_BUTTON_LEFT_SHOULDER as JoyButton
	lb.button_index = lb_btn
	_add_if_missing("lane_0", lb)

	# lane_3 = RB
	var rb: InputEventJoypadButton = InputEventJoypadButton.new()
	var rb_btn: JoyButton = JOY_BUTTON_RIGHT_SHOULDER as JoyButton
	rb.button_index = rb_btn
	_add_if_missing("lane_3", rb)

	# Make sure lane_1/2 are ONLY triggers
	_remove_motion("lane_1", (JOY_AXIS_TRIGGER_RIGHT as JoyAxis))
	_remove_motion("lane_2", (JOY_AXIS_TRIGGER_LEFT as JoyAxis))

	# lane_1 = LT
	var lt: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var lt_axis: JoyAxis = JOY_AXIS_TRIGGER_LEFT as JoyAxis
	lt.axis = lt_axis
	lt.axis_value = 1.0
	_add_if_missing("lane_1", lt)
	InputMap.action_set_deadzone("lane_1", JOY_DZ)

	# lane_2 = RT
	var rt: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var rt_axis: JoyAxis = JOY_AXIS_TRIGGER_RIGHT as JoyAxis
	rt.axis = rt_axis
	rt.axis_value = 1.0
	_add_if_missing("lane_2", rt)
	InputMap.action_set_deadzone("lane_2", JOY_DZ)

	# rhythm_pause = START
	if not InputMap.has_action("rhythm_pause"):
		InputMap.add_action("rhythm_pause")

	var start_btn: InputEventJoypadButton = InputEventJoypadButton.new()
	var start_jb: JoyButton = JOY_BUTTON_START as JoyButton
	start_btn.button_index = start_jb
	_add_if_missing("rhythm_pause", start_btn)

	# ----------------------------
	# Gamepad editor cursor actions
	# ----------------------------
	var editor_actions: Array[String] = [
		"editor_gp_lane_left",
		"editor_gp_lane_right",
		"editor_gp_time_forward",
		"editor_gp_time_back",
		"editor_gp_place",
		"editor_gp_select",
		"editor_gp_toggle_select",
		"editor_gp_delete",
		"editor_gp_clear_selection",
		"editor_gp_nudge_left",
		"editor_gp_nudge_right",
		"editor_gp_nudge_up",
		"editor_gp_nudge_down",
	]

	for action_name in editor_actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)

	# Cursor left = D-pad left + left stick left
	var dpad_left: InputEventJoypadButton = InputEventJoypadButton.new()
	var dpad_left_btn: JoyButton = JOY_BUTTON_DPAD_LEFT as JoyButton
	dpad_left.button_index = dpad_left_btn
	_add_if_missing("editor_gp_lane_left", dpad_left)

	var ls_left: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var ls_left_axis: JoyAxis = JOY_AXIS_LEFT_X as JoyAxis
	ls_left.axis = ls_left_axis
	ls_left.axis_value = -1.0
	_add_if_missing("editor_gp_lane_left", ls_left)
	InputMap.action_set_deadzone("editor_gp_lane_left", 0.65)

	# Cursor right = D-pad right + left stick right
	var dpad_right: InputEventJoypadButton = InputEventJoypadButton.new()
	var dpad_right_btn: JoyButton = JOY_BUTTON_DPAD_RIGHT as JoyButton
	dpad_right.button_index = dpad_right_btn
	_add_if_missing("editor_gp_lane_right", dpad_right)

	var ls_right: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var ls_right_axis: JoyAxis = JOY_AXIS_LEFT_X as JoyAxis
	ls_right.axis = ls_right_axis
	ls_right.axis_value = 1.0
	_add_if_missing("editor_gp_lane_right", ls_right)
	InputMap.action_set_deadzone("editor_gp_lane_right", 0.65)

	# Cursor time forward = D-pad up + left stick up
	var dpad_up: InputEventJoypadButton = InputEventJoypadButton.new()
	var dpad_up_btn: JoyButton = JOY_BUTTON_DPAD_UP as JoyButton
	dpad_up.button_index = dpad_up_btn
	_add_if_missing("editor_gp_time_forward", dpad_up)

	var ls_up: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var ls_up_axis: JoyAxis = JOY_AXIS_LEFT_Y as JoyAxis
	ls_up.axis = ls_up_axis
	ls_up.axis_value = -1.0
	_add_if_missing("editor_gp_time_forward", ls_up)
	InputMap.action_set_deadzone("editor_gp_time_forward", 0.65)

	# Cursor time back = D-pad down + left stick down
	var dpad_down: InputEventJoypadButton = InputEventJoypadButton.new()
	var dpad_down_btn: JoyButton = JOY_BUTTON_DPAD_DOWN as JoyButton
	dpad_down.button_index = dpad_down_btn
	_add_if_missing("editor_gp_time_back", dpad_down)

	var ls_down: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var ls_down_axis: JoyAxis = JOY_AXIS_LEFT_Y as JoyAxis
	ls_down.axis = ls_down_axis
	ls_down.axis_value = 1.0
	_add_if_missing("editor_gp_time_back", ls_down)
	InputMap.action_set_deadzone("editor_gp_time_back", 0.65)

	# A = place at cursor
	var btn_a: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_a_idx: JoyButton = JOY_BUTTON_A as JoyButton
	btn_a.button_index = btn_a_idx
	_add_if_missing("editor_gp_place", btn_a)

	# X = select nearest at cursor
	var btn_x: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_x_idx: JoyButton = JOY_BUTTON_X as JoyButton
	btn_x.button_index = btn_x_idx
	_add_if_missing("editor_gp_select", btn_x)

	# B = toggle select nearest at cursor
	var btn_b: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_b_idx: JoyButton = JOY_BUTTON_B as JoyButton
	btn_b.button_index = btn_b_idx
	_add_if_missing("editor_gp_toggle_select", btn_b)

	# Y = delete nearest note, or delete current selection
	var btn_y: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_y_idx: JoyButton = JOY_BUTTON_Y as JoyButton
	btn_y.button_index = btn_y_idx
	_add_if_missing("editor_gp_delete", btn_y)

	# Back + Left Stick Click = clear selection
	var btn_back: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_back_idx: JoyButton = JOY_BUTTON_BACK as JoyButton
	btn_back.button_index = btn_back_idx
	_add_if_missing("editor_gp_clear_selection", btn_back)

	var btn_ls_click: InputEventJoypadButton = InputEventJoypadButton.new()
	var btn_ls_click_idx: JoyButton = JOY_BUTTON_LEFT_STICK as JoyButton
	btn_ls_click.button_index = btn_ls_click_idx
	_add_if_missing("editor_gp_clear_selection", btn_ls_click)

	# Right stick = move selected notes
	var rs_left: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var rs_left_axis: JoyAxis = JOY_AXIS_RIGHT_X as JoyAxis
	rs_left.axis = rs_left_axis
	rs_left.axis_value = -1.0
	_add_if_missing("editor_gp_nudge_left", rs_left)
	InputMap.action_set_deadzone("editor_gp_nudge_left", 0.70)

	var rs_right: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var rs_right_axis: JoyAxis = JOY_AXIS_RIGHT_X as JoyAxis
	rs_right.axis = rs_right_axis
	rs_right.axis_value = 1.0
	_add_if_missing("editor_gp_nudge_right", rs_right)
	InputMap.action_set_deadzone("editor_gp_nudge_right", 0.70)

	var rs_up: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var rs_up_axis: JoyAxis = JOY_AXIS_RIGHT_Y as JoyAxis
	rs_up.axis = rs_up_axis
	rs_up.axis_value = -1.0
	_add_if_missing("editor_gp_nudge_up", rs_up)
	InputMap.action_set_deadzone("editor_gp_nudge_up", 0.70)

	var rs_down: InputEventJoypadMotion = InputEventJoypadMotion.new()
	var rs_down_axis: JoyAxis = JOY_AXIS_RIGHT_Y as JoyAxis
	rs_down.axis = rs_down_axis
	rs_down.axis_value = 1.0
	_add_if_missing("editor_gp_nudge_down", rs_down)
	InputMap.action_set_deadzone("editor_gp_nudge_down", 0.70)

func _add_if_missing(action: String, ev: InputEvent) -> void:
	for e_event in InputMap.action_get_events(action):
		var jb: InputEventJoypadButton = e_event as InputEventJoypadButton
		var jm: InputEventJoypadMotion = e_event as InputEventJoypadMotion

		if ev is InputEventJoypadButton and jb != null:
			var evb: InputEventJoypadButton = ev as InputEventJoypadButton
			if jb.button_index == evb.button_index:
				return

		if ev is InputEventJoypadMotion and jm != null:
			var evm: InputEventJoypadMotion = ev as InputEventJoypadMotion
			if jm.axis == evm.axis and abs(jm.axis_value - evm.axis_value) < 0.001:
				return

	InputMap.action_add_event(action, ev)


# FIX: axis_idx is a JoyAxis (not int) so comparisons are enum-clean
func _remove_motion(action: String, axis_idx: JoyAxis) -> void:
	var to_remove: Array[InputEvent] = []
	for e_event in InputMap.action_get_events(action):
		var jm: InputEventJoypadMotion = e_event as InputEventJoypadMotion
		if jm != null and jm.axis == axis_idx:
			to_remove.append(e_event)

	for e_event in to_remove:
		InputMap.action_erase_event(action, e_event)
