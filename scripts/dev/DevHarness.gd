extends Node

## The dev harness: one place for the jobs that keep needing doing, instead of a
## throwaway scene each time.
##
##   godot --path . --windowed res://scenes/_dev/DevHarness.tscn -- <mode>
##
## Run it from the editor too (F6) — with no arguments it verifies.
##
##   verify            checks the content and the baked city, then exits
##                     non-zero if anything failed. This is the regression net.
##   perf              draw calls and frame time on the map, by day and night
##   loadtime          what a level and the map cost to open, cold and warmed
##   shots <prefix>    the standard screenshots, to <prefix>_*.png
##   play <seconds>    runs a story level for real and watches it: screenshots
##                     as it goes, worst frame times, and how much of the track
##                     built itself on the way (see _build_gate_body)
##   bake              re-bakes Calder City, then verifies it
##
## BAKE AND SHOTS MUST RUN WINDOWED. Headless has no renderer: a bake done that
## way saves every MultiMesh (the streetlights) with no transforms at all, and
## nobody notices until the city is on screen at night with no lamps lit.

const MAP_SCENE: String = "res://scenes/story/StoryMap.tscn"
const GAME_SCENE: String = "res://scenes/GameScene.tscn"
const RUNNER_SCENE: String = "res://scenes/beat3d/Section_BeatRunner3D.tscn"
const BEATMAP_DIR: String = "res://data/beatmaps"
## Where shots land.
const SHOT_DIR: String = "user://devshots"
## The copy of the save every run works on. Never the player's own file.
const RUN_SAVE: String = "user://devsave_run.cfg"

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "verify"
	var arg: String = args[1] if args.size() > 1 else ""
	print("-- dev harness: %s --" % mode)
	# Every frame-time number here is worthless with V-Sync on: the display
	# caps at 60 Hz, so a frame that really costs 9 ms and one that really
	# costs 16 ms both measure 16.67, and a change looks free right up until
	# it pushes past the cap and halves the rate. Engine.max_fps = 0 does not
	# cover this — that is the engine's own limiter, not the presentation one.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_sandbox_save()
	match mode:
		"verify":
			await _verify()
		"perf":
			await _perf()
		"loadtime":
			await _loadtime()
		"shots":
			await _shots(arg if arg != "" else "shot")
		"ui":
			await _ui_shots()
		"tiers":
			await _tiers(arg)
		"ablate":
			await _ablate()
		"candidates":
			await _candidates()
		"compare":
			await _compare_looks()
		"upgrades":
			await _upgrades()
		"world":
			await _world_density()
		"elec":
			await _electric_zones(arg)
		"bigmesh":
			await _big_meshes()
		"bake":
			await _bake()
		"play":
			await _play(float(arg) if arg != "" else 14.0,
				args[2] if args.size() > 2 else "")
		_:
			print("unknown mode '%s' - try verify | perf | loadtime | shots | ui | tiers | ablate | candidates | bake" % mode)
	if _checks > 0:
		print("-- %d checks, %d failed --" % [_checks, _failures])
	_release_save()
	get_tree().quit(1 if _failures > 0 else 0)


## Every mode here boots the map or a level, and both of those write as they go:
## the map persists the time of day, a death rolls a seed off the never-seen
## list, a finished song files a high score. So the whole run works on a COPY of
## the save and deletes it afterwards — a dev run must not move the player's
## clock or spend their seeds.
func _sandbox_save() -> void:
	var copy := ConfigFile.new()
	if copy.load(Save.PATH) == OK:
		copy.save(RUN_SAVE)
	Save.dev_use_path(RUN_SAVE)


func _release_save() -> void:
	Save.dev_use_path(Save.PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RUN_SAVE))


# ── Checking ─────────────────────────────────────────────────────────────────

func _check(ok: bool, what: String) -> bool:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL  %s" % what)
	return ok


## Everything that can be checked without playing the game.
func _verify() -> void:
	_verify_charts()
	_verify_story_map()
	await _verify_baked_city()
	await _verify_boots()
	_verify_save()
	await _verify_rules()
	await _verify_menus()
	await _verify_lazy_gates()


## Charts have to parse, point at a song that exists, and not fight over a level
## number — two charts claiming level 4 means one of them is unreachable, and
## which one you get is down to directory order.
func _verify_charts() -> void:
	print("charts:")
	var dir := DirAccess.open(BEATMAP_DIR)
	if not _check(dir != null, "%s is missing" % BEATMAP_DIR):
		return
	var orders: Dictionary = {}
	for file: String in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var key: String = file.get_basename()
		var data: Dictionary = ContentDB.get_beatmap(key)
		if not _check(not data.is_empty(), "%s does not parse" % file):
			continue
		var song: String = String(data.get("song_path", ""))
		_check(song != "", "%s has no song_path" % file)
		if song.begins_with("res://"):
			_check(ResourceLoader.exists(song), "%s points at a missing song: %s" % [file, song])
		var order: int = int(data.get("song_order", 0))
		if order > 0:
			_check(not orders.has(order), "level %d is claimed by both %s and %s" % [
				order, String(orders.get(order, "")), key])
			orders[order] = key
		print("  %-24s level %-4s %d events" % [key, str(order) if order > 0 else "-",
			(data.get("events", []) as Array).size()])


## The map's own data: it has to load, every node has to hang off something that
## exists, and a node claiming a level nothing charts is worth saying out loud —
## that rift sits on the map unplayable.
func _verify_story_map() -> void:
	print("story map:")
	var data := StoryMapData.load_from()
	if not _check(data.load_error == "", "story_map.json: %s" % data.load_error):
		return
	_check(data.order.size() > 0, "story map has no nodes")
	for id: String in data.order:
		var parent: String = data.parent_of(id)
		_check(parent == data.hub_id or data.has_node_id(parent),
			"%s hangs off '%s', which is not a node" % [id, parent])
		var level: int = data.level_of(id)
		if level > 0 and data.song_key_of(id) == "":
			print("  note: %s is level %d - nothing charts that yet" % [id, level])
	print("  %d nodes, hub '%s'" % [data.order.size(), data.hub_id])


## The baked city. These are the things that have actually gone wrong: a bake run
## headless saved its streetlights with no transforms, and anchors left over from
## an older map data file put rifts where no rift is.
func _verify_baked_city() -> void:
	print("baked city:")
	if not _check(ResourceLoader.exists(StoryMap.BAKED_CITY),
			"%s is missing - bake it" % StoryMap.BAKED_CITY):
		return
	var city: Node = (load(StoryMap.BAKED_CITY) as PackedScene).instantiate()
	add_child(city)
	await get_tree().process_frame

	var counts: Dictionary = {"mesh": 0, "multi": 0, "empty": 0, "instances": 0}
	var skins: Dictionary = {}
	_walk(city, func(n: Node) -> void:
		if n is MeshInstance3D:
			counts["mesh"] = int(counts["mesh"]) + 1
			_note_skins((n as MeshInstance3D).mesh, skins)
		elif n is MultiMeshInstance3D:
			counts["multi"] = int(counts["multi"]) + 1
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			if mm == null or mm.instance_count == 0 or mm.buffer.is_empty():
				counts["empty"] = int(counts["empty"]) + 1
			else:
				counts["instances"] = int(counts["instances"]) + mm.instance_count
				_note_skins(mm.mesh, skins))

	_check(int(counts["mesh"]) > 500, "only %d meshes in the city - did the bake run?" % counts["mesh"])
	_check(int(counts["empty"]) == 0, "%d of %d MultiMeshes have no transforms (bake was run headless)" % [
		counts["empty"], counts["multi"]])
	for named: String in ["LitGlass", "LampGlow", "LampPool"]:
		_check(skins.has(named), "no material named %s - the clock drives it by that name" % named)

	var anchors: Node = city.get_node_or_null("RiftAnchors")
	if _check(anchors != null, "no RiftAnchors in the baked city"):
		var data := StoryMapData.load_from()
		_check(anchors.get_child_count() == data.order.size(),
			"%d rift anchors for %d map nodes - re-bake" % [anchors.get_child_count(), data.order.size()])
	print("  %d meshes, %d multimeshes holding %d instances" % [
		counts["mesh"], counts["multi"], counts["instances"]])
	city.queue_free()


## Every scene the game can be sitting in, opened once. Catches what only shows
## up when a script really runs: a bad @onready path, a renamed autoload, a
## scene that lost its script.
func _verify_boots() -> void:
	print("scenes:")
	for path: String in ["res://scenes/Main.tscn", MAP_SCENE, RUNNER_SCENE]:
		if not _check(ResourceLoader.exists(path), "%s is missing" % path):
			continue
		if path == RUNNER_SCENE:
			_story_context()
		var node: Node = (load(path) as PackedScene).instantiate()
		add_child(node)
		if path == RUNNER_SCENE:
			# Let it finish building before taking it away. Freeing a level
			# halfway through its own loading screen tears the scene out from
			# under the coroutine that is still building it.
			await _until_level_ready(node)
		else:
			await _frames(30)
		_check(is_instance_valid(node) and node.is_inside_tree(), "%s did not stay up" % path)
		print("  %-46s ok" % path.get_file())
		_shut_down(node)
		await _frames(3)


## Gates build themselves as the track comes up rather than all at once (see
## Section_BeatRunner3d._build_gate_body). This walks a whole level past an
## imaginary player and checks that nothing is ever SHOWN with nothing in it —
## the one way that optimisation could go wrong where a player would see it.
func _verify_lazy_gates() -> void:
	print("gate geometry:")
	var dir := DirAccess.open(BEATMAP_DIR)
	if dir == null:
		return
	# Every chart, not just the first: a sparse opening proves nothing about a
	# dense one, and density is exactly what this optimisation is betting on.
	for file: String in dir.get_files():
		if file.ends_with(".json"):
			await _sweep_track(file.get_basename())


## Walks one chart's whole track past an imaginary player.
func _sweep_track(song_key: String) -> void:
	_story_context(song_key)
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var section: Node = _find_section(level)
	if not _check(section != null, "no section in the level scene"):
		return

	var gates: Array = section.get("gate_nodes")
	var zs: PackedFloat32Array = section.get("gate_world_zs")
	if not _check(gates.size() > 0, "level built no gates"):
		return

	# The countdown's shader warmup shows every gate for a few frames; let it
	# finish and put the track back to hidden, or this measures that instead.
	for i in 90:
		await get_tree().process_frame
		if bool(section.get("_warmup_done")):
			break
	for gate: Variant in gates:
		if gate != null:
			(gate as Node3D).visible = false

	var empty_shown: int = 0
	var at: float = 0.0
	var finish: float = zs[zs.size() - 1] + 80.0
	while at < finish:
		await get_tree().process_frame
		section.set("_player_path_dist", at)
		# Four passes: the per-frame build budget is small on purpose, and this
		# stands in for the frames a player would take to cover thirty metres.
		for pass_i in 4:
			section.call("_update_gate_visibility")
		for i in gates.size():
			var gate: Node3D = gates[i]
			if gate == null or not gate.visible:
				continue
			var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
			if vis == null or vis.get_child_count() == 0:
				empty_shown += 1
				if empty_shown < 4:
					print("    gate %d at %.0f m, player %.0f m, built=%s, action=%s, children=%d" % [
						i, zs[i], at, str((section.get("_gate_vis_built") as Array)[i]),
						String((section.get("gate_actions") as Array)[i]),
						0 if vis == null else vis.get_child_count()])
		at += 30.0

	var built: int = 0
	for flag: bool in (section.get("_gate_vis_built") as Array):
		if flag:
			built += 1
	_check(empty_shown == 0, "%d gates were shown with nothing in them" % empty_shown)
	_check(built == gates.size(), "%d of %d gates never built" % [gates.size() - built, gates.size()])
	var looks: Variant = section.get("_looks")
	var arcs: int = (looks.arc_lights as Array).size() if looks != null else 0
	print("  %-22s %d gates, all built by the end of the track (%d arc lights)" % [
		song_key, gates.size(), arcs])
	_shut_down(level)
	await _frames(3)


## The save: the real one is only looked at, never written. The round trip runs
## against a sandbox file, because a test that can eat somebody's progress is
## worse than no test.
func _verify_save() -> void:
	print("save:")
	var real := ConfigFile.new()
	if real.load(Save.PATH) == OK:
		_check(int(real.get_value("meta", "version", 0)) == Save.VERSION,
			"save.cfg is version %s, this build writes %d" % [
				str(real.get_value("meta", "version", 0)), Save.VERSION])
		print("  real save: version %d, %d cleared, %d shards, %d upgrades" % [
			int(real.get_value("meta", "version", 0)), Save.get_story_cleared().size(),
			Save.shards(), Save.owned_upgrades().size()])
	else:
		print("  no save yet (nothing to check)")

	var sandbox: String = "user://devsave_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sandbox))
	Save.dev_use_path(sandbox)
	_check(Save.get_story_cleared().is_empty(), "a fresh save should start with no progress")

	Save.mark_story_cleared("node_a")
	Save.set_story_position("node_a")
	Save.set_story_time(2.5)
	Save.save_high_score("song_x", 100, 10)
	Save.add_shards(50)
	Save.grant_upgrade(Save.UPGRADE_EXTRA_LIFE)
	_check(not Save.spend_shards(80), "spent shards that were not there")
	_check(Save.spend_shards(30) and Save.shards() == 20, "spending shards did not add up")
	_check(not Save.grant_upgrade(Save.UPGRADE_EXTRA_LIFE), "granted the same upgrade twice")

	# Re-open from disk: everything above has to still be there.
	Save.dev_use_path(sandbox)
	_check(Save.is_story_cleared("node_a"), "cleared node did not survive a reload")
	_check(Save.get_story_position() == "node_a", "map position did not survive a reload")
	_check(absf(float(Save.get_story_time()["time"]) - 2.5) < 0.001, "time of day did not survive")
	_check(int(Save.get_high_score("song_x")["score"]) == 100, "high score did not survive")
	_check(Save.has_upgrade(Save.UPGRADE_EXTRA_LIFE), "upgrade did not survive a reload")
	_check(Save.shards() == 20, "shards did not survive a reload")
	_check(not Save.save_high_score("song_x", 50, 5), "a worse run was called a record")
	_check(int(Save.get_high_score("song_x")["score"]) == 100, "a worse run overwrote the record")

	# A file that will not parse must be kept, not overwritten.
	var broken: String = "user://devsave_broken.cfg"
	var f := FileAccess.open(broken, FileAccess.WRITE)
	f.store_string("this is not a config file -- [[[ broken")
	f.close()
	Save.dev_use_path(broken)
	_check(Save.get_story_cleared().is_empty(), "a broken save should read as empty")
	var kept: int = 0
	for name: String in DirAccess.open("user://").get_files():
		if name.begins_with("save.corrupt-") or name.begins_with("devsave_broken"):
			kept += 1
	_check(kept > 0, "a broken save was not kept aside")

	Save.dev_use_path(RUN_SAVE)   # back to the run's copy, never the real file
	for name: String in DirAccess.open("user://").get_files():
		if name.begins_with("devsave_") or name.begins_with("save.corrupt-"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + name))


## The rules of the game, asserted against a real level rather than read off
## the source. Everything else here checks that the game BUILDS; this checks
## that it SCORES — the half that a refactor can quietly break while every
## structural check still passes.
func _verify_rules() -> void:
	print("rules:")
	_story_context()
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var s: Node = _find_section(level)

	# ── The multiplier ladder: +1 every 10 combo, capped at x20 ──────────────
	for pair: Array in [[0, 1], [9, 1], [10, 2], [19, 2], [20, 3], [189, 19], [190, 20], [500, 20]]:
		s.set("_combo", int(pair[0]))
		_check(int(s.call("_score_multiplier")) == int(pair[1]),
			"combo %d should multiply x%d, got x%d" % [
				pair[0], pair[1], int(s.call("_score_multiplier"))])

	# A wall-jump climb doubles whatever the ladder says.
	s.set("_combo", 10)
	s.set("_wj_mult_active", true)
	_check(int(s.call("_score_multiplier")) == 4, "wall-jump bonus should double the multiplier")
	s.set("_wj_mult_active", false)

	# OVERDRIVE overrides the ladder outright.
	s.set("_charge_mult_timer", 1.0)
	_check(int(s.call("_score_multiplier")) == 100, "overdrive should lock the multiplier to x100")

	# ...and inside it a miss costs nothing but the points: combo and health hold.
	s.set("_combo", 7)
	s.set("_health_pct", 0.5)
	s.call("_on_gate_scored", false)
	_check(int(s.get("_combo")) == 7, "a miss inside overdrive must not break the combo")
	_check(absf(float(s.get("_health_pct")) - 0.5) < 0.001,
		"a miss inside overdrive must not cost health")
	s.set("_charge_mult_timer", 0.0)

	# ── A hit: 500 points x the multiplier, +1 combo, +5% health ────────────
	s.set("_combo", 0)
	s.set("_score", 0)
	s.set("_gates_hit", 0)
	s.set("_health_pct", 0.5)
	s.call("_on_gate_scored", true)
	_check(int(s.get("_score")) == 500, "first hit should score 500, got %d" % int(s.get("_score")))
	_check(int(s.get("_combo")) == 1, "a hit should raise the combo")
	_check(int(s.get("_gates_hit")) == 1, "a hit should count as a hit")
	_check(absf(float(s.get("_health_pct")) - 0.55) < 0.001, "a hit should heal 5%")

	# At combo 10 the same hit is worth double, because the 11th hit multiplies x2.
	s.set("_combo", 9)
	s.set("_score", 0)
	s.call("_on_gate_scored", true)
	_check(int(s.get("_score")) == 1000, "a hit at combo 10 should score 1000, got %d" % int(s.get("_score")))

	# ── A miss: combo gone, 10% health gone ─────────────────────────────────
	s.set("_combo", 25)
	s.set("_health_pct", 0.5)
	s.set("_gates_missed", 0)
	s.call("_on_gate_scored", false)
	_check(int(s.get("_combo")) == 0, "a miss should reset the combo")
	_check(int(s.get("_gates_missed")) == 1, "a miss should count as a miss")
	_check(absf(float(s.get("_health_pct")) - 0.4) < 0.001, "a miss should cost 10%")

	# Health hitting zero ends the run.
	s.set("_health_pct", 0.05)
	s.call("_on_gate_scored", false)
	_check(bool(s.get("_song_finish_pending")), "a miss at 5% health should end the run")

	# ── The grade ───────────────────────────────────────────────────────────
	for case: Array in [[100, 0, "S"], [95, 5, "A"], [80, 20, "B"], [65, 35, "C"],
			[45, 55, "D"], [20, 80, "F"]]:
		s.set("_score_final", {})
		s.set("_gates_hit", int(case[0]))
		s.set("_gates_missed", int(case[1]))
		s.set("_score", 1000)
		var got: String = String((s.call("_finalise_score") as Dictionary).get("grade", "?"))
		_check(got == String(case[2]), "%d hit / %d missed should grade %s, got %s" % [
			case[0], case[1], case[2], got])

	# A clean run is worth half again as much.
	s.set("_score_final", {})
	s.set("_gates_hit", 10)
	s.set("_gates_missed", 0)
	s.set("_score", 1000)
	_check(int((s.call("_finalise_score") as Dictionary).get("score", 0)) == 1500,
		"a perfect run should pay x1.5")

	# ── Reduced flashing ────────────────────────────────────────────────────
	var was: bool = GameConfig.reduced_flashing
	GameConfig.reduced_flashing = false
	_check(absf(GameConfig.flash_scale() - 1.0) < 0.001, "flash scale should be 1.0 when off")
	GameConfig.reduced_flashing = true
	_check(GameConfig.flash_scale() < 0.5, "reduced flashing should actually reduce the flash")
	GameConfig.reduced_flashing = was

	# ── The FPS readout, end to end rather than by inspection ───────────────
	var hud: Node = s.get("_hud")
	var was_fps: bool = GameConfig.show_fps
	GameConfig.show_fps = true
	await _frames(60)   # it averages over half a second before it says anything
	var label: Label = hud.get("_fps_label") as Label if hud != null else null
	_check(label != null, "the HUD built no FPS label")
	if label != null:
		_check(label.visible, "the FPS readout stayed hidden with the setting on")
		_check(label.text.contains("FPS"), "the FPS readout said '%s'" % label.text)
	GameConfig.show_fps = false
	await _frames(5)
	if label != null:
		_check(not label.visible, "the FPS readout stayed up with the setting off")
	GameConfig.show_fps = was_fps

	_shut_down(level)
	await _frames(5)


## The three overlays a level puts up. Each one is opened for real, navigated,
## and photographed — none of them is confirmed, because every entry on them
## changes scene. Both the death and the results panel write as they open, which
## is why the whole run is on a copy of the save (see _sandbox_save).
func _verify_menus() -> void:
	print("menus:")
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_story_context()
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var section: Node = _find_section(level)
	var menus: Node = section.get("_menus")
	if not _check(menus != null, "the level built no LevelMenus"):
		return

	# Pause: opens, the stick and the keys move the lit entry, and it closes.
	section.call("_pause_game")
	await _frames(20)
	_check(bool(menus.call("is_pause_open")), "pause menu did not open")
	_check(get_tree().paused, "pausing did not freeze the tree")
	var before: int = int(menus.get("_pause_option"))
	menus.call("handle_pause_key", _key(KEY_DOWN))
	_check(int(menus.get("_pause_option")) != before, "pause selection did not move")
	await _shoot("menu_pause")
	section.call("_resume_game")
	await _frames(20)
	_check(not bool(menus.call("is_pause_open")), "pause menu did not close")
	_check(not get_tree().paused, "resuming did not unfreeze the tree")

	# Death: the card arrives behind a fade, so give it time to land.
	section.call("_trigger_death")
	# Time, not frames: the card arrives behind a 0.87 s tween, and ninety
	# frames stopped being a second and a half the moment the harness started
	# running with V-Sync off.
	await _until(func() -> bool: return bool(menus.call("is_death_open")), 4.0)
	_check(bool(menus.call("is_death_open")), "death card did not open")
	var death_before: int = int(menus.get("_death_sel"))
	menus.call("handle_death_key", _key(KEY_DOWN))
	_check(int(menus.get("_death_sel")) != death_before, "death selection did not move")
	await _shoot("menu_death")

	# Results, on a second level — the first one has just died.
	_shut_down(level)
	await _frames(5)
	level = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	section = _find_section(level)
	menus = section.get("_menus")
	section.call("_spawn_results_panel")
	await _until(func() -> bool: return bool(menus.call("is_results_open")), 4.0)
	_check(bool(menus.call("is_results_open")), "results panel did not open")
	var results_before: int = int(menus.get("_results_sel"))
	menus.call("handle_results_key", _key(KEY_RIGHT))
	_check(int(menus.get("_results_sel")) != results_before, "results selection did not move")
	await _shoot("menu_results")

	_shut_down(level)
	await _frames(5)


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


func _shoot(shot_name: String) -> void:
	await _frames(2)
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("  %s" % shot_name)


# ── Measuring ────────────────────────────────────────────────────────────────

## Draw calls and frame time on the map, by day and by night. Night is the
## expensive one: every window lit, and a pool of light under every lamp.
func _perf() -> void:
	Engine.max_fps = 0
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	add_child(map)
	await _frames(60)
	for hour: Array in [[1.0, "DAY"], [3.0, "NIGHT"]]:
		_set_hour(map, float(hour[0]))
		await _frames(90)
		var calls: int = 0
		var t0 := Time.get_ticks_usec()
		for i in 240:
			await get_tree().process_frame
			calls += RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		print("  %-6s %4d draw calls   %.2f ms/frame" % [String(hour[1]), calls / 240,
			float(Time.get_ticks_usec() - t0) / 1000.0 / 240.0])


## Why one quality tier stutters when the one below it runs clean. Plays the
## same chart on each tier named (default: the top two) and reports what a frame
## actually costs — plus the video memory it took to get there, because a
## stutter is usually memory being evicted rather than maths being slow.
func _tiers(arg: String) -> void:
	Engine.max_fps = 0   # the project caps at 120, which hides the whole story
	var want: PackedStringArray = (arg if arg != "" else "low,medium,high,ultra,max").split(",")
	for t: String in want:
		if not GraphicsQuality.PRESETS.has(t):
			print("  no such tier: %s" % t)
			continue
		# Every key of the tier, through the dev seam rather than set_tier():
		# set_tier() writes the player's own quality setting to disk, and a run
		# that dies halfway then leaves them on whatever it was measuring.
		GraphicsQuality.dev_clear_overrides()
		for key: String in (GraphicsQuality.PRESETS[t] as Dictionary):
			GraphicsQuality.dev_override(key, GraphicsQuality.PRESETS[t][key])
		await _frames(10)
		_story_context()
		var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
		add_child(level)
		await _until_level_ready(level)
		var env: Environment = null
		for node: Node in _find_section(level).get_children():
			if node is WorldEnvironment:
				env = (node as WorldEnvironment).environment
		var preset: Dictionary = GraphicsQuality.PRESETS[t]
		var vpt: Viewport = get_viewport()
		vpt.scaling_3d_scale = float(preset.scaling_3d_scale)
		vpt.msaa_3d = int(preset.msaa_3d)
		vpt.screen_space_aa = int(preset.screen_space_aa)
		vpt.mesh_lod_threshold = float(preset.mesh_lod_threshold)
		vpt.positional_shadow_atlas_size = int(preset.positional_shadow_atlas_size)
		RenderingServer.directional_shadow_atlas_set_size(
			int(preset.directional_shadow_size), true)
		RenderingServer.directional_soft_shadow_filter_set_quality(preset.shadow_soft_quality)
		RenderingServer.positional_soft_shadow_filter_set_quality(preset.shadow_soft_quality)
		if env != null:
			env.ssr_enabled = bool(preset.ssr)
			if bool(preset.ssr):
				env.ssr_max_steps = int(preset.ssr_steps)
			env.ssao_enabled = bool(preset.ssao)
			env.ssil_enabled = bool(preset.ssil)
			env.sdfgi_enabled = bool(preset.sdfgi)
			if bool(preset.sdfgi):
				env.sdfgi_bounce_feedback = float(preset.sdfgi_bounce)
			env.volumetric_fog_enabled = bool(preset.volumetric_fog)
			env.volumetric_fog_gi_inject = float(preset.get("fog_gi_inject", 0.0))
			env.volumetric_fog_anisotropy = float(preset.get("fog_anisotropy", 0.2))
		# Let SDFGI converge and the shaders finish compiling before counting.
		await _frames(240)

		var times: PackedFloat32Array = PackedFloat32Array()
		var calls: int = 0
		var prims: int = 0
		for i in 600:
			await get_tree().process_frame
			times.append(get_process_delta_time() * 1000.0)
			calls += RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			prims += RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var sorted: Array = Array(times)
		sorted.sort()
		var mean: float = 0.0
		for ms: float in times:
			mean += ms
		mean /= float(times.size())
		var spikes: int = 0
		for ms: float in times:
			if ms > mean * 2.0:
				spikes += 1

		var vp: Viewport = get_viewport()
		var canvas: Vector2 = vp.get_visible_rect().size
		var scale: float = float(GraphicsQuality.PRESETS[t]["scaling_3d_scale"])
		var samples: int = 4 if int(GraphicsQuality.PRESETS[t]["msaa_3d"]) == Viewport.MSAA_4X else 1
		print("  %-6s %6.2f ms mean  %6.2f p99  %7.2f worst  %3d spikes>2x" % [
			t, mean, sorted[int(sorted.size() * 0.99)], sorted[-1], spikes])
		print("         %5.1f fps   %5d draw calls   %7d primitives" % [
			1000.0 / mean, calls / 600, prims / 600])
		print("         3D buffer %.0fx%.0f = %.1f MP x%d samples = %.1f MSamples" % [
			canvas.x * scale, canvas.y * scale,
			canvas.x * scale * canvas.y * scale / 1e6, samples,
			canvas.x * scale * canvas.y * scale * samples / 1e6])
		print("         video memory %.0f MB (textures %.0f MB)" % [
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0])
		_shut_down(level)
		await _frames(30)
	GraphicsQuality.dev_clear_overrides()


## Which knob in a tier is actually paying for the frame. Boots a level on
## "max", then puts ONE setting back to what "ultra" uses and measures again —
## the difference is what that setting costs, which a table of preset values
## cannot tell you.
func _ablate() -> void:
	Engine.max_fps = 0
	# Through the dev seam, never set_tier(): that writes the player's own
	# quality setting to disk, and a run that dies halfway leaves it wrong.
	GraphicsQuality.dev_clear_overrides()
	for key: String in (GraphicsQuality.PRESETS["max"] as Dictionary):
		GraphicsQuality.dev_override(key, GraphicsQuality.PRESETS["max"][key])
	await _frames(10)
	_story_context()
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	await _frames(240)

	var vp: Viewport = get_viewport()
	var env: Environment = null
	for node: Node in _find_section(level).get_children():
		if node is WorldEnvironment:
			env = (node as WorldEnvironment).environment
	if env == null:
		print("  no environment found")
		return

	var base: float = await _measure()
	print("  max as it ships           %6.2f ms  (%5.1f fps)" % [base, 1000.0 / base])
	print("  ── one setting back to what ultra uses ──")
	for step: Array in [
		["3D scale 1.75 -> 1.20", func() -> void: vp.scaling_3d_scale = 1.2,
			func() -> void: vp.scaling_3d_scale = 1.75],
		["mesh LOD 1.0 -> 4.0", func() -> void: vp.mesh_lod_threshold = 4.0,
			func() -> void: vp.mesh_lod_threshold = 1.0],
		["SSR steps 256 -> 64", func() -> void: env.ssr_max_steps = 64,
			func() -> void: env.ssr_max_steps = 256],
		["volumetric fog off", func() -> void: env.volumetric_fog_enabled = false,
			func() -> void: env.volumetric_fog_enabled = true],
		["SDFGI bounce 1.5 -> 0.6", func() -> void: env.sdfgi_bounce_feedback = 0.6,
			func() -> void: env.sdfgi_bounce_feedback = 1.5],
		["SDFGI off entirely", func() -> void: env.sdfgi_enabled = false,
			func() -> void: env.sdfgi_enabled = true],
		["SSIL off", func() -> void: env.ssil_enabled = false,
			func() -> void: env.ssil_enabled = true],
		["shadow atlas 8192 -> 4096", func() -> void:
			RenderingServer.directional_shadow_atlas_set_size(4096, true)
			vp.positional_shadow_atlas_size = 2048,
			func() -> void:
				RenderingServer.directional_shadow_atlas_set_size(8192, true)
				vp.positional_shadow_atlas_size = 4096],
		["soft shadows ULTRA -> HIGH", func() -> void:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
			RenderingServer.positional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_HIGH),
			func() -> void:
				RenderingServer.directional_soft_shadow_filter_set_quality(
					RenderingServer.SHADOW_QUALITY_SOFT_ULTRA)
				RenderingServer.positional_soft_shadow_filter_set_quality(
					RenderingServer.SHADOW_QUALITY_SOFT_ULTRA)],
		["MSAA 4x -> off", func() -> void: vp.msaa_3d = Viewport.MSAA_DISABLED,
			func() -> void: vp.msaa_3d = Viewport.MSAA_4X],
	]:
		(step[1] as Callable).call()
		await _frames(150)
		var ms: float = await _measure()
		print("  %-26s %6.2f ms  (%5.1f fps)   %+6.2f ms saved" % [
			step[0], ms, 1000.0 / ms, base - ms])
		(step[2] as Callable).call()
		await _frames(90)

	_shut_down(level)
	await _frames(10)
	GraphicsQuality.dev_clear_overrides()


## Candidate settings for a cheaper "max" that still looks like max. Each one
## plays the SAME seed to the same point in the song, is photographed there, and
## is then measured — so the look and the cost can be judged against each other
## instead of one being argued from the other.
##
## It applies the settings straight to the viewport and the environment and
## never calls GraphicsQuality.set_tier(), which would write the player's own
## quality setting to disk.
const ABLATE_SEED: int = 20251005


## Every candidate states ALL of its extra settings, defaults included: these
## are global RenderingServer state, so a value left unset would simply be
## whatever the candidate before it happened to leave behind.
func _gfx_extras(env: Environment, gi: float, aniso: float, fog_vol: int,
		rays: int, light_frames: int, ss_quality: int, ssr_rough: int) -> void:
	env.volumetric_fog_gi_inject = gi
	env.volumetric_fog_anisotropy = aniso
	RenderingServer.environment_set_volumetric_fog_volume_size(fog_vol, fog_vol)
	RenderingServer.environment_set_sdfgi_ray_count(rays)
	RenderingServer.environment_set_sdfgi_frames_to_update_light(light_frames)
	# half_size off once the quality is raised: that is most of what "high" buys.
	var half: bool = ss_quality <= RenderingServer.ENV_SSAO_QUALITY_MEDIUM
	RenderingServer.environment_set_ssao_quality(ss_quality, half, 0.5, 2, 50.0, 300.0)
	RenderingServer.environment_set_ssil_quality(ss_quality, half, 0.5, 4, 50.0, 300.0)
	RenderingServer.environment_set_ssr_roughness_quality(ssr_rough)


## The shipped values, read from the project rather than remembered. These are
## global RenderingServer state: a candidate that applies nothing does not run
## "as shipped", it runs on whatever the candidate before it left behind, which
## is how a baseline silently becomes a copy of the thing it is measuring.
func _gfx_defaults(env: Environment) -> void:
	var ssao_q: int = int(ProjectSettings.get_setting(
		"rendering/environment/ssao/quality", RenderingServer.ENV_SSAO_QUALITY_MEDIUM))
	var ssil_q: int = int(ProjectSettings.get_setting(
		"rendering/environment/ssil/quality", RenderingServer.ENV_SSIL_QUALITY_MEDIUM))
	env.volumetric_fog_gi_inject = 0.0      # what GraphicsQuality sets up
	env.volumetric_fog_anisotropy = 0.2     # Godot's own default
	RenderingServer.environment_set_volumetric_fog_volume_size(
		int(ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_size", 64)),
		int(ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_depth", 64)))
	RenderingServer.environment_set_sdfgi_ray_count(int(ProjectSettings.get_setting(
		"rendering/global_illumination/sdfgi/probe_ray_count",
		RenderingServer.ENV_SDFGI_RAY_COUNT_32)))
	RenderingServer.environment_set_sdfgi_frames_to_update_light(
		int(ProjectSettings.get_setting(
			"rendering/global_illumination/sdfgi/frames_to_update_lights",
			RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_4_FRAMES)))
	RenderingServer.environment_set_ssao_quality(ssao_q, bool(ProjectSettings.get_setting(
		"rendering/environment/ssao/half_size", true)), 0.5, 2, 50.0, 300.0)
	RenderingServer.environment_set_ssil_quality(ssil_q, bool(ProjectSettings.get_setting(
		"rendering/environment/ssil/half_size", true)), 0.5, 4, 50.0, 300.0)
	RenderingServer.environment_set_ssr_roughness_quality(int(ProjectSettings.get_setting(
		"rendering/environment/screen_space_reflection/roughness_quality",
		RenderingServer.ENV_SSR_ROUGHNESS_QUALITY_MEDIUM)))


## name, preset overrides, extras
func _gfx_candidates() -> Array:
	return [
		["max_now", {}, _gfx_defaults],
		["fog_gi", {}, func(env: Environment) -> void:
			_gfx_defaults(env)
			env.volumetric_fog_gi_inject = 0.4],
		["fog_gi_aniso", {}, func(env: Environment) -> void:
			_gfx_defaults(env)
			env.volumetric_fog_gi_inject = 0.4
			env.volumetric_fog_anisotropy = 0.7],
		["fog_all", {}, func(env: Environment) -> void:
			_gfx_defaults(env)
			env.volumetric_fog_gi_inject = 0.4
			env.volumetric_fog_anisotropy = 0.7
			RenderingServer.environment_set_volumetric_fog_volume_size(128, 128)
			RenderingServer.environment_set_sdfgi_ray_count(
				RenderingServer.ENV_SDFGI_RAY_COUNT_96)
			RenderingServer.environment_set_sdfgi_frames_to_update_light(
				RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_1_FRAME)],
		# The same thing twice, last: anything this differs from the first run
		# by is drift — thermal, background load, the track itself — and no
		# delta smaller than that gap means anything.
		["max_now_again", {}, _gfx_defaults],
	]


func _candidates() -> void:
	Engine.max_fps = 0
	var maxp: Dictionary = GraphicsQuality.PRESETS["max"]
	print("  level built under tier '%s' (fur and CPU knobs come from there)" % GraphicsQuality.tier)
	for cand: Array in _gfx_candidates():
		var over: Dictionary = cand[1]
		_story_context()
		Run.run_seed = ABLATE_SEED   # same track every candidate, and never recorded
		var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
		add_child(level)
		await _until_level_ready(level)

		var vp: Viewport = get_viewport()
		var env: Environment = null
		for node: Node in _find_section(level).get_children():
			if node is WorldEnvironment:
				env = (node as WorldEnvironment).environment
		if env == null:
			print("  no environment found")
			return

		# Max in full, then whatever this candidate changes about it.
		var g := func(key: String) -> Variant: return over.get(key, maxp[key])
		vp.scaling_3d_scale = float(g.call("scaling_3d_scale"))
		vp.msaa_3d = int(g.call("msaa_3d"))
		vp.screen_space_aa = int(g.call("screen_space_aa"))
		vp.mesh_lod_threshold = float(g.call("mesh_lod_threshold"))
		vp.positional_shadow_atlas_size = int(g.call("positional_shadow_atlas_size"))
		RenderingServer.directional_shadow_atlas_set_size(
			int(g.call("directional_shadow_size")), true)
		RenderingServer.directional_soft_shadow_filter_set_quality(
			g.call("shadow_soft_quality"))
		RenderingServer.positional_soft_shadow_filter_set_quality(
			g.call("shadow_soft_quality"))
		env.ssr_enabled = bool(g.call("ssr"))
		env.ssr_max_steps = int(g.call("ssr_steps"))
		env.ssao_enabled = bool(g.call("ssao"))
		env.ssil_enabled = bool(g.call("ssil"))
		env.sdfgi_enabled = bool(g.call("sdfgi"))
		env.sdfgi_bounce_feedback = float(g.call("sdfgi_bounce"))
		env.volumetric_fog_enabled = bool(g.call("volumetric_fog"))
		(cand[2] as Callable).call(env)

		# Same point in the same song for every candidate, so the shots line up.
		var elapsed: float = 0.0
		while elapsed < 9.0:
			await get_tree().process_frame
			elapsed += get_process_delta_time()
		get_viewport().get_texture().get_image().save_png(
			"%s/tier_%s.png" % [SHOT_DIR, cand[0]])

		var ms: float = await _measure()
		var canvas: Vector2 = vp.get_visible_rect().size
		var sc: float = vp.scaling_3d_scale
		print("  %-15s %6.2f ms (%5.1f fps)   3D %.0fx%.0f = %4.1f MP   vram %.0f MB" % [
			cand[0], ms, 1000.0 / ms, canvas.x * sc, canvas.y * sc,
			canvas.x * sc * canvas.y * sc / 1e6,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
		_shut_down(level)
		await _frames(30)
	print("  written to %s" % ProjectSettings.globalize_path(SHOT_DIR))


## The same frozen frame under each candidate. _candidates() measures what they
## COST, but its shots drift apart — a slower candidate reaches the nine-second
## mark further down the track. Here the scene is stopped first and the settings
## are changed underneath it, so the only difference left between the images is
## the settings themselves.
func _compare_looks() -> void:
	Engine.max_fps = 0
	var maxp: Dictionary = GraphicsQuality.PRESETS["max"]
	_story_context()
	Run.run_seed = ABLATE_SEED
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)

	var elapsed: float = 0.0
	while elapsed < 9.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	get_tree().paused = true   # one viewpoint for every shot

	var vp: Viewport = get_viewport()
	var env: Environment = null
	for node: Node in _find_section(level).get_children():
		if node is WorldEnvironment:
			env = (node as WorldEnvironment).environment
	for cand: Array in _gfx_candidates():
		var over: Dictionary = cand[1]
		var g := func(key: String) -> Variant: return over.get(key, maxp[key])
		vp.scaling_3d_scale = float(g.call("scaling_3d_scale"))
		vp.msaa_3d = int(g.call("msaa_3d"))
		vp.screen_space_aa = int(g.call("screen_space_aa"))
		vp.mesh_lod_threshold = float(g.call("mesh_lod_threshold"))
		vp.positional_shadow_atlas_size = int(g.call("positional_shadow_atlas_size"))
		RenderingServer.directional_shadow_atlas_set_size(
			int(g.call("directional_shadow_size")), true)
		RenderingServer.directional_soft_shadow_filter_set_quality(g.call("shadow_soft_quality"))
		RenderingServer.positional_soft_shadow_filter_set_quality(g.call("shadow_soft_quality"))
		env.ssr_enabled = bool(g.call("ssr"))
		env.ssr_max_steps = int(g.call("ssr_steps"))
		env.ssao_enabled = bool(g.call("ssao"))
		env.ssil_enabled = bool(g.call("ssil"))
		env.sdfgi_enabled = bool(g.call("sdfgi"))
		env.sdfgi_bounce_feedback = float(g.call("sdfgi_bounce"))
		env.volumetric_fog_enabled = bool(g.call("volumetric_fog"))
		(cand[2] as Callable).call(env)
		# GI and fog need frames to re-converge after a settings change.
		await _frames(240)
		get_viewport().get_texture().get_image().save_png(
			"%s/look_%s.png" % [SHOT_DIR, cand[0]])
		print("  look_%s" % cand[0])
	get_tree().paused = false
	get_tree().paused = false
	_shut_down(level)
	await _frames(10)


## What an improvement to max would COST. The inverse of _ablate(): start from
## max as it ships and turn ONE thing up, on a frozen scene so the track cannot
## drift between readings. The numbers are GPU-side only — nothing here changes
## what the CPU does per frame — and a stopped scene is cheaper in absolute
## terms than a moving one, so read the deltas, not the totals.
func _upgrades() -> void:
	Engine.max_fps = 0
	_story_context()
	Run.run_seed = ABLATE_SEED
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var elapsed: float = 0.0
	while elapsed < 9.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	get_tree().paused = true

	var env: Environment = null
	for node: Node in _find_section(level).get_children():
		if node is WorldEnvironment:
			env = (node as WorldEnvironment).environment
	await _frames(120)
	var base: float = await _measure()
	print("  max as it ships now      %6.2f ms  (frozen scene)" % base)
	print("  -- turning one thing up --")
	for step: Array in [
		["fog takes GI colour", func() -> void: env.volumetric_fog_gi_inject = 0.4,
			func() -> void: env.volumetric_fog_gi_inject = 0.0],
		["fog anisotropy .2 -> .7", func() -> void: env.volumetric_fog_anisotropy = 0.7,
			func() -> void: env.volumetric_fog_anisotropy = 0.2],
		["fog volume 64 -> 128", func() -> void:
			RenderingServer.environment_set_volumetric_fog_volume_size(128, 128),
			func() -> void:
				RenderingServer.environment_set_volumetric_fog_volume_size(64, 64)],
		["SDFGI rays 16 -> 96", func() -> void:
			RenderingServer.environment_set_sdfgi_ray_count(
				RenderingServer.ENV_SDFGI_RAY_COUNT_96),
			func() -> void:
				RenderingServer.environment_set_sdfgi_ray_count(
					RenderingServer.ENV_SDFGI_RAY_COUNT_16)],
		["SDFGI light update 2 -> 1", func() -> void:
			RenderingServer.environment_set_sdfgi_frames_to_update_light(
				RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_1_FRAME),
			func() -> void:
				RenderingServer.environment_set_sdfgi_frames_to_update_light(
					RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_2_FRAMES)],
		["SSAO quality -> ultra", func() -> void:
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_ULTRA, false, 0.5, 2, 50.0, 300.0),
			func() -> void:
				RenderingServer.environment_set_ssao_quality(
					RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, 50.0, 300.0)],
		["SSIL quality -> ultra", func() -> void:
			RenderingServer.environment_set_ssil_quality(
				RenderingServer.ENV_SSIL_QUALITY_ULTRA, false, 0.5, 4, 50.0, 300.0),
			func() -> void:
				RenderingServer.environment_set_ssil_quality(
					RenderingServer.ENV_SSIL_QUALITY_MEDIUM, true, 0.5, 4, 50.0, 300.0)],
		["SSR roughness -> high", func() -> void:
			RenderingServer.environment_set_ssr_roughness_quality(
				RenderingServer.ENV_SSR_ROUGHNESS_QUALITY_HIGH),
			func() -> void:
				RenderingServer.environment_set_ssr_roughness_quality(
					RenderingServer.ENV_SSR_ROUGHNESS_QUALITY_MEDIUM)],
		["SSR steps 128 -> 256", func() -> void: env.ssr_max_steps = 256,
			func() -> void: env.ssr_max_steps = 128],
		["3D scale 1.0 -> 1.25", func() -> void: get_viewport().scaling_3d_scale = 1.25,
			func() -> void: get_viewport().scaling_3d_scale = 1.0],
		["mesh LOD 4.0 -> 2.0", func() -> void: get_viewport().mesh_lod_threshold = 2.0,
			func() -> void: get_viewport().mesh_lod_threshold = 4.0],
	]:
		(step[1] as Callable).call()
		await _frames(150)
		var ms: float = await _measure()
		print("  %-26s %6.2f ms   %+6.2f ms" % [step[0], ms, ms - base])
		(step[2] as Callable).call()
		await _frames(90)
	get_tree().paused = false
	_shut_down(level)
	await _frames(10)


## How much more neon the frame can carry. These knobs are read once while the
## level builds itself, so each candidate needs its own boot — and each boot is
## driven to the same PATH DISTANCE before the shot, not the same elapsed time,
## because a slower candidate covers less ground per second and would otherwise
## be photographed somewhere else entirely.
## The electric blackout, photographed either side of a zone edge. There is no
## way to fake this: the gates only grow their arcs if the chart says that part
## of the song is electric, so the only honest test is to play up to a real one.
func _electric_zones(song: String) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_story_context(song)
	Run.run_seed = ABLATE_SEED
	# Four times the default preview. "No matter how much preview someone has"
	# is the requirement, so the test has to actually ask for a lot of it.
	var was_preview: float = GameConfig.gate_preview_beats
	GameConfig.gate_preview_beats = 10.0
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var s: Node = _find_section(level)
	var zones: Array = s.get("_electric_zones") as Array
	print("  %s: %d electric zones" % [Run.current_song_key, zones.size()])
	if zones.is_empty():
		print("  nothing electric in this chart — try another song key")
		_shut_down(level)
		return
	for z: Dictionary in zones:
		print("     %.1fs .. %.1fs" % [float(z.get("start_t", 0.0)), float(z.get("end_t", 0.0))])

	var first: float = float((zones[0] as Dictionary).get("start_t", 0.0))
	var shot_before: bool = false
	var probed_after: bool = false
	var checked_start: bool = false
	var shot_marks: Dictionary = {}
	var shot_inside: bool = false
	for i in 60000:
		await get_tree().process_frame
		var t: float = float(s.call("_song_time"))
		if not shot_before and t >= first - 2.6 and t < first - 1.8:
			shot_before = true
			await _shoot("elec_before")
			_cue_probe_before = _probe_cues(s)
			_check(float(s.get("_elec_dark")) < 0.05,
				"the blackout had already started more than a preroll before the zone")
		# Close to the edge, where the same gates are still in front of the
		# player: "it breaks right when it dims" is a two-second window, and
		# ten seconds later every gate from the first sample is long gone.
		# The point of the preroll: by the zone's own start time the blackout is
		# finished, not starting. The first electric gate arrives into a room
		# that is already dark.
		if shot_before and not checked_start and t >= first and t < first + 0.35:
			checked_start = true
			_check(float(s.get("_elec_dark")) > 0.9,
				"at the zone's first gate the dark had only reached %.2f" % float(s.get("_elec_dark")))
		if shot_before and not probed_after and t >= first + 1.5:
			probed_after = true
			_report_cue_changes(s)
		for mark: float in [-0.3, 0.4, 1.2, 3.0, 6.5, 10.0]:
			if not shot_marks.has(mark) and t >= first + mark:
				shot_marks[mark] = true
				await _shoot("elec_edge_%+.1f" % mark)
		if not shot_inside and t >= first + 10.0:
			shot_inside = true
			await _check_electric_detail(s)
			await _check_preview_budget(s)
			_gate_cue_census(s, "inside the zone")
			_check(float(s.get("_elec_dark")) > 0.8,
				"inside the zone the dark only reached %.2f" % float(s.get("_elec_dark")))
			break
		if t > first + 24.0:
			break
	_check(shot_before and shot_inside, "never reached the first electric zone")
	GameConfig.gate_preview_beats = was_preview
	_shut_down(level)
	await _frames(10)


## Snapshot of every floor cue on the gates in view, by gate index, so the same
## gates can be looked at again after the lights go down. "It breaks right when
## it dims" is a claim about a transition, and a transition needs two samples.
var _cue_probe_before: Dictionary = {}


func _probe_cues(s: Node) -> Dictionary:
	var out: Dictionary = {}
	var gates: Array = s.get("gate_nodes") as Array
	var zs: PackedFloat32Array = s.get("gate_world_zs")
	var pd: float = float(s.get("_player_path_dist"))
	for gi in gates.size():
		var g: Node3D = gates[gi]
		if g == null or not is_instance_valid(g):
			continue
		if gi >= zs.size() or zs[gi] < pd - 20.0 or zs[gi] > pd + 200.0:
			continue
		var v: Node3D = g.get_node_or_null("VisRoot") as Node3D
		if v == null:
			continue
		var cues: Array = []
		for c: Node in v.get_children():
			var ci := c as GeometryInstance3D
			if ci == null:
				continue
			if not (c is MultiMeshInstance3D or (c is MeshInstance3D
					and (c as Node3D).position.y < 0.25)):
				continue
			var e: float = -1.0
			var sm := ci.material_override as ShaderMaterial
			if sm != null:
				var ev: Variant = sm.get_shader_parameter("energy")
				if ev != null:
					e = float(ev)
			cues.append({"name": c.name, "vis": ci.visible, "energy": e,
				"layers": ci.layers, "cast": ci.cast_shadow})
		if cues.is_empty():
			continue
		out[gi] = {"gate_vis": g.visible, "pos": v.position, "cues": cues,
			"electric": bool((s.get("gate_is_electric") as Array)[gi])}
	return out


## What actually changed on those same gates once the lights went down.
func _report_cue_changes(s: Node) -> void:
	var after: Dictionary = _probe_cues(s)
	var same: int = 0
	var gone: int = 0
	var dimmed: int = 0
	var lines: Array = []
	for gi: int in _cue_probe_before:
		if not after.has(gi):
			continue
		var b: Dictionary = _cue_probe_before[gi]
		var a: Dictionary = after[gi]
		var bc: Array = b["cues"]
		var ac: Array = a["cues"]
		if bc.size() != ac.size():
			gone += 1
			lines.append("    gate %d: %d cues -> %d" % [gi, bc.size(), ac.size()])
			continue
		var changed: bool = false
		for ci in bc.size():
			var bb: Dictionary = bc[ci]
			var aa: Dictionary = ac[ci]
			if bool(bb["vis"]) != bool(aa["vis"]):
				changed = true
				lines.append("    gate %d cue '%s': visible %s -> %s (electric=%s)" % [
					gi, bb["name"], str(bb["vis"]), str(aa["vis"]), str(a["electric"])])
			elif absf(float(bb["energy"]) - float(aa["energy"])) > 0.01:
				dimmed += 1
				lines.append("    gate %d cue '%s': energy %.2f -> %.2f" % [
					gi, bb["name"], float(bb["energy"]), float(aa["energy"])])
				changed = true
		if not changed:
			same += 1
	print("  cues across the dim: %d unchanged, %d lost a cue node, %d changed energy" % [
		same, gone, dimmed])
	for l: String in lines:
		print(l)


## Where each settled gate's visual actually sits, and how many of them still
## carry their floor cues — the three approach marks and the safe-lane strip.
## Run either side of a zone edge, because "it broke in electric zones" is only
## meaningful against what the same count does outside one.
func _gate_cue_census(s: Node, where: String) -> void:
	var gates2: Array = s.get("gate_nodes") as Array
	var zs2: PackedFloat32Array = s.get("gate_world_zs")
	var done: Array = s.get("_gate_spawn_done") as Array
	var pd2: float = float(s.get("_player_path_dist"))
	var shown: int = 0
	var stray: int = 0
	var cues: int = 0
	var worst: float = 0.0
	for gi2 in gates2.size():
		var g2: Node3D = gates2[gi2]
		if g2 == null or not g2.visible:
			continue
		if gi2 >= zs2.size() or zs2[gi2] < pd2 - 10.0 or zs2[gi2] > pd2 + 160.0:
			continue
		# A gate still sliding in is SUPPOSED to be away from its gate.
		if gi2 >= done.size() or not bool(done[gi2]):
			continue
		shown += 1
		var v2: Node3D = g2.get_node_or_null("VisRoot") as Node3D
		if v2 == null:
			continue
		var off: float = v2.position.length()
		worst = maxf(worst, off)
		if off > 0.6:
			stray += 1
		if not bool((s.get("gate_is_electric") as Array)[gi2]):
			continue
		for c2: Node in v2.get_children():
			if c2 is MultiMeshInstance3D or (c2 is MeshInstance3D
					and (c2 as Node3D).position.y < 0.2):
				cues += 1
				break
	print("  %-16s settled gates %d, displaced %d (worst %.2f m), with floor cues %d" % [
		where, shown, stray, worst, cues])
	_check(stray == 0, "%s: %d settled gate visuals are away from their gate" % [where, stray])
	# Electric gates carry no floor cues by design — no approach marks, no
	# safe strip. The zone is a blackout and reading the gate is the challenge,
	# so nothing in there paints the way through.
	if where.begins_with("inside") and shown > 0:
		_check(cues == 0, "%d gates inside the zone still show floor cues" % cues)
		# Gates are always on screen; what changes is how hard they burn. So the
		# thing to check is that a gate still out in the dark is dimmer than one
		# that has closed — not that it is missing, which is what this used to
		# assert and what made the zone unreadable to play.
		var looks2: Variant = s.get("_looks")
		var lights2: Array = looks2.get("arc_lights") as Array
		var idx2: Array = looks2.get("arc_gate_idx") as Array
		var near_e: float = -1.0
		var far_e: float = -1.0
		for li in lights2.size():
			var l2 := lights2[li] as OmniLight3D
			if l2 == null or not is_instance_valid(l2) or li >= idx2.size():
				continue
			var g4: int = int(idx2[li])
			if g4 < 0 or g4 >= zs2.size():
				continue
			var ahead2: float = zs2[g4] - pd2
			if ahead2 > 10.0 and ahead2 < 45.0:
				near_e = maxf(near_e, l2.light_energy)
			elif ahead2 > 110.0 and ahead2 < 200.0:
				far_e = maxf(far_e, l2.light_energy)
		if near_e >= 0.0 and far_e >= 0.0:
			print("    gate arcs: %.2f near, %.2f far" % [near_e, far_e])
			_check(far_e < near_e * 0.6,
				"a gate out at distance burns %.2f against %.2f up close — it is not igniting late" % [
					far_e, near_e])




## How many gates are readable ahead, averaged over a few seconds of real play.
## The preview is a fraction, so a single frame cannot test it: the gate after
## next is up for part of each gap and down for the rest, and either sample on
## its own looks like a whole number.
func _check_preview_budget(s: Node) -> void:
	var gates: Array = s.get("gate_nodes") as Array
	var elec: Array = s.get("gate_is_electric") as Array
	var total: int = 0
	var worst: int = 0
	var samples: int = 0
	var waited: float = 0.0
	while waited < 4.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		var zs: PackedFloat32Array = s.get("gate_world_zs")
		var pd: float = float(s.get("_player_path_dist"))
		var n: int = 0
		for gi in gates.size():
			if gi >= zs.size() or gi >= elec.size() or not bool(elec[gi]):
				continue
			# Clearly ahead, not the one being crossed. _player_path_dist is a
			# projection onto the path and wobbles either side of a gate as the
			# player passes through it, so a gate at zero flickers between
			# behind and ahead and lands in the count twice.
			if zs[gi] - pd <= 2.0:
				continue
			var g: Node3D = gates[gi]
			if g == null or not g.visible:
				continue
			var v: Node3D = g.get_node_or_null("VisRoot") as Node3D
			if v != null and v.visible:
				n += 1
		total += n
		worst = maxi(worst, n)
		samples += 1
	var mean: float = float(total) / float(maxi(samples, 1))
	print("    gates readable ahead: %.2f average, %d worst (preview %.1f beats)" % [
		mean, worst, GameConfig.gate_preview_beats])
	_check(worst <= 2, "%d electric gates were readable at once — the zone can be planned" % worst)
	_check(mean > 1.3 and mean < 2.1,
		"average gates ahead was %.2f, which is not the 1.5-2 the zone is meant to give" % mean)


## The two things a screenshot cannot show: that the gate lights actually
## flicker, and that the gates drift on their mounts without the judge areas
func _check_electric_detail(s: Node) -> void:
	var looks: Variant = s.get("_looks")
	var lights: Array = looks.get("arc_lights") as Array
	var idx: Array = looks.get("arc_gate_idx") as Array
	# It has to be a light the player is actually near: the ones behind are not
	# written any more and hold whatever value they had when they went past,
	# which looks exactly like a flicker that is not working.
	var zs: PackedFloat32Array = s.get("gate_world_zs")
	var pd: float = float(s.get("_player_path_dist"))
	var lit: OmniLight3D = null
	var lit_i: int = -1
	for i in lights.size():
		var l := lights[i] as OmniLight3D
		if l == null or not is_instance_valid(l):
			continue
		var gi0: int = int(idx[i]) if i < idx.size() else -1
		if gi0 < 0 or gi0 >= zs.size():
			continue
		if zs[gi0] < pd + 5.0 or zs[gi0] > pd + 120.0:
			continue
		lit = l
		lit_i = i
		break
	if not _check(lit != null, "no gate light ahead of the player inside the zone"):
		return
	var lo: float = 1e9
	var hi: float = -1e9
	for f in 40:
		await get_tree().process_frame
		lo = minf(lo, lit.light_energy)
		hi = maxf(hi, lit.light_energy)
	_check(hi - lo > 0.2, "gate light never flickered (%.2f..%.2f)" % [lo, hi])
	_check(lit.omni_range > 10.0, "gate light did not widen its throw (%.1f m)" % lit.omni_range)

	# The visual drifts; the thing being judged does not.
	var gates: Array = s.get("gate_nodes") as Array
	var gi: int = int(idx[lit_i]) if lit_i < idx.size() else -1
	if gi >= 0 and gi < gates.size():
		var gate: Node3D = gates[gi]
		var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
		_check(vis != null and vis.position.length() > 0.001,
			"the gate visual is not drifting inside the dark")
		var area: Node3D = null
		for c: Node in gate.get_children():
			if c is Area3D:
				area = c as Node3D
		_check(area == null or area.position.length() < 0.001,
			"the judge area moved with the visual — hits would drift with it")


## Photographs a frame mid-run, then once more with each group of the level
## switched off. Finding a thing from a screenshot by grepping for likely
## names does not work when the thing has no name worth grepping for.
func _big_meshes() -> void:
	_story_context()
	Run.run_seed = ABLATE_SEED
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	# Out of the rift intro and into open track, where the thing being
	# looked for is actually on screen.
	var section: Node = _find_section(level)
	while float(section.get("_player_path_dist")) < 250.0:
		await get_tree().process_frame
	get_tree().paused = true
	await _frames(20)
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	get_viewport().get_texture().get_image().save_png("%s/bigmesh_frame.png" % SHOT_DIR)
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		print("  no camera")
		return
	# Hide each group in turn and photograph the result, so a thing seen in a
	# screenshot can be traced to the code that draws it. Geometry queries are
	# no good for this: an AABB around a long diagonal laser covers half the
	# screen, and the thing being looked for is usually not the biggest box.
	for child: Node in _find_section(level).get_children():
		var vis := child as Node3D
		if vis == null or not vis.visible:
			continue
		vis.visible = false
		await _frames(4)
		get_viewport().get_texture().get_image().save_png(
			"%s/hide_%s.png" % [SHOT_DIR, child.name])
		print("  hide_%s.png" % child.name)
		vis.visible = true
		await _frames(2)
	get_tree().paused = false
	_shut_down(level)
	await _frames(10)


## How much more neon the frame can carry. These knobs are read once while the
## level builds itself, so each candidate needs its own boot — and each boot is
## photographed at the shared post-load state, before anything has moved.
func _world_density() -> void:
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	for cand: Array in [
		["world_now", {}],
		["world_lights", {"ambient_light_spacing_m": 14.0, "laser_fixtures": 34}],
		["world_lights_more", {"ambient_light_spacing_m": 10.0, "laser_fixtures": 50}],
		["world_fur_mid", {"fur_scale": 1.6}],
		["world_fur", {"fur_scale": 1.9}],
		["world_now_again", {}],
	]:
		GraphicsQuality.dev_clear_overrides()
		for key: String in (cand[1] as Dictionary):
			GraphicsQuality.dev_override(key, (cand[1] as Dictionary)[key])
		_story_context()
		Run.run_seed = ABLATE_SEED
		var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
		add_child(level)
		await _until_level_ready(level)
		var section: Node = _find_section(level)

		# The shot comes from the one state every boot genuinely shares: the
		# moment loading finishes, before anything has moved. Driving to a
		# fixed distance first does NOT work — the auto-runner takes different
		# hits in each build, so the same path distance lands at a different
		# place in the song, and the "difference" being measured is the
		# scenery, not the setting.
		await _frames(90)
		get_tree().paused = true
		await _frames(30)
		get_viewport().get_texture().get_image().save_png(
			"%s/%s.png" % [SHOT_DIR, cand[0]])
		get_tree().paused = false
		await _frames(10)

		# Cost, though, wants the track moving under it.
		while float(section.get("_player_path_dist")) < 300.0:
			await get_tree().process_frame
		var ms: float = await _measure()
		var lights: int = 0
		var shells: int = 0
		for node: Node in section.find_children("*", "Light3D", true, false):
			lights += 1
		var player: Node = section.get("player")
		if player != null:
			shells = GraphicsQuality.scale_fur_shells(int(player.get("fur_shells")))
		print("  %-16s %6.2f ms (%5.1f fps)   %4d lights   %3d fur shells   %5d draw calls" % [
			cand[0], ms, 1000.0 / ms, lights, shells,
			RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
		_shut_down(level)
		await _frames(20)
	GraphicsQuality.dev_clear_overrides()
	print("  written to %s" % ProjectSettings.globalize_path(SHOT_DIR))


## Waits for something to become true, or gives up after `seconds`. Anything
## driven by a tween has to be waited for in seconds: a frame count means one
## thing at 60 fps and something quite different at 130.
func _until(cond: Callable, seconds: float) -> void:
	var waited: float = 0.0
	while waited < seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if bool(cond.call()):
			return


## Mean frame time over 300 frames, in milliseconds.
func _measure() -> float:
	var total: float = 0.0
	for i in 300:
		await get_tree().process_frame
		total += get_process_delta_time() * 1000.0
	return total / 300.0


## What the two long waits cost, and how much Preload takes off them.
func _loadtime() -> void:
	for warmed: bool in [false, true]:
		var label: String = "warmed" if warmed else "cold"
		if warmed:
			var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
			add_child(map)
			await _frames(40)
			await _until_warm()
			map.queue_free()
			await _frames(5)
		_story_context()
		var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
		add_child(level)
		await _frames(240)
		var section: Node = _find_section(level)
		print("level, %s:" % label)
		if section != null:
			for step: Dictionary in (section.get("load_timings") as Array):
				print("  %5d ms  %s" % [int(step["ms"]), String(step["step"])])
		if warmed:
			Preload.warm("map", PackedStringArray([MAP_SCENE, StoryMap.BAKED_CITY]))
			await _frames(2)
			await _until_warm()
		_shut_down(level)
		await _frames(5)
		var t0 := Time.get_ticks_msec()
		var back: Node = (load(MAP_SCENE) as PackedScene).instantiate()
		add_child(back)
		print("map, %s: %d ms" % [label, Time.get_ticks_msec() - t0])
		await _frames(20)
		back.queue_free()
		await _frames(5)


# ── Pictures ─────────────────────────────────────────────────────────────────

## The standard framings, so two passes over the art can be compared like for
## like. `_entering` is the map's own entry beat pulling the camera down, and it
## is the only close view the game ever has of the city.
func _shots(prefix: String) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	add_child(map)
	await _frames(40)
	var data: StoryMapData = map.get("_data")
	var play: Node3D = map.find_child("Playground", true, false) as Node3D
	await _shot(map, prefix + "_day_map", 1.0, Vector3.INF)
	await _shot(map, prefix + "_dusk_map", 2.0, Vector3.INF)
	await _shot(map, prefix + "_night_map", 3.0, Vector3.INF)
	await _shot(map, prefix + "_day_hub", 1.0, data.hub_position + Vector3(0.0, 0.0, 6.0))
	if data.order.size() > 3:
		await _shot(map, prefix + "_day_rift", 1.0, data.position_of(data.order[3]))
		await _shot(map, prefix + "_night_rift", 3.0, data.position_of(data.order[3]))
	if play != null:
		await _shot(map, prefix + "_day_park", 1.0, play.global_position)
	print("  written to %s" % ProjectSettings.globalize_path(SHOT_DIR))


## Every screen that has UI on it, photographed at the project's own canvas
## size. This is the pass that shows whether a change to the UI scale pushed a
## label off an edge or crowded the play lanes — scale_for() is one number read
## by eight scripts, so the only honest check is to look at all of them.
func _ui_shots() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	print("screens: scale %.2f on a %s canvas" % [
		UiStyle.scale_for(get_viewport().get_visible_rect().size),
		str(get_viewport().get_visible_rect().size)])
	for entry: Array in [
		["ui_main", "res://scenes/Main.tscn"],
		["ui_song_select", "res://scenes/SongSelect.tscn"],
		["ui_how_to_play", "res://scenes/HowToPlay.tscn"],
		["ui_warnings", "res://scenes/Warnings.tscn"],
		["ui_map", MAP_SCENE],
	]:
		var scene: Node = (load(entry[1]) as PackedScene).instantiate()
		add_child(scene)
		await _frames(90)
		await _shoot(entry[0])
		_shut_down(scene)
		await _frames(5)

	# The HUD mid-song: the one screen whose readouts sit against the edges.
	_story_context()
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	await _frames(420)
	await _shoot("ui_hud")
	_shut_down(level)
	await _frames(5)

	# Pause, death and results come with their own assertions attached.
	await _verify_menus()
	print("  written to %s" % ProjectSettings.globalize_path(SHOT_DIR))


func _shot(map: Node, shot_name: String, hour: float, focus: Vector3) -> void:
	_set_hour(map, hour)
	var close: bool = focus != Vector3.INF
	map.set("_entering", close)
	if close:
		map.set("_entry_focus", focus)
	await _frames(170)
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("  %s" % shot_name)


## Plays a level with nobody at the controls, to see that the track is actually
## there and that nothing hitches while it builds itself in front of the player.
## The runner will take hits — that is fine, it is the track being watched.
func _play(seconds: float, song_key: String = "") -> void:
	Engine.max_fps = 0   # the project caps at 120; that hides every spike
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_story_context(song_key)
	print("  chart: %s" % Run.current_song_key)
	var level: Node = (load(GAME_SCENE) as PackedScene).instantiate()
	add_child(level)
	await _until_level_ready(level)
	var section: Node = _find_section(level)
	print("  loading screen: %d ms" % int((section.get("load_timings") as Array).back()["ms"]))

	var times: PackedFloat32Array = PackedFloat32Array()
	var shot_at: float = 0.0
	var elapsed: float = 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		elapsed += dt
		# Skip the countdown and the first bars: shaders are still compiling
		# there, and that spike is not what this is looking for.
		if elapsed > 3.0:
			times.append(dt)
		if elapsed >= shot_at:
			get_viewport().get_texture().get_image().save_png(
				"%s/play_%s_%02d.png" % [SHOT_DIR, Run.current_song_key, int(shot_at)])
			shot_at += 2.0
	var built: int = 0
	for flag: bool in (section.get("_gate_vis_built") as Array):
		if flag:
			built += 1
	print("  %d of %d gates built after %.0f s" % [built, (section.get("gate_nodes") as Array).size(), seconds])
	# Against the median rather than a fixed number: what matters is whether
	# some frames cost far more than the frames around them.
	var sorted := times.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2] if sorted.size() > 0 else 0.0
	var p99: float = sorted[int(float(sorted.size()) * 0.99)] if sorted.size() > 0 else 0.0
	var spikes: int = 0
	for dt: float in times:
		if dt > median * 3.0:
			spikes += 1
	print("  frames: median %.2f ms, 99th %.2f ms, worst %.2f ms, %d of %d over 3x median" % [
		median * 1000.0, p99 * 1000.0, sorted[sorted.size() - 1] * 1000.0, spikes, times.size()])
	print("  shots in %s" % ProjectSettings.globalize_path(SHOT_DIR))
	_shut_down(level)
	await _frames(5)


# ── Baking ───────────────────────────────────────────────────────────────────

func _bake() -> void:
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	add_child(map)
	await _frames(10)
	var t0 := Time.get_ticks_msec()
	# Not awaited: it saves before its first await, and what comes after is a
	# reload of the map that this harness has no use for.
	map.call("_bake_city")
	print("  baked in %d ms" % (Time.get_ticks_msec() - t0))
	map.queue_free()
	await _frames(10)
	await _verify_baked_city()


# ── Plumbing ─────────────────────────────────────────────────────────────────

## A story run set up the way StoryMap does. With no `want` it takes the first
## node that has a chart; name a chart key to run that one instead.
func _story_context(want: String = "") -> void:
	var data := StoryMapData.load_from()
	var key: String = ""
	var node_id: String = ""
	for id: String in data.order:
		var k: String = data.song_key_of(id)
		if k == "" or (want != "" and k != want):
			continue
		key = k
		node_id = id
		break
	if key == "" and want != "":
		# Not on the map, or nothing claims its level: play it anyway.
		key = want
		node_id = data.order[0] if data.order.size() > 0 else ""
	Run.runner_pattern_mode = "run_random"
	Run.current_song_key = key
	Run.story_node_id = node_id
	Run.story_accent = Color(0.72, 0.30, 1.0)
	Run.run_seed = 0
	Run.song_lives = GameConfig.lives_per_song


func _set_hour(map: Node, hour: float) -> void:
	map.set("_time_hold", int(hour))
	map.set("_time", hour)
	map.call("_apply_time", hour)


## Waits for a level to finish its loading screen, by watching the record it
## keeps of its own steps.
func _until_level_ready(level: Node) -> void:
	var section: Node = level if level.has_method("_loading_step") else _find_section(level)
	for i in 600:
		await get_tree().process_frame
		if section == null or not is_instance_valid(section):
			return
		var steps: Array = section.get("load_timings")
		if steps != null and steps.size() > 0 and String(steps[steps.size() - 1]["step"]) == "ready":
			return
	print("  note: level never finished loading")


## Stops a level before freeing it: music off first, so the audio server is not
## left holding a stream belonging to a node that is going away.
func _shut_down(node: Node) -> void:
	var music := node.find_child("Music", true, false) as AudioStreamPlayer
	if music != null:
		music.stop()
	node.queue_free()


## The scene file is Section_BeatRunner3D.tscn but its root node is spelled
## Section_BeatRunner3d, so this matches on the pattern rather than the name.
func _find_section(level: Node) -> Node:
	return level.find_child("Section_BeatRunner3*", true, false)


func _note_skins(mesh: Mesh, out: Dictionary) -> void:
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		var m: Material = mesh.surface_get_material(i)
		if m != null and m.resource_name != "":
			out[m.resource_name] = true


func _walk(node: Node, fn: Callable) -> void:
	fn.call(node)
	for child in node.get_children():
		_walk(child, fn)


func _until_warm() -> void:
	for i in 1200:
		await get_tree().process_frame
		if Preload.is_idle():
			return
	print("  note: preload never finished")


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
