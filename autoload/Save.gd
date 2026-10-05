extends Node

## Everything the player keeps: progress, records, and what they own.
##
## ── One file, with a version on it ───────────────────────────────────────────
## This used to be four loose files — highscores.cfg, used_seeds.cfg,
## story_progress.cfg and save_slot_0.cfg — each opened, parsed and written on
## every single question asked of it, and none of them carrying any idea of what
## shape they were in. That was survivable while a save was a score and a list
## of cleared rifts. It stops being survivable the moment the lab starts selling
## upgrades: the day the shape has to change, there has to be a way to read the
## old one and move it forward, and a file with no version in it cannot be moved
## forward safely — you can only guess from which keys happen to be present.
##
## So: one file, read once into memory, written when something changes, with a
## VERSION at the top and a migration step for each change to the shape. The old
## files are imported the first time this runs and then renamed, not deleted —
## a save is somebody's hours, and nothing here throws one away.
##
## ── What belongs here, and what does not ─────────────────────────────────────
## This is PROGRESS. Settings — volume, key bindings, colours, graphics tier —
## belong to GameConfig and stay in its own file: a player wiping their progress
## should not lose their key bindings, and copying a save between machines
## should not drag another machine's graphics tier along with it.

const PATH: String = "user://save.cfg"
## Bump when the shape changes, and add a case to _migrate().
const VERSION: int = 1

## The pre-version files, imported once and then renamed out of the way.
const LEGACY_SCORES: String = "user://highscores.cfg"
const LEGACY_SEEDS: String = "user://used_seeds.cfg"
const LEGACY_STORY: String = "user://story_progress.cfg"
const LEGACY_SLOT: String = "user://save_slot_0.cfg"

## Sections. Scores and seeds get one section per song, prefixed so that a song
## called "story" or "meta" cannot collide with the game's own sections.
const S_META: String = "meta"
const S_PROFILE: String = "profile"
const S_STORY: String = "story"
const P_SCORE: String = "score."
const P_SEEDS: String = "seeds."

## Upgrade ids Anne's lab is expected to sell. They are only strings — this is
## the list as designed, not a limit; grant_upgrade() takes any id, and the shop
## decides what it offers. Named here so the game has one spelling of each.
const UPGRADE_EXTRA_LIFE: String = "extra_life"
const UPGRADE_MORE_HEALTH: String = "more_health"
const UPGRADE_OVERFILL_BAR: String = "overfill_bar"
const UPGRADE_COMBO_SHIELD: String = "combo_shield"

var _cfg: ConfigFile = null
var _path: String = PATH


func _ready() -> void:
	_open()


# ── The file ─────────────────────────────────────────────────────────────────

func _open() -> void:
	_cfg = ConfigFile.new()
	var err: int = _cfg.load(_path)
	if err == ERR_FILE_NOT_FOUND:
		_cfg.set_value(S_META, "version", VERSION)
		_import_legacy()
		_write()
		return
	if err != OK:
		# Unreadable, not absent. Keep it: a corrupt save is still the only copy
		# of somebody's progress, and a dev looking at it later is better than a
		# silent overwrite.
		var kept: String = "user://save.corrupt-%d.cfg" % Time.get_unix_time_from_system()
		DirAccess.rename_absolute(ProjectSettings.globalize_path(_path),
			ProjectSettings.globalize_path(kept))
		push_warning("[Save] %s would not load (error %d) — kept as %s, starting fresh." % [
			_path, err, kept])
		_cfg = ConfigFile.new()
		_cfg.set_value(S_META, "version", VERSION)
		_write()
		return

	var found: int = int(_cfg.get_value(S_META, "version", 0))
	if found != VERSION:
		_migrate(found)


## Moves a save forward a version at a time. Each step reads what the version
## before it wrote; none of them reads today's shape, so a save from three
## versions back comes forward through every step in turn.
func _migrate(from: int) -> void:
	if from > VERSION:
		# A save from a NEWER build. Leave it alone rather than mangling it.
		push_warning("[Save] save is version %d, this build knows %d — leaving it as it is." % [
			from, VERSION])
		return
	if from < 1:
		# v0 is "the four loose files"; a save.cfg at v0 should not exist, but
		# importing is harmless and better than dropping what is there.
		_import_legacy()
	_cfg.set_value(S_META, "version", VERSION)
	_write()
	print("[Save] migrated save from version %d to %d." % [from, VERSION])


## Reads the pre-version files into this one, then renames them so the import
## happens exactly once. Nothing is deleted.
func _import_legacy() -> void:
	var moved: Array[String] = []

	var scores := ConfigFile.new()
	if scores.load(LEGACY_SCORES) == OK:
		for song: String in scores.get_sections():
			_cfg.set_value(P_SCORE + song, "score", int(scores.get_value(song, "score", 0)))
			_cfg.set_value(P_SCORE + song, "combo", int(scores.get_value(song, "combo", 0)))
		moved.append(LEGACY_SCORES)

	var seeds := ConfigFile.new()
	if seeds.load(LEGACY_SEEDS) == OK:
		for song: String in seeds.get_sections():
			_cfg.set_value(P_SEEDS + song, "used", seeds.get_value(song, "seeds", []))
		moved.append(LEGACY_SEEDS)

	var story := ConfigFile.new()
	if story.load(LEGACY_STORY) == OK:
		for key: String in ["cleared", "position", "time_of_day", "time_stamp"]:
			if story.has_section_key(S_STORY, key):
				_cfg.set_value(S_STORY, key, story.get_value(S_STORY, key))
		moved.append(LEGACY_STORY)

	var slot := ConfigFile.new()
	if slot.load(LEGACY_SLOT) == OK:
		_cfg.set_value(S_PROFILE, "upgrades", slot.get_value("meta", "core_upgrades", []))
		var classes: Array = slot.get_value("meta", "unlocks_class", [])
		if classes.size() > 0:
			_cfg.set_value(S_PROFILE, "player_class", String(classes[0]))
		moved.append(LEGACY_SLOT)

	for old: String in moved:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(old),
			ProjectSettings.globalize_path(old + ".migrated"))
	if not moved.is_empty():
		print("[Save] imported %d older save files into %s." % [moved.size(), PATH])


func _write() -> void:
	var err: int = _cfg.save(_path)
	if err != OK:
		push_warning("[Save] could not write %s (error %d)." % [_path, err])


## Points the save at another file — for the dev harness, so a test round trip
## cannot touch a real save. Everything after this call reads and writes there.
func dev_use_path(path: String) -> void:
	_path = path
	_open()


# ── The player's profile ─────────────────────────────────────────────────────
# Shards buy upgrades at Anne's lab; upgrades are permanent and are what the
# health rework reads its ceiling from (the lab sells the bigger bar, so the
# ceiling is save state, never a constant).

func shards() -> int:
	return int(_cfg.get_value(S_PROFILE, "shards", 0))


func add_shards(amount: int) -> void:
	_cfg.set_value(S_PROFILE, "shards", maxi(0, shards() + amount))
	_write()


## Takes the shards if there are enough, and says whether it could.
func spend_shards(amount: int) -> bool:
	if amount <= 0 or shards() < amount:
		return false
	_cfg.set_value(S_PROFILE, "shards", shards() - amount)
	_write()
	return true


func owned_upgrades() -> PackedStringArray:
	var out := PackedStringArray()
	for id: Variant in (_cfg.get_value(S_PROFILE, "upgrades", []) as Array):
		out.append(String(id))
	return out


func has_upgrade(id: String) -> bool:
	return id in owned_upgrades()


## Returns true only if this upgrade is new, so a shop can tell "bought" from
## "already had it" without asking first.
func grant_upgrade(id: String) -> bool:
	if id.strip_edges() == "" or has_upgrade(id):
		return false
	var owned: Array = _cfg.get_value(S_PROFILE, "upgrades", [])
	owned.append(id)
	_cfg.set_value(S_PROFILE, "upgrades", owned)
	_write()
	return true


## Takes one back — for refunds, and for trying the game without it.
func revoke_upgrade(id: String) -> bool:
	var owned: Array = _cfg.get_value(S_PROFILE, "upgrades", [])
	if not (id in owned):
		return false
	owned.erase(id)
	_cfg.set_value(S_PROFILE, "upgrades", owned)
	_write()
	return true


## Copies the profile into Run for the session to read, and back again. Run is
## the working copy during a run; this file is the record.
func sync_to_run() -> void:
	Run.core_upgrades = Array(owned_upgrades())
	Run.shards = shards()
	Run.player_class = String(_cfg.get_value(S_PROFILE, "player_class", ""))


func sync_from_run() -> void:
	_cfg.set_value(S_PROFILE, "upgrades", Run.core_upgrades)
	_cfg.set_value(S_PROFILE, "shards", int(Run.shards))
	_cfg.set_value(S_PROFILE, "player_class", String(Run.player_class))
	_write()


# ── High scores ──────────────────────────────────────────────────────────────

## Returns {"score": int, "combo": int} for song_key, or zeros if no record.
func get_high_score(song_key: String) -> Dictionary:
	return {
		"score": int(_cfg.get_value(P_SCORE + song_key, "score", 0)),
		"combo": int(_cfg.get_value(P_SCORE + song_key, "combo", 0)),
	}


## Saves score+combo for song_key if they beat the current record.
## Returns true if a new high score was set (score strictly better).
func save_high_score(song_key: String, score: int, combo: int) -> bool:
	var prev: Dictionary = get_high_score(song_key)
	var record: bool = score > int(prev["score"])
	_cfg.set_value(P_SCORE + song_key, "score", maxi(score, int(prev["score"])))
	_cfg.set_value(P_SCORE + song_key, "combo", maxi(combo, int(prev["combo"])))
	_write()
	return record


## True if any song has a record. Gates the first-launch tutorial: once a record
## exists the player has played before.
func has_any_high_score() -> bool:
	for section: String in _cfg.get_sections():
		if section.begins_with(P_SCORE):
			return true
	return false


## Wipes every record and the used-seed log (dev tool).
func clear_all_high_scores() -> void:
	for section: String in _cfg.get_sections():
		if section.begins_with(P_SCORE) or section.begins_with(P_SEEDS):
			_cfg.erase_section(section)
	_write()
	print("[Save] All high scores and used seeds cleared.")


# ── Used-seed tracking ───────────────────────────────────────────────────────
# Story levels reshape on every attempt, so a seed that has been served once is
# never served again for that song.

func is_seed_used(song_key: String, seed: int) -> bool:
	return seed in (_cfg.get_value(P_SEEDS + song_key, "used", []) as Array)


func mark_seed_used(song_key: String, seed: int) -> void:
	var used: Array = _cfg.get_value(P_SEEDS + song_key, "used", [])
	if seed in used:
		return
	used.append(seed)
	_cfg.set_value(P_SEEDS + song_key, "used", used)
	_write()


# ── Story mode progress ──────────────────────────────────────────────────────
## Which story-map nodes have been cleared. That single list is the whole unlock
## state of the map: StoryMapData turns it into which rifts are visible and
## which routes are drawn, so nothing else about the map has to be persisted.

## Cleared story node ids, in the order they were cleared.
func get_story_cleared() -> PackedStringArray:
	var out := PackedStringArray()
	for id: Variant in (_cfg.get_value(S_STORY, "cleared", []) as Array):
		out.append(String(id))
	return out


func is_story_cleared(node_id: String) -> bool:
	return node_id in get_story_cleared()


## Records a story node as cleared. Returns true only if this was NEW — the map
## uses that to decide whether a reveal should play, so a re-clear stays quiet.
func mark_story_cleared(node_id: String) -> bool:
	if node_id.strip_edges() == "":
		return false
	var cleared: Array = _cfg.get_value(S_STORY, "cleared", [])
	if node_id in cleared:
		return false
	cleared.append(node_id)
	_cfg.set_value(S_STORY, "cleared", cleared)
	_write()
	return true


## The map node Meeko is standing on, or "" for "start at the hub". Saved so
## coming back from a level puts him where he played it rather than walking him
## back to the middle of the city every time.
func get_story_position() -> String:
	return String(_cfg.get_value(S_STORY, "position", ""))


func set_story_position(node_id: String) -> void:
	_cfg.set_value(S_STORY, "position", node_id)
	_write()


## The map's time of day, as a position in StoryMap.TIME_PRESETS, together with
## the wall-clock second it was written at.
##
## Both halves matter. Without the time the map opens at noon every visit, which
## is what it did before; without the STAMP the clock freezes the moment you look
## away, so a level could take five minutes and the city would not have moved —
## the thing that was supposed to feel alive would only be alive while watched.
##
## Returns time = -1.0 when nothing has been saved yet, meaning "pick a default".
func get_story_time() -> Dictionary:
	var t: float = float(_cfg.get_value(S_STORY, "time_of_day", -1.0))
	var stamp: int = int(_cfg.get_value(S_STORY, "time_stamp", 0))
	var now: int = int(Time.get_unix_time_from_system())
	# Guard a clock that has gone backwards (system time changed, or a save
	# copied from another machine): treat it as no time having passed rather
	# than winding the city backwards.
	var elapsed: float = maxf(0.0, float(now - stamp)) if stamp > 0 else 0.0
	return {"time": t, "elapsed": elapsed}


func set_story_time(t: float) -> void:
	_cfg.set_value(S_STORY, "time_of_day", t)
	_cfg.set_value(S_STORY, "time_stamp", int(Time.get_unix_time_from_system()))
	_write()


## Wipes story progress, putting the map back to its opening state (dev tool).
## Leaves records and the profile alone — this is the map, not the player.
func clear_story_progress() -> void:
	_cfg.erase_section(S_STORY)
	_write()
	print("[Save] Story progress cleared.")
