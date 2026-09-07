extends Node

var _beatmap_cache = {}
var current_beatmap_key: String = ""


func get_beatmap(key: String) -> Dictionary:
	var safe := key.strip_edges()
	if safe == "": return {}
	if _beatmap_cache.has(safe):
		return _beatmap_cache[safe]
	var try_paths := [
		"user://beatmaps/%s.json" % safe,
		"res://data/beatmaps/%s.json" % safe
	]
	for p in try_paths:
		if FileAccess.file_exists(p):
			var txt := FileAccess.get_file_as_string(p)
			var pr := JSON.new()
			var err := pr.parse(txt)
			if err == OK:
				var data: Dictionary = pr.get_data()
				_beatmap_cache[safe] = data
				return data
	return {}


# ── Song order index ─────────────────────────────────────────────────────────
## `song_order` in a beatmap is the chart's LEVEL NUMBER — "this chart is level
## 4" — not just a sort key. Freeplay only ever used it to order its list, so
## nothing in the game could answer "which chart is level 4?". Story Mode needs
## exactly that: its map nodes name a level number, and the chart that claims
## that number is the one that node plays. Charts do not have to be contiguous —
## having 1, 4 and 8 authored and nothing in between is normal mid-production.
##
## A chart with no `song_order` (or 0/negative) is unnumbered: it stays playable
## from Freeplay and simply has no level for the story map to reach it from.

const BEATMAP_DIRS: Array[String] = ["res://data/beatmaps", "user://beatmaps"]

var _order_to_key: Dictionary = {}   # int level number -> String beatmap key
var _key_to_order: Dictionary = {}   # String beatmap key -> int level number
var _index_built: bool = false


## Rebuilds the level-number index. Called lazily on first lookup; call it
## directly after writing a new chart so the map sees it without a restart.
func rebuild_song_index() -> void:
	_order_to_key.clear()
	_key_to_order.clear()
	_index_built = true

	var re := RegEx.new()
	re.compile('"song_order"\\s*:\\s*(-?[0-9]+)')

	# res:// first, user:// second, so a user chart overrides a shipped one of
	# the same name — the same precedence get_beatmap() uses.
	for dir_path: String in BEATMAP_DIRS:
		var dir: DirAccess = DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while entry != "":
			if not dir.current_is_dir() and entry.to_lower().ends_with(".json"):
				var key: String = entry.substr(0, entry.length() - 5)
				var order: int = _read_song_order("%s/%s" % [dir_path, entry], re)
				if order > 0:
					var prev: String = String(_order_to_key.get(order, ""))
					if prev != "" and prev != key:
						push_warning("[ContentDB] level %d is claimed by both '%s' and '%s' — '%s' wins." % [order, prev, key, key])
					_order_to_key[order] = key
					_key_to_order[key] = order
			entry = dir.get_next()
		dir.list_dir_end()


## Pulls `song_order` out of a chart WITHOUT parsing it.
##
## A beatmap is ~500 KB of note events and lyric data, and there will eventually
## be around forty of them; running the whole set through JSON.parse to read one
## integer each costs tens of megabytes of allocation on the way into the map
## screen. Reading the text and matching the one key is cheap, and the pattern is
## specific enough (a quoted JSON key, a colon, digits) that note or lyric data
## will not trip it. Anything unmatched reports 0 = unnumbered, which is also
## what a chart with no `song_order` reports — so a miss degrades to "not a story
## level" rather than to a wrong level.
func _read_song_order(path: String, re: RegEx) -> int:
	var txt: String = FileAccess.get_file_as_string(path)
	if txt == "":
		return 0
	var m: RegExMatch = re.search(txt)
	return int(m.get_string(1)) if m != null else 0


func _ensure_song_index() -> void:
	if not _index_built:
		rebuild_song_index()


## The beatmap key for a level number, or "" when no chart claims it yet.
func key_for_order(order: int) -> String:
	_ensure_song_index()
	return String(_order_to_key.get(order, ""))


## The level number a chart claims, or 0 when it is unnumbered.
func order_for_key(key: String) -> int:
	_ensure_song_index()
	return int(_key_to_order.get(key.strip_edges(), 0))


## Every level number that has a chart, ascending.
func song_orders() -> PackedInt32Array:
	_ensure_song_index()
	var out := PackedInt32Array()
	for order: int in _order_to_key.keys():
		out.append(order)
	out.sort()
	return out
