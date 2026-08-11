extends Node
signal life_lost(new_lives)
signal section_cleared(section_type)
signal level_cleared(level_index)
var runner_pattern_mode: String = "run_random"
var run_seed = 0
var level_index = 0
var section_index = 0
var lives = 20
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
	lives = 20
	player_class = chosen_class
	temp_upgrades.clear()
	core_upgrades.clear()
	shards = 0
func lose_life():
	lives -= 1
	emit_signal("life_lost", lives)
	if lives <= 0:
		_game_over()
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
	lives = 20
func _game_over():
	print("[Run] GAME OVER: ejected to outside world.")
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
