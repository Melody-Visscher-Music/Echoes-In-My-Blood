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
