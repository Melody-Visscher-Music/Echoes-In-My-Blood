class_name CharacterPoses
extends RefCounted

## Builds animation clips for SIAGCharacter.glb in code.
##
## The .glb ships exactly three clips — Run, Jump and Slide. BeatRunnerPlayer
## asks for five (it also wants Idle and Grind), and the wall jump has always
## borrowed the ordinary Jump. The two missing states and a dedicated wall-jump
## launch are generated here instead, as real Animation resources added to the
## model's own AnimationLibrary, so AnimationPlayer crossfades them exactly like
## the authored ones.
##
## ── Rig conventions ──────────────────────────────────────────────────────────
## Every pose value below is EULER DEGREES RELATIVE TO THE BONE'S REST, which is
## the same space the authored clips work in. These were measured off Run / Jump
## / Slide rather than guessed, so generated poses sit in the same ranges as the
## hand-made ones:
##
##   thigh.L/R    X  leg swing.      negative = knee forward/up  (Run ±45, Jump tuck −110)
##   shin.L/R     X  knee bend.      positive = heel toward hips (Run 0…40, Jump 0…98)
##   foot.L/R     X  ankle.          negative = toe pointed      (Jump −40…0)
##   spine        X  forward bend    positive = curl forward     (Jump 0…45)
##                Y  twist
##   upper_arm    X  arm elevation.  −75 = hanging at the side (what every authored
##                                   clip holds), 0 = straight out sideways (rest is
##                                   a T-pose), positive = raised overhead
##                Y  swing fore/aft. Run ±55. L and R mirror in rest, so the SAME
##                                   value swings them in opposite world directions
##   forearm      Z  elbow bend.     MIRRORED SIGN: L bends negative, R positive
##                                   (Run holds L −55 / R +55)
##   neck / head  X  nod (positive = chin down), Y turn, Z tilt.
##                                   Untracked in every authored clip — the head is
##                                   welded to the chest today, so anything here is
##                                   new movement rather than a fight with the art.
##   tail.01/.03  Y  side wag (Run ±45)
##
## The tail and ears are deliberately NOT keyed in any generated clip: they are
## owned by the SpringBoneSimulator3D chains BeatRunnerPlayer installs, which run
## after the AnimationPlayer and would overwrite these anyway. Letting the springs
## have them is the point — they react to real motion instead of a fixed sine.

## A keyframe: time in seconds, plus a bone → Vector3(euler degrees vs rest) map.
## Bones left out of a frame simply have no key at that time, so a track only
## carries the bones that actually move in that clip.

# ── Shared building blocks ────────────────────────────────────────────────────

## Arms hanging at the sides, elbows lightly bent — the neutral every authored
## clip holds. Generated poses start from this so they blend cleanly into Run.
const ARMS_DOWN: Dictionary = {
	"upper_arm.L": Vector3(-75, 0, 0), "upper_arm.R": Vector3(-75, 0, 0),
	"forearm.L":   Vector3(0, 0, -55), "forearm.R":   Vector3(0, 0, 55),
}


## Merges pose dictionaries left to right; later entries win.
static func _merge(parts: Array) -> Dictionary:
	var out: Dictionary = {}
	for p: Dictionary in parts:
		for k: String in p:
			out[k] = p[k]
	return out


# ═════════════════════════════════════════════════════════════════════════════
# CLIP DEFINITIONS
# ═════════════════════════════════════════════════════════════════════════════

## IDLE — he does not have an "at rest". Weight shifting foot to foot, knees
## springing, head flicking around looking for the next thing to run at. Loops.
static func idle_frames() -> Array:
	return [
		[0.00, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-6, 0, 0),  "shin.L": Vector3(10, 0, 0),
			"thigh.R": Vector3(2, 0, 0),   "shin.R": Vector3(16, 0, 0),
			"spine":   Vector3(4, -6, 0),
			"neck":    Vector3(-2, -10, 0), "head": Vector3(0, -6, 4),
			"upper_arm.L": Vector3(-72, 6, 0), "upper_arm.R": Vector3(-78, -4, 0),
		}])],
		[0.30, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(2, 0, 0),   "shin.L": Vector3(20, 0, 0),
			"thigh.R": Vector3(-6, 0, 0),  "shin.R": Vector3(9, 0, 0),
			"spine":   Vector3(7, 5, 0),
			"neck":    Vector3(2, 8, 0),   "head": Vector3(-3, 5, -3),
			"upper_arm.L": Vector3(-78, -5, 0), "upper_arm.R": Vector3(-71, 7, 0),
		}])],
		[0.55, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-4, 0, 0),  "shin.L": Vector3(12, 0, 0),
			"thigh.R": Vector3(1, 0, 0),   "shin.R": Vector3(15, 0, 0),
			"spine":   Vector3(3, 0, 0),
			# A quick head snap the other way — the fidget that says "bored".
			"neck":    Vector3(-4, 14, 0), "head": Vector3(-2, 8, 5),
			"upper_arm.L": Vector3(-74, 2, 0), "upper_arm.R": Vector3(-75, 0, 0),
		}])],
		[0.85, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(1, 0, 0),   "shin.L": Vector3(17, 0, 0),
			"thigh.R": Vector3(-5, 0, 0),  "shin.R": Vector3(11, 0, 0),
			"spine":   Vector3(6, -4, 0),
			"neck":    Vector3(1, -6, 0),  "head": Vector3(-1, -4, -2),
			"upper_arm.L": Vector3(-77, -3, 0), "upper_arm.R": Vector3(-73, 4, 0),
		}])],
		# Close the loop exactly on frame 0 so there is no pop at the wrap.
		[1.10, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-6, 0, 0),  "shin.L": Vector3(10, 0, 0),
			"thigh.R": Vector3(2, 0, 0),   "shin.R": Vector3(16, 0, 0),
			"spine":   Vector3(4, -6, 0),
			"neck":    Vector3(-2, -10, 0), "head": Vector3(0, -6, 4),
			"upper_arm.L": Vector3(-72, 6, 0), "upper_arm.R": Vector3(-78, -4, 0),
		}])],
	]


## GRIND — crouched low over the rail, outside arm flung out for balance, inside
## arm tucked, knees deep and absorbing. Loops with a slow wobble so it reads as
## "holding a line at speed" rather than a frozen statue. The rail's pitch and
## roll are still applied on top at the root by the player script.
static func grind_frames() -> Array:
	return [
		[0.00, {
			"thigh.L": Vector3(-32, 0, 0), "shin.L": Vector3(58, 0, 0), "foot.L": Vector3(-14, 0, 0),
			"thigh.R": Vector3(-18, 0, 0), "shin.R": Vector3(44, 0, 0), "foot.R": Vector3(-8, 0, 0),
			"spine":   Vector3(20, -8, 0),
			"neck":    Vector3(-14, 6, 0), "head": Vector3(-6, 4, 0),
			# Outside (R) arm thrown out and back; inside (L) arm tucked across.
			"upper_arm.R": Vector3(-18, -34, 0), "forearm.R": Vector3(0, 0, 22),
			"upper_arm.L": Vector3(-62, 30, 0),  "forearm.L": Vector3(0, 0, -74),
		}],
		[0.45, {
			"thigh.L": Vector3(-27, 0, 0), "shin.L": Vector3(52, 0, 0), "foot.L": Vector3(-11, 0, 0),
			"thigh.R": Vector3(-23, 0, 0), "shin.R": Vector3(50, 0, 0), "foot.R": Vector3(-11, 0, 0),
			"spine":   Vector3(24, -4, 0),
			"neck":    Vector3(-17, 3, 0), "head": Vector3(-4, 2, 0),
			"upper_arm.R": Vector3(-12, -28, 0), "forearm.R": Vector3(0, 0, 16),
			"upper_arm.L": Vector3(-66, 26, 0),  "forearm.L": Vector3(0, 0, -68),
		}],
		[0.90, {
			"thigh.L": Vector3(-32, 0, 0), "shin.L": Vector3(58, 0, 0), "foot.L": Vector3(-14, 0, 0),
			"thigh.R": Vector3(-18, 0, 0), "shin.R": Vector3(44, 0, 0), "foot.R": Vector3(-8, 0, 0),
			"spine":   Vector3(20, -8, 0),
			"neck":    Vector3(-14, 6, 0), "head": Vector3(-6, 4, 0),
			"upper_arm.R": Vector3(-18, -34, 0), "forearm.R": Vector3(0, 0, 22),
			"upper_arm.L": Vector3(-62, 30, 0),  "forearm.L": Vector3(0, 0, -74),
		}],
	]


## WALL JUMP — the headline. Deliberately nothing like the ordinary Jump, which
## is a symmetric two-foot tuck. This is a one-footed kick off the wall:
##
##   coil    deep gather, curled forward, arms cocked back
##   explode legs snap straight, spine ARCHES BACK, both arms thrown overhead
##   twist   spine twists toward the destination wall, legs split, one knee up
##   reach   arms swing forward to meet the far wall, legs coming under
##   catch   settling back toward the run pose
##
## `mirror` flips the twist and the leading leg so the launch reads as going the
## other way. Positive spine Y and a leading LEFT knee is the un-mirrored form.
static func wall_jump_frames(mirror: bool) -> Array:
	var s: float = -1.0 if mirror else 1.0
	# Leading / trailing leg swap with the direction of travel.
	var lead: String  = "thigh.R" if mirror else "thigh.L"
	var lead_s: String = "shin.R" if mirror else "shin.L"
	var trail: String = "thigh.L" if mirror else "thigh.R"
	var trail_s: String = "shin.L" if mirror else "shin.R"

	return [
		# ── COIL — everything gathers down and forward
		[0.00, {
			lead:  Vector3(-52, 0, 0), lead_s:  Vector3(78, 0, 0),
			trail: Vector3(-30, 0, 0), trail_s: Vector3(62, 0, 0),
			"foot.L": Vector3(-6, 0, 0), "foot.R": Vector3(-6, 0, 0),
			"spine":  Vector3(30, -12 * s, 0),
			"neck":   Vector3(16, -8 * s, 0), "head": Vector3(6, -6 * s, 0),
			# Arms cocked back and low, ready to be thrown.
			"upper_arm.L": Vector3(-86, -38, 0), "forearm.L": Vector3(0, 0, -72),
			"upper_arm.R": Vector3(-86, -38, 0), "forearm.R": Vector3(0, 0, 72),
		}],
		# ── EXPLODE — full extension, back arched, arms flung overhead
		[0.11, {
			lead:  Vector3(14, 0, 0),  lead_s:  Vector3(4, 0, 0),
			trail: Vector3(-8, 0, 0),  trail_s: Vector3(10, 0, 0),
			"foot.L": Vector3(-34, 0, 0), "foot.R": Vector3(-34, 0, 0),
			"spine":  Vector3(-22, 6 * s, 0),
			"neck":   Vector3(-26, 4 * s, 0), "head": Vector3(-10, 3 * s, 0),
			# X positive = above horizontal. This is the shape the ordinary Jump
			# never makes, and it is what sells the clip at a glance.
			"upper_arm.L": Vector3(34, 26, 0), "forearm.L": Vector3(0, 0, -16),
			"upper_arm.R": Vector3(34, 26, 0), "forearm.R": Vector3(0, 0, 16),
		}],
		# ── TWIST — airborne, rotating toward the far wall, legs split
		[0.28, {
			lead:  Vector3(-66, 0, 0), lead_s:  Vector3(92, 0, 0),
			trail: Vector3(22, 0, 0),  trail_s: Vector3(18, 0, 0),
			"foot.L": Vector3(-26, 0, 0), "foot.R": Vector3(-26, 0, 0),
			"spine":  Vector3(-6, 38 * s, 0),
			"neck":   Vector3(-14, 26 * s, 0), "head": Vector3(-4, 18 * s, 8 * s),
			"upper_arm.L": Vector3(6, 54, 0),   "forearm.L": Vector3(0, 0, -34),
			"upper_arm.R": Vector3(-24, -46, 0), "forearm.R": Vector3(0, 0, 48),
		}],
		# ── REACH — arms come round to meet the wall, knees gathering
		[0.43, {
			lead:  Vector3(-44, 0, 0), lead_s:  Vector3(66, 0, 0),
			trail: Vector3(-12, 0, 0), trail_s: Vector3(38, 0, 0),
			"foot.L": Vector3(-14, 0, 0), "foot.R": Vector3(-14, 0, 0),
			"spine":  Vector3(12, 18 * s, 0),
			"neck":   Vector3(-4, 12 * s, 0), "head": Vector3(0, 8 * s, 0),
			"upper_arm.L": Vector3(-34, 44, 0), "forearm.L": Vector3(0, 0, -46),
			"upper_arm.R": Vector3(-40, 30, 0), "forearm.R": Vector3(0, 0, 40),
		}],
		# ── CATCH — back toward a runnable pose so the blend out is short
		[0.58, _merge([ARMS_DOWN, {
			lead:  Vector3(-24, 0, 0), lead_s:  Vector3(40, 0, 0),
			trail: Vector3(-8, 0, 0),  trail_s: Vector3(24, 0, 0),
			"foot.L": Vector3(-6, 0, 0), "foot.R": Vector3(-6, 0, 0),
			"spine":  Vector3(8, 4 * s, 0),
			"neck":   Vector3(-2, 3 * s, 0), "head": Vector3(0, 2 * s, 0),
		}])],
	]


## ROLL — the Slide replacement. The .glb ships a 0.92 s airborne 360° flip for
## "Slide": the hips lift 0.72 → 1.01 m and the whole body somersaults. It is a
## nice piece of animation and it is the wrong move — the gameplay slide window
## is 0.13–0.35 s, so the clip was simply left to outlive it three times over.
##
## This is a ground roll. The bones only make the BALL; the revolution itself is
## driven on _char_root by BeatRunnerPlayer, tied to slide_duration, so the
## tumble finishes exactly when the hitbox stands back up — at any BPM. Four keys:
##
##   drop  knees drive up, spine curls, chin tucks, arms fold in
##   ball  tightest point — the frame that reads as "roll"
##   open  legs reach out for the ground, arms start to unfold
##   catch back to something Run can blend out of in one crossfade
##
## The small spine/head Y through the middle takes him slightly over one
## shoulder rather than dead straight down the lane — the flourish is in the
## shape, not in extra length.
static func roll_frames() -> Array:
	return [
		# ── DROP
		[0.00, {
			"thigh.L": Vector3(-72, 0, 0), "shin.L": Vector3(74, 0, 0), "foot.L": Vector3(-20, 0, 0),
			"thigh.R": Vector3(-62, 0, 0), "shin.R": Vector3(64, 0, 0), "foot.R": Vector3(-18, 0, 0),
			"spine":   Vector3(40, 4, 0),
			"neck":    Vector3(14, 6, 0),  "head": Vector3(10, 4, 0),
			# Elbows folded hard: the hands come to the chest and stay out of the roll.
			"upper_arm.L": Vector3(-62, 0, 0), "forearm.L": Vector3(0, 0, -108),
			"upper_arm.R": Vector3(-62, 0, 0), "forearm.R": Vector3(0, 0, 108),
		}],
		# ── BALL
		[0.11, {
			"thigh.L": Vector3(-104, 0, 0), "shin.L": Vector3(96, 0, 0), "foot.L": Vector3(-30, 0, 0),
			"thigh.R": Vector3(-98, 0, 0),  "shin.R": Vector3(92, 0, 0), "foot.R": Vector3(-28, 0, 0),
			"spine":   Vector3(50, 8, 0),
			"neck":    Vector3(20, 10, 0),  "head": Vector3(14, 8, 0),
			"upper_arm.L": Vector3(-52, 0, 0), "forearm.L": Vector3(0, 0, -126),
			"upper_arm.R": Vector3(-52, 0, 0), "forearm.R": Vector3(0, 0, 126),
		}],
		# ── OPEN
		[0.21, {
			"thigh.L": Vector3(-46, 0, 0), "shin.L": Vector3(60, 0, 0), "foot.L": Vector3(-12, 0, 0),
			"thigh.R": Vector3(-30, 0, 0), "shin.R": Vector3(40, 0, 0), "foot.R": Vector3(-10, 0, 0),
			"spine":   Vector3(26, 3, 0),
			"neck":    Vector3(6, 4, 0),   "head": Vector3(4, 3, 0),
			"upper_arm.L": Vector3(-66, 0, 0), "forearm.L": Vector3(0, 0, -80),
			"upper_arm.R": Vector3(-66, 0, 0), "forearm.R": Vector3(0, 0, 80),
		}],
		# ── CATCH
		[0.30, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-20, 0, 0), "shin.L": Vector3(32, 0, 0), "foot.L": Vector3(-4, 0, 0),
			"thigh.R": Vector3(-6, 0, 0),  "shin.R": Vector3(16, 0, 0), "foot.R": Vector3(-4, 0, 0),
			"spine":   Vector3(10, 0, 0),
			"neck":    Vector3(0, 0, 0),   "head": Vector3(0, 0, 0),
		}])],
	]


## JUMP RISE — the first ~0.16 s off the ground. One-shot.
##
## The authored Jump opens with a −0.28 m crouch keyed on the root, which is
## dead on arrival: velocity.y is set on the same frame the clip starts, so the
## mesh sank while the body was already climbing. There is deliberately no
## anticipation here for that reason — he is extending from frame one, and the
## weight is sold by the legs snapping out rather than by a dip that arrives
## too late to mean anything.
##
## Deliberately one-sided: left arm punches overhead, right drives down and
## back, lead knee comes up. The authored clip was asymmetric too (thigh.R 155°
## against thigh.L 65°) but with no apparent intent, which read as sloppy rather
## than as style. Same asymmetry, aimed.
static func jump_rise_frames() -> Array:
	return [
		# ── LAUNCH — already extending
		[0.00, {
			"thigh.L": Vector3(-18, 0, 0), "shin.L": Vector3(30, 0, 0), "foot.L": Vector3(-18, 0, 0),
			"thigh.R": Vector3(24, 0, 0),  "shin.R": Vector3(8, 0, 0),  "foot.R": Vector3(-34, 0, 0),
			# Negative spine X = arched back. Full extension, the opposite of a tuck.
			"spine":   Vector3(-12, 8, 0),
			"neck":    Vector3(-14, 6, 0), "head": Vector3(-6, 4, 0),
			"upper_arm.L": Vector3(10, 20, 0),   "forearm.L": Vector3(0, 0, -30),
			"upper_arm.R": Vector3(-84, -20, 0), "forearm.R": Vector3(0, 0, 60),
		}],
		# ── DRIVE — the punch. X positive on upper_arm = above horizontal.
		[0.08, {
			"thigh.L": Vector3(-70, 0, 0), "shin.L": Vector3(84, 0, 0), "foot.L": Vector3(-26, 0, 0),
			"thigh.R": Vector3(10, 0, 0),  "shin.R": Vector3(20, 0, 0), "foot.R": Vector3(-30, 0, 0),
			"spine":   Vector3(-6, 12, 0),
			"neck":    Vector3(-10, 8, 0), "head": Vector3(-4, 6, 0),
			"upper_arm.L": Vector3(36, 26, 0),   "forearm.L": Vector3(0, 0, -16),
			"upper_arm.R": Vector3(-70, -14, 0), "forearm.R": Vector3(0, 0, 52),
		}],
		# ── SETTLE — lands exactly on jump_air_frames() key 0 so the crossfade
		# into the looping hold is invisible. Keep these two in sync by hand.
		[0.16, {
			"thigh.L": Vector3(-92, 0, 0), "shin.L": Vector3(92, 0, 0), "foot.L": Vector3(-20, 0, 0),
			"thigh.R": Vector3(-34, 0, 0), "shin.R": Vector3(52, 0, 0), "foot.R": Vector3(-24, 0, 0),
			"spine":   Vector3(6, 10, 0),
			"neck":    Vector3(-4, 6, 0),  "head": Vector3(0, 5, 0),
			"upper_arm.L": Vector3(16, 20, 0),   "forearm.L": Vector3(0, 0, -40),
			"upper_arm.R": Vector3(-58, -10, 0), "forearm.R": Vector3(0, 0, 64),
		}],
	]


## JUMP AIR — the tucked hold. LOOPING.
##
## This clip is the reason the jump stops breaking. Real airtime is
## 2 × jump_velocity / gravity, which set_beat_duration scales to 0.20–0.66 s,
## and a rail drop has no upper bound at all. No fixed-length clip can cover
## that range: the authored 0.83 s somersault could not finish at ANY tempo, so
## he landed mid-rotation every single time. A loop stretches to fit anything.
##
## Nothing here rotates. The airborne flourish is a twist driven on _char_root
## from vertical velocity, which is exactly zero at touchdown by construction —
## see BeatRunnerPlayer._update_character_anim_glb().
static func jump_air_frames() -> Array:
	var hold: Dictionary = {
		"thigh.L": Vector3(-92, 0, 0), "shin.L": Vector3(92, 0, 0), "foot.L": Vector3(-20, 0, 0),
		"thigh.R": Vector3(-34, 0, 0), "shin.R": Vector3(52, 0, 0), "foot.R": Vector3(-24, 0, 0),
		"spine":   Vector3(6, 10, 0),
		"neck":    Vector3(-4, 6, 0),  "head": Vector3(0, 5, 0),
		"upper_arm.L": Vector3(16, 20, 0),   "forearm.L": Vector3(0, 0, -40),
		"upper_arm.R": Vector3(-58, -10, 0), "forearm.R": Vector3(0, 0, 64),
	}
	return [
		[0.00, hold],
		# Slow float — the knees trade a little and the arms breathe. Small on
		# purpose: this pose is on screen for anything from 3 frames to seconds.
		[0.20, {
			"thigh.L": Vector3(-80, 0, 0), "shin.L": Vector3(84, 0, 0), "foot.L": Vector3(-26, 0, 0),
			"thigh.R": Vector3(-46, 0, 0), "shin.R": Vector3(62, 0, 0), "foot.R": Vector3(-18, 0, 0),
			"spine":   Vector3(10, 6, 0),
			"neck":    Vector3(0, 4, 0),   "head": Vector3(2, 3, 0),
			"upper_arm.L": Vector3(10, 16, 0),  "forearm.L": Vector3(0, 0, -48),
			"upper_arm.R": Vector3(-64, -6, 0), "forearm.R": Vector3(0, 0, 58),
		}],
		# Closes exactly on key 0 — no pop at the wrap.
		[0.40, hold],
	]


## JUMP LAND — touchdown. One-shot, fired by the same impact the flair layer
## already detects. Reach, absorb, recover.
##
## The absorb is deliberately moderate: CharacterFlair adds its own land_fold to
## the spine (22° scaled by impact) on top of whatever plays here, so an
## aggressive fold in the clip stacks into a face-plant on a hard landing.
static func jump_land_frames() -> Array:
	return [
		# ── REACH — legs down, arms out to catch the balance
		[0.00, {
			"thigh.L": Vector3(-34, 0, 0), "shin.L": Vector3(40, 0, 0), "foot.L": Vector3(-6, 0, 0),
			"thigh.R": Vector3(-22, 0, 0), "shin.R": Vector3(30, 0, 0), "foot.R": Vector3(-6, 0, 0),
			"spine":   Vector3(14, 4, 0),
			"neck":    Vector3(2, 2, 0),   "head": Vector3(2, 0, 0),
			"upper_arm.L": Vector3(-46, 14, 0),  "forearm.L": Vector3(0, 0, -52),
			"upper_arm.R": Vector3(-50, -10, 0), "forearm.R": Vector3(0, 0, 50),
		}],
		# ── ABSORB — the knees eat the drop
		[0.07, {
			"thigh.L": Vector3(-58, 0, 0), "shin.L": Vector3(76, 0, 0), "foot.L": Vector3(-14, 0, 0),
			"thigh.R": Vector3(-50, 0, 0), "shin.R": Vector3(70, 0, 0), "foot.R": Vector3(-14, 0, 0),
			"spine":   Vector3(24, 2, 0),
			"neck":    Vector3(10, 0, 0),  "head": Vector3(6, 0, 0),
			"upper_arm.L": Vector3(-40, 22, 0),  "forearm.L": Vector3(0, 0, -70),
			"upper_arm.R": Vector3(-44, -16, 0), "forearm.R": Vector3(0, 0, 68),
		}],
		# ── RECOVER — one crossfade from Run
		[0.18, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-20, 0, 0), "shin.L": Vector3(30, 0, 0), "foot.L": Vector3(-4, 0, 0),
			"thigh.R": Vector3(-8, 0, 0),  "shin.R": Vector3(18, 0, 0), "foot.R": Vector3(-4, 0, 0),
			"spine":   Vector3(8, 0, 0),
			"neck":    Vector3(0, 0, 0),   "head": Vector3(0, 0, 0),
		}])],
	]


## ════════════════════════════════════════════════════════════════════════════
## ELECTRIC-ZONE VARIANTS
## ════════════════════════════════════════════════════════════════════════════
##
## In an electric zone the gates are live arcs and contact is death, not a bump.
## Every clip below is the survival read of a move that has a show-off version
## above it, and they differ on three rules:
##
##   1. NOTHING LEAVES THE SILHOUETTE. No arm above the head, no leg thrown out,
##      no yaw that swings a shoulder wide. The ordinary Jump punches an arm
##      overhead, which is exactly the limb that would touch an electric jump
##      gate's arc. Here both arms clamp to the chest.
##   2. SYMMETRIC. All the Y components are zero. Asymmetry is style, and style
##      is what he stops doing when the thing beside him can kill him.
##   3. SMALLER AND FASTER. Tighter tucks, deeper curls, shorter clips. He is
##      making himself into the smallest possible object and getting out.
##
## The root-level flourish is suppressed separately, in BeatRunnerPlayer: the
## airborne twist goes to zero (a twist is width) while the dive DEEPENS, and the
## roll loses its shoulder yaw and orbits lower. Pose and root motion have to
## agree or the clip fights the transform.

## The electric air tuck. Shared by JumpRiseElec's last key and JumpAirElec's
## first, the same contract the ordinary pair keeps — see jump_rise_frames().
const ELEC_TUCK: Dictionary = {
	"thigh.L": Vector3(-100, 0, 0), "shin.L": Vector3(100, 0, 0), "foot.L": Vector3(-26, 0, 0),
	"thigh.R": Vector3(-96, 0, 0),  "shin.R": Vector3(96, 0, 0),  "foot.R": Vector3(-26, 0, 0),
	# Curled forward, not arched. He is folding, not presenting.
	"spine":   Vector3(22, 0, 0),
	"neck":    Vector3(12, 0, 0),   "head": Vector3(8, 0, 0),
	# Elbows folded to the limit: hands at the chest, inside the silhouette.
	"upper_arm.L": Vector3(-58, 0, 0), "forearm.L": Vector3(0, 0, -118),
	"upper_arm.R": Vector3(-58, 0, 0), "forearm.R": Vector3(0, 0, 118),
}


## ROLL (ELECTRIC) — the survival roll. Same four beats as roll_frames() but
## tighter, faster and dead symmetric: no spine or head Y, so he goes straight
## under the bar instead of over a shoulder. Paired with a lower orbit
## (electric_roll_pivot_h) so the whole tumble sits closer to the floor.
static func roll_elec_frames() -> Array:
	return [
		# ── DIVE — already committed, no wind-up to spare
		[0.00, {
			"thigh.L": Vector3(-84, 0, 0), "shin.L": Vector3(84, 0, 0), "foot.L": Vector3(-24, 0, 0),
			"thigh.R": Vector3(-80, 0, 0), "shin.R": Vector3(82, 0, 0), "foot.R": Vector3(-24, 0, 0),
			"spine":   Vector3(46, 0, 0),
			"neck":    Vector3(20, 0, 0),  "head": Vector3(16, 0, 0),
			"upper_arm.L": Vector3(-58, 0, 0), "forearm.L": Vector3(0, 0, -118),
			"upper_arm.R": Vector3(-58, 0, 0), "forearm.R": Vector3(0, 0, 118),
		}],
		# ── BALL — tightest shape in the whole game
		[0.09, {
			"thigh.L": Vector3(-112, 0, 0), "shin.L": Vector3(104, 0, 0), "foot.L": Vector3(-34, 0, 0),
			"thigh.R": Vector3(-110, 0, 0), "shin.R": Vector3(102, 0, 0), "foot.R": Vector3(-34, 0, 0),
			"spine":   Vector3(56, 0, 0),
			"neck":    Vector3(26, 0, 0),   "head": Vector3(20, 0, 0),
			"upper_arm.L": Vector3(-46, 0, 0), "forearm.L": Vector3(0, 0, -134),
			"upper_arm.R": Vector3(-46, 0, 0), "forearm.R": Vector3(0, 0, 134),
		}],
		# ── OPEN — legs reach for the floor, arms stay in
		[0.18, {
			"thigh.L": Vector3(-50, 0, 0), "shin.L": Vector3(64, 0, 0), "foot.L": Vector3(-12, 0, 0),
			"thigh.R": Vector3(-40, 0, 0), "shin.R": Vector3(52, 0, 0), "foot.R": Vector3(-12, 0, 0),
			"spine":   Vector3(30, 0, 0),
			"neck":    Vector3(8, 0, 0),   "head": Vector3(6, 0, 0),
			"upper_arm.L": Vector3(-62, 0, 0), "forearm.L": Vector3(0, 0, -86),
			"upper_arm.R": Vector3(-62, 0, 0), "forearm.R": Vector3(0, 0, 86),
		}],
		# ── CATCH — up and running, no posing on the way out
		[0.26, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-18, 0, 0), "shin.L": Vector3(30, 0, 0), "foot.L": Vector3(-4, 0, 0),
			"thigh.R": Vector3(-6, 0, 0),  "shin.R": Vector3(16, 0, 0), "foot.R": Vector3(-4, 0, 0),
			"spine":   Vector3(8, 0, 0),
			"neck":    Vector3(0, 0, 0),   "head": Vector3(0, 0, 0),
		}])],
	]


## JUMP RISE (ELECTRIC) — 0.13 s, one-shot. Shorter and flatter than the
## ordinary launch: no arched back, no overhead punch. The arms drive DOWN and
## stay down, because on an electric jump gate the arc is above him and a raised
## hand is the first thing that would find it.
static func jump_rise_elec_frames() -> Array:
	return [
		# ── SNAP — straight up, nothing extended
		[0.00, {
			"thigh.L": Vector3(-12, 0, 0), "shin.L": Vector3(22, 0, 0), "foot.L": Vector3(-30, 0, 0),
			"thigh.R": Vector3(-8, 0, 0),  "shin.R": Vector3(18, 0, 0), "foot.R": Vector3(-30, 0, 0),
			"spine":   Vector3(-4, 0, 0),
			"neck":    Vector3(-6, 0, 0),  "head": Vector3(-2, 0, 0),
			"upper_arm.L": Vector3(-88, 0, 0), "forearm.L": Vector3(0, 0, -70),
			"upper_arm.R": Vector3(-88, 0, 0), "forearm.R": Vector3(0, 0, 70),
		}],
		# ── GATHER — knees come straight up under him
		[0.06, {
			"thigh.L": Vector3(-66, 0, 0), "shin.L": Vector3(82, 0, 0), "foot.L": Vector3(-30, 0, 0),
			"thigh.R": Vector3(-62, 0, 0), "shin.R": Vector3(78, 0, 0), "foot.R": Vector3(-30, 0, 0),
			"spine":   Vector3(8, 0, 0),
			"neck":    Vector3(2, 0, 0),   "head": Vector3(2, 0, 0),
			"upper_arm.L": Vector3(-72, 0, 0), "forearm.L": Vector3(0, 0, -96),
			"upper_arm.R": Vector3(-72, 0, 0), "forearm.R": Vector3(0, 0, 96),
		}],
		# ── into the hold, exactly
		[0.13, ELEC_TUCK],
	]


## JUMP AIR (ELECTRIC) — the survival hold. LOOPING, for the same reason the
## ordinary one loops: airtime is 0.20–0.66 s and unbounded off a rail, and no
## fixed clip covers that.
##
## This is the pose that has to be right, because it is the one he is actually
## wearing while he passes the arc. Knees to the chest, arms clamped in, chin
## down. The float is half the size of the ordinary one — he is holding still on
## purpose, not breathing.
static func jump_air_elec_frames() -> Array:
	return [
		[0.00, ELEC_TUCK],
		[0.18, {
			"thigh.L": Vector3(-94, 0, 0), "shin.L": Vector3(96, 0, 0), "foot.L": Vector3(-22, 0, 0),
			"thigh.R": Vector3(-102, 0, 0), "shin.R": Vector3(100, 0, 0), "foot.R": Vector3(-28, 0, 0),
			"spine":   Vector3(25, 0, 0),
			"neck":    Vector3(14, 0, 0),  "head": Vector3(9, 0, 0),
			"upper_arm.L": Vector3(-54, 0, 0), "forearm.L": Vector3(0, 0, -124),
			"upper_arm.R": Vector3(-54, 0, 0), "forearm.R": Vector3(0, 0, 124),
		}],
		[0.36, ELEC_TUCK],
	]


## JUMP LAND (ELECTRIC) — 0.14 s. Quicker than the ordinary landing and it does
## not open out: the arms stay tucked through the absorb, because he is still
## standing next to the thing that nearly killed him. Recovery only unfolds on
## the last key, where Run takes over anyway.
static func jump_land_elec_frames() -> Array:
	return [
		# ── REACH
		[0.00, {
			"thigh.L": Vector3(-36, 0, 0), "shin.L": Vector3(44, 0, 0), "foot.L": Vector3(-6, 0, 0),
			"thigh.R": Vector3(-32, 0, 0), "shin.R": Vector3(40, 0, 0), "foot.R": Vector3(-6, 0, 0),
			"spine":   Vector3(16, 0, 0),
			"neck":    Vector3(4, 0, 0),   "head": Vector3(3, 0, 0),
			"upper_arm.L": Vector3(-52, 0, 0), "forearm.L": Vector3(0, 0, -64),
			"upper_arm.R": Vector3(-52, 0, 0), "forearm.R": Vector3(0, 0, 64),
		}],
		# ── ABSORB
		[0.06, {
			"thigh.L": Vector3(-56, 0, 0), "shin.L": Vector3(72, 0, 0), "foot.L": Vector3(-12, 0, 0),
			"thigh.R": Vector3(-52, 0, 0), "shin.R": Vector3(68, 0, 0), "foot.R": Vector3(-12, 0, 0),
			"spine":   Vector3(26, 0, 0),
			"neck":    Vector3(10, 0, 0),  "head": Vector3(6, 0, 0),
			"upper_arm.L": Vector3(-46, 0, 0), "forearm.L": Vector3(0, 0, -76),
			"upper_arm.R": Vector3(-46, 0, 0), "forearm.R": Vector3(0, 0, 76),
		}],
		# ── RECOVER
		[0.14, _merge([ARMS_DOWN, {
			"thigh.L": Vector3(-18, 0, 0), "shin.L": Vector3(28, 0, 0), "foot.L": Vector3(-4, 0, 0),
			"thigh.R": Vector3(-6, 0, 0),  "shin.R": Vector3(16, 0, 0), "foot.R": Vector3(-4, 0, 0),
			"spine":   Vector3(6, 0, 0),
			"neck":    Vector3(0, 0, 0),   "head": Vector3(0, 0, 0),
		}])],
	]


## ════════════════════════════════════════════════════════════════════════════
## WALL-JUMP DESCENT RAMP
## ════════════════════════════════════════════════════════════════════════════
##
## The ramp used to be the one stretch of the song that asked for nothing — you
## rode it down and waited. It is a rhythm game, so it now carries spark taps on
## the beat, caught with the grind contract (hold the trigger, tap jump).
##
## It gets its own clips rather than borrowing Grind, because it is not a grind:
## there is no rail under him and nothing to balance ON. He is riding a steep
## surface with his weight BEHIND him and a hand trailing the deck — the shape a
## person makes going down something they do not entirely trust.

## The ride pose. Shared, so DescentPump ends exactly where Descent begins and
## the pump drops back into the ride with no seam. Same contract the jump pair
## keeps — see jump_rise_frames().
const DESCENT_RIDE: Dictionary = {
	"thigh.L": Vector3(-46, 0, 0), "shin.L": Vector3(70, 0, 0), "foot.L": Vector3(-16, 0, 0),
	"thigh.R": Vector3(-30, 0, 0), "shin.R": Vector3(52, 0, 0), "foot.R": Vector3(-10, 0, 0),
	# Negative spine X = leaning BACK. The body stays upright while the deck falls
	# away under it, so the lean is the only thing selling the slope.
	"spine":   Vector3(-14, 6, 0),
	# ...but the head goes the other way: chin down, reading the ramp ahead.
	"neck":    Vector3(14, -4, 0),  "head": Vector3(10, -3, 0),
	# Lead arm out wide for balance; trailing arm low and back, hand near the deck.
	"upper_arm.L": Vector3(-30, 34, 0),  "forearm.L": Vector3(0, 0, -40),
	"upper_arm.R": Vector3(-70, -30, 0), "forearm.R": Vector3(0, 0, 30),
}


## DESCENT — riding the ramp. LOOPING, because the ramp's length in seconds
## depends on the song's tempo and the run length rolled for the climb.
static func descent_frames() -> Array:
	return [
		[0.00, DESCENT_RIDE],
		# Weight trades between the legs and the shoulders counter-rock. Bigger
		# than the airborne float — he is working to stay on this thing.
		[0.30, {
			"thigh.L": Vector3(-34, 0, 0), "shin.L": Vector3(56, 0, 0), "foot.L": Vector3(-10, 0, 0),
			"thigh.R": Vector3(-44, 0, 0), "shin.R": Vector3(66, 0, 0), "foot.R": Vector3(-16, 0, 0),
			"spine":   Vector3(-10, -4, 0),
			"neck":    Vector3(16, 3, 0),  "head": Vector3(11, 2, 0),
			"upper_arm.L": Vector3(-24, 28, 0),  "forearm.L": Vector3(0, 0, -32),
			"upper_arm.R": Vector3(-76, -24, 0), "forearm.R": Vector3(0, 0, 38),
		}],
		[0.60, DESCENT_RIDE],
	]


## DESCENT PUMP — one per caught spark. A compress-and-extend, the same move a
## skater uses to pump a transition: it is what a player does with their body
## when they hit a beat, so it reads as the tap even though the tap is a button.
##
## Short on purpose (0.16 s). At a fast tempo the sparks are ~0.35 s apart, so
## anything longer would still be playing when the next one arrives.
static func descent_pump_frames() -> Array:
	return [
		# ── COMPRESS — down into the deck
		[0.00, {
			"thigh.L": Vector3(-62, 0, 0), "shin.L": Vector3(84, 0, 0), "foot.L": Vector3(-20, 0, 0),
			"thigh.R": Vector3(-56, 0, 0), "shin.R": Vector3(78, 0, 0), "foot.R": Vector3(-20, 0, 0),
			"spine":   Vector3(6, 4, 0),
			"neck":    Vector3(18, -2, 0), "head": Vector3(12, -2, 0),
			"upper_arm.L": Vector3(-40, 30, 0),  "forearm.L": Vector3(0, 0, -64),
			"upper_arm.R": Vector3(-78, -26, 0), "forearm.R": Vector3(0, 0, 50),
		}],
		# ── EXTEND — the pop. Legs drive out, chest opens, lead arm swings up.
		[0.07, {
			"thigh.L": Vector3(-18, 0, 0), "shin.L": Vector3(26, 0, 0), "foot.L": Vector3(-26, 0, 0),
			"thigh.R": Vector3(-12, 0, 0), "shin.R": Vector3(20, 0, 0), "foot.R": Vector3(-26, 0, 0),
			"spine":   Vector3(-20, 8, 0),
			"neck":    Vector3(6, -4, 0),  "head": Vector3(4, -3, 0),
			"upper_arm.L": Vector3(0, 40, 0),    "forearm.L": Vector3(0, 0, -20),
			"upper_arm.R": Vector3(-60, -34, 0), "forearm.R": Vector3(0, 0, 20),
		}],
		# ── back into the ride, exactly
		[0.16, DESCENT_RIDE],
	]


# ═════════════════════════════════════════════════════════════════════════════
# BUILDER
# ═════════════════════════════════════════════════════════════════════════════

## Turns a frame list into an Animation whose bone tracks match the ones the
## imported clips use.
##
## `skel_path` is the node path prefix the .glb's own tracks use (something like
## "SIAGCharacter/Skeleton3D"). It is read back off an existing clip rather than
## hardcoded, because it depends on how the model was named on export.
##
## Keys are authored relative to rest, so each one is baked as
## `rest_rotation * delta` — exactly how the authored clips store their values.
static func build(frames: Array, skel: Skeleton3D, skel_path: String,
		length: float, loop: bool) -> Animation:
	var anim := Animation.new()
	anim.length    = length
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE

	# One track per bone that appears anywhere in the clip.
	var tracks: Dictionary = {}   # bone name -> track index
	for f: Array in frames:
		for bone: String in (f[1] as Dictionary):
			if tracks.has(bone):
				continue
			if skel.find_bone(bone) < 0:
				push_warning("[CharacterPoses] no bone '%s' on this rig — skipped." % bone)
				continue
			var ti: int = anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(ti, NodePath("%s:%s" % [skel_path, bone]))
			# Cubic so a five-key clip still eases instead of ticking between poses.
			anim.track_set_interpolation_type(ti, Animation.INTERPOLATION_CUBIC)
			tracks[bone] = ti

	for f: Array in frames:
		var t: float = f[0]
		var pose: Dictionary = f[1]
		for bone: String in pose:
			if not tracks.has(bone):
				continue
			var bi: int = skel.find_bone(bone)
			var rest_q: Quaternion = skel.get_bone_rest(bi).basis.get_rotation_quaternion()
			var d: Vector3 = pose[bone]
			var delta_q := Quaternion(Basis.from_euler(Vector3(
				deg_to_rad(d.x), deg_to_rad(d.y), deg_to_rad(d.z))))
			anim.rotation_track_insert_key(tracks[bone], t, rest_q * delta_q)

	return anim


## Reads the "<node path>/Skeleton3D" prefix off any existing bone track, so the
## generated clips address the skeleton the same way the imported ones do.
## Returns "" when no rotation track can be found to learn from.
static func skeleton_track_prefix(ap: AnimationPlayer) -> String:
	for name in ap.get_animation_list():
		var a: Animation = ap.get_animation(name)
		for t in a.get_track_count():
			if a.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				continue
			var p: String = str(a.track_get_path(t))
			if ":" in p:
				return p.substr(0, p.rfind(":"))
	return ""
