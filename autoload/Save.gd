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
