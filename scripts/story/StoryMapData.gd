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
## The one side of the plaza Meeko uses. A rift takes whichever street is
## nearest, because a rift is a hole in a pavement and any pavement will do; the
## plaza is a built place with a way in, and using all four sides made it read
## as a roundabout rather than as somewhere you arrive at.
##
## Authored as `"facing"` on the hub in the map JSON: +Z is the near side on
## screen (the map camera looks down the -Z axis, so +Z is the bottom edge).
## Flip the sign, or move it to the X axis, to enter from another side.
var hub_facing: Vector3 = Vector3(0.0, 0.0, 1.0)
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
	if hub.has("facing"):
		var hf: Vector3 = _to_vec3(hub.get("facing"))
		if hf.length_squared() > 0.001:
			hub_facing = hf.normalized()

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

		# Branch maths puts a node wherever the numbers land, which is as often in
		# the middle of a junction as anywhere else. Every derived position is
		# pulled onto the nearest block's street frontage: on the pavement, a
		# building line behind it, the road in front. An explicit "position" is
		# taken as authored and left exactly where it was put.
		var pos: Vector3
		var facing := Vector3(0.0, 0.0, 1.0)
		if n.has("position"):
			pos = _to_vec3(n.get("position"))
		else:
			pos = branch_point(branch_id, float(n.get("along", 0.0)), float(n.get("across", 0.0)))
			var front: Dictionary = StoryCity.street_frontage(pos, hub_position)
			pos = front["pos"]
			facing = front["facing"]

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
			# Which way the rift looks: out at the road it fronts onto.
			"facing": facing,
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


## The direction a rift faces — out toward the street it fronts onto, so the
## wall variant's facade ends up behind it inside the block rather than standing
## in the road.
func facing_of(id: String) -> Vector3:
	if id == hub_id:
		return hub_facing
	var n: Dictionary = nodes.get(id, {}) as Dictionary
	return n.get("facing", Vector3(0.0, 0.0, 1.0)) as Vector3


## Replaces node positions with ones authored in the baked city scene. Anchors
## dragged around in the editor win over the branch maths, and the POSITION is
## taken exactly as placed — no frontage snapping, because a hand-placed spot is
## a decision.
##
## The facing is NOT taken from the marker, though. It is re-derived from where
## the anchor now sits, so a rift always exits onto the street nearest to it.
## Marker rotation is a thing nobody remembers to update while dragging things
## around, and a stale one sent routes across whole blocks to reach a road the
## rift used to front. Move an anchor anywhere and the route re-solves.
func apply_anchor_overrides(anchors: Dictionary) -> void:
	for id: String in anchors.keys():
		if not nodes.has(id):
			push_warning("[StoryMapData] scene has an anchor for unknown node '%s'." % id)
			continue
		var t: Transform3D = anchors[id]
		var n: Dictionary = nodes[id]
		n["position"] = t.origin
		n["facing"] = StoryCity.nearest_street_facing(t.origin, hub_position)
		nodes[id] = n


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


## The world-space polyline for one edge, routed along the city's streets rather
## than cut straight across the blocks. Authored `via` points still work — they
## become intermediate stops, and each leg between them is road-routed too.
##
## This is the single source of both the dotted trail and the walker's route, so
## Meeko physically walks the line that is drawn.
func edge_points(a: String, b: String) -> PackedVector3Array:
	var stops := PackedVector3Array([doorstep_of(a)])
	for bend: Vector3 in edge_via(a, b):
		stops.append(bend)
	stops.append(doorstep_of(b))

	var pts := PackedVector3Array([position_of(a)])
	for i in range(1, stops.size()):
		for p: Vector3 in StoryCity.road_route(stops[i - 1], stops[i], hub_position):
			pts.append(p)
	pts.append(position_of(b))
	return StoryCity.dedupe_points(pts)


## Where a node meets the road.
##
## For a rift that is its doorstep, on whichever street it sits nearest. For the
## hub it is the ONE side the plaza opens onto — every journey to or from the
## plaza leaves and arrives there, rather than cutting across it to whichever
## road happens to be closest to where it is going.
func doorstep_of(id: String) -> Vector3:
	if id == hub_id:
		return StoryCity.frontage_doorstep(hub_position, hub_facing, hub_position)
	if not nodes.has(id):
		return position_of(id)
	return StoryCity.frontage_doorstep(position_of(id), facing_of(id), hub_position)


## The route Meeko actually walks: the shortest way through the STREETS from one
## node to another, with no regard for how the map unlocks.
##
## Travel used to follow the unlock tree — up to the common ancestor and back
## down again — so crossing from rift 5 to rift 8 marched him through 3, 2, 1
## and the hub on the way. The tree says what OPENS what; it says nothing about
## how far apart two places are in a city. Any two points on a street grid are
## directly reachable, so this just routes between them and lets the trails go
## on showing the unlock structure, which is what they are for.
##
## Returns {"points": PackedVector3Array, "ids": PackedStringArray}, the ids
## naming only the two ends — every point between is a street corner.
func direct_plan(from_id: String, to_id: String) -> Dictionary:
	var points: PackedVector3Array = edge_points(from_id, to_id)
	var ids := PackedStringArray()
	for _i in points.size():
		ids.append("")
	if points.size() > 0:
		ids[0] = from_id
		ids[points.size() - 1] = to_id
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
