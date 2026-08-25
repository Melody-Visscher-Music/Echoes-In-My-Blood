extends CharacterBody3D
class_name BeatRunnerPlayer

@export var forward_speed: float = 18.0
@export var lane_xs: PackedFloat32Array = PackedFloat32Array([-2.4, 0.0, 2.4])
@export var lane_lerp_speed: float = 16.0

@export var gravity: float = 52.0
@export var jump_velocity: float = 11.4
@export var wall_jump_velocity: float = 22.0

@export var slide_duration: float = 0.28
# Hard ceiling on how much the authored Slide clip may be time-compressed to fit
# between two slides. Default 1.0 = NEVER compress: the clip plays at its authored
# speed, exactly like Jump does, and a following slide simply crossfades over
# whatever is left. Raise it only if the un-compressed tail visibly overstays.
@export var slide_anim_max_speed: float = 1.0
@export var stand_capsule_height: float = 1.8
@export var slide_capsule_height: float = 0.95

# ── Character model tuning (SIAGCharacter.glb) ────────────────────────────────
@export var character_yaw_offset_deg: float = 0.0
@export var character_scale: float = 1.0
@export var character_y_offset: float = 0.0
## Authored "Run" clip ground-sync: metres of track one FULL run cycle
## should appear to cover. The clip speed is derived from the actual
## forward speed (already tempo-scaled), so the feet grip the ground at
## every BPM. LOWER = faster feet. Tune this until the slip is gone.
@export var run_stride_m: float = 6.0
## Track speed tempo sync: at this BPM the runner moves at the authored
## forward_speed; faster songs push the world past proportionally faster
## (clamped ×0.5 … ×2.0). Safe for sync: the whole track is laid out as
## time × speed AFTER this is applied, so beat spacing simply widens in
## metres and everything still lands on the music.
@export var forward_speed_ref_bpm: float = 130.0

# ── SO FLUFFY fur settings (Inspector → "Fur") ────────────────────────────────
# All sliders update the fur live during Play mode — no restart needed.
# Body colour is auto-derived from GameConfig.fur_color (Highlight/Desaturate
# control how much lighter the shell tips appear vs. the base coat).
# Accent fur (tail tip + white ruff) shares shape/physics but has its own colour.
@export_group("Fur")

@export_subgroup("Body Colour")
## How much to brighten the game's body fur colour toward white for the shell tips.
## Keep this low (0.15–0.25) for a natural look; 0.55+ will look like cotton wool.
@export_range(0.0, 1.0, 0.01) var fur_highlight: float = 0.20:
	set(v):
		fur_highlight = v
		_sync_fur_color()

## How much to pull saturation toward grey as the highlights get lighter.
## Prevents neon tints on vividly-coloured base coats.
@export_range(0.0, 1.0, 0.01) var fur_desaturate: float = 0.30:
	set(v):
		fur_desaturate = v
		_sync_fur_color()

@export_subgroup("Accent Colour (Tail Tip + White Ruff)")
## How much to brighten the tail-tip / white-ruff colour above the game's base.
## These areas are already near-white, so keep this small (0.05–0.15).
@export_range(0.0, 1.0, 0.01) var fur_accent_highlight: float = 0.10:
	set(v):
		fur_accent_highlight = v
		_sync_accent_color()

## How much to shift the accent highlights toward neutral grey.
@export_range(0.0, 1.0, 0.01) var fur_accent_desaturate: float = 0.15:
	set(v):
		fur_accent_desaturate = v
		_sync_accent_color()

@export_subgroup("Shape")
## Number of shell layers stacked on top of the mesh.
## 16–24 is good for gameplay; 48–64 for cutscenes. Higher = smoother but costlier.
@export_range(4, 128, 1) var fur_shells: int = 40:
	set(v):
		fur_shells = v
		_set_fur_all(&"number_of_shells", v)

## Length of each strand in world units. 0.03–0.06 reads well at gameplay distance.
@export_range(0.01, 0.5, 0.001, "or_greater") var fur_length: float = 0.045:
	set(v):
		fur_length = v
		_set_fur_all(&"length", v)

## Strands per UV area unit. Higher = thicker coat, heavier on GPU.
@export_range(0.01, 3.0, 0.01, "or_greater") var fur_density: float = 0.5:
	set(v):
		fur_density = v
		_set_fur_all(&"density", v)

## Randomises individual strand heights. 0 = uniform, higher = messy/wild.
## Keep below 0.4 for a groomed look.
@export_range(0.0, 4.0, 0.01) var fur_scruffiness: float = 0.30:
	set(v):
		fur_scruffiness = v
		_set_fur_all(&"scruffiness", v)

## Uniform strand width multiplier. Higher = thicker individual hairs.
@export_range(0.1, 4.0, 0.01, "or_greater") var fur_thickness: float = 1.5:
	set(v):
		fur_thickness = v
		_set_fur_all(&"thickness_scale", v)

## 1 = strands grow along the surface normal (fluffy/outward).
## 0 = strands grow in the fixed direction set by Fur Static Local below.
@export_range(0.0, 1.0, 0.005) var fur_normal_strength: float = 1.0:
	set(v):
		fur_normal_strength = v
		_set_fur_all(&"normal_strength", v)

## Object-space direction override for strand growth (e.g. a mane or mohawk).
## Only has effect when Normal Strength is below 1.
@export var fur_static_local: Vector3 = Vector3.ZERO:
	set(v):
		fur_static_local = v
		_set_fur_all(&"static_direction_local", v)

## Fill in shell 0 (the skin layer) as a solid surface.
## Avoids needing a separate skin material underneath the fur.
@export var fur_render_skin: bool = false:
	set(v):
		fur_render_skin = v
		_set_fur_all(&"render_skin", v)

@export_subgroup("Curls")
## Enable spiral curl rendering. Looks great for tight-coiled fur; more expensive.
@export var fur_curls: bool = false:
	set(v):
		fur_curls = v
		_set_fur_all(&"curls_enabled", v)

## How many full twists per strand length. Higher = tighter spirals.
@export_range(0.0, 128.0, 0.5) var fur_curls_twist: float = 48.0:
	set(v):
		fur_curls_twist = v
		_set_fur_all(&"curls_twist", v)

## Arc fraction of each curl circle that is solid (in radians, max ~6.28 = full ring).
@export_range(0.0, 6.283, 0.01) var fur_curls_fill: float = 0.785:
	set(v):
		fur_curls_fill = v
		_set_fur_all(&"curls_fill", v)

@export_subgroup("LOD")
## Reduce shell count with distance for better performance. Recommended in gameplay.
@export var fur_lod: bool = true:
	set(v):
		fur_lod = v
		_set_fur_all(&"lod_enabled", v)

## Distance (m) at which LOD reduction begins.
@export_range(0.0, 20.0, 0.1) var fur_lod_min: float = 3.0:
	set(v):
		fur_lod_min = v
		_set_fur_all(&"lod_min_distance", v)

## Distance (m) at which the lowest shell count (8) is reached.
@export_range(0.0, 100.0, 0.5) var fur_lod_max: float = 25.0:
	set(v):
		fur_lod_max = v
		_set_fur_all(&"lod_max_distance", v)

@export_subgroup("Physics")
## Enable spring-physics simulation — fur lags behind and bounces as the player moves.
@export var fur_physics: bool = true:
	set(v):
		fur_physics = v
		_set_fur_all(&"physics_enabled", v)

## Constant gravity force applied to all strands (world space).
## Default is zero; a small negative Y gives a drooping/heavy look.
@export var fur_gravity: Vector3 = Vector3.ZERO:
	set(v):
		fur_gravity = v
		_set_fur_all(&"gravity", v)

## Spring stiffness — how quickly strands return to rest. Higher = snappier.
@export_range(0.0, 200.0, 0.5) var fur_spring: float = 80.0:
	set(v):
		fur_spring = v
		_set_fur_all(&"spring_constant", v)

## Strand mass — higher = more inertia / slower to move and settle.
@export_range(0.01, 2.0, 0.01) var fur_mass: float = 0.15:
	set(v):
		fur_mass = v
		_set_fur_all(&"mass", v)

## Spring damping — higher = less oscillation after movement stops.
@export_range(0.0, 20.0, 0.1) var fur_damping: float = 3.0:
	set(v):
		fur_damping = v
		_set_fur_all(&"damping", v)

## Per-height bending stiffness — higher means tips bend more than roots.
@export_range(0.0, 4.0, 0.01) var fur_stiffness: float = 1.0:
	set(v):
		fur_stiffness = v
		_set_fur_all(&"stiffness", v)

## Max strand stretch ratio. 1.0 = rigid, higher values allow elastic elongation.
@export_range(1.0, 2.0, 0.01) var fur_stretch: float = 1.0:
	set(v):
		fur_stretch = v
		_set_fur_all(&"stretch", v)

## Scales how much rotational movement (turning) displaces the strands.
@export_range(0.0, 4.0, 0.01) var fur_rotation_scale: float = 1.0:
	set(v):
		fur_rotation_scale = v
		_set_fur_all(&"rotational_physics_scale", v)

@export_group("")

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var visual: MeshInstance3D = $Visual   # original capsule — hidden at runtime

var current_lane: int = 1
var target_lane: int = 1

# ── Character pivot nodes ─────────────────────────────────────────────────────
var _char_root:       Node3D = null
var _char_torso:      Node3D = null
var _char_head:       Node3D = null
var _char_l_hip:      Node3D = null
var _char_r_hip:      Node3D = null
var _char_l_knee:     Node3D = null
var _char_r_knee:     Node3D = null
var _char_l_shoulder: Node3D = null
var _char_r_shoulder: Node3D = null
var _char_l_elbow:    Node3D = null
var _char_r_elbow:    Node3D = null
var _char_tail_root:  Node3D = null
var _anim_time:       float  = 0.0
var _run_freq:        float  = 2.4
var _forward_speed_base: float = -1.0   # scene-authored forward_speed, captured once
var _char_root_base_y: float = 0.0
# Corner bank — raw -1..1 arc value set each frame by Section_BeatRunner3d
var _arc_bank_raw: float = 0.0
var _arc_bank:     float = 0.0   # smoothed, applied to _char_root.rotation_degrees.z
var _arc_raise:    float = 0.0   # smoothed Y lift — outer lane rises with the banked floor

# ── GLB character model (preferred; falls back to procedural pivot rig) ───────
var _char_model:          Node3D          = null
var _char_anim_player:    AnimationPlayer = null
# Which authored clips the character .glb ships ("Slide", "Jump", …). When a
# clip exists it OWNS the pose — the procedural root crouch/lean for that
# state is skipped so the authored animation shows exactly as made.
var _char_clip_owned:     Dictionary = {}
var _char_skeleton:       Skeleton3D      = null
var _using_glb_character: bool  = false
var _run_anim_length:     float = 1.0
var _slide_anim_length:   float = 0.0   # authored Slide clip length (s)
var _slide_anim_speed:    float = 1.0   # speed_scale chosen for the current slide
var _slide_visual_timer:  float = 0.0   # anim keeps playing this long AFTER the
										# gameplay slide window has already closed
var _so_fluffy_node:         Node       = null        # SO FLUFFY instance on Body mesh
var _so_fluffy_accent_nodes: Array[Node] = []         # SO FLUFFY on TailTip + WhiteFur

# ── Grind-rail system ─────────────────────────────────────────────────────────
## Emitted when the player presses jump while grinding. Section listens to this
## to register a spark catch attempt.
signal grind_tap_pressed

var _is_grinding:          bool  = false
var _grind_rail_available: bool  = false   # set each frame by Section_BeatRunner3d
var _grind_rail_x:         float = 0.0    # lateral offset of the grind rail (branches out)
var _grind_rail_height:    float = 0.0    # height the rail rises to at the player's position
var _grind_rail_roll:      float = 0.0    # body roll (radians) the rail imparts — corkscrews invert
var _grind_rail_pitch:     float = 0.0    # body pitch (radians) — loops flip the rider forward
var _grind_base_y:         float = 0.0    # floor Y captured when the player mounts the rail
var _grind_saved_mask:     int   = -1     # collision_mask saved while grinding (-1 = not grinding)

# ── WJ descent slide — jump locked while sliding down ───────────────────────
var _jump_locked: bool = false   # set by Section; prevents jumping off the WJ slide ramp

## Lock / unlock the jump action.  Called by Section_BeatRunner3d when the player
## enters / leaves the post-wall-jump descent slide.
func set_jump_locked(v: bool) -> void:
	_jump_locked = v

# ── Charge-tunnel free-slide (drop buildup) ───────────────────────────────────
# A separate movement sub-mode used only inside a "drop buildup". The lane snap is
# dropped: the player slides freely LEFT/RIGHT (horizontal only) to thread the hoop
# tunnel. Vertical stays normal (on the riser floor). Section_BeatRunner3d drives this.
var _charge_slide_active: bool  = false
var _charge_lateral:      float = 0.0     # free lateral offset from track centre (metres)
var _charge_max_lat:      float = 3.0     # clamp range for the free slide
var _charge_slide_speed:  float = 7.0     # lateral metres/second while steering

# ── Colour palette (wolf character) ──────────────────────────────────────────
var   _COL_FUR:       Color = Color(0.09, 0.08, 0.11, 1.0)   # dark charcoal-black  (GameConfig)
var   _COL_JACKET:    Color = Color(0.75, 0.112, 0.123, 1.0)  # red leather jacket   (GameConfig)
const _COL_PANTS:     Color = Color(0.11, 0.10, 0.13, 1.0)   # dark grey-black jeans
var   _COL_HAIR:      Color = Color(0.90, 0.74, 0.10, 1.0)   # golden-blonde hair   (GameConfig)
const _COL_COLLAR:    Color = Color(0.92, 0.92, 0.92, 1.0)   # white neck ruff
const _COL_CHEST_FUR: Color = Color(0.78, 0.78, 0.78, 1.0)   # lighter chest fur
const _COL_PAW:       Color = Color(0.07, 0.06, 0.09, 1.0)   # very dark paws/gloves
const _COL_EAR_INNER: Color = Color(0.55, 0.14, 0.14, 1.0)   # dark-pink inner ear
const _COL_TAIL_TIP:  Color = Color(0.86, 0.86, 0.86, 1.0)   # white tail tip
const _COL_EYE_L:     Color = Color(0.10, 0.55, 1.00, 1.0)   # blue left eye
const _COL_EYE_R:     Color = Color(0.60, 0.08, 0.92, 1.0)   # purple right eye
const _COL_BELT:      Color = Color(0.14, 0.11, 0.10, 1.0)   # dark belt strap
const _COL_BUCKLE:    Color = Color(0.76, 0.76, 0.76, 1.0)   # silver buckle
const _COL_NOSE:      Color = Color(0.04, 0.03, 0.05, 1.0)   # dark nose

var slide_timer: float = 0.0
var slide_cooldown_timer: float = 0.0
@export var slide_cooldown: float = 0.18
var song_time: float = 0.0

var last_left_song_t: float = -9999.0
var last_right_song_t: float = -9999.0
var last_jump_song_t: float = -9999.0
var last_slide_song_t: float = -9999.0
var last_wall_left_song_t: float  = -9999.0
var last_wall_right_song_t: float = -9999.0

# Input buffer: if LB/RB is pressed while airborne, queue it and fire on landing
const WALL_BUFFER_S: float = 0.22
var _buffered_wall_action: String = ""
var _wall_buffer_timer:    float  = 0.0

## Set true to freeze all player-driven input (e.g. during end screen).
## Scripted request_action() calls (celebration) still work.
var input_disabled: bool = false

# ── Path direction (set each frame by Section_BeatRunner3d) ───────────────────
## Pure current-segment forward — used for velocity and lateral correction.
var forward_dir: Vector3 = Vector3(0.0, 0.0, 1.0)
## Pure current-segment right — used for lateral offset calculation.
var right_dir:   Vector3 = Vector3(1.0, 0.0, 0.0)
## Blended visual forward — used ONLY for rotation.y / camera turning.
## Starts blending toward next segment 45 m before the junction so the body
## pre-rotates smoothly without affecting the physics movement direction.
var _visual_fwd: Vector3 = Vector3(0.0, 0.0, 1.0)
## World position of the track centreline at the player's path distance.
var _track_center: Vector3 = Vector3.ZERO

func _ready() -> void:
	# Apply user-chosen colours before building the character mesh
	_COL_JACKET = GameConfig.jacket_color
	_COL_FUR    = GameConfig.fur_color
	_COL_HAIR   = GameConfig.hair_color
	_ensure_runner_input_map()
	current_lane = clamp(current_lane, 0, lane_xs.size() - 1)
	target_lane = current_lane
	global_position.x = lane_xs[current_lane]
	rotation.y = atan2(_visual_fwd.x, _visual_fwd.z)   # face track start direction (+Z)
	_apply_capsule_height(stand_capsule_height)
	_build_character()


func set_song_time(t: float) -> void:
	song_time = t


## Called every frame by Section_BeatRunner3d to keep direction in sync with turns.
## fwd / rgt are the PURE current-segment vectors used for physics + lane correction.
## vis_fwd is the look-ahead-blended vector used only for camera/body rotation.
func set_forward_dir(fwd: Vector3, rgt: Vector3, vis_fwd: Vector3 = fwd) -> void:
	forward_dir = fwd
	right_dir   = rgt
	_visual_fwd = vis_fwd


## Called every frame to give the player the path centreline world position.
func set_track_center(tc: Vector3) -> void:
	_track_center = tc


## Called every frame by Section_BeatRunner3d with the arc bank value (-1..1).
## Positive = right turn, negative = left turn.  0 outside any arc.
func set_arc_bank(raw: float) -> void:
	_arc_bank_raw = raw


## Called every frame by Section_BeatRunner3d.
## available = true while the player can enter grind mode.
## rail_x = lateral offset of the rail (in track-right units, matches lane_xs scale).
func set_grind_rail(available: bool, rail_x: float, rail_height: float = 0.0, rail_roll: float = 0.0, rail_pitch: float = 0.0) -> void:
	_grind_rail_available = available
	_grind_rail_x         = rail_x
	_grind_rail_height    = rail_height
	_grind_rail_roll      = rail_roll
	_grind_rail_pitch     = rail_pitch
	# Force-exit grind if the rail disappears: end of segment, OR the player failed
	# (missed too many sparks) and the Section dropped them off the rail.
	if not available and _is_grinding:
		_is_grinding = false


## Returns true while the player is actively riding the grind rail.
func is_grinding() -> bool:
	return _is_grinding


## Enter / leave the charge-tunnel free-slide. While active the player ignores lanes and
## slides smoothly left/right (steered by runner_left / runner_right) within ±max_lat.
## On exit we snap the lane target to whatever lane the player ended up nearest, so play
## resumes cleanly on the drop.
func set_charge_slide(active: bool, max_lat: float = 3.0, slide_speed: float = 7.0) -> void:
	if active and not _charge_slide_active:
		# Seed the free lateral from the player's current position so it doesn't jump.
		_charge_lateral = clampf((global_position - _track_center).dot(right_dir), -max_lat, max_lat)
	if not active and _charge_slide_active:
		# Resume lane play at the nearest lane to where the slide left us.
		var best_i: int   = 0
		var best_d: float = INF
		for i in range(lane_xs.size()):
			var dd: float = absf(lane_xs[i] - _charge_lateral)
			if dd < best_d:
				best_d = dd
				best_i = i
		target_lane  = best_i
		current_lane = best_i
	_charge_slide_active = active
	_charge_max_lat      = max_lat
	_charge_slide_speed  = slide_speed


## Current free-slide lateral offset (metres from track centre). Used by the Section to
## test hoop-gap alignment for charge build.
func charge_lateral() -> float:
	return _charge_lateral


func is_charge_sliding() -> bool:
	return _charge_slide_active


# ── BPM-aware timing calibration ─────────────────────────────────────────────
func set_beat_duration(beat_s: float) -> void:
	if beat_s <= 0.0:
		return

	const REF_BEAT_S:       float = 0.50
	const BASE_SLIDE:       float = 0.28
	const BASE_COOLDOWN:    float = 0.18
	const BASE_GRAVITY:     float = 52.0
	const BASE_JUMP_V:      float = 11.4
	# Wall jump targets a fixed 1.5 m peak above each ledge at any BPM.
	# v = sqrt(2 * g * 1.5) at reference gravity → sqrt(2 * 52 * 1.5) ≈ 12.49
	const BASE_WALL_JUMP_V: float = 13.68  # sqrt(2 * 52 * 1.8) — 1.8 m peak (was 1.5 m)

	var ratio: float = clamp(beat_s / REF_BEAT_S, 0.40, 1.60)

	slide_duration = clamp(BASE_SLIDE    * ratio, 0.13, 0.35)
	slide_cooldown = clamp(BASE_COOLDOWN * ratio, 0.07, 0.25)

	# Scale gravity and all jump velocities together so peak height stays
	# constant at every BPM.  Formula: peak = v² / (2g), kept constant when
	# both v and g scale by the same factor (v /= j, g /= j²  → peak unchanged).
	var j: float = clamp(ratio, 0.45, 1.50)
	gravity            = BASE_GRAVITY     / (j * j)
	jump_velocity      = BASE_JUMP_V      / j
	wall_jump_velocity = BASE_WALL_JUMP_V / j

	var song_bpm: float = 60.0 / beat_s

	# Track speed: authored forward_speed at forward_speed_ref_bpm, then
	# proportional to tempo. This MUST happen here — set_beat_duration runs
	# before any time→distance conversion, so gates, WJ spacing, rails and
	# the whole path are laid out with the scaled speed and stay in sync.
	# Scaling from a captured base (never compounding) keeps it idempotent.
	if _forward_speed_base < 0.0:
		_forward_speed_base = forward_speed
	forward_speed = _forward_speed_base \
		* clampf(song_bpm / maxf(1.0, forward_speed_ref_bpm), 0.5, 2.0)

func _physics_process(delta: float) -> void:
	_poll_runner_inputs()

	# Ride the rail along its own 3D path — drop collisions while grinding so it can go
	# under / over / straight through the track; they restore the instant grind ends.
	if _is_grinding and _grind_saved_mask < 0:
		_grind_saved_mask = collision_mask
		collision_mask    = 0
	elif not _is_grinding and _grind_saved_mask >= 0:
		collision_mask    = _grind_saved_mask
		_grind_saved_mask = -1
		# Dropped off the rail — no rescue. Gravity takes over from wherever the trick
		# left us (off to the side, under the track, up high), so failing a grind means
		# you fall, and falling off the world fails the level (Section watches y < -12).

	if _is_grinding:
		# Rail-driven vertical motion: the rail can peel up into the air, so drive Y
		# toward its height (base floor + rail rise) instead of applying gravity.
		# Clamp the closing speed so a late mount onto a raised rail lifts smoothly
		# rather than snapping the player up instantly.
		velocity.y = clampf(((_grind_base_y + _grind_rail_height) - global_position.y) * 8.0, -22.0, 22.0)
	elif not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if velocity.y < 0.0:
			velocity.y = 0.0
		# Drain wall-jump input buffer on landing
		if _wall_buffer_timer > 0.0:
			_wall_buffer_timer -= delta
			if _wall_buffer_timer > 0.0 and _buffered_wall_action != "":
				# Execute the buffered press now that we're on the floor
				if _buffered_wall_action == "wall_left":
					velocity.y  = wall_jump_velocity
					target_lane = lane_xs.size() - 1
					last_wall_left_song_t = song_time
				else:
					velocity.y  = wall_jump_velocity
					target_lane = 0
					last_wall_right_song_t = song_time
				_buffered_wall_action = ""
				_wall_buffer_timer    = 0.0
		else:
			_wall_buffer_timer = 0.0

	if slide_timer > 0.0:
		slide_timer -= delta
		if slide_timer <= 0.0:
			_apply_capsule_height(stand_capsule_height)

	# Purely cosmetic — the capsule is already standing again by now.
	if _slide_visual_timer > 0.0:
		_slide_visual_timer -= delta

	if slide_cooldown_timer > 0.0:
		slide_cooldown_timer -= delta

	# ── Charge-tunnel free-slide steer ───────────────────────────────────────
	# Continuous horizontal steering (no lane snap) while threading the hoop tunnel.
	if _charge_slide_active and not input_disabled:
		var steer: float = Input.get_action_strength("runner_left") - Input.get_action_strength("runner_right")
		_charge_lateral = clampf(_charge_lateral + steer * _charge_slide_speed * delta,
			-_charge_max_lat, _charge_max_lat)

	# ── Direction-aware lateral movement ─────────────────────────────────────
	# When grinding, lock to rail lateral; when charge-sliding, follow the free lateral;
	# otherwise snap toward the current lane.
	var target_lateral: float
	if _is_grinding:
		target_lateral = _grind_rail_x
	elif _charge_slide_active:
		target_lateral = _charge_lateral
	else:
		target_lateral = lane_xs[target_lane]
	var cur_lateral:    float = (global_position - _track_center).dot(right_dir)
	var dlateral:       float = (target_lateral - cur_lateral) * lane_lerp_speed
	velocity.x = forward_dir.x * forward_speed + right_dir.x * dlateral
	velocity.z = forward_dir.z * forward_speed + right_dir.z * dlateral

	move_and_slide()

	# ── Smooth body + camera rotation toward track forward direction ──────────
	# _visual_fwd is pre-blended toward the next segment (look-ahead), so the
	# body rotation anticipates the corner.  forward_dir stays pure so velocity
	# and lane correction are never affected by the visual blend.
	var target_y_rad: float = atan2(_visual_fwd.x, _visual_fwd.z)
	rotation.y = lerp_angle(rotation.y, target_y_rad, clampf(14.0 * delta, 0.0, 1.0))

	# Snap current_lane when close enough to target lateral position
	if abs((global_position - _track_center).dot(right_dir) - lane_xs[target_lane]) <= 0.15:
		current_lane = target_lane

	_anim_time += delta
	_update_character_anim(delta)

func _poll_runner_inputs() -> void:
	if input_disabled:
		return

	# ── Grind rail — handled before all other inputs ──────────────────────────
	# Enter grind = COMMIT: hold the trigger while on the floor near the rail. Once
	# you're on, there's no getting off — the rail locks you in until it ends.
	if _grind_rail_available and not _is_grinding:
		if Input.is_action_pressed("runner_grind") and is_on_floor() and not is_sliding():
			_is_grinding  = true
			_grind_base_y = global_position.y   # floor level the rail rises from
			# Cancel any buffered wall-jump so it can't fire the moment we land
			_buffered_wall_action = ""
			_wall_buffer_timer    = 0.0

	# Locked while grinding: releasing the trigger does NOT drop you. The grind ends
	# only when the Section marks the rail unavailable — segment end, or a fail
	# (too many missed sparks → dropped off the rail).
	if _is_grinding:
		if not _grind_rail_available:
			_is_grinding = false
		else:
			# Jump button = spark-catch tap; all other actions are blocked.
			if Input.is_action_just_pressed("runner_jump"):
				emit_signal("grind_tap_pressed")
			return   # no lane/jump/slide/wall-jump inputs during grind

	# Charge-tunnel free-slide: horizontal steer only (integrated in _physics_process).
	# Block lane/jump/slide/wall-jump so the player can ONLY thread the hoop tunnel.
	if _charge_slide_active:
		return

	# ── Normal runner inputs ───────────────────────────────────────────────────
	if Input.is_action_just_pressed("runner_left"):
		request_action("right")
	if Input.is_action_just_pressed("runner_right"):
		request_action("left")
	if Input.is_action_just_pressed("runner_jump"):
		request_action("jump")
	if Input.is_action_just_pressed("runner_slide"):
		request_action("slide")
	if Input.is_action_just_pressed("runner_lb"):
		request_action("wall_left")
	if Input.is_action_just_pressed("runner_rb"):
		request_action("wall_right")

func request_action(action: String) -> void:
	match action:
		"left":
			if target_lane > 0:
				target_lane -= 1
			last_left_song_t = song_time

		"right":
			if target_lane < lane_xs.size() - 1:
				target_lane += 1
			last_right_song_t = song_time

		"jump":
			if is_on_floor() and not is_sliding() and not _jump_locked:
				velocity.y = jump_velocity
			last_jump_song_t = song_time

		"slide":
			if is_on_floor() and slide_cooldown_timer <= 0.0:
				slide_timer = slide_duration
				slide_cooldown_timer = slide_cooldown + slide_duration
				_apply_capsule_height(slide_capsule_height)
				_start_slide_anim()
			last_slide_song_t = song_time

		"wall_left":
			if _is_grinding:
				pass   # wall jumps are suppressed while grinding
			else:
				last_wall_left_song_t = song_time
				if is_on_floor():
					velocity.y  = wall_jump_velocity
					target_lane = lane_xs.size() - 1
					_buffered_wall_action = ""
					_wall_buffer_timer    = 0.0
				else:
					# Pressed while airborne — buffer it so it fires on landing
					_buffered_wall_action = "wall_left"
					_wall_buffer_timer    = WALL_BUFFER_S

		"wall_right":
			if _is_grinding:
				pass   # wall jumps are suppressed while grinding
			else:
				last_wall_right_song_t = song_time
				if is_on_floor():
					velocity.y  = wall_jump_velocity
					target_lane = 0
					_buffered_wall_action = ""
					_wall_buffer_timer    = 0.0
				else:
					_buffered_wall_action = "wall_right"
					_wall_buffer_timer    = WALL_BUFFER_S

func _apply_capsule_height(new_height: float) -> void:
	if collision_shape == null:
		return
	var shape: CapsuleShape3D = collision_shape.shape as CapsuleShape3D
	if shape == null:
		return
	shape.height = max(0.2, new_height)
	collision_shape.position.y = (shape.height * 0.5) + shape.radius

func is_sliding() -> bool:
	return slide_timer > 0.0


# The authored Slide clip is almost always longer than the gameplay slide window
# (slide_duration is rhythm-tight: 0.13–0.35 s). We used to squeeze the whole clip
# into that window, which made a long clip unreadably fast. It now plays at its
# AUTHORED speed — same as Jump — and simply outlives the window: the hitbox stands
# back up on time while the animation keeps playing its recovery. A following slide
# crossfades over whatever is left, exactly like a re-triggered jump.
# slide_anim_max_speed defaults to 1.0, i.e. compression off; raise it only if the
# full-length tail overstays, and it will then fit the clip into the earliest
# possible next slide (slide_duration + slide_cooldown) up to that ceiling.
func _start_slide_anim() -> void:
	if _slide_anim_length <= 0.0 or not _char_clip_owned.get("Slide", false):
		_slide_anim_speed   = 1.0
		_slide_visual_timer = 0.0
		return
	var budget: float = slide_duration + slide_cooldown
	_slide_anim_speed = clampf(_slide_anim_length / maxf(0.05, budget),
							   1.0, maxf(1.0, slide_anim_max_speed))
	_slide_visual_timer = _slide_anim_length / _slide_anim_speed

func is_airborne() -> bool:
	return not is_on_floor()

func runner_lane() -> int:
	return current_lane

func runner_target_lane() -> int:
	return target_lane

func matches_gate(action: String, required_lane: int, t_s: float, window_s: float = 0.16) -> bool:
	match action:
		"left":
			return runner_target_lane() == required_lane

		"right":
			return runner_target_lane() == required_lane

		"jump":
			if runner_target_lane() != required_lane:
				return false
			return is_airborne() or abs(last_jump_song_t - t_s) <= window_s

		"slide":
			if runner_target_lane() != required_lane:
				return false
			return is_sliding() or abs(last_slide_song_t - t_s) <= window_s

	return false


# ─────────────────────────────────────────────────────────────────────────────
# CHARACTER BUILDING
# Primary path: instance res://assets/SIAGCharacter.glb — the rigged SIAG model
# (Skeleton3D + AnimationPlayer with Idle/Run/Jump/Slide/Grind) produced by
# blender/siag_character_builder.py. Its local +Z is the character's front;
# with character_yaw_offset_deg = 0 that aligns with world +Z (gates), so the
# camera (behind the player, looking toward +Z) sees the character's back —
# matching the original convention below.
#
# Fallback path (_build_character_procedural): box-primitive character, used
# only if the GLB fails to load.
#   _char_root.rotation_degrees.y = 180°  →  local -Z faces world +Z (gates)
#   Camera is behind player at world -Z   →  it sees local +Z side (back/tail)
#   Left/right: local +X = world -X, local -X = world +X  (mirrored by 180° Y)
# All positions below are in _char_root-local space.
# ─────────────────────────────────────────────────────────────────────────────

# Emissive coloured box — the building block for every body part (fallback only).
func _cm(sz: Vector3, col: Color, emis: float = 1.2) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = sz; mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color        = col
	mat.emission_enabled    = true
	mat.emission            = col
	mat.emission_energy_multiplier = emis
	mi.material_override    = mat
	return mi


# Pivot at `pos` with one mesh child offset so the segment hangs from the pivot.
func _cp(pos: Vector3, sz: Vector3, col: Color, mesh_off: Vector3,
		 emis: float = 1.2) -> Node3D:
	var pivot := Node3D.new(); pivot.position = pos
	var mesh  := _cm(sz, col, emis); mesh.position = mesh_off
	pivot.add_child(mesh)
	return pivot


func _build_character() -> void:
	if visual != null:
		visual.visible = false

	var cap_shape: CapsuleShape3D = collision_shape.shape as CapsuleShape3D
	_char_root_base_y = cap_shape.radius if cap_shape != null else 0.0

	_char_root = Node3D.new()
	_char_root.position = Vector3(0.0, _char_root_base_y, 0.0)
	add_child(_char_root)

	var glb_scene: PackedScene = load("res://assets/SIAGCharacter.glb") as PackedScene
	if glb_scene != null:
		var model: Node3D = glb_scene.instantiate() as Node3D
		if model != null:
			_char_model = model
			_char_root.rotation_degrees.y = character_yaw_offset_deg
			_char_model.position = Vector3(0.0, character_y_offset, 0.0)
			_char_model.scale    = Vector3.ONE * character_scale
			_char_root.add_child(_char_model)

			_char_anim_player = _char_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
			_char_skeleton    = _char_model.find_child("Skeleton3D",      true, false) as Skeleton3D
			_using_glb_character = true

			_apply_character_colors()
			_attach_so_fluffy(_char_model)

			if _char_anim_player != null:
				for clip in ["Idle", "Run", "Jump", "Slide", "Grind"]:
					_char_clip_owned[clip] = _char_anim_player.has_animation(clip)
				if _char_clip_owned["Run"]:
					_run_anim_length = _char_anim_player.get_animation("Run").length
				if _char_clip_owned["Slide"]:
					var slide_clip: Animation = _char_anim_player.get_animation("Slide")
					_slide_anim_length = slide_clip.length
					# One-shot, explicitly: the visual tail detects "clip done" via
					# is_playing(), which never goes false on a looping clip.
					slide_clip.loop_mode = Animation.LOOP_NONE
				if _char_clip_owned["Idle"]:
					_char_anim_player.play("Idle")
			return

	# ── Fallback: GLB missing — build the original box-primitive character ───
	push_warning("[BeatRunnerPlayer] SIAGCharacter.glb not found — using procedural fallback character.")
	_char_root.rotation_degrees.y = 180.0
	_build_character_procedural()


# Duplicate and recolour the Body/Jacket/Hair materials on the GLB model so the
# GameConfig appearance settings applied in _ready() carry over to the rig.
func _apply_character_colors() -> void:
	if _char_model == null:
		return
	_override_mesh_albedo("Body",   _COL_FUR)
	_override_mesh_albedo("Jacket", _COL_JACKET)
	_override_mesh_albedo("Hair",   _COL_HAIR)


func _override_mesh_albedo(node_name: String, color: Color) -> void:
	var mesh_node: MeshInstance3D = _char_model.find_child(node_name, true, false) as MeshInstance3D
	if mesh_node == null or mesh_node.mesh == null:
		return
	for surf: int in mesh_node.mesh.get_surface_count():
		var mat: Material = mesh_node.get_active_material(surf)
		if mat == null:
			continue
		var new_mat: Material = mat.duplicate() as Material
		if new_mat is StandardMaterial3D:
			(new_mat as StandardMaterial3D).albedo_color = color
		mesh_node.set_surface_override_material(surf, new_mat)


func _set_fur_all(prop: StringName, val: Variant) -> void:
	# Applies a SO FLUFFY property to the body fur and both accent nodes in one call.
	if _so_fluffy_node and is_instance_valid(_so_fluffy_node):
		_so_fluffy_node.set(prop, val)
	for _n: Node in _so_fluffy_accent_nodes:
		if is_instance_valid(_n):
			_n.set(prop, val)


func _sync_fur_color() -> void:
	# Derives the SO FLUFFY highlight colour from the current game fur colour.
	# Called on startup and whenever the Body Colour sliders change.
	if _so_fluffy_node == null:
		return
	var s: float = lerp(_COL_FUR.s, 0.0, fur_desaturate)
	var v: float = clamp(lerp(_COL_FUR.v, 1.0, fur_highlight), 0.0, 1.0)
	_so_fluffy_node.albedo_color = Color.from_hsv(_COL_FUR.h, s, v)


func _sync_accent_color() -> void:
	# Derives the accent SO FLUFFY colour for TailTip + WhiteFur nodes.
	# Called on startup and whenever the Accent Colour sliders change.
	if _so_fluffy_accent_nodes.is_empty():
		return
	var base: Color = _COL_TAIL_TIP
	var s: float = lerp(base.s, 0.0, fur_accent_desaturate)
	var v: float = clamp(lerp(base.v, 1.0, fur_accent_highlight), 0.0, 1.0)
	var col: Color = Color.from_hsv(base.h, s, v)
	for _n: Node in _so_fluffy_accent_nodes:
		if is_instance_valid(_n):
			_n.albedo_color = col


func _attach_so_fluffy(model: Node3D) -> void:
	# SO FLUFFY shell-fur attached at runtime to Body, TailTip, and WhiteFur.
	# Blender particle/geometry-nodes hair can't survive glTF export, so we
	# recreate it here. Shape/physics params are shared; each mesh gets its own
	# colour. Tweak everything in the Inspector under the "Fur" export group.
	# NOTE: All three meshes need UV maps — re-export from Blender if fur looks wrong.
	_so_fluffy_accent_nodes.clear()

	# ── Helper: attach one SO FLUFFY node to a named mesh ──────────────────
	var _attach := func(mesh_name: String) -> Node:
		var mesh_node: MeshInstance3D = model.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh_node == null:
			push_warning("[BeatRunnerPlayer] SO FLUFFY skipped — no '%s' mesh found." % mesh_name)
			return null
		var node := preload("res://addons/so_fluffy/so_fluffy.gd").new()
		node.name = "SoFluffy"
		mesh_node.add_child(node)   # _ready() fires: mesh = get_parent()
		return node

	# ── Body (primary black fur) ────────────────────────────────────────────
	var body_node: Node = _attach.call("Body")
	if body_node == null:
		return
	_so_fluffy_node = body_node

	# ── Accent: TailTip + WhiteFur (shared lighter colour) ─────────────────
	for accent_name: String in ["TailTip", "WhiteFur"]:
		var accent_node: Node = _attach.call(accent_name)
		if accent_node != null:
			_so_fluffy_accent_nodes.append(accent_node)

	# ── Apply shape / physics to ALL nodes via _set_fur_all ────────────────
	_set_fur_all(&"number_of_shells",         GraphicsQuality.scale_fur_shells(fur_shells))
	# Spring physics pushes a shader parameter to EVERY shell of every fur node on
	# each physics tick whenever the fur is in motion. The lower tiers trade that
	# for static fur, which still reads as fur — it just does not sway.
	if not bool(GraphicsQuality.get_setting("fur_physics", true)):
		_set_fur_all(&"physics_enabled", false)
	_set_fur_all(&"length",                   fur_length)
	_set_fur_all(&"density",                  fur_density)
	_set_fur_all(&"scruffiness",              fur_scruffiness)
	_set_fur_all(&"thickness_scale",          fur_thickness)
	_set_fur_all(&"normal_strength",          fur_normal_strength)
	_set_fur_all(&"static_direction_local",   fur_static_local)
	_set_fur_all(&"render_skin",              fur_render_skin)
	_set_fur_all(&"curls_enabled",            fur_curls)
	_set_fur_all(&"curls_twist",              fur_curls_twist)
	_set_fur_all(&"curls_fill",               fur_curls_fill)
	_set_fur_all(&"lod_enabled",              fur_lod)
	_set_fur_all(&"lod_min_distance",         fur_lod_min)
	_set_fur_all(&"lod_max_distance",         fur_lod_max)
	_set_fur_all(&"physics_enabled",          fur_physics)
	_set_fur_all(&"gravity",                  fur_gravity)
	_set_fur_all(&"spring_constant",          fur_spring)
	_set_fur_all(&"mass",                     fur_mass)
	_set_fur_all(&"damping",                  fur_damping)
	_set_fur_all(&"stiffness",                fur_stiffness)
	_set_fur_all(&"stretch",                  fur_stretch)
	_set_fur_all(&"rotational_physics_scale", fur_rotation_scale)

	# ── Apply colours separately (body vs accent) ──────────────────────────
	_sync_fur_color()
	_sync_accent_color()


func _build_character_procedural() -> void:
	# ── FEET / PAWS ────────────────────────────────────────────────────────────
	# Large, slightly rounded-looking paws. Built on local -Z half so they
	# protrude forward (world +Z).  After 180° flip: local -Z → world +Z.
	for s: int in [-1, 1]:
		var px: float = s * 0.155
		# Main paw body
		var paw := _cm(Vector3(0.26, 0.18, 0.44), _COL_PAW, 0.4)
		paw.position = Vector3(px, 0.09, -0.06)   # local -Z = forward
		_char_root.add_child(paw)
		# Toe-ridge accent
		var toe := _cm(Vector3(0.22, 0.06, 0.10), _COL_PAW, 0.8)
		toe.position = Vector3(px, 0.03, -0.24)
		_char_root.add_child(toe)

	# ── LOWER LEGS (shins) ─────────────────────────────────────────────────────
	# Static shin pieces attached directly to root (knees animate the upper leg).
	# These stay planted; hips pivot above.
	for s: int in [-1, 1]:
		var shin := _cm(Vector3(0.20, 0.38, 0.20), _COL_PANTS, 0.3)
		shin.position = Vector3(s * 0.155, 0.38, 0.0)
		_char_root.add_child(shin)

	# ── UPPER LEGS — hip pivot → knee sub-pivot ────────────────────────────────
	_char_l_hip = _cp(Vector3(-0.155, 0.82, 0.0),
		Vector3(0.22, 0.36, 0.22), _COL_PANTS, Vector3(0.0, -0.18, 0.0))
	_char_root.add_child(_char_l_hip)

	_char_l_knee = _cp(Vector3(0.0, -0.36, 0.0),
		Vector3(0.20, 0.36, 0.20), _COL_PANTS, Vector3(0.0, -0.18, 0.0), 0.3)
	_char_l_hip.add_child(_char_l_knee)

	_char_r_hip = _cp(Vector3(0.155, 0.82, 0.0),
		Vector3(0.22, 0.36, 0.22), _COL_PANTS, Vector3(0.0, -0.18, 0.0))
	_char_root.add_child(_char_r_hip)

	_char_r_knee = _cp(Vector3(0.0, -0.36, 0.0),
		Vector3(0.20, 0.36, 0.20), _COL_PANTS, Vector3(0.0, -0.18, 0.0), 0.3)
	_char_r_hip.add_child(_char_r_knee)

	# ── BELT ───────────────────────────────────────────────────────────────────
	var hips_block := _cm(Vector3(0.48, 0.14, 0.24), _COL_PANTS)
	hips_block.position = Vector3(0.0, 0.88, 0.0)
	_char_root.add_child(hips_block)

	var belt := _cm(Vector3(0.50, 0.08, 0.26), _COL_BELT, 0.5)
	belt.position = Vector3(0.0, 0.94, 0.0)
	_char_root.add_child(belt)

	var buckle := _cm(Vector3(0.12, 0.08, 0.28), _COL_BUCKLE, 2.0)
	buckle.position = Vector3(0.0, 0.94, -0.01)   # local -Z = front of belt
	_char_root.add_child(buckle)

	# ── TAIL ───────────────────────────────────────────────────────────────────
	# Tail base is on local +Z (= world -Z = toward camera). Camera sees it ✓
	_char_tail_root = Node3D.new()
	_char_tail_root.position = Vector3(-0.05, 0.92, 0.14)
	_char_root.add_child(_char_tail_root)

	# Seg 1 — thick dark base sweeping up and back
	var t1 := _cm(Vector3(0.30, 0.26, 0.58), _COL_FUR, 0.5)
	t1.position = Vector3(-0.10, 0.08, 0.22)
	t1.rotation_degrees.x = -30.0
	_char_tail_root.add_child(t1)

	# Seg 2 — mid section curving downward
	var t2 := _cm(Vector3(0.24, 0.22, 0.50), _COL_FUR, 0.4)
	t2.position = Vector3(-0.22, -0.18, 0.54)
	t2.rotation_degrees.x = -10.0
	t2.rotation_degrees.z = 10.0
	_char_tail_root.add_child(t2)

	# Seg 3 — tip, lighter (dark-to-white gradient via two pieces)
	var t3 := _cm(Vector3(0.20, 0.18, 0.38), _COL_FUR.lerp(_COL_TAIL_TIP, 0.4), 0.6)
	t3.position = Vector3(-0.30, -0.34, 0.74)
	t3.rotation_degrees.x = 15.0
	t3.rotation_degrees.z = 14.0
	_char_tail_root.add_child(t3)

	var t4 := _cm(Vector3(0.18, 0.16, 0.32), _COL_TAIL_TIP, 1.0)
	t4.position = Vector3(-0.34, -0.44, 0.90)
	t4.rotation_degrees.x = 25.0
	t4.rotation_degrees.z = 16.0
	_char_tail_root.add_child(t4)

	# ── TORSO pivot ────────────────────────────────────────────────────────────
	_char_torso = Node3D.new()
	_char_torso.position = Vector3(0.0, 1.04, 0.0)
	_char_root.add_child(_char_torso)

	# Jacket body — slightly cropped, ends above belt
	var jacket_body := _cm(Vector3(0.48, 0.42, 0.26), _COL_JACKET)
	jacket_body.position = Vector3(0.0, 0.21, 0.0)
	_char_torso.add_child(jacket_body)

	# Back panel (slightly thicker at the back — local +Z = toward camera)
	var jacket_back := _cm(Vector3(0.46, 0.40, 0.06), _COL_JACKET, 1.0)
	jacket_back.position = Vector3(0.0, 0.21, 0.14)
	_char_torso.add_child(jacket_back)

	# White chest-fur patch (local -Z = front, visible when looking at the front)
	var chest := _cm(Vector3(0.20, 0.34, 0.28), _COL_CHEST_FUR, 0.9)
	chest.position = Vector3(0.0, 0.20, -0.01)
	_char_torso.add_child(chest)

	# Jacket lapels (two angled slim pieces at local -Z front)
	for ls: int in [-1, 1]:
		var lapel := _cm(Vector3(0.08, 0.28, 0.05), _COL_JACKET, 1.3)
		lapel.position = Vector3(ls * 0.11, 0.28, -0.14)
		lapel.rotation_degrees.z = ls * -20.0
		_char_torso.add_child(lapel)

	# Zipper strip (local -Z front centre, small bright line)
	var zip := _cm(Vector3(0.03, 0.26, 0.05), _COL_BUCKLE, 2.5)
	zip.position = Vector3(0.0, 0.25, -0.14)
	_char_torso.add_child(zip)

	# ── ARMS — shoulder pivot → elbow sub-pivot ────────────────────────────────
	# Red jacket sleeves, dark-fur forearms/paws.
	_char_l_shoulder = _cp(Vector3(-0.31, 0.38, 0.0),
		Vector3(0.18, 0.34, 0.18), _COL_JACKET, Vector3(0.0, -0.17, 0.0))
	_char_torso.add_child(_char_l_shoulder)

	_char_l_elbow = _cp(Vector3(0.0, -0.34, 0.0),
		Vector3(0.16, 0.32, 0.16), _COL_PAW, Vector3(0.0, -0.16, 0.0), 0.4)
	_char_l_shoulder.add_child(_char_l_elbow)

	_char_r_shoulder = _cp(Vector3(0.31, 0.38, 0.0),
		Vector3(0.18, 0.34, 0.18), _COL_JACKET, Vector3(0.0, -0.17, 0.0))
	_char_torso.add_child(_char_r_shoulder)

	_char_r_elbow = _cp(Vector3(0.0, -0.34, 0.0),
		Vector3(0.16, 0.32, 0.16), _COL_PAW, Vector3(0.0, -0.16, 0.0), 0.4)
	_char_r_shoulder.add_child(_char_r_elbow)

	# Jacket cuffs
	for s: int in [-1, 1]:
		var cuff := _cm(Vector3(0.19, 0.07, 0.19), _COL_JACKET, 1.5)
		cuff.position = Vector3(s * 0.31, 0.05, 0.0)
		_char_torso.add_child(cuff)

	# ── WHITE NECK RUFF ────────────────────────────────────────────────────────
	var ruff := _cm(Vector3(0.36, 0.22, 0.34), _COL_COLLAR, 1.4)
	ruff.position = Vector3(0.0, 0.50, 0.0)
	_char_torso.add_child(ruff)

	# ── HEAD pivot ─────────────────────────────────────────────────────────────
	_char_head = Node3D.new()
	_char_head.position = Vector3(0.0, 0.58, 0.0)
	_char_torso.add_child(_char_head)

	# Main skull — dark fur
	var skull := _cm(Vector3(0.32, 0.36, 0.32), _COL_FUR, 0.6)
	skull.position = Vector3(0.0, 0.18, 0.0)
	_char_head.add_child(skull)

	# Muzzle protrudes forward (local -Z = world +Z = toward gates)
	var muzzle := _cm(Vector3(0.20, 0.18, 0.16), _COL_FUR.lightened(0.08), 0.7)
	muzzle.position = Vector3(0.0, 0.10, -0.20)
	_char_head.add_child(muzzle)

	# Nose (tip of muzzle, darker)
	var nose := _cm(Vector3(0.07, 0.05, 0.04), _COL_NOSE, 0.3)
	nose.position = Vector3(0.0, 0.16, -0.29)
	_char_head.add_child(nose)

	# White muzzle patch
	var muz_patch := _cm(Vector3(0.16, 0.12, 0.18), _COL_CHEST_FUR, 0.7)
	muz_patch.position = Vector3(0.0, 0.06, -0.18)
	_char_head.add_child(muz_patch)

	# Eyes — heterochromia: blue left, purple right
	# In local space (before 180° root flip): left eye is at local -X → world +X.
	# From camera's POV (looking at back), world +X is camera's right.
	# This matches the reference art (blue eye on viewer's left when looking at face).
	var eye_l := _cm(Vector3(0.08, 0.08, 0.04), _COL_EYE_L, 6.0)
	eye_l.position = Vector3(-0.092, 0.22, -0.185)
	_char_head.add_child(eye_l)

	var eye_r := _cm(Vector3(0.08, 0.08, 0.04), _COL_EYE_R, 6.0)
	eye_r.position = Vector3(0.092, 0.22, -0.185)
	_char_head.add_child(eye_r)

	# Blonde hair — main swept block on top of skull
	var hair_main := _cm(Vector3(0.32, 0.12, 0.30), _COL_HAIR, 1.1)
	hair_main.position = Vector3(0.0, 0.39, 0.02)
	_char_head.add_child(hair_main)

	# Fringe sweeping forward and down over face (local -Z)
	var fringe_a := _cm(Vector3(0.28, 0.14, 0.12), _COL_HAIR, 1.0)
	fringe_a.position = Vector3(-0.02, 0.36, -0.18)
	fringe_a.rotation_degrees.x = 30.0
	_char_head.add_child(fringe_a)

	var fringe_b := _cm(Vector3(0.18, 0.10, 0.10), _COL_HAIR, 0.9)
	fringe_b.position = Vector3(0.06, 0.28, -0.20)
	fringe_b.rotation_degrees.x = 40.0
	_char_head.add_child(fringe_b)

	# Side hair tufts
	for s: int in [-1, 1]:
		var side_hair := _cm(Vector3(0.08, 0.18, 0.14), _COL_HAIR, 0.9)
		side_hair.position = Vector3(s * 0.19, 0.28, -0.06)
		_char_head.add_child(side_hair)

	# ── WOLF EARS ──────────────────────────────────────────────────────────────
	for s: int in [-1, 1]:
		# Outer dark ear — tall pointed
		var ear_out := _cm(Vector3(0.12, 0.28, 0.08), _COL_FUR, 0.6)
		ear_out.position = Vector3(s * 0.15, 0.50, 0.06)
		ear_out.rotation_degrees.z = s * -14.0
		_char_head.add_child(ear_out)
		# Inner ear — dark pinkish-red
		var ear_in := _cm(Vector3(0.07, 0.18, 0.04), _COL_EAR_INNER, 1.4)
		ear_in.position = Vector3(s * 0.15, 0.50, 0.02)
		ear_in.rotation_degrees.z = s * -14.0
		_char_head.add_child(ear_in)

	# ── CHAIN EARRING (right ear, local +X side) ───────────────────────────────
	var chain_a := _cm(Vector3(0.025, 0.08, 0.025), _COL_BUCKLE, 4.0)
	chain_a.position = Vector3(0.22, 0.36, 0.04)
	_char_head.add_child(chain_a)
	var chain_b := _cm(Vector3(0.025, 0.05, 0.025), _COL_BUCKLE, 3.0)
	chain_b.position = Vector3(0.225, 0.28, 0.04)
	_char_head.add_child(chain_b)


# ─────────────────────────────────────────────────────────────────────────────
# CHARACTER ANIMATION
# ─────────────────────────────────────────────────────────────────────────────

func _update_character_anim(_delta: float) -> void:
	if _char_root == null:
		return

	if _using_glb_character:
		_update_character_anim_glb(_delta)
	else:
		_update_character_anim_procedural(_delta)

	# ── Corner bank + outer-lane rise (suppressed during grind) ─────────────
	const CHAR_BANK_MAX_DEG: float = 7.0
	const CHAR_RAISE_MAX_M:  float = 0.30   # metres of Y lift at the outer lane peak
	if _is_grinding:
		# Decay residual bank so it's clean when we exit the grind
		_arc_bank  = lerpf(_arc_bank,  0.0, _delta * 5.0)
		_arc_raise = lerpf(_arc_raise, 0.0, _delta * 5.0)
		# Note: rotation_degrees.z is already set by the grind pose above — don't touch it here
	elif _arc_bank_raw != 0.0 and lane_xs.size() > 1:
		# Outer lane (same side as the turn) gets ×1.4 lean, inner gets ×0.6.
		var max_lane_abs: float = absf(lane_xs[lane_xs.size() - 1])
		var lane_norm:    float = lane_xs[current_lane] / max_lane_abs   # -1..1
		var lane_mod:     float = 1.0 + lane_norm * signf(_arc_bank_raw) * 0.4
		_arc_bank  = lerpf(_arc_bank,  _arc_bank_raw * CHAR_BANK_MAX_DEG * lane_mod, _delta * 5.0)
		# Rise: outer lane = positive raise, center = 0, inner = slight dip
		_arc_raise = lerpf(_arc_raise, -_arc_bank_raw * lane_norm * CHAR_RAISE_MAX_M, _delta * 5.0)
		_char_root.rotation_degrees.z  = _arc_bank
		_char_root.position.y         += _arc_raise
	else:
		_arc_bank  = lerpf(_arc_bank,  0.0, _delta * 5.0)
		_arc_raise = lerpf(_arc_raise, 0.0, _delta * 5.0)
		_char_root.rotation_degrees.z  = _arc_bank
		_char_root.position.y         += _arc_raise


# Drive the rigged model via baked AnimationPlayer clips. _char_root-level
# position/rotation tweaks mirror the procedural path's per-state body lean
# and vertical bob so the corner-bank block below behaves identically.
func _update_character_anim_glb(_delta: float) -> void:
	var on_floor: bool = is_on_floor()
	var sliding: bool  = is_sliding()
	var target_anim:  String = "Idle"
	var target_speed: float  = 1.0

	# ── Kill the cosmetic slide tail when it stops making sense ──────────────
	# Leaving the ground or hopping on a rail hands the body to another clip, and
	# a finished one-shot must not be re-triggered by the leftover timer.
	if _slide_visual_timer > 0.0 and not sliding:
		if not on_floor or _is_grinding:
			_slide_visual_timer = 0.0
		elif _char_anim_player != null \
		and _char_anim_player.current_animation == "Slide" \
		and not _char_anim_player.is_playing():
			_slide_visual_timer = 0.0

	# Authored clips own their pose: the procedural root crouch/lean below is
	# only a fallback for states the .glb doesn't ship. This is what lets an
	# authored Slide put the body as low as it wants — the old hard-coded
	# −0.5 m root shove would stack on top and squash it into the floor.
	if sliding or _slide_visual_timer > 0.0:
		target_anim = "Slide"
		if _char_clip_owned.get("Slide", false):
			_char_root.position.y         = _char_root_base_y
			_char_root.rotation_degrees.x = 0.0
			# Speed was chosen once, at slide start, by _start_slide_anim() — the
			# clip is allowed to run past the gameplay window rather than being
			# crushed into it. See that function for the reasoning.
			target_speed = _slide_anim_speed
		else:
			_char_root.position.y         = _char_root_base_y - 0.50
			_char_root.rotation_degrees.x = -10.0
	elif _is_grinding:
		target_anim = "Grind"
		var tg: float = _anim_time * _run_freq * TAU
		var g_owned: bool = _char_clip_owned.get("Grind", false)
		_char_root.position.y         = _char_root_base_y \
			+ (0.0 if g_owned else abs(sin(tg)) * -0.04)
		# Trick pitch/roll stay code-driven ALWAYS (they follow the rail);
		# only the static −3° base lean yields to an authored clip.
		_char_root.rotation_degrees.x = (0.0 if g_owned else -3.0) + rad_to_deg(_grind_rail_pitch)
		# +Z lean = into the track (inside). Rail is on the outside; lean away from it
		# for balance while the outside arm reaches out to grip it.
		_char_root.rotation_degrees.z = rad_to_deg(_grind_rail_roll)   # 0 normally; only corkscrews roll
	elif not on_floor:
		target_anim = "Jump"
		_char_root.position.y         = _char_root_base_y
		_char_root.rotation_degrees.x = 0.0 if _char_clip_owned.get("Jump", false) else -5.0
	else:
		target_anim  = "Run"
		# Authored Run clip: speed derived from the ACTUAL ground speed so the
		# feet cover run_stride_m per cycle — no slip, at any tempo (forward
		# speed is already BPM-scaled). Fallback: old footstep-frequency fit.
		target_speed = clampf(_run_anim_length * forward_speed
			/ maxf(0.5, run_stride_m), 0.25, 4.0) \
			if _char_clip_owned.get("Run", false) \
			else _run_anim_length * _run_freq
		var t: float = _anim_time * _run_freq * TAU
		_char_root.position.y         = _char_root_base_y \
			+ (0.0 if _char_clip_owned.get("Run", false) else abs(sin(t)) * -0.05)
		_char_root.rotation_degrees.x = 0.0

	if _char_anim_player == null:
		return
	if not _char_clip_owned.get(target_anim, false):
		return   # state clip not authored — procedural pose above covers it
	if _char_anim_player.current_animation != target_anim or not _char_anim_player.is_playing():
		# Crossfade so run flows INTO the slide (and back) instead of snapping;
		# jumps blend faster — they need to read instantly.
		_char_anim_player.play(target_anim, 0.08 if target_anim == "Jump" else 0.18)
	_char_anim_player.speed_scale = target_speed


func _update_character_anim_procedural(_delta: float) -> void:
	var t: float      = _anim_time * _run_freq * TAU
	var on_floor: bool = is_on_floor()
	var sliding: bool  = is_sliding()

	if sliding:
		# ── Slide pose: crouched, body angled forward ─────────────────────────
		_char_root.position.y     = _char_root_base_y - 0.50
		_char_root.rotation_degrees.x = -10.0

		if _char_torso != null:   _char_torso.rotation_degrees.x = -20.0
		if _char_l_hip  != null:  _char_l_hip.rotation_degrees.x  = -58.0
		if _char_r_hip  != null:  _char_r_hip.rotation_degrees.x  = -58.0
		if _char_l_knee != null:  _char_l_knee.rotation_degrees.x =  65.0
		if _char_r_knee != null:  _char_r_knee.rotation_degrees.x =  65.0
		if _char_l_shoulder != null: _char_l_shoulder.rotation_degrees.x = -32.0
		if _char_r_shoulder != null: _char_r_shoulder.rotation_degrees.x = -32.0
		if _char_l_elbow != null: _char_l_elbow.rotation_degrees.x = 22.0
		if _char_r_elbow != null: _char_r_elbow.rotation_degrees.x = 22.0
		if _char_head   != null:  _char_head.rotation_degrees.x    = 12.0
		if _char_tail_root != null: _char_tail_root.rotation_degrees.x = 15.0

	elif _is_grinding:
		# ── Grind pose: running, body leaning INTO the track while the outside arm reaches out to grip the rail ──
		var tg: float        = _anim_time * _run_freq * TAU
		var leg_swing: float = sin(tg) * 28.0
		var bob_y: float     = abs(sin(tg)) * -0.04

		_char_root.position.y         = _char_root_base_y + bob_y
		_char_root.rotation_degrees.x = -3.0 + rad_to_deg(_grind_rail_pitch)   # loops flip forward
		# +Z lean = into the track (inside); the rail sits on the outside edge, so the
		# body counterbalances away from it while the outside arm reaches out to grip it.
		_char_root.rotation_degrees.z = rad_to_deg(_grind_rail_roll)   # 0 normally; only corkscrews roll

		if _char_torso != null:
			_char_torso.rotation_degrees.x =  -6.0
			_char_torso.rotation_degrees.z =   7.0   # torso leans inside with body
		if _char_l_hip  != null:  _char_l_hip.rotation_degrees.x  =  leg_swing
		if _char_r_hip  != null:  _char_r_hip.rotation_degrees.x  = -leg_swing
		if _char_l_knee != null:  _char_l_knee.rotation_degrees.x = maxf(0.0, -leg_swing * 0.85 + 8.0)
		if _char_r_knee != null:  _char_r_knee.rotation_degrees.x = maxf(0.0,  leg_swing * 0.85 + 8.0)
		# Left arm: normal forward swing (counterbalance)
		if _char_l_shoulder != null:
			_char_l_shoulder.rotation_degrees.x = sin(tg + PI) * 22.0
			_char_l_shoulder.rotation_degrees.z = 0.0
		if _char_l_elbow != null:
			_char_l_elbow.rotation_degrees.x = 22.0
			_char_l_elbow.rotation_degrees.z =  0.0
		# Right arm: extended laterally, gripping the rail
		if _char_r_shoulder != null:
			_char_r_shoulder.rotation_degrees.x = -5.0
			_char_r_shoulder.rotation_degrees.z =  52.0   # arm out to right toward rail
		if _char_r_elbow != null:
			_char_r_elbow.rotation_degrees.x = -18.0
			_char_r_elbow.rotation_degrees.z =   0.0
		if _char_head != null:
			_char_head.rotation_degrees.x = 2.0
		if _char_tail_root != null:
			_char_tail_root.rotation_degrees.z = sin(tg * 0.8) * 5.0   # tail swings right
			_char_tail_root.rotation_degrees.x = 5.0

	elif not on_floor:
		# ── Jump pose: legs tucked, arms spread for balance ───────────────────
		_char_root.position.y     = _char_root_base_y
		_char_root.rotation_degrees.x = -5.0

		if _char_torso != null:   _char_torso.rotation_degrees.x = -8.0
		if _char_l_hip  != null:  _char_l_hip.rotation_degrees.x  = -42.0
		if _char_r_hip  != null:  _char_r_hip.rotation_degrees.x  = -42.0
		if _char_l_knee != null:  _char_l_knee.rotation_degrees.x =  52.0
		if _char_r_knee != null:  _char_r_knee.rotation_degrees.x =  52.0
		if _char_l_shoulder != null:
			_char_l_shoulder.rotation_degrees.x = 38.0
			_char_l_shoulder.rotation_degrees.z =  0.0
		if _char_r_shoulder != null:
			_char_r_shoulder.rotation_degrees.x = 38.0
			_char_r_shoulder.rotation_degrees.z =  0.0
		if _char_l_elbow != null:
			_char_l_elbow.rotation_degrees.x = -28.0
			_char_l_elbow.rotation_degrees.z =   0.0
		if _char_r_elbow != null:
			_char_r_elbow.rotation_degrees.x = -28.0
			_char_r_elbow.rotation_degrees.z =   0.0
		if _char_head   != null:  _char_head.rotation_degrees.x    = -10.0
		if _char_tail_root != null: _char_tail_root.rotation_degrees.x = -10.0

	else:
		# ── Run cycle ─────────────────────────────────────────────────────────
		var leg_swing:   float = sin(t) * 40.0
		var arm_swing:   float = sin(t + PI) * 30.0
		var elbow_ang:   float = 24.0 + sin(t) * 10.0
		var torso_sway:  float = sin(t * 2.0) * 0.6
		var bob_y:       float = abs(sin(t)) * -0.05
		var head_nod:    float = sin(t * 2.0) * 3.5
		var tail_wag:    float = sin(t * 0.8) * 8.0

		_char_root.position.y     = _char_root_base_y + bob_y
		_char_root.rotation_degrees.x = 0.0

		if _char_torso != null:
			_char_torso.rotation_degrees.x = -7.0   # constant forward lean
			_char_torso.rotation_degrees.z = torso_sway

		# Positive x-rotation: child pivot swings in local +X plane.
		# With root rotated 180°Y, this makes legs swing forward/back correctly.
		if _char_l_hip  != null:  _char_l_hip.rotation_degrees.x  =  leg_swing
		if _char_r_hip  != null:  _char_r_hip.rotation_degrees.x  = -leg_swing
		if _char_l_knee != null:  _char_l_knee.rotation_degrees.x = maxf(0.0, -leg_swing * 0.85 + 8.0)
		if _char_r_knee != null:  _char_r_knee.rotation_degrees.x = maxf(0.0,  leg_swing * 0.85 + 8.0)
		if _char_l_shoulder != null:
			_char_l_shoulder.rotation_degrees.x =  arm_swing
			_char_l_shoulder.rotation_degrees.z =  0.0
		if _char_r_shoulder != null:
			_char_r_shoulder.rotation_degrees.x = -arm_swing
			_char_r_shoulder.rotation_degrees.z =  0.0
		if _char_l_elbow != null:
			_char_l_elbow.rotation_degrees.x = elbow_ang
			_char_l_elbow.rotation_degrees.z = 0.0
		if _char_r_elbow != null:
			_char_r_elbow.rotation_degrees.x = elbow_ang
			_char_r_elbow.rotation_degrees.z = 0.0
		if _char_head   != null:  _char_head.rotation_degrees.x    = head_nod
		if _char_tail_root != null:
			_char_tail_root.rotation_degrees.z = tail_wag   # side wag
			_char_tail_root.rotation_degrees.x = 0.0


func _ensure_runner_input_map() -> void:
	# Actual key/button setup now lives in GameConfig (autoload — reachable
	# from the Options > Controls tab in the main menu too, where there's no
	# BeatRunnerPlayer instance). This keeps gameplay and the rebind UI on
	# the exact same InputMap state; see GameConfig.apply_all_control_bindings().
	GameConfig.apply_all_control_bindings()
