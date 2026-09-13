class_name StoryRoads
extends RefCounted

## Calder City's street network, as an actual graph.
##
## The map used to be routed on a perfect lattice: roads at fixed intervals on
## both axes, every one of them present, every block an identical square. That
## made routing trivial — "step onto the nearest centreline, drive, turn once" —
## but it also made the city read as Manhattan, and no amount of paint on the
## buildings fixed the layout underneath.
##
## So the streets are a graph now: intersections that have wandered off their
## slots, segments that are sometimes simply missing, and blocks that come out
## whatever shape the four corners around them happen to make. Travel is a
## shortest-path search over that graph rather than arithmetic on a grid.
##
## ── Why it is still built from a grid ────────────────────────────────────────
## The intersections START on a lattice and are then jittered, and the segments
## start as its edges and are then thinned. Growing a road network organically
## gives prettier results and is far harder to keep sane — every block has to
## stay convex enough to build on, every street has to stay reachable. Perturbing
## a grid gives irregular streets and irregular blocks while keeping both of
## those guarantees for free, and at map distance the origin does not show.
##
## Connectivity is guaranteed by CONSTRUCTION, not by checking: a random spanning
## tree is laid first and the remaining segments are added back on top of it. No
## amount of thinning can strand a corner of town, so no route can ever fail.

## Metres between intersection slots before jitter.
const PITCH: float = 43.0
## How far an intersection wanders off its slot. This is what bends the streets
## — every segment picks up a slight angle, and no two blocks come out alike.
const JITTER: float = 8.5
## Share of the non-essential segments left out. Missing links merge neighbouring
## cells into bigger, odder blocks, which is most of what kills the grid read.
const DROP_CHANCE: float = 0.22
## Half-widths of the two street grades.
const AVENUE_HALF: float = 5.5
const LANE_HALF: float = 3.7
## How far inside the kerb a building frontage sits.
const FRONTAGE_INSET: float = 2.6
## The network is generated over a fixed area rather than one derived from where
## the rifts are. Rift placement asks the roads where the frontages are, so the
## roads cannot in turn depend on the rifts without the two defining each other.
const NETWORK_RADIUS: float = 320.0
const NETWORK_SEED: int = 0x5A1AC17
## No intersection is allowed nearer the origin than this, so the plaza gets a
## block wide enough that no street clips its canopy.
const PLAZA_CLEAR: float = 30.0

## Intersections.
var points: PackedVector3Array = PackedVector3Array()
## Segments, as index pairs into `points`.
var edges: Array[Vector2i] = []
## 1 for an avenue, 0 for a lane.
var major: PackedByteArray = PackedByteArray()
## point index -> Array of [neighbour index, edge index]
var adjacency: Array = []

var origin: Vector3 = Vector3.ZERO
var _slot: Dictionary = {}        # Vector2i grid slot -> point index
var _point_slot: Array[Vector2i] = []
var _span: int = 0

static var _shared: StoryRoads = null


## The one network everybody uses. The city draws it, rift placement asks it for
## frontages and travel routes over it — all three have to agree exactly, so
## there is only ever one of them.
static func shared(at: Vector3 = Vector3.ZERO) -> StoryRoads:
	if _shared == null or _shared.origin != at:
		_shared = StoryRoads.new()
		_shared.build(at)
	return _shared


func build(at: Vector3) -> void:
	origin = at
	var rng := RandomNumberGenerator.new()
	rng.seed = NETWORK_SEED
	_span = int(ceil(NETWORK_RADIUS / PITCH))

	_place_intersections(rng)
	var candidates: Array[Vector2i] = _candidate_segments()
	_lay_streets(candidates, rng)
	_build_adjacency()


## Intersections on their slots, then nudged. The jitter is the whole point:
## straight streets are what made the old city look surveyed.
##
## Slots are offset by HALF a pitch so that the ORIGIN lands in the middle of a
## cell rather than on a junction. The hub plaza stands at the origin, and on the
## unshifted lattice that put a crossroads straight through the middle of it.
func _place_intersections(rng: RandomNumberGenerator) -> void:
	for i in range(-_span, _span + 1):
		for j in range(-_span, _span + 1):
			var p := Vector3(
				origin.x + (float(i) + 0.5) * PITCH + rng.randf_range(-JITTER, JITTER),
				origin.y,
				origin.z + (float(j) + 0.5) * PITCH + rng.randf_range(-JITTER, JITTER))
			# Keep the plaza's own block generous: a corner that wandered inward
			# would drag its two streets across the canopy.
			var out := Vector3(p.x - origin.x, 0.0, p.z - origin.z)
			var d: float = out.length()
			if d < PLAZA_CLEAR and d > 0.01:
				p = origin + out / d * PLAZA_CLEAR
			_slot[Vector2i(i, j)] = points.size()
			points.append(p)
			_point_slot.append(Vector2i(i, j))


func _candidate_segments() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in range(-_span, _span + 1):
		for j in range(-_span, _span + 1):
			var here: Vector2i = Vector2i(i, j)
			for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var there: Vector2i = here + step
				if _slot.has(there):
					out.append(Vector2i(_slot[here], _slot[there]))
	return out


## Lays a random spanning tree first, then adds most of the rest back.
##
## Doing it this way means the town can never be cut in half however aggressive
## DROP_CHANCE gets — the tree already reaches every intersection, and
## everything after it is a bonus loop. Dropping segments at random and then
## testing connectivity would work too, but it can fail, and a city where one
## rift is unreachable is a far worse bug than a slightly too regular one.
func _lay_streets(candidates: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	var order: Array[int] = []
	for i in candidates.size():
		order.append(i)
	# Fisher-Yates, so the spanning tree is a different shape every seed.
	for i in range(order.size() - 1, 0, -1):
		var k: int = rng.randi_range(0, i)
		var tmp: int = order[i]
		order[i] = order[k]
		order[k] = tmp

	var parent: PackedInt32Array = PackedInt32Array()
	parent.resize(points.size())
	for i in points.size():
		parent[i] = i

	var extras: Array[Vector2i] = []
	for idx: int in order:
		var e: Vector2i = candidates[idx]
		var ra: int = _find(parent, e.x)
		var rb: int = _find(parent, e.y)
		if ra != rb:
			parent[ra] = rb
			_add_edge(e)
		else:
			extras.append(e)

	for e2: Vector2i in extras:
		if rng.randf() >= DROP_CHANCE:
			_add_edge(e2)


func _add_edge(e: Vector2i) -> void:
	edges.append(e)
	# Avenues are the long through-routes: every third lattice line, taken from
	# the slots themselves rather than measured back out of the jittered
	# positions, which stopped being reliable once the lattice was offset.
	var sa: Vector2i = _point_slot[e.x]
	var sb: Vector2i = _point_slot[e.y]
	var line: int = sa.y if sa.x != sb.x else sa.x
	major.append(1 if posmod(line, 3) == 0 else 0)


static func _find(parent: PackedInt32Array, i: int) -> int:
	var root: int = i
	while parent[root] != root:
		root = parent[root]
	# Path compression, so the tree build stays linear-ish on a big network.
	var walk: int = i
	while parent[walk] != root:
		var next: int = parent[walk]
		parent[walk] = root
		walk = next
	return root


func _build_adjacency() -> void:
	adjacency.resize(points.size())
	for i in points.size():
		adjacency[i] = []
	for ei in edges.size():
		var e: Vector2i = edges[ei]
		(adjacency[e.x] as Array).append([e.y, ei])
		(adjacency[e.y] as Array).append([e.x, ei])


func half_width(edge_index: int) -> float:
	return AVENUE_HALF if major[edge_index] == 1 else LANE_HALF


# ── Queries ──────────────────────────────────────────────────────────────────

## The segment nearest `pos`, with the point on it closest to `pos`.
## Returns {"edge": int, "point": Vector3, "normal": Vector3} where the normal
## points from the street back toward `pos`.
func nearest_edge(pos: Vector3) -> Dictionary:
	var best: int = -1
	var best_d: float = INF
	var best_p := Vector3.ZERO
	for ei in edges.size():
		var e: Vector2i = edges[ei]
		var p: Vector3 = _closest_on_segment(pos, points[e.x], points[e.y])
		var d: float = Vector2(pos.x - p.x, pos.z - p.z).length_squared()
		if d < best_d:
			best_d = d
			best = ei
			best_p = p
	var n := Vector3(pos.x - best_p.x, 0.0, pos.z - best_p.z)
	if n.length_squared() < 0.0001:
		# Standing exactly on the centreline: any side will do, so take the
		# segment's own left.
		var e2: Vector2i = edges[best]
		var along: Vector3 = (points[e2.y] - points[e2.x]).normalized()
		n = Vector3(-along.z, 0.0, along.x)
	return {"edge": best, "point": best_p, "normal": n.normalized()}


## The nearest street lying in a given direction from `pos`.
##
## The plaza opens on ONE side, and "nearest street" is not that — the plaza sits
## in the middle of its block with streets on every side, so plain nearest picks
## whichever happens to be closest and the entrance wanders. Constraining the
## search to the half-plane the entrance faces keeps every arrival on the same
## side however the streets around it fell.
func nearest_edge_toward(pos: Vector3, dir: Vector3) -> Dictionary:
	var want := Vector3(dir.x, 0.0, dir.z)
	if want.length_squared() < 0.0001:
		return nearest_edge(pos)
	want = want.normalized()

	var best: int = -1
	var best_d: float = INF
	var best_p := Vector3.ZERO
	for ei in edges.size():
		var e: Vector2i = edges[ei]
		var p: Vector3 = _closest_on_segment(pos, points[e.x], points[e.y])
		var away := Vector3(p.x - pos.x, 0.0, p.z - pos.z)
		if away.dot(want) <= 0.0:
			continue
		var d: float = away.length_squared()
		if d < best_d:
			best_d = d
			best = ei
			best_p = p
	if best < 0:
		return nearest_edge(pos)
	var n := Vector3(pos.x - best_p.x, 0.0, pos.z - best_p.z)
	return {"edge": best, "point": best_p, "normal": n.normalized()}


## Where a rift stands: back from the kerb of the nearest street, on the block
## side it was already on, facing the road.
func frontage(pos: Vector3) -> Dictionary:
	var hit: Dictionary = nearest_edge(pos)
	var n: Vector3 = hit["normal"]
	var back: float = half_width(int(hit["edge"])) + FRONTAGE_INSET
	var spot: Vector3 = (hit["point"] as Vector3) + n * back

	# Stepping back off one street can land you in another. On a lattice that
	# could not happen — the next street was a full block away — but these
	# streets bend and meet at odd angles, so a corner plot can be within reach
	# of two at once. Nudge away from whatever is nearest until nothing is.
	for _pass in 4:
		var near: Dictionary = nearest_edge(spot)
		var clear: float = half_width(int(near["edge"])) + FRONTAGE_INSET
		var gap: float = spot.distance_to(near["point"] as Vector3)
		if gap >= clear - 0.05:
			break
		spot = (near["point"] as Vector3) + (near["normal"] as Vector3) * clear

	var final: Dictionary = nearest_edge(spot)
	return {
		"pos": spot,
		"facing": -(final["normal"] as Vector3),
	}


## The point on the carriageway a frontage steps out onto. With a `facing` it is
## the street on that side; without one, simply the nearest.
func doorstep(pos: Vector3, facing: Vector3 = Vector3.ZERO) -> Vector3:
	return nearest_edge_toward(pos, facing)["point"]


## An on-street polyline from `a` to `b`.
##
## Both ends are projected onto their nearest segment, then it is a shortest
## path between the four possible endpoints of those two segments. Four
## Dijkstra lookups rather than one because a segment can be entered from either
## end, and taking the nearer end is not always the shorter journey.
func route(a: Vector3, b: Vector3) -> PackedVector3Array:
	var ha: Dictionary = nearest_edge(a)
	var hb: Dictionary = nearest_edge(b)
	var pa: Vector3 = ha["point"]
	var pb: Vector3 = hb["point"]
	var ea: Vector2i = edges[int(ha["edge"])]
	var eb: Vector2i = edges[int(hb["edge"])]

	if int(ha["edge"]) == int(hb["edge"]):
		return PackedVector3Array([pa, pb])

	var best: PackedVector3Array = PackedVector3Array()
	var best_cost: float = INF
	for sa: int in [ea.x, ea.y]:
		var walk: Dictionary = _dijkstra(sa)
		var dist: PackedFloat32Array = walk["dist"]
		var prev: PackedInt32Array = walk["prev"]
		for sb: int in [eb.x, eb.y]:
			if dist[sb] >= INF:
				continue
			var cost: float = pa.distance_to(points[sa]) + dist[sb] + points[sb].distance_to(pb)
			if cost >= best_cost:
				continue
			best_cost = cost
			var line := PackedVector3Array([pa])
			for p: Vector3 in _trace(prev, sa, sb):
				line.append(p)
			line.append(pb)
			best = line
	return best


func _dijkstra(source: int) -> Dictionary:
	var dist := PackedFloat32Array()
	var prev := PackedInt32Array()
	var done := PackedByteArray()
	dist.resize(points.size())
	prev.resize(points.size())
	done.resize(points.size())
	for i in points.size():
		dist[i] = INF
		prev[i] = -1
		done[i] = 0
	dist[source] = 0.0

	# The network is a couple of hundred intersections, so a linear scan for the
	# next node is cheaper than the bookkeeping a heap would need — and this runs
	# a handful of times when the map loads, not per frame.
	while true:
		var best: int = -1
		var best_d: float = INF
		for i in points.size():
			if done[i] == 0 and dist[i] < best_d:
				best_d = dist[i]
				best = i
		if best < 0:
			break
		done[best] = 1
		for link: Array in (adjacency[best] as Array):
			var to: int = link[0]
			if done[to] == 1:
				continue
			var step: float = points[best].distance_to(points[to])
			if dist[best] + step < dist[to]:
				dist[to] = dist[best] + step
				prev[to] = best
	return {"dist": dist, "prev": prev}


func _trace(prev: PackedInt32Array, source: int, target: int) -> PackedVector3Array:
	var back := PackedVector3Array()
	var walk: int = target
	var guard: int = 0
	while walk != -1 and guard < 4096:
		back.append(points[walk])
		if walk == source:
			break
		walk = prev[walk]
		guard += 1
	var out := PackedVector3Array()
	for i in range(back.size() - 1, -1, -1):
		out.append(back[i])
	return out


static func _closest_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t: float = clampf(Vector3(p.x - a.x, 0.0, p.z - a.z).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


# ── Blocks ───────────────────────────────────────────────────────────────────

## The four corners of one grid cell, in order. Because the corners have all
## wandered, a "block" is an irregular quadrilateral rather than a square, and
## no two of them are the same shape.
func cell_corners(i: int, j: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]:
		if not _slot.has(s):
			return PackedVector3Array()
		out.append(points[_slot[s]])
	return out


## True when a street actually runs between two adjacent slots. Where one does
## not, the cells either side of it are effectively one larger block — which is
## exactly the irregularity that a full lattice cannot produce.
func has_street(a: Vector2i, b: Vector2i) -> bool:
	if not (_slot.has(a) and _slot.has(b)):
		return false
	var ia: int = _slot[a]
	var ib: int = _slot[b]
	for link: Array in (adjacency[ia] as Array):
		if int(link[0]) == ib:
			return true
	return false


func slot_span() -> int:
	return _span


## Pulls a cell's corners in toward its middle by the width of whichever street
## borders each edge — the buildable footprint of the block. Edges with no
## street get almost no inset, so the pavement runs straight into its neighbour
## and the two read as one block.
func buildable_quad(i: int, j: int) -> PackedVector3Array:
	var c: PackedVector3Array = cell_corners(i, j)
	if c.size() < 4:
		return c
	var mid := Vector3.ZERO
	for p: Vector3 in c:
		mid += p
	mid /= 4.0

	var out := PackedVector3Array()
	for k in 4:
		var inset: float = maxf(_edge_inset(i, j, k), _edge_inset(i, j, (k + 3) % 4))
		var dir: Vector3 = (mid - c[k])
		dir.y = 0.0
		var d: float = dir.length()
		out.append(c[k] + dir / maxf(d, 0.001) * minf(inset * 1.4, d * 0.45))
	return out


## The street along side `k` of a cell (0 = south, 1 = east, 2 = north,
## 3 = west), as an index into `edges` — or -1 where no street runs and the
## block simply carries on into its neighbour. Side k runs from corner k to
## corner k + 1 of cell_corners(), in that order.
func side_edge(i: int, j: int, k: int) -> int:
	var slots: Array[Vector2i] = [Vector2i(i, j), Vector2i(i + 1, j),
		Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
	var a: Vector2i = slots[k]
	var b: Vector2i = slots[(k + 1) % 4]
	if not (_slot.has(a) and _slot.has(b)):
		return -1
	var ib: int = _slot[b]
	for link: Array in (adjacency[_slot[a]] as Array):
		if int(link[0]) == ib:
			return int(link[1])
	return -1


## Inset for side `k` of a cell: 0 = south, 1 = east, 2 = north, 3 = west.
func _edge_inset(i: int, j: int, k: int) -> float:
	var a: Vector2i
	var b: Vector2i
	match k:
		0: a = Vector2i(i, j);         b = Vector2i(i + 1, j)
		1: a = Vector2i(i + 1, j);     b = Vector2i(i + 1, j + 1)
		2: a = Vector2i(i + 1, j + 1); b = Vector2i(i, j + 1)
		_: a = Vector2i(i, j + 1);     b = Vector2i(i, j)
	if not has_street(a, b):
		return 0.4
	var ia: int = _slot[a]
	var ib: int = _slot[b]
	for link: Array in (adjacency[ia] as Array):
		if int(link[0]) == ib:
			return half_width(int(link[1])) + 1.0
	return AVENUE_HALF + 1.0
