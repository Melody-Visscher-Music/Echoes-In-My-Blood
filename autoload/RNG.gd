extends Node
var _rng = RandomNumberGenerator.new()
func seed_for_section(section_key):
	var base_str = str(Run.run_seed) + ":" + str(Run.level_index) + ":" + str(Run.section_index) + ":" + section_key
	var h = hash(base_str)
	if h < 0:
		h = -h
	_rng.seed = h
	return h
func randi_range_i(a, b):
	return _rng.randi_range(a, b)
func randf():
	return _rng.randf()
