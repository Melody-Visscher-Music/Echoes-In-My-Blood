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

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "verify"
	var arg: String = args[1] if args.size() > 1 else ""
	print("-- dev harness: %s --" % mode)
	match mode:
		"verify":
			await _verify()
		"perf":
			await _perf()
		"loadtime":
			await _loadtime()
		"shots":
			await _shots(arg if arg != "" else "shot")
		"bake":
			await _bake()
		"play":
			await _play(float(arg) if arg != "" else 14.0,
				args[2] if args.size() > 2 else "")
		_:
			print("unknown mode '%s' - try verify | perf | loadtime | shots | bake" % mode)
	if _checks > 0:
		print("-- %d checks, %d failed --" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


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

	Save.dev_use_path(Save.PATH)   # back to the real one before anything else runs
	for name: String in DirAccess.open("user://").get_files():
		if name.begins_with("devsave_") or name.begins_with("save.corrupt-"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + name))


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
