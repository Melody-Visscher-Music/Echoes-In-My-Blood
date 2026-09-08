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
##     there along the graph — the player never drives him directly;
##   * clearing a level reveals the next rift and lights its route up.
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
var _links: Dictionary = {}            # "from>to"  -> StoryPathLink
var _walker: StoryWalker = null
var _camera: Camera3D = null
var _cam_focus: Vector3 = Vector3.ZERO

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
	_build_city()
	_build_hub_marker()
	_build_links()
	_build_rifts()
	_build_walker()
	_build_camera()
	_build_hud()

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
	env.ambient_light_energy = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0

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
	sun.light_color  = Color(0.98, 0.94, 0.88)
	sun.light_energy = 1.7
	sun.rotation_degrees = Vector3(-46.0, 38.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 320.0
	add_child(sun)


func _build_city() -> void:
	# Everything the city has to leave room for: the hub, every rift (whether or
	# not it is unlocked yet — a building may not appear inside a rift that has
	# not opened yet either), and every route trail.
	var keep_clear: Array[Dictionary] = [{"pos": _data.hub_position, "radius": 16.0}]
	for id: String in _data.order:
		keep_clear.append({"pos": _data.position_of(id), "radius": 15.0})

	var paths: Array[PackedVector3Array] = []
	for edge: Dictionary in _data.edges():
		paths.append(_edge_points(String(edge["from"]), String(edge["to"])))

	var city := StoryCity.new()
	city.name = "City"
	add_child(city)
	city.build(_data.hub_position, _data.extent() + 78.0, keep_clear, paths)


## The hub is a plain civic square, not a rift — it is the one node that is
## always open and it is where Meeko starts.
## TODO(art): real hub landmark (Anne's building / the plaza) goes here.
func _build_hub_marker() -> void:
	var plaza := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius      = 12.0
	disc.bottom_radius   = 12.0
	disc.height          = 0.3
	disc.radial_segments = 24
	plaza.mesh = disc
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.48, 0.47, 0.48)
	m.roughness    = 0.95
	plaza.material_override = m
	plaza.position = _data.hub_position + Vector3(0.0, 0.15, 0.0)
	add_child(plaza)

	var pillar := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(2.2, 9.0, 2.2)
	pillar.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.58, 0.56, 0.55)
	pmat.roughness    = 0.9
	pillar.material_override = pmat
	# Off to one side of the plaza, NOT on the middle of it — Meeko starts on the
	# hub, and a monument on the exact same spot hides him behind it.
	pillar.position = _data.hub_position + Vector3(-6.5, 4.5, -6.0)
	add_child(pillar)


func _build_links() -> void:
	for edge: Dictionary in _data.edges():
		var from_id: String = String(edge["from"])
		var to_id: String = String(edge["to"])
		var link := StoryPathLink.new()
		link.name = "Link_%s_%s" % [from_id, to_id]
		add_child(link)
		link.build(from_id, to_id, _edge_points(from_id, to_id), _accent_for(to_id))
		_links[_link_key(from_id, to_id)] = link


func _build_rifts() -> void:
	var alternate: int = 0
	for id: String in _data.order:
		var entry: Dictionary = _data.nodes[id]
		var variant: String = String(entry.get("variant", "auto"))
		if variant == "auto":
			# Purely visual variety — no gameplay reads this. Alternating keeps
			# a cluster from being three of the same thing side by side.
			variant = StoryRift.VARIANT_GROUND if alternate % 2 == 0 else StoryRift.VARIANT_WALL
		alternate += 1

		var rift := StoryRift.new()
		rift.name = "Rift_%s" % id
		add_child(rift)
		rift.position = _data.position_of(id)
		rift.setup(id, _data.title_of(id), variant, _accent_for(id))
		# Wall rifts have a front; turn them toward whatever they connect back
		# to, so the gash always faces the route Meeko arrives on.
		rift.face_toward(_data.position_of(_data.parent_of(id)))
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

	if target == _data.hub_id:
		_detail_label.text = _data.hub_title
		_hint_label.text = "← →  SELECT A RIFT     ENTER / A  TRAVEL     ESC / B  BACK"
		return

	# CLOSED is a fact about the RIFT, not about where Meeko happens to be
	# standing. It used to be worked out inside the you-are-here branch only, so
	# every rift the player had already closed dropped its marker the moment they
	# selected a different one — the last one beaten looked like the only one.
	var closed_mark: String = "  ·  CLOSED" if target in _cleared else ""
	_detail_label.text = "%s%s" % [target_title, closed_mark]

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
	var newly_open: PackedStringArray = PackedStringArray()

	for id: String in _data.order:
		var rift: StoryRift = _rifts.get(id, null)
		if rift == null:
			continue
		var unlocked: bool = _data.is_unlocked(id, _cleared)
		if unlocked and not rift.is_revealed():
			newly_open.append(id)
		if unlocked != rift.is_revealed():
			rift.set_revealed(unlocked, animate and unlocked)
		# Closed rifts dim right down. Driven from the cleared list every refresh
		# rather than set once on the clear, so it is also correct for the rifts
		# already beaten when the map loads.
		rift.set_closed(id in _cleared)

	# A trail is drawn only when BOTH of its ends are on the map — otherwise it
	# would point at a rift the player is not supposed to know about yet.
	for key: String in _links.keys():
		var link: StoryPathLink = _links[key]
		var open: bool = _is_on_map(link.from_id) and _is_on_map(link.to_id)
		var reveal: bool = animate and open and not link.is_open() \
			and (link.to_id in newly_open or link.from_id in newly_open)
		if open != link.is_open():
			link.set_open(open, reveal)


func _is_on_map(id: String) -> bool:
	if id == _data.hub_id:
		return true
	return _data.is_unlocked(id, _cleared)


func _select_first_available() -> void:
	var ids: PackedStringArray = _data.unlocked_ids(_cleared)
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
	ids.append_array(_data.unlocked_ids(_cleared))
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
	var plan: Dictionary = _data.travel_plan(_data.route(_at_node, id))
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


# ── Graph helpers ────────────────────────────────────────────────────────────

## The full polyline for one edge, routed along the streets. Shared by the trail
## visuals, the walker's route and the city's keep-clear test, so all three agree
## on where a path actually runs.
func _edge_points(from_id: String, to_id: String) -> PackedVector3Array:
	return _data.edge_points(from_id, to_id)


static func _link_key(from_id: String, to_id: String) -> String:
	return "%s>%s" % [from_id, to_id]


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
