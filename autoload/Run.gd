extends Node
## Cross-scene run state.
##
## NOTE ON LIVES: `song_lives` is the real, live system — three tries per song,
## owned and decremented by Section_BeatRunner3d (death screen, pause > RESTART),
## refilled on a clear and seeded from GameConfig.lives_per_song.
##
## There used to be a SECOND, older lives system here as well: `lives = 20`,
## `lose_life()`, a `life_lost` signal and a `_game_over()` that kicked the
## player back to the main menu. Nothing could reach it — its only caller was
## LevelManager._on_section_finished(), which fires off a `section_finished`
## signal that Section_BeatRunner3d has never declared or emitted. It is gone
## rather than left lying around looking authoritative.

signal section_cleared(section_type)
signal level_cleared(level_index)

var runner_pattern_mode: String = "run_random"
var run_seed = 0
var level_index = 0
var section_index = 0

# Reserved for the not-yet-built upgrade/shop layer. Save.save_to_disk() already
# persists these, so they stay even though nothing writes them during play yet.
var player_class = ""
var temp_upgrades = []
var core_upgrades = []
var shards = 0

var current_song_key: String = "stuck_in_a_game"
var song_lives: int = 3        # lives remaining for the current song attempt (per-song, not meta)

# ── Story Mode context ───────────────────────────────────────────────────────
## The story-map node whose level is currently loaded, or "" when the level was
## started from Freeplay. StoryMap sets it on the way in and clears it on the
## way back, so it is non-empty only while a story level is actually running.
##
## The level itself never learns what a story node IS — it only asks the three
## helpers below. That is what keeps Section_BeatRunner3d identical for both
## modes: Freeplay is simply "the story context is empty".
var story_node_id: String = ""

## Set when a story level is played to the end, and consumed by the map on the
## way back so it plays the reveal instead of just showing the newly opened rift
## already sitting there. Separate from the saved cleared-list on purpose: "is
## cleared" and "was JUST cleared" are different questions and only the second
## one should trigger a cutscene.
var story_just_cleared: String = ""

func in_story_mode() -> bool:
	return story_node_id != ""

## Where backing out of a level goes. Freeplay came from the song list, a story
## run came from the map, and each should return where it came from.
func level_exit_scene() -> String:
	return "res://scenes/story/StoryMap.tscn" if in_story_mode() else "res://scenes/SongSelect.tscn"

## The name for that destination. It lives next to the path deliberately — the
## death, pause and results screens each label this exit themselves, and a label
## that disagrees with where the button actually goes is worse than either.
## Each screen keeps its own icon; only the words come from here.
func level_exit_name() -> String:
	return "STORY MAP" if in_story_mode() else "SONG SELECT"

## Called by the runner when a song is played to the end. No-op in Freeplay, so
## the call site does not need to branch.
func on_story_level_cleared() -> void:
	if story_node_id == "":
		return
	Save.mark_story_cleared(story_node_id)
	Save.set_story_position(story_node_id)
	story_just_cleared = story_node_id

## Drops the story context, so a level started later from Freeplay is not
## mistaken for a story run.
func end_story_context() -> void:
	story_node_id = ""
	story_just_cleared = ""

func start_new_run(seed_value, chosen_class):
	run_seed = seed_value
	level_index = 0
	section_index = 0
	player_class = chosen_class
	temp_upgrades.clear()
	core_upgrades.clear()
	shards = 0
func add_temp_upgrade(id):
	if not temp_upgrades.has(id):
		temp_upgrades.append(id)
func on_section_clear(section_type):
	emit_signal("section_cleared", section_type)
	section_index += 1
func on_level_clear():
	for u in temp_upgrades:
		if not core_upgrades.has(u):
			core_upgrades.append(u)
	temp_upgrades.clear()
	emit_signal("level_cleared", level_index)
	level_index += 1
	section_index = 0
