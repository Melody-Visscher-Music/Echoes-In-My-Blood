class_name StoryPathLink
extends Node3D

## One edge of the map graph, drawn as a dotted route through the streets.
##
## PLACEHOLDER ART: flat discs sampled along the polyline. Dots rather than a
## solid ribbon because the map camera sits far back — a dotted trail reads as a
## route at that distance, and it gives the reveal something to travel along.
##
## Two visual states, both muted enough that the rifts stay the brightest thing
## on screen:
##
##   * HIDDEN — either end is still locked. Not drawn at all.
##   * OPEN   — both ends are revealed. A calm trail with a slow highlight
##              running along it.
##
## On a reveal the trail plays a one-off travelling flare from the cleared node
## toward the newly opened one, then settles back to calm. That flare IS the
## "path lights up" beat in the design; it is driven by light_up(), which
## StoryMap calls right after it reveals the new rift.
##
## TODO(art): replace the discs with the authored route decal / trail VFX. The
## public surface (build, set_open, light_up) is what StoryMap uses.

## Metres between dots along the route.
const DOT_SPACING: float = 2.6
const DOT_RADIUS: float = 0.42
const CALM_ENERGY: float = 0.75
const FLARE_ENERGY: float = 5.0

var from_id: String = ""
var to_id: String = ""

var _accent: Color = Color(0.72, 0.30, 1.00)
var _dots: Array[MeshInstance3D] = []
var _mats: Array[StandardMaterial3D] = []
## Distance along the route for each dot, 0..1 — the wave and the flare both
## index the trail by this rather than by dot number, so spacing changes do not
## change how fast either travels.
var _dot_t: PackedFloat32Array = PackedFloat32Array()

var _open: bool = false
var _wave_t: float = 0.0
var _flare_head: float = -1.0   # < 0 = no flare running


## `points` is the full polyline for this edge, from the parent node to the
## child node, including any authored `via` bends.
func build(edge_from: String, edge_to: String, points: PackedVector3Array, accent: Color) -> void:
	from_id = edge_from
	to_id   = edge_to
	_accent = accent

	if points.size() < 2:
		return

	var dot_mesh := CylinderMesh.new()
	dot_mesh.top_radius      = DOT_RADIUS
	dot_mesh.bottom_radius   = DOT_RADIUS
	dot_mesh.height          = 0.12
	dot_mesh.radial_segments = 8
	dot_mesh.rings           = 1

	var total: float = _polyline_length(points)
	if total <= 0.001:
		return

	# Both endpoints sit under a rift, so the trail starts and stops short of
	# them — otherwise the last dots disappear inside the rift's own halo.
	var start_pad: float = minf(4.0, total * 0.2)
	var end_pad:   float = minf(4.5, total * 0.2)
	var walk: float = start_pad
	while walk <= total - end_pad:
		var p: Vector3 = _point_at(points, walk)
		var dot := MeshInstance3D.new()
		dot.mesh = dot_mesh
		var m := StandardMaterial3D.new()
		m.albedo_color               = _accent.darkened(0.35)
		m.emission_enabled           = true
		m.emission                   = _accent
		m.emission_energy_multiplier = CALM_ENERGY
		m.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot.material_override = m
		# Clear of the road slab's top face (roads top out at y = 0.07), so the
		# dots never z-fight with the street they now run down.
		dot.position = p + Vector3(0.0, 0.11, 0.0)
		add_child(dot)
		_dots.append(dot)
		_mats.append(m)
		_dot_t.append(clampf(walk / total, 0.0, 1.0))
		walk += DOT_SPACING

	visible = false


func is_open() -> bool:
	return _open


## Shows or hides the trail. `animate` runs the travelling flare; StoryMap passes
## false for edges that were already open when the map loaded.
func set_open(on: bool, animate: bool = false) -> void:
	_open = on
	visible = on
	if on and animate:
		light_up()
	elif on:
		_flare_head = -1.0


## The reveal beat: a bright head runs from the parent end of the trail to the
## child end, leaving the calm trail behind it.
func light_up() -> void:
	_flare_head = 0.0
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(v: float) -> void: _flare_head = v, 0.0, 1.35, 1.0)
	tw.tween_callback(func() -> void: _flare_head = -1.0)


func _process(delta: float) -> void:
	if not _open or _dots.is_empty():
		return
	_wave_t += delta

	for i in _mats.size():
		var t: float = _dot_t[i]
		# Calm state: a slow bright band drifting outward along the route.
		var wave: float = 0.65 + 0.35 * sin((t * 6.0) - _wave_t * 2.2)
		var energy: float = CALM_ENERGY * wave

		# Reveal flare: a short, much brighter head riding over the calm wave.
		if _flare_head >= 0.0:
			var d: float = absf(t - _flare_head)
			if d < 0.18:
				energy += FLARE_ENERGY * (1.0 - d / 0.18)

		_mats[i].emission_energy_multiplier = energy


# ── Polyline helpers ─────────────────────────────────────────────────────────

static func _polyline_length(points: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## Point `dist` metres along the polyline, clamped to its ends.
static func _point_at(points: PackedVector3Array, dist: float) -> Vector3:
	if points.is_empty():
		return Vector3.ZERO
	var walked: float = 0.0
	for i in range(1, points.size()):
		var seg: float = points[i].distance_to(points[i - 1])
		if seg <= 0.0001:
			continue
		if walked + seg >= dist:
			return points[i - 1].lerp(points[i], (dist - walked) / seg)
		walked += seg
	return points[points.size() - 1]
