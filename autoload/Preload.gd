extends Node

## Loads what the NEXT screen needs while the player is still on this one.
##
## Both of the long waits in Story Mode have a stretch of time in front of them
## where nothing is being asked of the machine: the map sits idle while a rift
## is selected, and a level fades out for over a second on the way back. This
## does the file reading in those windows, on a worker thread, so the screen
## that follows finds its resources already in memory.
##
## ── What this can and cannot shorten ─────────────────────────────────────────
## Only the READING. A level spends most of its loading screen BUILDING — gates,
## track path, floors, decorations — and that is generated on the main thread
## from the chart, so it cannot be done early. Measured on this machine, of a
## level's ~1.8 s, about 150 ms is files; of the map's ~1.1 s, about 370 ms is
## the baked city. The map is the one that gains most, and it is also the one
## with no loading screen to hide behind.
##
## ── Why it is a hold, not just a request ─────────────────────────────────────
## Godot's resource cache only keeps what something still points at. Once a
## level frees its track pieces, loading them "again" is a fresh read off the
## disk. So a warmed set is HELD here until another set replaces it, and then
## load() during the next scene's build is a cache hit rather than a read.
##
## One set at a time, on purpose: the map holds the level's files, the level
## holds the map's, and whichever is warming now drops what the other left. Two
## sets held at once would be both screens' worth of memory for no gain.

## Resources of the set currently held, by path.
var _held: Dictionary = {}
## Paths requested and not yet collected, by path -> set name it belongs to.
var _pending: Dictionary = {}
## Paths waiting to be read on the main thread, one per frame. See warm_main().
var _slow: PackedStringArray = PackedStringArray()
var _set: String = ""


func _ready() -> void:
	set_process(false)


## Starts reading `paths` in the background as the named set, and drops the set
## held before it. Paths already held or already in flight are left alone, so
## calling this repeatedly — every time the map's selection moves, say — costs
## nothing after the first time.
func warm(set_name: String, paths: PackedStringArray) -> void:
	if set_name != _set:
		_set = set_name
		_held.clear()

	for path: String in paths:
		if path == "" or _held.has(path) or _pending.has(path):
			continue
		if not ResourceLoader.exists(path):
			continue
		# NO sub-threads. Reading the authored .glb track pieces with them on
		# crashes the engine later, when the level duplicates templates out of
		# those scenes and they are freed again — plain threaded reads of the
		# same files are fine, and so is holding them. Not worth the
		# milliseconds it would save on the city.
		if ResourceLoader.load_threaded_request(path) == OK:
			_pending[path] = set_name
	set_process(not _pending.is_empty())


## Lets go of a set once it is clear it is not wanted after all — the player
## un-paused and is still playing, so the map they might have quit to is just
## memory now. In-flight reads are still collected, they are simply not kept.
func drop(set_name: String) -> void:
	if _set != set_name:
		return
	_set = ""
	_held.clear()
	_slow.clear()


## Reads these on the MAIN thread instead, one file per frame.
##
## Godot's threaded loader and the authored .glb track pieces do not get on.
## Warmed on a worker thread and then left for a level to duplicate templates
## out of, they crash the engine when those are freed — sometimes immediately,
## sometimes only at shutdown, and not every run. Plain reads of the same files,
## held the same way, are fine. They are small and the map is sitting still, so
## one per frame costs nothing and buys the same head start.
func warm_main(set_name: String, paths: PackedStringArray) -> void:
	if set_name != _set:
		_set = set_name
		_held.clear()
	for path: String in paths:
		if path == "" or _held.has(path) or _slow.has(path):
			continue
		if ResourceLoader.exists(path):
			_slow.append(path)
	set_process(not _pending.is_empty() or not _slow.is_empty())


## True once nothing is still being read — only for the dev readout and tests.
func is_idle() -> bool:
	return _pending.is_empty() and _slow.is_empty()


func held_count() -> int:
	return _held.size()


func _process(_delta: float) -> void:
	for path: String in _pending.keys():
		match ResourceLoader.load_threaded_get_status(path):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			ResourceLoader.THREAD_LOAD_LOADED:
				var res: Resource = ResourceLoader.load_threaded_get(path)
				# Anything that finished for a set we have since moved on from
				# still has to be collected — the loader keeps it pending
				# otherwise — but it is not worth holding.
				if res != null and String(_pending[path]) == _set:
					_held[path] = res
				_pending.erase(path)
			_:
				push_warning("[Preload] could not read %s" % path)
				_pending.erase(path)

	# One main-thread read per frame, so a long list cannot cost a frame.
	if not _slow.is_empty():
		var path: String = _slow[0]
		_slow.remove_at(0)
		var res: Resource = load(path)
		if res != null:
			_held[path] = res

	set_process(not _pending.is_empty() or not _slow.is_empty())
