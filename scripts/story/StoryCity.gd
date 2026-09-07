class_name StoryCity
extends Node3D

## The mundane city the Story Mode map sits in.
##
## PLACEHOLDER ART: boxes on a street grid. That is deliberate at this stage —
## the map camera never comes near the ground, so what actually has to be right
## in this pass is the LARGE-SCALE read: block layout, building massing and a
## skyline that varies from downtown to the edges. Small props would not survive
## the viewing distance, so none are built.
##
## ── The city is not damaged ──────────────────────────────────────────────────
## No debris, no cracks, no decay, no destruction — not near the rifts either.
## A rift is inconvenient, not destructive, and the whole visual idea of the map
## depends on the city reading as an ordinary weekday: everything here is muted
## and grey-brown so the rifts are the only saturated, wrong-looking thing on
## screen. Anything added later that scuffs the city up takes that contrast away.
##
## TODO(art): swap the boxes for authored block kits. `build()` already receives
## the keep-clear list, so real geometry can be placed the same way.

## Fixed seed: the map layout must be the same city every time the player opens
## it. The RNG autoload is deliberately not used — that one is seeded per run
## and per section for gameplay variety, which is the opposite of what a map
## backdrop wants.
const CITY_SEED: int = 0x5A1AC17

const BLOCK_SIZE: float = 32.0
const ROAD_WIDTH: float = 11.0
const BLOCK_PITCH: float = BLOCK_SIZE + ROAD_WIDTH

## Metres of clearance kept around the route trails, so a building never sits on
## top of a path Meeko has to walk down.
const PATH_CLEARANCE: float = 7.0

## How far from a map node the city is actually built. The map camera shows
## roughly 120 m of ground and never leaves the nodes, so this is a generous
## margin — the player reaches fog long before the edge of the built area.
const VIEW_BAND: float = 135.0

## Muted, NOT dark. The first pass had everything down around 0.1 albedo and the
## whole city read as a black hole with a pink dot in it — "mundane" means low
## saturation, not low value. These are ordinary daylight concrete/brick values;
## the rifts stay the brightest thing on screen by being SATURATED and emissive,
## not by being the only lit object.
const GROUND_COL: Color = Color(0.300, 0.295, 0.305, 1.0)
const ROAD_COL:   Color = Color(0.235, 0.232, 0.245, 1.0)
const PARK_COL:   Color = Color(0.270, 0.320, 0.255, 1.0)

## Facade tints: grey-brown, low saturation, small spread — a real city block on
## an ordinary afternoon seen from a long way up, not a neon skyline.
const FACADE_COLS: Array[Color] = [
	Color(0.400, 0.388, 0.400, 1.0),
	Color(0.462, 0.432, 0.402, 1.0),
	Color(0.345, 0.352, 0.386, 1.0),
	Color(0.500, 0.478, 0.452, 1.0),
	Color(0.306, 0.310, 0.323, 1.0),
]

static var _facade_mat: StandardMaterial3D = null

var _rng := RandomNumberGenerator.new()
var _unit_box: BoxMesh = null
var _facade_mats: Array[StandardMaterial3D] = []
var _building_count: int = 0


## Shared facade look, so StoryRift's wall variant reads as the same city fabric
## as the blocks around it rather than as a prop dropped on top of them.
static func facade_material() -> StandardMaterial3D:
	if _facade_mat == null:
		_facade_mat = StandardMaterial3D.new()
		_facade_mat.albedo_color = FACADE_COLS[1]
		_facade_mat.roughness    = 0.95
		_facade_mat.metallic     = 0.0
	return _facade_mat


## Builds the backdrop out to `radius` metres around `center`.
##
## `keep_clear` is a list of {"pos": Vector3, "radius": float} — the rifts and
## the hub, which must not end up inside a building. `paths` is the list of
## route polylines, kept clear by PATH_CLEARANCE so trails stay walkable and
## visible from above.
func build(center: Vector3, radius: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> void:
	_rng.seed = CITY_SEED
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	for col: Color in FACADE_COLS:
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness    = 0.95
		m.metallic     = 0.0
		_facade_mats.append(m)

	_build_ground(center, radius)
	_build_roads(center, radius)
	_build_blocks(center, radius, keep_clear, paths)
	print("[StoryCity] %d placeholder buildings over a %.0f m radius." % [_building_count, radius])


func _build_ground(center: Vector3, radius: float) -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius * 2.6, radius * 2.6)
	ground.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_color = GROUND_COL
	m.roughness    = 1.0
	ground.material_override = m
	ground.position = center
	add_child(ground)


## Road strips laid over the ground between blocks. Flat boxes rather than a
## real mesh: at map distance a road is a value change, nothing more.
func _build_roads(center: Vector3, radius: float) -> void:
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = ROAD_COL
	road_mat.roughness    = 1.0

	var span: int = int(ceil(radius / BLOCK_PITCH)) + 1
	var length: float = radius * 2.2

	for i in range(-span, span + 1):
		var offset: float = float(i) * BLOCK_PITCH - BLOCK_PITCH * 0.5

		var ns := MeshInstance3D.new()
		ns.mesh = _unit_box
		ns.material_override = road_mat
		ns.scale    = Vector3(ROAD_WIDTH, 0.08, length)
		ns.position = center + Vector3(offset, 0.03, 0.0)
		add_child(ns)

		var ew := MeshInstance3D.new()
		ew.mesh = _unit_box
		ew.material_override = road_mat
		ew.scale    = Vector3(length, 0.08, ROAD_WIDTH)
		ew.position = center + Vector3(0.0, 0.03, offset)
		add_child(ew)


func _build_blocks(center: Vector3, radius: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> void:
	var span: int = int(ceil(radius / BLOCK_PITCH))

	for gx in range(-span, span + 1):
		for gz in range(-span, span + 1):
			var block_center: Vector3 = center + Vector3(float(gx) * BLOCK_PITCH, 0.0, float(gz) * BLOCK_PITCH)
			var from_center: float = Vector2(block_center.x - center.x, block_center.z - center.z).length()
			if from_center > radius:
				continue
			# The camera only ever sits over a node (it frames Meeko or the
			# selected rift), so a block further than VIEW_BAND from every node is
			# one the player can never look at. Filling the whole disc anyway is
			# what makes the city cost grow with the SQUARE of map size; this
			# makes it grow with the number of nodes instead. At the current map
			# the bands overlap and nothing is culled, so the city is unchanged —
			# it only starts paying off as the map spreads out.
			if not _within_view_band(block_center, keep_clear):
				continue

			# One block in seven is left open — a square, a lot, a park. Breaks
			# up the grid so the skyline is not a uniform field of towers.
			if _rng.randf() < 0.14:
				_build_open_block(block_center)
				continue

			_build_block(block_center, from_center, radius, keep_clear, paths)


func _build_open_block(block_center: Vector3) -> void:
	var pad := MeshInstance3D.new()
	pad.mesh = _unit_box
	var m := StandardMaterial3D.new()
	m.albedo_color = PARK_COL
	m.roughness    = 1.0
	pad.material_override = m
	pad.scale    = Vector3(BLOCK_SIZE * 0.9, 0.1, BLOCK_SIZE * 0.9)
	pad.position = block_center + Vector3(0.0, 0.05, 0.0)
	add_child(pad)


## Fills one block with three to five buildings. Height falls off with distance
## from the hub, so the middle of the map reads as downtown and the edges as
## low-rise — that gradient is most of what makes the skyline legible from a
## map camera.
func _build_block(block_center: Vector3, from_center: float, radius: float,
		keep_clear: Array[Dictionary], paths: Array[PackedVector3Array]) -> void:
	var falloff: float = 1.0 - clampf(from_center / maxf(1.0, radius), 0.0, 1.0)
	# Downtown in the middle, low-rise at the edges. Capped well under the map
	# camera's height on purpose — a tower tall enough to reach the sight line
	# would occlude the rift the player is walking toward, and on a map screen
	# losing the character behind a building is worse than a flatter skyline.
	var height_scale: float = 0.5 + falloff * falloff * 1.0

	var lots: int = _rng.randi_range(3, 5)
	for _lot in lots:
		var w: float = _rng.randf_range(8.0, 15.0)
		var d: float = _rng.randf_range(8.0, 15.0)
		var half_free: float = BLOCK_SIZE * 0.5 - maxf(w, d) * 0.5
		var pos: Vector3 = block_center + Vector3(
			_rng.randf_range(-half_free, half_free), 0.0,
			_rng.randf_range(-half_free, half_free))

		var footprint: float = Vector2(w, d).length() * 0.5
		if not _is_clear(pos, footprint, keep_clear, paths):
			continue

		var h: float = _rng.randf_range(8.0, 26.0) * height_scale
		var mat: StandardMaterial3D = _facade_mats[_rng.randi() % _facade_mats.size()]

		var body := MeshInstance3D.new()
		body.mesh = _unit_box
		body.material_override = mat
		body.scale    = Vector3(w, h, d)
		body.position = pos + Vector3(0.0, h * 0.5, 0.0)
		add_child(body)
		_building_count += 1

		# Setback on the taller ones: a narrower second stage. One extra box per
		# tower, and it is what stops downtown reading as a row of identical
		# rectangles from above.
		if h > 22.0 and _rng.randf() < 0.55:
			var cap_h: float = _rng.randf_range(5.0, 12.0)
			var cap := MeshInstance3D.new()
			cap.mesh = _unit_box
			cap.material_override = mat
			cap.scale    = Vector3(w * 0.6, cap_h, d * 0.6)
			cap.position = pos + Vector3(0.0, h + cap_h * 0.5, 0.0)
			add_child(cap)


## True when a block is close enough to some node to ever be on screen.
func _within_view_band(block_center: Vector3, keep_clear: Array[Dictionary]) -> bool:
	for entry: Dictionary in keep_clear:
		var c: Vector3 = entry.get("pos", Vector3.ZERO)
		if Vector2(block_center.x - c.x, block_center.z - c.z).length() <= VIEW_BAND:
			return true
	return false


## True when a building of `footprint` radius at `pos` clears every rift, the
## hub, and every route trail.
func _is_clear(pos: Vector3, footprint: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> bool:
	for entry: Dictionary in keep_clear:
		var c: Vector3 = entry.get("pos", Vector3.ZERO)
		var r: float = float(entry.get("radius", 10.0))
		if Vector2(pos.x - c.x, pos.z - c.z).length() < r + footprint:
			return false

	for line: PackedVector3Array in paths:
		for i in range(1, line.size()):
			if _point_to_segment(pos, line[i - 1], line[i]) < PATH_CLEARANCE + footprint:
				return false
	return true


## Distance from `p` to segment a-b, measured on the XZ plane only.
static func _point_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var pp := Vector2(p.x, p.z)
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	var ab: Vector2 = bb - aa
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return pp.distance_to(aa)
	var t: float = clampf((pp - aa).dot(ab) / len_sq, 0.0, 1.0)
	return pp.distance_to(aa + ab * t)
