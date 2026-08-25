class_name LaserRig
extends Node3D

## Beat-driven laser fixtures lining the track.
##
## Design constraint: the track is tens of thousands of metres long, so placing
## a fixture every 25 m for a whole song would be thousands of nodes. Instead
## this is a fixed-size POOL — the same trick WorldFxPool uses — with one extra
## rule: slots are recycled by *path distance* rather than by lifetime. As the
## player advances, the slot holding the fixture furthest behind is picked up
## and re-seeded at the next unplaced distance ahead.
##
## That matters for how it looks, not just what it costs. A rig welded to the
## player would slide along with them and read as static; re-seeding by distance
## means beams genuinely rush past, so the parallax is real. Cost stays flat at
## `count` fixtures no matter how long the song is.
##
## Each fixture is three nodes deep, and the split is load-bearing:
##   pivot — positioned on the path and aligned to the track's forward vector
##   aim   — the sweep rotation, so animating it cannot disturb that alignment
##   beam  — the cone, offset up its own +Y so it emanates from the pivot origin
##
## The rig needs to know where the track goes, but the path lives in
## Section_BeatRunner3d. Rather than reach back into it, the two lookups are
## injected as Callables in setup().

const _SHADER: String = "res://shaders/world/laser_beam.gdshader"

## Distinct per fixture, cycled round-robin — the point of the effect is that
## no two neighbouring beams are the same colour.
const PALETTE: Array[Color] = [
	Color(1.00, 0.20, 0.62),   # hot pink
	Color(0.28, 0.80, 1.00),   # cyan
	Color(0.68, 0.22, 1.00),   # violet
	Color(1.00, 0.82, 0.16),   # gold
	Color(0.32, 1.00, 0.60),   # mint
	Color(1.00, 0.48, 0.14),   # orange
]

## Widest gap the rig will ever use, for low counts. The ACTUAL gap is derived
## from the fixture count in setup() — see _step.
@export var spacing: float      = 26.0    # metres between fixtures on one side
@export var spawn_ahead: float  = 240.0   # place fixtures this far in front
@export var keep_behind: float  = 40.0    # recycle once this far behind
@export var beam_len: float     = 46.0
@export var mount_height: float = 0.70   # head height above the track surface
@export var side_offset: float  = 1.6     # outboard of the track edge

var _pivots: Array[Node3D]         = []
var _aims:   Array[Node3D]         = []
var _mats:   Array[ShaderMaterial] = []
var _lens_mats: Array[ShaderMaterial] = []

var _slot_pd:   PackedFloat32Array = PackedFloat32Array()   # path distance per slot
var _slot_side: PackedInt32Array   = PackedInt32Array()     # -1 left, +1 right
var _phase:     PackedFloat32Array = PackedFloat32Array()   # per-fixture sweep offset
var _speed:     PackedFloat32Array = PackedFloat32Array()

## Distance between consecutive placements (sides alternate, so the gap on one
## side is twice this). Derived from the fixture count so that asking for more
## lasers makes them DENSER around the player rather than merely stretching the
## rig further into the fog.
##
## This is what made 30 feel like no more than 18: placements advanced by a
## fixed 13 m, so the rig filled spawn_ahead after ~21 fixtures and every
## fixture past that had nowhere left to go.
var _step: float = 13.0
var _lateral: float = 6.0
var _next_pd: float = 0.0
var _place_n: int   = 0     # placements so far — drives side alternation
var _beat_s:  float = 0.5
var _enabled: bool  = false

var _path_pos: Callable = Callable()
var _path_fwd: Callable = Callable()


## `count` fixtures total. `path_pos` takes (path_dist, lateral, height) and
## returns a world position; `path_fwd` takes (path_dist) and returns the
## track's forward vector there.
func setup(count: int, track_half_w: float, beat_s: float,
		path_pos: Callable, path_fwd: Callable, detail: int = 2) -> void:
	_path_pos = path_pos
	_path_fwd = path_fwd
	_beat_s   = maxf(beat_s, 0.12)
	_lateral  = track_half_w + side_offset
	# Spread the requested fixtures evenly across the whole live window, but
	# never further apart than `spacing` — a handful of lasers strung out over
	# hundreds of metres would read as nothing at all.
	_step = minf((spawn_ahead + keep_behind) / float(maxi(count, 1)), spacing * 0.5)
	_enabled  = count > 0 and not path_pos.is_null() and not path_fwd.is_null()
	if not _enabled:
		return

	# ── Shared geometry ──────────────────────────────────────────────────────
	# Every fixture is the same hardware, so all four meshes and the housing
	# material are built once and shared. Only the beam and lens materials are
	# per-fixture, because those carry the colour.
	var beam_mesh := CylinderMesh.new()
	beam_mesh.height          = beam_len
	beam_mesh.bottom_radius   = 0.07    # emitter end
	beam_mesh.top_radius      = 0.34    # spread at the far end
	beam_mesh.radial_segments = 6 if detail > 0 else 4
	beam_mesh.rings           = 1
	beam_mesh.cap_top         = false
	beam_mesh.cap_bottom      = false

	# Base plate — what actually reads as "bolted to the track".
	var base_mesh := CylinderMesh.new()
	base_mesh.height        = 0.05
	base_mesh.top_radius    = 0.17
	base_mesh.bottom_radius = 0.20
	base_mesh.radial_segments = 8 if detail > 0 else 6
	base_mesh.rings = 1

	# Post rising from the plate to the head.
	var post_mesh := CylinderMesh.new()
	post_mesh.height        = mount_height
	post_mesh.top_radius    = 0.045
	post_mesh.bottom_radius = 0.06
	post_mesh.radial_segments = 6 if detail > 0 else 4
	post_mesh.rings = 1

	# The moving head itself — a par-can body that swings with the beam.
	var can_mesh := CylinderMesh.new()
	can_mesh.height        = 0.26
	can_mesh.top_radius    = 0.135   # mouth, where the light leaves
	can_mesh.bottom_radius = 0.10
	can_mesh.radial_segments = 8 if detail > 0 else 6
	can_mesh.rings = 1

	# A slim lit band around the can. The level runs on 0.18 ambient, so a dark
	# metallic housing on its own would be a black silhouette — this is what
	# makes the hardware read as hardware instead of as a hole in the neon.
	var band_mesh := CylinderMesh.new()
	band_mesh.height        = 0.05
	band_mesh.top_radius    = 0.142
	band_mesh.bottom_radius = 0.142
	band_mesh.radial_segments = 8 if detail > 0 else 6
	band_mesh.rings = 1

	# The lens disc sitting in the mouth.
	var lens_mesh := CylinderMesh.new()
	lens_mesh.height        = 0.03
	lens_mesh.top_radius    = 0.125
	lens_mesh.bottom_radius = 0.125
	lens_mesh.radial_segments = 8 if detail > 0 else 6
	lens_mesh.rings = 1

	# Dark metal, shared by every post/base/can in the rig — one material means
	# the renderer can batch all 3 × count of them.
	var shell := StandardMaterial3D.new()
	shell.albedo_color = Color(0.055, 0.048, 0.078)
	shell.metallic     = 0.68
	shell.roughness    = 0.40

	# Where the beam actually starts: just past the lens, so it emerges from the
	# fixture rather than through the middle of it.
	var muzzle: float = 0.19

	for i in range(count):
		var col: Color = PALETTE[i % PALETTE.size()]

		var pivot := Node3D.new()
		pivot.visible = false
		add_child(pivot)

		# Base and post hang off the PIVOT, not the aim — the hardware stays
		# bolted upright while only the head swings. The pivot sits at head
		# height, so both hang below it.
		var base := MeshInstance3D.new()
		base.mesh = base_mesh
		base.material_override = shell
		base.position = Vector3(0.0, -mount_height, 0.0)
		base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(base)

		var post := MeshInstance3D.new()
		post.mesh = post_mesh
		post.material_override = shell
		post.position = Vector3(0.0, -mount_height * 0.5, 0.0)
		post.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(post)

		var aim := Node3D.new()
		pivot.add_child(aim)

		var can := MeshInstance3D.new()
		can.mesh = can_mesh
		can.material_override = shell
		can.position = Vector3(0.0, 0.06, 0.0)
		can.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		aim.add_child(can)

		# Glowing lens in the can's mouth, so the fixture reads as switched on
		# from any angle — including from behind, where the beam is edge-on.
		var lens_mat: ShaderMaterial = NeonMat.orb(col, 5.0)
		var lens := MeshInstance3D.new()
		lens.mesh = lens_mesh
		lens.material_override = lens_mat
		lens.position = Vector3(0.0, 0.175, 0.0)
		lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		aim.add_child(lens)

		# Shares the lens material, so it costs no extra material and pulses
		# with it for free.
		var band := MeshInstance3D.new()
		band.mesh = band_mesh
		band.material_override = lens_mat
		band.position = Vector3(0.0, 0.045, 0.0)
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		aim.add_child(band)

		var mi := MeshInstance3D.new()
		mi.mesh = beam_mesh
		# CylinderMesh straddles its own origin; shifting it half a length up
		# its +Y — plus the muzzle offset — puts the narrow end at the lens, so
		# the beam emerges from the fixture instead of out of thin air.
		mi.position    = Vector3(0.0, muzzle + beam_len * 0.5, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Pure light with no surface — skipping GI keeps beams out of the
		# SDFGI and reflection passes entirely.
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

		var mat := ShaderMaterial.new()
		mat.shader = load(_SHADER)
		mat.set_shader_parameter("tint",     col)
		mat.set_shader_parameter("beam_len", beam_len)
		mat.set_shader_parameter("energy",   3.2)
		mat.set_shader_parameter("detail",   detail)
		mat.set_shader_parameter("dust_amount", 0.38 if detail > 0 else 0.0)
		mi.material_override = mat
		aim.add_child(mi)

		_pivots.append(pivot)
		_aims.append(aim)
		_mats.append(mat)
		_lens_mats.append(lens_mat)
		_slot_pd.append(-1.0)
		_slot_side.append(1)
		_phase.append(randf() * TAU)
		# Sweep rate in beats, deliberately staggered per fixture so the rig
		# never falls into visible lockstep.
		_speed.append(0.55 + float(i % 5) * 0.17)


## Re-seeds any slot that has fallen behind, at the next unplaced distance
## ahead. Call once a frame with the player's current path distance.
func advance(player_pd: float) -> void:
	if not _enabled:
		return
	if _next_pd < player_pd:
		_next_pd = player_pd   # first frame, or after a seek

	# Bounded by the pool size: at most every slot can be re-seeded in one frame.
	var guard: int = _pivots.size()
	while _next_pd < player_pd + spawn_ahead and guard > 0:
		guard -= 1
		var slot: int = _oldest_slot(player_pd)
		if slot < 0:
			break                      # rig is full — everything is still ahead
		_seed_slot(slot, _next_pd)
		# Sides alternate per PLACEMENT, not per slot index: slots are recycled
		# in whatever order they fall behind, so keying off the index would let
		# one side starve.
		_next_pd += _step


## The slot holding the fixture furthest behind the player, or -1 if every slot
## is still in front of them.
func _oldest_slot(player_pd: float) -> int:
	var best: int = -1
	var best_pd: float = INF
	for i in range(_slot_pd.size()):
		var pd: float = _slot_pd[i]
		if pd < 0.0:
			return i                      # never placed — take it immediately
		if pd < player_pd - keep_behind and pd < best_pd:
			best_pd = pd
			best = i
	return best


func _seed_slot(i: int, pd: float) -> void:
	var side: int = 1 if _place_n % 2 == 0 else -1
	_place_n += 1

	var pos: Vector3 = _path_pos.call(pd, float(side) * _lateral, mount_height)
	var fwd: Vector3 = _path_fwd.call(pd)

	var pivot: Node3D = _pivots[i]
	pivot.position = pos
	pivot.visible  = true
	# Align to the track so the sweep below works in track-relative space even
	# through a 90° corner.
	if fwd.length_squared() > 0.0001:
		pivot.look_at(pos + fwd, Vector3.UP)

	_slot_pd[i]   = pd
	_slot_side[i] = side
	_phase[i]     = randf() * TAU


## Animates the sweep. `t` is song time, so the motion is locked to the music
## rather than to wall-clock or frame rate.
func tick(t: float, beat_phase: float) -> void:
	if not _enabled:
		return
	var beats: float = t / _beat_s
	var b: float = clampf(beat_phase, 0.0, 1.0)

	for i in range(_pivots.size()):
		if not _pivots[i].visible:
			continue
		var ph: float   = _phase[i]
		var sp: float   = _speed[i]
		var side: float = float(_slot_side[i])

		# Base pose: angled inward across the track and tilted up, the way a
		# real rig is hung — so the beams cross above the player instead of
		# running parallel down the sides.
		var yaw: float   =  side * (0.55 + sin(beats * sp + ph) * 0.42)
		var pitch: float = -1.05 + sin(beats * sp * 0.63 + ph * 1.7) * 0.30

		_aims[i].rotation = Vector3(pitch, yaw, 0.0)
		_mats[i].set_shader_parameter("beat", b)
		# The lens brightens with the beam, so the hardware reads as powered
		# rather than as a prop with a light stuck near it.
		NeonMat.set_energy(_lens_mats[i], 5.0 + b * 4.5)


## The rig is built before the chart has been parsed, so setup() only ever sees
## the default beat length. The real tempo arrives later — without this the
## sweep would run at a fixed 0.5 s beat regardless of what the song is doing,
## which is precisely the thing the effect is supposed to be locked to.
func set_beat(beat_s: float) -> void:
	_beat_s = maxf(beat_s, 0.12)


## Global brightness — lets the level dim the rig between drops, or kill it for
## a quality tier, without tearing the pool down.
func set_intensity(v: float) -> void:
	for m in _mats:
		m.set_shader_parameter("alpha", clampf(v, 0.0, 1.0))
