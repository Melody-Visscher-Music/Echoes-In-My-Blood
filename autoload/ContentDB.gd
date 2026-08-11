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
