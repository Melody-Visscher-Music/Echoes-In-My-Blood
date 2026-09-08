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
##
## Small on purpose now that routes run down the STREETS. A road is already an
## 11 m gap between blocks, so a trail on a road centreline needs no clearance of
## its own — and asking for the old 7 m would have culled every building on a
## lot facing a used road, stripping the city back along each route. What this
## still covers is the short spur from a rift out to its nearest road, which
## does cross a block.
const PATH_CLEARANCE: float = 2.5

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


# ── Road grid routing ────────────────────────────────────────────────────────
## Where map routes come from. The grid lives here because this file is what
## draws it — anything that wants to travel the city asks, rather than keeping a
## second copy of the block pitch that can drift out of step with the roads.
##
## Routes used to be straight lines from rift to rift, which cut diagonally
## across blocks and through buildings. They now step out to the nearest street,
## drive the grid, and turn in at the far end, so both the dotted trail and Meeko
## follow roads like anything else in a city would.

## Centreline of the nearest north-south road to `x`. Roads sit at
## `origin + i * BLOCK_PITCH - BLOCK_PITCH/2`, which is what _build_roads draws.
static func nearest_road_x(x: float, origin_x: float) -> float:
	var half: float = BLOCK_PITCH * 0.5
	return origin_x + round((x - origin_x + half) / BLOCK_PITCH) * BLOCK_PITCH - half


static func nearest_road_z(z: float, origin_z: float) -> float:
	return nearest_road_x(z, origin_z)


## Every street a position could reasonably step out onto: the road either side
## of it on each axis, so four in all. Each entry is {"pos", "h"}, where h means
## an east-west road (z fixed, free to travel in x).
##
## Both neighbours are offered, not just the nearer one. A block is bounded by
## two roads on each axis and the useful one is whichever heads toward the
## destination — the hub sits dead centre between four of them, so "nearest"
## there is a coin toss that was sending routes off the wrong way entirely.
static func _access_candidates(pos: Vector3, origin: Vector3) -> Array[Dictionary]:
	var half: float = BLOCK_PITCH * 0.5
	var out: Array[Dictionary] = []
	var zi: float = floor((pos.z - origin.z + half) / BLOCK_PITCH)
	var xi: float = floor((pos.x - origin.x + half) / BLOCK_PITCH)
	for k: float in [0.0, 1.0]:
		out.append({"pos": Vector3(pos.x, pos.y, origin.z + (zi + k) * BLOCK_PITCH - half), "h": true})
		out.append({"pos": Vector3(origin.x + (xi + k) * BLOCK_PITCH - half, pos.y, pos.z), "h": false})
	return out


## An on-road polyline from `a` to `b`: a spur onto the street, at most two turns
## along the grid, then a spur in at the far end. Corners always land on real
## intersections, so no leg ever crosses a block.
##
## Picks the shortest of every access pairing rather than trying to reason about
## which street is "right". Sixteen candidate routes per edge, built once when
## the map loads — far cheaper than the special cases the alternative needs.
static func road_route(a: Vector3, b: Vector3, origin: Vector3) -> PackedVector3Array:
	var best := PackedVector3Array()
	var best_len: float = INF
	for ca: Dictionary in _access_candidates(a, origin):
		for cb: Dictionary in _access_candidates(b, origin):
			var cand: PackedVector3Array = _route_between(a, b, ca, cb, origin)
			var total: float = 0.0
			for i in range(1, cand.size()):
				total += cand[i].distance_to(cand[i - 1])
			if total < best_len:
				best_len = total
				best = cand
	return best


static func _route_between(a: Vector3, b: Vector3, ca: Dictionary, cb: Dictionary,
		origin: Vector3) -> PackedVector3Array:
	var ap: Vector3 = ca["pos"]
	var bp: Vector3 = cb["pos"]
	var a_h: bool = ca["h"]
	var b_h: bool = cb["h"]

	var pts := PackedVector3Array([a, ap])

	if a_h and b_h:
		if not is_equal_approx(ap.z, bp.z):
			# Two east-west roads: drive across, turn up the destination's
			# column, then turn onto its street.
			var vx: float = nearest_road_x(bp.x, origin.x)
			pts.append(Vector3(vx, a.y, ap.z))
			pts.append(Vector3(vx, a.y, bp.z))
	elif not a_h and not b_h:
		if not is_equal_approx(ap.x, bp.x):
			var vz: float = nearest_road_z(bp.z, origin.z)
			pts.append(Vector3(ap.x, a.y, vz))
			pts.append(Vector3(bp.x, a.y, vz))
	elif a_h:
		pts.append(Vector3(bp.x, a.y, ap.z))    # turn onto b's column
	else:
		pts.append(Vector3(ap.x, a.y, bp.z))    # turn onto b's row

	pts.append(bp)
	pts.append(b)
	return _dedupe(pts)


## Drops points that land on top of each other, which the corner cases above
## produce whenever two legs happen to share a road.
static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.5:
			out.append(p)
	return out


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
