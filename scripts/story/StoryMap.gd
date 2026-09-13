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

## ── Entering a rift ──────────────────────────────────────────────────────────
## Confirming a level does not cut straight to it. The camera drops in on the
## rift, Meeko steps into it, the rift takes him, and only then does the scene
## change. About a second and a half — long enough to read as going somewhere,
## short enough that replaying a level is not sitting through a cutscene.
##
## The camera moves FIRST and alone. Meeko is a couple of metres of model seen
## from 124 m: until the camera has come down there is nobody visible to watch
## step into anything, and a rift surging while he is still a speck is a light
## show with no one in it.
##
## TODO(cutscene): this is the placeholder for the real one. The timings are the
## thing worth keeping — the shape of the beat is already what it should be.
const ENTRY_ZOOM_IN: float = 0.40
## The walk from the kerb into the mouth. This is the part the beat exists for,
## so it gets the time — roughly walking pace over StoryMapData.STAND_OFF.
const ENTRY_STEP: float = 0.80
const ENTRY_DRAW: float = 0.48
## A beat on the flare after he is gone, before the cut.
const ENTRY_HOLD: float = 0.16
## Where the camera ends up, relative to the rift. Close, because Meeko is small
## beside a rift and at anything looser he is a few pixels walking into a light
## — this is the one moment the map is allowed to be a shot rather than a map.
##
## And STEEPER than map framing, which the rest of the screen never is. At 124 m
## nothing can get between the camera and a rift; from twelve metres back a
## single house does, and half the rifts have one put behind them. The
## first pass kept the map's 59° sightline and spent half the beat looking at
## the back of somebody's roof. Up and over is what clears it.
const ENTRY_CAM_OFFSET := Vector3(0.0, 39.0, 11.5)
const ENTRY_CAM_RATE: float = 4.0
## Where the camera sits the rest of the time. Named because the entry beat now
## moves it and something has to bring it home.
const MAP_CAM_OFFSET := Vector3(0.0, CAM_HEIGHT, CAM_BACK)

## Coming back out. Shorter than going in: the player has already watched the
## going-in half of this, and is now waiting on a score.
const EXIT_DRAW: float = 0.40
const EXIT_STEP: float = 0.55
const EXIT_SETTLE: float = 0.30

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
## Set while the entry beat runs. It takes the camera off Meeko and onto the
## rift, and it locks input: the beat ends in a scene change, so there is
## nothing left to cancel back to.
var _entering: bool = false
var _entry_focus: Vector3 = Vector3.ZERO
## Camera offset from whatever it is looking at. Constant at map distance; the
## entry beat is the only thing that moves it.
var _cam_offset: Vector3 = MAP_CAM_OFFSET
## The cleared-level score card, while it is up. Blocks the map underneath it.
var _result_card: Control = null

var _title_label: Label = null
var _progress_label: Label = null
var _plate: PlatePanel = null
var _badge: PanelContainer = null
var _badge_label: Label = null
var _name_label: Label = null
var _chip: PanelContainer = null
var _chip_label: Label = null
var _song_label: Label = null
var _keys_row: Control = null
var _act_prompt: Control = null
var _act_label: Label = null
var _select_prompt: Control = null
var _s: float = 1.0


func _ready() -> void:
	_s = UiStyle.scale_for(get_viewport().get_visible_rect().size)

	_data = StoryMapData.load_from(MAP_JSON)

	# Coming back from a level. Read the story context BEFORE clearing it: the
	# map is not a level, so nothing from here on may look like a story run.
	var just_cleared: String = Run.story_just_cleared
	# Story Mode has no results screen inside the level, so the run's numbers
	# come back with it and are reported here. Read before end_story_context().
	var result: Dictionary = Run.story_result.duplicate()
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

	_load_time_of_day()
	_build_environment()
	_build_world()
	_build_rifts()
	_build_walker()
	_build_camera()
	_build_hud()

	# Shelters need the world in the tree (for global transforms) and the walker
	# placed, so this is the first point both are true.
	_collect_shelters(self)
	_collect_lit_glass(self)
	_apply_time(_time)

	# No animation on this pass: the map opens showing the city the player has
	# already opened up, it does not replay every past reveal.
	_refresh_visibility(false)
	if start_node != _data.hub_id:
		_set_selected(start_node)
	else:
		_select_first_available()
	_update_hud()

	if _data.load_error != "":
		_name_label.text = _data.load_error
		return

	if just_cleared != "":
		_play_return_reveal(just_cleared, cleared_now, result)


## The reveal after a level is beaten, played on arriving back at the map.
##
## TODO(cutscene): the real beat is a cutscene — camera move, the rift closing,
## the next one tearing open. The delay here stands in for its timing so the
## surrounding flow (path light-up, re-selection) is already correct.
func _play_return_reveal(just_cleared: String, cleared_now: PackedStringArray,
		result: Dictionary) -> void:
	_badge.visible = false
	_act_prompt.visible = false
	_keys_row.visible = false
	_chip.visible = true
	_chip_label.text = "CLOSED"
	_tint_chip(_chip, UiStyle.CYAN)
	_name_label.text = _data.title_of(just_cleared)
	_song_label.text = "RIFT CLOSED"

	await _play_exit(just_cleared)
	if not is_inside_tree():
		return

	_cleared = cleared_now
	_refresh_visibility(true)
	_focus_newly_revealed()
	_keys_row.visible = true
	if not result.is_empty():
		_show_result(just_cleared, result)


## Coming back out of the rift — the entry beat run backwards.
##
## The map OPENS on the close shot rather than moving into it: the level was
## left on a close shot of a rift, so arriving on one is the same camera
## continuing, and cutting to map distance first would throw that away.
func _play_exit(id: String) -> void:
	var mouth: Vector3 = _data.position_of(id)
	var stand: Vector3 = _data.stand_point_of(id)

	_entering = true
	_entry_focus = stand.lerp(mouth, 0.62) + Vector3(0.0, 1.4, 0.0)
	# Already there, not lerping toward it — this is a continuation, not a move.
	_cam_focus  = _entry_focus
	_cam_offset = ENTRY_CAM_OFFSET

	await _walker.exit_rift(mouth, stand, EXIT_DRAW, EXIT_STEP)
	if not is_inside_tree():
		return
	# Hand the camera back; _process lifts it home from wherever it is.
	_entering = false
	await get_tree().create_timer(EXIT_SETTLE).timeout


# ── World construction ───────────────────────────────────────────────────────

## Authored times of day.
##
## One row per look, holding everything the environment and the two lights need.
## The point of the shape is what comes next: adding dawn or full night is a row
## rather than a rewrite, and a day/night CYCLE is lerping between rows off one
## float instead of re-deriving a look every frame.
##
## What is NOT in here is deliberate. SSAO, the tonemap curve, the glow blend
## mode and blur levels, and the shadow splits are the same at every hour — they
## are properties of this camera and this city, not of the light, so they are set
## once in _build_environment() and never touched again.
## How long a full day takes, in seconds.
##
## Longer than it was, and the save is why. The clock keeps running while the
## player is off in a level, so the cycle length decides what a level COSTS in
## map time: at the old five minutes a single three-minute song moved the city
## most of the way round the clock, so you left at dusk and came back at dawn,
## which reads as random rather than as time passing. At fifteen, the same song
## moves it about a fifth of a day — noticeable, and still recognisably the
## afternoon you left.
##
## Ctrl+Alt+T is there for when you want to see the hours quickly.
const DAY_LENGTH_S: float = 900.0

const TIME_PRESETS: Array[Dictionary] = [
	{
		# DAWN. Cold and blue, the sun barely up and doing almost no work — the
		# fill is carrying the frame, which is why this is the one hour where the
		# two lights are nearly equal.
		"name": "DAWN",
		"sky_top": Color(0.130, 0.175, 0.360),
		"sky_horizon": Color(0.560, 0.420, 0.470),
		"ground_bottom": Color(0.090, 0.085, 0.115),
		"ground_horizon": Color(0.260, 0.230, 0.260),
		"sun_disc": 16.0,
		"ambient": 0.50,
		"exposure": 1.02,
		"sun_color": Color(1.00, 0.78, 0.62),
		"sun_energy": 1.05,
		"sun_pitch": -13.0,
		"fill_color": Color(0.470, 0.560, 0.930),
		"fill_energy": 0.70,
		"fog_color": Color(0.380, 0.360, 0.480),
		"fog_density": 0.0016,
		"glow_threshold": 1.00,
		"glow_scale": 2.20,
		"glow_intensity": 1.12,
		"lit": 0.55,
	},
	{
		# DAY. Not the old overcast noon.
		#
		# Three things made that flat, and none of them was the sky. Ambient sat
		# at 1.05, which fills every shadow until a lit face and a shaded one are
		# nearly the same value — that IS flatness. The sun was near-white
		# against a grey-blue fill, so there was no warm/cool split to separate
		# the faces. And it hung at 38 degrees, which is short shadows from a
		# camera that reads the city almost entirely through them.
		#
		# So: ambient halved and the energy it lost handed to the sun, a real
		# warm/cool split, and the sun dropped to a late-morning rake.
		"name": "DAY",
		"sky_top": Color(0.255, 0.400, 0.660),
		"sky_horizon": Color(0.640, 0.715, 0.790),
		"ground_bottom": Color(0.230, 0.225, 0.235),
		"ground_horizon": Color(0.455, 0.450, 0.455),
		"sun_disc": 12.0,
		"ambient": 0.55,
		"exposure": 1.00,
		"sun_color": Color(1.00, 0.925, 0.795),
		"sun_energy": 2.60,
		"sun_pitch": -27.0,
		"fill_color": Color(0.480, 0.620, 0.950),
		"fill_energy": 0.55,
		# Aerial perspective. The camera never sees sky, so haze is the ONLY way
		# the sky reaches the frame at all — but the dose has to respect that
		# Godot's fog is per-metre exponential and this camera looks across
		# roughly 250 m of city. The first pass at 0.0042 works out to about 65%
		# fog at the far edge and drowned the whole map in mist; this is nearer
		# 20%, which reads as distance rather than weather.
		"fog_color": Color(0.585, 0.660, 0.755),
		"fog_density": 0.0009,
		# Still high enough that daylit render does not bloom into mush — a lit
		# wall at this exposure sits just under it — but low enough that a rift
		# finally gets a halo in daylight instead of only after dark.
		"glow_threshold": 1.15,
		"glow_scale": 2.00,
		"glow_intensity": 1.10,
		# Nothing. A window with a light on behind it at noon reads as a mistake,
		# and the pale albedo left behind reads as a blind, which is correct.
		"lit": 0.00,
	},
	{
		# DUSK. The levels are neon against near-black, and a matte daylight map
		# is not a less-polished version of that — it is a different lighting
		# model, and the harder one to sell, because nothing in it is allowed to
		# glow. This hands the frame to the two things that already emit: the
		# rifts and the lit windows.
		"name": "DUSK",
		"sky_top": Color(0.055, 0.060, 0.135),
		"sky_horizon": Color(0.300, 0.175, 0.265),
		"ground_bottom": Color(0.030, 0.026, 0.050),
		"ground_horizon": Color(0.115, 0.090, 0.130),
		"sun_disc": 18.0,
		"ambient": 0.55,
		"exposure": 1.05,
		"sun_color": Color(1.00, 0.62, 0.38),
		"sun_energy": 1.55,
		"sun_pitch": -19.0,
		"fill_color": Color(0.420, 0.520, 0.920),
		"fill_energy": 0.62,
		"fog_color": Color(0.175, 0.140, 0.245),
		"fog_density": 0.0022,
		# Low enough that the CITY can reach it, not just the rifts. It used to
		# sit at 1.25 specifically to keep the buildings out — right when they
		# were grey boxes and the rifts had to win, wrong once the windows lit up
		# and the sky went dark enough for them to matter.
		"glow_threshold": 0.85,
		"glow_scale": 2.50,
		"glow_intensity": 1.15,
		"lit": 1.10,
	},
	{
		# NIGHT. The one hour with no sun at all: the "sun" here is a cold moon
		# doing barely more than separating the roofs from the streets, and the
		# city is lit by its own windows and the rifts.
		#
		# It is still not black. This is a screen you have to READ — a rift has
		# to be findable and a street has to be followable — so ambient and the
		# fill are held at a floor that keeps the massing legible. The contrast
		# comes from what is EMITTING, not from crushing everything else.
		"name": "NIGHT",
		"sky_top": Color(0.020, 0.022, 0.055),
		"sky_horizon": Color(0.075, 0.055, 0.120),
		"ground_bottom": Color(0.012, 0.010, 0.024),
		"ground_horizon": Color(0.045, 0.036, 0.070),
		"sun_disc": 10.0,
		"ambient": 0.34,
		"exposure": 1.08,
		"sun_color": Color(0.62, 0.72, 1.00),
		"sun_energy": 0.42,
		"sun_pitch": -34.0,
		"fill_color": Color(0.300, 0.360, 0.780),
		"fill_energy": 0.34,
		"fog_color": Color(0.060, 0.050, 0.110),
		"fog_density": 0.0026,
		"glow_threshold": 0.72,
		"glow_scale": 2.60,
		"glow_intensity": 1.22,
		"lit": 1.75,
	},
]

var _env: Environment = null
var _sky_mat: ProceduralSkyMaterial = null
var _sun: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
## Position in TIME_PRESETS, as a FLOAT: 1.5 is halfway between DAY and DUSK.
## The presets are a ring, so this wraps. Loaded from the save in _ready().
var _time: float = 1.0
## Dev hold. -1 runs the clock; 0+ pins it to that keyframe.
var _time_hold: int = -1
## The one shared lit-window material inside the baked city, found by name. The
## share of windows that CAN light is baked; how brightly they burn is not.
var _lit_mats: Array[StandardMaterial3D] = []
## The streetlights' heads and the pools of light under them, found the same
## way and driven off the same `lit` curve as the windows: on from dusk, off by
## noon.
var _lamp_glow_mats: Array[StandardMaterial3D] = []
var _lamp_pool_mats: Array[StandardMaterial3D] = []
## The pools' nodes, hidden outright while the lamps are off. Additive black
## adds nothing, but it is still two hundred discs drawn over the whole street
## network for no pixel of difference.
var _lamp_pool_nodes: Array[GeometryInstance3D] = []
## How hard a lamp head burns against a window at the same hour — a lamp is a
## bare bulb, a window is a lit room behind glass.
const LAMP_GLOW_GAIN: float = 1.7
## What a pool of lamplight adds to the ground at full night. It is drawn
## additively, so this is light ON TOP of the scene, not a colour painted over it.
const LAMP_POOL_COL: Color = Color(0.50, 0.38, 0.23)
## `lit` at full night, which is where the pools reach LAMP_POOL_COL.
const LIT_FULL: float = 1.75


func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY

	_sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.sky = sky

	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES

	# Contact shading. From map height the city is read almost entirely through
	# where one box meets another, and without occlusion in the gaps a block of
	# buildings flattens into a single grey mass.
	_env.ssao_enabled = true
	_env.ssao_radius = 3.0
	_env.ssao_intensity = 1.6
	_env.ssao_power = 1.4
	_env.ssao_detail = 0.4

	_env.glow_enabled    = true
	_env.glow_normalized = true
	_env.glow_strength   = 1.05
	_env.glow_bloom      = 0.04
	# SCREEN: blooms bright sources like additive but asymptotes at white, so a
	# cluster of lit windows cannot stack past it into a blown-out patch.
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	# The halo itself. Godot enables the tight levels by default, which makes a
	# source brighter without making it glow; the wide ones are what bleed.
	_env.set_glow_level(3, 1.0)
	_env.set_glow_level(4, 1.0)
	_env.set_glow_level(5, 0.8)

	_env.fog_enabled = true
	_env.fog_sky_affect = 0.35

	var world_env := WorldEnvironment.new()
	world_env.environment = _env
	add_child(world_env)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.shadow_enabled = true
	_sun.shadow_bias = 0.03
	_sun.shadow_normal_bias = 1.2
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = 420.0
	_sun.directional_shadow_split_1 = 0.06
	_sun.directional_shadow_split_2 = 0.16
	_sun.directional_shadow_split_3 = 0.42
	add_child(_sun)

	# A cool fill from the opposite side, unshadowed. Sun-plus-ambient alone left
	# every north face the same flat value; this separates the faces so massing
	# reads without lifting the whole city. It is standing in for the SKY, which
	# is why every preset makes it the cool half of a warm/cool pair — that split
	# is most of what stops a box city looking like plastic.
	_fill = DirectionalLight3D.new()
	_fill.name = "SkyFill"
	_fill.shadow_enabled = false
	_fill.rotation_degrees = Vector3(-24.0, -142.0, 0.0)
	add_child(_fill)

	_apply_time(_time)


## Picks up the clock where it was left, plus however long the player has been
## away. A first-ever visit opens at midday.
func _load_time_of_day() -> void:
	var saved: Dictionary = Save.get_story_time()
	var t: float = float(saved.get("time", -1.0))
	if t < 0.0:
		return   # nothing saved yet; the declared default (midday) stands
	var span: float = float(TIME_PRESETS.size())
	_time = fposmod(t + float(saved.get("elapsed", 0.0)) * span / DAY_LENGTH_S, span)


## Writes the clock. Called on every way OUT of the map rather than on a timer:
## the exits are few and known, and a file write per frame to keep a sky in sync
## would be a poor trade.
func _save_time_of_day() -> void:
	Save.set_story_time(_time)


## Puts the clock on screen, interpolating between the two keyframes it falls
## between. Everything an hour of the day owns lives here; everything it does
## not is set once in _build_environment().
##
## The sun's BEARING is deliberately not interpolated — only its pitch, colour
## and energy. A sun that swings round the compass would sweep every shadow in
## the city across the streets, and this is a screen people are trying to read a
## layout off. Fixing the bearing means dawn and dusk differ by colour rather
## than by direction, which is a small lie nobody notices and a lot of stability
## bought for it.
func _apply_time(t: float) -> void:
	var n: int = TIME_PRESETS.size()
	var f: float = fposmod(t, float(n))
	var i: int = int(f)
	var a: Dictionary = TIME_PRESETS[i]
	var b: Dictionary = TIME_PRESETS[(i + 1) % n]
	var k: float = f - float(i)

	_sky_mat.sky_top_color        = (a["sky_top"] as Color).lerp(b["sky_top"], k)
	_sky_mat.sky_horizon_color    = (a["sky_horizon"] as Color).lerp(b["sky_horizon"], k)
	_sky_mat.ground_bottom_color  = (a["ground_bottom"] as Color).lerp(b["ground_bottom"], k)
	_sky_mat.ground_horizon_color = (a["ground_horizon"] as Color).lerp(b["ground_horizon"], k)
	_sky_mat.sun_angle_max        = lerpf(a["sun_disc"], b["sun_disc"], k)

	_env.ambient_light_energy = lerpf(a["ambient"], b["ambient"], k)
	_env.tonemap_exposure     = lerpf(a["exposure"], b["exposure"], k)
	_env.glow_hdr_threshold   = lerpf(a["glow_threshold"], b["glow_threshold"], k)
	_env.glow_hdr_scale       = lerpf(a["glow_scale"], b["glow_scale"], k)
	_env.glow_intensity       = lerpf(a["glow_intensity"], b["glow_intensity"], k)
	_env.fog_light_color      = (a["fog_color"] as Color).lerp(b["fog_color"], k)
	_env.fog_density          = lerpf(a["fog_density"], b["fog_density"], k)

	_sun.light_color  = (a["sun_color"] as Color).lerp(b["sun_color"], k)
	_sun.light_energy = lerpf(a["sun_energy"], b["sun_energy"], k)
	_sun.rotation_degrees = Vector3(lerpf(a["sun_pitch"], b["sun_pitch"], k), 34.0, 0.0)

	_fill.light_color  = (a["fill_color"] as Color).lerp(b["fill_color"], k)
	_fill.light_energy = lerpf(a["fill_energy"], b["fill_energy"], k)

	var lit: float = lerpf(a["lit"], b["lit"], k)
	for m: StandardMaterial3D in _lit_mats:
		m.emission_energy_multiplier = lit
	for m: StandardMaterial3D in _lamp_glow_mats:
		m.emission_energy_multiplier = lit * LAMP_GLOW_GAIN
	var pool: float = clampf(lit / LIT_FULL, 0.0, 1.0)
	for m: StandardMaterial3D in _lamp_pool_mats:
		m.albedo_color = Color(LAMP_POOL_COL.r * pool, LAMP_POOL_COL.g * pool,
			LAMP_POOL_COL.b * pool)
	var pools_on: bool = pool > 0.002
	for pool_node: GeometryInstance3D in _lamp_pool_nodes:
		if pool_node.visible != pools_on:
			pool_node.visible = pools_on


## The name of the hour, for the dev readout.
func _time_name() -> String:
	var n: int = TIME_PRESETS.size()
	var f: float = fposmod(_time, float(n))
	var i: int = int(f)
	var k: float = f - float(i)
	if k < 0.06:
		return String(TIME_PRESETS[i]["name"])
	return "%s -> %s  %d%%" % [TIME_PRESETS[i]["name"],
		TIME_PRESETS[(i + 1) % n]["name"], int(k * 100.0)]


## Finds the shared lit-window material inside the baked city, and the
## streetlights' glow and pool materials.
##
## By resource_name, set in StoryCity. Nothing else marks them out: once the
## city is packed they are StandardMaterial3Ds among hundreds, and walking for
## "the emissive one" would also catch anything emissive added later. The lamps
## are MultiMeshes, so their mesh hangs off the multimesh, not the node.
func _collect_lit_glass(root: Node) -> void:
	for child in root.get_children():
		_collect_lit_glass(child)
		var mesh: Mesh = null
		if child is MeshInstance3D:
			mesh = (child as MeshInstance3D).mesh
		elif child is MultiMeshInstance3D and (child as MultiMeshInstance3D).multimesh != null:
			mesh = (child as MultiMeshInstance3D).multimesh.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as StandardMaterial3D
			if m == null:
				continue
			match m.resource_name:
				"LitGlass":
					if not _lit_mats.has(m):
						_lit_mats.append(m)
				"LampGlow":
					if not _lamp_glow_mats.has(m):
						_lamp_glow_mats.append(m)
				"LampPool":
					if not _lamp_pool_mats.has(m):
						_lamp_pool_mats.append(m)
					if not _lamp_pool_nodes.has(child):
						_lamp_pool_nodes.append(child as GeometryInstance3D)


## Puts the city on screen.
##
## NOTHING here may add city geometry on top of a baked scene. The scene IS the
## city — if a building is not in CalderCity.tscn it must not be in the game.
## Rifts used to bring their own building with them at runtime, which meant
## buildings appeared in play that could not be found or deleted in the editor.
## Everything a rift stands against is part of the baked city, and is then just
## another building to move or remove like the rest of them.
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
	#
	# No buildings are put behind the rifts here. There used to be, for the
	# rifts that wore the wall look — but there is one rift now, and whether it
	# stands against a wall or out in the open is a placement decision, made by
	# dragging its anchor in this scene. A rule in code that puts a house behind
	# every other one takes that decision away.
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
		_name_label.text = "BAKE FAILED — SEE OUTPUT"
		return

	print("[StoryMap] baked the city to %s — open it in the editor to change it." % BAKED_CITY)
	_badge.visible = false
	_chip.visible = false
	_name_label.text = "CITY BAKED"
	_song_label.text = "SAVED TO %s  ·  RELOADING" % BAKED_CITY
	await get_tree().create_timer(0.9).timeout
	if is_inside_tree():
		get_tree().reload_current_scene()


## PackedScene only keeps nodes that belong to the scene being packed, so every
## descendant has to be claimed by the root before it is worth saving.
func _claim(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_claim(child, root)


func _build_rifts() -> void:
	for id: String in _data.order:
		var rift := StoryRift.new()
		rift.name = "Rift_%s" % id
		add_child(rift)
		rift.position = _data.position_of(id)
		rift.setup(id, _data.title_of(id), _accent_for(id))
		# A rift opens toward the road it fronts onto: its cracks spread into the
		# carriageway rather than back through whatever is behind it.
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
	var here: Vector3 = _data.stand_point_of(_at_node)
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
	_camera.global_position = focus + _cam_offset
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

	# -- Corner: where you are, and how far through ---------------------------
	var corner := VBoxContainer.new()
	corner.position = Vector2(56 * _s, 40 * _s)
	corner.add_theme_constant_override("separation", int(7 * _s))
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(corner)

	# The map data holds the city's name as written ("Calder City"); the caps
	# are the screen's, not the data's - the same split SongSelect uses.
	_title_label = UiStyle.label(_data.map_title.to_upper(), UiStyle.caption(7.0),
		int(22 * _s), Color.WHITE, int(4 * _s))
	_title_label.self_modulate = UiStyle.signature_color(0.1)
	corner.add_child(_title_label)

	# Progress belongs up here rather than in the plate: it is a fact about the
	# save, and it must not appear to change as the cursor moves between rifts.
	# Bright with a heavy outline, not TEXT_DIM: this line sits on the CITY, not
	# on a plate, and the city is pale — the palette's dim lavender is legible on
	# ink and invisible on a sunlit pavement.
	_progress_label = UiStyle.label("", UiStyle.display(600, 2.4), int(14 * _s),
		Color.WHITE, int(4 * _s))
	_progress_label.self_modulate = Color(0.94, 0.91, 1.00)
	corner.add_child(_progress_label)

	# -- Plate: everything about the rift under the cursor --------------------
	# PlatePanel has no size of its own - it takes it from `content` - so it has
	# to sit in containers rather than be positioned by hand.
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_END
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(column)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	_plate = PlatePanel.create(int(20 * _s), UiStyle.VIOLET, 18.0 * _s)
	_plate.custom_minimum_size = Vector2(720 * _s, 0)
	_plate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_plate)

	var bottom_pad := Control.new()
	bottom_pad.custom_minimum_size = Vector2(0, 46 * _s)
	bottom_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(bottom_pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(9 * _s))
	_plate.content.add_child(col)

	# Line 1: level badge, rift name, state. All three used to be one string
	# with the controls glued on the end of it. The level number is the thing
	# the player actually looks for, so it gets a badge of its own instead of
	# sitting halfway along a run of button prompts.
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", int(13 * _s))
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)

	_badge = _chip_box(UiStyle.VIOLET)
	_badge_label = UiStyle.label("", UiStyle.display(700, 2.0), int(15 * _s), Color.WHITE)
	_badge.add_child(_badge_label)
	head.add_child(_badge)

	_name_label = UiStyle.label("", UiStyle.caption(3.5), int(21 * _s), Color.WHITE)
	_name_label.self_modulate = Color(1.00, 0.94, 1.00)
	_name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_name_label)

	_chip = _chip_box(UiStyle.TEXT_DIM)
	_chip_label = UiStyle.label("", UiStyle.display(700, 2.0), int(12 * _s), Color.WHITE)
	_chip.add_child(_chip_label)
	head.add_child(_chip)

	# Line 2: which chart is behind this rift.
	_song_label = UiStyle.label("", UiStyle.body(1.6), int(15 * _s), Color.WHITE)
	_song_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_song_label.self_modulate = UiStyle.TEXT_DIM
	col.add_child(_song_label)

	# Line 3: the controls, as caps rather than as more prose.
	var keys := HBoxContainer.new()
	_keys_row = keys
	keys.alignment = BoxContainer.ALIGNMENT_CENTER
	keys.add_theme_constant_override("separation", int(24 * _s))
	keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(keys)

	_select_prompt = _prompt(String.chr(0x2190) + " " + String.chr(0x2192), "SELECT")
	keys.add_child(_select_prompt)
	_act_prompt = _prompt("ENTER / A", "TRAVEL")
	# The one prompt whose wording changes with the selection. _prompt puts the
	# action word last.
	_act_label = _act_prompt.get_child(_act_prompt.get_child_count() - 1) as Label
	keys.add_child(_act_prompt)
	keys.add_child(_prompt("ESC / B", "BACK"))


## A small rounded chip with a Label inside it - the level badge and the state
## marker. A PanelContainer rather than a styled Label so the fill hugs whatever
## text it is given.
func _chip_box(col: Color) -> PanelContainer:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tint_chip(box, col)
	return box


func _tint_chip(box: PanelContainer, col: Color) -> void:
	var sb: StyleBoxFlat = UiStyle.pill(Color(col.r, col.g, col.b, 0.20), 6.0 * _s,
		Color(col.r, col.g, col.b, 0.85))
	sb.content_margin_left   = 10 * _s
	sb.content_margin_right  = 10 * _s
	sb.content_margin_top    = 4 * _s
	sb.content_margin_bottom = 4 * _s
	box.add_theme_stylebox_override("panel", sb)


## One control prompt: the button in a cap, then what it does. The cap is what
## separates "a key you press" from "a word about the rift" - the old hint line
## ran both together in the same weight and the same colour.
func _prompt(cap_text: String, what: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(7 * _s))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var cap := PanelContainer.new()
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb: StyleBoxFlat = UiStyle.pill(Color(0.62, 0.55, 0.82, 0.18), 5.0 * _s,
		Color(0.70, 0.64, 0.88, 0.55))
	sb.content_margin_left   = 8 * _s
	sb.content_margin_right  = 8 * _s
	sb.content_margin_top    = 3 * _s
	sb.content_margin_bottom = 3 * _s
	cap.add_theme_stylebox_override("panel", sb)
	cap.add_child(UiStyle.label(cap_text, UiStyle.display(700, 1.5), int(11 * _s),
		Color(0.93, 0.89, 1.00)))
	h.add_child(cap)

	var what_label := UiStyle.label(what, UiStyle.display(600, 2.6), int(11 * _s),
		Color.WHITE)
	what_label.self_modulate = Color(0.64, 0.59, 0.80)
	what_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(what_label)
	return h


func _update_hud() -> void:
	if _name_label == null:
		return

	var target: String = _selected
	var accent: Color = UiStyle.VIOLET if target == _data.hub_id else _accent_for(target)
	_plate.set_accent(accent)
	_tint_chip(_badge, accent)

	# Reveal-all is loud on purpose: a map showing rifts the save has not earned
	# looks like broken progress unless it says why.
	var dev: String = "     DEV: ALL REVEALED" if _reveal_all else ""
	_progress_label.text = "%d / %d RIFTS CLOSED%s" % [
		_cleared.size(), _data.order.size(), dev]

	# One rift on the map means there is nothing to cycle between.
	_select_prompt.visible = _visible_ids().size() > 1

	if _walker != null and _walker.is_walking():
		_badge.visible = false
		_chip.visible = false
		_act_prompt.visible = false
		_name_label.text = "TRAVELLING TO  %s" % _data.title_of(target)
		_song_label.text = "MEEKO IS ON HIS WAY"
		return

	var level: int = _data.level_of(target)
	var song: String = _data.song_key_of(target)

	_badge.visible = level > 0
	_badge_label.text = "LV %02d" % level
	_name_label.text = _data.title_of(target)

	# CLOSED is a fact about the RIFT, not about where Meeko happens to be
	# standing. It used to be worked out inside the you-are-here branch only, so
	# every rift the player had already closed dropped its marker the moment
	# they selected a different one - the last one beaten looked like the only
	# one.
	var state: String = ""
	var state_col: Color = UiStyle.TEXT_DIM
	if target in _cleared:
		state = "CLOSED"
		state_col = UiStyle.CYAN
	elif target == _at_node:
		state = "YOU ARE HERE"
		state_col = accent
	_chip.visible = state != ""
	_chip_label.text = state
	_tint_chip(_chip, state_col)

	# The chart line says which beatmap claimed this level number, so a
	# mis-numbered chart is visible on the screen that depends on it rather than
	# only showing up as the wrong song starting.
	if target == _data.hub_id:
		_song_label.text = "WHERE MEEKO STARTS"
	elif song != "":
		_song_label.text = song.replace("_", " ").to_upper()
	elif level > 0:
		# SKIPPED, not PENDING: an empty rift does not hold the run up, so the
		# player should read it as scenery rather than as a wall.
		_song_label.text = "NO CHART YET  " + String.chr(0xB7) + "  SKIPPED"
	else:
		_song_label.text = ""

	var act: String = "TRAVEL"
	if target == _at_node:
		act = "" if song == "" else ("RUN AGAIN" if target in _cleared else "CLOSE RIFT")
	_act_prompt.visible = act != ""
	_act_label.text = act


# ── Visibility / unlock state ────────────────────────────────────────────────

# -- The cleared-level score card ---------------------------------------------

## Story Mode's results screen, on the map instead of in the level.
##
## The level's own card carries a PLAY AGAIN button, and in Story Mode that
## would restart the level on the seed already sitting in Run. A story level is
## meant to reshape on every attempt (see the SETTLED note in _enter_level), so
## the run has to go back out through the map, which is the thing that reseeds
## it. Taking the card out of the level and putting it here is what makes that
## the only door.
##
## Every number here was worked out in the level by _finalise_score() and came
## back on Run.story_result. The perfect bonus and the high-score write have
## already happened by the time this draws — this only reports.
func _show_result(id: String, result: Dictionary) -> void:
	var grade_col: Color = result.get("grade_color", UiStyle.VIOLET) as Color

	var layer := CanvasLayer.new()
	layer.name = "ResultCard"
	layer.layer = 2
	add_child(layer)

	_result_card = Control.new()
	_result_card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_card.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(_result_card)

	var veil := ColorRect.new()
	veil.color = Color(0.015, 0.008, 0.045, 0.82)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_card.add_child(veil)

	# The plate takes the grade's colour, so an S run and an F run do not look
	# alike before a single number has been read.
	var card := PlatePanel.create(int(34 * _s), grade_col, 30.0 * _s)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(720 * _s, 0)
	_result_card.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(3 * _s))
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.content.add_child(col)

	col.add_child(_result_line("RIFT CLOSED  \u00b7  %s" % _data.title_of(id),
		UiStyle.caption(5.0), 11, Color(0.66, 0.60, 0.86, 0.90)))
	col.add_child(_result_line(String(result.get("grade", "?")),
		UiStyle.display(800), 74, grade_col))

	if bool(result.get("is_perfect", false)):
		col.add_child(_result_line("\u2726  PERFECT  \u00d71.5  \u2726",
			UiStyle.caption(6.0), 15, Color(0.40, 1.00, 0.60)))

	col.add_child(_result_line("SCORE", UiStyle.caption(5.0), 11,
		Color(0.65, 0.58, 0.85, 0.85)))
	col.add_child(_result_line(UiStyle.group_digits(int(result.get("score", 0))),
		UiStyle.display(800), 54, Color.WHITE))

	if bool(result.get("is_new_high", false)):
		col.add_child(_result_line("\u2605  NEW HIGH SCORE  \u2605",
			UiStyle.caption(5.0), 14, UiStyle.PINK))
	else:
		col.add_child(_result_line(
			"BEST  %s" % UiStyle.group_digits(int(result.get("best", 0))),
			UiStyle.caption(3.0), 11, Color(0.58, 0.52, 0.75, 0.85)))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(50 * _s))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)

	var missed: int = int(result.get("missed", 0))
	var stats: Array = [
		["BEST COMBO", "\u00d7%d" % int(result.get("max_combo", 0)), UiStyle.CYAN],
		["HIT", str(int(result.get("hit", 0))), Color(0.40, 1.00, 0.55)],
		["MISSED", str(missed),
			UiStyle.DANGER if missed > 0 else Color(0.50, 0.46, 0.68)],
		["ACCURACY", "%.1f%%" % (float(result.get("accuracy", 0.0)) * 100.0),
			Color(0.86, 0.80, 1.00)],
	]
	for st: Array in stats:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(_result_line(String(st[1]), UiStyle.display(800), 30, st[2] as Color))
		cell.add_child(_result_line(String(st[0]), UiStyle.caption(3.0), 10,
			Color(0.58, 0.52, 0.75, 0.85)))
		row.add_child(cell)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 16 * _s)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(pad)

	var keys := HBoxContainer.new()
	keys.alignment = BoxContainer.ALIGNMENT_CENTER
	keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(keys)
	keys.add_child(_prompt("ENTER / A", "CONTINUE"))

	_result_card.modulate.a = 0.0
	create_tween().tween_property(_result_card, "modulate:a", 1.0, 0.35)


func _result_line(text: String, font: Font, size: int, col: Color) -> Label:
	var l: Label = UiStyle.label(text, font, int(float(size) * _s), Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.self_modulate = col
	return l


func _dismiss_result() -> void:
	if _result_card == null:
		return
	var layer: Node = _result_card.get_parent()
	_result_card = null
	if layer != null:
		layer.queue_free()
	_update_hud()


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
	if _entering or not _is_on_map(id):
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
	if _entering or _walker.is_walking():
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
		_name_label.text = _data.title_of(id)
		_song_label.text = "NOTHING CLAIMS LEVEL %02d YET — CHART IT AND THIS RIFT OPENS" % level
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
	# The level builds its own rifts at the start and end of the song, and they
	# are the rift he just stepped into — so they take its colour with them.
	Run.story_accent        = _accent_for(id)
	Run.run_seed            = 0
	Run.song_lives          = GameConfig.lives_per_song
	Save.set_story_position(id)

	_badge.visible = true
	_badge_label.text = "LV %02d" % level
	_chip.visible = false
	_keys_row.visible = false
	_name_label.text = "ENTERING  %s" % _data.title_of(id)
	_song_label.text = song_key.replace("_", " ").to_upper()
	print("[StoryMap] level %d (%s) -> %s" % [level, id, song_key])
	# The clock has to be banked before the scene goes, and it keeps running
	# while the level is played — see Save.get_story_time().
	_save_time_of_day()

	await _play_entry(id)
	if not is_inside_tree():
		return

	var err: int = get_tree().change_scene_to_file(LEVEL_SCENE)
	if err != OK:
		# Put the map back rather than leaving it mid-beat: the entry state locks
		# input and Meeko is scaled down to nothing, so a failed load would
		# otherwise strand the player on a frozen screen with no character on it.
		Run.end_story_context()
		_entering = false
		_walker.snap_to(_data.stand_point_of(id), _data.facing_of(id))
		_keys_row.visible = true
		_name_label.text = "FAILED TO LOAD %s (code %d)" % [LEVEL_SCENE, err]
		push_error("[StoryMap] change_scene_to_file failed: code=%d path=%s" % [err, LEVEL_SCENE])
		_update_hud()


## Meeko stepping into the rift, with the camera coming down on it — the beat
## between confirming a level and the level actually starting.
##
## The three parts run together on purpose: the camera is driven from _process
## (see _entering), the rift runs its own tween, and only the walker is awaited,
## because the walker is the one that decides when he is gone.
func _play_entry(id: String) -> void:
	var rift: StoryRift = _rifts.get(id, null)

	_entering = true

	# He waits at the kerb of the rift (StoryMapData.STAND_OFF), so the last
	# stride is a real walk of a few metres into the mouth — which is the part
	# the player is here to watch.
	var mouth: Vector3 = _data.position_of(id)
	var look: Vector3 = mouth - _walker.global_position
	look.y = 0.0

	# Frame the walk, not just its destination: between where he is standing and
	# where he is going, so both ends are on screen, but weighted toward the
	# rift — it is the taller thing and the one that has to stay in shot once he
	# is gone. Lifted off the pavement because the tear is what matters and the
	# tear is up.
	_entry_focus = _walker.global_position.lerp(mouth, 0.62) + Vector3(0.0, 1.4, 0.0)

	# Camera alone first — see the note on ENTRY_ZOOM_IN.
	await get_tree().create_timer(ENTRY_ZOOM_IN).timeout
	if not is_inside_tree():
		return

	if rift != null:
		rift.open_for_entry(ENTRY_STEP, ENTRY_DRAW + ENTRY_HOLD)

	await _walker.enter_rift(mouth, look, ENTRY_STEP, ENTRY_DRAW)
	if not is_inside_tree():
		return
	await get_tree().create_timer(ENTRY_HOLD).timeout


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
	# The entry beat ends in a scene change, so there is nothing to cancel back
	# to and nothing else worth answering while it plays.
	if _entering:
		return
	# The score card owns the screen until it is dismissed — any of the three
	# ways a player would try, because none of them should do anything else.
	if _result_card != null:
		var clicked: bool = event is InputEventMouseButton \
			and (event as InputEventMouseButton).pressed
		if clicked or event.is_action_pressed("ui_accept") \
				or event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			_dismiss_result()
		return
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
		# Dev: walk the keyframes, then give the clock back. Pressing it pins the
		# hour so a look can be judged still; pressing past the last one resumes
		# the cycle. Lighting has to be checked both ways — held, against the
		# real city, and moving, because a cycle can be wrong only in transit.
		if key.physical_keycode == KEY_T and key.ctrl_pressed and key.alt_pressed:
			get_viewport().set_input_as_handled()
			_time_hold += 1
			if _time_hold >= TIME_PRESETS.size():
				_time_hold = -1
				print("[StoryMap] time of day: cycle running")
			else:
				_time = float(_time_hold)
				_apply_time(_time)
				print("[StoryMap] time of day: %s (held)" % _time_name())
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
		_save_time_of_day()
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

## Each entry: {"node", "mats": Array[StandardMaterial3D], "base_alpha":
## PackedFloat32Array, "modes": PackedInt32Array, "center": Vector2, "radius",
## "alpha"} — one material, base alpha and transparency mode per surface.
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

		# Materials are duplicated per shelter: the baked scene shares material
		# resources between nodes, and fading a shared one would take unrelated
		# parts of the city with it. And EVERY surface's, because a house roof is
		# tiles plus a fascia — fade only the first and the fascia is left
		# hanging in the air.
		var mats: Array[StandardMaterial3D] = []
		var src := mi.material_override as StandardMaterial3D
		if src != null:
			var mat := src.duplicate() as StandardMaterial3D
			mi.material_override = mat
			mats.append(mat)
		else:
			for i in mi.mesh.get_surface_count():
				var surf := mi.get_active_material(i) as StandardMaterial3D
				if surf == null:
					continue
				var mat := surf.duplicate() as StandardMaterial3D
				mi.set_surface_override_material(i, mat)
				mats.append(mat)
		if mats.is_empty():
			push_warning("[StoryMap] shelter '%s' has no StandardMaterial3D to fade." % mi.name)
			continue

		var base_alpha := PackedFloat32Array()
		var modes := PackedInt32Array()
		for mat: StandardMaterial3D in mats:
			base_alpha.append(mat.albedo_color.a)
			modes.append(mat.transparency)

		var centre := world.get_center()
		_shelters.append({
			"node": mi,
			"mats": mats,
			"base_alpha": base_alpha,
			"modes": modes,
			"center": Vector2(centre.x, centre.z),
			"radius": maxf(world.size.x, world.size.z) * 0.5 + SHELTER_MARGIN,
			"alpha": 1.0,
		})


func _update_shelters(delta: float) -> void:
	if _shelters.is_empty() or _walker == null:
		return
	var here := Vector2(_walker.global_position.x, _walker.global_position.z)
	var k: float = clampf(SHELTER_FADE_RATE * delta, 0.0, 1.0)

	for sh: Dictionary in _shelters:
		var under: bool = here.distance_to(sh["center"] as Vector2) < float(sh["radius"])
		var target: float = SHELTER_FADE if under else 1.0
		var was: float = sh["alpha"]
		var a: float = lerpf(was, target, k)
		# Snap the tail of the lerp, so a roof that is not fading comes to rest
		# and is left alone. Every house roof is a shelter, and rewriting all of
		# their materials every frame to the values they already hold is not
		# free.
		if absf(a - target) < 0.002:
			a = target
		if a == was:
			continue
		sh["alpha"] = a

		# Blended only while it is actually see-through. An alpha-blended
		# material skips the depth prepass, so SSAO never reaches it — and every
		# house roof used to sit in that state permanently, losing its contact
		# shading for the sake of a fade it almost never does.
		var mats: Array[StandardMaterial3D] = sh["mats"]
		var base_alpha: PackedFloat32Array = sh["base_alpha"]
		var modes: PackedInt32Array = sh["modes"]
		for i in mats.size():
			var mat: StandardMaterial3D = mats[i]
			var mode: int = BaseMaterial3D.TRANSPARENCY_ALPHA if a < 1.0 else modes[i]
			if mat.transparency != mode:
				mat.transparency = mode as BaseMaterial3D.Transparency
			var col: Color = mat.albedo_color
			mat.albedo_color = Color(col.r, col.g, col.b, base_alpha[i] * a)

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
	if _time_hold < 0 and not TIME_PRESETS.is_empty():
		_time = fposmod(_time + delta * float(TIME_PRESETS.size()) / DAY_LENGTH_S,
			float(TIME_PRESETS.size()))
		_apply_time(_time)

	if _camera == null or _walker == null:
		return
	# The camera trails Meeko rather than snapping to him, and it never changes
	# height or pitch — at map distance the whole point is that the framing does
	# not change, only what is under it. The entry beat is the one exception,
	# and it is still a straight dolly along the same sightline.
	var rate: float = ENTRY_CAM_RATE if _entering else CAM_FOLLOW_RATE
	var weight: float = clampf(rate * delta, 0.0, 1.0)
	if _entering:
		_cam_focus = _cam_focus.lerp(_entry_focus, weight)
		_cam_offset = _cam_offset.lerp(ENTRY_CAM_OFFSET, weight)
	else:
		_cam_focus = _cam_focus.lerp(_focus_target(), weight)
		# Back to map framing. Without this the camera would stay wherever the
		# entry beat left it — which is what coming out of a rift depends on,
		# and what a failed level load would otherwise be stuck at.
		_cam_offset = _cam_offset.lerp(MAP_CAM_OFFSET, weight)
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
