## TrackPieceLibrary — registry of authored Blender track pieces.
##
## Scans res://assets/track/ (recursively) for .glb / .gltf / .tscn scenes
## exported from Blender with the SIAG Track Builder add-on. Each piece is
## recognised by glTF-extras metadata (siag_type, siag_length, siag_radius,
## siag_direction, siag_bank_deg, …) which the add-on's "Export Selected →
## .glb" button writes automatically. As a fallback, pieces are recognised by
## their object names (TrackStraight_10m, TrackTurn90L_r20m, GrindRail_30m,
## JumpHurdle, SlideGate, LaneBlocker, NeonArch, WallPlate, Ledge, …).
##
## Section_BeatRunner3d asks this library what exists: authored pieces are
## instanced along the generated path (positioned, rotated and banked to fit),
## and the matching procedural visuals are skipped. Anything NOT found here is
## generated procedurally exactly like before. Collision is always procedural.
##
## Piece types: straight, turn, rail, hurdle, slide, blocker, arch, strip,
## marks, lightpost, beacon, wj_ledge, wj_plate, wj_kit, wj_slide,
## charge_hoop, spark, pylon, fence_post, halo, gem, deco_arch, pad,
## haze_pillar, building.
class_name TrackPieceLibrary
extends RefCounted

const PIECES_DIR := "res://assets/track"

## Each entry: { "type": String, "params": Dictionary, "template": Node3D,
##               "source": String, "animated": bool }
## "animated" = the piece brought its own glTF animation loop(s); a "SIAGAnim"
## AnimationPlayer on the template autoplays them, and the runner skips its
## own procedural motion (gem/crystal/halo spins) for that piece.
var _entries: Array[Dictionary] = []
var _by_type: Dictionary = {}            # type -> Array[Dictionary]

# Optional player character scene discovered during scanning.
var character_scene: PackedScene = null
var character_source: String = ""


func scan() -> void:
	clear()
	_scan_dir(PIECES_DIR)
	if _entries.is_empty():
		print("[TrackPieceLibrary] no authored pieces in %s — full procedural generation." % PIECES_DIR)
	else:
		var summary: Dictionary = {}
		for e in _entries:
			summary[e.type] = int(summary.get(e.type, 0)) + 1
		print("[TrackPieceLibrary] authored pieces: ", summary)


## Free the orphan template nodes (call from _exit_tree of the owner).
func clear() -> void:
	for e in _entries:
		var t: Node3D = e.template as Node3D
		if is_instance_valid(t):
			t.free()
	_entries.clear()
	_by_type.clear()
	character_scene = null
	character_source = ""


# ── Queries ───────────────────────────────────────────────────────────────────

func has_type(t: String) -> bool:
	return _by_type.has(t)


func first_of(t: String) -> Dictionary:
	var arr: Array = _by_type.get(t, [])
	return arr[0] if not arr.is_empty() else {}


func of_type(t: String) -> Array:
	return _by_type.get(t, [])


## Every discovered piece, regardless of type — used by ShaderWarmup.gd to
## instance one of everything so the GPU driver compiles each piece's render
## pipeline once, up front, instead of the first time it's actually seen in
## a level.
func all_entries() -> Array[Dictionary]:
	return _entries


## Returns the authored ledge for a given 1-based jump index (1 = first landing,
## 2 = second, … 8 = eighth).  Falls back to the generic wj_ledge if no
## index-specific piece exists, then to an empty dict if neither is present.
## This lets each jump slot have a unique shape while a single generic piece
## still covers all slots as a fallback.
func ledge_for_index(idx: int) -> Dictionary:
	var typed: Dictionary = first_of("wj_ledge_%d" % idx)
	if not typed.is_empty():
		return typed
	return first_of("wj_ledge")


## Entry of type t whose siag_variant matches (e.g. "left"/"right" blockers).
## Falls back to a variant-less (generic) entry, then to any entry of the type.
func variant_of(t: String, variant: String) -> Dictionary:
	var generic: Dictionary = {}
	for e in of_type(t):
		var v: String = String(e.params.get("variant", ""))
		if v == variant:
			return e
		if v == "" and generic.is_empty():
			generic = e
	return generic if not generic.is_empty() else first_of(t)


## Longest authored straight whose length fits in max_len (+small tolerance).
func best_straight(max_len: float) -> Dictionary:
	var best: Dictionary = {}
	var best_len: float = 0.0
	for e in of_type("straight"):
		var l: float = float(e.params.get("length", 0.0))
		if l > best_len and l <= max_len + 0.02:
			best_len = l
			best = e
	return best


## Shortest authored straight (used scaled-down to close remainder gaps).
func shortest_straight() -> Dictionary:
	var best: Dictionary = {}
	var best_len: float = INF
	for e in of_type("straight"):
		var l: float = float(e.params.get("length", 0.0))
		if l > 0.0 and l < best_len:
			best_len = l
			best = e
	return best


## Sorted unique radii of all authored corner pieces. The path generator only
## picks corner radii from this list, so every arc has a matching asset.
func turn_radii() -> Array:
	var out: Array = []
	for e in of_type("turn"):
		var r: float = float(e.params.get("radius", 0.0))
		if r > 0.0 and not out.has(r):
			out.append(r)
	out.sort()
	return out


## Authored 90° corner matching radius (within tol metres) and direction label.
## Prefers the closest radius; among equals prefers bank_mode "GAME".
func match_turn(radius: float, dir_label: String, tol: float = 0.75) -> Dictionary:
	var best: Dictionary = {}
	var best_err: float = tol + 1.0
	for e in of_type("turn"):
		if String(e.params.get("direction", "")) != dir_label:
			continue
		var err: float = absf(float(e.params.get("radius", -1000.0)) - radius)
		if err > tol:
			continue
		var better: bool = err < best_err - 0.001
		if not better and absf(err - best_err) <= 0.001:
			better = String(e.params.get("bank_mode", "")) == "GAME" \
				and String(best.get("params", {}).get("bank_mode", "")) != "GAME"
		if better:
			best_err = err
			best = e
	return best


## Fresh copy of an entry's node tree (children + transforms, identity root).
func instance(entry: Dictionary) -> Node3D:
	var tpl: Node3D = entry.template as Node3D
	return tpl.duplicate() as Node3D



## Returns true if a SIAGCharacter scene was discovered.
func has_character() -> bool:
	return character_scene != null


## Instantiates the discovered SIAGCharacter scene.
func instance_character() -> Node3D:
	if character_scene == null:
		return null
	return character_scene.instantiate() as Node3D


# ── Scanning ──────────────────────────────────────────────────────────────────

func _scan_dir(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn: String = dir.get_next()
	while fn != "":
		if dir.current_is_dir():
			if not fn.begins_with("."):
				_scan_dir(path.path_join(fn))
		else:
			var full: String = path.path_join(fn)
			# In exported builds imported scenes appear as .remap files.
			if full.ends_with(".remap"):
				full = full.trim_suffix(".remap")
			var ext: String = full.get_extension().to_lower()
			if ext == "glb" or ext == "gltf" or ext == "tscn" or ext == "scn":
				_scan_scene(full)
		fn = dir.get_next()
	dir.list_dir_end()


func _scan_scene(res_path: String) -> void:
	if not ResourceLoader.exists(res_path):
		return
	var ps: PackedScene = load(res_path) as PackedScene
	if ps == null:
		return

	# Special case: automatically register a player character scene.
	var file_name := res_path.get_file().to_lower()
	if file_name == "siagcharacter.glb" or file_name == "siagcharacter.gltf" or file_name == "siagcharacter.tscn" or file_name == "siagcharacter.scn":
		character_scene = ps
		character_source = res_path
		print("[TrackPieceLibrary] found SIAGCharacter: %s" % res_path)
		return
	var root: Node = ps.instantiate()
	if root == null:
		return
	_collect(root, root, res_path)
	root.free()


## Walk the scene; every node that identifies as a SIAG piece becomes an entry
## (its whole subtree is the piece — children are the colourable parts).
func _collect(node: Node, scene_root: Node, source: String) -> void:
	var info: Dictionary = _identify(node)
	if not info.is_empty() and node is Node3D:
		var tpl: Node3D = (node as Node3D).duplicate() as Node3D
		tpl.transform = Transform3D.IDENTITY   # user may have moved it in the .blend
		var entry: Dictionary = {
			"type": info.type, "params": info.params,
			"template": tpl, "source": source,
			"animated": _attach_piece_animations(scene_root, node as Node3D, tpl),
		}
		_entries.append(entry)
		if not _by_type.has(info.type):
			_by_type[info.type] = []
		(_by_type[info.type] as Array).append(entry)
		return   # don't recurse into a piece — children are its parts
	for c in node.get_children():
		_collect(c, scene_root, source)


## glTF import puts ONE AnimationPlayer at the scene root, with track paths
## reaching into every piece in the file. Pieces are duplicated OUT of that
## scene, which would orphan their animations — so every track that targets
## this piece's subtree is copied into a fresh "SIAGAnim" AnimationPlayer on
## the template, its path rewritten relative to the piece root, merged into a
## single looping autoplay animation. Instancing the template then plays the
## authored loops automatically wherever the piece is used.
## Tracks aimed at the piece ROOT are skipped (the game owns the root
## transform for placement / mirroring / stretching) — animate child parts.
## Returns true when at least one track was attached.
func _attach_piece_animations(scene_root: Node, piece: Node3D, tpl: Node3D) -> bool:
	var merged: Animation = null
	var players: Array = []
	var stack: Array = [scene_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == piece:
			continue   # players INSIDE the piece duplicate with it already
		if n is AnimationPlayer:
			players.append(n)
		for c in n.get_children():
			stack.append(c)

	for ap_v in players:
		var ap: AnimationPlayer = ap_v as AnimationPlayer
		var base: Node = ap.get_node_or_null(ap.root_node)
		if base == null:
			base = ap.get_parent()
		if base == null:
			continue
		for anim_name in ap.get_animation_list():
			var src: Animation = ap.get_animation(anim_name)
			if src == null:
				continue
			for ti in range(src.get_track_count()):
				var tp: NodePath = src.track_get_path(ti)
				var target: Node = base.get_node_or_null(NodePath(String(tp.get_concatenated_names())))
				if target == null:
					continue
				if target == piece:
					print("[TrackPieceLibrary] %s: animation targets the piece ROOT — "
						% piece.name, "skipped (animate child parts instead)")
					continue
				if not piece.is_ancestor_of(target):
					continue
				if merged == null:
					merged = Animation.new()
				merged.length = maxf(merged.length, src.length)
				var nti: int = merged.get_track_count()
				src.copy_track(ti, merged)
				var sub: String = String(tp.get_concatenated_subnames())
				var rel: String = String(piece.get_path_to(target))
				merged.track_set_path(nti,
					NodePath(rel + (":" + sub if sub != "" else "")))

	if merged == null:
		return false
	merged.loop_mode = Animation.LOOP_LINEAR
	var alib := AnimationLibrary.new()
	alib.add_animation("piece", merged)
	var player := AnimationPlayer.new()
	player.name = "SIAGAnim"
	tpl.add_child(player)
	player.add_animation_library("", alib)
	player.autoplay = "piece"
	return true


func _identify(node: Node) -> Dictionary:
	# 1. Metadata (glTF extras → node meta, written by the Blender add-on)
	if node.has_meta("siag_type"):
		var params: Dictionary = {}
		for m in node.get_meta_list():
			var ms: String = String(m)
			if ms.begins_with("siag_") and ms != "siag_type":
				params[ms.trim_prefix("siag_")] = node.get_meta(m)
		return {"type": String(node.get_meta("siag_type")), "params": params}

	# 2. Name fallback (metadata missing — e.g. exported without extras)
	var n: String = String(node.name)
	var re_straight := RegEx.create_from_string("^TrackStraight_([0-9_\\.]+)m")
	var rm: RegExMatch = re_straight.search(n)
	if rm != null:
		return {"type": "straight", "params": {"length": _num(rm.get_string(1))}}
	var re_turn := RegEx.create_from_string("^TrackTurn90([LR])_r([0-9_\\.]+)m")
	rm = re_turn.search(n)
	if rm != null:
		return {"type": "turn", "params": {
			"direction": rm.get_string(1), "radius": _num(rm.get_string(2)),
			"bank_deg": 21.0, "bank_mode": "GAME"}}
	var re_rail := RegEx.create_from_string("^GrindRail_([0-9_\\.]+)m")
	rm = re_rail.search(n)
	if rm != null:
		return {"type": "rail", "params": {"length": _num(rm.get_string(1)), "side": "LEFT"}}

	const NAME_MAP: Dictionary = {
		"JumpHurdle": "hurdle", "SlideGate": "slide", "LaneBlocker": "blocker",
		"NeonArch": "arch", "SafeStrip": "strip", "ApproachMarks": "marks",
		"LightPost": "lightpost", "Beacon": "beacon", "WallPlate": "wj_plate",
		"Ledge": "wj_ledge", "WallJumpKit": "wj_kit",
		# v2.2 pieces — WJ descent slide, charge tunnel, sparks, electric
		# theme, halos, world deco, city buildings.
		"WJSlide": "wj_slide", "ChargeHoop": "charge_hoop", "Spark": "spark",
		"Pylon": "pylon", "FencePost": "fence_post", "Halo": "halo",
		"Gem": "gem", "DecoArch": "deco_arch", "PulsePad": "pad",
		"HazePillar": "haze_pillar", "Building": "building",
		# Indexed ledge slots — WJLedge_01 through WJLedge_08 map to wj_ledge_1 … wj_ledge_8.
		# Export each shaped ledge from Blender with the matching name (or siag_type metadata).
		"WJLedge_01": "wj_ledge_1", "WJLedge_02": "wj_ledge_2",
		"WJLedge_03": "wj_ledge_3", "WJLedge_04": "wj_ledge_4",
		"WJLedge_05": "wj_ledge_5", "WJLedge_06": "wj_ledge_6",
		"WJLedge_07": "wj_ledge_7", "WJLedge_08": "wj_ledge_8",
	}
	for prefix in NAME_MAP.keys():
		if n.begins_with(prefix):
			return {"type": NAME_MAP[prefix], "params": {}}
	return {}


## Parse a number that may have had its '.' replaced by '_' during node-name
## sanitising on import ("17_5" → 17.5).
static func _num(s: String) -> float:
	if s.contains(".") or not s.contains("_"):
		return s.to_float()
	return s.replace("_", ".").to_float()
