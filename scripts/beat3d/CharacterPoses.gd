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
