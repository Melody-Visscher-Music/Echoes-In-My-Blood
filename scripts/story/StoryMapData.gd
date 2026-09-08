class_name StoryMapData
extends RefCounted

## The Story Mode map graph, loaded from res://data/story/story_map.json.
##
## The map is a TREE, not an authored scene layout: one hub, branches leaving it
## on an authored heading, and level nodes sitting some distance out along a
## branch. Nothing in here knows about meshes, cameras or input — StoryMap.gd
## builds the world from whatever this returns, so adding a rift later is a JSON
## edit and nothing else. That is the whole reason this layer exists.
##
## ── Why positions are derived, not authored ──────────────────────────────────
## A node's world position is computed as
##
##     world = hub + heading(branch) * along + right(branch) * across
##
## which is what makes the design's two placement rules cheap to express:
##
##   * "level 5 sits further out along the SAME branch as 1-3"  → a bigger
##     `along` on the same branch id.
##   * "level 4's branch opens on the geometrically OPPOSITE side of the hub"
##     → a branch whose `heading_deg` is the first one's + 180.
##
## Hand-placing the same thing as raw XZ coordinates would make both rules
## invisible in the data. A node may still pin `"position": [x, y, z]` when a
## spot really has to be hand-chosen; everything downstream reads `position`
## either way.
##
## ── Unlock model ─────────────────────────────────────────────────────────────
## `unlocked_by` is a list of node ids that must be CLEARED first. A node is
## unlocked when its own list is satisfied AND its branch's list is satisfied —
## the branch gate is what lets a whole cluster stay hidden until the run
## reaches it, without repeating the same condition on every node in it.
## Unlocked means VISIBLE: locked nodes are not drawn at all (not greyed out),
## so the map only ever shows the city the player has actually opened up.

const DEFAULT_PATH: String = "res://data/story/story_map.json"

## Ids in authored order — the order the map cycles through with left/right.
var order: PackedStringArray = PackedStringArray()

## id -> {
##   "id", "title", "song_key", "branch", "cluster", "variant",
##   "parent"     : String             — graph edge toward the hub
##   "position"   : Vector3            — resolved world position
##   "via"        : PackedVector3Array — extra waypoints on the edge from `parent`
##   "unlocked_by": PackedStringArray
## }
var nodes: Dictionary = {}

var hub_id: String = "hub"
var hub_title: String = "HUB"
var hub_position: Vector3 = Vector3.ZERO
var map_title: String = ""

## branch id -> {"id", "title", "heading_deg", "unlocked_by"}
var branches: Dictionary = {}

var load_error: String = ""


## Reads and resolves the map. Returns a StoryMapData either way — check
## `load_error` rather than a null, so the caller can put the reason on screen
## instead of crashing on an empty map.
static func load_from(path: String = DEFAULT_PATH) -> StoryMapData:
	var data := StoryMapData.new()
	if not FileAccess.file_exists(path):
		data.load_error = "Story map not found: %s" % path
		push_error("[StoryMapData] " + data.load_error)
		return data

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		data.load_error = "Story map is not a JSON object: %s" % path
		push_error("[StoryMapData] " + data.load_error)
		return data

	data._parse(parsed as Dictionary)
	return data


func _parse(root: Dictionary) -> void:
	map_title = String(root.get("title", ""))

	var hub: Dictionary = root.get("hub", {}) as Dictionary
	hub_id       = String(hub.get("id", "hub"))
	hub_title    = String(hub.get("title", "HUB"))
	hub_position = _to_vec3(hub.get("position", [0.0, 0.0, 0.0]))

	for b_raw: Variant in root.get("branches", []):
		if not (b_raw is Dictionary):
			continue
		var b: Dictionary = b_raw as Dictionary
		var bid: String = String(b.get("id", ""))
		if bid == "":
			push_warning("[StoryMapData] branch with no id — skipped.")
			continue
		branches[bid] = {
			"id": bid,
			"title": String(b.get("title", bid)),
			"heading_deg": float(b.get("heading_deg", 0.0)),
			"unlocked_by": _to_ids(b.get("unlocked_by", [])),
		}

	for n_raw: Variant in root.get("nodes", []):
		if not (n_raw is Dictionary):
			continue
		var n: Dictionary = n_raw as Dictionary
		var nid: String = String(n.get("id", ""))
		if nid == "":
			push_warning("[StoryMapData] node with no id — skipped.")
			continue
		if nodes.has(nid):
			push_warning("[StoryMapData] duplicate node id '%s' — later one skipped." % nid)
			continue

		var branch_id: String = String(n.get("branch", ""))

		var pos: Vector3
		if n.has("position"):
			pos = _to_vec3(n.get("position"))
		else:
			pos = branch_point(branch_id, float(n.get("along", 0.0)), float(n.get("across", 0.0)))

		var via := PackedVector3Array()
		for v_raw: Variant in n.get("via", []):
			if v_raw is Array and (v_raw as Array).size() >= 2:
				var v: Array = v_raw as Array
				via.append(branch_point(branch_id, float(v[0]), float(v[1])))

		nodes[nid] = {
			"id": nid,
			"title": String(n.get("title", nid)),
			# Which LEVEL this node is. The chart is not named here — it is
			# whichever beatmap claims this number in its `song_order`. See
			# song_key_of(). `song_key` stays supported as an explicit override
			# for a one-off that should not be reachable by number.
			"level": int(n.get("level", 0)),
			"song_key": String(n.get("song_key", "")),
			"branch": branch_id,
			"cluster": String(n.get("cluster", branch_id)),
			"variant": String(n.get("variant", "auto")),
			"parent": String(n.get("connects_from", hub_id)),
			"position": pos,
			"via": via,
			"unlocked_by": _to_ids(n.get("unlocked_by", [])),
		}
		order.append(nid)

	_validate()


## Resolves a point in a branch's own frame. `along` runs out from the hub on
## the branch heading, `across` is perpendicular to it — so a cluster is three
## nodes with near-identical `along` and a few metres of `across` between them.
func branch_point(branch_id: String, along: float, across: float) -> Vector3:
	var heading: float = 0.0
	if branches.has(branch_id):
		heading = deg_to_rad(float((branches[branch_id] as Dictionary).get("heading_deg", 0.0)))
	# Heading 0° points along +X and turns toward +Z, so the map reads like a
	# compass rose seen from above; `right` is that heading turned a quarter turn.
	var fwd   := Vector3(cos(heading), 0.0, sin(heading))
	var right := Vector3(-sin(heading), 0.0, cos(heading))
	return hub_position + fwd * along + right * across


## Warns about edges that point at nothing and unlock conditions naming nodes
## that do not exist. Both are silent-wrong-map bugs otherwise: a bad `parent`
## just drops the node out of every route, and a typo'd `unlocked_by` id can
## never be satisfied, so the node stays invisible forever with no clue why.
func _validate() -> void:
	for id: String in nodes.keys():
		var n: Dictionary = nodes[id]
		var parent: String = String(n.get("parent", ""))
		if parent != hub_id and not nodes.has(parent):
			push_warning("[StoryMapData] node '%s' connects_from '%s', which does not exist." % [id, parent])
		var branch_id: String = String(n.get("branch", ""))
		if branch_id != "" and not branches.has(branch_id):
			push_warning("[StoryMapData] node '%s' is on unknown branch '%s'." % [id, branch_id])
		for req: String in (n.get("unlocked_by", PackedStringArray()) as PackedStringArray):
			if not nodes.has(req):
				push_warning("[StoryMapData] node '%s' is unlocked_by unknown node '%s'." % [id, req])
	if _has_cycle():
		push_error("[StoryMapData] connects_from forms a cycle — routing will not work.")


func _has_cycle() -> bool:
	for id: String in nodes.keys():
		var seen: Dictionary = {}
		var walk: String = id
		while walk != hub_id and nodes.has(walk):
			if seen.has(walk):
				return true
			seen[walk] = true
			walk = String((nodes[walk] as Dictionary).get("parent", hub_id))
	return false


# ── Queries ──────────────────────────────────────────────────────────────────

func has_node_id(id: String) -> bool:
	return id == hub_id or nodes.has(id)


func title_of(id: String) -> String:
	if id == hub_id:
		return hub_title
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	return String(n.get("title", id))


## The level number this node is, or 0 for the hub / an unnumbered node.
func level_of(id: String) -> int:
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	return int(n.get("level", 0))


## The beatmap key this node plays, or "" when no chart claims its level yet.
##
## Resolved through ContentDB's `song_order` index rather than stored in the map
## data. The chart is the thing that says which level it is, so a node and its
## chart cannot drift apart, and charting level 8 makes the level-8 node play it
## with no edit here. An explicit `song_key` in the JSON still wins, for a node
## that should point at a specific chart regardless of numbering.
func song_key_of(id: String) -> String:
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	var override: String = String(n.get("song_key", "")).strip_edges()
	if override != "":
		return override
	var level: int = int(n.get("level", 0))
	return ContentDB.key_for_order(level) if level > 0 else ""


func position_of(id: String) -> Vector3:
	if id == hub_id:
		return hub_position
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	return n.get("position", hub_position) as Vector3


func parent_of(id: String) -> String:
	if id == hub_id:
		return ""
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	return String(n.get("parent", hub_id))


## True when a chart claims this node's level. An unplayable node is a rift with
## nothing inside it yet.
func is_playable(id: String) -> bool:
	return song_key_of(id) != ""


## True when the node's own `unlocked_by` AND its branch's `unlocked_by` are all
## satisfied. The hub is always unlocked.
##
## ── Uncharted rifts are not gates ────────────────────────────────────────────
## A requirement is satisfied when it has been cleared — OR when it can never BE
## cleared, because no chart claims its level yet. Without that rule the run
## dead-ends on the first gap in the chart list: level 2 has no beatmap, so it
## can never be beaten, so levels 3 onward could never open and the map stopped
## at rift 2 forever.
##
## An uncharted requirement only counts once it is itself REACHABLE, though —
## otherwise rift 3 would sit on the map from the very first launch, because its
## only gate (rift 2) happens to be empty. So an uncharted node behaves as if it
## were cleared the instant it opens, which is what "skip it" actually means:
## progression runs straight through it to the next rift that has something in
## it. That is derived live from the chart list, never written to the save, so
## charting level 2 later makes it a real gate again with nothing stale on disk.
func is_unlocked(id: String, cleared: PackedStringArray) -> bool:
	return _is_unlocked(id, cleared, {})


func _is_unlocked(id: String, cleared: PackedStringArray, visiting: Dictionary) -> bool:
	if id == hub_id:
		return true
	if not nodes.has(id):
		return false
	# Something already beaten is always on the map, whatever its gates say now.
	# Charting a level the player has already run past would otherwise make the
	# rifts beyond it vanish out of an existing save.
	if id in cleared:
		return true
	if visiting.has(id):
		push_error("[StoryMapData] unlocked_by forms a cycle through '%s'." % id)
		return false
	visiting[id] = true

	var ok: bool = true
	var n: Dictionary = nodes[id]
	for req: String in (n.get("unlocked_by", PackedStringArray()) as PackedStringArray):
		if not _requirement_met(req, cleared, visiting):
			ok = false
			break
	if ok:
		var b: Dictionary = branches.get(String(n.get("branch", "")), {}) as Dictionary
		for req_b: String in (b.get("unlocked_by", PackedStringArray()) as PackedStringArray):
			if not _requirement_met(req_b, cleared, visiting):
				ok = false
				break

	visiting.erase(id)
	return ok


func _requirement_met(req: String, cleared: PackedStringArray, visiting: Dictionary) -> bool:
	if req in cleared:
		return true
	if not nodes.has(req):
		return false
	if is_playable(req):
		return false          # real content, and not beaten yet — a real gate
	return _is_unlocked(req, cleared, visiting)   # empty rift: pass straight through


## Every unlocked node id, in authored order.
func unlocked_ids(cleared: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in order:
		if is_unlocked(id, cleared):
			out.append(id)
	return out


## Every edge in the graph as {"from", "to"} — one per node, toward its parent.
func edges() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in order:
		out.append({"from": String((nodes[id] as Dictionary).get("parent", hub_id)), "to": id})
	return out


## Node ids from `from_id` up to the hub, hub last. Used to find where two
## routes meet.
func chain_to_hub(from_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	var walk: String = from_id
	var guard: int = 0
	while walk != "" and guard < 256:
		out.append(walk)
		if walk == hub_id:
			break
		walk = parent_of(walk)
		guard += 1
	return out


## The node ids to travel through to get from `from_id` to `to_id`, inclusive of
## both ends. The graph is a tree, so this is "up to the common ancestor, then
## back down" — no search needed, and it is stable regardless of unlock state.
func route(from_id: String, to_id: String) -> PackedStringArray:
	if from_id == to_id:
		return PackedStringArray([to_id])
	var up:   PackedStringArray = chain_to_hub(from_id)
	var down: PackedStringArray = chain_to_hub(to_id)

	var meet_up: int = up.size() - 1
	var meet_down: int = down.size() - 1
	for i in up.size():
		var idx: int = down.find(up[i])
		if idx != -1:
			meet_up = i
			meet_down = idx
			break

	var out := PackedStringArray()
	for i in meet_up + 1:
		out.append(up[i])
	for i in range(meet_down - 1, -1, -1):
		out.append(down[i])
	return out


## The world-space polyline for one edge, routed along the city's streets rather
## than cut straight across the blocks. Authored `via` points still work — they
## become intermediate stops, and each leg between them is road-routed too.
##
## This is the single source of both the dotted trail and the walker's route, so
## Meeko physically walks the line that is drawn.
func edge_points(a: String, b: String) -> PackedVector3Array:
	var stops := PackedVector3Array([position_of(a)])
	for bend: Vector3 in edge_via(a, b):
		stops.append(bend)
	stops.append(position_of(b))

	var out := PackedVector3Array()
	for i in range(1, stops.size()):
		var leg: PackedVector3Array = StoryCity.road_route(stops[i - 1], stops[i], hub_position)
		for j in leg.size():
			if i > 1 and j == 0:
				continue    # the previous leg already ended on this point
			out.append(leg[j])
	return out


## World-space waypoints for a whole route, road-routed end to end.
func waypoints(route_ids: PackedStringArray) -> PackedVector3Array:
	return travel_plan(route_ids).get("points", PackedVector3Array())


## Points plus the node id reached at each one ("" for a street corner), kept in
## step by being built together. They used to be assembled separately — the map
## rebuilt the id list by counting `via` points — which only held while a leg was
## a straight line. Road routing inserts corners, so anything counting hops would
## now silently mis-label which waypoint is a rift.
##
## Returns {"points": PackedVector3Array, "ids": PackedStringArray}.
func travel_plan(route_ids: PackedStringArray) -> Dictionary:
	var points := PackedVector3Array()
	var ids := PackedStringArray()
	if route_ids.is_empty():
		return {"points": points, "ids": ids}

	points.append(position_of(route_ids[0]))
	ids.append(route_ids[0])
	for i in range(1, route_ids.size()):
		var leg: PackedVector3Array = edge_points(route_ids[i - 1], route_ids[i])
		# Skip the leg's first point: the previous leg already ended there.
		for j in range(1, leg.size()):
			points.append(leg[j])
			ids.append(route_ids[i] if j == leg.size() - 1 else "")
	return {"points": points, "ids": ids}


## The `via` points on the edge between two adjacent route entries, oriented for
## travel a -> b. Only the child end of an edge owns them, so walking toward the
## hub reads the same list backwards.
func edge_via(a: String, b: String) -> PackedVector3Array:
	if parent_of(b) == a and nodes.has(b):
		return (nodes[b] as Dictionary).get("via", PackedVector3Array()) as PackedVector3Array
	if parent_of(a) == b and nodes.has(a):
		var fwd: PackedVector3Array = (nodes[a] as Dictionary).get("via", PackedVector3Array())
		var rev := PackedVector3Array()
		for i in range(fwd.size() - 1, -1, -1):
			rev.append(fwd[i])
		return rev
	return PackedVector3Array()


## Radius (on XZ) that contains the hub and every node — the camera and the city
## backdrop both size themselves off this instead of a magic number.
func extent() -> float:
	var r: float = 20.0
	for id: String in order:
		var p: Vector3 = position_of(id)
		r = maxf(r, Vector2(p.x - hub_position.x, p.z - hub_position.z).length())
	return r


# ── Parsing helpers ──────────────────────────────────────────────────────────

static func _to_vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


static func _to_ids(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if v is Array:
		for item: Variant in (v as Array):
			out.append(String(item))
	elif v is String and String(v) != "":
		out.append(String(v))
	return out
