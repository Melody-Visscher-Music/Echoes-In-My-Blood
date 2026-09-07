extends Node
func save_to_disk(slot):
	var cfg = ConfigFile.new()
	cfg.set_value("meta", "core_upgrades", Run.core_upgrades)
	cfg.set_value("meta", "unlocks_class", [Run.player_class])
	var path = _slot_path(slot)
	var err = cfg.save(path)
	if err != OK:
		push_warning("Save failed: " + str(err))
func load_from_disk(slot):
	var cfg = ConfigFile.new()
	var err = cfg.load(_slot_path(slot))
	if err != OK:
		return
	Run.core_upgrades = cfg.get_value("meta", "core_upgrades", [])
func _slot_path(slot):
	return "user://save_slot_%d.cfg" % slot

# ── High Score ───────────────────────────────────────────────────────────────
const _HS_PATH: String = "user://highscores.cfg"

## Returns {"score": int, "combo": int} for song_key, or zeros if no record.
func get_high_score(song_key: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(_HS_PATH) != OK:
		return {"score": 0, "combo": 0}
	return {
		"score": int(cfg.get_value(song_key, "score", 0)),
		"combo": int(cfg.get_value(song_key, "combo", 0)),
	}

## Returns true if a high score has been registered for ANY song. Used to
## gate the first-launch tutorial: once any record exists, the player has
## already played, so the tutorial is skipped on later launches.
func has_any_high_score() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(_HS_PATH) != OK:
		return false
	return cfg.get_sections().size() > 0

## Wipes every high score record and the used-seed log (dev tool).
func clear_all_high_scores() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_HS_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_SEEDS_PATH))
	print("[Save] All high scores and used seeds cleared.")

# ── Used-seed tracking ───────────────────────────────────────────────────────
const _SEEDS_PATH: String = "user://used_seeds.cfg"

## Returns true if this seed has already been played for song_key.
func is_seed_used(song_key: String, seed: int) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(_SEEDS_PATH) != OK:
		return false
	var used: Array = cfg.get_value(song_key, "seeds", [])
	return seed in used

## Permanently records seed as used for song_key.
func mark_seed_used(song_key: String, seed: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SEEDS_PATH)   # ignore error — file may not exist yet
	var used: Array = cfg.get_value(song_key, "seeds", [])
	if seed not in used:
		used.append(seed)
		cfg.set_value(song_key, "seeds", used)
		cfg.save(_SEEDS_PATH)

## Saves score+combo for song_key if they beat the current record.
## Returns true if a new high score was set (score strictly better), false otherwise.
func save_high_score(song_key: String, score: int, combo: int) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(_HS_PATH)   # ignore error — file may not exist yet
	var prev_score: int = int(cfg.get_value(song_key, "score", 0))
	var prev_combo: int = int(cfg.get_value(song_key, "combo", 0))
	var new_record: bool = score > prev_score
	cfg.set_value(song_key, "score", maxi(score, prev_score))
	cfg.set_value(song_key, "combo", maxi(combo, prev_combo))
	cfg.save(_HS_PATH)
	return new_record

# ── Story mode progress ──────────────────────────────────────────────────────
## Which story-map nodes have been cleared. That single list is the whole
## unlock state of the Story Mode map: StoryMapData turns it into which rifts
## are visible and which routes are drawn, so nothing else has to be persisted.
##
## Kept in its own file rather than in the save slot because it is progress, not
## a loadout — and because the slot only ever round-trips core_upgrades today.
## Freeplay does not read this, and this does not read Freeplay's high scores;
## the two modes stay independent.
const _STORY_PATH: String = "user://story_progress.cfg"

## Cleared story node ids. Order is the order they were cleared in.
func get_story_cleared() -> PackedStringArray:
	var cfg := ConfigFile.new()
	if cfg.load(_STORY_PATH) != OK:
		return PackedStringArray()
	var raw: Array = cfg.get_value("story", "cleared", [])
	var out := PackedStringArray()
	for id in raw:
		out.append(String(id))
	return out

func is_story_cleared(node_id: String) -> bool:
	return node_id in get_story_cleared()

## Records a story node as cleared. Returns true only if this was NEW — the map
## uses that to decide whether a reveal should play, so a re-clear stays quiet.
func mark_story_cleared(node_id: String) -> bool:
	if node_id.strip_edges() == "":
		return false
	var cfg := ConfigFile.new()
	cfg.load(_STORY_PATH)   # ignore error — file may not exist yet
	var cleared: Array = cfg.get_value("story", "cleared", [])
	if node_id in cleared:
		return false
	cleared.append(node_id)
	cfg.set_value("story", "cleared", cleared)
	cfg.save(_STORY_PATH)
	return true

## The map node Meeko is standing on, or "" for "start at the hub". Saved so
## coming back from a level puts him where he played it rather than walking him
## back to the middle of the city every time.
func get_story_position() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_STORY_PATH) != OK:
		return ""
	return String(cfg.get_value("story", "position", ""))

func set_story_position(node_id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_STORY_PATH)   # ignore error — file may not exist yet
	cfg.set_value("story", "position", node_id)
	cfg.save(_STORY_PATH)

## Wipes story progress, putting the map back to its opening state (dev tool).
func clear_story_progress() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_STORY_PATH))
	print("[Save] Story progress cleared.")
