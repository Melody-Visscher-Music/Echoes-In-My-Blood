extends Node3D
class_name StoryMap

## Story Mode level select — the 3D node map of the city.
##
## PROTOTYPE. Every mesh on this screen is a primitive standing in for art that
## does not exist yet; what is real is the behaviour:
##
##   * the hub/branch/node graph comes from data (res://data/story/story_map.json
##     via StoryMapData), not from anything authored into this scene;
##   * only UNLOCKED rifts exist on the map — locked ones are not drawn at all,
##     not greyed out;
##   * clicking (or selecting and confirming) a rift makes Meeko walk himself
##     there through the streets — the player never drives him directly;
##   * clearing a level reveals the next rift.
##
## There are no drawn routes between rifts. There used to be, following the
## unlock tree, back when travel followed that tree too. Travel takes the
## shortest way through the streets now, so a drawn trail showed a road Meeko
## did not use — worse than no line at all.
##
## Freeplay is untouched by all of this: scripts/SongSelect.gd is still the flat
## song list and still the only thing the FREEPLAY menu entry reaches. This is a
## second, separate mode, and the two share nothing but the beatmap keys.
##
## ── Picking ──────────────────────────────────────────────────────────────────
## Rifts are picked in SCREEN SPACE (unproject each rift, take the nearest one
## inside a pixel radius) rather than with Area3D and physics picking. Two
## reasons: physics picking needs Viewport.physics_object_picking flipped on,
## which is global state this screen would have to remember to put back, and a
## rift is only a few pixels across from map distance — a generous pixel radius
## is what actually makes it clickable, not an accurate collision shape.

const MAP_JSON: String = "res://data/story/story_map.json"
const MAIN_SCENE: String = "res://scenes/Main.tscn"
## The scene a level runs in. Same one Freeplay launches, on purpose: a story
## level and a Freeplay run of the same chart are the same level — the only
## difference is the story context Run carries in with it.
const LEVEL_SCENE: String = "res://scenes/GameScene.tscn"
## The hand-editable city. Present = the map instances it; absent = the map
## generates one and Ctrl+Alt+B can bake it here.
const BAKED_CITY: String = "res://scenes/story/CalderCity.tscn"

## Camera stays at map distance at all times — it never approaches the ground,
## which is why the city is built for silhouette rather than detail.
const CAM_HEIGHT: float = 124.0
const CAM_BACK: float = 74.0
const CAM_FOV: float = 46.0
const CAM_FOLLOW_RATE: float = 2.6

## How near the pointer has to be to a rift's screen position to count, in
## pixels at the 1920x1080 reference (scaled with the viewport).
const PICK_PIXELS: float = 90.0

var _data: StoryMapData = null
var _cleared: PackedStringArray = PackedStringArray()

var _rifts: Dictionary = {}            # node id -> StoryRift
var _walker: StoryWalker = null
var _camera: Camera3D = null
var _cam_focus: Vector3 = Vector3.ZERO
## True when the city came from BAKED_CITY rather than from the generator.
var _city_is_baked: bool = false
## Dev override: show every rift whatever the save says. A VIEW toggle, not a
## save edit — nothing is written, so turning it off puts the map straight back
## to real progress, and rifts stay un-closed so their art can be looked at.
var _reveal_all: bool = false

## Where Meeko is standing (a node id, or the hub id). Only ever changed by the
## walker arriving, so it cannot drift out of sync with what is on screen.
var _at_node: String = ""
var _selected: String = ""
var _hovered: String = ""

var _title_label: Label = null
var _detail_label: Label = null
var _hint_label: Label = null
var _s: float = 1.0


func _ready() -> void:
	_s = UiStyle.scale_for(get_viewport().get_visible_rect().size)

	_data = StoryMapData.load_from(MAP_JSON)

	# Coming back from a level. Read the story context BEFORE clearing it: the
	# map is not a level, so nothing from here on may look like a story run.
	var just_cleared: String = Run.story_just_cleared
	var start_node: String = Save.get_story_position()
	Run.end_story_context()
	if not _data.has_node_id(start_node):
		start_node = _data.hub_id

	# The clear is already on disk by the time the map reloads, so building
	# straight from it would show the newly opened rift as if it had always been
	# there. Build the map as it stood BEFORE the clear, then apply the clear
	# with animation — that is what makes the reveal a reveal.
	var cleared_now: PackedStringArray = Save.get_story_cleared()
	_cleared = cleared_now
	if just_cleared != "":
		_cleared = PackedStringArray()
		for id: String in cleared_now:
			if id != just_cleared:
				_cleared.append(id)

	_at_node  = start_node
	_selected = ""   # so the first _set_selected() below actually applies

	_build_environment()
	_build_world()
	_build_rifts()
	_build_walker()
	_build_camera()
	_build_hud()

	# Shelters need the world in the tree (for global transforms) and the walker
	# placed, so this is the first point both are true.
	_collect_shelters(self)

	# No animation on this pass: the map opens showing the city the player has
	# already opened up, it does not replay every past reveal.
	_refresh_visibility(false)
	if start_node != _data.hub_id:
		_set_selected(start_node)
	else:
		_select_first_available()
	_update_hud()

	if _data.load_error != "":
		_detail_label.text = _data.load_error
		return

	if just_cleared != "":
		_play_return_reveal(just_cleared, cleared_now)


## The reveal after a level is beaten, played on arriving back at the map.
##
## TODO(cutscene): the real beat is a cutscene — camera move, the rift closing,
## the next one tearing open. The delay here stands in for its timing so the
## surrounding flow (path light-up, re-selection) is already correct.
func _play_return_reveal(just_cleared: String, cleared_now: PackedStringArray) -> void:
	_detail_label.text = "%s  ·  CLOSED" % _data.title_of(just_cleared)
	_hint_label.text = "RIFT CLOSED"
	await get_tree().create_timer(1.1).timeout
	if not is_inside_tree():
		return
	_cleared = cleared_now
	_refresh_visibility(true)
	_focus_newly_revealed()


# ── World construction ───────────────────────────────────────────────────────

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# An overcast late-afternoon sky. Muted on purpose — the rifts are the only
	# saturated thing allowed on this screen.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color     = Color(0.38, 0.44, 0.56)
	sky_mat.sky_horizon_color = Color(0.62, 0.63, 0.66)
	sky_mat.ground_bottom_color = Color(0.24, 0.23, 0.24)
	sky_mat.ground_horizon_color = Color(0.46, 0.45, 0.46)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.05
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0

	# Contact shading. From map height the city is read almost entirely through
	# where one box meets another, and without occlusion in the gaps a block of
	# buildings flattens into a single grey mass.
	env.ssao_enabled = true
	env.ssao_radius = 3.0
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.ssao_detail = 0.4

	# Just enough glow that the rift emissives bleed; the city sits well under
	# the threshold and stays flat.
	env.glow_enabled = true
	env.glow_intensity = 1.1
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.25

	env.fog_enabled = true
	env.fog_light_color = Color(0.52, 0.53, 0.58)
	env.fog_density = 0.0022
	env.fog_sky_affect = 0.35

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color  = Color(1.00, 0.96, 0.90)
	sun.light_energy = 1.85
	# Low and off-axis, so every building throws a long shadow across the street
	# beside it. Those shadows are what give the grid depth from directly above.
	sun.rotation_degrees = Vector3(-38.0, 34.0, 0.0)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	add_child(sun)

	# A cool fill from the opposite side, unshadowed. Pure sun-plus-ambient left
	# every north face the same flat value; this separates the faces so massing
	# reads without lifting the whole city.
	var fill := DirectionalLight3D.new()
	fill.name = "SkyFill"
	fill.light_color  = Color(0.72, 0.78, 0.94)
	fill.light_energy = 0.45
	fill.rotation_degrees = Vector3(-24.0, -142.0, 0.0)
	fill.shadow_enabled = false
	add_child(fill)


## Puts the city on screen.
##
## NOTHING here may add city geometry on top of a baked scene. The scene IS the
## city — if a building is not in CalderCity.tscn it must not be in the game.
## Wall rifts used to bring their own facade at runtime, which meant buildings
## appeared in play that could not be found or deleted in the editor. Anything a
## wall rift needs to be cut into gets baked, and is then just another building
## to move or remove like the rest of them.
##
## Two routes in. If res://scenes/story/CalderCity.tscn exists it is instanced
## as-is — that scene is a real, hand-editable tree, and whatever has been moved,
## deleted or added in the editor is what the player sees. Otherwise the city is
## generated procedurally, exactly as before, and Ctrl+Alt+B bakes that result
## out to the scene so it can be taken over by hand.
##
## The baked scene also carries a Marker3D per rift under RiftAnchors. Dragging
## one in the editor moves the rift AND re-routes the streets Meeko walks to
## reach it, because the anchors are applied to the map data before anything
## else is built from it.
func _build_world() -> void:
	if ResourceLoader.exists(BAKED_CITY):
		_instance_baked_city()
		return
	_build_city_procedural(self)
	_build_hub_marker(self)


func _instance_baked_city() -> void:
	var packed: PackedScene = load(BAKED_CITY) as PackedScene
	if packed == null:
		push_error("[StoryMap] %s exists but would not load — falling back to procedural." % BAKED_CITY)
		_build_city_procedural(self)
		_build_hub_marker(self)
		return

	var city: Node = packed.instantiate()
	city.name = "CalderCity"
	add_child(city)
	_city_is_baked = true

	# Anchors win over the branch maths, so a rift dragged in the editor stays
	# where it was put and the routes follow it there.
	var anchors: Node = city.get_node_or_null("RiftAnchors")
	if anchors == null:
		print("[StoryMap] baked city has no RiftAnchors — positions come from the map data.")
		return
	var overrides: Dictionary = {}
	for child in anchors.get_children():
		var marker := child as Node3D
		if marker == null or not String(marker.name).begins_with("Rift_"):
			continue
		overrides[String(marker.name).substr(5)] = marker.transform
	_data.apply_anchor_overrides(overrides)
	print("[StoryMap] baked city loaded; %d rift anchors applied." % overrides.size())


func _build_city_procedural(parent: Node3D) -> void:
	# Everything the city has to leave room for: the hub, every rift (whether or
	# not it is unlocked yet — a building may not appear inside a rift that has
	# not opened yet either), and every route trail.
	var keep_clear: Array[Dictionary] = [{"pos": _data.hub_position, "radius": 20.0}]
	for id: String in _data.order:
		keep_clear.append({"pos": _data.position_of(id), "radius": 11.0})

	# The only stretch of any journey that is NOT already a road is the spur from
	# a rift out to its doorstep, so that is all the buildings have to stand
	# clear of. This used to keep them off the whole drawn route between nodes,
	# back when there was one; those routes ran down streets, which are gaps
	# between blocks by construction, so it was clearing space that was already
	# empty and thinning the city for nothing.
	var paths: Array[PackedVector3Array] = []
	var walked: PackedStringArray = PackedStringArray([_data.hub_id])
	walked.append_array(_data.order)
	for id: String in walked:
		var spur := PackedVector3Array([_data.position_of(id), _data.doorstep_of(id)])
		if spur[0].distance_to(spur[1]) > 0.5:
			paths.append(spur)

	var city := StoryCity.new()
	city.name = "City"
	parent.add_child(city)
	city.build(_data.hub_position, _data.extent() + 78.0, keep_clear, paths)


## The hub is a civic square, not a rift — the one node that is always open, and
## where Meeko starts. The geometry lives in StoryCity with the rest of the
## city furniture, so the map and the bake build the same plaza.
func _build_hub_marker(parent: Node3D) -> void:
	StoryCity.build_hub(parent, _data.hub_position, _data.hub_facing)


# ── Baking the city to an editable scene ─────────────────────────────────────

## Ctrl+Alt+B. Generates the city once more and writes it to BAKED_CITY as a
## normal scene of plain Node3D/MeshInstance3D nodes, then reloads the map onto
## it. From then on the map instances that scene instead of generating, so
## anything moved or deleted in the editor sticks.
##
## Baking again OVERWRITES those edits — it is a fresh generation, not a merge.
## That is why it is a deliberate keystroke and not something the map does on its
## own when the file is missing.
func _bake_city() -> void:
	var root := Node3D.new()
	root.name = "CalderCity"
	add_child(root)

	_build_city_procedural(root)
	_build_hub_marker(root)

	# Rift anchors: one Marker3D per node, carrying the position AND the way it
	# faces. StoryRift.face_toward() aims local +Z, so the marker is built the
	# same way and apply_anchor_overrides() reads it back the same way.
	var facades := Node3D.new()
	facades.name = "RiftFacades"
	root.add_child(facades)
	for id: String in _data.order:
		if _variant_for(id) == StoryRift.VARIANT_WALL:
			StoryCity.build_rift_facade(facades, _data.position_of(id),
				_data.facing_of(id), "Facade_%s" % id)

	var anchors := Node3D.new()
	anchors.name = "RiftAnchors"
	root.add_child(anchors)
	for id: String in _data.order:
		var marker := Marker3D.new()
		marker.name = "Rift_%s" % id
		marker.position = _data.position_of(id)
		var facing: Vector3 = _data.facing_of(id)
		marker.rotation.y = atan2(facing.x, facing.z)
		anchors.add_child(marker)

	# The generator's own node keeps a script that would only confuse anyone
	# opening the scene — the baked city is data, not a generator.
	var city: Node = root.get_node_or_null("City")
	if city != null:
		city.set_script(null)

	_claim(root, root)

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("[StoryMap] could not pack the city.")
		root.queue_free()
		return
	var dir := DirAccess.open("res://scenes")
	if dir != null and not dir.dir_exists("story"):
		dir.make_dir("story")
	var err: int = ResourceSaver.save(packed, BAKED_CITY)
	root.queue_free()

	if err != OK:
		push_error("[StoryMap] saving %s failed (code %d)." % [BAKED_CITY, err])
		_detail_label.text = "BAKE FAILED — SEE OUTPUT"
		return

	print("[StoryMap] baked the city to %s — open it in the editor to change it." % BAKED_CITY)
	_detail_label.text = "CITY BAKED"
	_hint_label.text = "SAVED TO %s  ·  RELOADING" % BAKED_CITY
	await get_tree().create_timer(0.9).timeout
	if is_inside_tree():
		get_tree().reload_current_scene()


## PackedScene only keeps nodes that belong to the scene being packed, so every
## descendant has to be claimed by the root before it is worth saving.
func _claim(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_claim(child, root)


## Which look a node wears. Purely visual variety — no gameplay reads this.
##
## Derived from the node's index rather than a running counter, because the
## rifts and their buildings are built in separate passes and both have to
## arrive at the same answer.
func _variant_for(id: String) -> String:
	var entry: Dictionary = _data.nodes.get(id, {}) as Dictionary
	var variant: String = String(entry.get("variant", "auto"))
	if variant != "auto":
		return variant
	# Alternating keeps a cluster from being three of the same thing in a row.
	return StoryRift.VARIANT_GROUND if _data.order.find(id) % 2 == 0 else StoryRift.VARIANT_WALL


func _build_rifts() -> void:
	for id: String in _data.order:
		var variant: String = _variant_for(id)

		var rift := StoryRift.new()
		rift.name = "Rift_%s" % id
		add_child(rift)
		rift.position = _data.position_of(id)
		rift.setup(id, _data.title_of(id), variant, _accent_for(id))
		# A rift faces the road it fronts onto, so the wall variant's facade ends
		# up behind it inside the block instead of standing in the carriageway.
		rift.face_toward(_data.position_of(id) + _data.facing_of(id))
		rift.picked.connect(_on_rift_picked)
		_rifts[id] = rift


func _build_walker() -> void:
	_walker = StoryWalker.new()
	_walker.name = "Meeko"
	add_child(_walker)
	_walker.setup(UiStyle.CYAN)
	# Meeko starts wherever the save says he is standing, not always at the hub —
	# coming back from a level has to put him at the rift he just played. He
	# faces the way he arrived (away from whatever the node connects back to),
	# so a restored position looks walked-to rather than dropped in.
	var here: Vector3 = _data.position_of(_at_node)
	var facing: Vector3 = here - _data.position_of(_data.parent_of(_at_node))
	facing.y = 0.0
	if facing.length_squared() < 0.001:
		facing = Vector3(0.0, 0.0, 1.0)
	_walker.snap_to(here, facing)
	_walker.arrived.connect(_on_walker_arrived)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "MapCamera"
	_camera.fov = CAM_FOV
	_camera.far = 900.0
	add_child(_camera)
	# Opens framed on Meeko, wherever he is — otherwise a map restored at an
	# outlying rift opens looking at the hub and slides across the city.
	_cam_focus = _walker.global_position if _walker != null else _data.hub_position
	_place_camera(_cam_focus)
	_camera.current = true


func _place_camera(focus: Vector3) -> void:
	_camera.global_position = focus + Vector3(0.0, CAM_HEIGHT, CAM_BACK)
	_camera.look_at(focus, Vector3.UP)


# ── HUD ──────────────────────────────────────────────────────────────────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MapHud"
	add_child(layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# The map data holds the city's name as written ("Calder City"); the caps are
	# the screen's, not the data's — same split SongSelect uses for song titles.
	_title_label = UiStyle.label(_data.map_title.to_upper(), UiStyle.caption(7.0), int(22 * _s),
		Color.WHITE, int(3 * _s))
	_title_label.position = Vector2(56 * _s, 40 * _s)
	_title_label.self_modulate = UiStyle.signature_color(0.1)
	root.add_child(_title_label)

	# PlatePanel has no size of its own — it takes it from `content` — so it has
	# to sit in containers rather than be positioned by hand. Bottom-aligned
	# column, centred row, panel at its own minimum size.
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_END
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(column)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	var panel := PlatePanel.create(int(22 * _s), UiStyle.VIOLET, 18.0 * _s)
	panel.custom_minimum_size = Vector2(680 * _s, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(panel)

	var bottom_pad := Control.new()
	bottom_pad.custom_minimum_size = Vector2(0, 46 * _s)
	bottom_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(bottom_pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(4 * _s))
	panel.content.add_child(col)

	_detail_label = UiStyle.label("", UiStyle.caption(3.5), int(19 * _s), Color.WHITE)
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.self_modulate = Color(1.00, 0.90, 1.00)
	col.add_child(_detail_label)

	_hint_label = UiStyle.label("", UiStyle.display(600), int(12 * _s), Color.WHITE)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.self_modulate = Color(0.60, 0.55, 0.76)
	col.add_child(_hint_label)


func _update_hud() -> void:
	if _detail_label == null:
		return

	var target: String = _selected
	var target_title: String = _data.title_of(target)
	var song: String = _data.song_key_of(target)

	if _walker != null and _walker.is_walking():
		_detail_label.text = "TRAVELLING TO  %s" % target_title
		_hint_label.text = "MEEKO IS ON HIS WAY"
		return

	# The chart line says which level this is and which beatmap claimed that
	# number, so a mis-numbered chart is visible on the screen that depends on it
	# rather than only showing up as the wrong song starting.
	var level: int = _data.level_of(target)
	var song_line: String = ""
	if song != "":
		song_line = "  ·  LV %02d  %s" % [level, song.replace("_", " ").to_upper()]
	elif level > 0:
		# Says SKIPPED, not just PENDING: an empty rift does not hold the run up,
		# so the player should read it as scenery rather than as a wall.
		song_line = "  ·  LV %02d  NO CHART — SKIPPED" % level

	# Reveal-all is loud on purpose: a map showing rifts the save has not earned
	# looks like broken progress unless it says why.
	var dev: String = "  [DEV: ALL REVEALED]" if _reveal_all else ""

	if target == _data.hub_id:
		_detail_label.text = _data.hub_title + dev
		_hint_label.text = "← →  SELECT A RIFT     ENTER / A  TRAVEL     ESC / B  BACK"
		return

	# CLOSED is a fact about the RIFT, not about where Meeko happens to be
	# standing. It used to be worked out inside the you-are-here branch only, so
	# every rift the player had already closed dropped its marker the moment they
	# selected a different one — the last one beaten looked like the only one.
	var closed_mark: String = "  ·  CLOSED" if target in _cleared else ""
	_detail_label.text = "%s%s%s" % [target_title, closed_mark, dev]

	if target != _at_node:
		_hint_label.text = "ENTER / A  TRAVEL%s     ← →  SELECT     ESC / B  BACK" % song_line
	elif song == "":
		_hint_label.text = "NOTHING TO ENTER%s     ← →  SELECT     ESC / B  BACK" % song_line
	elif target in _cleared:
		_hint_label.text = "ENTER / A  RUN AGAIN%s     ← →  SELECT     ESC / B  BACK" % song_line
	else:
		_hint_label.text = "ENTER / A  CLOSE RIFT%s     ← →  SELECT     ESC / B  BACK" % song_line


# ── Visibility / unlock state ────────────────────────────────────────────────

## Brings every rift and trail in line with what has been cleared. `animate`
## plays the reveal flourish on anything that has just become visible — passed
## false on load, true after a clear.
func _refresh_visibility(animate: bool) -> void:
	for id: String in _data.order:
		var rift: StoryRift = _rifts.get(id, null)
		if rift == null:
			continue
		var unlocked: bool = _is_on_map(id)
		if unlocked != rift.is_revealed():
			rift.set_revealed(unlocked, animate and unlocked)
		# Closed rifts dim right down. Driven from the cleared list every refresh
		# rather than set once on the clear, so it is also correct for the rifts
		# already beaten when the map loads.
		rift.set_closed(id in _cleared)


func _is_on_map(id: String) -> bool:
	if id == _data.hub_id or _reveal_all:
		return true
	return _data.is_unlocked(id, _cleared)


## Every node the map is currently showing, in authored order.
func _visible_ids() -> PackedStringArray:
	if not _reveal_all:
		return _data.unlocked_ids(_cleared)
	var all := PackedStringArray()
	for id: String in _data.order:
		all.append(id)
	return all


func _select_first_available() -> void:
	var ids: PackedStringArray = _visible_ids()
	_set_selected(ids[0] if ids.size() > 0 else _data.hub_id)


func _set_selected(id: String) -> void:
	if _selected == id:
		return
	var prev: StoryRift = _rifts.get(_selected, null)
	if prev != null:
		prev.set_selected(false)
	_selected = id
	var now: StoryRift = _rifts.get(id, null)
	if now != null:
		now.set_selected(true)
	_update_hud()


## Left/right walk the unlocked rifts in authored order, with the hub folded in
## at the front so there is always a way back to it without the mouse.
func _cycle_selection(delta: int) -> void:
	var ids: PackedStringArray = PackedStringArray([_data.hub_id])
	ids.append_array(_visible_ids())
	if ids.size() <= 1:
		return
	var idx: int = ids.find(_selected)
	if idx == -1:
		idx = 0
	_set_selected(ids[posmod(idx + delta, ids.size())])


# ── Travel ───────────────────────────────────────────────────────────────────

func _travel_to(id: String) -> void:
	if not _is_on_map(id):
		return
	if id == _at_node:
		return
	var plan: Dictionary = _data.direct_plan(_at_node, id)
	_set_selected(id)
	_walker.walk(plan["points"], plan["ids"], id)
	_update_hud()


func _on_walker_arrived(id: String) -> void:
	_at_node = id
	_update_hud()


func _on_rift_picked(id: String) -> void:
	if _walker.is_walking():
		return
	if id == _at_node:
		_enter_level(id)
	else:
		_travel_to(id)


## Plays the level this rift stands for — for real, if a chart exists.
##
## Which chart that is comes from ContentDB's `song_order` index: the node knows
## it is level 4, and whichever beatmap declares `"song_order": 4` is the one
## that runs. Nothing here, and nothing in the map data, names a song file. That
## is the whole point — dropping a new chart into res://data/beatmaps with a
## `song_order` makes its node playable with no code or data edit anywhere.
##
## A node whose level has no chart yet is inert: it stays on the map, it can
## still be walked to, and it says so rather than doing something surprising.
func _enter_level(id: String) -> void:
	if id == _data.hub_id:
		return

	var song_key: String = _data.song_key_of(id)
	var level: int = _data.level_of(id)
	if song_key == "":
		_detail_label.text = "%s  ·  NO CHART" % _data.title_of(id)
		_hint_label.text = "NOTHING CLAIMS LEVEL %02d YET — CHART IT AND THIS RIFT OPENS" % level
		return

	# SETTLED — do not change this to a fixed layout.
	# Story levels reshape on every attempt. That is the echo mechanic itself:
	# "an echo is never an exact copy of what came before, it comes back
	# changed", and Meeko reading patterns by endgame is the accumulation of
	# those runs. A fixed authored layout would quietly delete that. It is set
	# explicitly here rather than inherited so whichever mode the player last
	# picked in Freeplay can never leak into a story run.
	Run.runner_pattern_mode = "run_random"
	Run.current_song_key    = song_key
	Run.story_node_id       = id
	Run.run_seed            = 0
	Run.song_lives          = GameConfig.lives_per_song
	Save.set_story_position(id)

	_detail_label.text = "ENTERING  %s" % _data.title_of(id)
	_hint_label.text = "LV %02d  ·  %s" % [level, song_key.replace("_", " ").to_upper()]
	print("[StoryMap] level %d (%s) -> %s" % [level, id, song_key])

	var err: int = get_tree().change_scene_to_file(LEVEL_SCENE)
	if err != OK:
		Run.end_story_context()
		_detail_label.text = "FAILED TO LOAD %s (code %d)" % [LEVEL_SCENE, err]
		push_error("[StoryMap] change_scene_to_file failed: code=%d path=%s" % [err, LEVEL_SCENE])


## The reveal entry point for a clear reported while the map is already open.
## The normal route is _play_return_reveal() — the player comes BACK from a
## level, having cleared it there. This stays because a clear can also arrive
## without a scene change (a debug command, and later a cutscene that resolves
## on the map itself).
func _on_level_cleared(id: String) -> void:
	if Save.mark_story_cleared(id):
		_cleared = Save.get_story_cleared()
		_refresh_visibility(true)
		_focus_newly_revealed()
	_update_hud()


## After a reveal, put the selection on the rift the player should go to next —
## the first open one that actually has a chart in it. A clear can open several
## rifts at once when the ones between have no chart yet, and landing the cursor
## on an empty one would point the player at nothing.
func _focus_newly_revealed() -> void:
	var fallback: String = ""
	for id: String in _data.order:
		if id in _cleared or not _data.is_unlocked(id, _cleared):
			continue
		if _data.is_playable(id):
			_set_selected(id)
			return
		if fallback == "":
			fallback = id
	if fallback != "":
		_set_selected(fallback)
	_update_hud()


# ── Input ────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		# Dev: wipe story progress and rebuild the map from scratch. Mirrors the
		# Ctrl+Alt+H high-score wipe on the song list.
		if key.physical_keycode == KEY_R and key.ctrl_pressed and key.alt_pressed:
			get_viewport().set_input_as_handled()
			Save.clear_story_progress()
			get_tree().reload_current_scene()
			return
		# Dev: reveal every rift, ignoring progress. Toggles, and writes nothing.
		if key.physical_keycode == KEY_U and key.ctrl_pressed and key.alt_pressed:
			get_viewport().set_input_as_handled()
			_reveal_all = not _reveal_all
			_refresh_visibility(false)
			if not _is_on_map(_selected):
				_select_first_available()
			_update_hud()
			print("[StoryMap] reveal-all %s" % ("ON" if _reveal_all else "off"))
			return
		# Dev: bake the generated city out to an editable scene. Overwrites any
		# hand edits already in it, so it is a deliberate keystroke.
		if key.physical_keycode == KEY_B and key.ctrl_pressed and key.alt_pressed:
			get_viewport().set_input_as_handled()
			_bake_city()
			return

	if event is InputEventMouseMotion:
		_hover_at((event as InputEventMouseMotion).position)
		return

	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		var hit: String = _pick_at(mb.position)
		if hit != "":
			get_viewport().set_input_as_handled()
			_on_rift_picked(hit)
		return

	if not (event is InputEventKey or event is InputEventJoypadButton):
		return

	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file(MAIN_SCENE)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if not _walker.is_walking():
			if _selected == _at_node:
				_enter_level(_selected)
			else:
				_travel_to(_selected)
	elif event.is_action_pressed("ui_left"):
		get_viewport().set_input_as_handled()
		_cycle_selection(-1)
	elif event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()
		_cycle_selection(1)


func _hover_at(screen_pos: Vector2) -> void:
	var hit: String = _pick_at(screen_pos)
	if hit == _hovered:
		return
	var prev: StoryRift = _rifts.get(_hovered, null)
	if prev != null:
		prev.set_hovered(false)
	_hovered = hit
	var now: StoryRift = _rifts.get(hit, null)
	if now != null:
		now.set_hovered(true)


## Nearest revealed rift to `screen_pos`, or "" when the pointer is not near
## one. Screen space rather than physics — see the note at the top of the file.
func _pick_at(screen_pos: Vector2) -> String:
	if _camera == null:
		return ""
	var threshold: float = PICK_PIXELS * _s
	var best: String = ""
	var best_dist: float = threshold
	for id: String in _rifts.keys():
		var rift: StoryRift = _rifts[id]
		if not rift.is_revealed():
			continue
		var world: Vector3 = rift.anchor_point()
		if _camera.is_position_behind(world):
			continue
		var d: float = _camera.unproject_position(world).distance_to(screen_pos)
		if d < best_dist:
			best_dist = d
			best = id
	return best


# ── Shelters ─────────────────────────────────────────────────────────────────
## Roofs fade out while Meeko is underneath them.
##
## The map camera looks down from 124 m, so anything overhead hides whatever is
## beneath it — the covered plaza swallows Meeko at the exact spot he starts on
## and returns to. Rather than banning roofs, they dissolve when he is under one
## and come back when he leaves, which is what a map camera is expected to do.
##
## A mesh counts as a shelter when it is in the `shelter` group OR its name
## contains "roof", and it sits at least SHELTER_MIN_HEIGHT above the ground.
## The name rule means anything built in the editor and called Roof-something
## just works; the group is there for a roof you would rather call something
## else. Nothing else about the scene has to be set up.

## Alpha a roof drops to with Meeko beneath it — faint rather than gone, so the
## shelter still reads as a structure and its columns do not look freestanding.
const SHELTER_FADE: float = 0.16
const SHELTER_FADE_RATE: float = 6.0
## Ignore anything low enough to be street furniture; a shelter is overhead.
const SHELTER_MIN_HEIGHT: float = 3.0
## Extra metres beyond a roof's own footprint that still count as underneath, so
## it starts fading just before he actually crosses the edge.
const SHELTER_MARGIN: float = 2.5

## Each entry: {"node", "mat", "center": Vector2, "radius", "base_alpha", "alpha"}
var _shelters: Array[Dictionary] = []


func _collect_shelters(root: Node) -> void:
	for child in root.get_children():
		_collect_shelters(child)

		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if not (mi.is_in_group("shelter") or String(mi.name).to_lower().contains("roof")):
			continue

		var world: AABB = mi.global_transform * mi.get_aabb()
		if world.position.y + world.size.y < SHELTER_MIN_HEIGHT:
			continue

		# The material is duplicated per shelter: the baked scene shares material
		# resources between nodes, and fading a shared one would take unrelated
		# parts of the city with it.
		var src := mi.material_override as StandardMaterial3D
		if src == null and mi.mesh.get_surface_count() > 0:
			src = mi.get_active_material(0) as StandardMaterial3D
		if src == null:
			push_warning("[StoryMap] shelter '%s' has no StandardMaterial3D to fade." % mi.name)
			continue
		var mat := src.duplicate() as StandardMaterial3D
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = mat

		var centre := world.get_center()
		_shelters.append({
			"node": mi,
			"mat": mat,
			"center": Vector2(centre.x, centre.z),
			"radius": maxf(world.size.x, world.size.z) * 0.5 + SHELTER_MARGIN,
			"base_alpha": mat.albedo_color.a,
			"alpha": 1.0,
		})


func _update_shelters(delta: float) -> void:
	if _shelters.is_empty() or _walker == null:
		return
	var here := Vector2(_walker.global_position.x, _walker.global_position.z)
	var k: float = clampf(SHELTER_FADE_RATE * delta, 0.0, 1.0)

	for sh: Dictionary in _shelters:
		var under: bool = here.distance_to(sh["center"] as Vector2) < float(sh["radius"])
		var a: float = lerpf(float(sh["alpha"]), SHELTER_FADE if under else 1.0, k)
		sh["alpha"] = a

		var mat: StandardMaterial3D = sh["mat"]
		var col: Color = mat.albedo_color
		mat.albedo_color = Color(col.r, col.g, col.b, float(sh["base_alpha"]) * a)

		# A roof that has faded out but still casts its shadow would leave Meeko
		# standing in a dark disc with nothing overhead to explain it.
		var mi: MeshInstance3D = sh["node"]
		var want: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if a > 0.95 \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mi.cast_shadow != want:
			mi.cast_shadow = want


# ── Camera ───────────────────────────────────────────────────────────────────

## What the camera keeps in frame: Meeko while he is walking, and otherwise the
## rift currently selected.
##
## Following Meeko alone was fine at five nodes, which nearly fit on screen at
## once. At ten they span ~180 m and the camera only shows ~120, so cycling with
## left/right could name a rift that is nowhere on screen — the player would be
## choosing a destination they cannot see. Letting the selection pull the camera
## turns that into a preview of where they are about to send him. Standing on a
## node the two agree anyway, so nothing moves when nothing is being chosen.
func _focus_target() -> Vector3:
	if _walker.is_walking():
		return _walker.global_position
	if _selected != "" and _data.has_node_id(_selected):
		return _data.position_of(_selected)
	return _walker.global_position


func _process(delta: float) -> void:
	if _camera == null or _walker == null:
		return
	# The camera trails Meeko rather than snapping to him, and it never changes
	# height or pitch — at map distance the whole point is that the framing does
	# not change, only what is under it.
	_cam_focus = _cam_focus.lerp(_focus_target(), clampf(CAM_FOLLOW_RATE * delta, 0.0, 1.0))
	_place_camera(_cam_focus)
	_update_shelters(delta)


# ── Graph helpers ────────────────────────────────────────────────────────────

## A rift's colour, walked along the game's own signature band (pink → violet →
## cyan) by authored order. Rifts are the only saturated thing on the map, so
## they share the band the HUD and the track already use rather than inventing
## a palette that belongs to nothing else.
func _accent_for(id: String) -> Color:
	var idx: int = _data.order.find(id)
	if idx < 0:
		return UiStyle.VIOLET
	var span: int = maxi(1, _data.order.size() - 1)
	return UiStyle.signature_color(float(idx) / float(span) * 1.4)
