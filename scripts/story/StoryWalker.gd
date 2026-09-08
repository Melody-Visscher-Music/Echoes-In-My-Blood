class_name StoryWalker
extends Node3D

## Meeko on the Story Mode map.
##
## This is NOT free-roam movement. The player picks a destination rift, the map
## hands this a finished list of waypoints, and Meeko walks himself there —
## Mario 3D World style. Nothing here reads the movement input actions on
## purpose: if a second thing could move him, the map's idea of "which node is
## Meeko standing on" would stop being true.
##
## ── Animation seam ───────────────────────────────────────────────────────────
## `walk_clips` is the hook for animation variety later: give it several walk
## cycles and _next_walk_clip() rotates through them, one per leg of a route, so
## a long walk across the city does not loop the same six frames the whole way.
## Today SIAGCharacter.glb ships no walk cycle at all, so the list falls back to
## the authored "Run" clip slowed to walking pace — and if the model is missing
## entirely, to a capsule that just slides. All three cases go through the same
## _play_move() / _play_idle() pair.
##
## TODO(anim): author Walk_A / Walk_B / Walk_Look clips on SIAGCharacter and put
## their names in `walk_clips`. Nothing else here has to change.

## Fired when Meeko reaches the end of the route he was given.
signal arrived(node_id: String)
## Fired each time he passes through an intermediate node on the way.
signal passed_through(node_id: String)

const CHARACTER_GLB: String = "res://assets/SIAGCharacter.glb"

## Metres per second on the map for a SHORT hop. Map travel is meant to feel
## brisk but readable.
@export var walk_speed: float = 20.0
## A cross-map trek is walked faster than a hop between two rifts in the same
## cluster. Routes here are not equal: stepping between rifts 2 and 3 is 12 m,
## while going from rift 5 back round to rift 6 crosses the whole city through
## the hub — over 200 m. At one flat speed the second one is a twenty-second
## wait for a menu action. Speed ramps to this multiple of walk_speed as a route
## approaches `long_route_m`, so short hops keep their weight and long ones stop
## being a loading screen with legs.
@export var long_route_boost: float = 1.7
## Route length, in metres, at which the boost is fully applied.
@export var long_route_m: float = 190.0
## How fast he turns to face the next leg, in turns-per-second-ish lerp weight.
@export var turn_rate: float = 9.0
## Metres of ground one full cycle of a walk clip should appear to cover — the
## same idea (and the same fix for foot-slip) as BeatRunnerPlayer.run_stride_m.
@export var stride_m: float = 6.0
## Meeko is drawn oversized on the map, like a piece on a board. At true scale
## and map distance he is about eight pixels tall and the player cannot find
## him; every world map in this genre cheats the same way.
@export var map_scale: float = 2.6

## Clip names tried, in order, for movement. First one the model owns wins.
## See the animation seam note above — this is the list to grow.
var walk_clips: PackedStringArray = PackedStringArray(["Walk", "Run"])
var idle_clip: String = "Idle"

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _using_glb: bool = false
var _clip_cursor: int = 0
var _current_clip: String = ""

var _route: PackedVector3Array = PackedVector3Array()
## Node id reached at each waypoint, or "" for a bend that is not a node. Kept
## parallel to `_route` so passing a node can be announced mid-walk.
var _route_ids: PackedStringArray = PackedStringArray()
var _leg: int = 0
## walk_speed with the long-route boost already folded in, for the current walk.
var _speed: float = 16.0
var _walking: bool = false
var _destination: String = ""
var _bob_t: float = 0.0


func setup(accent: Color) -> void:
	_build_character(accent)
	_play_idle()


func _build_character(accent: Color) -> void:
	# Everything hangs off a scaled pivot, so map_scale applies the same way to
	# the authored model and to the capsule fallback.
	var pivot := Node3D.new()
	pivot.name  = "Pivot"
	pivot.scale = Vector3.ONE * map_scale
	add_child(pivot)
	_build_contact_shadow(pivot)

	var glb: PackedScene = load(CHARACTER_GLB) as PackedScene
	if glb != null:
		var model: Node3D = glb.instantiate() as Node3D
		if model != null:
			_model = model
			pivot.add_child(_model)
			_anim = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
			_using_glb = true
			# The authored Run clip is exported one-shot; on the map it has to
			# loop for as long as the walk lasts. Same fix the runner applies.
			if _anim != null and _anim.has_animation("Run"):
				_anim.get_animation("Run").loop_mode = Animation.LOOP_LINEAR
			_ensure_idle_clip(_model.find_child("Skeleton3D", true, false) as Skeleton3D)
			return

	# TODO(art): fallback only — a capsule that slides along the route. It keeps
	# the map testable on a checkout without the character asset.
	push_warning("[StoryWalker] %s not found — using a placeholder capsule." % CHARACTER_GLB)
	var body := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.42
	mesh.height = 1.7
	body.mesh = mesh
	var m := StandardMaterial3D.new()
	m.albedo_color               = accent.lightened(0.25)
	m.emission_enabled           = true
	m.emission                   = accent
	m.emission_energy_multiplier = 0.7
	body.material_override = m
	body.position = Vector3(0.0, 0.85, 0.0)
	_model = body
	pivot.add_child(_model)


## SIAGCharacter.glb ships Run / Jump / Slide and no Idle, so standing still
## used to leave him in the rig's rest pose — which from a map camera reads as a
## T-posed starfish on the plaza. The runner already solves this by generating
## the missing clips out of CharacterPoses; the map borrows the same seam rather
## than inventing a second idle. Only Idle is generated here — the map has no use
## for grinds, wall jumps or the electric-zone variants.
func _ensure_idle_clip(skeleton: Skeleton3D) -> void:
	if _anim == null or skeleton == null or _anim.has_animation(idle_clip):
		return
	var prefix: String = CharacterPoses.skeleton_track_prefix(_anim)
	if prefix == "":
		push_warning("[StoryWalker] no bone tracks to learn the skeleton path from — no idle pose.")
		return
	var lib: AnimationLibrary = _anim.get_animation_library("")
	if lib == null:
		return
	lib.add_animation(idle_clip, CharacterPoses.build(
		CharacterPoses.idle_frames(), skeleton, prefix, 1.10, true))


## A dark disc under his feet. The map camera is far enough back that the sun
## shadow alone does not tie him to the ground, and losing track of the
## character on a level-select screen is the one thing that must not happen.
## TODO(art): replace with a proper blob-shadow decal.
func _build_contact_shadow(parent: Node3D) -> void:
	var shadow := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius      = 0.75
	mesh.bottom_radius   = 0.75
	mesh.height          = 0.04
	mesh.radial_segments = 16
	shadow.mesh = mesh
	var m := StandardMaterial3D.new()
	m.albedo_color  = Color(0.03, 0.03, 0.05, 0.42)
	m.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = m
	shadow.position = Vector3(0.0, 0.06, 0.0)
	parent.add_child(shadow)


# ── Travel ───────────────────────────────────────────────────────────────────

func is_walking() -> bool:
	return _walking


## Drops Meeko onto a node with no walk — used when the map first loads.
func snap_to(pos: Vector3, facing: Vector3 = Vector3.ZERO) -> void:
	_walking = false
	_route = PackedVector3Array()
	global_position = pos
	if facing.length_squared() > 0.001:
		rotation.y = atan2(facing.x, facing.z)
	_play_idle()


## Starts a walk. `points` is the full world-space polyline (waypoints(), which
## already folds in the authored bends); `ids` names the node reached at each
## point, or "" for a bend. Calling this mid-walk replaces the current route, so
## the player can re-target without waiting.
func walk(points: PackedVector3Array, ids: PackedStringArray, destination_id: String) -> void:
	if points.size() < 2:
		# Already there — still report an arrival so the caller's flow is the
		# same whether or not travel was needed.
		_destination = destination_id
		_finish()
		return
	_route = points
	_route_ids = ids
	_destination = destination_id
	_leg = 1
	global_position = points[0]
	_walking = true

	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	var t: float = clampf(total / maxf(1.0, long_route_m), 0.0, 1.0)
	_speed = walk_speed * lerpf(1.0, long_route_boost, t)

	_play_move()


func _physics_process(delta: float) -> void:
	if not _walking:
		if _using_glb:
			return
		# Placeholder capsule: a small idle bob, so it is obvious it is alive.
		_bob_t += delta
		if _model != null:
			_model.position.y = 0.85 + sin(_bob_t * 2.0) * 0.03
		return

	var target: Vector3 = _route[_leg]
	var to: Vector3 = target - global_position
	to.y = 0.0
	var dist: float = to.length()

	if dist <= _speed * delta:
		global_position = Vector3(target.x, global_position.y, target.z)
		var reached: String = _route_ids[_leg] if _leg < _route_ids.size() else ""
		_leg += 1
		if _leg >= _route.size():
			_finish()
			return
		if reached != "" and reached != _destination:
			passed_through.emit(reached)
			# One clip per leg, so a route through several nodes cycles through
			# whatever walk animations exist rather than looping one forever.
			_play_move()
		return

	var dir: Vector3 = to / dist
	global_position += dir * _speed * delta
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), clampf(turn_rate * delta, 0.0, 1.0))


func _finish() -> void:
	_walking = false
	_route = PackedVector3Array()
	_play_idle()
	arrived.emit(_destination)


# ── Animation seam ───────────────────────────────────────────────────────────

## The next movement clip the model actually owns, or "" when it owns none.
## Rotates through `walk_clips` so consecutive legs differ once more than one
## clip exists.
func _next_walk_clip() -> String:
	if _anim == null:
		return ""
	var owned := PackedStringArray()
	for clip_name: String in walk_clips:
		if _anim.has_animation(clip_name):
			owned.append(clip_name)
	if owned.is_empty():
		return ""
	var pick: String = owned[_clip_cursor % owned.size()]
	_clip_cursor += 1
	return pick


func _play_move() -> void:
	var clip: String = _next_walk_clip()
	if clip == "" or _anim == null:
		return
	_current_clip = clip
	# Ground-sync: one full cycle covers `stride_m` metres, so the feet keep up
	# with the speed actually being walked — including the long-route boost —
	# instead of skating.
	var length: float = maxf(0.05, _anim.get_animation(clip).length)
	_anim.play(clip, 0.25)
	_anim.speed_scale = clampf((_speed / maxf(0.1, stride_m)) * length, 0.35, 3.2)


func _play_idle() -> void:
	if _anim == null:
		return
	_anim.speed_scale = 1.0
	if _anim.has_animation(idle_clip):
		_current_clip = idle_clip
		_anim.play(idle_clip, 0.3)
		return
	# SIAGCharacter.glb ships no Idle clip — the runner builds one at load time
	# out of CharacterPoses. The map does not need that whole machinery, so
	# standing still just stops the walk cycle and leaves him in the rest pose.
	# TODO(anim): drop this branch once an authored Idle clip exists.
	_anim.stop()
	_current_clip = ""
