extends Node3D

@export_file("*.json") var beatmap_json_path: String = ""
@export var song_stream: AudioStream

@export var judge_window_s: float = 0.16
@export var gate_depth: float = 1.1
@export var lane_blocker_width: float = 1.7
@export var lane_blocker_height: float = 2.5

# Wall-jump climb: number of jumps (= rainbow ledges). Editable in the Inspector. Drives
# BOTH the scored wall gates (_gen_wall_jump) and the geometry slots
# (_spawn_wj_geometry_on_path). An authored wj_kit asset is measured and FIT to this count,
# so any value works in the same kit.
@export_range(2, 16, 1) var wall_jump_count: int = 8

@export var jump_hurdle_height: float = 0.9
@export var slide_bar_y: float = 1.65
@export var slide_bar_height: float = 0.45

@export var melody_world_color: Color = Color(0.984, 0.68, 1.0, 0.0)
@export var fx_world_color: Color = Color(1.0, 1.0, 1.0, 0.0)

@onready var music: AudioStreamPlayer = $Music
@onready var player: BeatRunnerPlayer = $Player
@onready var gates_root: Node3D = $Gates
@onready var world_fx_root: Node3D = $WorldFX
@onready var floor_mesh: MeshInstance3D    = $Track/FloorBody/FloorMesh
@onready var _floor_body: StaticBody3D     = $Track/FloorBody
@onready var _floor_col: CollisionShape3D  = $Track/FloorBody/CollisionShape3D
@export var color_cycle_enabled: bool = true
@export var color_cycle_period_s: float = 14.0
@export var color_cycle_gate_blend: float = 0.18
@export var color_cycle_floor_blend: float = 0.20

@export var cycle_color_a: Color = Color(1.00, 0.45, 0.70, 1.0) # pink
@export var cycle_color_b: Color = Color(0.45, 0.82, 1.00, 1.0) # baby blue
@export var cycle_color_c: Color = Color(0.30, 0.85, 0.55, 1.0) # green
@export var cycle_color_d: Color = Color(0.95, 0.78, 0.30, 1.0) # warm gold
@export_enum("tutorial_fixed", "song_seeded", "run_random") var runner_pattern_mode: String = "run_random"
@export var runner_seed_override: int = 0
@export_range(0.0, 1.0, 0.01) var runner_randomness: float = 0.35
@export var auto_quit_after_song: bool = true
@export var auto_quit_delay_s: float = 1.0

@export var gate_preview_beats: float = 8.0
@export var gate_keep_behind_beats: float = 1.25
@export var min_gate_preview_distance: float = 36.0

var _song_finish_pending: bool = false
var _end_screen_active:  bool  = false
var _end_screen_sel:     int   = 0     # 0 = play again, 1 = song select
var _end_lbl_again:      Label = null
var _end_lbl_select:     Label = null
var _gameplay_pulse_index: int = 0
var _runner_avg_beat_s: float = 0.5

var _runner_rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _floor_base_albedo: Color = Color(0.941, 0.946, 0.95, 0.0)

var gameplay_events: Array[Dictionary] = []
var world_events: Array[Dictionary] = []
var runner_plan: Array[Dictionary] = []
var gate_nodes: Array[Node3D] = []
var gate_judged: Array[bool] = []
var gate_success: Array[bool] = []
var gate_world_zs: Array[float] = []
var gate_culled: Array[bool] = []   # permanently hidden — _update_gate_visibility must never re-show these

var _judge_index: int = 0
var _vis_start_idx: int = 0   # lower-bound cursor for visibility loop
var _world_index: int = 0
var _halo_preview_index: int = 0   # unused; kept to avoid parser errors on old references

var _floor_material: StandardMaterial3D = null
var _fell: bool = false

# ── HUD / scoring state ───────────────────────────────────────────────────────
var _score:      int   = 0
var _combo:      int   = 0
var _max_combo:  int   = 0   # highest combo reached this run
var _gates_hit:  int   = 0   # total notes hit
var _gates_missed: int = 0   # total notes missed
var _health_pct: float = 0.50   # 0.0 – 1.0, starts at 50 %

var _hud_score_label:  Label     = null
var _hud_combo_label:  Label     = null
var _hud_hp_fill:      ColorRect = null   # inner fill bar
var _hud_hp_label:     Label     = null   # "HP" caption
var _hud_flash:        ColorRect = null
var _hud_wj_label:     Label     = null   # "WALL JUMP ×2!" flash label

# 3D speed streaks — elongated particles that rush past the player at high combo
var _speed_streaks:     GPUParticles3D          = null
var _speed_streaks_mat: ParticleProcessMaterial = null

# Wall-jump score bonus — doubles the multiplier for a short window after a
# successful wall-jump landing.  Decayed in _process; reset on section miss.
var _wj_mult_timer: float = 0.0
const _WJ_MULT_DURATION: float = 10.0    # seconds the bonus stays active

# ── Death screen state ───────────────────────────────────────────────────────
var _death_menu_active: bool = false
var _death_menu_option: int  = 0          # 0 = RETRY, 1 = SONG SELECT
var _death_option_nodes: Array[Control]   = []   # [retry_node, songselect_node]

# ── Level start — countdown before music begins ───────────────────────────────
# All heavy setup (gates, decorations, city) happens in _ready(). We then wait
# a few seconds for Godot to finish shader compilation / texture uploads before
# playing the music, so audio and gameplay are always perfectly in sync.
var _level_started:   bool  = false
var _countdown_timer: float = 0.0
const _COUNTDOWN_DURATION: float = 1.5   # seconds of settle time before music starts
var _countdown_label:  Label  = null       # big center number (3 / 2 / 1 / GO!)
var _countdown_title:  Label  = null       # song name shown during countdown
var _beatmap_title:    String = ""         # parsed from JSON, shown in countdown
var _warmup_done:      bool   = false      # set true once _warmup_shader_precompile() finishes;
											# _start_level() will not fire until this is true

# ── Pause state ───────────────────────────────────────────────────────────────
var _paused: bool = false
@warning_ignore("unused_private_class_variable")
var _pause_canvas: CanvasLayer  = null
var _pause_root:   Control      = null
var _pause_option: int          = 0       # 0 = RESUME, 1 = RESTART, 2 = MAIN MENU, 3 = SONG SELECT

# ── Gate spawn animation ──────────────────────────────────────────────────────
var _gate_animated: Array[bool] = []      # true once the gate's intro tween has fired

# ── City buildings ────────────────────────────────────────────────────────────
# One material per BUILDING (all window strips on a building share it) — much
# cheaper than one material per strip.  One roof light per building.
var _city_bldg_mats:   Array[StandardMaterial3D] = []
var _city_bldg_lights: Array[OmniLight3D]         = []
var _city_pulse_t:     float = 0.0   # 0-1, set to 1 on each beat, decays in _process
var _electric_zones:   Array[Dictionary] = []  # [{start_t, end_t}] seconds; empty = all city

# ── Electric theme ────────────────────────────────────────────────────────────
var _elec_obs_mats:   Array[StandardMaterial3D] = []   # obstacle arc meshes — pulse hard
var _elec_env_mats:   Array[StandardMaterial3D] = []   # pylon tip glows — pulse subtly
var _elec_arc_lights: Array[OmniLight3D]        = []   # shared lights from both
var _elec_pulse_t:    float = 0.0   # 0-1, set to 1 on each beat, decays in _process
var _elec_flicker_t:  float = 0.0   # cooldown between ambient flickers in electric zones
# Shared mesh resources — all arc segments + pylon parts reuse these so the
# renderer can GPU-instance them instead of issuing one draw call per node.
var _elec_seg_mesh:    BoxMesh    = null   # 1×0.055×0.055 unit box; scaled per segment
var _pylon_pole_mesh:  BoxMesh    = null
var _pylon_brace_mesh: BoxMesh    = null
var _pylon_beam_mesh:  BoxMesh    = null
var _pylon_glow_mesh:  SphereMesh = null
var _pylon_pole_mat:   StandardMaterial3D = null
var _pylon_brace_mat:  StandardMaterial3D = null
var _pylon_beam_mat:   StandardMaterial3D = null

# ── World vitality — hit = more alive, miss = less alive ─────────────────────
var _world_vitality:   float = 0.5   # 0.0 (dead) → 1.0 (fully alive)
var _lod_frame:        int   = 0     # toggles each frame — decorations update every other frame
var _beat_phase:       float = 0.0   # 0-1, snaps to 1 on each beat, decays in _process

# Refs to reactive world decoration elements (populated by _spawn_track_decorations)
var _world_strip_mats: Array[StandardMaterial3D] = []
var _world_rail_mats:  Array[StandardMaterial3D] = []
var _world_gem_lights: Array[OmniLight3D]         = []
var _world_arch_lights: Array[OmniLight3D]        = []
var _world_pad_mats:   Array[StandardMaterial3D] = []
# Authored wall-jump kit + ledge emissives — beat-pulsed (full on beat, dim between).
var _world_track_mats:   Array[StandardMaterial3D] = []
var _world_track_base_e: Array[float]              = []   # each mat's authored base energy
var _track_mat_seen:     Dictionary                = {}   # source-mat id → unique pulse mat (dedup)

# Melody visual system — env reference for fog colour pulses
var _melody_env: Environment = null
var _fx_tween_host: Node = null   # PROCESS_MODE_INHERIT — pauses with SceneTree
# Live halo ring materials — recoloured every frame with the song's colour cycle.
# _b holds secondary (dual-colour) materials; always empty when halo_dual_color = false.
var _active_halo_mats:   Array[StandardMaterial3D] = []
var _active_halo_mats_b: Array[StandardMaterial3D] = []
# Z range of the wall-jump section — halos are suppressed inside this zone
var _wj_zone_start_z:    float = -INF
var _wj_zone_end_z:      float = -INF
# Path distance where the ground floor resumes after the WJ descent platforms.
# Set by _spawn_wall_jump_section; used by _spawn_path_floors to skip only the
# void rather than all segments past _floor_cutoff_dist.  -1 = no WJ section.
var _wj_ground_resume_z: float = -1.0
# Slide rail that replaces descent platforms — free-lateral movement while descending
var _wj_slide_start_z:   float = -1.0   # path dist where slide begins
var _wj_slide_end_z:     float = -1.0   # path dist where slide ends
var _wj_slide_engaged:   bool  = false  # true while player is on the slide
var _wj_slide_safe_lane: int   = -1     # lane index that is safe (not electrified)
var _wj_shock_cd:        float = 0.0   # seconds until next shock is allowed

# Ambient sky sparks — always drifting, pulses on beat
var _spark_ambient:     GPUParticles3D          = null
var _spark_ambient_mat: ParticleProcessMaterial = null


# Footstep floor ripple — tracks run cycle to detect foot strikes
var _foot_cycle:    float = 0.0
var _foot_prev_sin: float = 0.0

# ── Snaking track path ────────────────────────────────────────────────────────
# The track is split into straight segments connected at 90° corners.
# All "distance along track" values are in metres (time × forward_speed).
# Gate positions, visibility, and judgment all use path distances, not world Z.

class TrackSeg:
	var origin:     Vector3 = Vector3.ZERO       # world position of segment start (track centre)
	var direction:  Vector3 = Vector3(0,0,1)     # unit forward direction
	var right:      Vector3 = Vector3(1,0,0)     # unit lateral-right  = Vector3(dir.z, 0, -dir.x)
	var length:     float   = 100.0              # metres
	var path_start: float   = 0.0               # path distance at start of this segment
	func path_end() -> float: return path_start + length

var _track_segs:        Array          = []      # Array[TrackSeg]
var _player_path_dist:  float          = 0.0    # song_time × forward_speed
var _last_seg_idx:      int            = 0
var _floor_cutoff_dist: float          = INF    # floor not spawned past this (wall-jump void)
# Path distances of every arc turn — start and end — used to cull gates.
var _turn_junction_pds: Array[float]   = []   # arc start
var _turn_arc_ends:     Array[float]   = []   # arc end
var _turn_is_right:     Array[bool]    = []   # true = right turn; used by banking + camera lean

# ── HUD progress ─────────────────────────────────────────────────────────────
var _hud_progress_fill: ColorRect = null
var _song_total_duration: float   = 0.0

# ── SFX ──────────────────────────────────────────────────────────────────────
var _sfx_miss: AudioStreamPlayer = null

# ── Rap / Grind-rail system ───────────────────────────────────────────────────
# Rap segments + taps are parsed from the beatmap JSON. When the song reaches
# a rap segment, a glowing rail spawns on the right outer edge. The player can
# hold the grind trigger to ride it and tap the jump button to catch spark nodes
# that fly toward them along the rail — each catch scores 1.5× a normal gate.
# Normal gates still exist during rap segments: players who don't grind can still
# hit them as usual. Players who DO grind skip gate judgment with no penalty,
# trading guaranteed gate income for higher-ceiling spark income.
#
# Beatmap format additions (all optional — if absent, grind system is inactive):
#   "rap_segments": [{"start_t": 12.5, "end_t": 24.0}, ...]  (times in seconds)
#   "rap_taps":     [12.5, 12.75, 13.0, ...]  (sorted list of tap times in seconds)
#   If rap_taps is omitted, 8th-note subdivision is auto-generated for each segment.

var _rap_segs:     Array[Dictionary] = []   # {start_t, end_t}
var _rap_taps_t:   Array[float]      = []   # sorted tap times  (seconds)
var _rap_tap_pds:  Array[float]      = []   # same, as path distances (metres)

# ── Charge tunnel (drop buildup) ──────────────────────────────────────────────
# Chart marker: "drop_buildups": [{"start_t": s, "end_t": s}, ...]  (seconds).
# During a buildup the lanes drop away and the player free-slides to thread a tunnel of
# hoops whose openings weave side to side. Clean threading (while HOLDING runner_grind)
# fills a charge meter; clipping/letting-go bleeds it. Release on the drop's downbeat
# (end_t) cashes the charge in: the score multiplier snaps to ×100 for a window whose
# LENGTH scales with how full the charge was. During that window misses don't drop the
# multiplier (but still score nothing).
var _drop_buildups:       Array[Dictionary] = []   # {start_t, end_t}
var _charge_active:       bool      = false   # tunnel currently spawned (incl. preview lead-in)
var _charge_building:     bool      = false   # player is in the buildup proper (free-slide on)
var _charge_finalized:    bool      = false   # payoff already resolved for this buildup
var _charge:              float     = 0.0     # 0..1 fill
var _charge_seg:          Dictionary = {}
var _charge_seg_start_pd: float     = 0.0
var _charge_seg_end_pd:   float     = 0.0
var _charge_root:         Node3D    = null    # parent for hoop meshes
var _charge_last_held:    bool      = false   # previous-frame hold state (release edge detect)
var _charge_release_t:    float     = -1.0    # song-time of the most recent hold release
var _charge_mult_timer:   float     = 0.0     # seconds the ×100 window has left
var _hud_charge_label:    Label     = null

const _CHARGE_LEAD_S:       float = 2.5    # spawn the tunnel this many seconds early (preview)
const _CHARGE_HOOP_SPACING: float = 4.0    # metres between hoops
const _CHARGE_GAP_RADIUS:   float = 1.15   # hoop inner radius = lateral alignment tolerance
const _CHARGE_WEAVE_AMP:    float = 2.2    # lateral weave amplitude (metres)
const _CHARGE_WEAVE_FREQ:   float = 0.16   # weave radians per metre of path
const _CHARGE_HEIGHT:       float = 1.2    # hoop centre height above the floor
const _CHARGE_FILL_RATE:    float = 0.55   # charge/sec while threading cleanly
const _CHARGE_CLIP_BLEED:   float = 0.45   # charge/sec lost while held but misaligned
const _CHARGE_LETGO_BLEED:  float = 1.20   # charge/sec lost while NOT holding (fizzle)
const _CHARGE_REL_WIN_S:    float = 0.35   # release-timing window around the drop downbeat
const _CHARGE_MIN_FILL:     float = 0.25   # below this final fill → no payoff (fizzle)
const _CHARGE_MULT_MIN_S:   float = 3.0    # ×100 window length at the minimum qualifying fill
const _CHARGE_MULT_MAX_S:   float = 12.0   # ×100 window length at a full charge
const _CHARGE_MULT_VALUE:   int   = 100    # the locked multiplier

# Active grind segment state
var _grind_rail_active:  bool      = false
var _grind_rail_root:    Node3D    = null   # parent for rail mesh segments
var _grind_seg_start_pd: float     = 0.0
var _grind_seg_end_pd:   float     = 0.0

# Spark nodes for the active segment (rebuilt on each segment entry)
var _spark_nodes:       Array[Node3D] = []
var _spark_caught:      Array[bool]   = []
var _spark_tap_pds:     Array[float]  = []   # path dist of each spark in active seg
var _spark_preview_idx: int           = 0    # next index to unhide as player approaches

# Per-segment counters
var _grind_caught_this_seg: int = 0
var _grind_total_this_seg:  int = 0
var _grind_engaged_this_seg: bool = false   # did the player actually ride the rail this segment?

# Branch geometry — the rail leaves the track on its OWN 3D path (across, under, over,
# spiralling) and rejoins at the end. A trick type + amplitudes randomised per segment.
var _grind_trick:        int   = 0   # 0 sweep · 1 cross-over · 2 cross-under · 3 corkscrew · 4 wander
var _grind_branch_lat:   float = 0.0  # lateral amplitude (metres)
var _grind_branch_h:     float = 0.0  # vertical amplitude (metres; can go below the track)
var _grind_branch_turns: float = 0.0  # spiral/wiggle turns over the segment

# Ramping FLOW multiplier (consecutive catches) + fail tracking (consecutive misses)
var _grind_flow_streak: int  = 0
var _grind_flow_mult:   int  = 1
var _grind_miss_streak: int  = 0
var _grind_failed:      bool = false

# HUD
var _hud_grind_label: Label = null

# ── Lyrics (on-screen, synced; fixed bottom-of-screen position) ───────────────
var _lyrics:            Array[Dictionary] = []    # [{mode,t_start,t_end,words:[{t,w}],text}]
var _lyrics_hud:        HBoxContainer     = null  # word row, anchored to bottom centre
var _lyrics_active_idx: int               = -1
var _lyrics_revealed:   int               = 0
var _lyrics_slide_off:  float             = 0.0   # vertical entrance offset, tweens to 0
var _lyric_font:        Font              = null  # randomly chosen each run from res://fonts/
const _LYRICS_HOLD_S:   float             = 1.1   # how long a finished line lingers on screen
const _LYRIC_COLORS: Array[Color] = [
	Color(0.00, 0.95, 1.00),   # neon cyan
	Color(1.00, 0.15, 0.75),   # hot pink
	Color(1.00, 0.92, 0.08),   # electric yellow
	Color(0.65, 0.20, 1.00),   # violet
	Color(1.00, 1.00, 1.00),   # white
]

const _GRIND_RAIL_LATERAL:  float = 3.35   # left side — just past outermost lane
const _GRIND_SPARK_H:       float = 0.85   # height of spark orbs above the floor
const _GRIND_PREVIEW_M:     float = 32.0   # show sparks within this many metres ahead
const _GRIND_SCORE_PER_SPARK: int = 750    # 1.5 × city gate hit (500); electric gates score 1000
const _GRIND_FLOW_MULT_MAX:  int = 8       # cap on the ramping flow multiplier
const _GRIND_FAIL_MISSES:    int = 3       # consecutive missed sparks → fall off the rail
const _GRIND_FULLCLEAR_BONUS: int = 5000   # bonus for catching every spark in a segment
# Chart trick names → internal trick ids. A rap_segment may name one of these to pin the
# rail (else it's rolled randomly per run seed). See _roll_grind_trick / _grind_branch_offset.
const _GRIND_TRICK_IDS: Dictionary = {
	"sweep": 0, "cross_over": 1, "cross_under": 2, "corkscrew": 3, "wander": 4, "loop": 5,
}

# ── Authored track pieces (Blender exports in assets/track/) ─────────────────
# The library scans for hand-made pieces; whatever exists is instanced along
# the path (positioned / rotated / banked automatically) and the matching
# procedural visuals are skipped. Missing pieces are generated as before.
# Collision is ALWAYS procedural — authored pieces are visual replacements.
## Flip this if imported Blender corner pieces bend the wrong way.
@export var mirror_turn_pieces: bool = false
## Flip this if the authored WJ descent slide puts the safe lane on the wrong side.
@export var mirror_wj_slide: bool = false
var _piece_lib: TrackPieceLibrary = null
var _authored_arcs: Dictionary = {}   # arc_idx -> true when an authored corner was placed
var _piece_mat_seen: Dictionary = {}  # src material id -> unique dup (piece pulse lists)

# ── Camera FX — beat pulse, lane tilt ────────────────────────────────────────
var _camera: Camera3D   = null
var _cam_fov_base: float = 62.0   # matches scene default; overwritten in _ready
var _beat_cam_t: float   = 0.0    # 0→1, set on each beat, decays in _process
var _cam_tilt: float     = 0.0    # current z-rotation in degrees, decays toward 0
var _cam_arc_tilt: float = 0.0   # smooth z-roll during arc corners; lerps in/out
var _cam_prev_lane: int  = -1     # last known lane — lane-change tilt trigger


func _resolve_beatmap_from_run() -> void:
	var key: String = str(Run.current_song_key).strip_edges()
	if key == "":
		return
	var try_paths: Array[String] = [
		"user://beatmaps/%s.json" % key,
		"res://data/beatmaps/%s.json" % key,
	]
	for p in try_paths:
		if FileAccess.file_exists(p):
			beatmap_json_path = p
			return
	push_warning("[BeatRunner] Run.current_song_key='%s' set but no matching file found — falling back to inspector path." % key)


# If the beatmap specifies a fixed font, override the random pick made in _ready().
func _apply_beatmap_lyric_font(d: Dictionary) -> void:
	var choice: String = String(d.get("lyric_font", "random")).strip_edges()
	if choice == "" or choice == "random":
		return   # keep whatever was randomly picked
	var path := "res://fonts/" + choice
	if ResourceLoader.exists(path):
		_lyric_font = load(path)


func _pick_random_lyric_font() -> void:
	var dir := DirAccess.open("res://fonts/")
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".ttf") or f.ends_with(".otf"):
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	if files.is_empty():
		return
	_lyric_font = load("res://fonts/" + files[randi() % files.size()])


func _ready() -> void:
	# Apply user settings before any world/material setup
	_pick_random_lyric_font()
	_fx_tween_host = Node.new()
	_fx_tween_host.name = "FxTweenHost"
	add_child(_fx_tween_host)
	cycle_color_a       = GameConfig.level_color_a
	cycle_color_b       = GameConfig.level_color_b
	_floor_base_albedo  = GameConfig.floor_color
	color_cycle_enabled = GameConfig.color_cycle_enabled
	gate_preview_beats  = GameConfig.gate_preview_beats
	_resolve_beatmap_from_run()
	_setup_world_environment()
	_prepare_floor_material()
	_load_chart_and_build_plan()
	player.set_beat_duration(_runner_avg_beat_s)
	_piece_lib = TrackPieceLibrary.new()
	_piece_lib.scan()                 # authored Blender pieces (assets/track) — BEFORE gate visuals
	_build_all_gate_visuals()         # places gates at initial Z positions (no geometry yet)
	_prescan_wj_zone()                # estimate WJ bounds from plan so path can protect the band
	_build_track_path()               # turns spread from 100 m onwards; only WJ band protected
	_reposition_gates_on_path()       # move every gate to its correct world position on the path
	_spawn_wj_geometry_on_path()      # path-aware WJ geometry + gate lifts + WJ zone culling
	# _cull_turn_zone_gates() — no longer needed; arc turns are smooth enough to play
	_place_authored_corners()         # authored Blender corners — before path floors
	_floor_body.visible = false       # hide the 50 km scene floor — path segments take over
	_spawn_path_floors()              # spawn per-segment floor bodies
	_spawn_corner_pieces()            # fill 90° gap pads at each turn junction
	_spawn_track_decorations()
	_spawn_arc_decorations()          # outer barrier, inner accent, entry beacons
	_spawn_floor_grid()
	_spawn_city_buildings()
	if not _electric_zones.is_empty():
		_spawn_electric_environment()
	_setup_music()   # assigns stream only — does NOT play yet

	var cb := Callable(self, "_on_music_finished")
	if not music.finished.is_connected(cb):
		music.finished.connect(cb)

	_update_gate_visibility()
	_create_hud()
	_build_miss_sfx()

	# Connect grind-tap signal so Section can judge spark catches
	if player.grind_tap_pressed.is_connected(_on_grind_tap) == false:
		player.grind_tap_pressed.connect(_on_grind_tap)

	# Cache camera for beat-sync FX
	_camera = get_viewport().get_camera_3d()
	if _camera != null:
		_cam_fov_base = _camera.fov
	_cam_prev_lane = player.current_lane

	# ── Countdown — hold everything until the engine has had time to settle ──
	# IMPORTANT: disable physics too so the player doesn't run through early gates
	# while the countdown is on screen.
	player.input_disabled = true
	player.set_physics_process(false)
	_countdown_timer = _COUNTDOWN_DURATION
	_spawn_countdown_ui()
	_warmup_shader_precompile()   # runs in the background — see _update_countdown()


func _process(delta: float) -> void:
	# ── Countdown phase — wait for engine to settle before starting music ────
	# (runs even if stream is null so the countdown can still fire and unblock input)
	if not _level_started:
		_update_countdown(delta)
		return

	if music.stream == null:
		return

	# City / electric pulse decay runs even when paused so lights don't freeze mid-flash
	_update_city_pulse(delta)
	_update_electric_pulse(delta)

	# Decay wall-jump bonus timer (runs through pause so the label fades naturally)
	if _wj_mult_timer > 0.0:
		_wj_mult_timer = maxf(0.0, _wj_mult_timer - delta)
		_update_wj_bonus_label()

	# Beat phase decays quickly (full fade in ~0.28 s) — drives beat-sync brightness spikes
	_beat_phase = maxf(0.0, _beat_phase - delta * 3.6)
	# Beat camera pulse decays — drives FOV kick
	_beat_cam_t = maxf(0.0, _beat_cam_t - delta * 5.0)
	# Vitality drifts gently toward 0.50 baseline when nothing is happening
	_world_vitality = lerpf(_world_vitality, 0.5, delta * 0.07)
	_update_camera_fx(delta)

	# Game paused — only update the HUD so the overlay stays responsive
	if _paused:
		return

	var t_s: float = _song_time()
	player.set_song_time(t_s)

	# Charge OVERDRIVE window countdown (gameplay time — not while paused).
	if _charge_mult_timer > 0.0:
		_charge_mult_timer = maxf(0.0, _charge_mult_timer - delta)
		if _charge_mult_timer <= 0.0:
			_update_hud_score()   # multiplier label drops back to the combo-based value

	# Song progress bar
	_update_hud_progress(t_s)

	# slow palette drift
	if has_method("_update_color_cycle"):
		_update_color_cycle(t_s)

	# ── Path tracking — keep path dist + player direction in sync each frame ────
	# Walk forward/backward from last frame's segment by physical projection.
	# No time estimate — that was the source of intermittent timing spikes on
	# variable-radius arcs where a 2–3-sub-segment look-ahead error caused proj
	# to go negative on a future segment, clamping _player_path_dist too far ahead.
	if not _track_segs.is_empty():
		var seg_idx: int      = clampi(_last_seg_idx, 0, _track_segs.size() - 1)
		var cur_seg: TrackSeg = _track_segs[seg_idx] as TrackSeg
		var proj: float       = (player.global_position - cur_seg.origin).dot(cur_seg.direction)

		# Walk forward while the player is past the end of the current segment
		while proj > cur_seg.length and seg_idx + 1 < _track_segs.size():
			seg_idx += 1
			cur_seg  = _track_segs[seg_idx] as TrackSeg
			proj     = (player.global_position - cur_seg.origin).dot(cur_seg.direction)

		# Walk backward if the player somehow hasn't reached this segment (safety net)
		while proj < 0.0 and seg_idx > 0:
			seg_idx -= 1
			cur_seg  = _track_segs[seg_idx] as TrackSeg
			proj     = (player.global_position - cur_seg.origin).dot(cur_seg.direction)

		_last_seg_idx     = seg_idx
		_player_path_dist = cur_seg.path_start + clampf(proj, 0.0, cur_seg.length)

	if not _track_segs.is_empty():
		var seg_idx: int      = _path_seg_idx_at(_player_path_dist)
		var cur_seg: TrackSeg = _track_segs[seg_idx] as TrackSeg

		# Pure current-segment direction — ALWAYS used for velocity and lateral correction.
		# Blending these into the physics causes the lane-snap to fire huge correction
		# forces when right_dir rotates 90°, shooting the player off the track.
		var pfwd: Vector3 = cur_seg.direction
		var prgt: Vector3 = cur_seg.right

		# ── Look-ahead visual blend — only drives rotation.y / camera turning.
		# Starts 45 m before the junction so the body pre-rotates smoothly.
		# The actual movement direction stays pure until the player crosses the junction.
		const LOOK_AHEAD_M: float = 20.0
		var vis_fwd: Vector3 = cur_seg.direction   # default: same as movement dir
		var dist_to_seg_end: float = cur_seg.path_end() - _player_path_dist
		if dist_to_seg_end < LOOK_AHEAD_M and seg_idx + 1 < _track_segs.size():
			var next_seg: TrackSeg = _track_segs[seg_idx + 1] as TrackSeg
			# ease-in curve: slow at first, accelerates as the corner approaches
			var t: float = 1.0 - (dist_to_seg_end / LOOK_AHEAD_M)
			var blend: float = t * t
			vis_fwd = pfwd.lerp(next_seg.direction, blend).normalized()
			# NOTE: prgt intentionally NOT blended — lane correction stays stable

		var pctr: Vector3 = _path_pos_at(_player_path_dist)
		player.set_forward_dir(pfwd, prgt, vis_fwd)
		player.set_track_center(pctr)

	# Recolour any live halo rings each frame.
	# Alpha is preserved so the fade-in / fade-out tweens still work correctly.
	var _halo_col_a: Color = _current_cycle_color(t_s) if GameConfig.color_cycle_affects_halos else GameConfig.halo_color_a
	if not _active_halo_mats.is_empty():
		for hmat in _active_halo_mats:
			if is_instance_valid(hmat):
				var a: float = hmat.albedo_color.a
				hmat.albedo_color = Color(_halo_col_a.r, _halo_col_a.g, _halo_col_a.b, a)
				hmat.emission     = _halo_col_a
	if not _active_halo_mats_b.is_empty():
		# B colour: if dual_color use GameConfig.halo_color_b, else follow A
		var _halo_col_b: Color = GameConfig.halo_color_b if GameConfig.halo_dual_color else _halo_col_a
		for hmat in _active_halo_mats_b:
			if is_instance_valid(hmat):
				var a: float = hmat.albedo_color.a
				hmat.albedo_color = Color(_halo_col_b.r, _halo_col_b.g, _halo_col_b.b, a)
				hmat.emission     = _halo_col_b

	# only show gates a few beats ahead instead of the whole song at once
	_update_gate_visibility()

	# gameplay judgement
	_judge_passed_unhit_gates_by_position()

	# floor now reacts to BEATS
	_run_floor_beats(t_s)

	# melody/fx can still drive world-side visuals
	_run_world_events(t_s)

	# Grind-rail system — spawn/update rail + sparks during rap segments
	_update_grind_system(t_s)
	# Charge tunnel — drop buildups (free-slide hoop threading → ×100 overdrive)
	_update_charge_tunnel(t_s, delta)
	# WJ descent slide — jump lock + shock on wrong lane
	_update_wj_slide(delta)
	_update_lyrics(t_s)

	# Floor glow under each foot strike
	_check_footstep_ripple(delta)

	# Fall detection — show death/retry screen if player drops into the void
	if not _fell and player.global_position.y < -12.0:
		_fell = true
		_trigger_death()

# ── Countdown / level-start ───────────────────────────────────────────────────

func _spawn_countdown_ui() -> void:
	# Create a high-priority CanvasLayer so it sits above everything else
	var cl := CanvasLayer.new()
	cl.layer = 50
	cl.name  = "CountdownLayer"
	add_child(cl)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(root)

	# Dark semi-transparent overlay so the player can see the track loading
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	# Song title
	_countdown_title = Label.new()
	var title_text: String = _beatmap_title if _beatmap_title != "" else str(Run.current_song_key).strip_edges()
	if title_text == "" or title_text == "null":
		title_text = "Get ready…"
	_countdown_title.text = title_text
	_countdown_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_title.set_anchors_preset(Control.PRESET_CENTER)
	_countdown_title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_countdown_title.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_countdown_title.offset_top      = -80
	_countdown_title.offset_bottom   = -80 + 32
	_countdown_title.add_theme_font_size_override("font_size", 22)
	_countdown_title.add_theme_color_override("font_color", Color(0.80, 0.70, 1.00, 0.85))
	_countdown_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_countdown_title)

	# Big countdown label
	_countdown_label = Label.new()
	_countdown_label.text = "GET READY"
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	_countdown_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_countdown_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_countdown_label.offset_top      = -50
	_countdown_label.offset_bottom   = -50 + 100
	_countdown_label.add_theme_font_size_override("font_size", 96)
	_countdown_label.add_theme_color_override("font_color", Color(1.00, 0.45, 0.72, 1.0))
	_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_countdown_label)


func _update_countdown(delta: float) -> void:
	_countdown_timer -= delta
	# Also wait on _warmup_done — if shader warm-up is still forcing gates
	# visible to compile their pipelines, don't cut over to real gameplay
	# (and its normal distance-windowed gate visibility) out from under it.
	if _countdown_timer <= 0.0 and _warmup_done:
		_start_level()


## Gates only become visible within min_gate_preview_distance while the
## player is stationary (see _update_gate_visibility()) — so most of a
## level's gate variety never actually gets *drawn*, and therefore never
## gets its render pipeline compiled by the GPU driver, until the player
## runs into an unseen gate type mid-level. That's the real source of the
## "choppy first 10-20 seconds" stutter, worst on levels that throw varied
## gates at the player immediately with no lead-in.
##
## Fix: force every already-built gate visible for a handful of frames
## right now, hidden behind the countdown's dark overlay, so the driver
## compiles every unique gate pipeline while the player is still looking
## at "GET READY" — then hide them again and hand back to
## _update_gate_visibility() for normal distance-windowed reveal. Never
## touches _gate_animated, so each gate's pop-in reveal tween still plays
## the first time the player actually approaches it later.
func _warmup_shader_precompile() -> void:
	for gate in gate_nodes:
		if gate != null and gate.process_mode != Node.PROCESS_MODE_DISABLED:
			gate.visible = true

	# A handful of real frames — enough for the renderer to submit draw
	# calls for everything now visible and for the driver to work through
	# compiling whatever pipelines it hasn't seen yet this run.
	for _i in range(8):
		await get_tree().process_frame

	for gate in gate_nodes:
		if gate != null:
			gate.visible = false

	_warmup_done = true


func _start_level() -> void:
	_level_started = true

	# "GO!" flash — then remove the entire countdown canvas
	if _countdown_label != null:
		_countdown_label.text = "GO!"
		_countdown_label.add_theme_color_override("font_color", Color(0.30, 1.00, 0.55, 1.0))
		var gtw := create_tween()
		gtw.tween_property(_countdown_label, "modulate:a", 0.0, 0.45)
		# Remove the whole CountdownLayer once the flash is done
		var cl: Node = get_node_or_null("CountdownLayer")
		if cl != null:
			gtw.tween_callback(cl.queue_free)

	# Re-enable physics, input, and start music all on the same frame —
	# player movement and audio clock both begin at exactly t=0.
	player.set_physics_process(true)
	player.input_disabled = false
	if music.stream != null:
		music.play()


func _setup_music() -> void:
	# Beatmap song_path always wins — song_stream is just an editor/fallback override.
	# NOTE: we only ASSIGN the stream here — actual playback starts in _start_level()
	# after the countdown, so music and gameplay are always perfectly in sync.
	var song_from_chart: AudioStream = _try_load_song_from_chart()
	if song_from_chart != null:
		music.stream = song_from_chart
	elif song_stream != null:
		music.stream = song_stream

	if music.stream == null:
		push_warning("BeatRunner: no song found — set song_path in the beatmap JSON or assign song_stream in the Inspector.")

func _song_time() -> float:
	if not _level_started:
		return 0.0   # countdown is running — no song yet
	var tplay: float = music.get_playback_position()
	tplay += AudioServer.get_time_since_last_mix()
	# NOTE: do NOT also subtract AudioServer.get_output_latency() here — the
	# tap-test calibration in AudioCalibrator already measures the full
	# round-trip latency (engine buffer + BT/hardware + reaction time), so
	# GameConfig's offset already cancels the engine buffer once. Subtracting
	# it again here double-corrects and shifts gameplay by an extra helping
	# of buffer latency on top of the calibrated value.
	tplay -= GameConfig.get_audio_offset_s()   # per-device calibration offset (total round-trip)
	return max(0.0, tplay)

func _thin_beats(events: Array[Dictionary], min_gap_s: float) -> Array[Dictionary]:
	# Drop any beat that arrives less than min_gap_s after the previous kept beat.
	# This makes dense/fast musical passages playable by capping gate frequency.
	var out: Array[Dictionary] = []
	var last_t: float = -9999.0
	for e in events:
		var t: float = float(e.get("t", 0.0))
		if t - last_t >= min_gap_s:
			out.append(e)
			last_t = t
	return out


func _load_chart_and_build_plan() -> void:
	gameplay_events.clear()
	world_events.clear()
	runner_plan.clear()
	gate_nodes.clear()

	if beatmap_json_path == "":
		push_warning("BeatRunner: beatmap_json_path is empty.")
		return
	if not FileAccess.file_exists(beatmap_json_path):
		push_warning("BeatRunner: beatmap file not found: %s" % beatmap_json_path)
		return

	var f: FileAccess = FileAccess.open(beatmap_json_path, FileAccess.READ)
	if f == null:
		push_warning("BeatRunner: failed to open beatmap json.")
		return

	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		push_warning("BeatRunner: invalid beatmap json.")
		return

	var d: Dictionary = parsed as Dictionary

	# Store the beatmap title for the countdown screen
	var json_title: String = String(d.get("title", "")).strip_edges()
	if json_title != "":
		_beatmap_title = json_title
	else:
		# Fall back to the filename without extension
		_beatmap_title = beatmap_json_path.get_file().get_basename()

	var evs: Variant = d.get("events", [])
	if evs is not Array:
		return

	for item in (evs as Array):
		if item is not Dictionary:
			continue
		var e: Dictionary = (item as Dictionary).duplicate(true)

		var pass_id: String = String(e.get("capture_pass", ""))
		if pass_id == "beats":
			gameplay_events.append(e)
		elif pass_id == "melody" or pass_id == "fx":
			world_events.append(e)

	gameplay_events.sort_custom(Callable(self, "_sort_event_by_t"))
	world_events.sort_custom(Callable(self, "_sort_event_by_t"))

	# Remove beats that are too close together to be physically playable.
	# The minimum gap scales with BPM: at high tempo we allow denser gates (down
	# to a hard floor for reaction time); at slow tempo we respect beat spacing.
	# Originally (0.20, ×0.55), which killed 1-2 out of every hardstyle
	# double/triple/quadruple kick. First loosened to (0.08, ×0.35) — still not
	# enough: at 150-160 BPM (Echoes in My Blood's range), 16th-note kick rolls
	# sit at beat_s/4 ≈ 0.094-0.1 s apart, and ×0.35 was landing at ~0.13-0.14 s
	# — still above the roll spacing, so it was still eating every other kick.
	# Now ×0.22 (comfortably under beat_s/4, with margin for tap-timing jitter
	# in the captured chart) so a full 16th-note roll survives intact at these
	# tempos. 32nd-note ornaments (beat_s/8) still get thinned some — that's
	# ~20 hits/sec, past what's meant to be individually tapped anyway.
	var _raw_beat_s: float = _estimate_runner_avg_beat_s(gameplay_events)
	var _min_gap_s:  float = maxf(0.06, _raw_beat_s * 0.28)
	gameplay_events = _thin_beats(gameplay_events, _min_gap_s)

	_runner_avg_beat_s = _estimate_runner_avg_beat_s(gameplay_events)

	# Calibrate player physics NOW (not after this function returns) so the wall-jump
	# feasibility check used during plan building sees the correct BPM-scaled gravity
	# and jump velocity. Safe to call again later — set_beat_duration is idempotent.
	player.set_beat_duration(_runner_avg_beat_s)

	# Let SongSelect override the pattern mode via the Run autoload
	var run_mode: String = str(Run.get("runner_pattern_mode")).strip_edges()
	if run_mode != "" and run_mode != "null" and run_mode != "Null":
		runner_pattern_mode = run_mode

	_setup_runner_rng()

	runner_plan = _build_runner_plan_from_beats(gameplay_events)
	_parse_rap_data(d)
	_parse_drop_buildups(d)
	_parse_electric_zones(d)
	_parse_lyrics(d)
	_apply_beatmap_lyric_font(d)

func _setup_runner_rng() -> void:
	if runner_seed_override != 0:
		_runner_rng.seed = runner_seed_override
		return

	match runner_pattern_mode:
		"tutorial_fixed":
			_runner_rng.seed = 1337

		"song_seeded":
			var seed_src: String = "%s|%d|%d" % [beatmap_json_path, gameplay_events.size(), world_events.size()]
			_runner_rng.seed = _hash_string_simple(seed_src)

		"run_random":
			# Re-use the seed from a previous run of the same song (retry),
			# so the map stays identical until the player explicitly goes back
			# to song select and picks a song (which resets Run.run_seed to 0).
			if Run.run_seed != 0:
				_runner_rng.seed = Run.run_seed
			else:
				# Pick a seed that has never been played for this song before
				_runner_rng.randomize()
				while Save.is_seed_used(Run.current_song_key, _runner_rng.seed):
					_runner_rng.randomize()
				Run.run_seed   = _runner_rng.seed
				Run.song_lives = 3   # fresh song → full 3 lives
				Save.mark_seed_used(Run.current_song_key, Run.run_seed)

		_:
			_runner_rng.seed = 1337


func _hash_string_simple(s: String) -> int:
	var h: int = 2166136261
	for i in range(s.length()):
		h = h ^ s.unicode_at(i)
		h = int(h * 16777619)
		h = abs(h)
	return max(1, h)

func _try_load_song_from_chart() -> AudioStream:
	if beatmap_json_path == "" or not FileAccess.file_exists(beatmap_json_path):
		return null

	var f: FileAccess = FileAccess.open(beatmap_json_path, FileAccess.READ)
	if f == null:
		return null
	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		return null

	var d: Dictionary = parsed as Dictionary
	var song_path: String = String(d.get("song_path", ""))
	if song_path == "":
		return null

	# res:// path (correct, preferred)
	if song_path.begins_with("res://") and ResourceLoader.exists(song_path):
		var r: Resource = load(song_path)
		if r is AudioStream:
			return r as AudioStream

	# Absolute path fallback (ManualMapper sometimes saves full Windows paths)
	if FileAccess.file_exists(song_path):
		var r: Resource = load(song_path)
		if r is AudioStream:
			return r as AudioStream

	push_warning("[BeatRunner] Could not load song from path: '%s'" % song_path)

	return null

# ── Phrase-aware planner ────────────────────────────────────────────────────
# Beats are grouped into phrases (default 8 beats). Each phrase gets one
# section type (zigzag / jump_chain / slide_recover / rush / breathe).
# Within a phrase, actions form a coherent pattern instead of beat-by-beat
# random decisions. This is also the extension point for wall-jump and rail
# section types in Phase 3.

const PHRASE_BEATS: int     = 8   # target beats per phrase
const MIN_PHRASE_BEATS: int = 4   # phrases smaller than this get merged up


func _build_runner_plan_from_beats(beat_events: Array[Dictionary]) -> Array[Dictionary]:
	if beat_events.is_empty():
		return []

	# 1. Split beat stream into musical phrases
	var phrases: Array = _segment_phrases(beat_events)

	# 2. Analyse each phrase (density, position in song, etc.)
	var song_end_t: float = float(beat_events[-1].get("t", 1.0))
	var analyses: Array[Dictionary] = []
	for phrase in phrases:
		analyses.append(_analyse_phrase(phrase, song_end_t))

	# 3. Choose a section type per phrase
	var section_types: Array[String] = _choose_section_sequence(analyses)

	# 3b. Actively place exactly one wall-jump at the most evenly-spaced FEASIBLE
	# phrase. Searches every phrase, so if the natural pick was unjumpable we keep
	# looking; if nothing is jumpable, no WJ is placed (sections still get filled).
	_place_feasible_wall_jump(section_types, phrases, analyses)

	# 4. Generate per-beat actions inside each phrase
	var out: Array[Dictionary] = []
	var virtual_lane: int = 1
	# After a wall_jump phrase, stores the slide landing lane so the first
	# lane-change gate in the next section can match it. -1 = inactive.
	var wj_exit_lane: int = -1

	for pi in range(phrases.size()):
		var phrase: Array        = phrases[pi]
		var stype: String        = section_types[pi]
		var actions: Array[String] = _generate_section_actions(stype, phrase.size(), virtual_lane)

		# Safety net: every beat MUST get a renderable action. A generator that caps or
		# returns short (e.g. _gen_wall_jump stops at 10 beats, while merged phrases can
		# be longer) would otherwise leave the leftover beats as blank, invisible gates —
		# a "gap of notes" with no gate to hit. Pad to exactly phrase.size() with safe
		# alternating lane moves so the stretch is always filled.
		if actions.size() < phrase.size():
			var pad_lane: int = virtual_lane
			for a in actions:
				match a:
					"left":       pad_lane = maxi(0, pad_lane - 1)
					"right":      pad_lane = mini(player.lane_xs.size() - 1, pad_lane + 1)
					"wall_left":  pad_lane = player.lane_xs.size() - 1
					"wall_right": pad_lane = 0
			while actions.size() < phrase.size():
				if pad_lane >= player.lane_xs.size() - 1:
					actions.append("left");  pad_lane -= 1
				else:
					actions.append("right"); pad_lane += 1

		# Guard: a wall_jump phrase whose ACTUAL beat spacing isn't physically jumpable
		# would be culled at spawn time, leaving an empty corridor with no gates. Catch
		# it here and demote to a normal section so the beats are always filled in.
		if stype == "wall_jump":
			var wj_times: Array[float] = []
			for wj_bi in range(phrase.size()):
				if actions[wj_bi] == "wall_left" or actions[wj_bi] == "wall_right":
					wj_times.append(float(phrase[wj_bi].get("t", 0.0)))
			if not bool(_validate_wall_jump_feasibility(wj_times).get("feasible", false)):
				push_warning("[BeatRunner] WJ phrase %d not jumpable for this song — demoting to zigzag." % pi)
				stype   = "zigzag"
				actions = _generate_section_actions(stype, phrase.size(), virtual_lane)

		# If the previous phrase was wall_jump, fix the first lane-change gate in this
		# phrase so its open arch is on the same lane where the slide deposits the player.
		# Trick: wall_left ends on max_lane, wall_right ends on lane 0. Forcing "right"
		# at max_lane (or "left" at lane 0) clamps in place, giving post_lane == pre_lane
		# so the arch sits exactly where the player just landed — no extra movement needed.
		var wj_gate_fixed: bool = (wj_exit_lane < 0)   # true = no fix needed this phrase
		# Tracks the landing lane of the last wall_left/wall_right within THIS phrase.
		# Must come from the actual wall action, NOT virtual_lane at phrase end — padding
		# actions after the last wall jump can shift virtual_lane away from 0/max_lane.
		var last_wj_act_lane: int = -1

		for bi in range(phrase.size()):
			var e: Dictionary  = phrase[bi]
			var action: String = actions[bi]

			# Post-WJ phrase: player can't jump or slide right after the descent slide —
			# replace those actions with lane moves so they're always reachable.
			if wj_exit_lane >= 0 and (action == "jump" or action == "slide"):
				action = "right" if virtual_lane < player.lane_xs.size() - 1 else "left"

			# Snap first lane-change gate to slide landing lane
			if not wj_gate_fixed and (action == "left" or action == "right"):
				action = "right" if wj_exit_lane >= player.lane_xs.size() - 1 else "left"
				wj_gate_fixed = true

			var pre_lane: int  = virtual_lane

			match action:
				"left":       virtual_lane = max(0, virtual_lane - 1)
				"right":      virtual_lane = min(player.lane_xs.size() - 1, virtual_lane + 1)
				"wall_left":  virtual_lane = player.lane_xs.size() - 1   # bounce to right side
				"wall_right": virtual_lane = 0                            # bounce to left side
			# Record wall landing lane separately — virtual_lane may drift if padding follows
			if action == "wall_left" or action == "wall_right":
				last_wj_act_lane = virtual_lane

			out.append({
				"t":            float(e.get("t", 0.0)),
				"action":       action,
				"pre_lane":     pre_lane,
				"post_lane":    virtual_lane,
				"source_lane":  int(e.get("lane", 0)),
				"section_tag":  stype,
				"phrase_index": pi,
			})

		# Record WJ exit lane for the following phrase using the LAST wall action's
		# landing lane — not virtual_lane which may have been moved by padding actions.
		wj_exit_lane = last_wj_act_lane if (stype == "wall_jump" and last_wj_act_lane >= 0) else -1

	return out


# ── Phrase segmentation ─────────────────────────────────────────────────────

func _segment_phrases(events: Array[Dictionary]) -> Array:
	var gap_threshold: float = _runner_avg_beat_s * 2.5
	var phrases: Array       = []
	var current: Array       = []

	for i in range(events.size()):
		if current.size() > 0:
			var prev_t: float = float(current[-1].get("t", 0.0))
			var this_t: float = float(events[i].get("t", 0.0))
			# Break phrase on musical silence gap OR when target size is reached
			if (this_t - prev_t) > gap_threshold or current.size() >= PHRASE_BEATS:
				phrases.append(current)
				current = []
		current.append(events[i])

	if current.size() > 0:
		phrases.append(current)

	# Merge tiny tail phrases (< MIN_PHRASE_BEATS) into the previous phrase
	var merged: Array = []
	for ph in phrases:
		if merged.size() > 0 and (ph as Array).size() < MIN_PHRASE_BEATS:
			for e in ph:
				(merged[-1] as Array).append(e)
		else:
			merged.append(ph)

	return merged


# ── Phrase analysis ─────────────────────────────────────────────────────────

func _analyse_phrase(phrase: Array, song_end_t: float) -> Dictionary:
	var beat_count: int = phrase.size()
	if beat_count == 0:
		return {}

	var t_start: float  = float(phrase[0].get("t", 0.0))
	var t_end: float    = float(phrase[-1].get("t", t_start))
	var duration: float = max(0.01, t_end - t_start)
	var density: float  = float(beat_count) / duration   # beats/second

	# Inter-beat gap variance — higher = more irregular rhythm
	var gaps: Array[float] = []
	for i in range(1, beat_count):
		gaps.append(float(phrase[i].get("t", 0.0)) - float(phrase[i - 1].get("t", 0.0)))
	var avg_g: float = 0.0
	for g in gaps: avg_g += g
	if gaps.size() > 0: avg_g /= float(gaps.size())
	var variance: float = 0.0
	for g in gaps: variance += (g - avg_g) * (g - avg_g)
	if gaps.size() > 0: variance /= float(gaps.size())

	return {
		"beat_count": beat_count,
		"t_start":    t_start,
		"density":    density,
		"variance":   variance,
		"song_pos":   clampf(t_start / max(1.0, song_end_t), 0.0, 1.0),
	}


# ── Section type sequencing ─────────────────────────────────────────────────

func _choose_section_sequence(analyses: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	var history: Array[String] = []   # last N picked types for variety enforcement
	var wall_jump_used: bool = false
	for i in range(analyses.size()):
		var prev: String = history.back() if history.size() > 0 else ""
		var stype: String = _pick_section_type(analyses[i], prev, i, analyses.size(), wall_jump_used, history)
		if stype == "wall_jump":
			wall_jump_used = true
		result.append(stype)
		history.append(stype)
		if history.size() > 5:
			history.pop_front()

	# Wall-jump placement is handled by _place_feasible_wall_jump() (called from
	# _build_runner_plan_from_beats), which actively searches every phrase for the
	# most evenly-spaced FEASIBLE spot and places exactly one WJ there. The
	# `wall_jump_used` flag above only stops the natural pool from stacking multiple
	# tentative WJ tags; the dedicated pass clears them and re-chooses the spot.

	return result


# Actively choose the single best wall-jump location: scan every eligible phrase,
# score it by feasibility + how evenly spaced its beats are, and place the WJ at the
# best one. If the first/natural choice was unjumpable we simply keep searching, so a
# feasible spot is almost always found. If none exists, no WJ is placed (sections stay
# filled — never an empty corridor).
func _place_feasible_wall_jump(section_types: Array[String], phrases: Array, analyses: Array[Dictionary]) -> void:
	const MAX_WJ_BEAT_S: float = 0.74
	const WJ_PLACE_PROB: float = 0.90   # chance a song gets a WJ at all (set 1.0 = every song)

	# Clear any WJ the natural pool tentatively placed — we pick the spot ourselves.
	for i in range(section_types.size()):
		if section_types[i] == "wall_jump":
			section_types[i] = "zigzag"

	if not GameConfig.wall_jumps_enabled or _runner_avg_beat_s >= MAX_WJ_BEAT_S:
		return
	if _runner_rng.randf() >= WJ_PLACE_PROB:
		return   # intentionally WJ-free this song (variety)

	# Search EVERY non-edge phrase for the most evenly-spaced feasible spot.
	var best_i:     int   = -1
	var best_score: float = 0.0
	for i in range(1, phrases.size() - 1):
		if int(analyses[i].get("beat_count", 0)) < 4:
			continue
		var score: float = _wj_phrase_score(phrases[i], analyses[i])
		if score > best_score:
			best_score = score
			best_i     = i

	if best_i != -1:
		section_types[best_i] = "wall_jump"


# Scores a phrase as a wall-jump host. Returns -1.0 if the beat spacing isn't
# physically jumpable; otherwise a positive score rewarding EVEN spacing (low gap
# variation), a mid-song position, and having more gates to climb.
func _wj_phrase_score(phrase: Array, a: Dictionary) -> float:
	var times: Array[float] = []
	for bi in range(mini(phrase.size(), 10)):
		times.append(float(phrase[bi].get("t", 0.0)))
	if times.size() < 2:
		return -1.0
	if not bool(_validate_wall_jump_feasibility(times).get("feasible", false)):
		return -1.0

	# Evenness from the actual gaps — coefficient of variation (0 = perfectly even).
	var gaps: Array[float] = []
	for gi in range(times.size() - 1):
		gaps.append(times[gi + 1] - times[gi])
	var mean: float = 0.0
	for g in gaps: mean += g
	mean /= float(gaps.size())
	var varr: float = 0.0
	for g in gaps: varr += (g - mean) * (g - mean)
	varr /= float(gaps.size())
	var cov:      float = sqrt(varr) / maxf(0.001, mean)
	var evenness: float = 1.0 / (1.0 + cov * 4.0)            # → 1.0 when perfectly even

	var song_pos:     float = float(a.get("song_pos", 0.0))
	var mid_bonus:    float = maxf(0.0, 1.0 - absf(song_pos - 0.55) * 1.2)
	# Strongly prefer phrases long enough for the full 7-jump rainbow (need ~7 walls
	# after ≤2 setup beats, so ≥8-9 beats). Length now dominates so every jump is scored;
	# shorter phrases still win when nothing longer is feasible (geometry shows 7 ledges
	# either way).
	var enough: float = 1.0 if gaps.size() >= 8 else float(gaps.size()) / 8.0
	var length_bonus: float = enough * 1.6

	return evenness * 2.0 + mid_bonus + length_bonus


func _pick_section_type(a: Dictionary, prev: String, phrase_idx: int, _total: int, wall_jump_used: bool = false, history: Array[String] = []) -> String:
	if runner_pattern_mode == "tutorial_fixed":
		return _pick_section_tutorial(phrase_idx)

	var density: float  = float(a.get("density",    2.0))
	var song_pos: float = float(a.get("song_pos",   0.0))
	var n_beats: int    = int(a.get("beat_count",   8))

	# Pool grows as the song progresses. Early sections stay readable;
	# the full palette unlocks by the halfway point.
	var pool: Array[String]
	if song_pos < 0.20:
		# Intro — gentle movement only, no surprises
		pool = [
			"zigzag", "breathe", "sweep", "pendulum",
			"double_tap", "stagger", "triple",
			"slide_recover", "slide_rush", "slide_drift", "slide_spam",
			"rush", "jump_chain", "jump_recover", "jump_breathe",
			"jump_weave", "pulse", "stutter", "offbeat", "bounce",
			"funnel", "cross", "mirror", "wall_brush",
			"breathe_then_rush", "rush_then_breathe",
			"cascade_left", "cascade_right", "sprint_slide",
			"lane_lock", "wall_jump",
			"triple_jump", "syncopated", "rush_slide",      # new
			"wave_weave", "burst_recover",                  # new
			"slide_chain", "slide_weave", "end_jump", "end_slide",
			"march", "gallop", "diamond", "zipper",
			"skip3", "skip3_slide", "alternating_vert", "three_phase",
			"double_jump", "double_slide", "ladder_right", "ladder_left",
			"triple_slide", "wide_zigzag", "pinball", "shimmy",
			"spread", "center_sprint", "jump_gallop", "wave_jump",
			"slide_gallop",                                 # new x25
		]
	elif song_pos < 0.45:
		# Building — add slides, rhythm variations, simple combos
		pool = [
			"zigzag", "breathe", "sweep", "pendulum",
			"double_tap", "stagger", "triple",
			"slide_recover", "slide_rush", "slide_drift", "slide_spam",
			"rush", "jump_chain", "jump_recover", "jump_breathe",
			"jump_weave", "pulse", "stutter", "offbeat", "bounce",
			"funnel", "cross", "mirror", "wall_brush",
			"breathe_then_rush", "rush_then_breathe",
			"cascade_left", "cascade_right", "sprint_slide",
			"lane_lock", "wall_jump",
			"triple_jump", "syncopated", "rush_slide",      # new
			"wave_weave", "burst_recover",                  # new
			"slide_chain", "slide_weave", "end_jump", "end_slide",
			"march", "gallop", "diamond", "zipper",
			"skip3", "skip3_slide", "alternating_vert", "three_phase",
			"double_jump", "double_slide", "ladder_right", "ladder_left",
			"triple_slide", "wide_zigzag", "pinball", "shimmy",
			"spread", "center_sprint", "jump_gallop", "wave_jump",
			"slide_gallop",                                 # new x25
		]
	elif song_pos < 0.70:
		# Full gameplay — everything except the very hardest patterns
		pool = [
			"zigzag", "breathe", "sweep", "pendulum",
			"double_tap", "stagger", "triple",
			"slide_recover", "slide_rush", "slide_drift", "slide_spam",
			"rush", "jump_chain", "jump_recover", "jump_breathe",
			"jump_weave", "pulse", "stutter", "offbeat", "bounce",
			"funnel", "cross", "mirror", "wall_brush",
			"breathe_then_rush", "rush_then_breathe",
			"cascade_left", "cascade_right", "sprint_slide",
			"lane_lock", "wall_jump",
			"triple_jump", "syncopated", "rush_slide",      # new
			"wave_weave", "burst_recover",                  # new
			"slide_chain", "slide_weave", "end_jump", "end_slide",
			"march", "gallop", "diamond", "zipper",
			"skip3", "skip3_slide", "alternating_vert", "three_phase",
			"double_jump", "double_slide", "ladder_right", "ladder_left",
			"triple_slide", "wide_zigzag", "pinball", "shimmy",
			"spread", "center_sprint", "jump_gallop", "wave_jump",
			"slide_gallop",                                 # new x25
		]
	else:
		# Finale — full palette
		pool = [
			"zigzag", "breathe", "sweep", "pendulum",
			"double_tap", "stagger", "triple",
			"slide_recover", "slide_rush", "slide_drift", "slide_spam",
			"rush", "jump_chain", "jump_recover", "jump_breathe",
			"jump_weave", "pulse", "stutter", "offbeat", "bounce",
			"funnel", "cross", "mirror", "wall_brush",
			"breathe_then_rush", "rush_then_breathe",
			"cascade_left", "cascade_right", "sprint_slide",
			"lane_lock", "wall_jump",
			"triple_jump", "syncopated", "rush_slide",      # new
			"wave_weave", "burst_recover",                  # new
			"slide_chain", "slide_weave", "end_jump", "end_slide",
			"march", "gallop", "diamond", "zipper",
			"skip3", "skip3_slide", "alternating_vert", "three_phase",
			"double_jump", "double_slide", "ladder_right", "ladder_left",
			"triple_slide", "wide_zigzag", "pinball", "shimmy",
			"spread", "center_sprint", "jump_gallop", "wave_jump",
			"slide_gallop",                                 # new x25
		]

	# Only one wall_jump per song; skip if disabled, already used, or BPM too slow.
	# MAX_WJ_BEAT_S: below ~81 BPM the j-clamp freezes wall-jump physics while beat
	# intervals keep growing, so the player lands before the next gate fires.
	const MAX_WJ_BEAT_S: float = 0.74
	if wall_jump_used or not GameConfig.wall_jumps_enabled or _runner_avg_beat_s >= MAX_WJ_BEAT_S:
		pool = pool.filter(func(s: String) -> bool: return s != "wall_jump")

	# Dense passages → simpler patterns so fast gates stay readable
	if density > 3.0:
		pool = pool.filter(func(s: String) -> bool: return s in [
			"breathe", "slide_recover", "sweep", "lane_lock",
			"bounce", "jump_recover", "offbeat",
		])
		if pool.is_empty():
			pool = ["breathe"]

	# Short phrases — strip patterns that need length to read correctly
	if n_beats < 5:
		var needs_length: Array[String] = [
			"wall_jump", "jump_chain", "funnel", "cross", "mirror",
			"breathe_then_rush", "rush_then_breathe", "wall_brush",
			"cascade_left", "cascade_right", "stagger", "triple",
		]
		pool = pool.filter(func(s: String) -> bool: return s not in needs_length)

	# Never repeat same section back-to-back
	if pool.size() > 1:
		pool = pool.filter(func(s: String) -> bool: return s != prev)

	if pool.is_empty():
		pool = ["zigzag"]

	# Weighted pick — patterns seen recently get lower weight so they feel less
	# predictable.  Age 0 (just used) = 0.15 weight; unseen = 4.0 weight.
	if pool.size() > 1 and history.size() > 0:
		var weights: Array[float] = []
		for s in pool:
			var recency: int = history.rfind(s)   # -1 if not in history
			if recency == -1:
				weights.append(4.0)
			else:
				var age: int = history.size() - 1 - recency   # 0 = most recent
				weights.append(0.15 + age * 0.85)
		var total_w: float = 0.0
		for w in weights: total_w += w
		var r: float = _runner_rng.randf() * total_w
		var acc: float = 0.0
		for pi in range(pool.size()):
			acc += weights[pi]
			if r <= acc:
				return pool[pi]

	return pool[_runner_rng.randi() % pool.size()]


func _pick_section_tutorial(phrase_idx: int) -> String:
	# Fixed readable progression — one mechanic introduced at a time
	var seq: Array[String] = [
		"breathe",        # 0  ease in
		"zigzag",         # 1  introduce left/right
		"zigzag",         # 2  reinforce left/right
		"slide_recover",  # 3  introduce slide
		"zigzag",         # 4
		"rush",           # 5  introduce single-jump zigzag
		"zigzag",         # 6
		"slide_recover",  # 7
		"rush",           # 8  combined speed section
		"zigzag",         # 9
	]
	return seq[phrase_idx % seq.size()]


# ── Per-section action generators ───────────────────────────────────────────
# Every generator returns exactly beat_count actions.
# Lane tracking inside the generator must mirror what the main loop will do
# when it applies each action to virtual_lane (left/right move; jump/slide don't).

func _generate_section_actions(stype: String, beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String]
	match stype:
		"zigzag":           actions = _gen_zigzag(beat_count, start_lane)
		"jump_chain":       actions = _gen_jump_chain(beat_count, start_lane)
		"slide_recover":    actions = _gen_slide_recover(beat_count, start_lane)
		"rush":             actions = _gen_rush(beat_count, start_lane)
		"breathe":          actions = _gen_breathe(beat_count, start_lane)
		"wall_jump":        actions = _gen_wall_jump(beat_count, start_lane)
		"sweep":            actions = _gen_sweep(beat_count, start_lane)
		"pendulum":         actions = _gen_pendulum(beat_count, start_lane)
		"double_tap":       actions = _gen_double_tap(beat_count, start_lane)
		"stagger":          actions = _gen_stagger(beat_count, start_lane)
		"pulse":            actions = _gen_pulse(beat_count, start_lane)
		"stutter":          actions = _gen_stutter(beat_count, start_lane)
		"offbeat":          actions = _gen_offbeat(beat_count, start_lane)
		"triple":           actions = _gen_triple(beat_count, start_lane)
		"bounce":           actions = _gen_bounce(beat_count, start_lane)
		"slide_rush":       actions = _gen_slide_rush(beat_count, start_lane)
		"slide_drift":      actions = _gen_slide_drift(beat_count, start_lane)
		"slide_spam":       actions = _gen_slide_spam(beat_count, start_lane)
		"jump_recover":     actions = _gen_jump_recover(beat_count, start_lane)
		"jump_breathe":     actions = _gen_jump_breathe(beat_count, start_lane)
		"jump_weave":       actions = _gen_jump_weave(beat_count, start_lane)
		"lane_lock":        actions = _gen_lane_lock(beat_count, start_lane)
		"funnel":           actions = _gen_funnel(beat_count, start_lane)
		"cross":            actions = _gen_cross(beat_count, start_lane)
		"wall_brush":       actions = _gen_wall_brush(beat_count, start_lane)
		"breathe_then_rush":actions = _gen_breathe_then_rush(beat_count, start_lane)
		"rush_then_breathe":actions = _gen_rush_then_breathe(beat_count, start_lane)
		"mirror":           actions = _gen_mirror(beat_count, start_lane)
		"cascade_left":     actions = _gen_cascade_left(beat_count, start_lane)
		"cascade_right":    actions = _gen_cascade_right(beat_count, start_lane)
		"sprint_slide":     actions = _gen_sprint_slide(beat_count, start_lane)
		"triple_jump":      actions = _gen_triple_jump(beat_count, start_lane)
		"syncopated":       actions = _gen_syncopated(beat_count, start_lane)
		"rush_slide":       actions = _gen_rush_slide(beat_count, start_lane)
		"wave_weave":       actions = _gen_wave_weave(beat_count, start_lane)
		"burst_recover":    actions = _gen_burst_recover(beat_count, start_lane)
		"slide_chain":      actions = _gen_slide_chain(beat_count, start_lane)
		"slide_weave":      actions = _gen_slide_weave(beat_count, start_lane)
		"end_jump":         actions = _gen_end_jump(beat_count, start_lane)
		"end_slide":        actions = _gen_end_slide(beat_count, start_lane)
		"march":            actions = _gen_march(beat_count, start_lane)
		"gallop":           actions = _gen_gallop(beat_count, start_lane)
		"diamond":          actions = _gen_diamond(beat_count, start_lane)
		"zipper":           actions = _gen_zipper(beat_count, start_lane)
		"skip3":            actions = _gen_skip3(beat_count, start_lane)
		"skip3_slide":      actions = _gen_skip3_slide(beat_count, start_lane)
		"alternating_vert": actions = _gen_alternating_vert(beat_count, start_lane)
		"three_phase":      actions = _gen_three_phase(beat_count, start_lane)
		"double_jump":      actions = _gen_double_jump(beat_count, start_lane)
		"double_slide":     actions = _gen_double_slide(beat_count, start_lane)
		"ladder_right":     actions = _gen_ladder_right(beat_count, start_lane)
		"ladder_left":      actions = _gen_ladder_left(beat_count, start_lane)
		"triple_slide":     actions = _gen_triple_slide(beat_count, start_lane)
		"wide_zigzag":      actions = _gen_wide_zigzag(beat_count, start_lane)
		"pinball":          actions = _gen_pinball(beat_count, start_lane)
		"shimmy":           actions = _gen_shimmy(beat_count, start_lane)
		"spread":           actions = _gen_spread(beat_count, start_lane)
		"center_sprint":    actions = _gen_center_sprint(beat_count, start_lane)
		"jump_gallop":      actions = _gen_jump_gallop(beat_count, start_lane)
		"wave_jump":        actions = _gen_wave_jump(beat_count, start_lane)
		"slide_gallop":     actions = _gen_slide_gallop(beat_count, start_lane)
		_:                  actions = _gen_zigzag(beat_count, start_lane)

	# Post-pass: guarantee at least one lane-move gate between any two vertical
	# actions (jump or slide). Catches edge cases in all generators at once.
	_enforce_vert_gap(actions, start_lane)
	return actions


# Scan an action list and replace any vertical (jump/slide) that comes too soon
# after a previous one with a safe lane move.  Always guarantees exactly one
# lane gate between verticals.
func _enforce_vert_gap(actions: Array[String], start_lane: int) -> void:
	var max_lane: int  = player.lane_xs.size() - 1
	var lane: int      = start_lane
	var going_right: bool = lane * 2 <= max_lane
	var last_vert: int = -3   # pretend we had one 3 beats ago so beat 0 is always allowed

	for i in range(actions.size()):
		var a: String = actions[i]
		var is_vert: bool = (a == "jump" or a == "slide")

		if is_vert and i - last_vert < 3:
			# Too close — replace with a lane move
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions[i] = "right" if going_right else "left"
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
		else:
			# Track lane position for accurate fallback lane moves
			match actions[i]:
				"left":  lane = max(lane - 1, 0)
				"right": lane = min(lane + 1, max_lane)
			if is_vert:
				last_vert = i


func _gen_zigzag(beat_count: int, start_lane: int) -> Array[String]:
	# Alternates left/right every beat; bounces cleanly off lane walls.
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane

	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false
		elif not going_right and lane <= 0:  going_right = true

		var action: String = "right" if going_right else "left"
		actions.append(action)
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		going_right = not going_right

	return actions


func _gen_jump_chain(beat_count: int, start_lane: int) -> Array[String]:
	# Jump every N beats (gap-safe), zigzag between.
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap

	for i in range(beat_count):
		if i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right

	return actions


func _gen_slide_recover(beat_count: int, start_lane: int) -> Array[String]:
	# Slide on beat 0, then zigzag recovery for the remainder of the phrase.
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane

	for i in range(beat_count):
		if i == 0:
			actions.append("slide")  # no lane change
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			var action: String = "right" if going_right else "left"
			actions.append(action)
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right

	return actions


func _gen_rush(beat_count: int, start_lane: int) -> Array[String]:
	# Full zigzag with a jump in the middle — only when the phrase is long enough
	# and the beat interval gives room to actually land before the next gate.
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int = _min_vert_gap()
	var mid: int = beat_count >> 1
	if beat_count >= gap * 2 + 1 and mid >= gap and (beat_count - 1 - mid) >= gap:
		actions[mid] = "jump"
	return actions


func _gen_breathe(beat_count: int, start_lane: int) -> Array[String]:
	# Slow zigzag: hold the same direction for 2 beats before switching.
	# Never uses jump or slide — stays readable even at high gate density.
	# Feels like a gentle drift rather than frantic switching.
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var held: int = 0

	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; held = 0
		elif not going_right and lane <= 0:  going_right = true;  held = 0

		var action: String = "right" if going_right else "left"
		actions.append(action)
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		held += 1

		if held >= 2:
			going_right = not going_right
			held = 0

	return actions

func _gen_wall_jump(beat_count: int, start_lane: int) -> Array[String]:
	beat_count = mini(beat_count, 10)   # cap at 10 — longer phrases would over-extend the section
	# Alternating wall_left / wall_right.
	# wall_left  → player launches upward, snaps to right side (target_lane = max)
	# wall_right → player launches upward, snaps to left side  (target_lane = 0)
	#
	# If the player enters from the wrong side we prepend plain lane-move beats
	# so they are never forced to choose between hitting the last normal gate and
	# positioning for the wall jump.
	var actions: Array[String] = []
	var max_lane: int     = player.lane_xs.size() - 1
	var first_is_left: bool = start_lane * 2 <= max_lane
	# Approach lane = the side the player must reach before the first wall jump.
	var approach_lane: int  = 0 if first_is_left else max_lane

	# Setup beats: steer to the approach lane with visible lane-gate obstacles.
	var lane: int = start_lane
	while lane != approach_lane and actions.size() < beat_count:
		actions.append("left" if lane > approach_lane else "right")
		lane += (-1 if lane > approach_lane else 1)

	# Remaining beats: alternating wall_left / wall_right — emit wall_jump_count of them so all
	# jumps are SCORED (the geometry builds the same number of ledges). The host phrase must
	# have enough beats for them all; the picker prefers long phrases, and any trailing walls
	# past the phrase length are truncated by the plan builder's per-beat loop.
	for wj_i in range(wall_jump_count):
		actions.append("wall_left" if (wj_i % 2 == 0) == first_is_left else "wall_right")

	return actions



# ── 25 new pattern generators ────────────────────────────────────────────────

# Minimum beats that must separate any two vertical (jump or slide) actions.
# Based on the longer of: full slide cooldown or full jump arc, divided by
# the song's average beat interval.  Always at least 2.
func _min_vert_gap() -> int:
	var slide_total: float = player.slide_duration + player.slide_cooldown
	var jump_air:    float = (player.jump_velocity / maxf(0.1, player.gravity)) * 2.1
	var worst:       float = maxf(slide_total, jump_air)
	return maxi(2, int(ceilf(worst / maxf(0.05, _runner_avg_beat_s))))


# One zigzag lane step — advances lane and direction in the ref arrays, returns action.
func _zz_step(lane_ref: Array, going_right_ref: Array, max_lane: int) -> String:
	var lane: int         = lane_ref[0]
	var going_right: bool = going_right_ref[0]
	if going_right and lane >= max_lane: going_right = false
	elif not going_right and lane <= 0:  going_right = true
	var action: String = "right" if going_right else "left"
	lane_ref[0]        = clamp(lane + (1 if going_right else -1), 0, max_lane)
	going_right_ref[0] = not going_right
	return action


# 1. SWEEP — drifts all lanes in one direction, flips and repeats.
func _gen_sweep(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var dir: int      = 1 if lane * 2 <= max_lane else -1
	for _i in range(beat_count):
		if lane >= max_lane: dir = -1
		elif lane <= 0:      dir =  1
		actions.append("right" if dir > 0 else "left")
		lane = clamp(lane + dir, 0, max_lane)
	return actions


# 2. PENDULUM — wall-to-wall oscillation, always targeting the opposite wall.
func _gen_pendulum(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	for _i in range(beat_count):
		var action: String = "right" if going_right else "left"
		actions.append(action)
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		if lane >= max_lane: going_right = false
		elif lane <= 0:      going_right = true
	return actions


# 3. DOUBLE_TAP — two steps same direction then flip (RR→LL→RR…).
func _gen_double_tap(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var tap: int = 0
	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; tap = 0
		elif not going_right and lane <= 0:  going_right = true;  tap = 0
		actions.append("right" if going_right else "left")
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		tap += 1
		if tap >= 2:
			going_right = not going_right
			tap = 0
	return actions


# 4. STAGGER — three steps same direction then one step back (RRR→L→RRR…).
func _gen_stagger(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var count: int = 0
	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; count = 0
		elif not going_right and lane <= 0:  going_right = true;  count = 0
		if count < 3:
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			count += 1
		else:
			# single backstep
			var back: String = "left" if going_right else "right"
			actions.append(back)
			lane = clamp(lane + (-1 if going_right else 1), 0, max_lane)
			count = 0
	return actions


# 5. PULSE — jump with minimum gap, lane change between jumps.
func _gen_pulse(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		if i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 6. STUTTER — lane change then hold-jump, but only when gap allows.
func _gen_stutter(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		# Even beats: lane change; odd beats: jump if allowed, else extra lane step
		if i % 2 == 0:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
		elif i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		else:
			# Gap too small — do another lane step instead
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 7. OFFBEAT — jump on beat 0, then zigzag from beat 1 onward.
func _gen_offbeat(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	if beat_count == 0:
		return actions
	actions.append("jump")
	var rest: Array[String] = _gen_zigzag(beat_count - 1, start_lane)
	actions.append_array(rest)
	return actions


# 8. TRIPLE — three same direction then one opposite, alternating lead side.
func _gen_triple(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var step: int = 0
	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; step = 0
		elif not going_right and lane <= 0:  going_right = true;  step = 0
		if step < 3:
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			step += 1
		else:
			going_right = not going_right
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			step = 1
	return actions


# 9. BOUNCE — alternating jump and slide, spaced by the minimum safe gap.
# Fills the beats in between with lane moves so it never double-stacks verticals.
func _gen_bounce(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	var want_jump: bool = true   # alternates jump / slide each time we can place one
	for i in range(beat_count):
		if i - last_vert >= gap:
			actions.append("jump" if want_jump else "slide")
			last_vert = i
			want_jump = not want_jump
		else:
			# Fill with a lane move
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 10. SLIDE_RUSH — zigzag but slide replaces the middle beat when gap allows.
func _gen_slide_rush(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int = _min_vert_gap()
	var mid: int = beat_count >> 1
	if beat_count >= gap * 2 + 1 and mid >= gap and (beat_count - 1 - mid) >= gap:
		actions[mid] = "slide"
	return actions


# 11. SLIDE_DRIFT — breathe (2-beat hold) but fires a slide on direction switches,
# only when the gap since the last vertical action is large enough.
func _gen_slide_drift(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var held: int      = 0
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	var i: int         = 0
	for _b in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; held = 0
		elif not going_right and lane <= 0:  going_right = true;  held = 0
		if held == 0 and i - last_vert >= gap:
			actions.append("slide")
			last_vert = i
		else:
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		held += 1
		if held >= 2:
			going_right = not going_right
			held = 0
		i += 1
	return actions


# 12. SLIDE_SPAM — slides spaced by minimum safe gap; zigzag fills between.
func _gen_slide_spam(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		if i - last_vert >= gap:
			actions[i] = "slide"
			last_vert  = i
	return actions


# 13. JUMP_RECOVER — jump on beat 0, zigzag the rest (mirror of slide_recover).
func _gen_jump_recover(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	if beat_count == 0:
		return actions
	actions.append("jump")
	var rest: Array[String] = _gen_zigzag(beat_count - 1, start_lane)
	actions.append_array(rest)
	return actions


# 14. JUMP_BREATHE — breathe pattern with a jump on direction switches (gap-safe).
func _gen_jump_breathe(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var held: int      = 0
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	var i: int         = 0
	for _b in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; held = 0
		elif not going_right and lane <= 0:  going_right = true;  held = 0
		if held == 0 and i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		else:
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		held += 1
		if held >= 2:
			going_right = not going_right
			held = 0
		i += 1
	return actions


# 15. JUMP_WEAVE — lane-change on even beats, jump on odd beats when gap allows.
func _gen_jump_weave(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		var want_jump: bool = (i % 2 == 1) and (i - last_vert >= gap)
		if want_jump:
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 16. LANE_LOCK — travel across lanes with jumps/slides at key waypoints.
# Revised: actually moves the player side-to-side so inputs stay meaningful.
func _gen_lane_lock(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	var want_jump: bool = _runner_rng.randf() > 0.5

	# Pick a destination on the opposite side from start
	var dest_lane: int = max_lane - start_lane
	if dest_lane == lane:
		dest_lane = clamp(lane + 2, 0, max_lane)
	var going_to_dest: bool = true

	for i in range(beat_count):
		var ready_for_vert: bool = (i - last_vert >= gap)
		var target: int = dest_lane if going_to_dest else start_lane
		var at_target: bool = (lane == target)

		if ready_for_vert and at_target:
			# Drop a vertical at the waypoint, then reverse direction
			actions.append("jump" if want_jump else "slide")
			last_vert  = i
			want_jump  = not want_jump
			going_to_dest = not going_to_dest
		elif lane < target:
			actions.append("right")
			lane = min(lane + 1, max_lane)
		elif lane > target:
			actions.append("left")
			lane = max(lane - 1, 0)
		elif ready_for_vert:
			# At target but not ready for vert yet — shouldn't normally happen,
			# but if it does drop a vertical rather than stalling in place
			actions.append("jump" if want_jump else "slide")
			last_vert = i
			want_jump = not want_jump
			going_to_dest = not going_to_dest
		else:
			# Travelling but already there and vert not ready — step away briefly
			var step_dir: String = "right" if lane < max_lane else "left"
			actions.append(step_dir)
			lane = clamp(lane + (1 if step_dir == "right" else -1), 0, max_lane)
	return actions


# 17. FUNNEL — converge toward center in first half, zigzag out in second half.
func _gen_funnel(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var center: int   = max_lane >> 1
	var half: int     = beat_count >> 1

	# First half: step toward center each beat
	for _i in range(half):
		if lane < center:
			actions.append("right"); lane = min(lane + 1, max_lane)
		elif lane > center:
			actions.append("left"); lane = max(lane - 1, 0)
		else:
			actions.append("jump")   # already centered — mark with a jump

	# Second half: zigzag freely from center
	var going_right: bool = true
	for _i in range(beat_count - half):
		if going_right and lane >= max_lane: going_right = false
		elif not going_right and lane <= 0:  going_right = true
		actions.append("right" if going_right else "left")
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		going_right = not going_right

	return actions


# 18. CROSS — travel all the way to the opposite wall, then all the way back.
func _gen_cross(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var target: int   = max_lane if start_lane * 2 <= max_lane else 0
	var dir: int      = 1 if target > lane else -1
	for _i in range(beat_count):
		if lane == target:
			dir = -dir
			target = max_lane - target
		actions.append("right" if dir > 0 else "left")
		lane = clamp(lane + dir, 0, max_lane)
	return actions


# 19. WALL_BRUSH — move to edge, jump there once, step back, do the other side.
func _gen_wall_brush(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	# Phase: 0=move to right wall, 1=jump at wall, 2=step back, 3=move to left wall, 4=jump, 5=step back
	var phase: int = 0
	for _i in range(beat_count):
		match phase:
			0:  # move right
				actions.append("right")
				lane = min(lane + 1, max_lane)
				if lane >= max_lane: phase = 1
			1:  # jump at right wall
				actions.append("jump")
				phase = 2
			2:  # step back left
				actions.append("left")
				lane = max(lane - 1, 0)
				phase = 3
			3:  # move left
				actions.append("left")
				lane = max(lane - 1, 0)
				if lane <= 0: phase = 4
			4:  # jump at left wall
				actions.append("jump")
				phase = 5
			5:  # step back right
				actions.append("right")
				lane = min(lane + 1, max_lane)
				phase = 0
	return actions


# 20. BREATHE_THEN_RUSH — slow drift first half, fast zigzag second half.
func _gen_breathe_then_rush(beat_count: int, start_lane: int) -> Array[String]:
	var half: int = beat_count >> 1
	var slow: Array[String] = _gen_breathe(half, start_lane)
	# Figure out lane after the slow section
	var lane: int = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	for a in slow:
		match a:
			"left":  lane = max(lane - 1, 0)
			"right": lane = min(lane + 1, max_lane)
	var fast: Array[String] = _gen_zigzag(beat_count - half, lane)
	slow.append_array(fast)
	return slow


# 21. RUSH_THEN_BREATHE — fast zigzag first half, slow drift second half.
func _gen_rush_then_breathe(beat_count: int, start_lane: int) -> Array[String]:
	var half: int = beat_count >> 1
	var fast: Array[String] = _gen_zigzag(half, start_lane)
	var lane: int = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	for a in fast:
		match a:
			"left":  lane = max(lane - 1, 0)
			"right": lane = min(lane + 1, max_lane)
	var slow: Array[String] = _gen_breathe(beat_count - half, lane)
	fast.append_array(slow)
	return fast


# 22. MIRROR — zigzag right for first half, then exact reverse sequence for second half.
func _gen_mirror(beat_count: int, start_lane: int) -> Array[String]:
	var half: int = beat_count >> 1
	var first: Array[String] = _gen_zigzag(half, start_lane)
	# Reverse: flip every left↔right
	var second: Array[String] = []
	for i in range(first.size() - 1, -1, -1):
		match first[i]:
			"left":  second.append("right")
			"right": second.append("left")
			_:       second.append(first[i])
	# Fill remaining beats if beat_count is odd
	for _i in range(beat_count - half - second.size()):
		second.append("jump")
	first.append_array(second)
	return first


# 23. CASCADE_LEFT — all leftward movement with slides every 3rd beat.
func _gen_cascade_left(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int = start_lane
	for i in range(beat_count):
		if i % 3 == 2:
			actions.append("slide")
		elif lane > 0:
			actions.append("left")
			lane = max(lane - 1, 0)
		else:
			actions.append("jump")   # already at left wall — mark with jump
	return actions


# 24. CASCADE_RIGHT — same but rightward.
func _gen_cascade_right(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	for i in range(beat_count):
		if i % 3 == 2:
			actions.append("slide")
		elif lane < max_lane:
			actions.append("right")
			lane = min(lane + 1, max_lane)
		else:
			actions.append("jump")
	return actions


# 25. SPRINT_SLIDE — sprint in one direction with one surprise slide in the middle.
func _gen_sprint_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var dir: int      = 1 if lane * 2 <= max_lane else -1
	var mid: int      = beat_count >> 1
	for i in range(beat_count):
		if i == mid:
			actions.append("slide")
		else:
			if lane >= max_lane: dir = -1
			elif lane <= 0:      dir =  1
			actions.append("right" if dir > 0 else "left")
			lane = clamp(lane + dir, 0, max_lane)
	return actions


# ── 26 new pattern generators ────────────────────────────────────────────────

# 26. TRIPLE_JUMP — three evenly-spaced jumps with zigzag lanes in between.
#     Always falls back gracefully when the phrase is too short.
func _gen_triple_jump(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int = _min_vert_gap()
	# Place jumps at 1/4, 1/2 and 3/4 of the phrase if there is room
	var slots: Array[int] = [beat_count / 4.0, beat_count / 2.0, beat_count * 3.0 / 4.0]
	var last_jump: int = -gap
	for s in slots:
		if s >= last_jump + gap and s < beat_count:
			actions[s] = "jump"
			last_jump  = s
	return actions


# 27. SYNCOPATED — irregular rhythm: two quick steps, one pause-step, repeat.
#     Feels "off-beat" without ever being physically impossible.
func _gen_syncopated(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var cycle_pos: int    = 0   # 0,1 = quick, 2 = pause (same direction as last)

	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false
		elif not going_right and lane <= 0:  going_right = true

		var action: String
		if cycle_pos < 2:
			action = "right" if going_right else "left"
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			if cycle_pos == 1:
				going_right = not going_right  # flip after the quick pair
		else:
			# Pause beat — lane step in the NEW direction without flipping again
			action = "right" if going_right else "left"
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)

		actions.append(action)
		cycle_pos = (cycle_pos + 1) % 3

	return actions


# 28. RUSH_SLIDE — full-speed sweep with a slide in the centre instead of a jump.
#     Variation on rush that trains the "slide on beat" muscle memory.
func _gen_rush_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int = _min_vert_gap()
	var mid: int = beat_count >> 1
	if beat_count >= gap * 2 + 1 and mid >= gap and (beat_count - 1 - mid) >= gap:
		actions[mid] = "slide"
	return actions


# 29. WAVE_WEAVE — slow sine-wave coast: glide fully to one wall, then fully to
#     the other over the phrase.  Calm, predictable, good recovery/breather.
func _gen_wave_weave(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	# We want to reach the far wall smoothly — use full sweeps back and forth
	for _i in range(beat_count):
		if going_right and lane >= max_lane:
			going_right = false
		elif not going_right and lane <= 0:
			going_right = true
		actions.append("right" if going_right else "left")
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
	return actions


# 30. BURST_RECOVER — first half is an aggressive rush (fast zigzag + jump),
#     second half is a slow breathe.  Creates a satisfying tension-release arc.
func _gen_burst_recover(beat_count: int, start_lane: int) -> Array[String]:
	var half: int = beat_count >> 1
	# Burst half: zigzag + a jump if there is room
	var burst: Array[String] = _gen_rush(half, start_lane)
	# Track where the lane ends up after the burst half
	var lane: int = start_lane
	for a in burst:
		match a:
			"left":  lane = max(lane - 1, 0)
			"right": lane = min(lane + 1, player.lane_xs.size() - 1)
	# Recover half: gentle breathe from that lane
	var rest: int  = beat_count - half
	var recover: Array[String] = _gen_breathe(rest, lane)
	burst.append_array(recover)
	return burst


# 31. SLIDE_CHAIN — slide every gap beats with zigzag fills between. Mirror of jump_chain.
func _gen_slide_chain(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		if i - last_vert >= gap:
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 32. SLIDE_WEAVE — slide on every Nth beat (gap-spaced), lane steps between.
func _gen_slide_weave(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(2, gap)
	var last_vert: int = -cycle
	for i in range(beat_count):
		var want_vert: bool = (i % cycle == cycle - 1)
		if want_vert and i - last_vert >= gap:
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 33. END_JUMP — zigzag throughout, single jump on the very last beat (if safe).
func _gen_end_jump(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int    = _min_vert_gap()
	var target: int = beat_count - 1
	if target >= gap:
		actions[target] = "jump"
	return actions


# 34. END_SLIDE — zigzag throughout, single slide on the very last beat (if safe).
func _gen_end_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int    = _min_vert_gap()
	var target: int = beat_count - 1
	if target >= gap:
		actions[target] = "slide"
	return actions


# 35. MARCH — lane step then jump in a strict cycle; rhythmic, predictable, satisfying.
func _gen_march(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(2, gap + 1)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 36. GALLOP — 2 steps forward then 1 step back; asymmetric 3-beat micro-phrase.
func _gen_gallop(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int    = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var primary: int = 1  # start drifting right
	for i in range(beat_count):
		var phase: int = i % 3
		if phase < 2:
			if (primary > 0 and lane >= max_lane) or (primary < 0 and lane <= 0):
				primary = -primary
			actions.append("right" if primary > 0 else "left")
			lane = clamp(lane + primary, 0, max_lane)
		else:
			var back: int = -primary
			actions.append("right" if back > 0 else "left")
			lane = clamp(lane + back, 0, max_lane)
	return actions


# 37. DIAMOND — RRLL repeating group; carves a wide diamond path across lanes.
func _gen_diamond(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var seq: Array[String] = ["right", "right", "left", "left"]
	for i in range(beat_count):
		var action: String = seq[i % 4]
		if action == "right" and lane >= max_lane: action = "left"
		elif action == "left"  and lane <= 0:       action = "right"
		actions.append(action)
		lane = clamp(lane + (1 if action == "right" else -1), 0, max_lane)
	return actions


# 38. ZIPPER — tight oscillation between 2 adjacent lanes; fast and narrow.
func _gen_zipper(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var max_lane: int = player.lane_xs.size() - 1
	var lane: int     = mini(start_lane, max_lane - 1)
	var going_right: bool = start_lane == lane
	for _i in range(beat_count):
		actions.append("right" if going_right else "left")
		going_right = not going_right
	return actions


# 39. SKIP3 — jump every 3rd beat, zigzag between; clear periodic punctuation.
func _gen_skip3(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(3, gap)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 40. SKIP3_SLIDE — slide every 3rd beat, zigzag between; mirror of skip3.
func _gen_skip3_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(3, gap)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 41. ALTERNATING_VERT — strictly alternates jump / slide with lane steps between.
func _gen_alternating_vert(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	var vert_idx: int  = 0
	for i in range(beat_count):
		if i - last_vert >= gap:
			actions.append("jump" if vert_idx % 2 == 0 else "slide")
			last_vert = i
			vert_idx += 1
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 42. THREE_PHASE — phrase split into thirds: breathe / zigzag / rush arc.
func _gen_three_phase(beat_count: int, start_lane: int) -> Array[String]:
	var third: int = maxi(1, beat_count / 3)
	var rest:  int = beat_count - third * 2
	var p1: Array[String] = _gen_breathe(third, start_lane)
	var lane1: int = start_lane
	for a in p1:
		match a:
			"left":  lane1 = max(lane1 - 1, 0)
			"right": lane1 = min(lane1 + 1, player.lane_xs.size() - 1)
	var p2: Array[String] = _gen_zigzag(third, lane1)
	var lane2: int = lane1
	for a in p2:
		match a:
			"left":  lane2 = max(lane2 - 1, 0)
			"right": lane2 = min(lane2 + 1, player.lane_xs.size() - 1)
	var p3: Array[String] = _gen_rush(rest, lane2)
	p1.append_array(p2)
	p1.append_array(p3)
	return p1


# 43. DOUBLE_JUMP — two jumps placed gap-apart near the middle, zigzag the rest.
func _gen_double_jump(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int  = _min_vert_gap()
	var mid: int  = beat_count >> 1
	var j1: int   = maxi(gap, mid - gap)
	var j2: int   = j1 + gap
	if j1 < beat_count:
		actions[j1] = "jump"
	if j2 < beat_count:
		actions[j2] = "jump"
	return actions


# 44. DOUBLE_SLIDE — two slides placed gap-apart near the middle, zigzag the rest.
func _gen_double_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = _gen_zigzag(beat_count, start_lane)
	var gap: int  = _min_vert_gap()
	var mid: int  = beat_count >> 1
	var s1: int   = maxi(gap, mid - gap)
	var s2: int   = s1 + gap
	if s1 < beat_count:
		actions[s1] = "slide"
	if s2 < beat_count:
		actions[s2] = "slide"
	return actions


# 45. LADDER_RIGHT — drift steadily right; jump when approaching right wall, wrap left.
func _gen_ladder_right(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var gap: int      = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		if lane >= max_lane - 1 and i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		elif lane >= max_lane:
			actions.append("left")
			lane = max(lane - 1, 0)
		else:
			actions.append("right")
			lane = min(lane + 1, max_lane)
	return actions


# 46. LADDER_LEFT — drift steadily left; jump when approaching left wall, wrap right.
func _gen_ladder_left(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var gap: int      = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		if lane <= 1 and i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
		elif lane <= 0:
			actions.append("right")
			lane = min(lane + 1, max_lane)
		else:
			actions.append("left")
			lane = max(lane - 1, 0)
	return actions


# 47. TRIPLE_SLIDE — 3 lane steps then a slide; clear 4-beat micro-phrase.
func _gen_triple_slide(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(gap + 1, 4)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 48. WIDE_ZIGZAG — 3 beats per direction before reversing; lazier sweep than breathe.
func _gen_wide_zigzag(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var held: int = 0
	for _i in range(beat_count):
		if going_right and lane >= max_lane: going_right = false; held = 0
		elif not going_right and lane <= 0:  going_right = true;  held = 0
		actions.append("right" if going_right else "left")
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
		held += 1
		if held >= 3:
			going_right = not going_right
			held = 0
	return actions


# 49. PINBALL — far-right → center → far-left → center → repeat; full-lane pinball.
func _gen_pinball(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int     = start_lane
	var max_lane: int = player.lane_xs.size() - 1
	var center: int   = max_lane / 2.0
	var targets: Array[int] = [max_lane, center, 0, center]
	var tidx: int = 0
	for _i in range(beat_count):
		var tgt: int = targets[tidx % 4]
		if lane == tgt:
			tidx += 1
			tgt = targets[tidx % 4]
		var action: String = "right" if tgt > lane else "left"
		actions.append(action)
		lane = clamp(lane + (1 if action == "right" else -1), 0, max_lane)
	return actions


# 50. SHIMMY — quick zigzag with a slide every 4th beat; groovy with periodic ducks.
func _gen_shimmy(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(gap + 1, 4)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if i > 0 and (i % cycle == 0) and (i - last_vert >= gap):
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 51. SPREAD — sweep outward to far wall, then converge back toward center.
func _gen_spread(beat_count: int, start_lane: int) -> Array[String]:
	var half: int     = beat_count >> 1
	var rest: int     = beat_count - half
	var max_lane: int = player.lane_xs.size() - 1
	var center: int   = max_lane / 2.0
	# Outward: sweep away from center
	var out: Array[String] = []
	var lane: int = start_lane
	var going_right: bool = lane <= center
	for _i in range(half):
		if going_right and lane >= max_lane: going_right = false
		elif not going_right and lane <= 0:  going_right = true
		out.append("right" if going_right else "left")
		lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
	# Inward: head toward center
	var inn: Array[String] = []
	for _i in range(rest):
		var action: String = "right" if lane < center else "left"
		if lane == center:
			action = "right" if going_right else "left"
		inn.append(action)
		lane = clamp(lane + (1 if action == "right" else -1), 0, max_lane)
	out.append_array(inn)
	return out


# 52. CENTER_SPRINT — race to center, jump there, then zigzag outward.
func _gen_center_sprint(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var center: int    = max_lane / 2.0
	var gap: int       = _min_vert_gap()
	var jumped: bool   = false
	var last_vert: int = -gap
	var going_right: bool = lane * 2 <= max_lane
	for i in range(beat_count):
		if not jumped and lane == center and i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
			jumped = true
		elif not jumped:
			var action: String = "right" if lane < center else "left"
			actions.append(action)
			lane = clamp(lane + (1 if action == "right" else -1), 0, max_lane)
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 53. JUMP_GALLOP — 2 lane steps + jump per cycle; gallop momentum with jump payout.
func _gen_jump_gallop(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(gap + 1, 3)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("jump")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


# 54. WAVE_JUMP — wall-to-wall sweep; jump placed at each wall touch.
func _gen_wave_jump(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var last_vert: int = -gap
	for i in range(beat_count):
		var at_wall: bool = (going_right and lane >= max_lane) or (not going_right and lane <= 0)
		if at_wall and i - last_vert >= gap:
			actions.append("jump")
			last_vert = i
			going_right = not going_right
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
	return actions


# 55. SLIDE_GALLOP — 2 lane steps + slide per cycle; gallop momentum with duck payout.
func _gen_slide_gallop(beat_count: int, start_lane: int) -> Array[String]:
	var actions: Array[String] = []
	var lane: int      = start_lane
	var max_lane: int  = player.lane_xs.size() - 1
	var going_right: bool = lane * 2 <= max_lane
	var gap: int       = _min_vert_gap()
	var cycle: int     = maxi(gap + 1, 3)
	var last_vert: int = -cycle
	for i in range(beat_count):
		if (i % cycle == cycle - 1) and (i - last_vert >= gap):
			actions.append("slide")
			last_vert = i
		else:
			if going_right and lane >= max_lane: going_right = false
			elif not going_right and lane <= 0:  going_right = true
			actions.append("right" if going_right else "left")
			lane = clamp(lane + (1 if going_right else -1), 0, max_lane)
			going_right = not going_right
	return actions


func _build_all_gate_visuals() -> void:
	for c in gates_root.get_children():
		c.queue_free()

	gate_nodes.clear()
	gate_judged.clear()
	gate_success.clear()
	gate_world_zs.clear()
	gate_culled.clear()
	_gate_animated.clear()

	_judge_index = 0
	_vis_start_idx = 0
	_world_index = 0
	_gameplay_pulse_index = 0
	_song_finish_pending = false

	for i in range(runner_plan.size()):
		var entry: Dictionary = runner_plan[i]
		var gate: Node3D = _build_gate_visual(entry, i)
		gates_root.add_child(gate)
		gate_nodes.append(gate)
		gate_judged.append(false)
		gate_success.append(false)
		gate_world_zs.append(gate.global_position.z)
		_gate_animated.append(false)

	# WJ geometry is now spawned path-aware in _spawn_wj_geometry_on_path() after
	# _build_track_path(), so _spawn_section_geometry() is no longer called here.

func _build_gate_visual(entry: Dictionary, gate_index: int) -> Node3D:
	var root: Node3D = Node3D.new()
	var t_s: float     = float(entry.get("t", 0.0))
	var action: String = String(entry.get("action", "jump"))
	var post_lane: int = int(entry.get("post_lane", 1))

	root.position.z = t_s * player.forward_speed
	root.visible = false   # hidden until _update_gate_visibility brings it into range

	var tint: Color = _action_color(action)
	var tw: float   = _track_full_width()

	# All meshes go inside VisRoot so the spawn animation can scale them
	# independently of the judge Area3D (which stays on root).
	var vis_root := Node3D.new()
	vis_root.name = "VisRoot"
	# Electric zones: start paused so arc tweens don't run on every off-screen gate.
	# _update_gate_visibility flips this to INHERIT when the gate enters range.
	if _is_electric_at(t_s):
		vis_root.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(vis_root)

	# Authored Blender gate pieces take priority; procedural visuals are the fallback.
	if not _spawn_authored_gate(vis_root, action, post_lane, tw):
		if _is_electric_at(t_s):
			match action:
				"left", "right":           _vis_elec_lane_gate(vis_root, post_lane, tint, tw)
				"jump":                    _vis_elec_jump_gate(vis_root, tint, tw)
				"slide":                   _vis_elec_slide_gate(vis_root, tint, tw)
				"wall_left", "wall_right": _vis_elec_wall_gate(vis_root, action, tint)
		else:
			match action:
				"left", "right":           _vis_lane_gate(vis_root, post_lane, tint, tw)
				"jump":                    _vis_jump_gate(vis_root, tint, tw)
				"slide":                   _vis_slide_gate(vis_root, tint, tw)
				"wall_left", "wall_right": _vis_wall_gate(vis_root, action, tint)

	_add_gate_judge_area(root, gate_index, action, post_lane)
	return root


## Build a gate's visuals from authored Blender pieces when they exist.
## Returns true when authored pieces fully replaced the procedural visuals.
## jump → "hurdle" · slide → "slide" · lane gates → "blocker" (+ optional
## "arch" on the safe lane) · wall gates → "wj_plate".
func _spawn_authored_gate(vis_root: Node3D, action: String, safe_lane: int,
		tw: float) -> bool:
	if _piece_lib == null:
		return false
	match action:
		"jump":
			var e: Dictionary = _piece_lib.first_of("hurdle")
			if e.is_empty():
				return false
			_add_authored_piece(vis_root, e, Vector3.ZERO)
			return true
		"slide":
			var e: Dictionary = _piece_lib.first_of("slide")
			if e.is_empty():
				return false
			_add_authored_piece(vis_root, e, Vector3.ZERO)
			return true
		"left", "right":
			# Pick the variant matching the gate direction ("left" = pink gates,
			# "right" = blue in the procedural look); generic blockers cover both.
			var blocker: Dictionary = _piece_lib.variant_of("blocker", action)
			if blocker.is_empty():
				return false
			for ln in range(player.lane_xs.size()):
				if ln != safe_lane:
					_add_authored_piece(vis_root, blocker,
						Vector3(player.lane_xs[ln], 0.0, 0.0))
			var arch: Dictionary = _piece_lib.first_of("arch")
			if not arch.is_empty():
				_add_authored_piece(vis_root, arch,
					Vector3(player.lane_xs[safe_lane], 0.0, 0.0))
			# Safe-lane floor cues — authored strip/marks join the blocker
			# (both helpers fall back to nothing extra only if unauthored,
			# keeping fully-authored gates free of procedural boxes).
			if _piece_lib.has_type("strip"):
				vis_root.add_child(_make_safe_strip(player.lane_xs[safe_lane],
					_action_color(action)))
			if _piece_lib.has_type("marks"):
				_make_approach_marks(vis_root, player.lane_xs[safe_lane],
					lane_blocker_width * 0.80, _action_color(action))
			return true
		"wall_left", "wall_right":
			var plate: Dictionary = _piece_lib.first_of("wj_plate")
			if plate.is_empty():
				return false
			var wall_sign: float = -1.0 if action == "wall_left" else 1.0
			var inst: Node3D = _add_authored_piece(vis_root, plate,
				Vector3(wall_sign * tw * 0.5, lane_blocker_height * 0.78, 0.0))
			if wall_sign > 0.0:
				inst.rotation_degrees.y += 180.0   # face inward from the right wall
			return true
	return false


## Instance an authored piece under `parent` at a local offset. The 180° yaw
## maps the piece's Blender forward (−Z after import) onto the gate/track +Z.
func _add_authored_piece(parent: Node3D, entry: Dictionary, pos: Vector3) -> Node3D:
	var inst: Node3D = _piece_lib.instance(entry)
	inst.position = pos
	inst.rotation_degrees.y = 180.0
	parent.add_child(inst)
	return inst


## Collect the emissive StandardMaterial3D surfaces under `node` (an instanced authored
## piece) so they can be beat-pulsed. Materials are made unique (one copy per distinct source
## material, shared across instances) so the pulse is isolated and the per-frame list stays
## small. Non-emissive surfaces and ShaderMaterials are left alone.
func _register_track_emissives(node: Node) -> void:
	if node == null:
		return
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var src := mi.get_active_material(s) as StandardMaterial3D
				if src == null or not src.emission_enabled:
					continue
				var key: int = src.get_instance_id()
				var uniq: StandardMaterial3D
				if _track_mat_seen.has(key):
					uniq = _track_mat_seen[key]
				else:
					uniq = src.duplicate()
					_track_mat_seen[key] = uniq
					_world_track_mats.append(uniq)
					_world_track_base_e.append(maxf(0.05, uniq.emission_energy_multiplier))
				mi.set_surface_override_material(s, uniq)
		for c in n.get_children():
			stack.append(c)


## Like _register_track_emissives, but the unique material duplicates go into a
## caller-chosen pulse list (_world_pad_mats, _city_bldg_mats, _world_rail_mats, …)
## so authored deco pieces pulse with the same beat driver as their procedural
## counterparts. Only emission ENERGY is driven — colours stay yours.
func _register_piece_emissives(node: Node, into: Array) -> void:
	if node == null:
		return
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var src := mi.get_active_material(s) as StandardMaterial3D
				if src == null or not src.emission_enabled:
					continue
				var key: int = src.get_instance_id()
				var uniq: StandardMaterial3D
				if _piece_mat_seen.has(key):
					uniq = _piece_mat_seen[key]
				else:
					uniq = src.duplicate()
					_piece_mat_seen[key] = uniq
				mi.set_surface_override_material(s, uniq)
				if not into.has(uniq):
					into.append(uniq)
		for c in n.get_children():
			stack.append(c)


## Union AABB (in `root`-local space) of every MeshInstance3D under `root`. If `name_has`
## is non-empty, only meshes whose node name contains it (case-insensitive) are merged.
## Used to MEASURE an authored kit so the generated jumps are fit to its real geometry
## instead of trusting metadata. Returns a zero-size AABB when nothing matches.
func _piece_local_aabb(root: Node3D, name_has: String = "") -> AABB:
	var acc: AABB = AABB()
	var has: bool = false
	var stack: Array = []
	for c in root.get_children():
		var cxf: Transform3D = (c as Node3D).transform if c is Node3D else Transform3D.IDENTITY
		stack.append({"node": c, "xf": cxf})
	while not stack.is_empty():
		var it: Dictionary = stack.pop_back()
		var node: Node = it["node"]
		var xf: Transform3D = it["xf"]
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			if name_has == "" or String(node.name).to_lower().contains(name_has):
				var a: AABB = xf * (node as MeshInstance3D).mesh.get_aabb()
				if not has:
					acc = a
					has = true
				else:
					acc = acc.merge(a)
		for cc in node.get_children():
			var ccxf: Transform3D = xf * ((cc as Node3D).transform if cc is Node3D else Transform3D.IDENTITY)
			stack.append({"node": cc, "xf": ccxf})
	return acc if has else AABB()


# Returns the full visual width of the track (outer edge to outer edge).
func _track_full_width() -> float:
	if player.lane_xs.size() < 2:
		return lane_blocker_width
	return (player.lane_xs[player.lane_xs.size() - 1] - player.lane_xs[0]) + lane_blocker_width



## Returns the tint colour for each gate action type.
func _action_color(action: String) -> Color:
	match action:
		"left":       return Color(1.00, 0.35, 0.65, 1.0)  # pink
		"right":      return Color(0.30, 0.65, 1.00, 1.0)  # blue
		"jump":       return Color(0.30, 1.00, 0.55, 1.0)  # green
		"slide":      return Color(0.0, 0.821, 0.729, 1.0)  # orange
		"wall_left":  return Color(1.00, 0.55, 0.10, 1.0)  # orange
		"wall_right": return Color(1.00, 0.55, 0.10, 1.0)  # orange
	return Color(0.85, 0.85, 0.85, 1.0)

# ── Left / Right gate ───────────────────────────────────────────────────────
# Solid walls block the wrong lanes. The safe lane has an open corridor with
# a glowing floor strip and a connecting top-beam tying the walls together.

func _vis_lane_gate(root: Node3D, safe_lane: int, tint: Color, _tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Collect blocked lane indices and group consecutive runs into merged walls.
	var blocked: Array[int] = []
	for ln in range(player.lane_xs.size()):
		if ln != safe_lane:
			blocked.append(ln)

	# Each consecutive group of blocked lanes becomes one building facade.
	var gi: int = 0
	while gi < blocked.size():
		var group_start: int = gi
		while gi + 1 < blocked.size() and blocked[gi + 1] == blocked[gi] + 1:
			gi += 1
		var group_end: int = gi

		var x_left:  float = player.lane_xs[blocked[group_start]]
		var x_right: float = player.lane_xs[blocked[group_end]]
		var cx:      float = (x_left + x_right) * 0.5
		var wall_w:  float = (x_right - x_left) + lane_blocker_width

		# Building facade — dark body + horizontal neon window strips + rooftop cap
		var facade := _make_bldg_facade(
			Vector3(cx, lane_blocker_height * 0.5, 0.0),
			Vector3(wall_w, lane_blocker_height, gate_depth),
			tint, 0.12, 0.45)
		root.add_child(facade)

		gi += 1

	# Neon arch frames the safe-lane opening — the portal the player runs through
	var safe_x: float = player.lane_xs[safe_lane]
	_make_gate_arch(root, safe_x, lane_blocker_width * 0.88,
		0.0, lane_blocker_height, bright)

	# Approach runway marks aimed at the safe lane
	_make_approach_marks(root, safe_x, lane_blocker_width * 0.80, tint)

	# Glowing floor strip in the safe lane — tells the player exactly where to go
	root.add_child(_make_safe_strip(safe_x, bright))


# ── Jump gate ───────────────────────────────────────────────────────────────
# A full-width ground barrier spans all lanes — player must jump over it.
# Upward chevrons above it make the "jump" intent unambiguous at speed.

func _vis_jump_gate(root: Node3D, tint: Color, tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Low building barrier — the obstacle the player jumps over.
	var barrier_facade := _make_bldg_facade(
		Vector3(0.0, jump_hurdle_height * 0.5, 0.0),
		Vector3(tw, jump_hurdle_height, gate_depth),
		tint, 0.11, 0.40)
	root.add_child(barrier_facade)

	# Tall skyscraper towers flanking the gate — same building language as the
	# city backdrop, making the gate feel like it's part of the cityscape.
	# strip_gap 0.90 keeps each tower to ~4 strips max regardless of height.
	var tower_w: float = 1.0
	var tower_h: float = jump_hurdle_height * 3.2
	for side in [-1, 1]:
		var tower := _make_bldg_facade(
			Vector3(side * (tw * 0.5 + tower_w * 0.5 + 0.08), tower_h * 0.5, 0.0),
			Vector3(tower_w, tower_h, gate_depth * 0.75),
			tint.lightened(0.08), 0.10, 0.90)
		root.add_child(tower)

	# Neon arch framing the airspace the player clears on a good jump.
	# Sits just above the barrier top — clear landmark that says "jump through here".
	_make_gate_arch(root, 0.0, tw, jump_hurdle_height, jump_hurdle_height + 2.0, tint)

	# Floor approach marks — three hash lines leading up to the barrier
	_make_approach_marks(root, 0.0, tw, tint)

	# Upward V-chevrons — neon arrow signs on the face of the barrier building
	var chev_size: Vector3 = Vector3(tw * 0.42, 0.11, gate_depth * 0.5)
	var chev_y: float      = jump_hurdle_height + 0.40
	var chev_offset: float = tw * 0.17

	var chev_l := _make_box_mesh(chev_size, bright)
	chev_l.position   = Vector3(-chev_offset, chev_y, -gate_depth * 0.5 - 0.05)
	chev_l.rotation.z = deg_to_rad(32.0)
	root.add_child(chev_l)

	var chev_r := _make_box_mesh(chev_size, bright)
	chev_r.position   = Vector3(chev_offset, chev_y, -gate_depth * 0.5 - 0.05)
	chev_r.rotation.z = deg_to_rad(-32.0)
	root.add_child(chev_r)

	# Second smaller chevron above — stacked arrow for readability at speed
	var chev2_l := _make_box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
	chev2_l.position   = Vector3(-chev_offset * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
	chev2_l.rotation.z = deg_to_rad(32.0)
	root.add_child(chev2_l)

	var chev2_r := _make_box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
	chev2_r.position   = Vector3(chev_offset * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
	chev2_r.rotation.z = deg_to_rad(-32.0)
	root.add_child(chev2_r)


# ── Slide gate ──────────────────────────────────────────────────────────────
# A full-width overhead beam spans all lanes — player must slide under it.
# Side pillars support the beam and make it look like a real low obstacle.

func _vis_slide_gate(root: Node3D, tint: Color, tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Clearance edge — bottom of the solid overhead wall.
	var clearance_y: float = slide_bar_y - slide_bar_height * 0.5

	# Overhead building facade — the low-ceiling slab the player slides under.
	var solid_h:  float = lane_blocker_height - clearance_y
	var solid_cy: float = clearance_y + solid_h * 0.5
	var overhead_facade := _make_bldg_facade(
		Vector3(0.0, solid_cy, 0.0),
		Vector3(tw, solid_h, gate_depth),
		tint, 0.10, 0.50)
	root.add_child(overhead_facade)

	# Tall flanking towers — frame the gate like a city overpass
	var tower_w: float = 1.0
	var tower_h: float = lane_blocker_height * 1.6
	for side in [-1, 1]:
		var tower := _make_bldg_facade(
			Vector3(side * (tw * 0.5 + tower_w * 0.5 + 0.08), tower_h * 0.5, 0.0),
			Vector3(tower_w, tower_h, gate_depth * 0.75),
			tint.lightened(0.08), 0.10, 0.90)
		root.add_child(tower)

	# Neon arch framing the crawl zone — shows the player exactly the safe gap
	_make_gate_arch(root, 0.0, tw, 0.0, clearance_y, tint)

	# Floor approach marks leading to the slide zone
	_make_approach_marks(root, 0.0, tw, tint)

	# Bright limbo bar — the dangerous bottom edge the player has to duck below
	var bar := _make_box_mesh(
		Vector3(tw + 0.06, 0.10, gate_depth + 0.06), bright)
	bar.position = Vector3(0.0, clearance_y, 0.0)
	root.add_child(bar)

	# Downward-pointing indicator below the limbo bar — "duck here" signal
	for side: float in [-1.0, 0.0, 1.0]:
		var arr := _make_box_mesh(Vector3(0.08, clearance_y * 0.35, 0.06), bright)
		arr.position = Vector3(side * tw * 0.28, clearance_y * 0.5, -gate_depth * 0.5 - 0.04)
		root.add_child(arr)

	# Ground floor strip — shows the safe crawl zone beneath the facade
	var floor_strip := _make_box_mesh(
		Vector3(tw, 0.04, gate_depth * 0.6), bright)
	floor_strip.position = Vector3(0.0, 0.02, 0.0)
	root.add_child(floor_strip)


func _vis_wall_gate(root: Node3D, action: String, tint: Color) -> void:
	# In a wall_jump section the corridor walls provide the main structural visual.
	# Individual beat gates are large glowing face-plates flush with the corridor wall's
	# inner surface, with directional chevrons so the player knows where to jump.
	var tw: float      = _track_full_width()
	var half_tw: float = tw * 0.5
	var is_left: bool  = (action == "wall_left")
	# wall_sign: -1 for left wall (face at -half_tw), +1 for right wall (face at +half_tw)
	var wall_sign: float = -1.0 if is_left else 1.0
	var face_x: float    = wall_sign * half_tw
	# inward: direction from wall toward track centre
	var inward: float    = -wall_sign

	# Large glowing plate — wide enough to read at a glance
	var plate: MeshInstance3D = _make_box_mesh(
		Vector3(0.38, lane_blocker_height * 1.55, gate_depth * 2.0),
		tint
	)
	plate.position = Vector3(face_x, lane_blocker_height * 0.78, 0.0)
	var pmat: StandardMaterial3D = plate.material_override as StandardMaterial3D
	if pmat != null:
		pmat.emission_energy_multiplier = 4.2
	root.add_child(plate)

	# Point light so it casts colour onto the surrounding corridor
	var pl := OmniLight3D.new()
	pl.light_color  = tint
	pl.light_energy = 1.0
	pl.omni_range   = 9.0
	pl.position = Vector3(face_x + inward * 0.4, lane_blocker_height * 0.78, 0.0)
	root.add_child(pl)

	# Directional chevrons pointing inward — larger than before
	var chev_size: Vector3  = Vector3(0.14, lane_blocker_height * 0.38, gate_depth * 0.55)
	var chev_cx: float      = face_x + inward * 0.55
	var cy: float           = lane_blocker_height * 0.78
	var chev_off: float     = lane_blocker_height * 0.17

	var bright: Color = tint.lightened(0.04)
	var chev_top: MeshInstance3D = _make_box_mesh(chev_size, bright)
	chev_top.position = Vector3(chev_cx, cy + chev_off, 0.0)
	chev_top.rotation.z = deg_to_rad(-wall_sign * 30.0)
	var ctmat: StandardMaterial3D = chev_top.material_override as StandardMaterial3D
	if ctmat != null: ctmat.emission_energy_multiplier = 5.5
	root.add_child(chev_top)

	var chev_bot: MeshInstance3D = _make_box_mesh(chev_size, bright)
	chev_bot.position = Vector3(chev_cx, cy - chev_off, 0.0)
	chev_bot.rotation.z = deg_to_rad(wall_sign * 30.0)
	var cbmat: StandardMaterial3D = chev_bot.material_override as StandardMaterial3D
	if cbmat != null: cbmat.emission_energy_multiplier = 5.5
	root.add_child(chev_bot)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ELECTRIC THEME — obstacles + environment                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── Arc helper ──────────────────────────────────────────────────────────────────
# Four pre-built zigzag "frames" cycle at irregular intervals — the shape snaps
# like real lightning that never holds one form.  A spark sweeps left↔right with
# its own light, so coloured light travels across nearby geometry.
func _make_elec_arc(parent: Node3D, from_x: float, to_x: float, y: float,
		tint: Color, seg_count: int = 8, z_pos: float = 0.0) -> StandardMaterial3D:

	# Shared material — all frames use this; crackle tween drives emission
	var mat := StandardMaterial3D.new()
	mat.albedo_color               = Color.WHITE
	mat.emission_enabled           = true
	mat.emission                   = tint.lightened(0.4)
	mat.emission_energy_multiplier = 7.0

	# Four distinct zigzag shapes — snapping between them mimics lightning reshaping
	var zz_variants: Array = [
		[0.0,  0.18, -0.12,  0.22, -0.16,  0.14, -0.20,  0.10,  0.0],
		[0.0, -0.16,  0.20, -0.08,  0.18, -0.24,  0.12, -0.15,  0.0],
		[0.0,  0.22, -0.18,  0.10, -0.22,  0.16, -0.08,  0.20,  0.0],
		[0.0, -0.10,  0.24, -0.20,  0.08, -0.18,  0.22, -0.12,  0.0],
	]
	# Irregular display durations — organic, not metronomic
	var frame_times: Array[float] = [0.055, 0.040, 0.070, 0.045]

	var frame_roots: Array[Node3D] = []
	var seg_w: float = (to_x - from_x) / float(seg_count)

	for fi in range(zz_variants.size()):
		var fr := Node3D.new()
		fr.visible = (fi == 0)
		parent.add_child(fr)
		frame_roots.append(fr)

		var zz: Array  = zz_variants[fi]
		var px: float  = from_x
		var py: float  = y + float(zz[0])

		for i in range(seg_count):
			var nx: float  = from_x + seg_w * float(i + 1)
			var ny: float  = y + float(zz[mini(i + 1, zz.size() - 1)])
			var cx: float  = (px + nx) * 0.5
			var cy_: float = (py + ny) * 0.5
			var dx: float  = nx - px
			var dy: float  = ny - py

			var seg := MeshInstance3D.new()
			# Shared unit mesh — scale X instead of allocating a new BoxMesh per segment.
			# Godot 4 can GPU-instance all segments that share this resource.
			if _elec_seg_mesh == null:
				_elec_seg_mesh = BoxMesh.new()
				_elec_seg_mesh.size = Vector3(1.0, 0.055, 0.055)
			seg.mesh = _elec_seg_mesh
			seg.scale.x = sqrt(dx*dx + dy*dy)
			seg.material_override = mat
			seg.position = Vector3(cx, cy_, z_pos)
			seg.rotation.z = atan2(dy, dx)
			fr.add_child(seg)

			px = nx
			py = ny

	# Frame-flip tween — show each frame for its irregular interval, then next.
	# .bind() pins the target index at tween-build time (safe lambda capture).
	var n_frames: int = frame_roots.size()
	var flip_tween := parent.create_tween().set_loops()
	for fi in range(n_frames):
		flip_tween.tween_interval(frame_times[fi])
		var next_fi: int = (fi + 1) % n_frames
		var cb := func(idx: int, roots: Array) -> void:
			for k in range(roots.size()):
				roots[k].visible = (k == idx)
		flip_tween.tween_callback(cb.bind(next_fi, frame_roots))

	# Background crackle on the shared material
	var energies: Array[float] = [7.0, 12.0, 5.0, 10.0, 6.5, 13.0, 4.5, 9.0, 7.5, 11.0]
	var times:    Array[float] = [0.06, 0.03, 0.08, 0.04, 0.065, 0.025, 0.09, 0.04, 0.05, 0.03]
	var ctw := parent.create_tween().set_loops()
	for ei in range(energies.size()):
		ctw.tween_property(mat, "emission_energy_multiplier", energies[ei], times[ei])

	# Traveling spark — sweeps X while frames snap, giving the illusion the spark
	# is always riding a different wire.  Carries OmniLight3D so light moves too.
	var spark := MeshInstance3D.new()
	var sm    := SphereMesh.new()
	sm.radius = 0.08; sm.height = 0.16
	spark.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.albedo_color               = Color.WHITE
	smat.emission_enabled           = true
	smat.emission                   = tint.lightened(0.6)
	smat.emission_energy_multiplier = 25.0
	spark.material_override = smat
	spark.position = Vector3(from_x, y, z_pos)
	parent.add_child(spark)

	# Traveling light — child of spark so it follows automatically; smaller range
	# than before so it only illuminates immediately surrounding geometry.
	var sl := OmniLight3D.new()
	sl.light_color  = tint
	sl.light_energy = 5.0
	sl.omni_range   = 2.5
	spark.add_child(sl)
	# Register in pulse array so the beat flash also hits the traveling light.
	_elec_arc_lights.append(sl)

	var stw := parent.create_tween().set_loops()
	stw.tween_property(spark, "position:x", to_x,   0.20).set_trans(Tween.TRANS_LINEAR)
	stw.tween_property(spark, "position:x", from_x, 0.20).set_trans(Tween.TRANS_LINEAR)

	# No static ambient fill light — the emissive material + traveling spark
	# are sufficient; one fewer OmniLight3D per arc = significant GPU savings.
	return mat


# Slim dark-metal fence post at local origin; caller must set .position.x
# Authored "fence_post" pieces replace the procedural box, stretched to `height`.
func _make_fence_post(height: float) -> Node3D:
	var entry: Dictionary = (_piece_lib.first_of("fence_post") if _piece_lib != null else {})
	if not entry.is_empty():
		var auth_h: float = maxf(0.1, float(entry.params.get("height", 2.5)))
		var wrap := Node3D.new()
		var inst: Node3D = _piece_lib.instance(entry)
		inst.rotation_degrees.y = 180.0
		inst.scale.y = height / auth_h
		wrap.add_child(inst)
		return wrap

	var post := MeshInstance3D.new()
	var bm   := BoxMesh.new()
	bm.size  = Vector3(0.14, height, 0.14)
	post.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.14, 0.18, 1.0)
	mat.metallic     = 0.80
	mat.roughness    = 0.30
	post.material_override = mat
	post.position.y = height * 0.5
	return post


# ── Electric lane gate (left / right) ────────────────────────────────────────
# Fence posts on blocked lane edges; arcing electricity spans the blocked span.
# Safe lane keeps approach marks + floor strip just like the city theme.
func _vis_elec_lane_gate(root: Node3D, safe_lane: int, tint: Color, _tw: float) -> void:
	var blocked: Array[int] = []
	for ln in range(player.lane_xs.size()):
		if ln != safe_lane:
			blocked.append(ln)

	var gi: int = 0
	while gi < blocked.size():
		var group_start: int = gi
		while gi + 1 < blocked.size() and blocked[gi + 1] == blocked[gi] + 1:
			gi += 1
		var group_end: int = gi

		var x_left:  float = player.lane_xs[blocked[group_start]] - lane_blocker_width * 0.5
		var x_right: float = player.lane_xs[blocked[group_end]]   + lane_blocker_width * 0.5

		# Fence posts at group edges
		for px: float in [x_left, x_right]:
			var post := _make_fence_post(lane_blocker_height)
			post.position.x = px
			root.add_child(post)

		# Mid-height arc
		_make_elec_arc(root, x_left, x_right, lane_blocker_height * 0.52, tint)
		# Upper arc near post caps
		_make_elec_arc(root, x_left, x_right, lane_blocker_height * 0.90, tint, 6, -0.02)

		gi += 1

	# Safe-lane cues (same as city theme)
	var safe_x: float = player.lane_xs[safe_lane]
	_make_gate_arch(root, safe_x, lane_blocker_width * 0.88, 0.0, lane_blocker_height, tint)
	_make_approach_marks(root, safe_x, lane_blocker_width * 0.80, tint)
	root.add_child(_make_safe_strip(safe_x, tint))


# ── Electric jump gate ────────────────────────────────────────────────────────
# Low live-wire arc across the full track — player jumps over it.
func _vis_elec_jump_gate(root: Node3D, tint: Color, tw: float) -> void:
	var from_x: float = -tw * 0.5 - 0.4
	var to_x:   float =  tw * 0.5 + 0.4
	var bright: Color = tint.lightened(0.06)

	# Outer frame posts
	for px: float in [from_x - 0.1, to_x + 0.1]:
		var post := _make_fence_post(lane_blocker_height)
		post.position.x = px
		root.add_child(post)

	# The low arc the player must jump over
	_make_elec_arc(root, from_x, to_x, jump_hurdle_height * 0.55, tint)
	# Ground crackle — low voltage context strip
	_make_elec_arc(root, from_x, to_x, jump_hurdle_height * 0.20, tint, 6, 0.02)

	# Upward V-chevrons (same read as city jump gate)
	var chev_size: Vector3 = Vector3(tw * 0.42, 0.11, gate_depth * 0.5)
	var chev_y: float      = jump_hurdle_height + 0.40
	var chev_off: float    = tw * 0.17
	for sign: float in [-1.0, 1.0]:
		var chev := _make_box_mesh(chev_size, bright)
		chev.position   = Vector3(sign * chev_off, chev_y, -gate_depth * 0.5 - 0.05)
		chev.rotation.z = deg_to_rad(-sign * 32.0)
		root.add_child(chev)
		var chev2 := _make_box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
		chev2.position   = Vector3(sign * chev_off * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
		chev2.rotation.z = deg_to_rad(-sign * 32.0)
		root.add_child(chev2)

	_make_approach_marks(root, 0.0, tw, tint)


# ── Electric slide gate ───────────────────────────────────────────────────────
# High overhead live-wire arc — player slides under it.
func _vis_elec_slide_gate(root: Node3D, tint: Color, tw: float) -> void:
	# Visual bar sits higher than the physics clearance so it reads unambiguously
	# as "ceiling overhead" rather than "low wire on ground". The hitbox is still
	# governed by slide_bar_y in the physics — this is display only.
	var clearance_y: float = lane_blocker_height * 0.82   # ~2.05 — clearly overhead
	var from_x: float = -tw * 0.5 - 0.4
	var to_x:   float =  tw * 0.5 + 0.4
	var bright: Color = tint.lightened(0.06)

	# SHORT posts — only up to clearance_y, NOT full height.
	# This is the key visual distinction from the jump gate:
	# jump = tall posts + low wire at ground (go OVER)
	# slide = short posts + ceiling wire at head height (go UNDER)
	for px: float in [from_x - 0.1, to_x + 0.1]:
		var post := _make_fence_post(clearance_y)
		post.position.x = px
		root.add_child(post)

	# Solid limbo bar at clearance_y — the hard electric ceiling
	var bar := _make_box_mesh(Vector3(tw + 0.10, 0.10, gate_depth + 0.10), bright)
	bar.position = Vector3(0.0, clearance_y, 0.0)
	var bmat := bar.material_override as StandardMaterial3D
	if bmat != null: bmat.emission_energy_multiplier = 5.5
	root.add_child(bar)

	# Live-wire arcs sizzling along the bar (on top of the solid obstacle)
	_make_elec_arc(root, from_x, to_x, clearance_y + 0.06, tint)
	_make_elec_arc(root, from_x, to_x, clearance_y + 0.22, tint, 6, -0.02)

	# Large downward-pointing chevrons — "DUCK DOWN" signal
	var chev_h: float  = clearance_y * 0.40
	var chev_offset: float = tw * 0.22
	for sign: float in [-1.0, 0.0, 1.0]:
		var chev := _make_box_mesh(Vector3(0.10, chev_h, 0.07), bright)
		chev.position = Vector3(sign * chev_offset, clearance_y * 0.45, -gate_depth * 0.5 - 0.05)
		root.add_child(chev)

	# Floor strip — bright crawl zone marker
	var floor_strip := _make_box_mesh(Vector3(tw, 0.05, gate_depth * 0.7), bright)
	floor_strip.position = Vector3(0.0, 0.025, 0.0)
	var fsmat := floor_strip.material_override as StandardMaterial3D
	if fsmat != null: fsmat.emission_energy_multiplier = 2.5
	root.add_child(floor_strip)

	_make_approach_marks(root, 0.0, tw, tint)


# ── Electric wall gate ────────────────────────────────────────────────────────
# Stacked horizontal arcs on the correct corridor wall — wall-jump target.
func _vis_elec_wall_gate(root: Node3D, action: String, tint: Color) -> void:
	var tw: float        = _track_full_width()
	var half_tw: float   = tw * 0.5
	var is_left: bool    = (action == "wall_left")
	var wall_sign: float = -1.0 if is_left else 1.0
	var face_x: float    = wall_sign * half_tw
	var inward: float    = -wall_sign

	# Wall post / anchor
	var post := _make_fence_post(lane_blocker_height * 1.6)
	post.position.x = face_x
	root.add_child(post)

	# Three stacked horizontal arcs extending inward from wall face
	var arc_ys: Array[float] = [
		lane_blocker_height * 0.38,
		lane_blocker_height * 0.78,
		lane_blocker_height * 1.18,
	]
	var arm_len: float = 0.90
	for ay: float in arc_ys:
		var ax0: float = face_x
		var ax1: float = face_x + inward * arm_len
		_make_elec_arc(root, minf(ax0, ax1), maxf(ax0, ax1), ay, tint, 5, 0.0)

	# Colour light thrown into the corridor
	var light := OmniLight3D.new()
	light.light_color  = tint
	light.light_energy = 1.0
	light.omni_range   = 9.0
	light.position     = Vector3(face_x + inward * 0.5, lane_blocker_height * 0.78, 0.0)
	root.add_child(light)


# ── Electric environment ──────────────────────────────────────────────────────
# High-voltage transmission pylons with glowing insulator tips replace city
# buildings.  Tip glows pulse gently on beat; obstacle arcs pulse hard.
func _spawn_electric_environment() -> void:
	var end_z: float = _song_end_z()
	var tw:    float = _track_full_width()
	const PYLON_SPACING: float = 55.0
	var pylon_count: int = maxi(4, int(end_z / PYLON_SPACING))

	var body_col: Color = Color(0.10, 0.12, 0.16, 1.0)

	var arc_palette: Array[Color] = [
		Color(0.20, 0.80, 1.00),  # electric blue
		Color(0.85, 0.25, 1.00),  # violet
		Color(0.25, 1.00, 0.60),  # neon green
		Color(1.00, 0.85, 0.10),  # electric yellow
	]

	var pylon_dist: float = tw * 0.5 + 14.0   # lateral distance to pole centre
	var pylon_h:    float = 22.0
	var arm_reach:  float = 10.0               # inward arm length

	# ── Shared pylon meshes (built once, instanced across all pylons) ──────────
	if _pylon_pole_mesh == null:
		_pylon_pole_mesh       = BoxMesh.new()
		_pylon_pole_mesh.size  = Vector3(0.50, pylon_h, 0.50)
	if _pylon_brace_mesh == null:
		_pylon_brace_mesh      = BoxMesh.new()
		_pylon_brace_mesh.size = Vector3(0.18, pylon_h * 0.62, 0.18)
	if _pylon_beam_mesh == null:
		_pylon_beam_mesh       = BoxMesh.new()
		_pylon_beam_mesh.size  = Vector3(arm_reach, 0.32, 0.32)
	if _pylon_glow_mesh == null:
		_pylon_glow_mesh        = SphereMesh.new()
		_pylon_glow_mesh.radius = 0.30
		_pylon_glow_mesh.height = 0.60
	# Shared materials — same colour on every pylon, so all poles/braces/beams
	# with the same material share a draw call via GPU instancing.
	if _pylon_pole_mat == null:
		_pylon_pole_mat              = StandardMaterial3D.new()
		_pylon_pole_mat.albedo_color = body_col
		_pylon_pole_mat.metallic     = 0.75
		_pylon_pole_mat.roughness    = 0.35
	if _pylon_brace_mat == null:
		_pylon_brace_mat              = StandardMaterial3D.new()
		_pylon_brace_mat.albedo_color = body_col.lightened(0.10)
		_pylon_brace_mat.metallic     = 0.70
		_pylon_brace_mat.roughness    = 0.40
	if _pylon_beam_mat == null:
		_pylon_beam_mat              = StandardMaterial3D.new()
		_pylon_beam_mat.albedo_color = body_col.lightened(0.08)
		_pylon_beam_mat.metallic     = 0.75
		_pylon_beam_mat.roughness    = 0.30

	# Authored Blender pylon ("pylon") — instanced per side, mirrored so the
	# crossbeam arm always reaches toward the track. A child named "Tip" gets
	# the zone's arc colour + beat pulse, exactly like the procedural tips.
	var pylon_entry: Dictionary = (_piece_lib.first_of("pylon") if _piece_lib != null else {})

	for i in range(pylon_count):
		var bz: float = PYLON_SPACING * 0.5 + float(i) * PYLON_SPACING
		if not _z_is_electric(bz):
			continue
		var arc_col: Color = arc_palette[i % arc_palette.size()]

		if not pylon_entry.is_empty():
			var p_reach: float = float(pylon_entry.params.get("reach", arm_reach))
			var p_h:     float = float(pylon_entry.params.get("height", pylon_h))
			for side in [-1, 1]:
				var p_anchor := Node3D.new()
				p_anchor.position           = _path_world_pos(bz, float(side) * pylon_dist, 0.0)
				p_anchor.rotation_degrees.y = _path_y_rot_at(bz)
				# Authored arm points +X (Blender) which lands world −X after the
				# import yaw — mirror the LEFT side so both arms reach inward.
				p_anchor.scale.x = -1.0 if side < 0 else 1.0
				world_fx_root.add_child(p_anchor)
				var p_inst: Node3D = _piece_lib.instance(pylon_entry)
				p_inst.rotation_degrees.y = 180.0
				p_anchor.add_child(p_inst)

				# Colour + pulse the "Tip" glow like the procedural insulators.
				var tip_mat := StandardMaterial3D.new()
				tip_mat.albedo_color               = arc_col.lightened(0.20)
				tip_mat.emission_enabled           = true
				tip_mat.emission                   = arc_col
				tip_mat.emission_energy_multiplier = 1.2
				var p_stack: Array = [p_inst]
				while not p_stack.is_empty():
					var pn: Node = p_stack.pop_back()
					if pn is MeshInstance3D and String(pn.name).to_lower().contains("tip"):
						(pn as MeshInstance3D).material_override = tip_mat
						_elec_env_mats.append(tip_mat)
					for pc in pn.get_children():
						p_stack.append(pc)

				if i % 3 == 0:
					var p_alight := OmniLight3D.new()
					p_alight.light_color  = arc_col
					p_alight.light_energy = 0.8
					p_alight.omni_range   = 9.0
					p_alight.position     = _path_world_pos(bz,
						float(side) * (pylon_dist - p_reach), p_h - 1.5)
					world_fx_root.add_child(p_alight)
					_elec_arc_lights.append(p_alight)
			continue

		for side in [-1, 1]:
			var blat: float = float(side) * pylon_dist

			# ── Main vertical pole (shared mesh + shared material) ──────────
			var pole := MeshInstance3D.new()
			pole.mesh              = _pylon_pole_mesh
			pole.material_override = _pylon_pole_mat
			pole.position = _path_world_pos(bz, blat, pylon_h * 0.5)
			pole.rotation_degrees.y = _path_y_rot_at(bz)
			world_fx_root.add_child(pole)

			# ── X-brace diagonals (shared mesh + shared material) ───────────
			for bsign: float in [-1.0, 1.0]:
				var brace := MeshInstance3D.new()
				brace.mesh              = _pylon_brace_mesh
				brace.material_override = _pylon_brace_mat
				brace.position = _path_world_pos(bz, blat, pylon_h * 0.5)
				brace.rotation_degrees.y = _path_y_rot_at(bz)
				brace.rotation_degrees.z = bsign * 22.0
				world_fx_root.add_child(brace)

			# ── Crossbeam arm (shared mesh + shared material) ────────────────
			var arm_lat: float = blat - float(side) * arm_reach * 0.5
			var cross := MeshInstance3D.new()
			cross.mesh              = _pylon_beam_mesh
			cross.material_override = _pylon_beam_mat
			cross.position = _path_world_pos(bz, arm_lat, pylon_h)
			cross.rotation_degrees.y = _path_y_rot_at(bz)
			world_fx_root.add_child(cross)

			# ── Insulator glow (shared sphere mesh, unique emission material) ─
			var tip_lat: float = blat - float(side) * arm_reach
			var arc_mat := StandardMaterial3D.new()
			arc_mat.albedo_color               = arc_col.lightened(0.20)
			arc_mat.emission_enabled           = true
			arc_mat.emission                   = arc_col
			arc_mat.emission_energy_multiplier = 1.2
			_elec_env_mats.append(arc_mat)

			var glow := MeshInstance3D.new()
			glow.mesh              = _pylon_glow_mesh
			glow.material_override = arc_mat
			glow.position = _path_world_pos(bz, tip_lat, pylon_h)
			world_fx_root.add_child(glow)

			# ── Ambient light — only every 3rd pylon to keep light count down ─
			if i % 3 == 0:
				var alight := OmniLight3D.new()
				alight.light_color  = arc_col
				alight.light_energy = 0.8
				alight.omni_range   = 9.0
				alight.position     = _path_world_pos(bz, tip_lat, pylon_h - 1.5)
				world_fx_root.add_child(alight)
				_elec_arc_lights.append(alight)


# ── Electric pulse decay ──────────────────────────────────────────────────────
# Mirrors _update_city_pulse; drives obstacle arcs hard and env tips subtly.
func _update_electric_pulse(delta: float) -> void:
	# Ambient danger flicker — small random spikes between beats in electric zones
	_elec_flicker_t = maxf(0.0, _elec_flicker_t - delta)
	if _elec_pulse_t < 0.05 and _elec_flicker_t <= 0.0 and _is_electric_at(_song_time()):
		_elec_flicker_t = randf_range(0.15, 0.55)
		_elec_pulse_t   = randf_range(0.06, 0.20)

	if _elec_pulse_t <= 0.0:
		return
	var beat_s: float = max(0.18, _runner_avg_beat_s)
	_elec_pulse_t = maxf(0.0, _elec_pulse_t - delta / (beat_s * 0.55))

	var vit: float = _world_vitality

	# Arc materials are driven by their own crackle tweens — no override here.

	# Environment tip glows: subtle pulse
	var env_peak: float = lerpf(1.5, 3.0, vit)
	var env_base: float = lerpf(0.6, 1.2, vit)
	var env_e:    float = lerpf(env_base, env_peak, _elec_pulse_t)
	for mat in _elec_env_mats:
		mat.emission_energy_multiplier = env_e

	# Shared point lights
	var lp_peak: float = lerpf(0.4, 2.5, vit)
	var lp_base: float = lerpf(0.1, 0.5, vit)
	var lt_e:    float = lerpf(lp_base, lp_peak, _elec_pulse_t)
	for lt in _elec_arc_lights:
		lt.light_energy = lt_e


# ── Electric zone helpers ──────────────────────────────────────────────────────
func _is_electric_at(t_s: float) -> bool:
	for zone: Dictionary in _electric_zones:
		if t_s >= float(zone.get("start_t", 0.0)) and t_s < float(zone.get("end_t", 0.0)):
			return true
	return false

func _z_is_electric(world_z: float) -> bool:
	if player == null or player.forward_speed <= 0.0:
		return false
	return _is_electric_at(world_z / player.forward_speed)


# ── Section geometry (corridors, elevated paths, ramps) ────────────────────
# Spawned once after all gate visuals are built. These are large structural
# pieces that span an entire phrase rather than a single beat.

func _song_end_z() -> float:
	var last_t: float = 0.0
	for e in gameplay_events:
		var t: float = float(e.get("t", 0.0))
		if t > last_t: last_t = t
	for e in world_events:
		var t: float = float(e.get("t", 0.0))
		if t > last_t: last_t = t
	return max(last_t, 1.0) * player.forward_speed + 500.0


func _spawn_section_geometry() -> void:
	if runner_plan.is_empty():
		return

	# Group runner_plan entries by phrase_index
	var phrases: Dictionary = {}
	for entry in runner_plan:
		var pi: int = int(entry.get("phrase_index", -1))
		if pi < 0:
			continue
		if not phrases.has(pi):
			phrases[pi] = []
		(phrases[pi] as Array).append(entry)

	var wj_sections_spawned: int = 0
	var max_wj_sections:     int = 1   # one wall-jump section per song

	for pi in phrases.keys():
		if wj_sections_spawned >= max_wj_sections:
			break
		var phrase_entries: Array = phrases[pi]
		if phrase_entries.is_empty():
			continue
		var stag: String = String(phrase_entries[0].get("section_tag", ""))
		if stag != "wall_jump":
			continue
		_spawn_wall_jump_section(phrase_entries)
		wj_sections_spawned += 1


# ── Wall jump physics validation ───────────────────────────────────────────────
# Returns {"feasible", "beats_per_jump", "gap_t", "gap_z", "step_height",
#          "step_heights", "active_times"}.
# Validates EVERY consecutive pair individually (not just the average).
# A pair is feasible when gap_t ∈ [t_peak, 2×t_peak):
#   • gap_t >= t_peak  — player has peaked and is descending when the next gate fires
#   • step_h  > 0.05 m — height gain is still positive (not back below start)

func _validate_wall_jump_feasibility(wj_gate_times: Array[float]) -> Dictionary:
	if wj_gate_times.size() < 2:
		return {"feasible": false}

	# Use actual BPM-scaled physics (set by set_beat_duration before this runs).
	# step_h = height player reaches at the next gate's Z position.
	# A pair is feasible when:
	#   • gap_t >= MIN_REACT_S  — enough time to react (too-fast guard)
	#   • step_h > MIN_STEP_H   — player still airborne at next gate Z (too-slow guard)
	# step_h ≤ 0 means the player has already landed before the gate fires,
	# which happens when j is clamped (BPM ≤ ~81) and the beat interval exceeds
	# the wall-jump flight time.
	var wjv:           float = player.wall_jump_velocity
	var grav:          float = player.gravity
	# Loosened gate-timing window (was MIN_REACT 0.18 / step_h > 0.05). The player can
	# buffer a wall-jump (WALL_BUFFER_S ≈ 0.22) and can simply stand on a ledge and
	# re-jump on cue, so a gate that fires just AFTER landing is still playable. We
	# therefore allow step_h to dip slightly negative (player lands a hair early) and
	# clamp the ledge rise to a positive floor so the geometry still steps up cleanly.
	const MIN_REACT_S:    float = 0.15   # min time to read + react to the next gate
	const MIN_STEP_H:     float = -0.30  # allow landing just before the gate (buffered)
	const LEDGE_MIN_RISE: float = 0.40   # ledges always step up at least this much

	# Try thinning factors — prefer bpj=1 (every beat), fall back to 2, 3, 4.
	for bpj in [1, 2, 3, 4]:
		var active_times: Array[float] = []
		for i in range(0, wj_gate_times.size(), bpj):
			active_times.append(wj_gate_times[i])

		if active_times.size() < 2:
			continue

		# Per-gap check: reaction-time floor AND physics ceiling.
		var all_ok: bool = true
		var step_heights: Array[float] = []
		for i in range(active_times.size() - 1):
			var gap:    float = active_times[i + 1] - active_times[i]
			var step_h: float = wjv * gap - 0.5 * grav * gap * gap
			if gap < MIN_REACT_S or step_h <= MIN_STEP_H:
				all_ok = false
				break
			step_heights.append(maxf(LEDGE_MIN_RISE, step_h))   # clamp rise for geometry
		if not all_ok:
			continue

		var sum_gap_t: float = 0.0
		for i in range(active_times.size() - 1):
			sum_gap_t += active_times[i + 1] - active_times[i]
		var avg_gap_t: float = sum_gap_t / float(active_times.size() - 1)

		var avg_step_h: float = 0.0
		for sh in step_heights:
			avg_step_h += sh
		avg_step_h /= float(step_heights.size())

		return {
			"feasible":       true,
			"beats_per_jump": bpj,
			"gap_t":          avg_gap_t,
			"gap_z":          avg_gap_t * player.forward_speed,
			"step_height":    avg_step_h,
			"step_heights":   step_heights,
			"active_times":   active_times,
		}

	return {"feasible": false}


# ── Wall jump section spawner ───────────────────────────────────────────────────
# Spawns the full wall-jump sub-level:
#   • Corridor side walls (visual only, rising height)
#   • Ledge platforms at each gate Z, at i × step_height (no floor between them → void)
#   • Gate visuals repositioned to sit on their ledge
#   • Elevated floor from the final landing point onward
#   • Descent ramp + new ground floor after the elevated section

func _spawn_wall_jump_section(phrase_entries: Array) -> void:
	# ── 1. Collect actual wall_left / wall_right gates ─────────────────────────
	var wj_times: Array[float]  = []
	var wj_zs:    Array[float]  = []
	var wj_acts:  Array[String] = []
	for e in phrase_entries:
		var act: String = String(e.get("action", ""))
		if act == "wall_left" or act == "wall_right":
			var t: float = float(e.get("t", 0.0))
			wj_times.append(t)
			wj_zs.append(t * player.forward_speed)
			wj_acts.append(act)
	if wj_zs.is_empty():
		return

	# Keep parallel time + Z + action arrays sorted together
	var order: Array[int] = []
	for i in range(wj_times.size()): order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return wj_times[a] < wj_times[b])
	var sorted_times: Array[float]  = []
	var sorted_zs:    Array[float]  = []
	var sorted_acts:  Array[String] = []
	for idx in order:
		sorted_times.append(wj_times[idx])
		sorted_zs.append(wj_zs[idx])
		sorted_acts.append(wj_acts[idx])

	# ── 2. Physics feasibility check ───────────────────────────────────────────
	var phys: Dictionary = _validate_wall_jump_feasibility(sorted_times)
	if not bool(phys.get("feasible", false)):
		push_warning("[BeatRunner] Wall jump section not feasible — hiding bare gates to avoid visual mess.")
		# Hide and pre-judge all WJ gates in this phrase so they don't appear or score as misses.
		for gi in range(gate_nodes.size()):
			if gate_world_zs[gi] >= sorted_zs[0] - 1.0 and gate_world_zs[gi] <= sorted_zs[sorted_zs.size() - 1] + 1.0:
				gate_nodes[gi].visible = false
				gate_nodes[gi].process_mode = Node.PROCESS_MODE_DISABLED
				if gi < gate_judged.size():
					gate_judged[gi] = true
					gate_success[gi] = true
		return

	var beats_per_jump: int     = int(phys.get("beats_per_jump", 1))
	var gap_z: float            = float(phys.get("gap_z", 10.0))
	var raw_step_heights: Array = phys.get("step_heights", [])

	# Active gate Z positions + actions — thin by beats_per_jump
	var active_zs:   Array[float]  = []
	var active_acts: Array[String] = []
	for i in range(0, sorted_zs.size(), beats_per_jump):
		active_zs.append(sorted_zs[i])
		active_acts.append(sorted_acts[i])

	# Enforce strict alternation: thinning by an even beats_per_jump can produce
	# runs of the same action (e.g. wall_left, wall_left, …).  Flip any duplicate
	# so platforms always alternate sides.
	for i in range(1, active_acts.size()):
		if active_acts[i] == active_acts[i - 1]:
			active_acts[i] = "wall_right" if active_acts[i] == "wall_left" else "wall_left"

	if active_zs.size() < 2:
		push_warning("[BeatRunner] Too few active gates after thinning — hiding bare gates.")
		for gi in range(gate_nodes.size()):
			if gate_world_zs[gi] >= sorted_zs[0] - 1.0 and gate_world_zs[gi] <= sorted_zs[sorted_zs.size() - 1] + 1.0:
				gate_nodes[gi].visible = false
				gate_nodes[gi].process_mode = Node.PROCESS_MODE_DISABLED
				if gi < gate_judged.size():
					gate_judged[gi] = true
					gate_success[gi] = true
		return

	var n_jumps: int = active_zs.size()

	# Build cumulative ledge heights from the per-pair step_heights.
	# cum_heights[i] = height of ledge i after i jumps from the ground.
	# step_heights has (n_jumps - 1) entries (one per consecutive pair of active gates).
	# The final jump (from the last active gate to the elevated floor) reuses the last
	# known step height as a safe estimate.
	var cum_heights: Array[float] = []
	cum_heights.append(0.0)   # ledge 0 = ground level
	var fallback_step: float = float(phys.get("step_height", 1.0))
	for i in range(n_jumps - 1):
		var sh: float = float(raw_step_heights[i]) if i < raw_step_heights.size() else fallback_step
		cum_heights.append(cum_heights[cum_heights.size() - 1] + sh)
	# total_height = height of the elevated floor = height of ledge (n_jumps-1) + one more jump
	var last_step: float = float(raw_step_heights[raw_step_heights.size() - 1]) \
		if not raw_step_heights.is_empty() else fallback_step
	var total_height: float = cum_heights[cum_heights.size() - 1] + last_step

	# Ledge depth = 85 % of the Z-gap so adjacent ledges never overlap,
	# and always at least 3 m so landings feel generous.
	var ledge_half_z: float  = clamp(gap_z * 0.425, 3.0, 6.5)
	var ledge_thick: float   = 0.30
	var tw: float            = _track_full_width()

	# ── 3. Corridor walls — visual only, thin emissive slabs rising with the climb ──
	var z_section_start: float = active_zs[0] - 8.0

	# Cut the main floor just before the first wall jump gate — not at the
	# corridor entrance.  This gives the player full-width solid ground during
	# the approach so setup lane-move gates can be executed safely.
	_resize_floor_to(max(10.0, active_zs[0] - 1.0))
	var z_section_end:   float = active_zs[active_zs.size() - 1] + gap_z + ledge_half_z + 4.0
	var corridor_len:    float = z_section_end - z_section_start
	var wall_thick:      float = 0.18
	var wall_cx_abs:     float = tw * 0.5 + wall_thick * 0.5
	var purple:          Color = Color(0.0, 0.672, 0.79, 1.0).darkened(0.22)
	var num_segs:        int   = 14
	var seg_z_len:       float = corridor_len / float(num_segs)

	for seg in range(num_segs):
		var t: float      = float(seg) / float(max(num_segs - 1, 1))
		var seg_h: float  = lerpf(lane_blocker_height * 1.1, total_height + 4.0, t)
		var seg_zc: float = z_section_start + (float(seg) + 0.5) * seg_z_len
		for side in [-1, 1]:
			var sr: Node3D = Node3D.new()
			sr.position = Vector3(side * wall_cx_abs, 0.0, seg_zc)
			gates_root.add_child(sr)
			var wm: MeshInstance3D = _make_box_mesh(
				Vector3(wall_thick, seg_h, seg_z_len * 0.97), purple)
			wm.position = Vector3(0.0, seg_h * 0.5, 0.0)
			sr.add_child(wm)

	# ── 3c. Entrance arch — two tall glowing pillars + crossbeam at corridor mouth ──
	# Visible from several beats away, this is the player's first "wall jump incoming" cue.
	var arch_z:     float = z_section_start - 1.5
	var arch_col:   Color = Color(1.00, 0.60, 0.05, 1.0)   # vivid orange — unmissable
	var pillar_h:   float = total_height + 5.5
	var pillar_w:   float = 0.55
	for side in [-1, 1]:
		var px: float = side * (tw * 0.5 + pillar_w * 0.5 + 0.08)
		var pillar: MeshInstance3D = _make_box_mesh(
			Vector3(pillar_w, pillar_h, pillar_w), arch_col)
		pillar.position = Vector3(px, pillar_h * 0.5, arch_z)
		var pm: StandardMaterial3D = pillar.material_override as StandardMaterial3D
		if pm != null: pm.emission_energy_multiplier = 5.0
		gates_root.add_child(pillar)

	# Horizontal crossbeam connecting the two pillars
	var beam: MeshInstance3D = _make_box_mesh(
		Vector3(tw + pillar_w * 2.0 + 0.16, 0.45, pillar_w), arch_col.lightened(0.20))
	beam.position = Vector3(0.0, pillar_h, arch_z)
	var bm2: StandardMaterial3D = beam.material_override as StandardMaterial3D
	if bm2 != null: bm2.emission_energy_multiplier = 5.5
	gates_root.add_child(beam)

	# Bright OmniLight inside the arch so it casts colour on approach
	var arch_light := OmniLight3D.new()
	arch_light.light_color  = arch_col.lightened(0.30)
	arch_light.light_energy = 5.0
	arch_light.omni_range   = 22.0
	arch_light.position     = Vector3(0.0, pillar_h * 0.5, arch_z)
	gates_root.add_child(arch_light)

	# ── 3b. Approach floor — narrow single-lane platform from corridor entrance to just
	# past the first WJ gate. Placed at the starting side so the player has a clear
	# lane to stand on when executing the first wall jump.
	# first action == wall_left  → player starts at left  (lane 0)
	# first action == wall_right → player starts at right (lane max)
	var approach_len:   float = active_zs[0] + 1.0 - z_section_start
	var approach_thick: float = 0.30
	var approach_w:     float = 2.8    # one lane wide
	var first_act:      String = active_acts[0]
	var max_lane_app:   int    = player.lane_xs.size() - 1
	var approach_lane:  int    = 0 if first_act == "wall_left" else max_lane_app
	var approach_x:     float  = player.lane_xs[approach_lane]

	var approach_body: StaticBody3D = StaticBody3D.new()
	approach_body.position = Vector3(approach_x, -approach_thick * 0.5,
									 z_section_start + approach_len * 0.5)
	gates_root.add_child(approach_body)
	var ac: CollisionShape3D = CollisionShape3D.new()
	var ab: BoxShape3D = BoxShape3D.new()
	ab.size = Vector3(approach_w, approach_thick, approach_len)
	ac.shape = ab
	approach_body.add_child(ac)
	approach_body.add_child(_make_box_mesh(
		Vector3(approach_w, approach_thick, approach_len), Color(0.862, 0.427, 0.817, 1.0)))

	# ── 4. Ledges — single-lane platforms at landing side, per-pair cumulative heights ──
	# cum_heights[i] = height player reaches after i jumps (ledge 0 = ground, no spawn).
	# Each ledge sits at the lane the player snaps to after the preceding jump:
	#   wall_left  (gate i-1) → player snaps right → ledge at lane_xs[max_lane]
	#   wall_right (gate i-1) → player snaps left  → ledge at lane_xs[0]
	var ledge_color:   Color = Color(0.65, 0.15, 1.00, 1.0)
	var ledge_w:       float = 2.8          # one lane wide (slightly generous)
	var max_lane_idx:  int   = player.lane_xs.size() - 1

	for i in range(1, n_jumps):
		var lz: float  = active_zs[i]
		var lh: float  = cum_heights[i]
		var lcy: float = lh - ledge_thick * 0.5   # box centre just below top surface

		# Determine landing lane from the PREVIOUS jump's action
		var prev_act: String  = active_acts[i - 1]
		var land_idx:  int    = max_lane_idx if prev_act == "wall_left" else 0
		var lx:        float  = player.lane_xs[land_idx]

		var ledge: StaticBody3D = StaticBody3D.new()
		ledge.position = Vector3(lx, lcy, lz)
		gates_root.add_child(ledge)

		var lc: CollisionShape3D = CollisionShape3D.new()
		var lb: BoxShape3D = BoxShape3D.new()
		lb.size = Vector3(ledge_w, ledge_thick, ledge_half_z * 2.0)
		lc.shape = lb
		ledge.add_child(lc)
		var lm: MeshInstance3D = _make_box_mesh(
			Vector3(ledge_w, ledge_thick, ledge_half_z * 2.0),
			ledge_color.lerp(Color(1, 1, 1, 1), float(i) / float(max(n_jumps, 1)) * 0.3))
		var lmat: StandardMaterial3D = lm.material_override as StandardMaterial3D
		if lmat != null:
			lmat.emission_energy_multiplier = 2.5 + float(i) * 0.4
		ledge.add_child(lm)

		# Small light above each ledge so the platform glows from below
		var ledge_light := OmniLight3D.new()
		ledge_light.light_color  = ledge_color.lightened(0.30)
		ledge_light.light_energy = 1.8
		ledge_light.omni_range   = 8.0
		ledge_light.position     = Vector3(lx, lh + 0.5, lz)
		gates_root.add_child(ledge_light)

	# ── 5. Lift gate visuals to match their exact cumulative ledge height ────────
	for j in range(active_zs.size()):
		var target_z: float = active_zs[j]
		var lift_y:   float = cum_heights[j]
		for gi in range(gate_nodes.size()):
			if abs(gate_world_zs[gi] - target_z) < 1.5:
				gate_nodes[gi].position.y += lift_y
				break

	# ── 6. Elevated floor — flush in Z and height with the last ledge ───────────
	# Z: start exactly at the trailing edge of the last ledge (no horizontal gap).
	# Height: match the last ledge top exactly — total_height was one step_height
	# (0.55 m) above the last ledge, which created a visible step the player caught.
	var elev_start_z: float = active_zs[active_zs.size() - 1] + ledge_half_z
	var elev_height:  float = cum_heights[active_zs.size() - 1]
	var elev_length:  float = 18.0
	_spawn_floor_segment(elev_start_z, elev_length, elev_height,
						 Color(0.70, 0.22, 0.95, 1.0).darkened(0.15))

	# Side rails along the elevated path (visual only)
	for side in [-1, 1]:
		var rail: Node3D = Node3D.new()
		rail.position = Vector3(side * tw * 0.5,
								elev_height + 0.45,
								elev_start_z + elev_length * 0.5)
		gates_root.add_child(rail)
		rail.add_child(_make_box_mesh(
			Vector3(0.07, 0.07, elev_length),
			Color(0.85, 0.45, 1.00, 1.0).lightened(0.20)))

	# ── 7. Descent platforms — single-lane stepping stones back to ground ────────
	var descent_step_h: float = 1.5
	# One platform per beat, so the descent feels rhythmic at any BPM.
	# clamp keeps it playable from very slow (~60 BPM) to very fast (~200 BPM).
	var beat_z:         float = _runner_avg_beat_s * player.forward_speed
	var descent_step_z: float = clamp(beat_z, 5.0, 12.0)
	var plat_w:         float = 2.4
	var plat_d:         float = clamp(descent_step_z * 0.60, 3.5, 7.0)
	var plat_thick:     float = 0.28
	var lane_colors:    Array[Color] = [
		Color(1.0, 0.35, 0.65, 1.0),   # left  = pink
		Color(0.95, 0.95, 0.95, 1.0),  # mid   = white
		Color(0.30, 0.65, 1.00, 1.0),  # right = blue
	]
	var n_descent: int = int(ceil(elev_height / descent_step_h)) + 1
	var desc_z_start: float = elev_start_z + elev_length + 4.0
	var last_descent_z: float = desc_z_start  # tracks actual last platform Z

	# Landing lane: the last wall-jump action determines which side the player
	# snaps to.  wall_left bounces to the right edge; wall_right to the left.
	var last_wj_act: String = active_acts[active_acts.size() - 1]
	var cur_desc_lane: int  = max_lane_idx if last_wj_act == "wall_left" else 0

	for di in range(n_descent):
		var dh: float = max(0.0, elev_height - float(di + 1) * descent_step_h)
		var lane_idx: int = cur_desc_lane
		var dx:   float = player.lane_xs[lane_idx]
		var dz:   float = desc_z_start + float(di) * descent_step_z
		var dcy:  float = dh - plat_thick * 0.5

		# Randomise next platform lane: step ±1 or stay, clamped to valid range.
		# Done before the platform is placed so the last platform doesn't advance.
		if di < n_descent - 1:
			var step: int = _runner_rng.randi_range(-1, 1)
			cur_desc_lane = clamp(cur_desc_lane + step, 0, max_lane_idx)

		last_descent_z = dz

		var dp: StaticBody3D = StaticBody3D.new()
		dp.position = Vector3(dx, dcy, dz)
		gates_root.add_child(dp)

		var dc: CollisionShape3D = CollisionShape3D.new()
		var db: BoxShape3D = BoxShape3D.new()
		db.size = Vector3(plat_w, plat_thick, plat_d)
		dc.shape = db
		dp.add_child(dc)

		var dm: MeshInstance3D = _make_box_mesh(
			Vector3(plat_w, plat_thick, plat_d), lane_colors[lane_idx])
		var dmat: StandardMaterial3D = dm.material_override as StandardMaterial3D
		if dmat != null:
			dmat.emission_enabled = true
			dmat.emission = lane_colors[lane_idx]
			dmat.emission_energy_multiplier = 1.6
		dp.add_child(dm)

		# Small light under each descent platform
		var dlight := OmniLight3D.new()
		dlight.light_color  = lane_colors[lane_idx].lightened(0.25)
		dlight.light_energy = 1.2
		dlight.omni_range   = 5.0
		dlight.position     = Vector3(dx, dh + 0.4, dz)
		gates_root.add_child(dlight)

		if dh <= 0.0:
			break

	# ── Gate culling for the entire WJ section ────────────────────────────────
	# Approach zone (z_section_start → first WJ gate):
	#   Keep ALL gates — setup lane-move gates here guide the player to the
	#   approach lane.  The floor is still solid here so they're safe to hit.
	# Climbing void (first WJ gate → elev_start_z):
	#   Only wall-jump gates stay visible; everything else floats in void.
	# Elevated floor + descent (elev_start_z → desc_zone_end):
	#   All gates hidden — platforms carry the rhythm there.
	var first_wj_z:    float = active_zs[0]
	var desc_zone_end: float = last_descent_z + plat_d * 0.5
	for gi in range(gate_nodes.size()):
		var gz:    float  = gate_world_zs[gi]
		var act:   String = String(runner_plan[gi].get("action", ""))
		var is_wj: bool   = act == "wall_left" or act == "wall_right"

		var should_cull: bool = false
		if gz >= z_section_start and gz < first_wj_z:
			should_cull = false           # approach zone — keep setup gates visible
		elif gz >= first_wj_z and gz < elev_start_z:
			should_cull = not is_wj       # climbing void — only WJ gates visible
		elif gz >= elev_start_z and gz < desc_zone_end:
			should_cull = true            # elevated floor + descent — hide all

		if should_cull:
			gate_nodes[gi].visible = false
			gate_nodes[gi].process_mode = Node.PROCESS_MODE_DISABLED
			# Mark as judged so the miss-detector never fires on these gates.
			if gi < gate_judged.size():
				gate_judged[gi] = true
				gate_success[gi] = true   # count as success — player can't hit what isn't there

	# Store wall-jump zone so halos are suppressed while the player is inside it
	_wj_zone_start_z = z_section_start
	_wj_zone_end_z   = desc_zone_end + 8.0

	# ── 8. Record where ground-level floor resumes after the WJ descent ───────────
	# _spawn_path_floors() runs after _build_track_path() and will lay path-aware
	# floor slabs for every segment, skipping the void [_floor_cutoff_dist,
	# _wj_ground_resume_z].  We no longer spawn a straight fallback slab here,
	# because turns after the WJ zone need the floor to follow the path direction.
	_wj_ground_resume_z = last_descent_z + plat_d * 0.5


## Path-aware wall-jump section geometry spawner.
## Must be called AFTER _build_track_path() and _reposition_gates_on_path() so that
## all platforms, ledges, and corridor walls follow snaking turns correctly.
## Also handles WJ gate lifts, zone culling, and refining _wj_zone_start/end_z.
func _spawn_wj_geometry_on_path() -> void:
	# ── 0. Collect WJ phrase entries ─────────────────────────────────────────
	var phrase_entries: Array = []
	for entry in runner_plan:
		if String(entry.get("section_tag", "")) == "wall_jump":
			phrase_entries.append(entry)
	if phrase_entries.is_empty():
		return

	# ── 1. Collect wall_left / wall_right gates ───────────────────────────────
	var wj_times: Array[float]  = []
	var wj_zs:    Array[float]  = []
	var wj_acts:  Array[String] = []
	for e in phrase_entries:
		var act: String = String(e.get("action", ""))
		if act == "wall_left" or act == "wall_right":
			var t: float = float(e.get("t", 0.0))
			wj_times.append(t)
			wj_zs.append(t * player.forward_speed)
			wj_acts.append(act)
	if wj_zs.is_empty():
		return

	var order: Array[int] = []
	for i in range(wj_times.size()): order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return wj_times[a] < wj_times[b])
	var sorted_times: Array[float]  = []
	var sorted_zs:    Array[float]  = []
	var sorted_acts:  Array[String] = []
	for idx in order:
		sorted_times.append(wj_times[idx])
		sorted_zs.append(wj_zs[idx])
		sorted_acts.append(wj_acts[idx])

	# ── 2. Guaranteed rainbow staircase (wall_jump_count ledges) ──────────────
	# HARD GUARANTEE: the climb is ALWAYS exactly wall_jump_count ledges (red→…), evenly spaced
	# at a physically-jumpable gap, no matter how many wall beats the chart phrase produced.
	# We NEVER thin/cull here (that old path is what left empty gaps). Instead we RESPACE:
	# WJ gates are judged by POSITION only (see _judge_passed_unhit_gates_by_position), so
	# moving a gate's Z never desyncs the music — there is no timing window to break.

	# Representative feasible gap, derived straight from the player's jump physics so it is
	# always reachable: gap ≥ reaction floor, ≤ airtime (player still rising at the next slot).
	var wjv:  float = player.wall_jump_velocity
	var grav: float = player.gravity
	const MIN_REACT_S:    float = 0.15
	const LEDGE_MIN_RISE: float = 0.40
	var t_apex: float = wjv / maxf(0.1, grav)
	var nat_gap_t: float = MIN_REACT_S * 2.0
	if sorted_times.size() >= 2:
		nat_gap_t = (sorted_times[sorted_times.size() - 1] - sorted_times[0]) \
			/ float(sorted_times.size() - 1)
	var gap_t: float = clampf(nat_gap_t, MIN_REACT_S, t_apex * 1.7)
	var step_height: float = maxf(LEDGE_MIN_RISE, wjv * gap_t - 0.5 * grav * gap_t * gap_t)
	var gap_z: float = gap_t * player.forward_speed

	# ── Authored wall-jump KIT override ───────────────────────────────────────
	# If a wj_kit asset exists (e.g. WallJumpKit_5j.glb — walls + elevated floor + rails as
	# one piece), it dictates the climb so the generated ledges/gates line up with its walls.
	# Jump count: siag metadata → "_5j" in the filename → the procedural default.
	# Gap + step: siag metadata → the SIAG kit standard (10 m gap, 1 m rise) as a fallback,
	# so it still aligns even if the .glb extras didn't survive import.
	# YOU pick the jump count in the Inspector — the `wall_jump_count` export (3, 6, 7, 8…).
	# The kit does NOT dictate the count; instead the kit is FIT to whatever count you chose,
	# so every count works in the same kit.
	var jumps_n: int = clampi(wall_jump_count, 2, 16)
	var wj_kit: Dictionary = (_piece_lib.first_of("wj_kit") if _piece_lib != null else {})
	if not wj_kit.is_empty():
		var kp: Dictionary = wj_kit.get("params", {})
		# Metadata gap/step (or the 10 m / 1 m kit standard) are only a last-resort fallback…
		gap_z       = float(kp.get("gap",  10.0))
		step_height = float(kp.get("step",  1.0))

		# …the real source is the kit's MEASURED geometry: fit exactly jumps_n ledges into the
		# measured corridor so the last one always lands on the elevated platform and the whole
		# climb stays inside the walls — for ANY jump count. Spacing (gap) and rise (step) both
		# rescale with jumps_n: fewer jumps → bigger steps/gaps, more jumps → smaller, same kit.
		# The 8 m approach pad mirrors z_section_start = active_zs[0] − 8.
		var kit_tpl: Node3D = wj_kit.get("template") as Node3D
		if kit_tpl != null:
			var full_ab: AABB = _piece_local_aabb(kit_tpl)
			if full_ab.size.z > 1.0:
				var elev_ab:      AABB  = _piece_local_aabb(kit_tpl, "elevfloor")
				var approach_pad: float = 8.0
				var elev_len:     float = elev_ab.size.z if elev_ab.size.z > 0.5 else full_ab.size.z * 0.22
				var climb_len:    float = maxf(4.0, full_ab.size.z - approach_pad - elev_len)
				gap_z = climb_len / float(jumps_n - 1)
				if elev_ab.size.y > 0.0:
					step_height = maxf(0.2, (elev_ab.position.y + elev_ab.size.y) / float(jumps_n - 1))

	# Auto-tune the wall-jump launch velocity to the FINAL spacing so the player lands exactly
	# on each ledge, in time with the music. At the (fixed) forward_speed each gap takes
	# gap_t = gap_z / forward_speed seconds; solving v·t − ½·g·t² = step for v gives the launch
	# speed whose arc reaches the next ledge right on gap_t. So every jump syncs with crossing a
	# ledge, the climb starts on the first wall beat, and it auto-adapts to any kit / jump count.
	# (forward_speed itself is NOT changed — the whole track scrolls at it; we tune the jump.)
	var gap_t_land: float = gap_z / maxf(1.0, player.forward_speed)
	player.wall_jump_velocity = step_height / maxf(0.05, gap_t_land) + 0.5 * player.gravity * gap_t_land

	# Evenly-spaced slots, alternating sides. Anchor slot 0 on the first real wall
	# beat so the section still starts where the music put it. Slot acts follow the chart's
	# actual gate acts where they exist (keeps each gate's baked visual on the right side),
	# then continue the alternation for any synthesised slots.
	var base_z: float = sorted_zs[0]
	var active_zs:   Array[float]  = []
	var active_acts: Array[String] = []
	for k in range(jumps_n):
		active_zs.append(base_z + float(k) * gap_z)
		if k < sorted_acts.size():
			active_acts.append(sorted_acts[k])
		else:
			active_acts.append("wall_right" if active_acts[k - 1] == "wall_left" else "wall_left")
	for k in range(1, active_acts.size()):
		if active_acts[k] == active_acts[k - 1]:
			active_acts[k] = "wall_right" if active_acts[k] == "wall_left" else "wall_left"

	var n_jumps: int = jumps_n   # 7-8 procedurally, or the kit's jump count

	# Uniform rainbow staircase heights.
	var raw_step_heights: Array[float] = []
	for _i in range(jumps_n):
		raw_step_heights.append(step_height)
	var cum_heights: Array[float] = []
	cum_heights.append(0.0)
	for i in range(n_jumps - 1):
		cum_heights.append(cum_heights[cum_heights.size() - 1] + step_height)
	var total_height: float = cum_heights[cum_heights.size() - 1] + step_height

	# ── 2b. Re-map the chart's wall gates onto the 7 slots (scoring) ──────────
	# Collect this phrase's wall gate_nodes (parallel to runner_plan), Z-sort them, and
	# move each onto a slot — overwriting gate_world_zs + the full node transform (incl. the
	# climb height) so the position-only landing check scores the right ledge. Surplus wall
	# gates beyond 7 are hidden + auto-passed so none float un-lifted in the void. Slots with
	# no gate are still climbable ledges (only happens if the host phrase was too short —
	# the picker avoids that; the 7-ledge rainbow is guaranteed regardless).
	var max_lane_g: int = player.lane_xs.size() - 1
	var wj_gate_idx: Array[int] = []
	for gi in range(mini(gate_nodes.size(), runner_plan.size())):
		var ga: String = String(runner_plan[gi].get("action", ""))
		if (ga == "wall_left" or ga == "wall_right") \
				and String(runner_plan[gi].get("section_tag", "")) == "wall_jump":
			wj_gate_idx.append(gi)
	wj_gate_idx.sort_custom(func(a: int, b: int) -> bool: return gate_world_zs[a] < gate_world_zs[b])

	for slot in range(wj_gate_idx.size()):
		var gi2: int = wj_gate_idx[slot]
		if slot >= jumps_n:
			gate_nodes[gi2].visible = false
			gate_nodes[gi2].process_mode = Node.PROCESS_MODE_DISABLED
			if gi2 < gate_judged.size():
				gate_judged[gi2] = true
				gate_success[gi2] = true
			continue
		# Lateral of this slot's ledge (slot 0 = take-off side; slot k = landing side of k-1).
		var lat_idx: int
		if slot == 0:
			lat_idx = 0 if active_acts[0] == "wall_left" else max_lane_g
		else:
			lat_idx = max_lane_g if active_acts[slot - 1] == "wall_left" else 0
		gate_world_zs[gi2] = active_zs[slot]
		runner_plan[gi2]["action"] = active_acts[slot]
		gate_nodes[gi2].position = _path_world_pos(active_zs[slot], player.lane_xs[lat_idx], cum_heights[slot])
		gate_nodes[gi2].rotation_degrees.y = _path_y_rot_at(active_zs[slot])

	var ledge_half_z: float = clamp(gap_z * 0.425, 3.0, 6.5)
	var ledge_thick:  float = 0.30
	var tw: float           = _track_full_width()

	# ── 3. Corridor walls ─────────────────────────────────────────────────────
	var z_section_start: float = active_zs[0] - 8.0
	_resize_floor_to(maxf(10.0, active_zs[0] - 1.0))
	var z_section_end:   float = active_zs[active_zs.size() - 1] + gap_z + ledge_half_z + 4.0
	var corridor_len:    float = z_section_end - z_section_start
	var wall_thick:      float = 0.18
	var wall_cx_abs:     float = tw * 0.5 + wall_thick * 0.5
	var purple:          Color = Color(0.0, 0.0, 0.0, 1.0).darkened(0.22)
	var num_segs:        int   = 14
	var seg_z_len:       float = corridor_len / float(num_segs)

	if wj_kit.is_empty():
		for seg in range(num_segs):
			var t: float      = float(seg) / float(max(num_segs - 1, 1))
			var seg_h: float  = lerpf(lane_blocker_height * 1.1, total_height + 4.0, t)
			var seg_zc: float = z_section_start + (float(seg) + 0.5) * seg_z_len
			for side in [-1, 1]:
				var sr: Node3D = Node3D.new()
				sr.position           = _path_world_pos(seg_zc, float(side) * wall_cx_abs, 0.0)
				sr.rotation_degrees.y = _path_y_rot_at(seg_zc)
				gates_root.add_child(sr)
				var wm: MeshInstance3D = _make_box_mesh(
					Vector3(wall_thick, seg_h, seg_z_len * 0.97), purple)
				wm.position = Vector3(0.0, seg_h * 0.5, 0.0)
				sr.add_child(wm)
	else:
		# Authored kit = walls + elevated floor + rails as one piece. Place it on the path at
		# slot 0; _add_authored_piece applies the Blender→Godot 180° flip so its corridor runs
		# forward (+Z) like the ledges. The kit's entry runway sits behind slot 0 (matching the
		# approach zone). Nudge these two if it sits slightly off in-engine.
		var kit_z_off: float = 0.0   # metres along the path (± to slide the kit fore/aft)
		var kit_y_off: float = 0.0   # metres up/down
		var kit_pivot := Node3D.new()
		kit_pivot.position           = _path_world_pos(active_zs[0] + kit_z_off, 0.0, kit_y_off)
		kit_pivot.rotation_degrees.y = _path_y_rot_at(active_zs[0])
		gates_root.add_child(kit_pivot)
		_register_track_emissives(_add_authored_piece(kit_pivot, wj_kit, Vector3.ZERO))

	# ── 3c. Entrance arch — removed (user request) ──────────────────────────
	# The big orange/yellow WJ arch pillars + crossbeam are hidden.

	# ── 3b. Approach floor ────────────────────────────────────────────────────
	var approach_len:    float  = active_zs[0] + 1.0 - z_section_start
	var approach_thick:  float  = 0.30
	var approach_w:      float  = 2.8
	var first_act:       String = active_acts[0]
	var max_lane_app:    int    = player.lane_xs.size() - 1
	var approach_lane:   int    = 0 if first_act == "wall_left" else max_lane_app
	var approach_x:      float  = player.lane_xs[approach_lane]
	var approach_pd_mid: float  = z_section_start + approach_len * 0.5

	var approach_body: StaticBody3D = StaticBody3D.new()
	approach_body.position           = _path_world_pos(approach_pd_mid, approach_x, -approach_thick * 0.5)
	approach_body.rotation_degrees.y = _path_y_rot_at(approach_pd_mid)
	gates_root.add_child(approach_body)
	var ac: CollisionShape3D = CollisionShape3D.new()
	var ab: BoxShape3D = BoxShape3D.new()
	ab.size = Vector3(approach_w, approach_thick, approach_len)
	ac.shape = ab
	approach_body.add_child(ac)
	# No visible mesh: this body is just the invisible collision runway into jump #1.
	# (An alpha-0 box still rendered here because _make_box_mesh forces emission and
	# never enables transparency.) The visible take-off surface is spawned as a real
	# ledge in §4a so it matches the landing ledges instead of reading as a platform.

	# ── 4. Ledges ─────────────────────────────────────────────────────────────
	# Rainbow colours for the procedural fallback — used when no authored ledge
	# exists for a given slot.  Index 0 = first landing ledge (i=1 in the loop).
	const LEDGE_COLORS: Array[Color] = [
		Color(1.00, 0.10, 0.10),   # 1 red
		Color(1.00, 0.50, 0.00),   # 2 orange
		Color(1.00, 0.95, 0.00),   # 3 yellow
		Color(0.10, 0.85, 0.20),   # 4 green
		Color(0.10, 0.45, 1.00),   # 5 blue
		Color(0.60, 0.10, 1.00),   # 6 purple
		Color(1.00, 0.30, 0.80),   # 7 pink
		Color(1.00, 1.00, 1.00),   # 8 white
	]
	var ledge_w:      float = 2.8
	var max_lane_idx: int   = player.lane_xs.size() - 1
	# Ledges sit at the outer lane centre, which leaves a gap to the corridor wall.
	# Nudge each ledge outward toward its wall so it reads as anchored to the wall.
	# Tune this single value to taste (metres).
	var ledge_wall_nudge: float = 0.6

	# ── 4a. First-gate ledge — the take-off surface for jump #1. Spawned as a real
	# ledge (authored piece, wall-hugging) at ground level so the FIRST surface
	# matches the landing ledges instead of looking like a plain platform. Take-off
	# collision is already provided by the invisible approach runway (§3b), so this
	# is visual-only.
	# Take-off side = the wall the player pushes off: wall_left → left wall (lane 0),
	# wall_right → right wall (max lane). (Opposite of the landing rule below, which
	# uses the side the player bounces TO.)
	var takeoff_idx:   int   = 0 if active_acts[0] == "wall_left" else max_lane_idx
	var takeoff_x:     float = player.lane_xs[takeoff_idx] \
		+ ledge_wall_nudge * (1.0 if takeoff_idx == max_lane_idx else -1.0)
	var first_pivot: Node3D = Node3D.new()
	first_pivot.position           = _path_world_pos(active_zs[0], takeoff_x, -ledge_thick * 0.5)
	first_pivot.rotation_degrees.y = _path_y_rot_at(active_zs[0])
	gates_root.add_child(first_pivot)
	var first_entry: Dictionary = (_piece_lib.ledge_for_index(1) if _piece_lib != null else {})
	if not first_entry.is_empty():
		_register_track_emissives(_add_authored_piece(first_pivot, first_entry, Vector3(0.0, ledge_thick * 0.5, 0.0)))
	else:
		first_pivot.add_child(_make_box_mesh(
			Vector3(ledge_w, ledge_thick, ledge_half_z * 2.0), LEDGE_COLORS[0]))

	for i in range(1, n_jumps):
		var lz:  float  = active_zs[i]
		var lh:  float  = cum_heights[i]
		var lcy: float  = lh - ledge_thick * 0.5
		var prev_act: String = active_acts[i - 1]
		var land_idx: int    = max_lane_idx if prev_act == "wall_left" else 0
		var lx:       float  = player.lane_xs[land_idx] \
			+ ledge_wall_nudge * (1.0 if land_idx == max_lane_idx else -1.0)

		var ledge: StaticBody3D = StaticBody3D.new()
		ledge.position           = _path_world_pos(lz, lx, lcy)
		ledge.rotation_degrees.y = _path_y_rot_at(lz)
		gates_root.add_child(ledge)
		var lc: CollisionShape3D = CollisionShape3D.new()
		var lb: BoxShape3D = BoxShape3D.new()
		lb.size = Vector3(ledge_w, ledge_thick, ledge_half_z * 2.0)
		lc.shape = lb
		ledge.add_child(lc)

		# Per-index authored piece: wj_ledge_1 … wj_ledge_8, fallback to generic
		# wj_ledge, fallback to procedural rainbow box.
		var ledge_entry: Dictionary = (_piece_lib.ledge_for_index(i) if _piece_lib != null else {})
		# Rainbow climb: take-off ledge is red (index 0), landings run orange→pink (i = 1..6).
		var ledge_color: Color = LEDGE_COLORS[mini(i, LEDGE_COLORS.size() - 1)]
		if not ledge_entry.is_empty():
			_register_track_emissives(_add_authored_piece(ledge, ledge_entry, Vector3(0.0, ledge_thick * 0.5, 0.0)))
		else:
			var lm: MeshInstance3D = _make_box_mesh(
				Vector3(ledge_w, ledge_thick, ledge_half_z * 2.0), ledge_color)
			var lmat: StandardMaterial3D = lm.material_override as StandardMaterial3D
			if lmat != null:
				lmat.emission_energy_multiplier = 2.5 + float(i) * 0.4
			ledge.add_child(lm)

		var ledge_light := OmniLight3D.new()
		ledge_light.light_color  = ledge_color.lightened(0.30)
		ledge_light.light_energy = 1.8
		ledge_light.omni_range   = 8.0
		ledge_light.position     = _path_world_pos(lz, lx, lh + 0.5)
		gates_root.add_child(ledge_light)

	# ── 5. (Gate lift) ─────────────────────────────────────────────────────────
	# No longer needed: §2b already places each mapped wall gate at its slot's full
	# transform (lateral + climb height). Lifting again here would double-count.

	# ── 6. Elevated floor ─────────────────────────────────────────────────────
	var elev_start_z: float = active_zs[active_zs.size() - 1] + ledge_half_z
	var elev_height:  float = cum_heights[active_zs.size() - 1]
	var elev_length:  float = 18.0
	# _spawn_floor_segment is path-aware when _track_segs is populated. With a kit present the
	# kit supplies the VISIBLE elevated floor (ElevFloor) — we still need a collision body to
	# stand on, so the procedural floor spawns collision-only (no mesh) to avoid z-fighting.
	_spawn_floor_segment(elev_start_z, elev_length, elev_height,
						 Color(0.70, 0.22, 0.95, 1.0).darkened(0.15), wj_kit.is_empty())

	# Elevated rails: procedural only when there's no kit (the kit has ElevRail.L/R).
	if wj_kit.is_empty():
		for side in [-1, 1]:
			var rail_pd_mid: float = elev_start_z + elev_length * 0.5
			var rail: Node3D = Node3D.new()
			rail.position           = _path_world_pos(rail_pd_mid, float(side) * tw * 0.5, elev_height + 0.45)
			rail.rotation_degrees.y = _path_y_rot_at(rail_pd_mid)
			gates_root.add_child(rail)
			rail.add_child(_make_box_mesh(
				Vector3(0.07, 0.07, elev_length),
				Color(0.85, 0.45, 1.00, 1.0).lightened(0.20)))

	# ── 7. Descent slide rail ────────────────────────────────────────────────
	# One inclined ramp per lane: collision covers each lane position separately
	# so lane-switching works normally.  The player lands on the lane matching the
	# last wall-jump act, then switches lanes as they descend.  Jumping is locked
	# by _update_wj_slide() → player.set_jump_locked(true) for the zone duration.
	var slide_start_z: float = elev_start_z + elev_length + 1.5
	var slide_h:       float = elev_height
	var slide_run:     float = clampf(slide_h * 3.2, 24.0, 52.0)
	var slide_diag:    float = sqrt(slide_h * slide_h + slide_run * slide_run)
	var slide_end_z:   float = slide_start_z + slide_run

	_wj_slide_start_z = slide_start_z
	_wj_slide_end_z   = slide_end_z

	var last_wj_act:  String = active_acts[active_acts.size() - 1]
	var land_lane_idx: int   = max_lane_idx if last_wj_act == "wall_left" else 0
	var land_x:        float = player.lane_xs[land_lane_idx]

	_wj_slide_safe_lane = land_lane_idx

	var ramp_cz: float = slide_start_z + slide_run * 0.5
	var ramp_ch: float = slide_h * 0.5
	# Positive X pitch: local +Z tilts toward -Y (down) — exit end is lower. ✓
	var slide_pitch: float = atan2(slide_h, slide_run)

	var safe_color   := Color(0.15, 0.90, 1.00)   # cyan — safe lane
	var danger_color := Color(1.00, 0.75, 0.05)   # electric yellow — danger lanes

	# ── Authored WJ descent slide (Blender "wj_slide") ────────────────────────
	# One piece covers strips + rails + beacon. It is authored at a reference
	# height/run (siag metadata) and stretched to THIS climb's exact drop and
	# run; the safe lane is authored on the Blender LEFT lane, so the piece is
	# mirrored when the run lands on lane 0. Collision, the jump lock and the
	# wrong-lane shock logic are untouched either way — only visuals swap.
	var slide_entry: Dictionary = (_piece_lib.first_of("wj_slide") if _piece_lib != null else {})
	var slide_authored: bool = not slide_entry.is_empty()

	# One narrow ramp per lane — collision (always) + procedural glow strip
	# (only when no authored slide exists).
	var lane_strip_w: float = 2.0
	for li in range(player.lane_xs.size()):
		var lx:      float = player.lane_xs[li]
		var is_safe: bool  = (li == land_lane_idx)
		var col:     Color = safe_color if is_safe else danger_color

		var lane_ramp := StaticBody3D.new()
		lane_ramp.position = _path_world_pos(ramp_cz, lx, ramp_ch)
		lane_ramp.rotation = Vector3(slide_pitch, deg_to_rad(_path_y_rot_at(ramp_cz)), 0.0)
		gates_root.add_child(lane_ramp)

		var lrc := CollisionShape3D.new()
		var lrb := BoxShape3D.new()
		lrb.size = Vector3(lane_strip_w, 0.28, slide_diag)
		lrc.shape = lrb
		lane_ramp.add_child(lrc)

		if slide_authored:
			continue   # authored piece supplies every visual for this lane

		# Glow strip on top
		var strip    := MeshInstance3D.new()
		var strip_bm := BoxMesh.new()
		strip_bm.size = Vector3(lane_strip_w, 0.06, slide_diag)
		strip.mesh    = strip_bm
		strip.position.y = 0.17
		var smat := StandardMaterial3D.new()
		smat.albedo_color               = Color.WHITE
		smat.emission_enabled           = true
		smat.emission                   = col
		smat.emission_energy_multiplier = 4.5 if is_safe else 6.0
		strip.material_override = smat
		lane_ramp.add_child(strip)

		# Dangerous lanes: crackle tween for electric flicker
		if not is_safe:
			var zap_e: Array[float] = [
				8.0, 2.5, 16.0, 3.5, 11.0, 1.8, 14.0, 5.0, 18.0, 2.0,
				9.5, 4.0, 13.0, 1.5, 7.0, 17.0, 3.0, 10.5, 2.2, 15.0,
				4.5, 12.0, 1.6, 8.5, 19.0, 3.2, 6.5, 14.5, 2.8, 11.5
			]
			var zap_t: Array[float] = [
				0.04, 0.09, 0.018, 0.07, 0.035, 0.10, 0.022, 0.06, 0.012, 0.08,
				0.03, 0.065, 0.025, 0.095, 0.05, 0.015, 0.075, 0.032, 0.085, 0.020,
				0.058, 0.028, 0.092, 0.042, 0.013, 0.078, 0.055, 0.021, 0.088, 0.038
			]
			var ztw := lane_ramp.create_tween().set_loops()
			for zi in range(zap_e.size()):
				ztw.tween_property(smat, "emission_energy_multiplier", zap_e[zi], zap_t[zi])

	if slide_authored:
		var auth_h:   float = maxf(0.1, float(slide_entry.params.get("height", 5.0)))
		var auth_run: float = maxf(0.1, float(slide_entry.params.get("run",  34.0)))
		var s_anchor := Node3D.new()
		s_anchor.position           = _path_world_pos(slide_start_z, 0.0, elev_height)
		s_anchor.rotation_degrees.y = _path_y_rot_at(ramp_cz)
		# Blender-left arrives world-right after the import yaw → mirror when
		# the landing lane is lane 0. mirror_wj_slide flips it if a piece was
		# authored the other way round.
		var mirror: bool = (land_lane_idx == 0) != mirror_wj_slide
		s_anchor.scale = Vector3(-1.0 if mirror else 1.0,
			slide_h / auth_h, slide_run / auth_run)
		gates_root.add_child(s_anchor)
		var s_inst: Node3D = _piece_lib.instance(slide_entry)
		s_inst.rotation_degrees.y = 180.0
		s_anchor.add_child(s_inst)
		_register_track_emissives(s_inst)   # beat-pulse her emissive parts
	else:
		# Outer edge rails — share the ramp pitch via a Node3D pivot
		for side in [-1, 1]:
			var outer_li:  int   = max_lane_idx if side > 0 else 0
			var outer_lx:  float = player.lane_xs[outer_li]
			var rpivot := Node3D.new()
			rpivot.position = _path_world_pos(ramp_cz, outer_lx, ramp_ch)
			rpivot.rotation = Vector3(slide_pitch, deg_to_rad(_path_y_rot_at(ramp_cz)), 0.0)
			gates_root.add_child(rpivot)

			var rail    := MeshInstance3D.new()
			var rail_bm := BoxMesh.new()
			rail_bm.size = Vector3(0.10, 0.30, slide_diag)
			rail.mesh    = rail_bm
			rail.position = Vector3(float(side) * (lane_strip_w * 0.5 + 0.05), 0.28, 0.0)
			var rrmat := StandardMaterial3D.new()
			rrmat.albedo_color               = Color.WHITE
			rrmat.emission_enabled           = true
			rrmat.emission                   = safe_color.lightened(0.30)
			rrmat.emission_energy_multiplier = 7.0
			rail.material_override = rrmat
			rpivot.add_child(rail)

		# Entry beacon — cyan sphere marking the safe entry point
		var beacon    := MeshInstance3D.new()
		var beacon_bm := SphereMesh.new()
		beacon_bm.radius = 0.35; beacon_bm.height = 0.70
		beacon.mesh = beacon_bm
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color               = Color.WHITE
		bmat.emission_enabled           = true
		bmat.emission                   = safe_color
		bmat.emission_energy_multiplier = 14.0
		beacon.material_override = bmat
		beacon.position = _path_world_pos(slide_start_z, land_x, elev_height + 0.6)
		gates_root.add_child(beacon)

	var slide_light := OmniLight3D.new()
	slide_light.light_color  = safe_color
	slide_light.light_energy = 2.5
	slide_light.omni_range   = 18.0
	slide_light.position     = _path_world_pos(ramp_cz, land_x, slide_h * 0.60)
	gates_root.add_child(slide_light)

	# ── 8. Gate culling for WJ section ───────────────────────────────────────
	var first_wj_z:    float = active_zs[0]
	var desc_zone_end: float = slide_end_z
	for gi in range(gate_nodes.size()):
		var gz:    float  = gate_world_zs[gi]
		var act:   String = String(runner_plan[gi].get("action", ""))
		var is_wj: bool   = act == "wall_left" or act == "wall_right"
		var should_cull: bool = false
		if gz >= z_section_start and gz < first_wj_z:
			should_cull = false        # approach zone — keep setup gates
		elif gz >= first_wj_z and gz < elev_start_z:
			should_cull = not is_wj    # climbing void — only WJ gates visible
		elif gz >= elev_start_z and gz < desc_zone_end:
			should_cull = true         # elevated floor + descent — clean cooldown, hide all gates
		if should_cull:
			gate_nodes[gi].visible = false
			gate_nodes[gi].process_mode = Node.PROCESS_MODE_DISABLED
			if gi < gate_judged.size():
				gate_judged[gi] = true
				gate_success[gi] = true

	# ── 9. Refine zone bounds + record floor-resume point ────────────────────
	_wj_zone_start_z    = z_section_start
	_wj_zone_end_z      = desc_zone_end + 8.0
	_wj_ground_resume_z = slide_end_z


# Spawns a flat StaticBody3D floor rectangle along the path.
# z_start / length are PATH distances; height = top surface Y above track (0 = level).
func _spawn_floor_segment(z_start: float, length: float, height: float, color: Color, with_mesh: bool = true) -> void:
	var tw:    float = _track_full_width()
	var thick: float = 0.30
	var cy:    float = height - thick * 0.5

	# If path hasn't been built yet (called during wall-jump section spawn), fall
	# back to the straight world-Z placement so the WJ void floor still lands correctly.
	if _track_segs.is_empty():
		var body: StaticBody3D = StaticBody3D.new()
		body.position = Vector3(0.0, cy, z_start + length * 0.5)
		gates_root.add_child(body)
		var col_shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(tw, thick, length)
		col_shape.shape = box
		body.add_child(col_shape)
		if with_mesh:
			body.add_child(_make_box_mesh(Vector3(tw, thick, length), color))
		return

	# Walk path segments and spawn one box per intersecting segment
	for seg_var in _track_segs:
		var seg: TrackSeg = seg_var as TrackSeg
		var overlap_start: float = maxf(z_start,        seg.path_start)
		var overlap_end:   float = minf(z_start + length, seg.path_end())
		var seg_len: float = overlap_end - overlap_start
		if seg_len <= 0.0:
			continue

		var seg_mid: Vector3 = seg.origin + seg.direction * (overlap_start - seg.path_start + seg_len * 0.5)
		seg_mid.y = cy

		var body: StaticBody3D = StaticBody3D.new()
		body.position = seg_mid
		body.rotation_degrees.y = rad_to_deg(atan2(seg.direction.x, seg.direction.z))
		gates_root.add_child(body)

		var col_shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(tw, thick, seg_len)
		col_shape.shape = box
		body.add_child(col_shape)
		if with_mesh:
			body.add_child(_make_box_mesh(Vector3(tw, thick, seg_len), color))


func _add_gate_judge_area(root: Node3D, gate_index: int, action: String, safe_lane: int) -> void:
	# Wall jump gates are judged continuously by _judge_passed_unhit_gates_by_position
	# (they need a per-frame check, not a one-shot body_entered signal).
	if action == "wall_left" or action == "wall_right":
		return

	var area: Area3D = Area3D.new()
	area.name = "JudgeArea"
	area.monitoring = true
	area.monitorable = true

	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	var tw: float = _track_full_width()

	var x: float
	var y: float
	var size: Vector3

	match action:
		"left", "right":
			# Lane-specific standing corridor
			x    = player.lane_xs[safe_lane]
			y    = 1.25
			size = Vector3(lane_blocker_width * 0.72, 2.4, gate_depth + 0.95)

		"jump":
			# Full-width zone above the barrier — any lane, must be in the air
			x    = 0.0
			y    = jump_hurdle_height + 0.80
			size = Vector3(tw, 1.20, gate_depth + 0.95)

		"slide":
			# Full-width low zone below the beam — any lane, must be crouching
			x    = 0.0
			y    = 0.50
			size = Vector3(tw, 0.80, gate_depth + 0.95)

		_:
			x    = player.lane_xs[safe_lane]
			y    = 1.25
			size = Vector3(lane_blocker_width * 0.72, 2.4, gate_depth + 0.95)

	shape.size = size
	shape_node.shape = shape
	shape_node.position = Vector3(x, y, 0.0)

	area.add_child(shape_node)
	root.add_child(area)

	area.body_entered.connect(Callable(self, "_on_gate_judge_area_body_entered").bind(gate_index))


func _on_gate_judge_area_body_entered(body: Node, gate_index: int) -> void:
	if gate_index < 0 or gate_index >= gate_judged.size():
		return
	if gate_judged[gate_index]:
		return
	if body != player:
		return

	var action: String = String(runner_plan[gate_index].get("action", ""))

	# Both jump and slide gates require the matching physical state.
	if action == "jump"  and not player.is_airborne():
		return
	if action == "slide" and not player.is_sliding():
		return

	gate_judged[gate_index] = true
	gate_success[gate_index] = true
	_mark_gate_result(gate_index, true)


func _judge_passed_unhit_gates_by_position() -> void:
	var player_z: float = _player_path_dist   # path distance, not world Z

	# Advance the lower-bound cursor past consecutive already-judged gates
	while _judge_index < gate_judged.size() and gate_judged[_judge_index]:
		_judge_index += 1

	for i in range(_judge_index, gate_nodes.size()):
		if i >= gate_judged.size():
			break
		if gate_judged[i]:
			continue

		var gate_z: float        = gate_world_zs[i]

		# Gates are sorted by Z — once we're more than 30 m ahead, nothing
		# further back matters this frame.
		if gate_z > player_z + 30.0:
			break

		var entry: Dictionary    = runner_plan[i]
		var action: String       = String(entry.get("action", ""))
		var safe_lane: int       = int(entry.get("post_lane", 1))

		# ── Wall jump: land-based scoring ────────────────────────────────────
		# Hit = player is standing on any surface at or past the gate Z.
		# This covers both the approach platform (first gate) and elevated
		# platforms (subsequent gates). No timing window, no button required —
		# if you're on the floor there, you made it.
		# Miss = fell and never landed; fires very late so real-world death
		# from health loss handles it naturally first.
		if action == "wall_left" or action == "wall_right":
			if player.is_on_floor() and player_z >= gate_z - 7.0:
				gate_judged[i] = true
				gate_success[i] = true
				_mark_gate_result(i, true)
				# First successful wall-jump landing activates the score bonus
				if _wj_mult_timer <= 0.0:
					_activate_wj_bonus()
				continue
			if player_z > gate_z + 18.0:        # well past — never landed
				gate_judged[i] = true
				gate_success[i] = false
				_mark_gate_result(i, false)
			continue   # never fall through to the standard miss check below

		# ── Charge-tunnel skip: player is free-sliding through a drop buildup ──
		# They can't act on normal gates while threading hoops; auto-pass silently.
		if player.is_charge_sliding():
			gate_judged[i] = true
			gate_success[i] = false
			if i < gate_nodes.size() and is_instance_valid(gate_nodes[i]):
				gate_nodes[i].visible = false
			continue

		# ── Grind skip: player is riding the rail through a rap segment ────────
		# The player traded gate income for spark income — skip judgment silently.
		if player.is_grinding() and _is_in_rap_segment(gate_z / player.forward_speed):
			gate_judged[i] = true
			gate_success[i] = false   # not a hit; not a miss — invisible skip
			# Hide the gate immediately so it doesn't show as a miss flash
			if i < gate_nodes.size() and is_instance_valid(gate_nodes[i]):
				gate_nodes[i].visible = false
			continue

		# ── Per-frame success check (works reliably on all path segments) ─────
		# Area3D body_entered can miss after a 90° path rotation because the
		# physics transform sync and the process-rate miss-check race each other.
		# We instead check directly: if the player is in the gate's depth window
		# AND in the correct physical state, count it as a hit immediately.
		if player_z >= gate_z - gate_depth * 0.45 and player_z <= gate_z + gate_depth * 0.45:
			var passed: bool = false
			match action:
				"jump":
					passed = player.is_airborne()
				"slide":
					passed = player.is_sliding()
				_:   # "left", "right" — check lateral proximity to safe lane
					if not _track_segs.is_empty():
						var cs: TrackSeg   = _track_segs[_last_seg_idx] as TrackSeg
						var seg_ctr: Vector3 = cs.origin + cs.direction * (_player_path_dist - cs.path_start)
						var cur_lat: float   = (player.global_position - seg_ctr).dot(cs.right)
						passed = abs(cur_lat - player.lane_xs[safe_lane]) < lane_blocker_width * 0.55
			if passed:
				gate_judged[i] = true
				gate_success[i] = true
				_mark_gate_result(i, true)
			continue   # still inside the window — do not fire miss yet

		# ── Standard miss (non-wall-jump gates only) ───────────────────────
		# Once the player is clearly past the gate and never triggered it, miss.
		if player_z > gate_z + (gate_depth * 0.65):
			gate_judged[i] = true
			gate_success[i] = false
			_check_near_miss(i, entry, action)
			_mark_gate_result(i, false)


# ── SFX ──────────────────────────────────────────────────────────────────────

func _build_miss_sfx() -> void:
	# MISS — two detuned low tones (85 Hz + 112 Hz) that beat against each other,
	# giving a dissonant "thunk/buzz" — clearly negative, not too harsh.
	var sr: int  = 22050
	var n:  int  = int(0.26 * sr)
	var data: PackedByteArray = PackedByteArray(); data.resize(n * 2)
	var p1: float = 0.0; var p2: float = 0.0
	for i in range(n):
		var t:   float = float(i) / float(n)
		var env: float = (1.0 - t) * (1.0 - t) * 0.92   # quadratic decay = thumpy
		p1 += 85.0  / float(sr)
		p2 += 112.0 / float(sr)   # detuned ~minor-third = dissonant
		var sample: float = (sin(p1 * TAU) * 0.58 + sin(p2 * TAU) * 0.42) * env
		var s: int = int(clamp(sample, -1.0, 1.0) * 32767.0)
		data[i * 2]     = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.data = data; wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sr; wav.stereo = false
	_sfx_miss = AudioStreamPlayer.new()
	_sfx_miss.stream    = wav
	_sfx_miss.volume_db = -5.0
	_sfx_miss.bus       = "Master"
	add_child(_sfx_miss)


# ── Near-miss system ─────────────────────────────────────────────────────────
# Detects when the player "almost" made it and awards a small score bonus.

func _check_near_miss(idx: int, entry: Dictionary, action: String) -> void:
	if player == null:
		return
	var is_near: bool = false

	match action:
		"left", "right":
			# Near if player is in the adjacent lane to the target
			var safe_lane: int = int(entry.get("safe_lane", 1))
			var target_x:  float = player.lane_xs[clamp(safe_lane, 0, player.lane_xs.size() - 1)]
			var lane_gap:  float = 2.4   # spacing between lanes
			is_near = abs(player.global_position.x - target_x) < lane_gap * 1.8
		"jump":
			# Near if the player made any upward movement (was at least trying to jump)
			is_near = player.velocity.y > 1.0 or not player.is_on_floor()
		"slide":
			# Near if the player recently started a slide (slide_timer close to max)
			is_near = player.slide_timer > 0.0

	if is_near:
		_award_near_miss(idx)


func _award_near_miss(_idx: int) -> void:
	# Award a flat 25-point bonus (intentionally small, not multiplier-scaled)
	_score += 25
	_update_hud_score()

	# Reuse the same HUD root that streak milestones use
	if _hud_flash == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return

	var lbl := Label.new()
	lbl.text = "NEAR!"
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color(1.00, 0.82, 0.10, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lbl.grow_vertical   = Control.GROW_DIRECTION_BOTH
	lbl.offset_top      = 60    # slightly below center so it doesn't clash with streak labels
	lbl.offset_bottom   = 60 + 38
	lbl.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	lbl.modulate.a      = 0.0
	root.add_child(lbl)

	var tw := create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, 0.08)
	tw.tween_property(lbl, "modulate", Color(1.4, 1.2, 0.3, 1.0), 0.08)
	tw.tween_property(lbl, "modulate", Color(1.0, 0.82, 0.10, 1.0), 0.10)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.28)
	tw.tween_callback(lbl.queue_free)


# ── HUD ──────────────────────────────────────────────────────────────────────

func _create_hud() -> void:
	_health_pct = 0.25

	var cl := CanvasLayer.new()
	cl.layer = 20
	add_child(cl)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(root)

	# ── Score + Combo block (top-right) ───────────────────────────────────────
	var score_glow := ColorRect.new()
	score_glow.anchor_left  = 1.0; score_glow.anchor_right  = 1.0
	score_glow.anchor_top   = 0.0; score_glow.anchor_bottom = 0.0
	score_glow.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	score_glow.offset_left  = -210; score_glow.offset_right  = -10
	score_glow.offset_top   = 10;   score_glow.offset_bottom = 102
	score_glow.color = Color(0.65, 0.18, 1.00, 0.38)
	score_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(score_glow)

	var score_bg := ColorRect.new()
	score_bg.anchor_left  = 1.0; score_bg.anchor_right  = 1.0
	score_bg.anchor_top   = 0.0; score_bg.anchor_bottom = 0.0
	score_bg.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	score_bg.offset_left  = -208; score_bg.offset_right  = -12
	score_bg.offset_top   = 12;   score_bg.offset_bottom = 100
	score_bg.color = Color(0.04, 0.02, 0.10, 0.90)
	score_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(score_bg)

	var score_cap := Label.new()
	score_cap.text = "SCORE"
	score_cap.anchor_left  = 1.0; score_cap.anchor_right  = 1.0
	score_cap.anchor_top   = 0.0; score_cap.anchor_bottom = 0.0
	score_cap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	score_cap.offset_left  = -202; score_cap.offset_right  = -18
	score_cap.offset_top   = 18;   score_cap.offset_bottom = 36
	score_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_cap.add_theme_color_override("font_color", Color(0.68, 0.28, 1.00, 0.65))
	score_cap.add_theme_font_size_override("font_size", 10)
	score_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(score_cap)

	_hud_score_label = Label.new()
	_hud_score_label.text = "0"
	_hud_score_label.anchor_left  = 1.0; _hud_score_label.anchor_right  = 1.0
	_hud_score_label.anchor_top   = 0.0; _hud_score_label.anchor_bottom = 0.0
	_hud_score_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_score_label.offset_left  = -202; _hud_score_label.offset_right  = -16
	_hud_score_label.offset_top   = 34;   _hud_score_label.offset_bottom = 72
	_hud_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud_score_label.add_theme_color_override("font_color", Color(1.00, 0.50, 0.85, 1.0))
	_hud_score_label.add_theme_font_size_override("font_size", 30)
	_hud_score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_score_label)

	_hud_combo_label = Label.new()
	_hud_combo_label.text = ""
	_hud_combo_label.anchor_left  = 1.0; _hud_combo_label.anchor_right  = 1.0
	_hud_combo_label.anchor_top   = 0.0; _hud_combo_label.anchor_bottom = 0.0
	_hud_combo_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_combo_label.offset_left  = -202; _hud_combo_label.offset_right  = -16
	_hud_combo_label.offset_top   = 72;   _hud_combo_label.offset_bottom = 92
	_hud_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud_combo_label.add_theme_color_override("font_color", Color(1.00, 0.88, 0.22, 1.0))
	_hud_combo_label.add_theme_font_size_override("font_size", 13)
	_hud_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_combo_label)

	# ── Health bar (top-left) ─────────────────────────────────────────────────
	# Layout: [HP label] [████░░░░░░] percentage bar
	var bar_w:   float = 180.0
	var bar_h:   float = 16.0
	var bar_x:   float = 12.0
	var bar_y:   float = 12.0
	var label_w: float = 28.0

	# "HP" label
	_hud_hp_label = Label.new()
	_hud_hp_label.text = "HP"
	_hud_hp_label.anchor_left   = 0.0; _hud_hp_label.anchor_right  = 0.0
	_hud_hp_label.anchor_top    = 0.0; _hud_hp_label.anchor_bottom = 0.0
	_hud_hp_label.offset_left   = bar_x
	_hud_hp_label.offset_right  = bar_x + label_w
	_hud_hp_label.offset_top    = bar_y
	_hud_hp_label.offset_bottom = bar_y + bar_h + 12
	_hud_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hud_hp_label.add_theme_color_override("font_color", Color(1.00, 0.45, 0.72, 0.80))
	_hud_hp_label.add_theme_font_size_override("font_size", 11)
	_hud_hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_hp_label)

	var bx: float = bar_x + label_w + 4.0

	# Outer glow border
	var bar_glow := ColorRect.new()
	bar_glow.anchor_left = 0.0; bar_glow.anchor_right  = 0.0
	bar_glow.anchor_top  = 0.0; bar_glow.anchor_bottom = 0.0
	bar_glow.offset_left   = bx - 2;       bar_glow.offset_right  = bx + bar_w + 2
	bar_glow.offset_top    = bar_y - 2;    bar_glow.offset_bottom = bar_y + bar_h + 2
	bar_glow.color = Color(1.00, 0.35, 0.65, 0.30)
	bar_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar_glow)

	# Dark track background
	var bar_track := ColorRect.new()
	bar_track.anchor_left = 0.0; bar_track.anchor_right  = 0.0
	bar_track.anchor_top  = 0.0; bar_track.anchor_bottom = 0.0
	bar_track.offset_left   = bx;       bar_track.offset_right  = bx + bar_w
	bar_track.offset_top    = bar_y;    bar_track.offset_bottom = bar_y + bar_h
	bar_track.color = Color(0.04, 0.02, 0.10, 0.92)
	bar_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar_track)

	# Half-fill marker (faint line at 50%)
	var half_marker := ColorRect.new()
	half_marker.anchor_left = 0.0; half_marker.anchor_right  = 0.0
	half_marker.anchor_top  = 0.0; half_marker.anchor_bottom = 0.0
	half_marker.offset_left   = bx + bar_w * 0.5 - 1
	half_marker.offset_right  = bx + bar_w * 0.5 + 1
	half_marker.offset_top    = bar_y
	half_marker.offset_bottom = bar_y + bar_h
	half_marker.color = Color(1.0, 1.0, 1.0, 0.20)
	half_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(half_marker)

	# Fill rect — we animate its right offset to show current HP%
	_hud_hp_fill = ColorRect.new()
	_hud_hp_fill.anchor_left = 0.0; _hud_hp_fill.anchor_right  = 0.0
	_hud_hp_fill.anchor_top  = 0.0; _hud_hp_fill.anchor_bottom = 0.0
	_hud_hp_fill.offset_left   = bx
	_hud_hp_fill.offset_right  = bx + bar_w * _health_pct
	_hud_hp_fill.offset_top    = bar_y
	_hud_hp_fill.offset_bottom = bar_y + bar_h
	_hud_hp_fill.color = Color(0.35, 1.00, 0.55, 1.0)   # green at start (mid)
	_hud_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_hp_fill)

	# Percentage text (right of bar)
	var pct_label := Label.new()
	pct_label.name = "HpPctLabel"
	pct_label.text = "50%"
	pct_label.anchor_left = 0.0; pct_label.anchor_right  = 0.0
	pct_label.anchor_top  = 0.0; pct_label.anchor_bottom = 0.0
	pct_label.offset_left   = bx + bar_w + 6
	pct_label.offset_right  = bx + bar_w + 56
	pct_label.offset_top    = bar_y
	pct_label.offset_bottom = bar_y + bar_h + 4
	pct_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pct_label.add_theme_color_override("font_color", Color(0.90, 0.90, 0.95, 0.70))
	pct_label.add_theme_font_size_override("font_size", 11)
	pct_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pct_label)

	# ── Song progress bar (bottom of screen) ─────────────────────────────────
	var prog_bg := ColorRect.new()
	prog_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	prog_bg.anchor_top    = 1.0; prog_bg.anchor_bottom = 1.0
	prog_bg.grow_vertical = Control.GROW_DIRECTION_BEGIN
	prog_bg.offset_top    = -6;  prog_bg.offset_bottom = 0
	prog_bg.color = Color(0.05, 0.02, 0.12, 0.88)
	prog_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(prog_bg)

	_hud_progress_fill = ColorRect.new()
	_hud_progress_fill.anchor_left   = 0.0; _hud_progress_fill.anchor_right  = 0.0
	_hud_progress_fill.anchor_top    = 1.0; _hud_progress_fill.anchor_bottom = 1.0
	_hud_progress_fill.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud_progress_fill.offset_left   = 0; _hud_progress_fill.offset_right  = 0
	_hud_progress_fill.offset_top    = -6; _hud_progress_fill.offset_bottom = 0
	_hud_progress_fill.color = Color(0.75, 0.22, 1.00, 1.0)   # violet
	_hud_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_progress_fill)

	# Tiny glow cap at the leading edge of the progress fill
	var prog_cap := ColorRect.new()
	prog_cap.name = "ProgCap"
	prog_cap.anchor_left   = 0.0; prog_cap.anchor_right  = 0.0
	prog_cap.anchor_top    = 1.0; prog_cap.anchor_bottom = 1.0
	prog_cap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	prog_cap.offset_left   = 0;   prog_cap.offset_right  = 4
	prog_cap.offset_top    = -8;  prog_cap.offset_bottom = 0
	prog_cap.color = Color(1.0, 0.75, 1.0, 0.85)
	prog_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(prog_cap)

	# ── Full-screen edge flash (hit / miss feedback) ───────────────────────────
	_hud_flash = ColorRect.new()
	_hud_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_flash.color = Color(0.0, 0.0, 0.0, 0.0)
	_hud_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud_flash)

	# Wall-jump bonus label — centred, gold, visible only while bonus is active
	_hud_wj_label = Label.new()
	_hud_wj_label.text = "⬆ WALL JUMP  ×2 !"
	_hud_wj_label.anchor_left   = 0.5; _hud_wj_label.anchor_right  = 0.5
	_hud_wj_label.anchor_top    = 0.0; _hud_wj_label.anchor_bottom = 0.0
	_hud_wj_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud_wj_label.offset_left  = -200; _hud_wj_label.offset_right  = 200
	_hud_wj_label.offset_top   = 100;  _hud_wj_label.offset_bottom = 140
	_hud_wj_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_wj_label.add_theme_color_override("font_color",   Color(1.00, 0.82, 0.10, 1.0))
	_hud_wj_label.add_theme_font_size_override("font_size", 26)
	_hud_wj_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_wj_label.visible = false
	root.add_child(_hud_wj_label)

	# Grind / FLOW label — bottom-centre, orange, shown during active rap segment
	_hud_grind_label = Label.new()
	_hud_grind_label.text = ""
	_hud_grind_label.anchor_left   = 0.5; _hud_grind_label.anchor_right  = 0.5
	_hud_grind_label.anchor_top    = 1.0; _hud_grind_label.anchor_bottom = 1.0
	_hud_grind_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud_grind_label.offset_left   = -220; _hud_grind_label.offset_right  = 220
	_hud_grind_label.offset_top    = -52;  _hud_grind_label.offset_bottom = -18
	_hud_grind_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_grind_label.add_theme_color_override("font_color",   Color(1.00, 0.60, 0.10, 1.0))
	_hud_grind_label.add_theme_font_size_override("font_size", 18)
	_hud_grind_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_grind_label.visible = false
	root.add_child(_hud_grind_label)

	# Charge meter — bottom-centre, cyan, shown only during a drop buildup. Sits a row
	# above the grind label so the two never overlap.
	_hud_charge_label = Label.new()
	_hud_charge_label.text = ""
	_hud_charge_label.anchor_left   = 0.5; _hud_charge_label.anchor_right  = 0.5
	_hud_charge_label.anchor_top    = 1.0; _hud_charge_label.anchor_bottom = 1.0
	_hud_charge_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud_charge_label.offset_left   = -320; _hud_charge_label.offset_right  = 320
	_hud_charge_label.offset_top    = -92;  _hud_charge_label.offset_bottom = -58
	_hud_charge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_charge_label.add_theme_color_override("font_color", Color(0.45, 0.95, 1.00, 1.0))
	_hud_charge_label.add_theme_font_size_override("font_size", 20)
	_hud_charge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_charge_label.visible = false
	root.add_child(_hud_charge_label)

	# Lyrics row — fixed at bottom of screen (positioned each frame in _update_lyrics).
	# Words fly in one at a time with neon glow; sentence lines appear whole.
	_lyrics_hud = HBoxContainer.new()
	_lyrics_hud.add_theme_constant_override("separation", 12)
	_lyrics_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lyrics_hud.visible = false
	root.add_child(_lyrics_hud)

	_update_hud_score()
	_update_hud_health()


# ════════════════════════════════════════════════════════════════════════════
# RAP / GRIND-RAIL SYSTEM
# ════════════════════════════════════════════════════════════════════════════

# Drives the lyric row each frame: picks the active line, reveals rap words as their times
# pass (sentence lines appear whole), positions at bottom-centre, and fades out at end.
func _update_lyrics(t_s: float) -> void:
	if _lyrics_hud == null or _lyrics.is_empty():
		return
	var idx: int = -1
	for i in range(_lyrics.size()):
		var e: Dictionary = _lyrics[i]
		if t_s >= float(e["t_start"]) - 0.05 and t_s < float(e["t_end"]) + _LYRICS_HOLD_S:
			idx = i
	if idx != _lyrics_active_idx:
		_lyrics_active_idx = idx
		for c in _lyrics_hud.get_children():
			c.queue_free()
		_lyrics_revealed = 0
		_lyrics_hud.modulate.a = 1.0
		# Slide-in entrance: start 28 px below, tween to resting position.
		_lyrics_slide_off = 28.0
		create_tween().tween_property(self, "_lyrics_slide_off", 0.0, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if idx < 0:
		_lyrics_hud.visible = false
		return
	_lyrics_hud.visible = true
	var cur: Dictionary = _lyrics[idx]
	if String(cur["mode"]) == "rap":
		var words: Array = cur["words"]
		while _lyrics_revealed < words.size() and t_s >= float(words[_lyrics_revealed]["t"]):
			_lyrics_pop_word(String(words[_lyrics_revealed]["w"]), _lyrics_revealed)
			_lyrics_revealed += 1
	elif _lyrics_revealed == 0:
		# Split into individual words so each gets its own colour.
		var word_list := String(cur["text"]).split(" ", false)
		for wi: int in range(word_list.size()):
			_lyrics_pop_word(word_list[wi], wi, wi * 0.07)
		_lyrics_revealed = max(1, word_list.size())
	# Fixed position: bottom 20 % of screen, centred horizontally.
	var vp := get_viewport().get_visible_rect().size
	_lyrics_hud.position = Vector2(
		vp.x * 0.5 - _lyrics_hud.size.x * 0.5,
		vp.y * 0.80 + _lyrics_slide_off
	)
	# Fade out as the line hold ends.
	var fade_end: float = float(cur["t_end"]) + _LYRICS_HOLD_S
	_lyrics_hud.modulate.a = clampf((fade_end - t_s) / 0.4, 0.0, 1.0)


# Spawns one word into the lyric row. color_idx drives the rainbow cycle; delay lets
# line-mode words stagger in. Words fly up, elastic-bounce, then idle-float.
func _lyrics_pop_word(w: String, color_idx: int, delay: float = 0.0) -> void:
	if _lyrics_hud == null:
		return
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(_lyrics_hud):
			return
	var col: Color = _LYRIC_COLORS[color_idx % _LYRIC_COLORS.size()]
	var lbl := Label.new()
	lbl.text = w
	if _lyric_font != null:
		lbl.add_theme_font_override("font", _lyric_font)
	lbl.add_theme_font_size_override("font_size", 40)
	lbl.add_theme_color_override("font_color",         Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_outline_color", col)
	lbl.add_theme_constant_override("outline_size", 10)
	lbl.add_theme_color_override("font_shadow_color",  Color(col.r, col.g, col.b, 0.55))
	lbl.add_theme_constant_override("shadow_offset_x", 0)
	lbl.add_theme_constant_override("shadow_offset_y", 0)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lyrics_hud.add_child(lbl)
	# Start below and invisible; scale at 1.15 for a quick squish-in feel.
	lbl.position.y = 32.0
	lbl.modulate.a = 0.0
	lbl.scale      = Vector2(1.15, 1.15)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", 0.0, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 1.0, 0.16)
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	# After landing: gentle idle float bound to the label (auto-stops when label is freed).
	await get_tree().create_timer(0.26).timeout
	if not is_instance_valid(lbl):
		return
	var phase: float = randf() * TAU   # stagger so words don't all bob in sync
	var float_tw := lbl.create_tween().set_loops()
	float_tw.tween_property(lbl, "position:y", -5.0 + sin(phase) * 2.0, 0.85 + randf() * 0.15) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	float_tw.tween_property(lbl, "position:y", 0.0 + sin(phase) * 2.0, 0.85 + randf() * 0.15) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# Parses the optional "lyrics" array from the chart. Two entry shapes:
#   rap  → {"mode":"rap","words":[{"t":sec,"w":"word"}, …]}   (per-word timing)
#   line → {"mode":"line","t":sec,"text":"whole sentence"}    (sung — shown all at once)
func _parse_lyrics(d: Dictionary) -> void:
	_lyrics.clear()
	_lyrics_active_idx = -1
	var raw: Variant = d.get("lyrics", [])
	if not (raw is Array):
		return
	for item in (raw as Array):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		var mode: String = String(it.get("mode", "line"))
		if mode == "rap" and it.get("words") is Array:
			var words: Array = []
			for w in (it.get("words") as Array):
				if w is Dictionary:
					words.append({"t": float((w as Dictionary).get("t", 0.0)), "w": String((w as Dictionary).get("w", ""))})
			if words.is_empty():
				continue
			words.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["t"]) < float(b["t"]))
			var txt: String = ""
			for w2 in words:
				txt += (" " if txt != "" else "") + String(w2["w"])
			_lyrics.append({
				"mode": "rap", "words": words, "text": txt,
				"t_start": float(words[0]["t"]), "t_end": float(words[words.size() - 1]["t"]),
			})
		else:
			var t0: float = float(it.get("t", 0.0))
			var t1: float = float(it.get("t_end", t0))   # optional stop; ≤ start → falls back to hold
			_lyrics.append({
				"mode": "line", "words": [], "text": String(it.get("text", "")),
				"t_start": t0, "t_end": maxf(t0, t1),
			})
	_lyrics.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["t_start"]) < float(b["t_start"]))


func _parse_rap_data(d: Dictionary) -> void:
	_rap_segs.clear()
	_rap_taps_t.clear()
	_rap_tap_pds.clear()

	# ── Segments ──────────────────────────────────────────────────────────────
	var raw_segs: Variant = d.get("rap_segments", [])
	if raw_segs is Array:
		for s in (raw_segs as Array):
			if s is Dictionary:
				var sd: Dictionary = s
				var st: float = float(sd.get("start_t", 0.0))
				var et: float = float(sd.get("end_t",   0.0))
				if et > st:
					var seg: Dictionary = {"start_t": st, "end_t": et}
					# Optional authored rail trick + exact-control overrides. Absent → the
					# grind rolls a random trick per the run seed (unchanged for other levels).
					if sd.has("trick"):
						seg["trick"] = String(sd.get("trick", ""))
					for k in ["height", "lat", "turns"]:
						if sd.has(k):
							seg[k] = float(sd.get(k, 0.0))
					_rap_segs.append(seg)

	if _rap_segs.is_empty():
		return   # no rap data — grind system will be inactive

	# ── Manual taps ───────────────────────────────────────────────────────────
	var raw_taps: Variant = d.get("rap_taps", [])
	if raw_taps is Array:
		for tap in (raw_taps as Array):
			_rap_taps_t.append(float(tap))

	# ── Auto-subdivision fallback ─────────────────────────────────────────────
	# If the chart has no manual taps, subdivide each segment at 8th-note intervals.
	# The player won't notice the difference unless they've memorised the song.
	if _rap_taps_t.is_empty():
		var subdiv: float = maxf(0.08, _runner_avg_beat_s * 0.5)
		for seg in _rap_segs:
			var t:  float = float(seg.get("start_t", 0.0))
			var et: float = float(seg.get("end_t",   0.0))
			while t <= et + 0.001:
				_rap_taps_t.append(t)
				t += subdiv

	_rap_taps_t.sort()

	# Convert to path distances once here — used every frame during the run
	for tt in _rap_taps_t:
		_rap_tap_pds.append(tt * player.forward_speed)


## Reads the chart's "drop_buildups" markers (charge-tunnel sections). Absent → the
## charge system stays dormant (every other level is unchanged).
func _parse_drop_buildups(d: Dictionary) -> void:
	_drop_buildups.clear()
	var raw: Variant = d.get("drop_buildups", [])
	if raw is Array:
		for s in (raw as Array):
			if s is Dictionary:
				var sd: Dictionary = s
				var st: float = float(sd.get("start_t", 0.0))
				var et: float = float(sd.get("end_t",   0.0))
				if et > st:
					_drop_buildups.append({"start_t": st, "end_t": et})
	_drop_buildups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("start_t", 0.0)) < float(b.get("start_t", 0.0)))

func _parse_electric_zones(d: Dictionary) -> void:
	_electric_zones.clear()
	var raw: Variant = d.get("electric_zones", [])
	if raw is Array:
		for s in (raw as Array):
			if s is Dictionary:
				var sd: Dictionary = s
				var st: float = float(sd.get("start_t", 0.0))
				var et: float = float(sd.get("end_t",   0.0))
				if et > st:
					_electric_zones.append({"start_t": st, "end_t": et})
	_electric_zones.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("start_t", 0.0)) < float(b.get("start_t", 0.0)))
	# Backward compat: old maps with "theme": "electric" → treat whole song as electric
	if _electric_zones.is_empty():
		var legacy: String = String(d.get("theme", "city")).strip_edges()
		if legacy == "electric":
			_electric_zones.append({"start_t": 0.0, "end_t": 99999.0})


## Returns true if the given song-time (seconds) falls inside any rap segment.
func _is_in_rap_segment(t_s: float) -> bool:
	for seg in _rap_segs:
		if t_s >= float(seg.get("start_t", 0.0)) and t_s <= float(seg.get("end_t", 0.0)):
			return true
	return false


# ════════════════════════════════════════════════════════════════════════════
# Charge tunnel — drop-buildup hoop threading → ×100 multiplier window
# ════════════════════════════════════════════════════════════════════════════

## Lateral offset (metres from track centre) of the hoop opening at a path distance.
## A smooth side-to-side weave the player must follow to keep threading hoops.
func _gap_curve_x(pd: float) -> float:
	return sin((pd - _charge_seg_start_pd) * _CHARGE_WEAVE_FREQ) * _CHARGE_WEAVE_AMP


## Manages the post-WJ descent slide each frame.
## - Locks / unlocks jumping (player can't escape the slide early).
## - Detects wrong-lane contact: if the player steps onto an electrified rail,
##   they get shocked (combo break + health hit + screen flash), once per 1.5 s.
func _update_wj_slide(delta: float) -> void:
	if _wj_slide_start_z < 0.0 or player == null:
		return

	var pz: float = _player_path_dist
	var should_slide: bool = pz >= _wj_slide_start_z and pz < _wj_slide_end_z + 4.0

	if should_slide != _wj_slide_engaged:
		_wj_slide_engaged = should_slide
		player.set_jump_locked(should_slide)
		if not should_slide:
			_wj_shock_cd = 0.0   # reset so next slide starts fresh

	if not _wj_slide_engaged or _wj_slide_safe_lane < 0:
		return

	# Shock cooldown
	_wj_shock_cd = maxf(0.0, _wj_shock_cd - delta)

	# Check if player is on an electrified lane
	if player.current_lane != _wj_slide_safe_lane and _wj_shock_cd <= 0.0:
		_wj_shock_cd = 1.5   # 1.5 s before next shock
		_combo = 0
		_health_pct = clampf(_health_pct - 0.08, 0.0, 1.0)
		_update_hud_score()
		_update_hud_health()
		_hud_flash_color(Color(1.00, 0.85, 0.10, 0.60), 0.35)   # electric yellow flash
		_shake_camera()


func _update_charge_tunnel(t_s: float, delta: float) -> void:
	if _drop_buildups.is_empty():
		return

	# Active buildup = the one whose [start-lead, end) window holds now. The window ends
	# exactly at end_t (the drop) so the tunnel tears down on the downbeat.
	var cur: Dictionary = {}
	for seg in _drop_buildups:
		var st: float = float(seg.get("start_t", 0.0))
		var et: float = float(seg.get("end_t",   0.0))
		if t_s >= st - _CHARGE_LEAD_S and t_s < et:
			cur = seg
			break

	if cur.is_empty():
		# Past the drop (or between buildups): resolve the payoff once, then tear down.
		if _charge_active:
			if _charge_building and not _charge_finalized:
				_charge_finalized = true
				_finalize_charge(t_s)
			_despawn_charge_tunnel()
		return

	if not _charge_active:
		_spawn_charge_tunnel(cur)

	# Enter the buildup proper at start_t: hand the player to free-slide.
	var st2: float = float(cur.get("start_t", 0.0))
	if t_s >= st2 and not _charge_building:
		_charge_building = true
		player.set_charge_slide(true, _CHARGE_WEAVE_AMP + _CHARGE_GAP_RADIUS + 0.6, 7.0)

	if _charge_building:
		var pd:       float = _player_path_dist
		var holding:  bool  = Input.is_action_pressed("runner_grind")
		var target_x: float = _gap_curve_x(pd)
		var aligned:  bool  = absf(player.charge_lateral() - target_x) < _CHARGE_GAP_RADIUS

		if not holding:
			_charge = maxf(0.0, _charge - _CHARGE_LETGO_BLEED * delta)   # let go early = fizzle
		elif aligned:
			_charge = minf(1.0, _charge + _CHARGE_FILL_RATE * delta)     # threading cleanly
		else:
			_charge = maxf(0.0, _charge - _CHARGE_CLIP_BLEED * delta)    # clipping the rim

		# Remember the song-time of each hold→release edge — used for drop-timing on release.
		if _charge_last_held and not holding:
			_charge_release_t = t_s
		_charge_last_held = holding

	_update_charge_hud()


func _spawn_charge_tunnel(seg: Dictionary) -> void:
	_charge_active       = true
	_charge_building     = false
	_charge_finalized    = false
	_charge              = 0.0
	_charge_release_t    = -1.0
	_charge_last_held    = false
	_charge_seg          = seg
	_charge_seg_start_pd = float(seg.get("start_t", 0.0)) * player.forward_speed
	_charge_seg_end_pd   = float(seg.get("end_t",   0.0)) * player.forward_speed

	_charge_root      = Node3D.new()
	_charge_root.name = "ChargeTunnel"
	gates_root.add_child(_charge_root)

	# Authored Blender hoops ("charge_hoop") replace the procedural torus.
	# Uniform scale keeps the authored opening exactly at the game's 1.15 m
	# alignment tolerance, whatever size the piece was modelled at.
	var hoop_entry: Dictionary = (_piece_lib.first_of("charge_hoop") if _piece_lib != null else {})
	var hoop_scale: float = 1.0
	if not hoop_entry.is_empty():
		hoop_scale = _CHARGE_GAP_RADIUS / maxf(0.05, float(hoop_entry.params.get("gap", 1.15)))

	# One shared ring mesh; the opening is the torus hole, centred on the weave curve.
	var ring := TorusMesh.new()
	ring.inner_radius  = _CHARGE_GAP_RADIUS
	ring.outer_radius  = _CHARGE_GAP_RADIUS + 0.16
	ring.rings         = 8
	ring.ring_segments = 20

	var pd:  float = _charge_seg_start_pd
	var idx: int   = 0
	while pd <= _charge_seg_end_pd:
		var gx: float = _gap_curve_x(pd)
		var pivot := Node3D.new()
		pivot.position           = _path_world_pos(pd, gx, _CHARGE_HEIGHT)
		pivot.rotation_degrees.y = _path_y_rot_at(pd)
		_charge_root.add_child(pivot)

		if not hoop_entry.is_empty():
			var h_inst: Node3D = _piece_lib.instance(hoop_entry)
			h_inst.rotation_degrees.y = 180.0
			h_inst.scale = Vector3.ONE * hoop_scale
			pivot.add_child(h_inst)
		else:
			var hoop := MeshInstance3D.new()
			hoop.mesh = ring
			hoop.rotation_degrees.x = 90.0   # stand the donut up so the hole faces along the path
			var col: Color = Color.from_hsv(0.55 + 0.10 * sin(float(idx) * 0.5), 0.70, 1.00)
			var mat := StandardMaterial3D.new()
			mat.albedo_color                = col
			mat.emission_enabled            = true
			mat.emission                    = col
			mat.emission_energy_multiplier  = 2.2
			hoop.material_override = mat
			pivot.add_child(hoop)

		idx += 1
		pd  += _CHARGE_HOOP_SPACING

	if _hud_charge_label != null:
		_hud_charge_label.visible = true


func _despawn_charge_tunnel() -> void:
	if _charge_root != null and is_instance_valid(_charge_root):
		_charge_root.queue_free()
	_charge_root     = null
	_charge_active   = false
	_charge_building = false
	if player != null:
		player.set_charge_slide(false)
	if _hud_charge_label != null:
		_hud_charge_label.visible = false


## Cash in the charge on the drop. Final fill = charge × release-timing quality; a high
## enough fill snaps the multiplier to ×100 for a window whose LENGTH scales with the fill.
func _finalize_charge(t_s: float) -> void:
	var et: float = float(_charge_seg.get("end_t", t_s))

	# Release timing: best when the player let go right on the drop downbeat. Still holding
	# at the drop = never popped it → partial. Released within the window → scaled by how
	# close. Released long before → ~0 (and the charge already bled away anyway).
	var timing: float
	if _charge_last_held:
		timing = 0.5
	elif _charge_release_t >= 0.0:
		timing = clampf(1.0 - absf(_charge_release_t - et) / _CHARGE_REL_WIN_S, 0.0, 1.0)
	else:
		timing = 0.0

	var fill: float = _charge * lerpf(0.45, 1.0, timing)

	player.set_charge_slide(false)   # hand back to lane play for the drop

	if fill >= _CHARGE_MIN_FILL:
		_charge_mult_timer = lerpf(_CHARGE_MULT_MIN_S, _CHARGE_MULT_MAX_S, clampf(fill, 0.0, 1.0))
		_hud_flash_color(Color(0.30, 0.85, 1.00, 0.40), 0.55)
		_show_grind_banner("⚡  ×%d  OVERDRIVE  (%.1fs)" % [_CHARGE_MULT_VALUE, _charge_mult_timer],
			Color(0.40, 0.90, 1.00))
		_shake_camera()
	else:
		_show_grind_banner("…charge fizzled", Color(0.60, 0.60, 0.72))
	_charge = 0.0


func _update_charge_hud() -> void:
	if _hud_charge_label == null:
		return
	if not _charge_active:
		_hud_charge_label.visible = false
		return
	_hud_charge_label.visible = true
	var filled: int = clampi(int(round(_charge * 10.0)), 0, 10)
	var bar: String = ""
	for i in range(10):
		bar += "█" if i < filled else "░"
	var state: String = "HOLD ⟂ THREAD" if _charge_building else "GET READY"
	_hud_charge_label.text = "⚡ CHARGE  [%s]  %d%%   %s" % [bar, int(round(_charge * 100.0)), state]
	_hud_charge_label.add_theme_color_override("font_color",
		Color(0.45, 0.95, 1.00).lerp(Color(1.00, 0.95, 0.35), _charge))


func _update_grind_system(t_s: float) -> void:
	if _rap_segs.is_empty():
		return

	# ── Segment activation ────────────────────────────────────────────────────
	var in_seg: bool = false
	for seg in _rap_segs:
		var st: float = float(seg.get("start_t", 0.0))
		var et: float = float(seg.get("end_t",   0.0))
		# Spawn the rail 3 s before the segment begins so the player can see it
		if t_s >= st - 3.0 and t_s < et + 0.5:
			if not _grind_rail_active:
				_spawn_grind_rail(seg)
			in_seg = true
			break

	if not in_seg and _grind_rail_active:
		_despawn_grind_rail()
		return

	if not _grind_rail_active:
		return

	# ── Per-frame updates ─────────────────────────────────────────────────────
	_update_spark_visibility()
	_check_missed_sparks()

	# Inform player whether the rail is reachable, and where it is right now (the
	# rail branches off the track, so pass the eased lateral + height at the player's
	# current path distance). Once failed, the rail is no longer available → drop off.
	var pd:  float = _player_path_dist
	var ok:  bool  = pd >= _grind_seg_start_pd - 12.0 and pd < _grind_seg_end_pd and not _grind_failed
	var off: Vector2 = _grind_branch_offset(pd)
	player.set_grind_rail(ok, _GRIND_RAIL_LATERAL + off.x, off.y,
		_grind_branch_roll(pd) + _grind_branch_lean(pd), _grind_branch_pitch(pd))

	# Mark the segment as "played" the moment the player commits to the rail — only then do
	# its sparks count toward the song note total (skipping a rap section costs nothing).
	if player.is_grinding():
		_grind_engaged_this_seg = true

	_update_grind_hud()


func _spawn_grind_rail(seg: Dictionary) -> void:
	_grind_rail_active  = true
	var st: float = float(seg.get("start_t", 0.0))
	var et: float = float(seg.get("end_t",   0.0))
	_grind_seg_start_pd = st * player.forward_speed
	_grind_seg_end_pd   = et * player.forward_speed

	# Roll this segment's trick BEFORE building the rail — the rail, the sparks, and the
	# player must all read the SAME branch params. (Bug fixed: the mesh used to be built
	# before the roll, so the orbs followed the new path but the rail used stale params.)
	_roll_grind_trick(seg)

	# Parent node — all rail meshes + spark nodes are children of this
	_grind_rail_root      = Node3D.new()
	_grind_rail_root.name = "GrindRail"
	gates_root.add_child(_grind_rail_root)

	# Build rail beam
	_build_grind_rail_mesh(_grind_seg_start_pd, _grind_seg_end_pd)

	# Collect taps within this segment and spawn a spark for each one
	_spark_nodes.clear()
	_spark_caught.clear()
	_spark_tap_pds.clear()
	_spark_preview_idx      = 0
	_grind_caught_this_seg  = 0
	_grind_total_this_seg   = 0
	_grind_engaged_this_seg = false

	for i in range(_rap_tap_pds.size()):
		var pd: float = _rap_tap_pds[i]
		if pd >= _grind_seg_start_pd - 0.5 and pd <= _grind_seg_end_pd + 0.5:
			var spark := _build_spark_node(pd)
			spark.visible = false
			gates_root.add_child(spark)
			_spark_nodes.append(spark)
			_spark_caught.append(false)
			_spark_tap_pds.append(pd)
			_grind_total_this_seg += 1

	if _hud_grind_label != null:
		_hud_grind_label.visible = true
	_update_grind_hud()


# Rolls this segment's branch "trick" (how the rail leaves the track) and resets the
# per-segment FLOW + fail state. Called once per segment BEFORE the rail/sparks build
# so the rail, the orbs and the player all share one path.
func _roll_grind_trick(seg: Dictionary = {}) -> void:
	# An authored trick from the chart wins; otherwise roll random per the run seed.
	var authored: String = String(seg.get("trick", "")).to_lower()
	if _GRIND_TRICK_IDS.has(authored):
		_grind_trick = int(_GRIND_TRICK_IDS[authored])
	else:
		_grind_trick = _runner_rng.randi() % 6
	_grind_branch_turns = 0.0
	match _grind_trick:
		1:  # cross-OVER — big swing across the track, well above it
			_grind_branch_lat = _runner_rng.randf_range(6.0, 9.0)
			_grind_branch_h   = _runner_rng.randf_range(3.5, 5.5)
		2:  # cross-UNDER — dive clearly below the track and across underneath
			_grind_branch_lat = _runner_rng.randf_range(6.0, 9.0)
			_grind_branch_h   = _runner_rng.randf_range(3.5, 5.5)
		3:  # corkscrew — helix; INTEGER turns so the body roll ends upright
			_grind_branch_lat   = _runner_rng.randf_range(2.5, 3.5)
			_grind_branch_h     = _runner_rng.randf_range(2.5, 3.5)
			_grind_branch_turns = float(_runner_rng.randi_range(1, 2))
		4:  # wander — weaves its own path, side to side and up/down
			_grind_branch_lat   = _runner_rng.randf_range(4.0, 7.0)
			_grind_branch_h     = _runner_rng.randf_range(2.0, 4.0)
			_grind_branch_turns = _runner_rng.randf_range(1.5, 2.5)
		5:  # loop — tall arc beside the track; the rider front-flips through the top
			_grind_branch_lat = _runner_rng.randf_range(0.0, 1.2)
			_grind_branch_h   = _runner_rng.randf_range(5.0, 7.0)
		_:  # 0 sweep — bows out to the side, maybe rising
			_grind_branch_lat = _runner_rng.randf_range(2.5, 5.0)
			_grind_branch_h   = _runner_rng.randf_range(0.0, 4.0)
	# Optional exact-control overrides from the chart (else the type's size stays rolled).
	if seg.has("height"): _grind_branch_h     = float(seg["height"])
	if seg.has("lat"):    _grind_branch_lat   = float(seg["lat"])
	if seg.has("turns"):  _grind_branch_turns = float(seg["turns"])
	_grind_flow_streak = 0
	_grind_flow_mult   = 1
	_grind_miss_streak = 0
	_grind_failed      = false


# Lateral + height offset of the rail from the track at a given path distance.
# A raised-cosine bump: exactly 0 (and zero-slope) at both segment ends so the rail
# peels away and rejoins the track cleanly, peaking in the middle. x = lateral (out
# from the track), y = height (up). Amplitudes are randomised per segment.
func _grind_branch_offset(pd: float) -> Vector2:
	var span: float = maxf(1.0, _grind_seg_end_pd - _grind_seg_start_pd)
	var u:    float = clampf((pd - _grind_seg_start_pd) / span, 0.0, 1.0)
	# Envelope: 0 (and zero-slope) at both ends so the rail peels off and rejoins cleanly.
	var env:  float = 0.5 * (1.0 - cos(TAU * u))
	var lat:  float = 0.0
	var h:    float = 0.0
	match _grind_trick:
		1:  # cross-OVER — swings across to the far side of the track while rising
			lat = -env * _grind_branch_lat        # negative crosses past track centre
			h   =  env * _grind_branch_h
		2:  # cross-UNDER — dives below the track and swings across underneath it
			lat = -env * _grind_branch_lat
			h   = -env * _grind_branch_h
		3:  # corkscrew — helix lifted ABOVE the track so the invert happens up in the air
			var ph: float = u * _grind_branch_turns * TAU
			lat = env * _grind_branch_lat * sin(ph)
			h   = env * (_grind_branch_h + 0.8 + _grind_branch_h * cos(ph))
		4:  # wander — a few sideways + vertical wiggles, going its own way then back
			var pw: float = u * _grind_branch_turns * TAU
			lat = env * _grind_branch_lat * sin(pw)
			h   = env * _grind_branch_h   * sin(pw * 0.5 + 1.3)
		5:  # loop — a tall arch; the rider flips through it (see _grind_branch_pitch)
			lat = env * _grind_branch_lat
			h   = env * _grind_branch_h
		_:  # 0 sweep — bows out to the rail side (and maybe up)
			lat = env * _grind_branch_lat
			h   = env * _grind_branch_h
	# Never phase through the track: when the rail sits laterally over it, clear above
	# (rider stands on top) or far enough below that an upright rider's head passes under.
	h = _grind_clear_track(_GRIND_RAIL_LATERAL + lat, h, _grind_trick == 2)
	return Vector2(lat, h)


# Body roll (radians, around the forward/tangent axis) for tricks that invert the rider.
# Only the corkscrew rolls; its integer turns return the body upright at the segment end.
func _grind_branch_roll(pd: float) -> float:
	if _grind_trick != 3:
		return 0.0
	var span: float = maxf(1.0, _grind_seg_end_pd - _grind_seg_start_pd)
	var u:    float = clampf((pd - _grind_seg_start_pd) / span, 0.0, 1.0)
	return u * _grind_branch_turns * TAU


# Body PITCH (radians, around the lateral axis) — a forward flip. Only the loop pitches;
# one full rotation over the segment so the rider is inverted at the top of the arc and
# back upright on the way down.
func _grind_branch_pitch(pd: float) -> float:
	if _grind_trick != 5:
		return 0.0
	var span: float = maxf(1.0, _grind_seg_end_pd - _grind_seg_start_pd)
	var u:    float = clampf((pd - _grind_seg_start_pd) / span, 0.0, 1.0)
	return u * TAU


# Bank lean (radians, around the forward axis) — the rider leans INTO lateral curves,
# scaled by how fast the rail is sweeping sideways, so they only lean while actually
# turning (0 on straights). Suppressed for the dedicated rotation tricks (corkscrew/loop).
func _grind_branch_lean(pd: float) -> float:
	if _grind_trick == 3 or _grind_trick == 5:
		return 0.0
	var d:     float = 1.5
	var slope: float = (_grind_branch_offset(pd + d).x - _grind_branch_offset(pd - d).x) / (2.0 * d)
	return clampf(-slope * 1.4, -0.42, 0.42)


# Track-collision avoidance for the rail path. Given the rail's TOTAL lateral and its
# height, returns a height that never lets the rail (or an upright rider on it) intersect
# the track slab. Only acts when the rail is laterally over the track; ramps in from the
# edge so the lift/dip is smooth. Detects the real track width + character height.
func _grind_clear_track(total_lat: float, h: float, prefer_under: bool) -> float:
	var half_w: float = _track_full_width() * 0.5
	# 0 at the track edge, 1 once ~0.7 m inside — gives the path room to clear smoothly.
	var pen: float = clampf((half_w - absf(total_lat)) / 0.7, 0.0, 1.0)
	if pen <= 0.0:
		return h                       # clear of the track laterally — any height is fine
	const TRACK_THICK: float = 0.30
	var char_h: float = player.stand_capsule_height if player != null else 1.8
	if prefer_under:
		# Rider hangs/stands below: rail + character height must clear the underside.
		return minf(h, lerpf(0.0, -(TRACK_THICK + char_h + 0.45), pen))
	# Rider stands on top: the rail just needs to sit above the track surface.
	return maxf(h, lerpf(0.0, 0.65, pen))


func _build_grind_rail_mesh(start_pd: float, end_pd: float) -> void:
	if _grind_rail_root == null:
		return

	# Authored Blender rail pieces — tile them along the path. The piece bakes
	# its own lateral offset (author rails as side LEFT → lands at +3.35, the
	# game's rail side). Sparks stay procedural either way.
	var rail_entry: Dictionary = (_piece_lib.first_of("rail") if _piece_lib != null else {})
	if not rail_entry.is_empty():
		var plen: float = maxf(0.5, float(rail_entry.params.get("length", 10.0)))
		var pd: float = start_pd
		while pd < end_pd - 0.05:
			var aoff: Vector2 = _grind_branch_offset(pd)
			var anchor := Node3D.new()
			anchor.position           = _path_world_pos(pd, aoff.x, aoff.y)
			anchor.rotation_degrees.y = _path_y_rot_at(minf(pd + plen * 0.5, end_pd)) + 180.0
			anchor.add_child(_piece_lib.instance(rail_entry))
			_grind_rail_root.add_child(anchor)
			pd += plen
		return

	const N_SEGS: int  = 80
	const RAIL_H: float = 0.88
	var pd_step: float  = (end_pd - start_pd) / float(N_SEGS)
	var lat: float      = _GRIND_RAIL_LATERAL

	for i in range(N_SEGS):
		# Sample the rail at this segment's ends so the bar orients along the full 3D
		# tangent (corkscrews, dives, climbs) instead of a flat yaw only.
		var pd_a: float = start_pd + float(i) * pd_step
		var pd_b: float = start_pd + float(i + 1) * pd_step
		var oa: Vector2 = _grind_branch_offset(pd_a)
		var ob: Vector2 = _grind_branch_offset(pd_b)
		var p0: Vector3 = _path_world_pos(pd_a, lat + oa.x, RAIL_H + oa.y)
		var p1: Vector3 = _path_world_pos(pd_b, lat + ob.x, RAIL_H + ob.y)
		var seg_len: float = maxf(0.05, p0.distance_to(p1)) * 1.04

		var node := Node3D.new()
		node.position = (p0 + p1) * 0.5
		var dir: Vector3 = p1 - p0
		if dir.length() > 0.001:
			var up_ref: Vector3 = Vector3.UP
			if absf(dir.normalized().dot(Vector3.UP)) > 0.97:
				up_ref = Vector3.RIGHT   # avoid look_at gimbal on near-vertical bits
			node.look_at_from_position(node.position, p1, up_ref)
		_grind_rail_root.add_child(node)

		# Main bar — box runs along local -Z, which look_at points down the tangent.
		var bm := BoxMesh.new()
		bm.size = Vector3(0.09, 0.09, seg_len)
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color              = Color(1.00, 0.55, 0.10, 1.0)
		mat.emission_enabled          = true
		mat.emission                  = Color(1.00, 0.55, 0.10, 1.0)
		mat.emission_energy_multiplier = 6.0
		mi.material_override          = mat
		node.add_child(mi)


func _build_spark_node(pd: float) -> Node3D:
	var off: Vector2 = _grind_branch_offset(pd)
	var root := Node3D.new()
	root.position           = _path_world_pos(pd, _GRIND_RAIL_LATERAL + off.x, _GRIND_SPARK_H + off.y)
	root.rotation_degrees.y = _path_y_rot_at(pd)

	# Authored Blender spark ("spark") replaces orb + glow ring; the point
	# light and catch-pop effects stay procedural either way.
	var spark_entry: Dictionary = (_piece_lib.first_of("spark") if _piece_lib != null else {})
	if not spark_entry.is_empty():
		var sp_inst: Node3D = _piece_lib.instance(spark_entry)
		sp_inst.rotation_degrees.y = 180.0
		root.add_child(sp_inst)
		var sp_light := OmniLight3D.new()
		sp_light.light_color  = Color(1.00, 0.82, 0.30, 1.0)
		sp_light.light_energy = 0.9
		sp_light.omni_range   = 4.5
		root.add_child(sp_light)
		return root

	# Orb mesh — slightly flattened sphere
	var sm := SphereMesh.new()
	sm.radius = 0.21; sm.height = 0.38
	var mi := MeshInstance3D.new()
	mi.mesh  = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color              = Color(1.00, 0.90, 0.20, 1.0)
	mat.emission_enabled          = true
	mat.emission                  = Color(1.00, 0.90, 0.20, 1.0)
	mat.emission_energy_multiplier = 9.0
	mi.material_override          = mat
	root.add_child(mi)

	# Glow ring — flat disc
	var dm := CylinderMesh.new()
	dm.top_radius    = 0.38; dm.bottom_radius = 0.38
	dm.height        = 0.04
	dm.rings         = 1;    dm.radial_segments = 20
	var di := MeshInstance3D.new()
	di.mesh = dm
	var dmat := StandardMaterial3D.new()
	dmat.albedo_color              = Color(1.00, 0.70, 0.05, 0.70)
	dmat.emission_enabled          = true
	dmat.emission                  = Color(1.00, 0.70, 0.05, 1.0)
	dmat.emission_energy_multiplier = 4.0
	dmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	di.material_override           = dmat
	root.add_child(di)

	# Point light
	var light := OmniLight3D.new()
	light.light_color  = Color(1.00, 0.82, 0.30, 1.0)
	light.light_energy = 0.9
	light.omni_range   = 4.5
	root.add_child(light)

	return root


func _despawn_grind_rail() -> void:
	_grind_rail_active = false
	player.set_grind_rail(false, 0.0)

	# Full-clear bonus + fanfare — every spark caught and never dropped off the rail.
	if _grind_total_this_seg > 0 and _grind_caught_this_seg >= _grind_total_this_seg and not _grind_failed:
		_score += _GRIND_FULLCLEAR_BONUS
		_update_hud_score()
		_show_grind_banner("◈  PERFECT FLOW!  +%d  ◈" % _GRIND_FULLCLEAR_BONUS, Color(1.0, 0.85, 0.2))

	# Rap-section notes count toward the song's note total at the results — but ONLY if the
	# player actually rode the rail this segment. Skipping a grind costs nothing (no phantom
	# misses). Caught sparks = hits, the rest of the ridden segment = misses.
	if _grind_engaged_this_seg:
		_gates_hit    += _grind_caught_this_seg
		_gates_missed += maxi(0, _grind_total_this_seg - _grind_caught_this_seg)

	for sn in _spark_nodes:
		if is_instance_valid(sn): sn.queue_free()
	_spark_nodes.clear()
	_spark_caught.clear()
	_spark_tap_pds.clear()

	if is_instance_valid(_grind_rail_root): _grind_rail_root.queue_free()
	_grind_rail_root = null

	if _hud_grind_label != null:
		_hud_grind_label.visible = false


func _update_spark_visibility() -> void:
	var pd: float = _player_path_dist
	for i in range(_spark_nodes.size()):
		if _spark_caught[i]:
			continue
		var spark_pd: float = _spark_tap_pds[i]
		var ahead:    float = spark_pd - pd
		# Show when within preview range; hide once well behind
		if is_instance_valid(_spark_nodes[i]):
			_spark_nodes[i].visible = (ahead >= -judge_window_s * player.forward_speed) \
									  and (ahead <= _GRIND_PREVIEW_M)


func _check_missed_sparks() -> void:
	var pd:           float = _player_path_dist
	var miss_thresh:  float = judge_window_s * player.forward_speed * 1.6
	for i in range(_spark_nodes.size()):
		if _spark_caught[i]:
			continue
		var spark_pd: float = _spark_tap_pds[i]
		if pd > spark_pd + miss_thresh:
			# Passed without a catch — mark as handled, hide silently
			_spark_caught[i] = true
			if is_instance_valid(_spark_nodes[i]):
				_spark_nodes[i].visible = false
			# Only counts against you while you're actually riding the rail. Breaks the
			# FLOW multiplier and, after too many in a row, drops you off the rail.
			if player.is_grinding() and not _grind_failed:
				_grind_flow_streak = 0
				_grind_flow_mult   = 1
				_grind_miss_streak += 1
				if _grind_miss_streak >= _GRIND_FAIL_MISSES:
					_grind_fail_off()


func _on_grind_tap() -> void:
	if not _grind_rail_active or _spark_nodes.is_empty():
		return

	var pd:           float = _player_path_dist
	var window_m:     float = judge_window_s * player.forward_speed * 1.5

	var best_idx:  int   = -1
	var best_dist: float = window_m

	for i in range(_spark_nodes.size()):
		if _spark_caught[i]:
			continue
		var dist: float = abs(_spark_tap_pds[i] - pd)
		if dist < best_dist:
			best_dist = dist
			best_idx  = i

	if best_idx >= 0:
		_catch_spark(best_idx)


func _catch_spark(idx: int) -> void:
	_spark_caught[idx]    = true
	_grind_caught_this_seg += 1

	# Ramping FLOW multiplier: climbs with each consecutive catch, resets on a miss.
	_grind_miss_streak  = 0
	_grind_flow_streak += 1
	_grind_flow_mult    = mini(1 + _grind_flow_streak / 3, _GRIND_FLOW_MULT_MAX)

	# Award score scaled by the flow multiplier (its own ramp, not the gate combo).
	var pts: int = _GRIND_SCORE_PER_SPARK * _grind_flow_mult
	_score    += pts
	_combo    += 1
	_max_combo = maxi(_max_combo, _combo)
	_update_hud_score()

	# Visual: floating "+score" popup at the orb, then expand & dissolve the orb.
	if is_instance_valid(_spark_nodes[idx]):
		var sn: Node3D = _spark_nodes[idx]
		_spawn_score_popup(sn.global_position, pts, _grind_flow_mult)
		sn.visible = true
		var tw := create_tween()
		tw.tween_property(sn, "scale", Vector3(2.8, 2.8, 2.8), 0.07)
		tw.tween_property(sn, "scale", Vector3(0.0, 0.0, 0.0), 0.11)
		tw.tween_callback(sn.queue_free)
		_spark_nodes[idx] = null   # prevent double-free

	# Combo flash
	if _hud_combo_label != null and _combo >= 2:
		var ctw := create_tween()
		ctw.tween_property(_hud_combo_label, "modulate", Color(1.5, 1.5, 0.3, 1.0), 0.05)
		ctw.tween_property(_hud_combo_label, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)

	# Milestone check (re-uses the same streak system)
	const _GRIND_MILESTONES: Array[int] = [10, 25, 50, 100, 200]
	if _combo in _GRIND_MILESTONES:
		_show_streak_milestone(_combo)

	_update_grind_hud()


func _update_grind_hud() -> void:
	if _hud_grind_label == null:
		return
	if not _grind_rail_active or _grind_total_this_seg == 0:
		_hud_grind_label.visible = false
		return
	_hud_grind_label.visible = true
	var pct: int = int(float(_grind_caught_this_seg) / float(_grind_total_this_seg) * 100.0)
	_hud_grind_label.text = "◈  FLOW  %d / %d  (%d%%)   ×%d" % [
		_grind_caught_this_seg, _grind_total_this_seg, pct, _grind_flow_mult]


# Drop the player off the rail mid-section after too many missed sparks. They forfeit
# the remaining sparks (and the full-clear bonus); _update_grind_system then marks the
# rail unavailable, so the player exits grind and gravity drops them back to the track.
func _grind_fail_off() -> void:
	if _grind_failed:
		return
	_grind_failed = true
	_show_grind_banner("✕  DROPPED!", Color(1.0, 0.35, 0.30))
	if _hud_grind_label != null:
		_hud_grind_label.visible = false


# Floating "+score" popup at a world position, drifting up and fading. Larger and
# warmer as the flow multiplier climbs, for escalating juice on each catch.
func _spawn_score_popup(world_pos: Vector3, pts: int, mult: int) -> void:
	var lbl := Label3D.new()
	lbl.text          = ("+%d" % pts) if mult <= 1 else ("+%d  ×%d" % [pts, mult])
	lbl.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size    = true
	lbl.pixel_size    = 0.0024
	lbl.font_size     = 26 + mult * 2
	lbl.outline_size  = 6
	lbl.modulate      = Color(1.0, 0.95, 0.45).lerp(
		Color(1.0, 0.55, 0.10), clampf(float(mult) / float(_GRIND_FLOW_MULT_MAX), 0.0, 1.0))
	lbl.position      = world_pos + Vector3(0.0, 0.4, 0.0)
	gates_root.add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y + 1.4, 0.6)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.6)
	tw.finished.connect(lbl.queue_free)


# Big centred banner (PERFECT FLOW / DROPPED). Mirrors _show_streak_milestone.
func _show_grind_banner(text: String, col: Color) -> void:
	if _hud_flash == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 44)
	lbl.add_theme_color_override("font_color", col)
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lbl.grow_vertical   = Control.GROW_DIRECTION_BOTH
	lbl.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	lbl.modulate.a      = 0.0
	root.add_child(lbl)
	var tw := create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, 0.10)
	tw.tween_property(lbl, "modulate", Color(col.r * 1.3, col.g * 1.3, col.b * 1.3, 1.0), 0.10)
	tw.tween_property(lbl, "modulate", Color(col.r, col.g, col.b, 1.0), 0.12)
	tw.tween_interval(0.70)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.25)
	tw.tween_callback(lbl.queue_free)


# ════════════════════════════════════════════════════════════════════════════

func _score_multiplier() -> int:
	# Charge-tunnel OVERDRIVE: a clean drop locks the multiplier to ×100 for a window
	# whose length scaled with how full the charge was. Overrides everything else.
	if _charge_mult_timer > 0.0:
		return _CHARGE_MULT_VALUE
	# Every 10 combo = +1 multiplier, capped at ×20 (reached at combo 190)
	var base: int = mini(int(_combo * 0.1) + 1, 20)
	# Wall-jump bonus: doubles the multiplier while the timer is running
	if _wj_mult_timer > 0.0:
		base *= 2
	return base


func _update_wj_bonus_label() -> void:
	if _hud_wj_label == null:
		return
	if _wj_mult_timer <= 0.0:
		_hud_wj_label.visible = false
		return
	# Fade out gracefully in the last 2 seconds
	var alpha: float = clamp(_wj_mult_timer / 2.0, 0.0, 1.0)
	_hud_wj_label.visible = true
	_hud_wj_label.modulate = Color(1.0, 1.0, 1.0, alpha)


func _activate_wj_bonus() -> void:
	_wj_mult_timer = _WJ_MULT_DURATION
	if _hud_wj_label != null:
		_hud_wj_label.visible = true
		_hud_wj_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	# Gold screen flash to signal the bonus
	_hud_flash_color(Color(1.00, 0.80, 0.10, 0.30), 0.50)


func _update_hud_score() -> void:
	if _hud_score_label != null:
		_hud_score_label.text = str(_score)
	if _hud_combo_label != null:
		if _combo >= 2:
			var m: int = _score_multiplier()
			if m > 1:
				_hud_combo_label.text = "× %d  COMBO  %d✕" % [_combo, m]
			else:
				_hud_combo_label.text = "× %d  COMBO" % _combo
		else:
			_hud_combo_label.text = ""


func _update_hud_health() -> void:
	if _hud_hp_fill == null:
		return
	var pct: float = clamp(_health_pct, 0.0, 1.0)
	# Bar fill: right offset tracks percentage
	# We need the left offset to derive bar width. Left offset is fixed at bx.
	var bar_left: float  = _hud_hp_fill.offset_left   # same bx as creation
	var bar_total: float = 180.0
	_hud_hp_fill.offset_right = bar_left + bar_total * pct

	# Colour: green (full) → yellow (50%) → red (empty)
	var fill_col: Color
	if pct >= 0.5:
		fill_col = Color(0.35, 1.00, 0.55, 1.0).lerp(Color(1.00, 0.88, 0.22, 1.0), (1.0 - pct) * 2.0)
	else:
		fill_col = Color(1.00, 0.88, 0.22, 1.0).lerp(Color(1.00, 0.18, 0.18, 1.0), (0.5 - pct) * 2.0)
	_hud_hp_fill.color = fill_col

	# Update percentage text
	var root: Control = _hud_hp_fill.get_parent() as Control
	if root != null:
		var pct_lbl: Label = root.find_child("HpPctLabel", false, false) as Label
		if pct_lbl != null:
			pct_lbl.text = "%d%%" % int(pct * 100.0)
			pct_lbl.add_theme_color_override("font_color", fill_col.lightened(0.25))


func _hud_flash_color(col: Color, duration: float) -> void:
	if _hud_flash == null:
		return
	_hud_flash.color = col
	var ftw := create_tween()
	ftw.tween_property(_hud_flash, "color", Color(col.r, col.g, col.b, 0.0), duration)


## Brief dev toast — a small label that fades in/out over the HUD canvas.
func _hud_show_dev_toast(msg: String) -> void:
	if _hud_flash == null:
		return
	var hud_root: Control = _hud_flash.get_parent() as Control
	if hud_root == null:
		return
	var toast := Label.new()
	toast.text = "[DEV]  %s" % msg
	toast.anchor_left   = 0.5; toast.anchor_right  = 0.5
	toast.anchor_top    = 0.0; toast.anchor_bottom = 0.0
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_left  = -300; toast.offset_right  = 300
	toast.offset_top   = 80;   toast.offset_bottom = 120
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_font_size_override("font_size", 20)
	toast.add_theme_color_override("font_color", Color(1.0, 0.75, 0.20))
	toast.modulate.a = 0.0
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(toast)
	var ttw := create_tween()
	ttw.tween_property(toast, "modulate:a", 1.0, 0.15)
	ttw.tween_interval(1.60)
	ttw.tween_property(toast, "modulate:a", 0.0, 0.35)
	ttw.tween_callback(toast.queue_free)


func _on_gate_scored(success: bool) -> void:
	if _song_finish_pending:
		return   # don't judge gates during the finish / death sequence

	if success:
		_combo += 1
		_max_combo = maxi(_max_combo, _combo)
		_gates_hit += 1
		var _base_gate_pts: int = 1000 if _is_electric_at(_song_time()) else 500
		_score += _base_gate_pts * _score_multiplier()
		_health_pct = clamp(_health_pct + 0.01, 0.0, 1.0)
		_world_vitality = clamp(_world_vitality + 0.07, 0.0, 1.0)
		_update_hud_score()
		_update_hud_health()
		_hud_flash_color(Color(0.20, 1.00, 0.40, 0.28), 0.30)
		# Combo label bounce
		if _hud_combo_label != null and _combo >= 2:
			var ctw := create_tween()
			ctw.tween_property(_hud_combo_label, "modulate", Color(1.5, 1.3, 0.4, 1.0), 0.05)
			ctw.tween_property(_hud_combo_label, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.14)
		# Streak milestones
		const MILESTONES: Array[int] = [10, 25, 50, 100, 200]
		if _combo in MILESTONES:
			_show_streak_milestone(_combo)
	else:
		# OVERDRIVE safe window: a miss does NOT drop the multiplier (combo preserved) and
		# costs no health — it just scores nothing. (User's design for the ×100 payoff.)
		if _charge_mult_timer > 0.0:
			_gates_missed += 1
			_update_hud_score()
			return
		_combo = 0
		_gates_missed += 1
		_world_vitality = clamp(_world_vitality - 0.18, 0.0, 1.0)
		_health_pct = clamp(_health_pct - 0.10, 0.0, 1.0)
		_update_hud_score()
		_update_hud_health()
		_hud_flash_color(Color(1.00, 0.10, 0.10, 0.45), 0.40)
		_shake_camera()
		# Combo label flash red then vanish
		if _hud_combo_label != null:
			var ctw := create_tween()
			ctw.tween_property(_hud_combo_label, "modulate", Color(1.0, 0.15, 0.15, 1.0), 0.05)
			ctw.tween_property(_hud_combo_label, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.20)
		if _sfx_miss != null:
			_sfx_miss.stop()
			_sfx_miss.play()
		if _health_pct <= 0.0:
			_trigger_death()


func _show_streak_milestone(combo: int) -> void:
	if _hud_flash == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return

	var col: Color
	match combo:
		15:  col = Color(0.90, 0.85, 0.20)   # gold
		30:  col = Color(0.30, 0.90, 1.00)   # cyan
		75:  col = Color(0.65, 0.30, 1.00)   # purple
		100: col = Color(1.00, 0.40, 0.20)   # orange
		_:   col = Color(1.00, 1.00, 1.00)   # white (200+)

	var lbl := Label.new()
	lbl.text = "★  ×%d  STREAK!  ★" % combo
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 46)
	lbl.add_theme_color_override("font_color", col)
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lbl.grow_vertical   = Control.GROW_DIRECTION_BOTH
	lbl.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	lbl.modulate.a      = 0.0
	root.add_child(lbl)

	var tw := create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, 0.10)
	tw.tween_property(lbl, "modulate", Color(col.r * 1.3, col.g * 1.3, col.b * 1.3, 1.0), 0.08)
	tw.tween_property(lbl, "modulate", Color(col.r, col.g, col.b, 1.0), 0.12)
	tw.tween_interval(0.65)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.22)
	tw.tween_callback(lbl.queue_free)


func _trigger_death() -> void:
	if _song_finish_pending:
		return
	_song_finish_pending = true   # blocks further scoring and re-entry

	music.stop()

	# ── 3-lives system ────────────────────────────────────────────────────────
	Run.song_lives -= 1
	var lives_exhausted: bool = (Run.song_lives <= 0)
	if lives_exhausted:
		# All tries used — roll a fresh seed (never-before-seen) and give 3 new lives
		_runner_rng.randomize()
		while Save.is_seed_used(Run.current_song_key, _runner_rng.seed):
			_runner_rng.randomize()
		Run.run_seed   = _runner_rng.seed
		Run.song_lives = 3
		Save.mark_seed_used(Run.current_song_key, Run.run_seed)

	# Big red death flash
	_hud_flash_color(Color(1.00, 0.05, 0.05, 0.75), 0.15)

	if _hud_flash == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return

	# ── Phase 1: fade to solid black ────────────────────────────────────────
	var blackout := ColorRect.new()
	blackout.color         = Color(0.00, 0.00, 0.00, 1.0)
	blackout.anchor_right  = 1.0; blackout.anchor_bottom = 1.0
	blackout.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	blackout.modulate.a    = 0.0
	root.add_child(blackout)

	# ── Phase 2: UI elements — built now, revealed after blackout ───────────
	# Title: "FAILED" or "OUT OF TRIES"
	var fail_label := Label.new()
	fail_label.text = "OUT OF TRIES" if lives_exhausted else "FAILED"
	fail_label.anchor_left   = 0.5; fail_label.anchor_right  = 0.5
	fail_label.anchor_top    = 0.5; fail_label.anchor_bottom = 0.5
	fail_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	fail_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	fail_label.offset_left   = -300; fail_label.offset_right  = 300
	fail_label.offset_top    = -160; fail_label.offset_bottom = -60
	fail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fail_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	fail_label.add_theme_color_override("font_color",
		Color(1.00, 0.55, 0.05, 1.0) if lives_exhausted else Color(1.00, 0.18, 0.28, 1.0))
	fail_label.add_theme_font_size_override("font_size", 72 if lives_exhausted else 80)
	fail_label.modulate.a  = 0.0
	fail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fail_label)

	# Score readout
	var score_label := Label.new()
	score_label.text = "score  %d" % _score
	score_label.anchor_left   = 0.5; score_label.anchor_right  = 0.5
	score_label.anchor_top    = 0.5; score_label.anchor_bottom = 0.5
	score_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	score_label.offset_left  = -200; score_label.offset_right  = 200
	score_label.offset_top   = -50;  score_label.offset_bottom = -8
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.add_theme_color_override("font_color", Color(0.85, 0.75, 1.00, 0.90))
	score_label.add_theme_font_size_override("font_size", 22)
	score_label.modulate.a  = 0.0
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(score_label)

	# Sub-message: lives remaining  OR  new-seed notice
	var sub_label := Label.new()
	if lives_exhausted:
		sub_label.text = "All 3 tries used — a brand new route has been generated!"
	else:
		var lv: int = Run.song_lives
		sub_label.text = "%d %s remaining" % [lv, "life" if lv == 1 else "lives"]
	sub_label.anchor_left   = 0.5; sub_label.anchor_right  = 0.5
	sub_label.anchor_top    = 0.5; sub_label.anchor_bottom = 0.5
	sub_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	sub_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	sub_label.offset_left  = -260; sub_label.offset_right  = 260
	sub_label.offset_top   = -4;   sub_label.offset_bottom = 20
	sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_label.add_theme_color_override("font_color",
		Color(1.00, 0.78, 0.20, 0.95) if lives_exhausted else Color(0.45, 0.92, 0.55, 0.90))
	sub_label.add_theme_font_size_override("font_size", 15)
	sub_label.modulate.a  = 0.0
	sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(sub_label)

	# Divider line (shifted down to leave room for sub_label)
	var divider := ColorRect.new()
	divider.color = Color(0.55, 0.20, 0.90, 0.60)
	divider.anchor_left   = 0.5; divider.anchor_right  = 0.5
	divider.anchor_top    = 0.5; divider.anchor_bottom = 0.5
	divider.grow_horizontal = Control.GROW_DIRECTION_BOTH
	divider.grow_vertical   = Control.GROW_DIRECTION_BOTH
	divider.offset_left  = -180; divider.offset_right  = 180
	divider.offset_top   = 28;   divider.offset_bottom = 30
	divider.modulate.a   = 0.0
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(divider)

	# Option helper — panel + label
	var _make_option: Callable = func(label_text: String, y_top: float, y_bot: float) -> Control:
		var panel := Panel.new()
		panel.anchor_left   = 0.5; panel.anchor_right  = 0.5
		panel.anchor_top    = 0.5; panel.anchor_bottom = 0.5
		panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
		panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
		panel.offset_left  = -170; panel.offset_right  = 170
		panel.offset_top   = y_top; panel.offset_bottom = y_bot
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color     = Color(0.10, 0.04, 0.20, 1.0)
		sb.border_color = Color(0.55, 0.18, 0.90, 1.0)
		sb.border_width_left = 2; sb.border_width_right  = 2
		sb.border_width_top  = 2; sb.border_width_bottom = 2
		sb.corner_radius_top_left     = 8; sb.corner_radius_top_right    = 8
		sb.corner_radius_bottom_left  = 8; sb.corner_radius_bottom_right = 8
		sb.content_margin_left  = 16; sb.content_margin_right  = 16
		sb.content_margin_top   = 10; sb.content_margin_bottom = 10
		panel.add_theme_stylebox_override("panel", sb)
		var lbl := Label.new()
		lbl.text = label_text
		lbl.anchor_right  = 1.0; lbl.anchor_bottom = 1.0
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color(0.70, 0.55, 1.00, 1.0))
		lbl.add_theme_font_size_override("font_size", 26)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lbl)
		panel.modulate.a = 0.0
		return panel

	var retry_text: String = "▶  PLAY NEW SEED" if lives_exhausted else "▶  RETRY"
	var retry_node   := _make_option.call(retry_text, 50, 102) as Control
	var songsel_node := _make_option.call("↩  SONG SELECT", 116, 168) as Control
	root.add_child(retry_node)
	root.add_child(songsel_node)

	_death_option_nodes = [retry_node, songsel_node]
	_death_menu_option  = 0

	# Hint line
	var hint_label := Label.new()
	hint_label.text = "↑↓ / D-pad choose  ·  Enter / A confirm"
	hint_label.anchor_left   = 0.5; hint_label.anchor_right  = 0.5
	hint_label.anchor_top    = 0.5; hint_label.anchor_bottom = 0.5
	hint_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	hint_label.offset_left  = -240; hint_label.offset_right  = 240
	hint_label.offset_top   = 182;  hint_label.offset_bottom = 210
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", Color(0.50, 0.45, 0.65, 0.80))
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.modulate.a  = 0.0
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hint_label)

	# ── Sequence: fade to black → then reveal UI on top ─────────────────────
	var ftw := create_tween()
	ftw.tween_property(blackout, "modulate:a", 1.0, 0.55)
	ftw.tween_callback(func() -> void:
		var ui_tw := create_tween()
		ui_tw.parallel().tween_property(fail_label,   "modulate:a", 1.0, 0.20)
		ui_tw.parallel().tween_property(score_label,  "modulate:a", 1.0, 0.28)
		ui_tw.parallel().tween_property(sub_label,    "modulate:a", 1.0, 0.30)
		ui_tw.parallel().tween_property(divider,      "modulate:a", 1.0, 0.32)
		ui_tw.parallel().tween_property(retry_node,   "modulate:a", 1.0, 0.36)
		ui_tw.parallel().tween_property(songsel_node, "modulate:a", 1.0, 0.42)
		ui_tw.parallel().tween_property(hint_label,   "modulate:a", 1.0, 0.50)
		ui_tw.finished.connect(func() -> void:
			_death_menu_active = true
			_death_update_selection()
		)
	)


# Highlight the currently selected death-menu option.
func _death_update_selection() -> void:
	for i in range(_death_option_nodes.size()):
		var panel := _death_option_nodes[i]
		if panel == null:
			continue
		var sb := StyleBoxFlat.new()
		var is_sel: bool = (i == _death_menu_option)
		if is_sel:
			sb.bg_color     = Color(0.32, 0.08, 0.58, 1.0)
			sb.border_color = Color(1.00, 0.45, 1.00, 1.0)
		else:
			sb.bg_color     = Color(0.10, 0.04, 0.20, 1.0)
			sb.border_color = Color(0.55, 0.18, 0.90, 1.0)
		sb.border_width_left = 2; sb.border_width_right  = 2
		sb.border_width_top  = 2; sb.border_width_bottom = 2
		sb.corner_radius_top_left     = 8; sb.corner_radius_top_right    = 8
		sb.corner_radius_bottom_left  = 8; sb.corner_radius_bottom_right = 8
		sb.content_margin_left  = 16; sb.content_margin_right  = 16
		sb.content_margin_top   = 10; sb.content_margin_bottom = 10
		panel.add_theme_stylebox_override("panel", sb)

		# Recolour label text
		var lbl := panel.get_child(0) as Label
		if lbl != null:
			lbl.add_theme_color_override("font_color",
				Color(1.00, 0.55, 1.00, 1.0) if is_sel else Color(0.70, 0.55, 1.00, 1.0))
			lbl.add_theme_font_size_override("font_size", 30 if is_sel else 26)


func _death_confirm() -> void:
	_death_menu_active = false
	match _death_menu_option:
		0:  # RETRY / PLAY NEW SEED — Run.run_seed already holds the correct seed
			get_tree().change_scene_to_file("res://scenes/GameScene.tscn")
		1:  # SONG SELECT — reset so the next song picked starts completely fresh
			Run.run_seed   = 0
			Run.song_lives = 3
			get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey or event is InputEventJoypadButton):
		return

	var just_pressed: bool = event.is_pressed() and not event.is_echo()
	if not just_pressed:
		return

	# ── Dev: Ctrl+Alt+H → wipe all high scores ───────────────────────────────
	var key_ev := event as InputEventKey
	if key_ev != null and key_ev.ctrl_pressed and key_ev.alt_pressed \
			and key_ev.physical_keycode == KEY_H:
		get_viewport().set_input_as_handled()
		Save.clear_all_high_scores()
		_hud_show_dev_toast("High scores cleared")
		return

	# ── End screen navigation ────────────────────────────────────────────────
	if _end_screen_active:
		if event.is_action("ui_left") or event.is_action("ui_right"):
			get_viewport().set_input_as_handled()
			_end_screen_sel = 1 - _end_screen_sel
			_end_update_nav_highlight()
		elif event.is_action("ui_accept"):
			get_viewport().set_input_as_handled()
			_end_confirm()
		elif event.is_action("ui_cancel"):
			get_viewport().set_input_as_handled()
			_end_screen_sel = 1
			_end_confirm()
		return

	# ── Pause toggle: ESC or gamepad Start ───────────────────────────────────
	var is_esc: bool = (event is InputEventKey and
		(event as InputEventKey).keycode == KEY_ESCAPE)
	var is_gamepad_start: bool = (event is InputEventJoypadButton and
		(event as InputEventJoypadButton).button_index == JOY_BUTTON_START)

	if (is_esc or is_gamepad_start) and not _death_menu_active and not _song_finish_pending:
		get_viewport().set_input_as_handled()
		if _paused:
			_resume_game()
		else:
			_pause_game()
		return

	# ── Pause menu navigation ─────────────────────────────────────────────────
	if _paused:
		if event.is_action("ui_up"):
			get_viewport().set_input_as_handled()
			_pause_option = posmod(_pause_option - 1, 5)
			_pause_update_selection()
		elif event.is_action("ui_down"):
			get_viewport().set_input_as_handled()
			_pause_option = posmod(_pause_option + 1, 5)
			_pause_update_selection()
		elif event.is_action("ui_accept"):
			get_viewport().set_input_as_handled()
			_pause_confirm()
		return

	# ── Death menu navigation ─────────────────────────────────────────────────
	if not _death_menu_active:
		return

	if event.is_action("ui_up"):
		get_viewport().set_input_as_handled()
		_death_menu_option = posmod(_death_menu_option - 1, _death_option_nodes.size())
		_death_update_selection()
	elif event.is_action("ui_down"):
		get_viewport().set_input_as_handled()
		_death_menu_option = posmod(_death_menu_option + 1, _death_option_nodes.size())
		_death_update_selection()
	elif event.is_action("ui_accept"):
		get_viewport().set_input_as_handled()
		_death_confirm()


# ── Gate arch helper ─────────────────────────────────────────────────────────
# Draws a bright neon rectangular frame (two posts + top beam) around the zone
# the player must pass through.  Makes gates feel like designed track landmarks
# rather than background props.
func _make_gate_arch(root: Node3D, cx: float, width: float,
		bot_y: float, top_y: float, tint: Color) -> void:
	var bright := tint.lightened(0.04)
	var pw     := 0.10            # post / beam cross-section
	var h      := top_y - bot_y
	var cy     := bot_y + h * 0.5

	# Left post
	var lp := _make_box_mesh(Vector3(pw, h, pw), bright)
	lp.position = Vector3(cx - width * 0.5 - pw * 0.5, cy, 0.0)
	root.add_child(lp)
	# Right post
	var rp := _make_box_mesh(Vector3(pw, h, pw), bright)
	rp.position = Vector3(cx + width * 0.5 + pw * 0.5, cy, 0.0)
	root.add_child(rp)
	# Top beam
	var tb := _make_box_mesh(Vector3(width + pw * 2.0 + 0.08, pw, pw), bright)
	tb.position = Vector3(cx, top_y + pw * 0.5, 0.0)
	root.add_child(tb)
	# Corner accent cubes (extra visual pop at the top corners)
	for sx: float in [-1.0, 1.0]:
		var corner := _make_box_mesh(Vector3(pw * 1.6, pw * 1.6, pw * 1.6), bright)
		corner.position = Vector3(cx + sx * (width * 0.5 + pw * 0.5), top_y + pw * 0.5, 0.0)
		root.add_child(corner)


# ── Approach runway helper ────────────────────────────────────────────────────
# Three neon hash marks on the floor extending toward the player, clearly
# marking "gate ahead" on the track surface.
func _make_approach_marks(root: Node3D, cx: float, width: float, tint: Color) -> void:
	# Authored Blender "ApproachMarks" replace the procedural hash lines —
	# stretched sideways so they fit lane-width AND full-track gates alike.
	var entry: Dictionary = (_piece_lib.first_of("marks") if _piece_lib != null else {})
	if not entry.is_empty():
		var auth_w: float = maxf(0.1, float(entry.params.get("width", 5.2)))
		var inst: Node3D = _piece_lib.instance(entry)
		inst.position           = Vector3(cx, 0.0, 0.0)
		inst.rotation_degrees.y = 180.0
		inst.scale.x            = width / auth_w
		root.add_child(inst)
		return
	var bright := tint.darkened(0.05)
	for i: int in 3:
		var mark := _make_box_mesh(Vector3(width * 0.80, 0.03, 0.14), bright)
		mark.position = Vector3(cx, 0.015, -(1.2 + float(i) * 1.3))
		root.add_child(mark)


# Glowing safe-lane floor strip — authored Blender "SafeStrip" when present
# (author it centred at lane x = 0; the game positions it per gate).
func _make_safe_strip(safe_x: float, tint: Color) -> Node3D:
	var entry: Dictionary = (_piece_lib.first_of("strip") if _piece_lib != null else {})
	if not entry.is_empty():
		var wrap := Node3D.new()
		wrap.position = Vector3(safe_x, 0.01, 0.0)
		var inst: Node3D = _piece_lib.instance(entry)
		inst.rotation_degrees.y = 180.0
		wrap.add_child(inst)
		return wrap
	var strip := _make_box_mesh(
		Vector3(lane_blocker_width * 0.7, 0.04, gate_depth * 1.2), tint)
	strip.position = Vector3(safe_x, 0.02, 0.0)
	return strip


# ── Building-facade helper ────────────────────────────────────────────────────
# Returns a Node3D containing a dark silhouette body, horizontal neon window
# strips (front-face only), and a bright rooftop cap — the same visual language
# as the city skyscrapers.  Positioned at `pos` relative to the caller's root.
func _make_bldg_facade(pos: Vector3, size: Vector3, win_col: Color,
		strip_h: float = 0.12, strip_gap: float = 0.45) -> Node3D:
	var node     := Node3D.new()
	node.position = pos

	# Dark silhouette body — gives the obstacle mass without bleeding emission
	var body     := MeshInstance3D.new()
	var bm       := BoxMesh.new()
	bm.size       = size
	body.mesh     = bm
	var body_mat  := StandardMaterial3D.new()
	body_mat.albedo_color     = Color(0.04, 0.02, 0.08, 1.0)
	body_mat.emission_enabled = false
	body.material_override    = body_mat
	node.add_child(body)

	# One shared material for every strip on this facade (no per-strip overhead)
	var win_mat := StandardMaterial3D.new()
	win_mat.albedo_color               = win_col.darkened(0.25)
	win_mat.emission_enabled           = true
	win_mat.emission                   = win_col
	win_mat.emission_energy_multiplier = 2.0

	# Front-face strips only — one mesh per row, facing the approaching player.
	# Side faces are intentionally left dark to keep gate mesh counts low.
	var y_local: float = -size.y * 0.5 + strip_gap
	while y_local < size.y * 0.5 - strip_h:
		var sf  := MeshInstance3D.new()
		var smf := BoxMesh.new()
		smf.size = Vector3(size.x + 0.02, strip_h, 0.06)
		sf.mesh  = smf
		sf.material_override = win_mat
		sf.position = Vector3(0.0, y_local, -size.z * 0.5 - 0.03)
		node.add_child(sf)
		y_local += strip_gap

	# Bright rooftop cap — same cap style as city buildings
	var cap      := _make_box_mesh(Vector3(size.x + 0.06, 0.08, size.z + 0.06), win_col.lightened(0.30))
	cap.position  = Vector3(0.0, size.y * 0.5 + 0.04, 0.0)
	node.add_child(cap)

	return node


func _make_box_mesh(size: Vector3, color: Color) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = size
	mi.mesh = bm

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	# Standard lit material — albedo carries the colour, emission is a subtle accent only
	mat.albedo_color    = color
	mat.metallic        = 0.05
	mat.roughness       = 0.68
	mat.emission_enabled = true
	mat.emission         = color
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat

	# store original color so color cycling can preserve shape identity
	mi.set_meta("base_color", color)

	return mi


# ── Camera FX ────────────────────────────────────────────────────────────────
func _update_camera_fx(delta: float) -> void:
	if _camera == null or not _level_started or _paused:
		return

	# FOV breathe on beat — very subtle, just enough to feel alive
	_camera.fov = _cam_fov_base + _beat_cam_t * 1.5

	# Tilt toward new lane — gentle, barely-there weight
	var cur_lane: int = player.current_lane
	if cur_lane != _cam_prev_lane:
		var dir: int = cur_lane - _cam_prev_lane
		_cam_tilt = clamp(_cam_tilt + dir * 0.6, -1.2, 1.2)
		_cam_prev_lane = cur_lane
	_cam_tilt = lerpf(_cam_tilt, 0.0, delta * 7.0)

	# Arc lean — smooth z-roll that builds into corners and unwinds after.
	# arc_bank_raw (-1..1) is also forwarded to the player for character banking.
	const ARC_LEAN_MAX_DEG: float = 5.0
	var arc_lean_target: float = 0.0
	var arc_bank_raw:    float = 0.0
	for i in range(_turn_junction_pds.size()):
		var arc_s: float = _turn_junction_pds[i]
		var arc_e: float = _turn_arc_ends[i]
		if _player_path_dist >= arc_s and _player_path_dist < arc_e:
			var t: float         = (_player_path_dist - arc_s) / (arc_e - arc_s)
			var lean_sign: float = 1.0 if _turn_is_right[i] else -1.0
			arc_bank_raw    = sin(t * PI) * lean_sign
			arc_lean_target = ARC_LEAN_MAX_DEG * arc_bank_raw
			break
	_cam_arc_tilt = lerpf(_cam_arc_tilt, arc_lean_target, delta * 3.0)
	player.set_arc_bank(arc_bank_raw)

	_camera.rotation_degrees.z = _cam_tilt + _cam_arc_tilt


func _shake_camera() -> void:
	# Small impulse on miss — camera nudges slightly then recovers
	_cam_tilt = clamp(_cam_tilt - 1.2, -2.0, 2.0)


# ── World environment (neon cyberpunk look) ───────────────────────────────────
func _setup_world_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()

	# Near-black deep-purple background
	env.background_mode  = Environment.BG_COLOR
	env.background_color = Color(0.018, 0.008, 0.050, 1.0)

	# Ambient: very dim violet so dark areas don't go full black
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.22, 0.06, 0.40, 1.0)
	env.ambient_light_energy = 0.18

	# Glow — punchy neon bloom; HDR threshold lowered so more surfaces contribute
	env.glow_enabled    = true
	env.glow_normalized = true
	env.glow_intensity  = 0.85
	env.glow_strength   = 1.10
	env.glow_bloom      = 0.12
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold  = 0.60
	env.glow_hdr_scale      = 2.0

	# Subtle depth fog — keeps the far end hazy
	env.fog_enabled        = true
	env.fog_light_color    = Color(0.12, 0.04, 0.25, 1.0)
	env.fog_light_energy   = 1.0
	env.fog_density        = 0.008

	# Quality-tier extras (SSR/SSAO/SSIL) — this Environment is the one that
	# actually renders (this WorldEnvironment is added to the tree after the
	# scene's own, so it supersedes it), so this is the correct place to
	# apply Options > Display > Quality.
	GraphicsQuality.apply_environment_overrides(env)

	we.environment = env
	_melody_env = env
	add_child(we)


# ── Floor grid lines ──────────────────────────────────────────────────────────
func _spawn_floor_grid() -> void:
	if player == null or player.lane_xs.size() < 2:
		return
	# Authored floor pieces bring their own lane lines — skip the procedural
	# purple divider lines entirely (floor visuals are asset-only).
	if _piece_lib != null and _piece_lib.has_type("straight"):
		return

	var end_path: float = _song_end_z()
	var line_h: float = 0.015
	var line_t: float = 0.035
	var grid_col: Color = Color(0.401, 0.117, 0.65, 0.0)

	# Per-segment lane divider lines (one per lane gap per path segment)
	for seg_var in _track_segs:
		var seg: TrackSeg = seg_var as TrackSeg
		var seg_len: float = minf(seg.length, end_path - seg.path_start)
		if seg_len <= 0.0:
			break
		var seg_y_rot: float = rad_to_deg(atan2(seg.direction.x, seg.direction.z))
		var seg_mid: Vector3 = seg.origin + seg.direction * (seg_len * 0.5)

		for i in range(player.lane_xs.size() - 1):
			var lx: float = (player.lane_xs[i] + player.lane_xs[i + 1]) * 0.5
			var line: MeshInstance3D = _make_box_mesh(Vector3(line_t, line_h, seg_len), grid_col)
			line.position = seg_mid + seg.right * lx + Vector3(0.0, line_h * 0.5, 0.0)
			line.rotation_degrees.y = seg_y_rot
			var lmat: StandardMaterial3D = line.material_override as StandardMaterial3D
			if lmat != null:
				lmat.emission_energy_multiplier = 1.4
			world_fx_root.add_child(line)


# ── Neon city buildings ───────────────────────────────────────────────────────
# Hard-capped at MAX_BLDGS total so draw-call count stays fixed regardless of
# song length.  All window strips on a building share one material — pulsing
# costs O(building_count) per beat, not O(strip_count).
func _spawn_city_buildings() -> void:
	const MAX_BLDGS_PER_SIDE: int = 18   # 36 total — cheap enough for smooth play
	var end_z: float = _song_end_z()
	var tw:    float = _track_full_width()

	var body_col: Color = Color(0.04, 0.02, 0.08, 1.0)
	# Two distance rows — closer row is bigger buildings, far row is taller/thinner
	var dist_rows: Array[float] = [tw * 0.5 + 16.0, tw * 0.5 + 30.0]

	var building_templates: Array = [
		[4.0, 5.0, 14.0], [3.0, 4.0, 10.0], [5.5, 6.0, 20.0],
		[2.5, 3.5,  8.0], [4.5, 5.0, 24.0], [3.5, 4.0, 12.0],
		[6.0, 6.5, 28.0], [2.8, 3.5,  9.0], [4.0, 5.0, 16.0],
	]

	var win_palette: Array[Color] = [
		Color(1.00, 0.25, 0.60, 1.0),
		Color(0.20, 0.80, 1.00, 1.0),
		Color(0.65, 0.10, 1.00, 1.0),
		Color(1.00, 0.85, 0.10, 1.0),
		Color(0.30, 1.00, 0.55, 1.0),
		Color(0.90, 0.25, 1.00, 1.0),
	]

	# Authored Blender buildings ("building") — the game cycles through ALL
	# authored ones; the far row is stretched taller/thinner exactly like the
	# procedural templates. "Windows" emissives pulse with the city beat.
	var bldg_entries: Array = (_piece_lib.of_type("building") if _piece_lib != null else [])

	var bldg_i: int = 0

	for side in [-1, 1]:
		for ri in dist_rows.size():
			var dist: float = dist_rows[ri]
			# Spread MAX_BLDGS_PER_SIDE buildings evenly across the track length
			var step: float = end_z / float(MAX_BLDGS_PER_SIDE)
			for bi in MAX_BLDGS_PER_SIDE:
				var bz:   float = step * 0.4 + float(bi) * step + float(ri) * step * 0.5
				if _z_is_electric(bz):
					bldg_i += 1
					continue

				if not bldg_entries.is_empty():
					var b_entry: Dictionary = bldg_entries[bldg_i % bldg_entries.size()]
					var b_anchor := Node3D.new()
					b_anchor.position           = _path_world_pos(bz, float(side) * dist, 0.0)
					b_anchor.rotation_degrees.y = _path_y_rot_at(bz)
					if ri == 1:
						b_anchor.scale = Vector3(0.65, 1.4, 1.0)   # far row: taller + thinner
					world_fx_root.add_child(b_anchor)
					var b_inst: Node3D = _piece_lib.instance(b_entry)
					b_inst.rotation_degrees.y = 180.0
					b_anchor.add_child(b_inst)
					_register_piece_emissives(b_inst, _city_bldg_mats)

					var b_h: float = float(b_entry.params.get("height", 14.0)) * b_anchor.scale.y
					var b_rlight := OmniLight3D.new()
					b_rlight.light_color  = win_palette[(bldg_i + ri * 3) % win_palette.size()]
					b_rlight.light_energy = 0.5
					b_rlight.omni_range   = 10.0
					b_rlight.position     = _path_world_pos(bz, float(side) * dist, b_h + 0.8)
					world_fx_root.add_child(b_rlight)
					_city_bldg_lights.append(b_rlight)

					bldg_i += 1
					continue

				var tmpl: Array = building_templates[bldg_i % building_templates.size()]
				var bw: float   = tmpl[0] as float
				var bd: float   = tmpl[1] as float
				var bh: float   = tmpl[2] as float
				# Far row: taller and thinner
				if ri == 1:
					bw *= 0.65; bh *= 1.4
				var blat: float = float(side) * dist

				# ── Dark silhouette ──────────────────────────────────────────
				var body := MeshInstance3D.new()
				var bm   := BoxMesh.new()
				bm.size = Vector3(bw, bh, bd)
				body.mesh = bm
				var body_mat := StandardMaterial3D.new()
				body_mat.albedo_color               = body_col
				body_mat.emission_enabled           = false
				body.material_override = body_mat
				body.position = _path_world_pos(bz, blat, bh * 0.5)
				body.rotation_degrees.y = _path_y_rot_at(bz)
				world_fx_root.add_child(body)

				# ── Window strips — all share ONE material per building ───────
				var win_col: Color = win_palette[(bldg_i + ri * 3) % win_palette.size()]
				var win_mat := StandardMaterial3D.new()
				win_mat.albedo_color               = win_col.darkened(0.30)
				win_mat.emission_enabled           = true
				win_mat.emission                   = win_col
				win_mat.emission_energy_multiplier = 0.8
				_city_bldg_mats.append(win_mat)

				var strip_h:  float = 0.14
				var strip_gap: float = 2.2
				var win_y:    float = strip_gap
				while win_y < bh - 0.5:
					var strip := MeshInstance3D.new()
					var sm    := BoxMesh.new()
					sm.size = Vector3(bw + 0.04, strip_h, 0.10)
					strip.mesh = sm
					strip.material_override = win_mat   # shared — no extra material object
					strip.position = _path_world_pos(bz, blat, win_y + strip_h * 0.5)
					strip.rotation_degrees.y = _path_y_rot_at(bz)
					world_fx_root.add_child(strip)
					win_y += strip_gap

				# ── One roof light per building ───────────────────────────────
				var rlight := OmniLight3D.new()
				rlight.light_color  = win_col
				rlight.light_energy = 0.5
				rlight.omni_range   = 10.0
				rlight.position     = _path_world_pos(bz, blat, bh + 0.8)
				world_fx_root.add_child(rlight)
				_city_bldg_lights.append(rlight)

				bldg_i += 1


# ── City pulse decay (called every frame, O(building_count)) ─────────────────
func _update_city_pulse(delta: float) -> void:
	if _city_pulse_t <= 0.0:
		return
	var beat_s: float = max(0.18, _runner_avg_beat_s)
	_city_pulse_t = maxf(0.0, _city_pulse_t - delta / (beat_s * 0.55))

	var vit: float = _world_vitality
	# Vitality scales the peak burst: at low vitality buildings barely flicker;
	# at high vitality they strobe hard on every beat.
	var peak_e:  float = lerpf(0.5, 2.5, vit)
	var peak_l:  float = lerpf(0.15, 1.8, vit)
	var energy:  float = lerpf(lerpf(0.1, 0.6, vit), peak_e, _city_pulse_t)
	var light_e: float = lerpf(lerpf(0.0, 0.3, vit), peak_l, _city_pulse_t)

	for mat in _city_bldg_mats:
		mat.emission_energy_multiplier = energy
	for rlight in _city_bldg_lights:
		rlight.light_energy = light_e


# ── Song progress bar update ──────────────────────────────────────────────────
func _update_hud_progress(t_s: float) -> void:
	if _hud_progress_fill == null:
		return

	# Derive total length from the last gameplay event + a small buffer
	if _song_total_duration <= 0.0:
		_song_total_duration = _song_end_z() / player.forward_speed

	var pct: float = clamp(t_s / _song_total_duration, 0.0, 1.0)
	var vp_w: float = float(get_viewport().get_visible_rect().size.x)
	_hud_progress_fill.offset_right = vp_w * pct

	# Move the glow cap to the leading edge
	var cap: Control = _hud_progress_fill.get_parent().get_node_or_null("ProgCap") as Control
	if cap != null:
		cap.offset_left  = vp_w * pct - 2.0
		cap.offset_right = vp_w * pct + 4.0


# ── Pause / resume ────────────────────────────────────────────────────────────
func _pause_game() -> void:
	_paused = true
	self.process_mode   = Node.PROCESS_MODE_ALWAYS  # keep input + HUD alive
	get_tree().paused   = true                       # freeze everything else
	music.stream_paused = true
	player.set_physics_process(false)
	player.set_process(false)

	# Build the pause overlay on the existing HUD CanvasLayer
	if _hud_flash == null:
		return
	var hud_root: Control = _hud_flash.get_parent() as Control
	if hud_root == null:
		return

	_pause_option = 0

	# Dark semi-transparent veil
	var veil := ColorRect.new()
	veil.name = "PauseVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = Color(0.02, 0.01, 0.08, 0.82)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(veil)
	_pause_root = veil

	# Neon border frame (four thin rects)
	var border_col: Color = Color(0.65, 0.22, 1.00, 0.80)
	for side in range(4):
		var b := ColorRect.new()
		b.color = border_col
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		match side:
			0: b.anchor_left=0.25; b.anchor_right=0.75; b.anchor_top=0.30; b.anchor_bottom=0.30; b.offset_bottom=3
			1: b.anchor_left=0.25; b.anchor_right=0.75; b.anchor_top=0.70; b.anchor_bottom=0.70; b.offset_bottom=3
			2: b.anchor_left=0.25; b.anchor_right=0.25; b.anchor_top=0.30; b.anchor_bottom=0.70; b.offset_right=3
			3: b.anchor_left=0.75; b.anchor_right=0.75; b.anchor_top=0.30; b.anchor_bottom=0.70; b.offset_right=3
		veil.add_child(b)

	# "PAUSED" title
	var title := Label.new()
	title.text = "PAUSED"
	title.anchor_left   = 0.5; title.anchor_right  = 0.5
	title.anchor_top    = 0.5; title.anchor_bottom = 0.5
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	title.grow_vertical   = Control.GROW_DIRECTION_BOTH
	title.offset_left  = -160; title.offset_right  = 160
	title.offset_top   = -110; title.offset_bottom = -60
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.80, 0.35, 1.00, 1.0))
	title.add_theme_font_size_override("font_size", 42)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.add_child(title)

	# Menu options  (0=RESUME  1=RESTART  2=MAIN MENU  3=SONG SELECT  4=CALIBRATE AUDIO)
	var opt_labels: Array[String] = ["▶  RESUME", "↺  RESTART  (-1 life)", "⌂  MAIN MENU", "⏹  SONG SELECT", "⊙  CALIBRATE AUDIO"]
	var opt_ys:     Array[float]  = [-104.0, -52.0, 0.0, 52.0, 104.0]
	for i in 5:
		var opt := Label.new()
		opt.name = "PauseOpt%d" % i
		opt.text = opt_labels[i]
		opt.anchor_left   = 0.5; opt.anchor_right  = 0.5
		opt.anchor_top    = 0.5; opt.anchor_bottom = 0.5
		opt.grow_horizontal = Control.GROW_DIRECTION_BOTH
		opt.grow_vertical   = Control.GROW_DIRECTION_BOTH
		opt.offset_left  = -160; opt.offset_right  = 160
		opt.offset_top   = opt_ys[i]; opt.offset_bottom = opt_ys[i] + 40
		opt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		opt.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		opt.add_theme_font_size_override("font_size", 22)
		opt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		veil.add_child(opt)

	# Hint text
	var hint := Label.new()
	hint.text = "ESC / Start  ·  ↑↓ navigate  ·  Enter / A confirm"
	hint.anchor_left   = 0.5; hint.anchor_right  = 0.5
	hint.anchor_top    = 0.5; hint.anchor_bottom = 0.5
	hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint.offset_left  = -240; hint.offset_right  = 240
	hint.offset_top   = 112;  hint.offset_bottom = 132
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.55, 0.45, 0.65, 0.70))
	hint.add_theme_font_size_override("font_size", 13)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.add_child(hint)

	# Animate the veil fading in
	veil.modulate.a = 0.0
	var ftw := create_tween()
	ftw.tween_property(veil, "modulate:a", 1.0, 0.18)

	_pause_update_selection()


func _pause_update_selection() -> void:
	if _pause_root == null:
		return
	var sel_col:  Color = Color(1.00, 0.95, 0.30, 1.0)   # gold — selected
	var mute_col: Color = Color(0.60, 0.50, 0.75, 0.75)  # muted — unselected
	var warn_col: Color = Color(1.00, 0.45, 0.20, 1.0)   # orange — restart warning
	for i in 4:
		var opt: Label = _pause_root.get_node_or_null("PauseOpt%d" % i) as Label
		if opt == null:
			continue
		var is_sel: bool = (i == _pause_option)
		var col: Color
		if is_sel:
			col = warn_col if i == 1 else sel_col
		else:
			col = mute_col
		opt.add_theme_color_override("font_color", col)
		opt.add_theme_font_size_override("font_size", 24 if is_sel else 20)


func _pause_confirm() -> void:
	match _pause_option:
		0:  # Resume
			_resume_game()
		1:  # Restart — costs one life, reloads the game scene
			_resume_game()   # unpause first so scene change is clean
			Run.song_lives -= 1
			var exhausted: bool = (Run.song_lives <= 0)
			if exhausted:
				_runner_rng.randomize()
				Run.run_seed   = _runner_rng.seed
				Run.song_lives = GameConfig.lives_per_song
			get_tree().reload_current_scene()
		2:  # Main Menu
			_resume_game()
			Run.run_seed   = 0
			Run.song_lives = GameConfig.lives_per_song
			get_tree().change_scene_to_file("res://scenes/Main.tscn")
		3:  # Song Select
			_resume_game()
			Run.run_seed   = 0
			Run.song_lives = GameConfig.lives_per_song
			get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")
		4:  # Calibrate Audio — overlay calibrator on top of paused game
			_launch_audio_calibrator()


func _launch_audio_calibrator() -> void:
	# Hide the pause overlay while calibrating (it comes back on cancel/complete).
	if _pause_root != null:
		_pause_root.visible = false
	var cal: Node = load("res://scripts/AudioCalibrator.gd").new()
	cal.calibration_complete.connect(func(_ms: float) -> void:
		if _pause_root != null:
			_pause_root.visible = true
	)
	cal.calibration_cancelled.connect(func() -> void:
		if _pause_root != null:
			_pause_root.visible = true
	)
	add_child(cal)   # Section is PROCESS_MODE_ALWAYS while paused — calibrator inherits it


func _resume_game() -> void:
	self.process_mode   = Node.PROCESS_MODE_INHERIT  # restore normal processing
	get_tree().paused   = false                       # unfreeze everything
	_paused = false
	music.stream_paused = false
	player.set_physics_process(true)
	player.set_process(true)

	if _pause_root != null:
		var ftw := create_tween()
		ftw.tween_property(_pause_root, "modulate:a", 0.0, 0.14)
		ftw.tween_callback(_pause_root.queue_free)
		_pause_root = null


func _mark_gate_result(idx: int, success: bool) -> void:
	if idx < 0 or idx >= gate_nodes.size():
		return
	_on_gate_scored(success)
	var gate: Node3D = gate_nodes[idx]
	var hit_color: Color = Color(0.30, 1.00, 0.40, 1.0) if success else Color(1.00, 0.20, 0.20, 1.0)

	# Grab the gate's original colour BEFORE overwriting it, so the echo uses it
	var gate_color: Color = Color(1.0, 1.0, 1.0, 1.0)
	for c in gate.get_children():
		var cmi: MeshInstance3D = c as MeshInstance3D
		if cmi == null:
			continue
		var cmat: StandardMaterial3D = cmi.material_override as StandardMaterial3D
		if cmat == null:
			continue
		gate_color = cmat.albedo_color
		gate_color.a = 1.0
		break   # one sample is enough

	for c in gate.get_children():
		var mi: MeshInstance3D = c as MeshInstance3D
		if mi == null:
			continue
		var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.albedo_color = hit_color
		mat.emission = hit_color
		mat.emission_energy_multiplier = 1.35

	# Light burst on hit/miss at the gate position
	var flash := OmniLight3D.new()
	flash.light_color  = hit_color
	flash.light_energy = 2.5 if success else 1.2
	flash.omni_range   = 14.0
	flash.position     = gate.global_position + Vector3(0.0, 1.5, 0.0)
	world_fx_root.add_child(flash)
	var ftw := create_tween()
	ftw.tween_property(flash, "light_energy", 0.0, 0.35)
	ftw.tween_callback(flash.queue_free)

	# On a clean hit: ghost echo at the player's lane in the gate's own colour
	if success:
		_spawn_gate_echo(gate.global_position, gate_color)

func _spawn_gate_echo(gate_world_pos: Vector3, echo_color: Color) -> void:
	# A translucent ghost of the gate that pulses outward and fades on a clean hit.
	# Positioned on the player's current lane so it feels personal. Very subtle.
	var qm := QuadMesh.new()
	qm.size = Vector2(lane_blocker_width * 1.05, lane_blocker_height * 1.05)

	var mat := StandardMaterial3D.new()
	mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode     = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode      = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color   = Color(echo_color.r, echo_color.g, echo_color.b, 0.10)
	qm.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = qm
	world_fx_root.add_child(mi)   # must be in tree before global_position is valid

	# Place at gate world position, offset laterally to the player's current lane
	var lane_lateral: float = player.lane_xs[player.current_lane]
	var rgt: Vector3 = _path_right_at(_player_path_dist)
	mi.global_position = Vector3(
		gate_world_pos.x + rgt.x * lane_lateral,
		lane_blocker_height * 0.5,
		gate_world_pos.z + rgt.z * lane_lateral)

	# Expand outward and fade to nothing over ~0.7 s
	var tw := create_tween().set_parallel(true)
	tw.tween_property(mi,  "scale",
			Vector3(2.0, 2.0, 1.0), 0.70
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color",
			Color(echo_color.r, echo_color.g, echo_color.b, 0.0), 0.70
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(mi.queue_free)


func _run_world_events(t_s: float) -> void:
	while _world_index < world_events.size():
		var e: Dictionary = world_events[_world_index]
		var ev_t: float = float(e.get("t", 0.0))
		if t_s < ev_t:
			return
		var pass_id: String = String(e.get("capture_pass", ""))
		var ev_dur: float   = float(e.get("dur", 0.0))   # > 0 for hold / long notes
		_pulse_world(pass_id, ev_dur)
		_world_index += 1


## Returns outline points (Vector2, XY plane) for the requested shape at the given radius.
## Handles: triangle, square, pentagon, hexagon, star, diamond, cross, heart.
## (circle is handled separately as a TorusMesh — not routed through here.)
func _get_shape_points(shape_id: String, radius: float) -> Array:
	var pts: Array = []
	match shape_id:
		"triangle":
			for i in 3:
				var a: float = (i / 3.0) * TAU - PI * 0.5
				pts.append(Vector2(cos(a), sin(a)) * radius)
		"square":
			for i in 4:
				var a: float = (i / 4.0) * TAU + PI * 0.25
				pts.append(Vector2(cos(a), sin(a)) * radius)
		"pentagon":
			for i in 5:
				var a: float = (i / 5.0) * TAU - PI * 0.5
				pts.append(Vector2(cos(a), sin(a)) * radius)
		"hexagon":
			for i in 6:
				var a: float = (i / 6.0) * TAU
				pts.append(Vector2(cos(a), sin(a)) * radius)
		"diamond":
			for i in 4:
				var a: float = (i / 4.0) * TAU
				pts.append(Vector2(cos(a), sin(a)) * radius)
		"cross":
			var w: float = radius * 0.28
			var l: float = radius
			pts = [
				Vector2(-w, -l), Vector2( w, -l),
				Vector2( w, -w), Vector2( l, -w),
				Vector2( l,  w), Vector2( w,  w),
				Vector2( w,  l), Vector2(-w,  l),
				Vector2(-w,  w), Vector2(-l,  w),
				Vector2(-l, -w), Vector2(-w, -w),
			]
		"heart":
			var steps: int = 32
			for i in steps:
				var t: float = (i / float(steps)) * TAU
				var x: float = 16.0 * pow(sin(t), 3.0)
				var y: float = -(13.0 * cos(t) - 5.0 * cos(2.0*t) - 2.0 * cos(3.0*t) - cos(4.0*t))
				pts.append(Vector2(x, y) * (radius / 16.0))
		_:  # "star" and any unknown value
			for i in 10:
				var a: float = (i / 10.0) * TAU - PI * 0.5
				var r: float = radius if i % 2 == 0 else radius * 0.42
				pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## Builds a Node3D tracing a closed outline through pts.
## tube_r controls how thick each segment is (box cross-section = tube_r * 2).
## All segments share mat so colour/alpha updates affect them all.
func _build_shape_node(pts: Array, mat: StandardMaterial3D, tube_r: float = 0.18) -> Node3D:
	var root := Node3D.new()
	var n: int = pts.size()
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var seg := MeshInstance3D.new()
		var bm  := BoxMesh.new()
		var length: float = a.distance_to(b)
		var side: float   = tube_r * 2.0
		bm.size               = Vector3(side, length, side)
		seg.mesh              = bm
		seg.material_override = mat
		var mid: Vector2 = (a + b) * 0.5
		seg.position     = Vector3(mid.x, mid.y, 0.0)
		seg.rotation.z   = atan2(b.y - a.y, b.x - a.x) - PI * 0.5
		root.add_child(seg)
	return root


## Authored Blender halo ("halo") — spawned instead of the procedural ring when
## one exists. Scaled to the configured halo size, spun like the procedural
## one, and faded through per-instance transparency so the authored materials
## are never modified (colour settings don't apply to authored halos).
func _spawn_authored_halo(note_dur: float) -> bool:
	var entry: Dictionary = (_piece_lib.first_of("halo") if _piece_lib != null else {})
	if entry.is_empty():
		return false
	var ahead:   float = player.forward_speed * 0.55
	var ring_pd: float = _player_path_dist + ahead
	if ring_pd >= _wj_zone_start_z and ring_pd <= _wj_zone_end_z:
		return true   # halos stay suppressed inside the wall-jump section

	var pivot := Node3D.new()
	pivot.position           = _path_world_pos(ring_pd, 0.0, 1.0)
	pivot.rotation_degrees.y = _path_y_rot_at(ring_pd)
	world_fx_root.add_child(pivot)

	var inst: Node3D = _piece_lib.instance(entry)
	var auth_r: float = maxf(0.1, float(entry.params.get("radius", 5.8)))
	inst.scale = Vector3.ONE * (GameConfig.halo_size / auth_r)
	pivot.add_child(inst)

	# Per-instance transparency fade — meshes share the authored materials,
	# so hundreds of hold-tunnel rings cost no extra material objects.
	var geoms: Array = []
	var stack: Array = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).transparency = 1.0
			geoms.append(n)
		for c in n.get_children():
			stack.append(c)
	var fade := func(v: float) -> void:
		for g in geoms:
			(g as GeometryInstance3D).transparency = v

	var tw_in := _fx_tween_host.create_tween()
	tw_in.tween_method(fade, 1.0, 0.45, 0.15)

	var cam_behind: float = 4.0
	if _camera != null:
		var to_cam: Vector3 = pivot.position - _camera.global_position
		cam_behind = maxf(to_cam.dot(_path_forward_at(ring_pd)), 2.0)
	var time_to_cam_pass: float = ((ahead + cam_behind) / maxf(player.forward_speed, 1.0)) + 0.10
	time_to_cam_pass += maxf(0.0, note_dur)

	# Halos that bring their own animation loop spin themselves — the game's
	# random pivot spin would fight it. Fade + lifetime stay game-driven.
	if not bool(entry.get("animated", false)):
		var spin_speed: float = randf_range(0.4, 1.2)
		var spin_dir:   float = 1.0 if randf() > 0.5 else -1.0
		var spin_tween := _fx_tween_host.create_tween()
		spin_tween.tween_property(pivot, "rotation_degrees:z",
			360.0 * spin_dir * spin_speed, time_to_cam_pass + 5.00)
		if note_dur > 0.2:
			var inner_tween := _fx_tween_host.create_tween()
			inner_tween.tween_property(pivot, "rotation_degrees:y",
				pivot.rotation_degrees.y - 120.0 * spin_dir, note_dur * 0.5)

	var tw_out := _fx_tween_host.create_tween()
	tw_out.tween_interval(time_to_cam_pass)
	tw_out.tween_method(fade, 0.45, 1.0, 0.20)
	tw_out.tween_callback(pivot.queue_free)
	return true


func _spawn_halo_ring(note_dur: float = 0.0) -> void:
	if player == null:
		return
	if _spawn_authored_halo(note_dur):
		return

	var t_s:      float = _song_time()
	var vit:      float = _world_vitality
	var init_col_a: Color = _current_cycle_color(t_s) if GameConfig.color_cycle_affects_halos else GameConfig.halo_color_a
	var init_col_b: Color = GameConfig.halo_color_b   if GameConfig.halo_dual_color           else init_col_a

	var ahead: float     = player.forward_speed * 0.55
	var ring_pd: float   = _player_path_dist + ahead   # path distance of the ring

	# Suppress halos inside the wall-jump section
	if ring_pd >= _wj_zone_start_z and ring_pd <= _wj_zone_end_z:
		return

	# ── Material A (primary — every odd segment, or everything when mono) ──
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color               = Color(init_col_a.r, init_col_a.g, init_col_a.b, 0.0)
	rmat.emission_enabled           = true
	rmat.emission                   = init_col_a
	rmat.emission_energy_multiplier = 2.5
	rmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA

	# ── Material B (secondary — every even segment; only used if dual_color) ──
	var rmat_b: StandardMaterial3D = null
	if GameConfig.halo_dual_color:
		rmat_b = StandardMaterial3D.new()
		rmat_b.albedo_color               = Color(init_col_b.r, init_col_b.g, init_col_b.b, 0.0)
		rmat_b.emission_enabled           = true
		rmat_b.emission                   = init_col_b
		rmat_b.emission_energy_multiplier = 2.5
		rmat_b.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Pivot sits at track centre at ring path dist; shape nodes are children
	var pivot := Node3D.new()
	pivot.position = _path_world_pos(ring_pd, 0.0, 1.0)
	pivot.rotation_degrees.y = _path_y_rot_at(ring_pd)
	world_fx_root.add_child(pivot)

	# Build halo — shape and radius driven by GameConfig
	var radius:   float  = GameConfig.halo_size
	var tube_r:   float  = clampf(radius * 0.1, 0.1, 0.1)
	var shape_id: String = GameConfig.halo_shape

	# Whether this halo uses a baked texture for dual colour (circle only).
	# Texture-based halos are excluded from per-frame recolouring — only alpha is tweened.
	var _texture_dual_circle: bool = false

	if shape_id == "circle":
		# Dual-colour: bake alternating stripes of col A and col B into the torus UV —
		# no second ring is generated; the texture lives on the original geometry.
		if GameConfig.halo_dual_color:
			_texture_dual_circle = true
			var stripe_img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
			for x in 256:
				var sc: Color = init_col_a if int(float(x) / 256.0 * 12.0) % 2 == 0 else init_col_b
				stripe_img.set_pixel(x, 0, sc)
			var stripe_tex := ImageTexture.create_from_image(stripe_img)
			rmat.albedo_texture   = stripe_tex
			rmat.emission_texture = stripe_tex
			rmat.emission         = Color(1.0, 1.0, 1.0, 0.0)   # texture drives colour; transparent = no tint
			rmat.albedo_color     = Color(1.0, 1.0, 1.0, 0.0)
			rmat_b = null   # texture carries both colours; no separate B material needed
		var ring := MeshInstance3D.new()
		var tmesh := TorusMesh.new()
		tmesh.inner_radius     = radius - tube_r
		tmesh.outer_radius     = radius + tube_r
		tmesh.rings            = 12
		tmesh.ring_segments    = 48
		ring.mesh              = tmesh
		ring.rotation_degrees  = Vector3(90.0, 0.0, 0.0)
		ring.material_override = rmat
		pivot.add_child(ring)
	else:
		var pts: Array = _get_shape_points(shape_id, radius)
		if rmat_b == null:
			# Mono — one shape, one material
			var shape_node: Node3D = _build_shape_node(pts, rmat, tube_r)
			pivot.add_child(shape_node)
		else:
			# Dual — alternating A/B colours across a single ring's segments (no extra geometry)
			var outer_node: Node3D = _build_shape_node_alternating(pts, rmat, rmat_b, tube_r)
			pivot.add_child(outer_node)

	if not _texture_dual_circle:
		_active_halo_mats.append(rmat)
	if rmat_b != null:
		_active_halo_mats_b.append(rmat_b)

	# Fade in quickly
	var rtw_in := _fx_tween_host.create_tween()
	rtw_in.tween_property(rmat, "albedo_color:a", 0.50, 0.15)
	if rmat_b != null:
		var rtw_in_b := _fx_tween_host.create_tween()
		rtw_in_b.tween_property(rmat_b, "albedo_color:a", 0.44, 0.15)

	# Stay visible until camera clears it, then fade out.
	# For hold notes (note_dur > 0), add the hold duration so the halo persists
	# for the full length of the note before fading.
	var cam_behind: float = 4.0
	if _camera != null:
		# Approximate camera-to-ring distance along the path direction
		var to_cam: Vector3 = pivot.position - _camera.global_position
		cam_behind = maxf(to_cam.dot(_path_forward_at(ring_pd)), 2.0)
	var time_to_cam_pass: float = ((ahead + cam_behind) / maxf(player.forward_speed, 1.0)) + 0.10
	time_to_cam_pass += maxf(0.0, note_dur)   # sustain for the full note length

	var spin_speed: float = randf_range(0.4, 1.2)
	var spin_dir:   float = 1.0 if randf() > 0.5 else -1.0
	var spin_tween := _fx_tween_host.create_tween()
	spin_tween.tween_property(pivot, "rotation_degrees:z",
		360.0 * spin_dir * spin_speed, time_to_cam_pass + 5.00)

	# If it's a hold note, spawn a counter-rotating inner spin for the B ring (visual candy)
	if rmat_b != null and note_dur > 0.2:
		var inner_tween := _fx_tween_host.create_tween()
		inner_tween.tween_property(pivot, "rotation_degrees:y",
			-120.0 * spin_dir, note_dur * 0.5)

	var rtw_out := _fx_tween_host.create_tween()
	rtw_out.tween_interval(time_to_cam_pass)
	rtw_out.tween_property(rmat, "albedo_color:a", 0.0, 0.18)
	rtw_out.parallel().tween_property(rmat, "emission_energy_multiplier", 0.0, 0.18)
	if rmat_b != null:
		rtw_out.parallel().tween_property(rmat_b, "albedo_color:a", 0.0, 0.22)
		rtw_out.parallel().tween_property(rmat_b, "emission_energy_multiplier", 0.0, 0.22)
	rtw_out.tween_callback(func() -> void:
		_active_halo_mats.erase(rmat)
		if rmat_b != null:
			_active_halo_mats_b.erase(rmat_b)
		pivot.queue_free()
	)


## Spawns a tunnel of halo rings that builds gradually over the hold duration.
## Each ring is scheduled via a tween callback so it spawns at the player's
## actual position at that moment — creating a corridor that grows ring by ring.
func _spawn_hold_tunnel(note_dur: float) -> void:
	if player == null or note_dur < 0.25:
		_spawn_halo_ring(note_dur)
		return

	# One ring roughly every 0.40 s, capped at 8 total.
	var ring_count: int = mini(1880, maxi(2, int(note_dur / 0.005) + 1))
	var interval: float = note_dur / float(ring_count)

	# First ring fires immediately.
	_spawn_halo_ring(0.0)

	# Subsequent rings are scheduled one at a time. Because each callback
	# reads player.global_position when it fires, every ring lands just
	# ahead of wherever the player actually is at that moment.
	for i in range(1, ring_count):
		var delay: float = float(i) * interval
		var tw := _fx_tween_host.create_tween()
		tw.tween_interval(delay)
		tw.tween_callback(func() -> void: _spawn_halo_ring(0.0))


## Builds a shape node where alternating segments use mat_odd / mat_even.
## Used for dual-colour halos — creates a striped neon pattern.
func _build_shape_node_alternating(pts: Array, mat_odd: StandardMaterial3D,
		mat_even: StandardMaterial3D, tube_r: float = 0.18) -> Node3D:
	var root := Node3D.new()
	var n: int = pts.size()
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var seg := MeshInstance3D.new()
		var bm  := BoxMesh.new()
		var length: float = a.distance_to(b)
		var side:   float = tube_r * 2.0
		bm.size               = Vector3(side, length, side)
		seg.mesh              = bm
		seg.material_override = mat_odd if (i % 2 == 0) else mat_even
		var mid: Vector2 = (a + b) * 0.5
		seg.position     = Vector3(mid.x, mid.y, 0.0)
		seg.rotation.z   = atan2(b.y - a.y, b.x - a.x) - PI * 0.5
		root.add_child(seg)
	return root


func _pulse_world(pass_id: String, note_dur: float = 0.0) -> void:
	if player == null:
		return
	var is_melody: bool = pass_id == "melody"
	var pulse_color: Color = melody_world_color if is_melody else fx_world_color
	if is_melody or pass_id == "fx":
		if note_dur > 0.25:
			_spawn_hold_tunnel(note_dur)
		else:
			_spawn_halo_ring(note_dur)
	var vit: float        = _world_vitality
	var spire_pd_ahead: float = randf_range(0.0, 5.0)
	var spire_pd: float      = _player_path_dist + spire_pd_ahead

	# ── 1. Rising light spires (both sides) ──────────────────────────────────
	# Tall thin columns erupt on both sides of the track, shoot upward,
	# bloom with light, then dissolve — like ghost pillars rising together.
	for spire_lat: float in [-7.2, 7.2]:
		var spire: MeshInstance3D = MeshInstance3D.new()
		var smesh := BoxMesh.new()
		smesh.size    = Vector3(0.10, 5.5, 0.10)
		spire.mesh    = smesh
		var smat      := StandardMaterial3D.new()
		smat.albedo_color              = Color(pulse_color.r, pulse_color.g, pulse_color.b, 0.90)
		smat.emission_enabled          = true
		smat.emission                  = pulse_color
		smat.emission_energy_multiplier = lerpf(2.5, 6.0, vit)
		smat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
		spire.material_override        = smat
		spire.position                 = _path_world_pos(spire_pd, spire_lat, -0.8)
		world_fx_root.add_child(spire)
		var stw := create_tween()
		stw.parallel().tween_property(spire, "position:y", 3.2, 0.22)
		stw.parallel().tween_property(smat, "emission_energy_multiplier", 0.0, 0.75)
		stw.parallel().tween_property(smat, "albedo_color:a", 0.0, 0.70)
		stw.tween_callback(spire.queue_free)
		# Light bloom at spire peak
		var spl := OmniLight3D.new()
		spl.light_color  = pulse_color
		spl.light_energy = lerpf(1.8, 4.0, vit)
		spl.omni_range   = 11.0
		spl.position     = _path_world_pos(spire_pd, spire_lat, 3.0)
		world_fx_root.add_child(spl)
		var spltw := create_tween()
		spltw.tween_property(spl, "light_energy", 0.0, 0.80)
		spltw.tween_callback(spl.queue_free)

	# ── 3. Floating wisps ─────────────────────────────────────────────────────
	# Small glowing orbs drift upward from both track edges like fireflies
	# stirred by the melody — gives the air a living, musical feel.
	var wsp_count: int = 5
	for side in [-4.6, 4.6]:
		for i in range(wsp_count):
			var wsp: MeshInstance3D = MeshInstance3D.new()
			var wsm                 := SphereMesh.new()
			wsm.radius          = 0.05 + randf() * 0.07
			wsm.height          = wsm.radius * 2.0
			wsm.radial_segments = 6
			wsm.rings           = 3
			wsp.mesh            = wsm
			var wmat            := StandardMaterial3D.new()
			var wc: Color        = pulse_color.lightened(randf() * 0.35)
			wmat.albedo_color              = Color(wc.r, wc.g, wc.b, 0.92)
			wmat.emission_enabled          = true
			wmat.emission                  = wc
			wmat.emission_energy_multiplier = lerpf(3.0, 7.0, vit)
			wmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
			wsp.material_override          = wmat
			var z_off: float  = float(i) * 2.0 - 3.0
			var x_off: float  = side + randf_range(-0.9, 0.9)
			wsp.position      = _path_world_pos(_player_path_dist + z_off, x_off, 0.2 + randf() * 0.6)
			world_fx_root.add_child(wsp)
			var dur: float     = 0.55 + randf() * 0.40
			var rise: float    = 2.0 + randf() * 2.0
			var drift_x: float = x_off + randf_range(-0.8, 0.8)
			var wtw := create_tween()
			wtw.parallel().tween_property(wsp, "position:y", wsp.position.y + rise, dur)
			wtw.parallel().tween_property(wsp, "position:x", drift_x, dur)
			wtw.parallel().tween_property(wmat, "emission_energy_multiplier", 0.0, dur * 0.90)
			wtw.parallel().tween_property(wmat, "albedo_color:a", 0.0, dur * 0.88)
			wtw.tween_callback(wsp.queue_free)

	# ── 4. Fog colour pulse ───────────────────────────────────────────────────
	# The world's atmospheric fog briefly absorbs the melody's colour —
	# a full-scene tint that feels cinematic without cluttering the track.
	if _melody_env != null:
		var fog_target: Color = pulse_color.darkened(0.50)
		fog_target.a = 1.0
		_melody_env.fog_light_color = fog_target
		var ftw := create_tween()
		ftw.tween_property(_melody_env, "fog_light_color", Color(0.12, 0.04, 0.25, 1.0), 1.4)

func _run_floor_beats(t_s: float) -> void:
	while _gameplay_pulse_index < gameplay_events.size():
		var e: Dictionary = gameplay_events[_gameplay_pulse_index]
		var ev_t: float = float(e.get("t", 0.0))
		if t_s < ev_t:
			return

		_pulse_floor_beat(t_s)
		_gameplay_pulse_index += 1


func _pulse_floor_beat(t_s: float) -> void:
	# Snap beat phase to 1 — decays in _process to drive per-frame brightness spikes
	_beat_phase   = 1.0
	_beat_cam_t   = 1.0   # camera FOV pulse

	var vit: float = _world_vitality
	var pulse_color: Color = Color(1.0, 1.0, 1.0, 1.0)
	if GameConfig.color_cycle_affects_floor and has_method("_current_cycle_color"):
		pulse_color = call("_current_cycle_color", t_s)
	pulse_color = pulse_color.lightened(0.10)

	# Floor emission pulse — peak height and decay speed scale with vitality
	if _floor_material != null:
		var peak: float = lerpf(0.15, 0.90, vit)
		_floor_material.emission_enabled = true
		_floor_material.emission = pulse_color
		_floor_material.emission_energy_multiplier = peak
		var tw: Tween = create_tween()
		tw.tween_property(_floor_material, "emission_energy_multiplier", 0.02, lerpf(0.25, 0.14, vit))
		tw.tween_property(_floor_material, "emission", Color(0.0, 0.0, 0.0, 1.0), 0.14)

	# Beat light burst at player — range and energy scale with vitality
	if player != null:
		var beat_light := OmniLight3D.new()
		beat_light.light_color  = pulse_color
		beat_light.light_energy = lerpf(0.3, 2.2, vit)
		beat_light.omni_range   = lerpf(6.0, 16.0, vit)
		beat_light.position     = player.global_position + Vector3(0.0, 2.2, 0.0)
		world_fx_root.add_child(beat_light)
		var ltw := create_tween()
		ltw.tween_property(beat_light, "light_energy", 0.0, lerpf(0.18, 0.32, vit))
		ltw.tween_callback(beat_light.queue_free)

	# Kick city / electric pulse — zone-aware: only drive the theme active at this beat
	if _is_electric_at(t_s):
		_elec_pulse_t = 1.0
	else:
		_city_pulse_t = 1.0

	# Spark burst around player
	_burst_sparks(vit, pulse_color)


# Bake a two-stop gradient into an ImageTexture so the image exists on the
# CPU immediately — avoids the "p_image.is_null()" rendering-thread error
# that GradientTexture1D triggers on its first update frame.
func _bake_gradient(c0: Color, c1: Color, width: int = 32) -> ImageTexture:
	var img := Image.create(width, 1, false, Image.FORMAT_RGBA8)
	for x in range(width):
		img.set_pixel(x, 0, c0.lerp(c1, float(x) / float(width - 1)))
	return ImageTexture.create_from_image(img)


func _ensure_spark_ambient() -> void:
	if _spark_ambient != null:
		return

	# Tiny bright sphere for each spark particle
	var sm := SphereMesh.new()
	sm.radius          = 0.055
	sm.height          = 0.11
	sm.radial_segments = 4
	sm.rings           = 2

	# Unshaded alpha material — particle color passes through as raw glow
	var mmat := StandardMaterial3D.new()
	mmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmat.vertex_color_use_as_albedo = true
	mmat.albedo_color               = Color(1.0, 1.0, 1.0, 1.0)
	sm.surface_set_material(0, mmat)

	# Alpha fade: bright at birth, invisible at death
	var ramp := _bake_gradient(Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.0))

	# Continuous ambient process material — large sphere covers the whole visible sky
	var pmat := ParticleProcessMaterial.new()
	pmat.emission_shape         = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pmat.emission_sphere_radius = 26.0      # fills visible play area
	pmat.direction              = Vector3(0.0, 1.0, 0.0)
	pmat.spread                 = 180.0     # all directions
	pmat.gravity                = Vector3(0.0, -0.6, 0.0)   # very gentle fall
	pmat.initial_velocity_min   = 0.4
	pmat.initial_velocity_max   = 2.0       # slow peaceful drift by default
	pmat.angular_velocity_min   = -180.0
	pmat.angular_velocity_max   =  180.0
	pmat.scale_min              = 0.5
	pmat.scale_max              = 2.8       # variety in size keeps it interesting
	pmat.color                  = Color(1.0, 0.55, 0.85, 1.0)
	pmat.color_ramp             = ramp
	_spark_ambient_mat = pmat

	var pe := GPUParticles3D.new()
	pe.process_material = pmat
	pe.draw_pass_1      = sm
	pe.amount           = 320
	pe.lifetime         = 3.2
	pe.one_shot         = false    # always streaming
	pe.emitting         = true
	pe.explosiveness    = 0.0      # steady trickle, not a burst
	pe.randomness       = 0.5
	pe.amount_ratio     = 0.35     # start at moderate density
	world_fx_root.add_child(pe)
	_spark_ambient = pe


func _burst_sparks(vit: float, _col: Color) -> void:
	# Velocity spike on beat — sparks suddenly fly faster, calming back each frame
	if _spark_ambient_mat == null:
		return
	_spark_ambient_mat.initial_velocity_min = lerpf(2.0, 5.5, vit)
	_spark_ambient_mat.initial_velocity_max = lerpf(5.0, 16.0, vit)



# ── 3D Speed streaks ──────────────────────────────────────────────────────────
# Elongated particles that fly past the player in world space, attached to the
# player so they always surround them. Appear at x10 combo, full intensity x50.

func _ensure_speed_streaks() -> void:
	if _speed_streaks != null or player == null:
		return

	# BoxMesh approach — no RibbonTrailMesh / trail system.
	# Each particle IS an already-elongated streak: wide enough to see (X),
	# razor-thin (Y), and long in Z so it looks like a light-trail line from
	# the slightly-elevated rear camera.  No alignment fighting — DISABLED keeps
	# the box naturally axis-aligned so Z-length stays along the run direction.
	var sm := BoxMesh.new()
	sm.size = Vector3(0.055, 0.007, 1.6)   # wide-ish, paper-thin, long in Z

	var mmat := StandardMaterial3D.new()
	mmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmat.vertex_color_use_as_albedo = true
	mmat.albedo_color               = Color(1.0, 1.0, 1.0, 1.0)
	mmat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	sm.surface_set_material(0, mmat)

	# Color over particle lifetime: jacket colour on spawn → fades to transparent.
	var jc := GameConfig.jacket_color
	var ramp := _bake_gradient(Color(jc.r, jc.g, jc.b, 0.95), Color(jc.r * 0.3, jc.g * 0.3, jc.b * 0.3, 0.0))

	var pmat := ParticleProcessMaterial.new()
	# Tighter emission box — keeps streaks close to jacket centre so they look
	# like they burst out from inside the fabric rather than floating beside it.
	pmat.emission_shape       = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pmat.emission_box_extents = Vector3(0.17, 0.09, 0.01)
	# Shoot straight backward — box Z-axis is already along run direction.
	pmat.direction            = Vector3(0.0, 0.0, -1.0)
	pmat.spread               = 1.5   # nearly parallel, tiny variance for natural feel
	pmat.gravity              = Vector3.ZERO
	pmat.initial_velocity_min = 14.0
	pmat.initial_velocity_max = 20.0
	pmat.scale_min            = 1.0
	pmat.scale_max            = 1.0
	pmat.color                = Color(jc.r, jc.g, jc.b, 1.0)
	pmat.color_ramp           = ramp
	_speed_streaks_mat = pmat

	var pe := GPUParticles3D.new()
	pe.process_material  = pmat
	pe.draw_pass_1       = sm
	pe.amount            = 8
	pe.lifetime          = 0.38
	pe.trail_enabled     = false   # the box itself is the streak — no trail system
	pe.transform_align   = GPUParticles3D.TRANSFORM_ALIGN_DISABLED
	pe.one_shot          = false
	pe.emitting          = true
	pe.explosiveness     = 0.0
	pe.randomness        = 0.0
	pe.amount_ratio      = 0.0
	# Slightly higher (1.28 vs 1.05) to sit at jacket torso level.
	# Z = -0.06 puts the emitter at the back surface of the jacket (facing camera),
	# so streaks appear to burst out from inside the fabric.
	pe.position          = Vector3(0.0, 1.28, -0.06)
	player.add_child(pe)
	_speed_streaks = pe


func _update_speed_streaks() -> void:
	if _speed_streaks_mat == null or _speed_streaks == null:
		return
	# Fade in from combo x0, fully visible at x40
	var combo_t: float = clampf(float(_combo) / 40.0, 0.0, 1.0)
	_speed_streaks.amount_ratio = combo_t
	# Beat pulse: briefly boost velocity so streaks flare longer on each hit
	var vel_boost: float = _beat_phase * 8.0
	_speed_streaks_mat.initial_velocity_min = 20.0 + vel_boost
	_speed_streaks_mat.initial_velocity_max = 24.0 + vel_boost


# ── Footstep floor ripple ─────────────────────────────────────────────────────

func _check_footstep_ripple(delta: float) -> void:
	if player == null or not player.is_on_floor() or player.slide_timer > 0.0:
		_foot_prev_sin = 0.0   # reset so first step after landing is clean
		return

	# Mirror the player's run cycle frequency (3.2 Hz from BeatRunnerPlayer)
	_foot_cycle += delta * 3.2
	var s: float = sin(_foot_cycle * TAU)

	# Downward zero-crossing → right foot lands; upward → left foot lands
	if _foot_prev_sin > 0.15 and s <= 0.0:
		_emit_footstep_ripple(
			player.global_position + Vector3(0.28, 0.05, 0.0),
			Color(0.60, 0.08, 0.92))   # right foot — purple (_COL_EYE_R)
	elif _foot_prev_sin < -0.15 and s >= 0.0:
		_emit_footstep_ripple(
			player.global_position + Vector3(-0.28, 0.05, 0.0),
			Color(0.10, 0.55, 1.00))   # left foot  — blue  (_COL_EYE_L)
	_foot_prev_sin = s


func _emit_footstep_ripple(pos: Vector3, col: Color) -> void:
	# Small glow pulse at floor level — energy scales slightly with vitality
	var energy: float = lerpf(0.6, 1.4, _world_vitality)
	var fl := OmniLight3D.new()
	fl.light_color  = col
	fl.light_energy = energy
	fl.omni_range   = 3.0
	fl.position     = pos
	world_fx_root.add_child(fl)
	var tw := create_tween()
	tw.tween_property(fl, "light_energy", 0.0, 0.18)
	tw.tween_callback(fl.queue_free)


func _update_gate_visibility() -> void:
	if player == null:
		return

	var beat_s: float   = max(0.20, _runner_avg_beat_s)
	var ahead_z: float  = max(min_gate_preview_distance, gate_preview_beats * beat_s * player.forward_speed)
	var behind_z: float = max(6.0, gate_keep_behind_beats * beat_s * player.forward_speed)

	var player_z: float = _player_path_dist   # path distance, not world Z

	# Advance lower-bound cursor past permanently-hidden/culled gates
	while _vis_start_idx < gate_nodes.size():
		var g: Node3D = gate_nodes[_vis_start_idx]
		if g != null and g.process_mode != Node.PROCESS_MODE_DISABLED \
				and gate_world_zs[_vis_start_idx] >= player_z - behind_z - 2.0:
			break
		_vis_start_idx += 1

	for i in range(_vis_start_idx, gate_nodes.size()):
		var gate: Node3D = gate_nodes[i]
		if gate == null:
			continue

		var dz: float = gate_world_zs[i] - player_z

		# Gates are Z-sorted — once we're too far ahead, stop
		if dz > ahead_z + 10.0:
			break

		# Culled gates are permanently hidden — never re-show them.
		if gate.process_mode == Node.PROCESS_MODE_DISABLED:
			continue

		var should_show: bool = (dz >= -behind_z and dz <= ahead_z)

		# First-time appearance: direction tied to gate type
		# jump → always from below, slide → always from above, others → cycle left/right
		if should_show and not gate.visible and not _gate_animated[i]:
			_gate_animated[i] = true
			var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
			if vis != null:
				var gate_action: String = String(runner_plan[i].get("action", ""))
				var atw := create_tween()
				atw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
				match gate_action:
					"jump":  # always rise from below
						vis.scale = Vector3(1.0, 0.0, 1.0)
						atw.tween_property(vis, "scale:y", 1.0, 0.22)
					"slide":  # always drop from above
						vis.position.y = 3.5
						atw.tween_property(vis, "position:y", 0.0, 0.22)
					_:  # left / right / wall — cycle left and right sides
						if i % 2 == 0:
							vis.position.x = -4.0
						else:
							vis.position.x = 4.0
						atw.tween_property(vis, "position:x", 0.0, 0.22)

		# Electric zones: pause/resume arc tweens with gate visibility so they
		# don't burn CPU on gates hundreds of metres from the player.
		var gate_t_s: float = float(runner_plan[i].get("t", 0.0))
		if _is_electric_at(gate_t_s):
			var ev := gate.get_node_or_null("VisRoot") as Node3D
			if ev != null:
				ev.process_mode = Node.PROCESS_MODE_INHERIT if should_show \
					else Node.PROCESS_MODE_DISABLED
		gate.visible = should_show


func _sort_event_by_t(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("t", 0.0)) < float(b.get("t", 0.0))

func _estimate_runner_avg_beat_s(beat_events: Array[Dictionary]) -> float:
	if beat_events.size() < 2:
		return 0.5

	var sum_dt: float = 0.0
	var count: int = 0
	for i in range(1, beat_events.size()):
		var t0: float = float(beat_events[i - 1].get("t", 0.0))
		var t1: float = float(beat_events[i].get("t", 0.0))
		var dt: float = t1 - t0
		if dt > 0.05 and dt < 2.0:
			sum_dt += dt
			count += 1

	if count <= 0:
		return 0.5

	return sum_dt / float(count)


func _on_music_finished() -> void:
	if _song_finish_pending:
		return

	_song_finish_pending = true

	# Stop forward movement so the player doesn't run off the end of the
	# generated track floor during the celebration animation.
	player.forward_speed = 0.0
	player.velocity      = Vector3.ZERO

	# Plenty of time for the celebration to breathe
	auto_quit_delay_s = 6.0

	_spawn_finish_lasers()
	_spawn_finish_confetti()
	_spawn_finish_orb_burst()

	# Screen flashes — rapid strobes at the start, then one final pulse
	var flash_times: Array[float] = [0.05, 0.20, 0.38, 0.58, 0.82, 1.10]
	var flash_cols: Array[Color] = [
		Color(1.0, 1.0, 1.0, 0.80),
		Color(1.0, 0.45, 0.85, 0.55),
		Color(0.40, 0.85, 1.00, 0.50),
		Color(1.0, 0.90, 0.30, 0.50),
		Color(0.80, 0.40, 1.00, 0.45),
		Color(1.0, 1.0, 1.0, 0.35),
	]
	for i in flash_times.size():
		var ft: float = flash_times[i]
		var fc: Color = flash_cols[i]
		var fct := get_tree().create_timer(ft)
		fct.timeout.connect(func() -> void:
			_hud_flash_color(fc, 0.28)
		)

	# Character celebration: rapid-fire jumps and slides — feels energetic
	var celebrate_acts: Array = [
		[0.10, "jump"], [0.33, "jump"], [0.57, "slide"],
		[0.80, "jump"], [1.00, "jump"], [1.20, "jump"],
		[1.40, "slide"],[1.63, "jump"], [1.83, "jump"],
		[2.03, "slide"],[2.23, "jump"], [2.43, "jump"],
		[2.63, "slide"],[2.87, "jump"], [3.10, "jump"],
	]
	for pair in celebrate_acts:
		var delay: float  = pair[0] as float
		var act:   String = pair[1] as String
		var ct := get_tree().create_timer(delay)
		ct.timeout.connect(func() -> void:
			player.request_action(act)
		)

	# Reset song lives for next attempt (they earned a clean slate by clearing)
	Run.song_lives = 3

	# Results panel slides in after the CLEAR! animation settles
	var panel_timer := get_tree().create_timer(1.30)
	panel_timer.timeout.connect(func() -> void:
		_spawn_results_panel()
	)


func _spawn_finish_lasers() -> void:
	var tw: float = _track_full_width()

	# Six lateral offsets from track centre — tight inner pair + wider mid + extreme outer
	var inner: float = tw * 0.5 + 3.0
	var mid:   float = tw * 0.5 + 6.5
	var outer: float = tw * 0.5 + 11.0
	var beam_lats: Array[float] = [
		-outer, -mid, -inner,
		 inner,  mid,  outer,
	]

	# Ten path-distance offsets ahead of player
	var beam_pd_offsets: Array[float] = [
		0.0, 5.0, 10.0, 16.0, 22.0,
		29.0, 37.0, 45.0, 54.0, 64.0,
	]

	var beam_colors: Array[Color] = [
		Color(1.00, 0.25, 0.60, 1.0),  # hot pink
		Color(0.65, 0.10, 1.00, 1.0),  # deep violet
		Color(0.20, 0.80, 1.00, 1.0),  # electric cyan
		Color(1.00, 0.85, 0.10, 1.0),  # gold
		Color(0.30, 1.00, 0.55, 1.0),  # neon mint
		Color(1.00, 0.45, 0.10, 1.0),  # blazing orange
		Color(0.90, 0.25, 1.00, 1.0),  # magenta
		Color(0.55, 1.00, 0.20, 1.0),  # lime
	]

	var beam_height: float = 80.0
	var beam_w:      float = 0.18
	var idx:         int   = 0

	for blat in beam_lats:
		for bpd_off in beam_pd_offsets:
			var col:   Color = beam_colors[idx % beam_colors.size()]
			# Stagger arrival — inner columns pop first, outer ones a beat later
			var delay: float = float(idx % beam_pd_offsets.size()) * 0.055 + float(idx) / float(beam_pd_offsets.size()) * 0.15

			# Tall glowing column — shoots up from the ground
			var beam: MeshInstance3D = _make_box_mesh(
				Vector3(beam_w, beam_height, beam_w), col)
			var bw: Vector3 = _path_world_pos(_player_path_dist + bpd_off, blat, beam_height * 0.5)
			beam.position = bw
			beam.scale.y  = 0.0
			var bmat: StandardMaterial3D = beam.material_override as StandardMaterial3D
			if bmat != null:
				bmat.emission_energy_multiplier = 18.0
			world_fx_root.add_child(beam)

			# Rise fast, then pulse emission energy to make it feel alive, then fall
			var hold_t: float = auto_quit_delay_s - delay - 1.0
			var btw := create_tween()
			btw.tween_interval(delay)
			btw.tween_property(beam, "scale:y", 1.0, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			# Pulse the glow a few times during the hold
			if bmat != null:
				btw.tween_property(bmat, "emission_energy_multiplier", 28.0, 0.18)
				btw.tween_property(bmat, "emission_energy_multiplier", 14.0, 0.25)
				btw.tween_property(bmat, "emission_energy_multiplier", 24.0, 0.18)
				btw.tween_property(bmat, "emission_energy_multiplier", 14.0, hold_t - 0.65)
			else:
				btw.tween_interval(hold_t)
			btw.tween_property(beam, "scale:y", 0.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			btw.tween_callback(beam.queue_free)

			# Wide-range point light — flares on rise then settles
			var bl := OmniLight3D.new()
			bl.light_color  = col
			bl.light_energy = 0.0
			bl.omni_range   = 28.0
			bl.position     = _path_world_pos(_player_path_dist + bpd_off, blat, 1.5)
			world_fx_root.add_child(bl)

			var ltw := create_tween()
			ltw.tween_interval(delay)
			ltw.tween_property(bl, "light_energy", 14.0, 0.10)
			ltw.tween_property(bl, "light_energy",  4.0, 0.30)
			ltw.tween_interval(maxf(0.2, hold_t - 0.40))
			ltw.tween_property(bl, "light_energy",  0.0, 0.35)
			ltw.tween_callback(bl.queue_free)

			idx += 1

	# Spinning diagonal sweep beams — one from each side
	for side in [-1, 1]:
		for wave in range(3):
			var sdelay: float = 0.30 + float(wave) * 1.80
			var sweep_pivot := Node3D.new()
			sweep_pivot.position = _path_world_pos(_player_path_dist + 8.0 + float(wave) * 12.0, float(side) * (tw * 0.5 + 1.0), 0.5)
			world_fx_root.add_child(sweep_pivot)

			var sweep: MeshInstance3D = _make_box_mesh(Vector3(0.12, 45.0, 0.12),
				beam_colors[(wave * 2 + (side + 1) / 2) % beam_colors.size()])
			sweep.position = Vector3(0.0, 22.5, 0.0)
			var smat: StandardMaterial3D = sweep.material_override as StandardMaterial3D
			if smat != null:
				smat.emission_energy_multiplier = 20.0
			sweep_pivot.add_child(sweep)

			var stw := create_tween()
			stw.tween_interval(sdelay)
			stw.tween_property(sweep_pivot, "rotation:z",
				float(side) * TAU * 1.5, 2.40).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			stw.tween_callback(sweep_pivot.queue_free)

	# ── HUD "CLEAR!" overlay ─────────────────────────────────────────────────
	if _hud_flash == null:
		return

	var cl: CanvasLayer = _hud_flash.get_parent().get_parent() as CanvasLayer
	if cl == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return

	# "CLEAR!" label — slams in from huge scale, then pulses
	var clear_label := Label.new()
	clear_label.text = "CLEAR!"
	clear_label.anchor_left   = 0.5; clear_label.anchor_right  = 0.5
	clear_label.anchor_top    = 0.5; clear_label.anchor_bottom = 0.5
	clear_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	clear_label.grow_vertical   = Control.GROW_DIRECTION_BOTH
	clear_label.offset_left   = -320; clear_label.offset_right  = 320
	clear_label.offset_top    = -80;  clear_label.offset_bottom = 80
	clear_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clear_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	clear_label.add_theme_color_override("font_color", Color(1.00, 0.95, 0.30, 1.0))
	clear_label.add_theme_font_size_override("font_size", 96)
	clear_label.scale   = Vector2(3.2, 3.2)
	clear_label.modulate.a = 0.0
	clear_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(clear_label)

	# CLEAR! slams in — big → normal with a bounce, then colour pulses, then fades as results panel arrives
	var ctw := create_tween()
	ctw.parallel().tween_property(clear_label, "scale", Vector2(1.0, 1.0), 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	ctw.parallel().tween_property(clear_label, "modulate:a", 1.0, 0.18)
	ctw.tween_interval(0.30)
	# Colour-shift pulses: gold → white → pink → gold
	ctw.tween_interval(0.55)
	ctw.tween_property(clear_label, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.15)
	ctw.tween_property(clear_label, "modulate", Color(1.0, 0.45, 0.85, 1.0), 0.15)
	ctw.tween_property(clear_label, "modulate", Color(1.0, 0.95, 0.30, 1.0), 0.15)
	ctw.tween_property(clear_label, "scale", Vector2(1.10, 1.10), 0.10)
	ctw.tween_property(clear_label, "scale", Vector2(1.00, 1.00), 0.12)
	# Fade out as the results panel slides in
	ctw.tween_interval(0.30)
	ctw.parallel().tween_property(clear_label, "modulate:a", 0.0, 0.40)


# Shoots ~120 2-D confetti pieces across the HUD CanvasLayer.
func _spawn_finish_confetti() -> void:
	if _hud_flash == null:
		return
	var root: Control = _hud_flash.get_parent() as Control
	if root == null:
		return

	var palette: Array[Color] = [
		Color(1.00, 0.25, 0.55, 1.0),  # pink
		Color(1.00, 0.85, 0.10, 1.0),  # gold
		Color(0.20, 0.80, 1.00, 1.0),  # cyan
		Color(0.55, 0.22, 1.00, 1.0),  # purple
		Color(0.30, 1.00, 0.45, 1.0),  # mint
		Color(1.00, 0.50, 0.10, 1.0),  # orange
		Color(0.95, 0.95, 1.00, 1.0),  # white
		Color(0.85, 1.00, 0.25, 1.0),  # lime
	]

	var vp_w: float = float(get_viewport().get_visible_rect().size.x)
	var vp_h: float = float(get_viewport().get_visible_rect().size.y)

	# Three waves: burst at 0 s, 0.45 s, 0.90 s
	for wave in range(3):
		var wave_delay: float = float(wave) * 0.45
		var count: int = 40 + wave * 10

		for i in count:
			# Random start: top edge or left/right edge, spread more naturally
			var edge: int = randi() % 3   # 0=top, 1=left, 2=right
			var start_x: float
			var start_y: float
			match edge:
				0:
					start_x = randf_range(0.0, vp_w)
					start_y = randf_range(-40.0, -5.0)
				1:
					start_x = randf_range(-30.0, -5.0)
					start_y = randf_range(0.0, vp_h * 0.6)
				_:
					start_x = randf_range(vp_w + 5.0, vp_w + 30.0)
					start_y = randf_range(0.0, vp_h * 0.6)

			var w:   float = randf_range(6.0,  14.0)
			var h:   float = randf_range(8.0,  20.0)
			var col: Color = palette[randi() % palette.size()]

			var piece := ColorRect.new()
			piece.color       = col
			piece.size        = Vector2(w, h)
			piece.position    = Vector2(start_x, start_y)
			piece.rotation    = randf_range(0.0, TAU)
			piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(piece)

			# Each piece flies across the screen with rotation and gentle arc
			var fall_x:  float = start_x + randf_range(-120.0, 120.0)
			var fall_y:  float = start_y + randf_range(vp_h * 0.7, vp_h * 1.3)
			var spin:    float = randf_range(-TAU * 2.0, TAU * 2.0)
			var dur:     float = randf_range(1.6, 3.2)
			var piece_delay: float = wave_delay + float(i) * 0.018

			var ptw := create_tween()
			ptw.tween_interval(piece_delay)
			ptw.parallel().tween_property(piece, "position:x", fall_x, dur).set_trans(Tween.TRANS_SINE)
			ptw.parallel().tween_property(piece, "position:y", fall_y, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			ptw.parallel().tween_property(piece, "rotation",   piece.rotation + spin, dur)
			ptw.parallel().tween_property(piece, "modulate:a", 0.0, dur * 0.4).set_delay(dur * 0.6)
			ptw.tween_callback(piece.queue_free)


# 3-D orb burst from the player — coloured diamonds fly outward like fireworks.
func _spawn_finish_orb_burst() -> void:
	var origin: Vector3 = player.global_position + Vector3(0.0, 1.2, 0.0)

	var orb_colors: Array[Color] = [
		Color(1.00, 0.25, 0.60, 1.0),
		Color(1.00, 0.85, 0.10, 1.0),
		Color(0.20, 0.80, 1.00, 1.0),
		Color(0.65, 0.10, 1.00, 1.0),
		Color(0.30, 1.00, 0.45, 1.0),
		Color(1.00, 0.45, 0.10, 1.0),
		Color(0.90, 1.00, 0.20, 1.0),
		Color(0.95, 0.50, 1.00, 1.0),
	]

	# Three waves of orbs — first is tight, later waves spread wider
	for wave in range(3):
		var wave_delay: float = float(wave) * 0.55
		var orb_count: int = 18 + wave * 6
		var speed_mul: float = 1.0 + float(wave) * 0.6

		for i in orb_count:
			var angle_h: float = float(i) / float(orb_count) * TAU
			var angle_v: float = randf_range(0.1, PI * 0.75)
			var spd:     float = randf_range(5.0, 12.0) * speed_mul
			var dir := Vector3(
				sin(angle_v) * cos(angle_h),
				cos(angle_v),
				sin(angle_v) * sin(angle_h)
			)
			var col: Color = orb_colors[i % orb_colors.size()]

			var orb_sz: float = randf_range(0.12, 0.32)
			var orb: MeshInstance3D = _make_box_mesh(Vector3(orb_sz, orb_sz, orb_sz), col)
			orb.position = origin
			orb.rotation = Vector3(randf_range(0, TAU),
								   randf_range(0, TAU),
								   randf_range(0, TAU))
			var omat: StandardMaterial3D = orb.material_override as StandardMaterial3D
			if omat != null:
				omat.emission_energy_multiplier = 22.0
			world_fx_root.add_child(orb)

			var end_pos: Vector3 = origin + dir * spd
			var dur: float = randf_range(0.8, 1.6)

			var otw := create_tween()
			otw.tween_interval(wave_delay)
			otw.parallel().tween_property(orb, "global_position", end_pos, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			otw.parallel().tween_property(orb, "scale", Vector3(0.05, 0.05, 0.05), dur * 0.7).set_delay(dur * 0.3)
			otw.parallel().tween_property(orb, "rotation:y", orb.rotation.y + TAU * 2.0, dur)
			otw.tween_callback(orb.queue_free)

# ── End-screen results panel ─────────────────────────────────────────────────
func _spawn_results_panel() -> void:
	if _hud_flash == null:
		return
	var hud_root: Control = _hud_flash.get_parent() as Control
	if hud_root == null:
		return

	# ── Perfect-run bonus: ×1.5 on score when zero misses ─────────────────────
	var is_perfect: bool = (_gates_hit > 0 and _gates_missed == 0)
	if is_perfect:
		_score = int(float(_score) * 1.5)

	# Save high score and find out if it's a new record
	var is_new_hs: bool = Save.save_high_score(Run.current_song_key, _score, _max_combo)
	var hs: Dictionary = Save.get_high_score(Run.current_song_key)

	# ── Full-screen dark backdrop ─────────────────────────────────────────────
	var overlay := ColorRect.new()
	overlay.color = Color(0.00, 0.00, 0.04, 0.92)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.modulate.a   = 0.0
	hud_root.add_child(overlay)

	# ── Full-screen card ──────────────────────────────────────────────────────
	var card := PanelContainer.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)   # transparent — overlay provides bg
	card_style.content_margin_left   = 80.0; card_style.content_margin_right  = 80.0
	card_style.content_margin_top    = 48.0; card_style.content_margin_bottom = 48.0
	card.add_theme_stylebox_override("panel", card_style)
	card.modulate.a = 0.0
	hud_root.add_child(card)

	# CenterContainer fills the card and vertically centres its child
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	vbox.custom_minimum_size = Vector2(680.0, 0.0)
	center.add_child(vbox)

	# ── PERFECT! badge (top, above score) ─────────────────────────────────────
	if is_perfect:
		var perf_lbl := Label.new()
		perf_lbl.text = "✦  PERFECT  ✦"
		perf_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		perf_lbl.add_theme_font_size_override("font_size", 28)
		perf_lbl.add_theme_color_override("font_color", Color(0.40, 1.00, 0.60))
		perf_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(perf_lbl)
		var ptw := create_tween().set_loops()
		ptw.tween_property(perf_lbl, "modulate", Color(1.2, 1.2, 1.0), 0.70)
		ptw.tween_property(perf_lbl, "modulate", Color(1.0, 1.0, 1.0), 0.70)

	# ── Score ─────────────────────────────────────────────────────────────────
	var score_val := Label.new()
	score_val.text = "%d" % _score
	score_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_val.add_theme_font_size_override("font_size", 96)
	score_val.add_theme_color_override("font_color", Color(1.00, 0.95, 0.30))
	score_val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(score_val)

	var score_cap := Label.new()
	if is_perfect:
		score_cap.text = "SCORE  ( ×1.5 PERFECT BONUS APPLIED )"
	else:
		score_cap.text = "SCORE"
	score_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_cap.add_theme_font_size_override("font_size", 14)
	score_cap.add_theme_color_override("font_color",
		Color(0.35, 0.90, 0.55) if is_perfect else Color(0.55, 0.50, 0.72))
	score_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(score_cap)

	# ── Letter grade ─────────────────────────────────────────────────────────
	var total_for_grade: int = _gates_hit + _gates_missed
	var acc: float = float(_gates_hit) / float(max(1, total_for_grade))
	var grade: String
	var grade_col: Color
	if _gates_missed == 0 and _gates_hit > 0:
		grade = "S";  grade_col = Color(1.00, 0.88, 0.20)   # gold
	elif acc >= 0.90:
		grade = "A";  grade_col = Color(0.30, 0.90, 1.00)   # cyan
	elif acc >= 0.75:
		grade = "B";  grade_col = Color(0.35, 1.00, 0.50)   # green
	elif acc >= 0.60:
		grade = "C";  grade_col = Color(1.00, 0.85, 0.25)   # yellow
	elif acc >= 0.40:
		grade = "D";  grade_col = Color(1.00, 0.55, 0.20)   # orange
	else:
		grade = "F";  grade_col = Color(1.00, 0.30, 0.30)   # red

	var grade_lbl := Label.new()
	grade_lbl.text = grade
	grade_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grade_lbl.add_theme_font_size_override("font_size", 86)
	grade_lbl.add_theme_color_override("font_color", grade_col)
	grade_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(grade_lbl)
	if grade == "S":
		var gtw := create_tween().set_loops()
		gtw.tween_property(grade_lbl, "modulate", Color(1.4, 1.3, 0.6), 0.60)
		gtw.tween_property(grade_lbl, "modulate", Color(1.0, 1.0, 1.0), 0.60)

	var acc_lbl := Label.new()
	acc_lbl.text = "%.1f%%" % (acc * 100.0)
	acc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	acc_lbl.add_theme_font_size_override("font_size", 15)
	acc_lbl.add_theme_color_override("font_color", grade_col.darkened(0.18))
	acc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(acc_lbl)

	# ── New high score badge ───────────────────────────────────────────────────
	if is_new_hs:
		var hs_lbl := Label.new()
		hs_lbl.text = "★  NEW HIGH SCORE  ★"
		hs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hs_lbl.add_theme_font_size_override("font_size", 22)
		hs_lbl.add_theme_color_override("font_color", Color(1.00, 0.38, 0.68))
		hs_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(hs_lbl)
		var htw := create_tween().set_loops()
		htw.tween_property(hs_lbl, "modulate", Color(1.3, 0.9, 1.3), 0.55)
		htw.tween_property(hs_lbl, "modulate", Color(1.0, 1.0, 1.0), 0.55)
	else:
		var prev_lbl := Label.new()
		prev_lbl.text = "Best: %d" % hs.score
		prev_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prev_lbl.add_theme_font_size_override("font_size", 15)
		prev_lbl.add_theme_color_override("font_color", Color(0.52, 0.48, 0.68))
		prev_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(prev_lbl)

	# ── Separator ─────────────────────────────────────────────────────────────
	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("separator_color", Color(0.35, 0.14, 0.58, 0.55))
	vbox.add_child(sep1)

	# ── Combo stats row ───────────────────────────────────────────────────────
	var combo_row := HBoxContainer.new()
	combo_row.alignment = BoxContainer.ALIGNMENT_CENTER
	combo_row.add_theme_constant_override("separation", 80)
	vbox.add_child(combo_row)

	for pair in [["BEST COMBO", str(_max_combo)], ["LAST COMBO", str(_combo)]]:
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var val_lbl := Label.new()
		val_lbl.text = pair[1]
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val_lbl.add_theme_font_size_override("font_size", 52)
		val_lbl.add_theme_color_override("font_color", Color(0.45, 0.85, 1.00))
		val_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var key_lbl := Label.new()
		key_lbl.text = pair[0]
		key_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_lbl.add_theme_font_size_override("font_size", 14)
		key_lbl.add_theme_color_override("font_color", Color(0.50, 0.46, 0.68))
		key_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(val_lbl)
		col.add_child(key_lbl)
		combo_row.add_child(col)

	# ── Notes stats row ───────────────────────────────────────────────────────
	var total_notes: int = _gates_hit + _gates_missed
	var notes_lbl := Label.new()
	notes_lbl.text = "%d hit  /  %d missed  /  %d total" % [_gates_hit, _gates_missed, total_notes]
	notes_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notes_lbl.add_theme_font_size_override("font_size", 20)
	var hit_col: Color
	if total_notes == 0 or _gates_missed == 0:
		hit_col = Color(0.30, 1.00, 0.50)
	elif float(_gates_hit) / float(total_notes) >= 0.90:
		hit_col = Color(0.65, 1.00, 0.35)
	elif float(_gates_hit) / float(total_notes) >= 0.70:
		hit_col = Color(1.00, 0.85, 0.25)
	else:
		hit_col = Color(1.00, 0.45, 0.35)
	notes_lbl.add_theme_color_override("font_color", hit_col)
	notes_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(notes_lbl)

	# ── Separator ─────────────────────────────────────────────────────────────
	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("separator_color", Color(0.35, 0.14, 0.58, 0.55))
	vbox.add_child(sep2)

	# ── Navigation buttons ────────────────────────────────────────────────────
	var nav_row := HBoxContainer.new()
	nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	nav_row.add_theme_constant_override("separation", 32)
	vbox.add_child(nav_row)

	_end_lbl_again  = _make_end_nav_label("▶  PLAY AGAIN")
	_end_lbl_select = _make_end_nav_label("◀  SONG SELECT")
	nav_row.add_child(_end_lbl_again)
	nav_row.add_child(_end_lbl_select)

	# ── Control hint ──────────────────────────────────────────────────────────
	var hint := Label.new()
	hint.text = "◀▶ / D-pad choose   ·   A / Enter confirm"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.40, 0.38, 0.58))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint)

	# ── Fade in (full-screen, no slide) ──────────────────────────────────────
	var itw := create_tween()
	itw.parallel().tween_property(overlay, "modulate:a", 1.0, 0.40)
	itw.parallel().tween_property(card, "modulate:a", 1.0, 0.40)
	itw.tween_callback(func() -> void:
		player.input_disabled = true
		_end_screen_sel = 0
		_end_update_nav_highlight()
		_end_screen_active = true
	)


func _make_end_nav_label(txt: String) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Styled like a pill button via theme stylebox
	var sb := StyleBoxFlat.new()
	sb.bg_color     = Color(0.10, 0.08, 0.18, 1.0)
	sb.border_color = Color(0.40, 0.18, 0.65, 1.0)
	sb.border_width_left   = 2; sb.border_width_right  = 2
	sb.border_width_top    = 2; sb.border_width_bottom = 2
	sb.corner_radius_top_left     = 8; sb.corner_radius_top_right    = 8
	sb.corner_radius_bottom_left  = 8; sb.corner_radius_bottom_right = 8
	sb.content_margin_left   = 22.0; sb.content_margin_right  = 22.0
	sb.content_margin_top    = 10.0; sb.content_margin_bottom = 10.0
	lbl.add_theme_stylebox_override("normal", sb)
	lbl.add_theme_color_override("font_color", Color(0.65, 0.58, 0.82))
	return lbl


func _end_update_nav_highlight() -> void:
	var active_col:   Color = Color(1.00, 0.42, 0.72, 1.0)
	var inactive_col: Color = Color(0.58, 0.52, 0.76, 1.0)
	var active_bg:   Color = Color(0.44, 0.10, 0.70, 1.0)
	var active_bdr:  Color = Color(0.80, 0.38, 1.00, 1.0)
	var inactive_bg:  Color = Color(0.10, 0.08, 0.18, 1.0)
	var inactive_bdr: Color = Color(0.40, 0.18, 0.65, 1.0)

	var labels: Array = [_end_lbl_again, _end_lbl_select]
	for i in labels.size():
		var lbl: Label = labels[i] as Label
		if lbl == null:
			continue
		var active: bool = (i == _end_screen_sel)
		lbl.add_theme_color_override("font_color", active_col if active else inactive_col)
		var sb := StyleBoxFlat.new()
		sb.bg_color     = active_bg  if active else inactive_bg
		sb.border_color = active_bdr if active else inactive_bdr
		sb.border_width_left   = 2; sb.border_width_right  = 2
		sb.border_width_top    = 2; sb.border_width_bottom = 2
		sb.corner_radius_top_left     = 8; sb.corner_radius_top_right    = 8
		sb.corner_radius_bottom_left  = 8; sb.corner_radius_bottom_right = 8
		sb.content_margin_left   = 22.0; sb.content_margin_right  = 22.0
		sb.content_margin_top    = 10.0; sb.content_margin_bottom = 10.0
		lbl.add_theme_stylebox_override("normal", sb)


func _end_confirm() -> void:
	_end_screen_active = false
	match _end_screen_sel:
		0:  # Play Again — relaunch with the same song key and mode
			get_tree().change_scene_to_file("res://scenes/GameScene.tscn")
		1:  # Song Select
			Run.run_seed   = 0
			Run.song_lives = 3
			get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")


# Record where the floor void begins.  The scene's single flat floor is hidden
# in _ready; _spawn_path_floors() uses this value to clip segment floor length.
func _resize_floor_to(floor_end_z: float) -> void:
	if floor_end_z > 0.0:
		_floor_cutoff_dist = floor_end_z


func _prepare_floor_material() -> void:
	if floor_mesh == null:
		return

	var existing: Material = floor_mesh.get_active_material(0)
	if existing is StandardMaterial3D:
		_floor_material = (existing as StandardMaterial3D).duplicate(true)
	else:
		_floor_material = StandardMaterial3D.new()

	# Always stamp our desired base colour — do NOT read back from the material,
	# because the scene's existing material might be dark and would overwrite _floor_base_albedo.
	_floor_material.albedo_color = _floor_base_albedo

	_floor_material.emission_enabled = true
	_floor_material.emission = Color(0.0, 0.0, 0.0, 1.0)
	_floor_material.emission_energy_multiplier = 0.0

	floor_mesh.set_surface_override_material(0, _floor_material)

func _smooth01(x: float) -> float:
	var y: float = clampf(x, 0.0, 1.0)
	return y * y * (3.0 - 2.0 * y)

func _current_cycle_color(song_t: float) -> Color:
	if not color_cycle_enabled:
		return cycle_color_a

	var period: float = max(6.0, color_cycle_period_s)
	var u: float = fposmod(song_t / period, 1.0) * 4.0
	var seg: int = int(floor(u))
	var t: float = _smooth01(u - float(seg))

	match seg:
		0:
			return cycle_color_a.lerp(cycle_color_b, t)
		1:
			return cycle_color_b.lerp(cycle_color_c, t)
		2:
			return cycle_color_c.lerp(cycle_color_d, t)
		_:
			return cycle_color_d.lerp(cycle_color_a, t)

func _spawn_track_decorations() -> void:
	var tw:      float = _track_full_width()
	var end_z:   float = _song_end_z()
	var end_path: float = end_z   # same numerical value — path distance to song end

	var gem_colors: Array[Color] = [
		Color(1.00, 0.35, 0.65, 1.0),   # pink
		Color(0.35, 0.78, 1.00, 1.0),   # blue
		Color(0.80, 0.35, 1.00, 1.0),   # purple
		Color(1.00, 0.85, 0.20, 1.0),   # gold
		Color(0.35, 1.00, 0.65, 1.0),   # mint
		Color(1.00, 0.55, 0.22, 1.0),   # orange
	]

	# ── 1. Continuous side-wall glow strips (per path segment) ──────────────────
	var strip_thick: float = 0.06
	var strip_h:     float = 1.0
	var strip_cx:    float = tw * 0.5 + strip_thick * 0.5 + 0.02

	# ── 2. Floor-edge glow rails (per path segment) ───────────────────────────
	var rail_y:  float = 0.02
	var rail_cx: float = tw * 0.5 - 0.10

	# Margin clipped from each end of every segment so the strips don't stick out
	# perpendicular to the player at 90° corners.
	const CORNER_MARGIN: float = 10.0

	for seg_var in _track_segs:
		var seg: TrackSeg = seg_var as TrackSeg
		var seg_clip_end: float = minf(seg.path_end(), end_path)
		# Arc sub-segments are ~2.8° apart — negligible visual overlap, no margin needed.
		# Straight segments still clip 10 m each end to avoid poking out at 90° junctions.
		var eff_margin: float = 0.0 if seg.length < 3.0 else CORNER_MARGIN
		var clip_start: float = seg.path_start + eff_margin
		var clip_end:   float = seg_clip_end   - eff_margin
		if clip_end <= clip_start:
			continue   # segment too short to show strips
		var clip_len: float   = clip_end - clip_start
		var clip_mid: float   = (clip_start + clip_end) * 0.5
		var seg_y_rot: float  = rad_to_deg(atan2(seg.direction.x, seg.direction.z))
		# Centre-point of the clipped strip along the path centre-line
		var strip_ctr: Vector3 = seg.origin + seg.direction * (clip_mid - seg.path_start)

		for side in [-1, 1]:
			for row in [0, 1]:   # low strip (~0.3 m) and high strip (~2.5 m)
				var sy: float = 0.30 + float(row) * 2.2
				var strip: MeshInstance3D = _make_box_mesh(
					Vector3(strip_thick, strip_h, clip_len),
					gem_colors[(row * 2) % gem_colors.size()])
				strip.position = strip_ctr + seg.right * (float(side) * strip_cx) + Vector3(0.0, sy, 0.0)
				strip.rotation_degrees.y = seg_y_rot
				var smat: StandardMaterial3D = strip.material_override as StandardMaterial3D
				if smat != null:
					smat.emission_energy_multiplier = 0.22
					_world_strip_mats.append(smat)
				world_fx_root.add_child(strip)

		for side in [-1, 1]:
			var rail: MeshInstance3D = _make_box_mesh(
				Vector3(0.06, 0.06, clip_len), Color(0.96, 0.0, 0.016, 1.0))
			rail.position = strip_ctr + seg.right * (float(side) * rail_cx) + Vector3(0.0, rail_y, 0.0)
			rail.rotation_degrees.y = seg_y_rot
			var rmat: StandardMaterial3D = rail.material_override as StandardMaterial3D
			if rmat != null:
				rmat.emission_energy_multiplier = 0.8
				_world_rail_mats.append(rmat)
			world_fx_root.add_child(rail)

	# ── 3. Gem + arch loop ────────────────────────────────────────────────────
	# Wider spacing = fewer nodes and looping tweens for the whole track.
	# Authored Blender pieces (gem / deco_arch / pad / haze_pillar) replace the
	# matching procedural meshes; spins, lights and beat pulsing stay identical.
	var gem_entry:     Dictionary = (_piece_lib.first_of("gem")         if _piece_lib != null else {})
	var darch_entry:   Dictionary = (_piece_lib.first_of("deco_arch")   if _piece_lib != null else {})
	var pad_entry:     Dictionary = (_piece_lib.first_of("pad")         if _piece_lib != null else {})
	var hpillar_entry: Dictionary = (_piece_lib.first_of("haze_pillar") if _piece_lib != null else {})

	var gem_spacing:  float = 32.0
	var arch_spacing: float = 64.0
	var z:   float = gem_spacing
	var gem_i: int = 0

	while z < end_path - 5.0:
		var col: Color = gem_colors[gem_i % gem_colors.size()]
		var z_y_rot: float = _path_y_rot_at(z)

		# Spinning diamond gem on each side — spin tween only (no bob)
		for side in [-1, 1]:
			var gem_root := Node3D.new()
			gem_root.position = _path_world_pos(z, float(side) * (tw * 0.5 + 1.4), 1.7)
			world_fx_root.add_child(gem_root)

			if not gem_entry.is_empty():
				var g_inst: Node3D = _piece_lib.instance(gem_entry)
				g_inst.rotation_degrees.y = 180.0
				gem_root.add_child(g_inst)
			else:
				var gem: MeshInstance3D = _make_box_mesh(Vector3(0.40, 0.40, 0.40), col)
				gem.rotation_degrees = Vector3(35.0, 0.0, 35.0)
				gem_root.add_child(gem)

			# Authored gems with their own animation spin themselves —
			# the procedural whole-gem spin would double up on top of it.
			if not bool(gem_entry.get("animated", false)):
				var spin := create_tween().set_loops()
				spin.tween_property(gem_root, "rotation_degrees:y", 360.0,
					2.8 + float(gem_i % 3) * 0.5).from(0.0)

			# One shared light per pair of gems (placed at centre, not per gem)
			if side == 1:
				var glight := OmniLight3D.new()
				glight.light_color  = col
				glight.light_energy = 0.35
				glight.omni_range   = 6.0
				glight.position     = _path_world_pos(z, 0.0, gem_root.position.y + 0.2)
				world_fx_root.add_child(glight)
				_world_gem_lights.append(glight)

		# Overhead arch every arch_spacing metres
		if int(z / arch_spacing) > int((z - gem_spacing) / arch_spacing):
			var arch_col: Color = col.darkened(0.15)

			if not darch_entry.is_empty():
				var da_anchor := Node3D.new()
				da_anchor.position           = _path_world_pos(z)
				da_anchor.rotation_degrees.y = z_y_rot + 180.0
				world_fx_root.add_child(da_anchor)
				var da_inst: Node3D = _piece_lib.instance(darch_entry)
				da_anchor.add_child(da_inst)
				# A child named "Crystal" spins like the procedural one — unless
				# the piece ships its own animation, which takes over entirely.
				if not bool(darch_entry.get("animated", false)):
					var da_crystal: Node3D = da_inst.find_child("Crystal*", true, false) as Node3D
					if da_crystal != null:
						var da_spin := create_tween().set_loops()
						da_spin.tween_property(da_crystal, "rotation_degrees:y", 360.0, 3.6).from(0.0)
			else:
				for side in [-1, 1]:
					var post: MeshInstance3D = _make_box_mesh(Vector3(0.10, 4.2, 0.10), arch_col)
					post.position = _path_world_pos(z, float(side) * tw * 0.5, 2.1)
					world_fx_root.add_child(post)

					# Small diagonal accent strut
					var strut: MeshInstance3D = _make_box_mesh(Vector3(0.06, 0.06, 0.70),
						arch_col.lightened(0.30))
					strut.position = _path_world_pos(z, float(side) * (tw * 0.5 - 0.4), 3.8)
					strut.rotation_degrees.z = float(side) * 25.0
					strut.rotation_degrees.y = z_y_rot
					world_fx_root.add_child(strut)

				# Horizontal beam across the top — oriented along track right direction
				var beam: MeshInstance3D = _make_box_mesh(
					Vector3(tw + 0.10, 0.10, 0.10), arch_col.lightened(0.30))
				beam.position = _path_world_pos(z, 0.0, 4.2)
				beam.rotation_degrees.y = z_y_rot
				world_fx_root.add_child(beam)

				# Dangling centre crystal
				var crystal_root := Node3D.new()
				crystal_root.position = _path_world_pos(z, 0.0, 3.5)
				world_fx_root.add_child(crystal_root)
				var crystal: MeshInstance3D = _make_box_mesh(Vector3(0.22, 0.44, 0.22),
					col.lightened(0.30))
				crystal.rotation_degrees = Vector3(0.0, 0.0, 45.0)
				crystal_root.add_child(crystal)
				var cspin := create_tween().set_loops()
				cspin.tween_property(crystal_root, "rotation_degrees:y", 360.0, 3.6).from(0.0)

			# Arch point light
			var alight := OmniLight3D.new()
			alight.light_color  = col.lightened(0.20)
			alight.light_energy = 0.60
			alight.omni_range   = 8.0
			alight.position     = _path_world_pos(z, 0.0, 4.0)
			world_fx_root.add_child(alight)
			_world_arch_lights.append(alight)

		# ── 4. Periodic floor pulse pads (every 4 gems, alternating sides) ──
		if gem_i % 4 == 0:
			var pad_side: float = 1.0 if (gem_i >> 2) % 2 == 0 else -1.0
			if not pad_entry.is_empty():
				var pad_anchor := Node3D.new()
				pad_anchor.position           = _path_world_pos(z, pad_side * (tw * 0.5 - 0.55), 0.01)
				pad_anchor.rotation_degrees.y = z_y_rot + 180.0
				world_fx_root.add_child(pad_anchor)
				var pad_inst: Node3D = _piece_lib.instance(pad_entry)
				pad_anchor.add_child(pad_inst)
				_register_piece_emissives(pad_inst, _world_pad_mats)   # beat pulse
			else:
				var pad: MeshInstance3D = _make_box_mesh(
					Vector3(0.80, 0.04, 1.4),
					gem_colors[(gem_i >> 2) % gem_colors.size()])
				pad.position = _path_world_pos(z, pad_side * (tw * 0.5 - 0.55), 0.03)
				pad.rotation_degrees.y = z_y_rot
				var pmat: StandardMaterial3D = pad.material_override as StandardMaterial3D
				if pmat != null:
					pmat.emission_energy_multiplier = 0.8
					_world_pad_mats.append(pmat)
				world_fx_root.add_child(pad)

		z += gem_spacing
		gem_i += 1

	# ── 5. Background distance haze pillars (far outside track, sparse) ────────
	var pillar_spacing: float = 120.0
	var pillar_pd: float = pillar_spacing
	var pi: int = 0
	while pillar_pd < end_path - 10.0:
		for side in [-1, 1]:
			for dist in [8.0, 14.0]:
				var ph: float = 20.0 + float(pi % 4) * 5.0
				if not hpillar_entry.is_empty():
					var hp_anchor := Node3D.new()
					hp_anchor.position = _path_world_pos(pillar_pd, float(side) * dist, 0.0)
					hp_anchor.rotation_degrees.y = _path_y_rot_at(pillar_pd) + 180.0
					hp_anchor.scale.y = ph / maxf(0.1,
						float(hpillar_entry.params.get("height", 26.0)))
					world_fx_root.add_child(hp_anchor)
					hp_anchor.add_child(_piece_lib.instance(hpillar_entry))
				else:
					var pillar: MeshInstance3D = _make_box_mesh(
						Vector3(0.22, ph, 0.22),
						gem_colors[pi % gem_colors.size()].darkened(0.50))
					pillar.position = _path_world_pos(pillar_pd, float(side) * dist, ph * 0.5)
					var plmat: StandardMaterial3D = pillar.material_override as StandardMaterial3D
					if plmat != null:
						plmat.emission_energy_multiplier = 0.40
					world_fx_root.add_child(pillar)
		pillar_pd += pillar_spacing
		pi += 1

	# ── 6. Ambient overhead track lights — always-on baseline illumination ────
	# Spaced every 25 m so the track is never purely dark between beat flashes.
	var ambient_spacing: float = 25.0
	var al_pd: float = ambient_spacing
	while al_pd < end_path - 10.0:
		var al := SpotLight3D.new()
		al.light_color      = Color(0.88, 0.84, 1.00, 1.0)
		al.light_energy     = 2.2
		al.spot_range       = 26.0
		al.spot_angle       = 60.0        # 60° half-angle → ~12 m radius at floor
		al.spot_attenuation = 0.8
		al.position         = _path_world_pos(al_pd, 0.0, 7.0)
		al.rotation_degrees = Vector3(90.0, 0.0, 0.0)   # point straight down
		world_fx_root.add_child(al)
		al_pd += ambient_spacing

	# ── 7. Authored lightposts — lining the track from assets/track/*.glb ─────
	# Each piece bakes its own lateral offset (e.g. siag_side "RIGHT"), so it's
	# anchored directly on the path centreline like rails/corners and just
	# faces forward along it. The authored mesh ships with no emission or
	# light of its own, so the lamp head gets a bright emissive material plus
	# a matching OmniLight3D to actually illuminate the track.
	if _piece_lib != null and _piece_lib.has_type("lightpost"):
		var lp_entry:    Dictionary = _piece_lib.first_of("lightpost")
		var lp_height:   float      = float(lp_entry.params.get("height", 4.0))
		var lp_spacing:  float      = 20.0
		var lp_glow_col: Color      = Color(1.0, 0.85, 0.5)
		var lp_pd:       float      = lp_spacing
		var lp_i:        int        = 0
		while lp_pd < end_path - 5.0:
			var lp_anchor := Node3D.new()
			lp_anchor.position           = _path_world_pos(lp_pd)
			lp_anchor.rotation_degrees.y = _path_y_rot_at(lp_pd) + 180.0
			var lp_inst: Node3D = _piece_lib.instance(lp_entry)
			# Alternate sides: local X is perpendicular to the path forward
			# direction under a pure Y-rotation, so mirroring across it
			# (scale.x = -1) flips the piece's baked siag_side offset to the
			# opposite edge of the track every other post — R, L, R, L, ...
			lp_inst.scale.x = -1.0 if lp_i % 2 == 1 else 1.0
			lp_anchor.add_child(lp_inst)
			world_fx_root.add_child(lp_anchor)

			for c in lp_inst.get_children():
				var lamp_mi: MeshInstance3D = c as MeshInstance3D
				if lamp_mi == null or String(c.name).to_lower().find("lamp") == -1:
					continue
				var lamp_mat := StandardMaterial3D.new()
				lamp_mat.albedo_color               = lp_glow_col
				lamp_mat.emission_enabled           = true
				lamp_mat.emission                   = lp_glow_col
				lamp_mat.emission_energy_multiplier = 8.0
				lamp_mi.material_override = lamp_mat
				_world_track_mats.append(lamp_mat)   # beat-pulse the lamp like the kit/ledges
				_world_track_base_e.append(maxf(0.05, lamp_mat.emission_energy_multiplier))

				var lp_light := OmniLight3D.new()
				lp_light.light_color  = lp_glow_col
				lp_light.light_energy = 3.5
				lp_light.omni_range   = 11.0
				lp_light.position     = Vector3(0.0, lp_height * 0.9, 0.0)
				lp_inst.add_child(lp_light)
				break

			lp_pd += lp_spacing


## Blends the emission of all MeshInstance3D children (recursively) toward live_col.
## Gate meshes store their original colour in the "base_color" meta — used here to
## preserve shape readability while the world palette shifts.
func _apply_cycle_to_node_meshes(node: Node3D, live_col: Color) -> void:
	var vis: Node3D = node.get_node_or_null("VisRoot") as Node3D
	if vis == null:
		vis = node
	_cycle_meshes_recursive(vis, live_col)


func _cycle_meshes_recursive(node: Node, live_col: Color) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child as MeshInstance3D
			if mi.material_override is StandardMaterial3D:
				var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D
				mat.emission = mat.emission.lerp(live_col, 0.04)
		if child.get_child_count() > 0:
			_cycle_meshes_recursive(child, live_col)


func _update_color_cycle(song_t: float) -> void:
	if not color_cycle_enabled:
		return

	# ── Ambient spark emitter — init lazily, follow player, update density/color ──
	_ensure_spark_ambient()
	if _spark_ambient != null and player != null:
		# Center the big sphere above and ahead of the player so it fills the sky
		_spark_ambient.global_position = player.global_position + Vector3(0.0, 6.0, 14.0)

	# ── 3D speed streaks — appear at high combo, follow the player ──────────
	_ensure_speed_streaks()
	_update_speed_streaks()

	var cycle_col: Color = _current_cycle_color(song_t)
	var vit: float       = _world_vitality
	var beat: float      = _beat_phase
	# Dead tint: dark desaturated purple toward which everything fades on misses
	var dead_tint: Color = Color(0.15, 0.12, 0.25, 1.0)
	# Squared beat for a snappier flash that fades fast
	var beat_boost: float = beat * beat

	# Vitality-tinted cycle color — desaturate toward dead_tint at low vitality
	var live_col: Color = cycle_col.lerp(dead_tint, (1.0 - vit) * 0.70)

	# ── Ambient sky sparks ────────────────────────────────────────────────────
	if _spark_ambient != null and _spark_ambient_mat != null:
		# Density: scales with vitality, beat_boost gives a density spike each beat
		_spark_ambient.amount_ratio = clampf(lerpf(0.18, 0.85, vit) + beat_boost * 0.15, 0.0, 1.0)
		# Color follows live palette
		_spark_ambient_mat.color = live_col.lightened(0.15)
		# Velocity eases back toward gentle baseline between beats
		var v_target: float = lerpf(0.4, 2.2, vit)
		_spark_ambient_mat.initial_velocity_min = lerpf(
			_spark_ambient_mat.initial_velocity_min, v_target * 0.25, 0.06)
		_spark_ambient_mat.initial_velocity_max = lerpf(
			_spark_ambient_mat.initial_velocity_max, v_target, 0.06)

	# ── Gates ────────────────────────────────────────────────────────────────
	if GameConfig.color_cycle_affects_gates:
		var beat_s: float   = max(0.20, _runner_avg_beat_s)
		var ahead_z: float  = max(min_gate_preview_distance, gate_preview_beats * beat_s * player.forward_speed)
		var player_z: float = _player_path_dist if player != null else 0.0

		for i in range(_vis_start_idx, gate_nodes.size()):
			var gate: Node3D = gate_nodes[i]
			if gate == null:
				continue
			var dz: float = gate_world_zs[i] - player_z
			if dz > ahead_z + 10.0:
				break
			if i < gate_judged.size() and gate_judged[i]:
				continue
			if not gate.visible:
				continue
			_apply_cycle_to_node_meshes(gate, live_col)

	# ── Floor ────────────────────────────────────────────────────────────────
	if _floor_material != null:
		var floor_target: Color
		if GameConfig.color_cycle_affects_floor:
			floor_target = _floor_base_albedo.lerp(live_col, color_cycle_floor_blend)
		else:
			floor_target = _floor_base_albedo
		_floor_material.albedo_color = _floor_material.albedo_color.lerp(floor_target, 0.06)
		var floor_e: float = lerpf(0.0, 0.65, vit) + beat_boost * 0.30
		_floor_material.emission_energy_multiplier = lerpf(
			_floor_material.emission_energy_multiplier, floor_e, 0.18)

	# ── Authored WJ kit + ledges: beat-reactive emission ─────────────────────
	# Full (authored energy) on the beat, smoothly dimming toward _TRACK_EMIT_DIM between
	# beats — never fully off. beat_boost (= _beat_phase²) is the on-beat spike; _beat_phase's
	# own decay in _process gives the soft falloff. Tune _TRACK_EMIT_DIM (0 = blink off,
	# 1 = no dimming).
	const _TRACK_EMIT_DIM: float = 0.30
	var track_pulse: float = _TRACK_EMIT_DIM + (1.0 - _TRACK_EMIT_DIM) * beat_boost
	for ti in range(_world_track_mats.size()):
		var tmat: StandardMaterial3D = _world_track_mats[ti]
		if tmat != null:
			tmat.emission_energy_multiplier = _world_track_base_e[ti] * track_pulse

	# ── Decoration LOD — only update world dressing every other frame ─────────
	_lod_frame = (_lod_frame + 1) % 2
	if _lod_frame != 0:
		return

	if not GameConfig.color_cycle_affects_world:
		return   # world deco colour-cycle disabled — keep existing tints

	# ── Side-wall strips ─────────────────────────────────────────────────────
	var strip_e: float = lerpf(0.05, 0.30, vit) + beat_boost * 0.50
	for smat: StandardMaterial3D in _world_strip_mats:
		if smat == null:
			continue
		smat.emission = smat.emission.lerp(live_col, 0.05)
		smat.emission_energy_multiplier = lerpf(smat.emission_energy_multiplier, strip_e, 0.15)

	# ── Floor-edge rails ─────────────────────────────────────────────────────
	var rail_e: float = lerpf(0.30, 1.4, vit) + beat_boost * 1.0
	for rmat: StandardMaterial3D in _world_rail_mats:
		if rmat == null:
			continue
		rmat.emission_energy_multiplier = lerpf(rmat.emission_energy_multiplier, rail_e, 0.20)

	# ── Gem lights ───────────────────────────────────────────────────────────
	var gem_e: float = lerpf(0.08, 0.45, vit) + beat_boost * 0.60
	var gem_r: float = lerpf(3.0, 7.0, vit) + beat_boost * 3.0
	for glight: OmniLight3D in _world_gem_lights:
		if glight == null:
			continue
		glight.light_color  = glight.light_color.lerp(live_col, 0.04)
		glight.light_energy = lerpf(glight.light_energy, gem_e, 0.15)
		glight.omni_range   = lerpf(glight.omni_range, gem_r, 0.15)

	# ── Arch lights ──────────────────────────────────────────────────────────
	var arch_e: float = lerpf(0.12, 0.80, vit) + beat_boost * 0.80
	for alight: OmniLight3D in _world_arch_lights:
		if alight == null:
			continue
		alight.light_color  = alight.light_color.lerp(live_col, 0.04)
		alight.light_energy = lerpf(alight.light_energy, arch_e, 0.15)

	# ── Floor pulse pads ─────────────────────────────────────────────────────────────────────────
	var pad_e: float = lerpf(0.0, 0.50, vit) + beat_boost * 0.40
	for pmat: StandardMaterial3D in _world_pad_mats:
		if pmat == null:
			continue
		pmat.emission       = pmat.emission.lerp(live_col, 0.06)
		pmat.emission_energy_multiplier = lerpf(pmat.emission_energy_multiplier, pad_e, 0.15)


# ═══════════════════════════════════════════════════════════════════════════════
# ── SNAKING PATH SYSTEM — helper functions ─────────────────────────────────────
# ═══════════════════════════════════════════════════════════════════════════════

## Build the list of TrackSeg objects that define the snaking path.
## Called in _ready AFTER _build_all_gate_visuals() so that _wj_zone_start_z /
## _wj_zone_end_z are already set.
##
## Turns can now appear at any point in the song — including well before the
## wall-jump zone.  The only restrictions are:
##   • No turn in the first 80 m (give the player a straight warm-up)
## Estimate the wall-jump zone bounds from runner_plan BEFORE the path is built.
## _build_track_path() uses these to forbid turn junctions inside the WJ band.
## The actual geometry is spawned (path-aware) in _spawn_wj_geometry_on_path().
func _prescan_wj_zone() -> void:
	var wj_zs: Array[float] = []
	for entry in runner_plan:
		if String(entry.get("section_tag", "")) != "wall_jump":
			continue
		var act: String = String(entry.get("action", ""))
		if act != "wall_left" and act != "wall_right":
			continue
		wj_zs.append(float(entry.get("t", 0.0)) * player.forward_speed)
	if wj_zs.is_empty():
		return
	wj_zs.sort()
	var first_wj_z: float = wj_zs[0]
	var last_wj_z:  float = wj_zs[wj_zs.size() - 1]
	# Conservative bounds: corridor starts 8 m before first gate, ends ~100 m
	# after the last (covers elevated floor + all descent steps).
	_wj_zone_start_z   = first_wj_z - 8.0
	_wj_zone_end_z     = last_wj_z  + 100.0
	# Solid floor ends just before the void begins.
	_floor_cutoff_dist = maxf(10.0, first_wj_z - 1.0)


##   • No turn junction within 60 m before or 80 m after the WJ band
##     (WJ geometry is now path-aware via _spawn_wj_geometry_on_path)
func _build_track_path() -> void:
	_track_segs.clear()
	_turn_junction_pds.clear()
	_turn_arc_ends.clear()
	_turn_is_right.clear()

	var total_len: float = _song_end_z() + 150.0
	var min_seg:   float = 250.0   # minimum metres between turns
	var max_seg:   float = 500.0   # maximum metres per segment
	var max_turns: int   = 10      # up to 10 corners per run; evenly spaced below

	# WJ geometry is now path-aware; only forbid junctions inside the WJ band.
	var wj_lo: float = _wj_zone_start_z - 60.0
	var wj_hi: float = _wj_zone_end_z   + 80.0
	var min_start: float = 100.0

	# ── Even spacing ────────────────────────────────────────────────────────
	# Precompute evenly-distributed turn target path-distances so turns spread
	# across the whole available section rather than clustering early.
	var avail: float = total_len - min_start
	var slot:  float = avail / float(max_turns + 1)
	var turn_targets: Array[float] = []
	for ti in range(max_turns):
		var base:   float = min_start + slot * float(ti + 1)
		var jitter: float = (_runner_rng.randf() - 0.5) * slot * 0.22   # ±11 % of slot
		turn_targets.append(clamp(base + jitter,
			min_start + float(ti) * min_seg,
			total_len  - float(max_turns - ti) * min_seg))

	var cur_origin: Vector3 = Vector3.ZERO
	var cur_dir:    Vector3 = Vector3(0, 0, 1)
	var cur_path:   float   = 0.0
	var turns_done: int     = 0
	# Forced alternation — even turns go right, odd turns go left (or opposite
	# if the first forced direction would overlap). This prevents 4× same-side runs.
	var last_was_right: bool = _runner_rng.randf() > 0.5   # randomise the first turn direction
	# Prevents the extend-last-segment optimization from absorbing the first straight
	# segment after an arc (the last arc sub-seg can be within 0.99 of the exit dir).
	var just_curved:   bool  = false
	# Chicane state — set after a regular turn fires a chicane roll, cleared after
	# the second arc is placed.  Overrides seg_len to the short connector distance.
	var chicane_next:  bool  = false
	var slot_idx:      int   = 0     # indexes turn_targets; only advances for non-chicane turns
	const CHICANE_SEG:    float = 65.0   # connector length between the two chicane arcs (m)
	const CHICANE_CHANCE: float = 0.35   # 35 % of regular turns become chicane pairs

	while cur_path < total_len:
		var remaining: float = total_len - cur_path
		var seg_len:   float

		if chicane_next:
			# Short connector between the two chicane arcs — ignore normal spacing
			seg_len = minf(CHICANE_SEG, remaining)
		elif turns_done >= max_turns or remaining <= min_seg:
			seg_len = remaining
		else:
			# Aim the segment length so we land near the next evenly-spaced target
			var target_junc: float = turn_targets[mini(slot_idx, turn_targets.size() - 1)]
			seg_len = clamp(target_junc - cur_path, min_seg, max_seg)
			seg_len = minf(seg_len, remaining)

		seg_len = maxf(seg_len, 1.0)

		# If the last committed segment goes the same direction, extend it instead
		# of creating a new one — keeps the segment list clean with no fake junctions.
		# just_curved guard: never extend the final arc sub-seg into the next straight.
		if not just_curved and not _track_segs.is_empty() and \
				(_track_segs[_track_segs.size() - 1] as TrackSeg).direction.dot(cur_dir) > 0.99:
			(_track_segs[_track_segs.size() - 1] as TrackSeg).length += seg_len
		else:
			var seg: TrackSeg = TrackSeg.new()
			seg.origin     = cur_origin
			seg.direction  = cur_dir
			seg.right      = Vector3(cur_dir.z, 0.0, -cur_dir.x)
			seg.length     = seg_len
			seg.path_start = cur_path
			_track_segs.append(seg)
		just_curved = false   # reset after each straight segment is placed

		cur_origin = cur_origin + cur_dir * seg_len
		cur_path  += seg_len

		if cur_path >= total_len or (turns_done >= max_turns and not chicane_next):
			break

		# ── Turn placement guards ──────────────────────────────────────────
		if cur_path < min_start:
			chicane_next = false
			continue
		if cur_path >= wj_lo and cur_path <= wj_hi:
			chicane_next = false   # can't chicane through the WJ zone
			continue

		# Alternate turns strictly: if last was right, prefer left, and vice versa.
		# Fall back to the same direction only if the preferred one would overlap.
		var right_opt: Vector3 = Vector3(cur_dir.z,  0.0, -cur_dir.x)
		var left_opt:  Vector3 = Vector3(-cur_dir.z, 0.0,  cur_dir.x)
		var preferred: Vector3 = left_opt  if last_was_right else right_opt
		var fallback:  Vector3 = right_opt if last_was_right else left_opt
		var dirs: Array = [preferred, fallback]

		var chosen: Vector3 = Vector3.ZERO
		for d in dirs:
			if not _path_would_cross(cur_origin, d, CHICANE_SEG if chicane_next else min_seg):
				chosen = d
				break

		if chosen == Vector3.ZERO:
			continue   # both directions would overlap an existing segment — skip

		last_was_right = (chosen == right_opt)

		# ── Racing-circuit arc corner ─────────────────────────────────────────
		# Instead of snapping the direction 90° at a point, insert CURVE_SEGS short
		# straight segments that together approximate a quarter-circle of radius
		# curve_radius.  Each sub-segment uses a slerp'd tangent direction so the
		# floor, collision bodies, and decorations all tile smoothly around the bend.
		const CURVE_SEGS: int = 32   # sub-segments per 90° arc (2.8° each = ultra smooth)
		# Variable radius: tight 12 m / normal 20 m / sweeping 32 m.
		# Chicane second arcs stay tight-or-normal — sweeping S-bends are too wide.
		# When authored Blender corners exist, the path ONLY uses their radii so
		# every arc is guaranteed to be covered by an asset (no procedural corners).
		var curve_radius: float
		var lib_radii: Array = (_piece_lib.turn_radii() if _piece_lib != null else [])
		if not lib_radii.is_empty():
			if chicane_next:
				# prefer the tighter authored radii for S-bend connectors
				curve_radius = float(lib_radii[_runner_rng.randi() % mini(2, lib_radii.size())])
			else:
				curve_radius = float(lib_radii[_runner_rng.randi() % lib_radii.size()])
		elif chicane_next:
			curve_radius = 12.0 if _runner_rng.randf() < 0.5 else 20.0
		else:
			var r_roll: float = _runner_rng.randf()
			if r_roll < 0.25:
				curve_radius = 12.0   # tight corner
			elif r_roll < 0.80:
				curve_radius = 20.0   # normal corner
			else:
				curve_radius = 32.0   # sweeping corner
		var arc_sub_len: float = curve_radius * PI / 2.0 / float(CURVE_SEGS)

		_turn_junction_pds.append(cur_path)   # record arc START for gate culling
		_turn_is_right.append(last_was_right) # record direction for banking + camera lean

		for arc_i in range(CURVE_SEGS):
			# MIDPOINT tangent sampling — each sub-segment heads along its
			# sub-arc's CHORD, so the polyline lands on the true circle exit
			# (± millimetres). Sampling at the sub-arc START (the old way)
			# walked a tangent polygon that came out rotated half a step:
			# the arc exit ended up ~r·√2·sin(1.4°) ≈ 0.7 m sideways/long
			# (mirrored per turn direction), so authored corner pieces —
			# which ARE true arcs anchored at the entry — visibly missed the
			# next piece's lane lines at the corner EXIT.
			var t: float       = (float(arc_i) + 0.5) / float(CURVE_SEGS)
			var sub_dir: Vector3   = cur_dir.slerp(chosen, t)
			var sub_right: Vector3 = Vector3(sub_dir.z, 0.0, -sub_dir.x)

			var arc_seg: TrackSeg = TrackSeg.new()
			arc_seg.origin     = cur_origin
			arc_seg.direction  = sub_dir
			arc_seg.right      = sub_right
			arc_seg.length     = arc_sub_len
			arc_seg.path_start = cur_path
			_track_segs.append(arc_seg)

			cur_origin = cur_origin + sub_dir * arc_sub_len
			cur_path  += arc_sub_len

		_turn_arc_ends.append(cur_path)       # record arc END for gate culling
		cur_dir     = chosen
		just_curved = true   # prevent next straight from merging with last arc sub-seg
		if chicane_next:
			# This was the second arc of a chicane pair — clear the flag
			chicane_next = false
		else:
			# Regular turn — roll for a chicane follow-up (not if near the end of budget)
			if turns_done < max_turns - 1:
				chicane_next = _runner_rng.randf() < CHICANE_CHANCE
			slot_idx += 1
		turns_done += 1


## Returns true if a proposed new segment (starting at `origin`, heading `dir`,
## at least `check_len` metres long) would overlap any existing track segment
## (excluding the immediately adjacent one that shares the junction).
## All directions are axis-aligned, so AABB intersection in the XZ plane suffices.
func _path_would_cross(origin: Vector3, dir: Vector3, check_len: float) -> bool:
	var tw_h: float = _track_full_width() * 0.5 + 2.0   # half-width + small margin
	# Skip past the largest possible arc footprint (R=32 m → ~50 m) + safety buffer.
	var cs:   Vector3 = origin + dir * 60.0
	var ce:   Vector3 = origin + dir * check_len

	# AABB of the proposed segment in the XZ plane
	var nx_min: float; var nx_max: float; var nz_min: float; var nz_max: float
	if abs(dir.z) > 0.5:   # Z-aligned
		nx_min = cs.x - tw_h;  nx_max = cs.x + tw_h
		nz_min = min(cs.z, ce.z);  nz_max = max(cs.z, ce.z)
	else:                   # X-aligned
		nx_min = min(cs.x, ce.x);  nx_max = max(cs.x, ce.x)
		nz_min = cs.z - tw_h;  nz_max = cs.z + tw_h

	# Compare against every committed segment except the last (shares the junction)
	var limit: int = max(0, _track_segs.size() - 1)
	for si in range(limit):
		var es:     TrackSeg = _track_segs[si] as TrackSeg
		var es_end: Vector3  = es.origin + es.direction * es.length
		var ex_min: float; var ex_max: float; var ez_min: float; var ez_max: float
		if abs(es.direction.z) > 0.5:
			ex_min = es.origin.x - tw_h;  ex_max = es.origin.x + tw_h
			ez_min = min(es.origin.z, es_end.z);  ez_max = max(es.origin.z, es_end.z)
		else:
			ex_min = min(es.origin.x, es_end.x);  ex_max = max(es.origin.x, es_end.x)
			ez_min = es.origin.z - tw_h;  ez_max = es.origin.z + tw_h

		if nx_max > ex_min and nx_min < ex_max and nz_max > ez_min and nz_min < ez_max:
			return true   # would cross
	return false


## Returns the index into _track_segs for the given path distance.
func _path_seg_idx_at(dist: float) -> int:
	if _track_segs.is_empty():
		return 0
	var idx: int = clampi(_last_seg_idx, 0, _track_segs.size() - 1)
	# Walk forward
	while idx < _track_segs.size() - 1 and dist >= (_track_segs[idx] as TrackSeg).path_end():
		idx += 1
	# Walk backward (shouldn't normally happen)
	while idx > 0 and dist < (_track_segs[idx] as TrackSeg).path_start:
		idx -= 1
	_last_seg_idx = idx
	return idx


func _path_seg_at(dist: float) -> TrackSeg:
	return _track_segs[_path_seg_idx_at(dist)] as TrackSeg


## World position of the path centreline at path distance `dist`.
func _path_pos_at(dist: float) -> Vector3:
	if _track_segs.is_empty():
		return Vector3(0.0, 0.0, dist)
	var seg: TrackSeg = _path_seg_at(dist)
	return seg.origin + seg.direction * (dist - seg.path_start)


func _path_forward_at(dist: float) -> Vector3:
	if _track_segs.is_empty():
		return Vector3(0.0, 0.0, 1.0)
	return (_path_seg_at(dist) as TrackSeg).direction


func _path_right_at(dist: float) -> Vector3:
	if _track_segs.is_empty():
		return Vector3(1.0, 0.0, 0.0)
	return (_path_seg_at(dist) as TrackSeg).right


## Convert path-space coordinates to a world Vector3.
##   path_dist — metres along the centreline
##   lateral   — metres left (−) / right (+) of centreline
##   height    — world Y above the track surface (0 = surface)
func _path_world_pos(path_dist: float, lateral: float = 0.0, height: float = 0.0) -> Vector3:
	if _track_segs.is_empty():
		return Vector3(lateral, height, path_dist)
	var seg: TrackSeg = _path_seg_at(path_dist)
	var base: Vector3 = seg.origin + seg.direction * (path_dist - seg.path_start)
	return base + seg.right * lateral + Vector3(0.0, height, 0.0)


## Returns the Y-rotation (degrees) that makes a node face the path forward direction.
func _path_y_rot_at(path_dist: float) -> float:
	var fwd: Vector3 = _path_forward_at(path_dist)
	return rad_to_deg(atan2(fwd.x, fwd.z))


## Move every already-built gate node to its correct world position on the path.
## Gate world_zs already hold the right path-distance values (set when gates were
## first built as `t * forward_speed`), so we just re-derive world pos from those.
func _reposition_gates_on_path() -> void:
	if _track_segs.is_empty():
		return
	for i in range(gate_nodes.size()):
		var gn: Node3D = gate_nodes[i]
		if gn == null:
			continue
		var pd: float  = gate_world_zs[i]   # this IS the path distance
		gn.position    = _path_world_pos(pd)
		gn.rotation_degrees.y = _path_y_rot_at(pd)


## Auto-succeed and permanently hide any gate whose path distance falls inside a
## turn arc zone.  Each arc is bounded by its START (in _turn_junction_pds) and END
## (_turn_arc_ends) path distances.  TURN_PRE/POST add small grace margins either side.
func _cull_turn_zone_gates() -> void:
	if _turn_junction_pds.is_empty():
		return

	const TURN_PRE:  float = 5.0   # metres before arc starts
	const TURN_POST: float = 8.0   # metres after arc ends (camera settle)

	for i in range(gate_nodes.size()):
		if gate_judged[i]:
			continue   # already judged (e.g. wall-jump gates handled elsewhere)

		var pd: float = gate_world_zs[i]

		for j in range(_turn_junction_pds.size()):
			var arc_start: float = _turn_junction_pds[j]
			# Fallback: if arc end wasn't recorded (shouldn't happen), estimate it
			var arc_end: float = _turn_arc_ends[j] if j < _turn_arc_ends.size() \
								 else arc_start + 35.0
			if pd >= arc_start - TURN_PRE and pd <= arc_end + TURN_POST:
				# Auto-succeed: player is not penalised, no health loss, no combo break
				gate_judged[i] = true
				gate_success[i] = true
				# Permanently hide the gate so it never pops into view
				var gn: Node3D = gate_nodes[i]
				if is_instance_valid(gn):
					gn.process_mode = Node.PROCESS_MODE_DISABLED
					gn.visible = false
				break   # no need to check other junctions for this gate


## Spawn per-segment StaticBody3D floor slabs along the entire path.
## The wall-jump void [_floor_cutoff_dist, _wj_ground_resume_z] is skipped, but
## all segments that come AFTER the void still get a proper path-aligned floor.
## Without this, turned segments after the WJ zone had no floor at all.
func _spawn_path_floors() -> void:
	var track_root: Node3D = $Track
	var tw:    float = _track_full_width()
	var thick: float = 0.30
	var cy:    float = -thick * 0.5

	# WJ void bounds (both are -INF / -1 when no WJ section exists).
	var void_lo: float = _floor_cutoff_dist                # floor ends here (before WJ)
	var void_hi: float = _wj_ground_resume_z               # floor resumes here (after WJ)
	var has_void: bool = (void_lo < INF and void_hi >= 0.0)

	for seg_var in _track_segs:
		var seg: TrackSeg = seg_var as TrackSeg
		var seg_s: float  = seg.path_start
		var seg_e: float  = seg.path_end()

		# Build up to two sub-ranges per segment: the part before the void and
		# the part after it.  When there is no WJ void, the whole segment is one range.
		var ranges: Array = []
		if has_void:
			# Before void
			if seg_s < void_lo:
				var r_end: float = minf(seg_e, void_lo)
				if r_end > seg_s:
					ranges.append([seg_s, r_end])
			# After void
			if seg_e > void_hi:
				var r_start: float = maxf(seg_s, void_hi)
				if r_start < seg_e:
					ranges.append([r_start, seg_e])
		else:
			ranges.append([seg_s, seg_e])

		for rng in ranges:
			var r_start: float = rng[0]
			var r_end:   float = rng[1]
			var r_len:   float = r_end - r_start
			if r_len <= 0.0:
				continue

			# Centre of this sub-range along the segment direction
			var center: Vector3 = seg.origin \
				+ seg.direction * (r_start - seg.path_start + r_len * 0.5)
			center.y = cy

			var body: StaticBody3D = StaticBody3D.new()
			body.position           = center
			body.rotation_degrees.y = rad_to_deg(atan2(seg.direction.x, seg.direction.z))

			var col_shape: CollisionShape3D = CollisionShape3D.new()
			var box: BoxShape3D = BoxShape3D.new()
			box.size = Vector3(tw, thick, r_len)
			col_shape.shape = box
			body.add_child(col_shape)

			var mid_pd: float = (r_start + r_end) * 0.5
			var arc_here: int = _arc_idx_at(mid_pd)
			var visual_done: bool = false

			# An authored Blender corner already covers this arc — collision only.
			if arc_here >= 0 and _authored_arcs.has(arc_here):
				visual_done = true

			# Authored straights are the ONLY straight floor visuals when any
			# exist — the game stops generating its own slabs entirely. Full
			# pieces are tiled; the remainder is closed with a Z-scaled piece,
			# so the whole range is covered by assets with no procedural fill.
			if not visual_done and arc_here < 0 and _piece_lib != null \
					and _piece_lib.has_type("straight"):
				_tile_authored_straights(body, r_len)
				visual_done = true

			if not visual_done:
				var mesh_inst: MeshInstance3D = _make_box_mesh(Vector3(tw, thick, r_len), _floor_base_albedo)
				if _floor_material != null:
					mesh_inst.set_surface_override_material(0, _floor_material)

				# ── Banking — tilt the visual mesh outward through arcs (collision stays flat)
				const BANK_MAX_DEG: float = 21.0
				for arc_i in range(_turn_junction_pds.size()):
					var arc_s: float = _turn_junction_pds[arc_i]
					var arc_e: float = _turn_arc_ends[arc_i]
					if mid_pd >= arc_s and mid_pd < arc_e:
						var t: float     = (mid_pd - arc_s) / (arc_e - arc_s)
						var bsign: float = -1.0 if _turn_is_right[arc_i] else 1.0
						# Negative local-Z rotation for a right turn raises the right (outer)
						# edge and lowers the left (inner) edge — correct racing-circuit bank.
						mesh_inst.rotation_degrees.z = BANK_MAX_DEG * sin(t * PI) * bsign
						break

				body.add_child(mesh_inst)

			track_root.add_child(body)


## Index of the 90° arc containing path distance pd, or -1 when on a straight.
func _arc_idx_at(pd: float) -> int:
	for i in range(_turn_junction_pds.size()):
		if pd >= _turn_junction_pds[i] and pd < _turn_arc_ends[i]:
			return i
	return -1


## Spawn authored Blender corner pieces on every arc whose radius + direction
## match a piece in the library (radius tolerance 0.75 m). Marks the arc in
## _authored_arcs so _spawn_path_floors / _spawn_arc_decorations skip their
## procedural floor visuals. Pieces are placed at the arc entry junction and
## rotated to the entry heading — banking is baked into the piece itself.
func _place_authored_corners() -> void:
	if _piece_lib == null or not _piece_lib.has_type("turn"):
		return
	var track_root: Node3D = $Track
	for arc_idx in range(_turn_junction_pds.size()):
		var arc_s: float = _turn_junction_pds[arc_idx]
		var arc_e: float = _turn_arc_ends[arc_idx]
		var radius: float = (arc_e - arc_s) * 2.0 / PI
		# Blender pieces arrive mirrored across the travel axis (Blender +Y →
		# Godot −Z import), so a game right-arc matches a piece authored as "L".
		var want: String = "L" if _turn_is_right[arc_idx] else "R"
		if mirror_turn_pieces:
			want = "R" if want == "L" else "L"
		var entry: Dictionary = _piece_lib.match_turn(radius, want)
		if entry.is_empty():
			# Radii are constrained to the authored set, so this only happens
			# when one turn DIRECTION wasn't exported. That arc falls back to
			# the procedural banked floor so the track has no hole.
			push_warning("[BeatRunner] No authored corner for r=%.1f dir=%s — export both directions! Using procedural floor for this arc." % [radius, want])
			continue
		var wrap: Node3D = Node3D.new()
		wrap.position           = _path_world_pos(arc_s)
		wrap.position.y         = 0.0
		# Entry heading comes from the STRAIGHT before the junction — the arc's
		# own sub-segments are chords (midpoint-sampled), so the first one is
		# already rotated half a sub-step into the turn and would swing the
		# authored piece's far end sideways. A straight always precedes an arc
		# (chicanes get a 65 m connector), so sampling 0.5 m back is safe.
		wrap.rotation_degrees.y = _path_y_rot_at(maxf(0.0, arc_s - 0.5)) + 180.0
		var corner_inst: Node3D = _piece_lib.instance(entry)
		wrap.add_child(corner_inst)
		track_root.add_child(wrap)
		_register_track_emissives(corner_inst)
		_authored_arcs[arc_idx] = true


## Fill a floor body with authored straight pieces, longest-first (greedy).
## The final remainder (always shorter than the shortest piece) is closed with
## a Z-scaled copy of the shortest piece, so coverage is 100 % asset-based —
## no procedural slabs anywhere on straights.
## Body local space: centre at floor mid-thickness; the sub-range spans local
## z −r_len/2 … +r_len/2; floor top is at local y +0.15.
func _tile_authored_straights(body: Node3D, r_len: float) -> void:
	var z: float = -r_len * 0.5
	var covered: float = 0.0
	while true:
		var entry: Dictionary = _piece_lib.best_straight(r_len - covered)
		if entry.is_empty():
			break
		var plen: float = float(entry.params.get("length", 0.0))
		if plen <= 0.0:
			break
		var inst: Node3D = _piece_lib.instance(entry)
		inst.position = Vector3(0.0, 0.15, z)
		inst.rotation_degrees.y = 180.0   # piece runs −Z after import; body forward is +Z
		body.add_child(inst)
		_register_track_emissives(inst)
		z += plen
		covered += plen

	var rest: float = r_len - covered
	if rest > 0.05:
		var short_e: Dictionary = _piece_lib.shortest_straight()
		if not short_e.is_empty():
			var slen: float = float(short_e.params.get("length", 0.0))
			if slen > 0.0:
				var tail: Node3D = _piece_lib.instance(short_e)
				tail.position = Vector3(0.0, 0.15, z)
				tail.rotation_degrees.y = 180.0
				tail.scale.z = rest / slen   # squash to close the gap exactly
				body.add_child(tail)
				_register_track_emissives(tail)


func _exit_tree() -> void:
	if _piece_lib != null:
		_piece_lib.clear()   # free orphan authored-piece templates
		_piece_lib = null


## Builds a smooth quad-strip ArrayMesh that follows the arc path.
## Both edges are expressed as (lateral, height) offsets in banked local space:
##   lateral — metres from track centreline (+right / −left in world terms)
##   height  — metres above the flat floor surface (applied along banked-up axis)
## normal_mode: 0 = banked-up (horizontal surfaces), 1 = inward (-banked_right*outer)
## outer: pass +1 or −1 for normal_mode=1 to control which way "inward" faces.
func _arc_quad_mesh(arc_s: float, arc_e: float, is_right: bool,
		lat_a: float, h_a: float, lat_b: float, h_b: float,
		normal_mode: int = 0, outer: float = 1.0, n: int = 72) -> ArrayMesh:
	var verts   := PackedVector3Array()
	var norms   := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var indices := PackedInt32Array()
	var bsign: float = -1.0 if is_right else 1.0
	const BANK_MAX: float = 21.0   # must match the constant in _spawn_path_floors

	for i in range(n + 1):
		var t:   float    = float(i) / float(n)
		var pd:  float    = arc_s + (arc_e - arc_s) * t
		var seg: TrackSeg = _path_seg_at(pd)
		var ctr: Vector3  = seg.origin + seg.direction * (pd - seg.path_start)
		var bank: float   = BANK_MAX * sin(t * PI) * bsign
		var br:  Vector3  = seg.right.rotated(seg.direction, deg_to_rad(bank))
		var bu:  Vector3  = Vector3.UP.rotated(seg.direction, deg_to_rad(bank))

		verts.append(ctr + br * lat_a + bu * h_a)
		verts.append(ctr + br * lat_b + bu * h_b)
		var norm: Vector3 = bu if normal_mode == 0 else -br * outer
		norms.append(norm); norms.append(norm)
		uvs.append(Vector2(0.0, t)); uvs.append(Vector2(1.0, t))

	for i in range(n):
		var b: int = i * 2
		indices.append(b);     indices.append(b + 2); indices.append(b + 1)
		indices.append(b + 1); indices.append(b + 2); indices.append(b + 3)

	var arr: Array = []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX]  = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Spawn arc-specific decorations: outer barrier wall, inner accent strip,
## entry/exit beacon pillars, and a smooth floor overlay that hides seams.
## Called once per arc after _build_track_path().
func _spawn_arc_decorations() -> void:
	if _turn_junction_pds.is_empty():
		return
	var tw:      float = _track_full_width()
	var half_tw: float = tw * 0.5
	var barrier_col: Color = Color(0.96, 0.04, 0.05, 1.0)   # red — matches floor rails
	var accent_col:  Color = Color(0.20, 0.85, 1.00, 1.0)   # cyan inner accent
	var beacon_col:  Color = Color(1.00, 0.88, 0.25, 1.0)   # gold entry/exit markers

	for arc_idx in range(_turn_junction_pds.size()):
		var arc_s:    float = _turn_junction_pds[arc_idx]
		var arc_e:    float = _turn_arc_ends[arc_idx]
		var is_right: bool  = _turn_is_right[arc_idx]
		var outer:    float = 1.0 if is_right else -1.0
		# Authored Blender corner here → its own floor/curbs/lines replace the
		# procedural floor overlay + inner accent. Barrier and beacons still spawn.
		var authored: bool  = _authored_arcs.has(arc_idx)

		# ── Smooth floor overlay — single mesh covering the entire arc ────────────
		# Sits 2 mm above the individual floor slabs; same material so it updates
		# with the beat-pulse colour cycle exactly like the rest of the floor.
		if not authored:
			var floor_mi := MeshInstance3D.new()
			floor_mi.mesh = _arc_quad_mesh(arc_s, arc_e, is_right,
					-half_tw, 0.002, half_tw, 0.002, 0)
			if _floor_material != null:
				floor_mi.set_surface_override_material(0, _floor_material)
			world_fx_root.add_child(floor_mi)

		# ── Smooth outer barrier — one continuous curved wall ─────────────────────
		var bar_mi := MeshInstance3D.new()
		bar_mi.mesh = _arc_quad_mesh(arc_s, arc_e, is_right,
				outer * (half_tw + 0.08), 0.0,
				outer * (half_tw + 0.08), 1.6,
				1, outer)
		var bar_mat := StandardMaterial3D.new()
		bar_mat.albedo_color = barrier_col
		bar_mat.emission_enabled = true
		bar_mat.emission = barrier_col
		bar_mat.emission_energy_multiplier = 0.8
		bar_mi.material_override = bar_mat
		_world_rail_mats.append(bar_mat)
		world_fx_root.add_child(bar_mi)

		# ── Smooth inner accent strip — low glowing cyan band on inner floor edge ─
		if not authored:
			var acc_mi := MeshInstance3D.new()
			acc_mi.mesh = _arc_quad_mesh(arc_s, arc_e, is_right,
					-outer * half_tw * 0.36, 0.025,
					-outer * half_tw * 0.56, 0.025, 0)
			var acc_mat := StandardMaterial3D.new()
			acc_mat.albedo_color = accent_col
			acc_mat.emission_enabled = true
			acc_mat.emission = accent_col
			acc_mat.emission_energy_multiplier = 1.4
			acc_mi.material_override = acc_mat
			_world_strip_mats.append(acc_mat)
			world_fx_root.add_child(acc_mi)

		# ── Entry/exit beacon pillars — individual boxes framing each arc end ─────
		# Authored Blender "Beacon" pieces replace the procedural gold pillars
		# (the piece bakes its own lateral offset; mirrored for the far side).
		var beacon_entry: Dictionary = (_piece_lib.first_of("beacon") if _piece_lib != null else {})
		for junction_pd in [arc_s, arc_e]:
			var j_seg: TrackSeg = _path_seg_at(junction_pd)
			var j_pos: Vector3  = _path_world_pos(junction_pd)
			var j_rot: float    = rad_to_deg(atan2(j_seg.direction.x, j_seg.direction.z))
			for side in [-1.0, 1.0]:
				if not beacon_entry.is_empty():
					var bc_anchor := Node3D.new()
					bc_anchor.position           = j_pos
					bc_anchor.rotation_degrees.y = j_rot
					bc_anchor.scale.x            = side   # one authored side covers both
					world_fx_root.add_child(bc_anchor)
					var bc_inst: Node3D = _piece_lib.instance(beacon_entry)
					bc_inst.rotation_degrees.y = 180.0
					bc_anchor.add_child(bc_inst)
					_register_piece_emissives(bc_inst, _world_rail_mats)   # beat pulse
					continue
				var beacon: MeshInstance3D = _make_box_mesh(
					Vector3(0.14, 3.2, 0.14), beacon_col)
				beacon.position = j_pos \
					+ j_seg.right * (side * (half_tw + 0.55)) \
					+ Vector3(0.0, 1.6, 0.0)
				var bmat: StandardMaterial3D = beacon.material_override as StandardMaterial3D
				if bmat != null:
					bmat.emission_energy_multiplier = 1.8
					_world_rail_mats.append(bmat)
				world_fx_root.add_child(beacon)
			var bar: MeshInstance3D = _make_box_mesh(
				Vector3(tw + 1.2, 0.08, 0.08), beacon_col)
			bar.position           = j_pos + Vector3(0.0, 3.2, 0.0)
			bar.rotation_degrees.y = j_rot
			var barmat: StandardMaterial3D = bar.material_override as StandardMaterial3D
			if barmat != null:
				barmat.emission_energy_multiplier = 1.4
				_world_rail_mats.append(barmat)
			world_fx_root.add_child(bar)


## Spawn square corner pads (tw × tw) at each segment junction to fill the gap
## created by 90° turns.
func _spawn_corner_pieces() -> void:
	if _track_segs.size() < 2:
		return
	var track_root: Node3D = $Track
	var tw:    float = _track_full_width()
	var thick: float = 0.30
	var cy:    float = -thick * 0.5

	for i in range(1, _track_segs.size()):
		var seg:      TrackSeg = _track_segs[i - 1] as TrackSeg
		var next_seg: TrackSeg = _track_segs[i] as TrackSeg
		var junc_pd:  float    = seg.path_end()
		var junc_pos: Vector3  = seg.origin + seg.direction * seg.length

		# Skip if the angle between adjacent segments is too small — this covers both
		# same-direction WJ guard splits AND arc sub-segment joints (~11° each).
		# cos(15°) ≈ 0.966, so threshold 0.95 skips anything under ~18°.
		if seg.direction.dot(next_seg.direction) > 0.95:
			continue

		# Skip corner if it's in the wall-jump void
		if junc_pd >= _floor_cutoff_dist:
			continue

		# ── 1. Precise gap-fill corner pad ───────────────────────────────────
		# A full tw×tw pad centred at junc_pos protrudes on the outer corner and
		# z-fights with both flanking floor slabs.  Instead we place a tw/2×tw/2
		# pad that fills *only* the uncovered inner-corner triangle.
		#
		# Cross-product Y: negative = right turn, positive = left turn.
		# Gap centre = junction + (tw/4) forward along approach
		#                       + (tw/4) inward (opposite the turning side).
		var cross_y: float = seg.direction.x * next_seg.direction.z \
						   - seg.direction.z * next_seg.direction.x
		var gap_ctr: Vector3 = junc_pos \
			+ seg.direction * (tw * 0.25) \
			+ cross_y * seg.right * (tw * 0.25)
		gap_ctr.y = cy

		var body: StaticBody3D = StaticBody3D.new()
		body.position = gap_ctr

		var col_shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(tw * 0.5, thick, tw * 0.5)
		col_shape.shape = box
		body.add_child(col_shape)

		var mesh_inst: MeshInstance3D = _make_box_mesh(Vector3(tw * 0.5, thick, tw * 0.5), _floor_base_albedo)
		if _floor_material != null:
			mesh_inst.set_surface_override_material(0, _floor_material)
		body.add_child(mesh_inst)
		track_root.add_child(body)
