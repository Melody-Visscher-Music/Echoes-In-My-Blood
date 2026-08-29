class_name CharacterFlair
extends SkeletonModifier3D

## Procedural personality layer, applied on top of whatever clip is playing.
##
## Eight of the rig's 25 bones have no keys in ANY authored clip — chest, neck,
## head, both hands and tail.02/.04/.05. The head in particular is welded rigid
## to the chest for the entire game. This modifier owns those bones, plus small
## additive offsets on the ones the clips do drive, and turns "a model playing a
## run cycle" into a kid who cannot hold still.
##
## It is a SkeletonModifier3D specifically so it runs INSIDE the skeleton's
## update, after the AnimationPlayer has written its poses. Writing bone poses
## from _physics_process instead would fight the player and lose, or land a frame
## late depending on order.
##
## Everything here is ADDITIVE — it reads the pose the animation just wrote and
## multiplies a small delta onto it — so the authored art is never replaced, only
## seasoned. `influence` (inherited) scales the whole layer, and every effect has
## its own magnitude knob, so any of it can be dialled to zero without touching
## the rest.

# ── Motion inputs, pushed in each frame by BeatRunnerPlayer ───────────────────
var lateral_v:   float = 0.0   # signed lane-change speed, m/s
var vertical_v:  float = 0.0   # signed vertical velocity, m/s
var bank:        float = 0.0   # corner bank, -1..1 (positive = right turn)
var speed01:     float = 0.0   # 0..1 how fast he is going vs. the authored base
var airborne:    bool  = false
var beat:        float = 0.0   # 0..1, snaps to 1 on each beat and decays
var look_lateral: float = 0.0  # where the next gate is, -1..1 (negative = his left)
## 0..1 — how dangerous the surroundings are right now. BeatRunnerPlayer drives
## this to 1 inside an electric zone, where touching a gate kills rather than
## bumps. Everything it scales is personality: the fidget, the beat bop, the tail
## whip. He does not stop moving, he stops PLAYING — the loose, showing-off
## motion drains out and what is left is tense and small. See the Danger group.
var danger: float = 0.0

## Fires a landing recoil. Called by the player on the frame it touches down;
## the size scales with how hard the landing was.
func land(impact01: float) -> void:
	_land_t = clampf(impact01, 0.0, 1.0)

## Fires a lane-change snap — a quick weight-shift flick, direction-signed.
func lane_flick(dir: float) -> void:
	_flick = clampf(dir, -1.0, 1.0)

# ── Tuning ───────────────────────────────────────────────────────────────────
@export_group("Head")
## How far the head turns toward the upcoming gate. He reads the track ahead —
## this is the one trait the story actually hangs on, and the art cannot do it.
@export_range(0.0, 60.0, 1.0) var head_look_deg: float = 26.0
## How much the head stays level while the body banks through a corner. 1.0 =
## fully counter-rotates, which is what real runners do and what stops the whole
## character reading as one rigid tipping object.
@export_range(0.0, 1.5, 0.05) var head_level: float = 0.85
## Head snap on the beat. Small — it should be felt, not watched.
@export_range(0.0, 20.0, 0.5) var head_beat_deg: float = 6.5
## Constant low-level head drift, so he is never still even in a straight line.
@export_range(0.0, 15.0, 0.5) var head_fidget_deg: float = 4.0

@export_group("Body")
## Spine counter-rotation through corners — hips go with the turn, chest resists.
@export_range(0.0, 40.0, 1.0) var spine_bank_deg: float = 15.0
## Forward lean that grows with speed.
@export_range(0.0, 30.0, 1.0) var speed_lean_deg: float = 11.0
## Chest twist driven by lane changes — he throws a shoulder into the movement.
@export_range(0.0, 40.0, 1.0) var lane_twist_deg: float = 17.0
## Landing recoil: how deep the spine folds on touchdown.
@export_range(0.0, 45.0, 1.0) var land_fold_deg: float = 22.0

@export_group("Tail")
## The tail is 5 bones and the authored clips key only tail.01 and tail.03, only
## in Run — it is frozen solid through Jump, Slide and every generated clip.
##
## This is a hand-written spring rather than Godot's SpringBoneSimulator3D. That
## node does work, but on this rig it settles into a pose ~170 deg off the
## imported rest and periodically snaps a full 180, and it would not respond to
## stiffness/drag tuning across a 5x sweep. A bounded additive spring cannot flip
## by construction — every joint is hard-clamped below — which matters a lot more
## than physical accuracy for a tail that is on screen constantly.
@export_range(0.0, 60.0, 1.0) var tail_swing_deg: float = 32.0   # side whip
@export_range(0.0, 60.0, 1.0) var tail_lift_deg:  float = 24.0   # up/down on jumps
## Hard ceiling per joint. Nothing below can exceed this, in any state.
@export_range(1.0, 45.0, 1.0) var tail_max_deg:   float = 30.0
@export_range(1.0, 60.0, 0.5) var tail_spring_k:  float = 34.0
@export_range(0.1, 20.0, 0.1) var tail_damp:      float = 4.2

@export_group("Ears")
## Ears are keyed in Run only, static everywhere else. Small and quick — ears
## flick, they do not swing.
@export_range(0.0, 40.0, 1.0) var ear_flick_deg: float = 21.0
@export_range(1.0, 30.0, 1.0) var ear_max_deg:   float = 20.0
@export_range(1.0, 80.0, 0.5) var ear_spring_k:  float = 58.0
@export_range(0.1, 20.0, 0.1) var ear_damp:      float = 5.8

@export_group("Arms")
## Elbow follow-through — the forearm lags behind the upper arm instead of being
## welded to it. Run keys the forearms with a single static key, so without this
## he runs with locked elbows.
@export_range(0.0, 60.0, 1.0) var elbow_lag_deg: float = 26.0
## How fast the lag catches up. Lower = looser, floppier arms.
@export_range(1.0, 30.0, 0.5) var elbow_catchup: float = 9.0

@export_group("Danger")
## How much of the fidget and the beat bop survive at full danger. 0.15 leaves a
## trace so he still reads as alive rather than as a paused model.
@export_range(0.0, 1.0, 0.05) var danger_idle_left: float = 0.15
## Extra forward hunch at full danger. Small — the clips already curl him; this
## is the bit of tension that shows even between moves.
@export_range(0.0, 25.0, 0.5) var danger_hunch_deg: float = 6.0
## How far the ears pin back at full danger. This is the single clearest tell an
## animal has, and it costs one line.
@export_range(0.0, 1.5, 0.05) var danger_ear_pin: float = 0.9
## How much of the tail whip is held back at full danger. The tail tucks in
## rather than trailing wide where an arc could find it.
@export_range(0.0, 1.0, 0.05) var danger_tail_hold: float = 0.55

@export_group("")
## Master switch. Off = the authored clips play completely untouched.
@export var enabled: bool = true

# ── Internal state ───────────────────────────────────────────────────────────
var _t:        float = 0.0
var _land_t:   float = 0.0
var _flick:    float = 0.0
var _look_s:   float = 0.0   # smoothed look target
var _bank_s:   float = 0.0
var _danger_s: float = 0.0   # smoothed danger — zones start and end on a hard edge
var _lean_s:   float = 0.0
var _twist_s:  float = 0.0
var _elbow_l:  float = 0.0   # lagged upper-arm swing, per side
var _elbow_r:  float = 0.0
var _prev_arm_l: float = 0.0
var _prev_arm_r: float = 0.0

# Bone indices, resolved once. -1 = this rig does not have that bone, in which
# case every effect that needs it is skipped rather than erroring per frame.
var _b_spine:   int = -1
var _b_chest:   int = -1
var _b_neck:    int = -1
var _b_head:    int = -1
var _b_fore_l:  int = -1
var _b_fore_r:  int = -1
var _b_arm_l:   int = -1
var _b_arm_r:   int = -1
var _b_tail:    PackedInt32Array = PackedInt32Array()
var _b_ear_l:   int = -1
var _b_ear_r:   int = -1
var _resolved:  bool = false

# Spring state: position + velocity for the tail's two axes and the ears' one.
var _tx:  float = 0.0
var _txv: float = 0.0
var _ty:  float = 0.0
var _tyv: float = 0.0
var _ex:  float = 0.0
var _exv: float = 0.0

## Per-joint weighting down the tail. The base barely moves and the tip travels
## furthest, which is what makes a chain read as heavy rather than as five
## independent bones agreeing with each other.
const _TAIL_W: Array[float] = [0.35, 0.65, 0.90, 1.10, 1.25]


func _resolve(sk: Skeleton3D) -> void:
	_resolved = true
	_b_spine  = sk.find_bone("spine")
	_b_chest  = sk.find_bone("chest")
	_b_neck   = sk.find_bone("neck")
	_b_head   = sk.find_bone("head")
	_b_arm_l  = sk.find_bone("upper_arm.L")
	_b_arm_r  = sk.find_bone("upper_arm.R")
	_b_fore_l = sk.find_bone("forearm.L")
	_b_fore_r = sk.find_bone("forearm.R")
	_b_ear_l  = sk.find_bone("ear.L")
	_b_ear_r  = sk.find_bone("ear.R")
	_b_tail.clear()
	for n in ["tail.01", "tail.02", "tail.03", "tail.04", "tail.05"]:
		_b_tail.append(sk.find_bone(n))


## Critically-ish damped spring step. Returns [pos, vel].
static func _spring(pos: float, vel: float, target: float,
		k: float, damp: float, delta: float) -> Array:
	var v: float = vel + (target - pos) * k * delta
	v *= exp(-damp * delta)
	return [pos + v * delta, v]


## Multiplies a delta rotation onto whatever the animation already wrote for this
## bone. Additive by construction — read, compose, write back.
static func _add(sk: Skeleton3D, bone: int, euler_deg: Vector3, amount: float) -> void:
	if bone < 0 or is_zero_approx(amount):
		return
	var d := Vector3(deg_to_rad(euler_deg.x), deg_to_rad(euler_deg.y), deg_to_rad(euler_deg.z)) * amount
	if d.is_zero_approx():
		return
	sk.set_bone_pose_rotation(bone,
		sk.get_bone_pose_rotation(bone) * Quaternion(Basis.from_euler(d)))


func _process_modification_with_delta(delta: float) -> void:
	var sk: Skeleton3D = get_skeleton()
	if sk == null or not enabled:
		return
	if not _resolved:
		_resolve(sk)

	_t += delta
	var k: float = clampf(delta * 12.0, 0.0, 1.0)   # generic smoothing rate

	# Decay the one-shot impulses.
	_land_t = maxf(0.0, _land_t - delta * 3.4)
	_flick  = move_toward(_flick, 0.0, delta * 4.5)

	# Smooth every continuous input so a jittery frame can never snap the body.
	_look_s  = lerpf(_look_s,  clampf(look_lateral, -1.0, 1.0), k)
	_bank_s  = lerpf(_bank_s,  clampf(bank, -1.0, 1.0), k)
	# Slower than the rest: a zone boundary is a hard edge in the chart, and
	# snapping the whole body's demeanour on one frame reads as a glitch.
	_danger_s = lerpf(_danger_s, clampf(danger, 0.0, 1.0), clampf(delta * 3.5, 0.0, 1.0))
	# What survives of the loose, playful motion at the current danger level.
	var loose: float = lerpf(1.0, danger_idle_left, _danger_s)
	_lean_s  = lerpf(_lean_s,  clampf(speed01, 0.0, 1.0), clampf(delta * 3.0, 0.0, 1.0))
	_twist_s = lerpf(_twist_s, clampf(lateral_v / 6.0, -1.0, 1.0), k)

	# ── Spine / chest ────────────────────────────────────────────────────────
	# Hips already bank with the root; the chest resisting it is what makes the
	# turn read as a body leaning rather than a model being tilted.
	var land_curve: float = _land_t * _land_t
	_add(sk, _b_spine, Vector3(
		speed_lean_deg * _lean_s + land_fold_deg * land_curve
			+ danger_hunch_deg * _danger_s,
		# The shoulder-throw on a lane change is showmanship; it shrinks with the
		# rest of it, so he changes lane without swinging himself into the fence.
		lane_twist_deg * _twist_s * loose,
		0.0), 1.0)
	_add(sk, _b_chest, Vector3(
		-land_fold_deg * 0.45 * land_curve,
		lane_twist_deg * 0.55 * _twist_s,
		-spine_bank_deg * _bank_s), 1.0)

	# Airborne: tuck a little and keep the chest open, so a jump has shape even
	# when the authored clip has already finished playing.
	if airborne:
		_add(sk, _b_spine, Vector3(-6.0 * clampf(vertical_v / 10.0, -1.0, 1.0), 0.0, 0.0), 1.0)

	# ── Head ─────────────────────────────────────────────────────────────────
	# Counter the bank so the horizon stays put, turn toward the next gate, then
	# add the fidget on top. Split across neck and head so it bends rather than
	# swivelling like a turret.
	# The bop and the fidget are him enjoying himself. Both fade with danger; the
	# LOOK does not, because watching the next gate is the opposite of showing off
	# and is exactly what he would be doing.
	var beat_nod: float  = -head_beat_deg * beat * beat * loose
	var fidget_y: float  = (sin(_t * 2.3) * head_fidget_deg * 0.6
		+ sin(_t * 5.1) * head_fidget_deg * 0.25) * loose
	var fidget_x: float  = sin(_t * 3.7) * head_fidget_deg * 0.35 * loose
	var flick_y:  float  = _flick * 14.0

	_add(sk, _b_neck, Vector3(
		beat_nod * 0.6 + fidget_x * 0.5,
		head_look_deg * 0.55 * _look_s + fidget_y * 0.5 + flick_y * 0.5,
		spine_bank_deg * 0.30 * _bank_s * head_level), 1.0)
	_add(sk, _b_head, Vector3(
		beat_nod * 0.4 + fidget_x * 0.5 - land_fold_deg * 0.5 * land_curve,
		head_look_deg * 0.45 * _look_s + fidget_y * 0.5 + flick_y * 0.5,
		spine_bank_deg * 0.70 * _bank_s * head_level), 1.0)

	# ── Tail ─────────────────────────────────────────────────────────────────
	# The tail TRAILS the body: it lags behind a lane change and swings past it
	# on the way back, and it lifts when he drops and drops when he rises.
	# Targets are normalised to ±1 first so the clamps below are meaningful
	# regardless of how fast the song is running.
	var tail_target_x: float = clampf(-lateral_v / 7.0, -1.0, 1.0) + _flick * 0.7
	var tail_target_y: float = clampf(-vertical_v / 11.0, -1.0, 1.0)
	var sx: Array = _spring(_tx, _txv, tail_target_x, tail_spring_k, tail_damp, delta)
	_tx = sx[0]; _txv = sx[1]
	var sy: Array = _spring(_ty, _tyv, tail_target_y, tail_spring_k * 0.8, tail_damp, delta)
	_ty = sy[0]; _tyv = sy[1]

	for i in range(_b_tail.size()):
		var b: int = _b_tail[i]
		if b < 0:
			continue
		var w: float = _TAIL_W[i] if i < _TAIL_W.size() else 1.0
		# Y = side wag, X = lift/drop — the axes the authored Run clip uses.
		# Clamped per joint, so no combination of inputs can fold the tail over.
		_add(sk, b, Vector3(
			clampf(_ty * tail_lift_deg  * w, -tail_max_deg, tail_max_deg),
			clampf(_tx * tail_swing_deg * w * (1.0 - danger_tail_hold * _danger_s),
				-tail_max_deg, tail_max_deg),
			0.0), 1.0)

	# ── Ears ─────────────────────────────────────────────────────────────────
	# Driven off the same lateral impulse but much stiffer, plus a kick on
	# landing. Z is the flap axis and the two sides mirror.
	# Pinned flat at full danger. One line, and it is the loudest thing on him.
	var ear_target: float = clampf(-lateral_v / 9.0, -1.0, 1.0) + _flick * 0.5 \
		- land_curve * 0.8 - _danger_s * danger_ear_pin
	var se: Array = _spring(_ex, _exv, ear_target, ear_spring_k, ear_damp, delta)
	_ex = se[0]; _exv = se[1]
	var ear_deg: float = clampf(_ex * ear_flick_deg, -ear_max_deg, ear_max_deg)
	_add(sk, _b_ear_l, Vector3(ear_deg * 0.4, 0.0,  ear_deg), 1.0)
	_add(sk, _b_ear_r, Vector3(ear_deg * 0.4, 0.0, -ear_deg), 1.0)

	# ── Elbow follow-through ─────────────────────────────────────────────────
	# Track each upper arm's swing and let the forearm chase it. The gap between
	# the two IS the follow-through, so a fast arm throws a floppier elbow.
	if _b_arm_l >= 0 and _b_fore_l >= 0:
		var swing_l: float = sk.get_bone_pose_rotation(_b_arm_l).get_euler().y
		var kk: float = clampf(delta * elbow_catchup, 0.0, 1.0)
		_elbow_l = lerpf(_elbow_l, swing_l, kk)
		# Forearm elbow axis is Z, and the two sides are mirrored (see CharacterPoses).
		_add(sk, _b_fore_l, Vector3(0.0, 0.0, -elbow_lag_deg * clampf(swing_l - _elbow_l, -1.0, 1.0)), 1.0)
		_prev_arm_l = swing_l
	if _b_arm_r >= 0 and _b_fore_r >= 0:
		var swing_r: float = sk.get_bone_pose_rotation(_b_arm_r).get_euler().y
		var kk2: float = clampf(delta * elbow_catchup, 0.0, 1.0)
		_elbow_r = lerpf(_elbow_r, swing_r, kk2)
		_add(sk, _b_fore_r, Vector3(0.0, 0.0, elbow_lag_deg * clampf(swing_r - _elbow_r, -1.0, 1.0)), 1.0)
		_prev_arm_r = swing_r
