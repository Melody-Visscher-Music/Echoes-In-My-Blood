extends Node
class_name LevelManager

signal level_looped

var _queue = []
var _current = null


func _ready() -> void:
	_build_queue()
	_load_next()


func _build_queue() -> void:
	_queue.clear()
	_queue.append("beat3d")



func _load_next() -> void:
	if _current != null:
		_current.queue_free()
		_current = null

	if _queue.is_empty():
		emit_signal("level_looped")
		Run.on_level_clear()
		_build_queue()

	var kind = _queue.pop_front()
	var scene_path: String = ""

	if kind == "runner":
		scene_path = "res://scenes/sections/Section_3DRunner.tscn"
	elif kind == "beat3d":
		scene_path = "res://scenes/beat3d/Section_BeatRunner3D.tscn"
	else:
		push_warning("Unknown section type: %s" % kind)
		_load_next()
		return

	var ps: PackedScene = load(scene_path)
	_current = ps.instantiate()
	add_child(_current)

	if _current.has_signal("section_finished"):
		_current.connect("section_finished", Callable(self, "_on_section_finished"))


## Section_BeatRunner3d does NOT emit `section_finished` — it owns its own
## lives, death screen and results panel end-to-end, so this never actually
## fires today. Kept (and kept harmless) for the section types that will:
## a failed section just re-loads, since the per-song lives that used to be
## spent here now live in Run.song_lives and are spent by the Section itself.
func _on_section_finished(passed: bool) -> void:
	if passed:
		Run.on_section_clear("generic")
	_load_next()
