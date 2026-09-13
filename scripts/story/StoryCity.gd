class_name StoryCity
extends Node3D

## The mundane city the Story Mode map sits in.
##
## PLACEHOLDER ART: boxes on a street grid. That is deliberate at this stage —
## the map camera never comes near the ground, so what actually has to be right
## in this pass is the LARGE-SCALE read: block layout, building massing and a
## skyline that varies from downtown to the edges. Small props would not survive
## the viewing distance, so none are built.
##
## The boxes are not flat colours, though. Walls and roofs are brick, render,
## stone, concrete, tile, slate and felt (see Surfaces below), tinted so each
## averages out to the colour its style always had — from map height a brick is
## a fraction of a pixel, so what the textures add is structure at the scale of
## a metre or more, not a new palette.
##
## ── The city is not damaged ──────────────────────────────────────────────────
## No debris, no cracks, no decay, no destruction — not near the rifts either.
## A rift is inconvenient, not destructive, and the whole visual idea of the map
## depends on the city reading as an ordinary weekday: everything here is muted
## and grey-brown so the rifts are the only saturated, wrong-looking thing on
## screen. Anything added later that scuffs the city up takes that contrast away.
##
## TODO(art): swap the boxes for authored block kits. `build()` already receives
## the keep-clear list, so real geometry can be placed the same way.

## Fixed seed: the map layout must be the same city every time the player opens
## it. The RNG autoload is deliberately not used — that one is seeded per run
## and per section for gameplay variety, which is the opposite of what a map
## backdrop wants.
const CITY_SEED: int = 0x5A1AC17

## Metres of clearance kept around the route trails, so a building never sits on
## top of a path Meeko has to walk down.
##
## Small on purpose now that routes run down the STREETS. A road is already an
## 11 m gap between blocks, so a trail on a road centreline needs no clearance of
## its own — and asking for the old 7 m would have culled every building on a
## lot facing a used road, stripping the city back along each route. What this
## still covers is the short spur from a rift out to its nearest road, which
## does cross a block.
const PATH_CLEARANCE: float = 2.5

## Ground level convention: the PAVEMENT top is y = 0, and the carriageway sits
## ROAD_DROP below it. Everything that stands on the city — rifts, Meeko, the
## route trails, buildings — is authored at y = 0 and needs no per-surface
## offset. Raising the pavement instead would have buried every rift halo in it.
const ROAD_DROP: float = 0.07

## How far from a map node the city is actually built. The map camera shows
## roughly 120 m of ground and never leaves the nodes, so this is a generous
## margin — the player reaches fog long before the edge of the built area.
const VIEW_BAND: float = 135.0

## Muted but COLOURED. An earlier pass had everything within a few points of the
## same grey, and the map read as a model rather than as a place. Calder City is
## a small town on an ordinary afternoon: brick, stucco, render and slate, with
## gardens and street trees through it. The rifts still dominate by being
## SATURATED and emissive — they do not need everything else to be colourless.
const GROUND_COL:   Color = Color(0.340, 0.325, 0.300, 1.0)
const ROAD_COL:     Color = Color(0.298, 0.290, 0.298, 1.0)
## Side streets are warmer and paler than the avenues — older paving, less tar.
const LANE_COL:     Color = Color(0.395, 0.372, 0.340, 1.0)
const PAVEMENT_COL: Color = Color(0.520, 0.500, 0.470, 1.0)
const MARKING_COL:  Color = Color(0.780, 0.760, 0.700, 1.0)
const GRAVEL_COL:   Color = Color(0.505, 0.462, 0.398, 1.0)

const GRASS_COL: Color = Color(0.318, 0.418, 0.242, 1.0)
const HEDGE_COL: Color = Color(0.232, 0.330, 0.196, 1.0)
const LEAF_COL_A: Color = Color(0.268, 0.392, 0.220, 1.0)
const LEAF_COL_B: Color = Color(0.330, 0.436, 0.238, 1.0)
const LEAF_COL_C: Color = Color(0.372, 0.400, 0.212, 1.0)
const TRUNK_COL: Color = Color(0.300, 0.238, 0.190, 1.0)
const WATER_COL: Color = Color(0.230, 0.372, 0.408, 1.0)
## Grass behind the houses: rougher and a shade darker than the mown front
## gardens, so each plot still reads against the ground it stands on.
const YARD_GRASS_COL: Color = Color(0.296, 0.382, 0.228, 1.0)
## Behind a row of shops: service yards and parking, in tarmac.
const YARD_COL: Color = Color(0.352, 0.342, 0.338, 1.0)
const KERB_COL: Color = Color(0.640, 0.625, 0.595, 1.0)
## Dressed stone: pond rims, fountain basins.
const STONE_COL: Color = Color(0.560, 0.540, 0.505, 1.0)

## Each style is [wall, roof, wall skin, roof skin]. Red brick, cream stucco,
## sage render, sandstone, blue-grey concrete, buff brick and pale concrete — a
## terrace of houses that were not all built at once.
##
## The colours are still what a style IS. A skin is a texture tinted so that its
## average lands exactly on that colour (_skin_mat): recolour a style here and
## its bricks follow.
const BUILDING_STYLES: Array = [
	[Color(0.605, 0.408, 0.330), Color(0.430, 0.235, 0.190), "brick_red",  "roof_tile"],
	[Color(0.760, 0.712, 0.605), Color(0.352, 0.330, 0.342), "render",     "slate"],
	[Color(0.548, 0.575, 0.512), Color(0.330, 0.302, 0.272), "render",     "roof_tile"],
	[Color(0.700, 0.622, 0.510), Color(0.412, 0.352, 0.310), "stone",      "roof_tile"],
	[Color(0.470, 0.512, 0.572), Color(0.312, 0.334, 0.372), "concrete",   "slate"],
	[Color(0.660, 0.500, 0.412), Color(0.398, 0.222, 0.182), "brick_buff", "roof_tile"],
	[Color(0.792, 0.760, 0.700), Color(0.372, 0.352, 0.340), "concrete",   "slate"],
]

# ── Surfaces ─────────────────────────────────────────────────────────────────
# What the walls and roofs are made of. The textures are generated by
# tools/gen_city_textures.py, which also writes skins.json — the average colour
# of each, which is what every tint is worked out from.

const SKIN_DIR: String = "res://assets/story/city/"
## [albedo, normal map, metres one repeat covers, roughness].
##
## The metres are load-bearing: they are the tile the generator laid its pattern
## out on, and if they disagree every brick in town comes out the wrong size.
## Change one there, change it here.
const SKINS: Dictionary = {
	"brick_red":  ["brick_red",  "brick",     6.3, 0.90],
	"brick_buff": ["brick_buff", "brick",     6.3, 0.90],
	"render":     ["render",     "render",    6.3, 0.94],
	"stone":      ["stone",      "stone",     6.3, 0.88],
	"concrete":   ["concrete",   "concrete",  6.3, 0.86],
	"roof_tile":  ["roof_tile",  "roof_tile", 4.2, 0.78],
	"slate":      ["slate",      "slate",     4.2, 0.62],
	"membrane":   ["membrane",   "membrane",  6.0, 0.92],
	# Ground. All but the paving have no direction to them, so they go on by
	# world position (triplanar) — no UVs needed on a single slab, disc or box.
	"asphalt":    ["asphalt",    "asphalt",   6.0, 0.92],
	"paving":     ["paving",     "paving",    4.8, 0.88],
	"grass":      ["grass",      "grass",     8.0, 0.97],
	"foliage":    ["foliage",    "foliage",   4.0, 0.90],
	"gravel":     ["gravel",     "gravel",    3.0, 0.95],
}
## Concrete is cast in panels this wide, three to the texture. See _wall_runs.
const CONCRETE_PANEL: float = 2.1

## The base course every building stands on: the same wall, darker. It is what
## stops a house looking set down on the pavement instead of built up out of
## it. Vertex colour rather than a second material, so it costs no extra draw
## call on any building. The shade is LINEAR — it multiplies in the shader.
const PLINTH_H: float = 0.45
const PLINTH_SHADE: float = 0.55
## How far a pitched roof overhangs its walls, at the eaves and the gable ends.
const EAVE: float = 0.35
## How deep a roof's edge is. Deep enough that the fascia draws a trim-coloured
## line round the roof from map height, which is what tells a brown roof from
## the brown wall under it when the camera sees both from above.
const FASCIA: float = 0.20
## A shop's flat roof: a parapet this tall, standing out past the wall by the
## lip, capped in concrete this wide, round a deck sunk this far below the cap.
const PARAPET_H: float = 0.6
const PARAPET_LIP: float = 0.25
const COPING_W: float = 0.35
const DECK_DROP: float = 0.18
## Pale enough to outline a shop from above, not so pale it glares at noon.
const COPING_COL: Color = Color(0.600, 0.585, 0.560, 1.0)
## Where a shop's upper-floor windows start, above its painted front.
const SHOP_GLASS_BASE: float = 3.5

# ── Streets ──────────────────────────────────────────────────────────────────
## The pavement between the kerb and whatever the block is: lawn behind the
## houses, a yard behind the shops. It used to be the WHOLE block, which is why
## the map was mostly grey, and it stopped a metre short of the road, which is
## the dark jagged seam that ran round every block.
const PAVE_W: float = 2.4
## The kerbstone along its road edge — a pale line round every block from map
## height, and most of what makes a street read as built rather than painted.
const KERB_W: float = 0.18
## Parked cars sit in the carriageway, this far out from the kerb and no nearer
## a corner than this. They used to be parked on the pavement.
const PARK_OUT: float = 1.15
const PARK_CLEAR: float = 6.0
## Nose to tail, near enough: a car and its gap.
const PARK_PITCH: float = 5.4
## Zebra crossings at the mouth of every avenue junction: stripes this wide and
## this long, starting just clear of the junction itself.
const ZEBRA_STRIPE: float = 0.5
const ZEBRA_DEPTH: float = 3.0

# ── Streetlights ─────────────────────────────────────────────────────────────
# One mesh shared by every lamp, drawn per block as a MultiMesh: two hundred
# lamps as separate nodes would be two hundred draw calls, most of them twice
# over for shadows. What they cost is a block's worth of editing granularity —
# delete a block's "Streetlights" and its lamps go together.
const LAMP_SPACING: float = 24.0
## First lamp this far along from each corner.
const LAMP_END: float = 5.0
## How far in from the kerb the post stands.
const LAMP_INSET: float = 0.55
const LAMP_HEIGHT: float = 5.4
## How far the arm reaches out over the road.
const LAMP_REACH: float = 1.3
## The pool of light each one lays on the ground after dark.
const LAMP_POOL_R: float = 4.8
const LAMP_GLOW_COL: Color = Color(1.00, 0.80, 0.52, 1.0)
const LAMP_POST_COL: Color = Color(0.180, 0.188, 0.200, 1.0)

# ── Parks ────────────────────────────────────────────────────────────────────
const PATH_W: float = 2.4
## Where the paths meet in a park with no pond: a gravel round with a fountain.
const ROUND_R: float = 3.4
## The playground: a fenced, rubber-floored rectangle in the park nearest the
## plaza, so the player actually passes it.
const PLAY_SIZE := Vector2(10.0, 8.0)
const RUBBER_COL: Color = Color(0.600, 0.285, 0.225, 1.0)
## Flower beds, muted — they are a garden, not a signal.
const FLOWER_COLS: Array[Color] = [
	Color(0.620, 0.360, 0.420), Color(0.720, 0.560, 0.240), Color(0.500, 0.440, 0.620),
]

## Shopfronts and parked cars: the two places the town is allowed to be bright.
const SHOPFRONT_COLS: Array[Color] = [
	Color(0.180, 0.372, 0.330), Color(0.560, 0.180, 0.190),
	Color(0.180, 0.268, 0.450), Color(0.640, 0.450, 0.140),
	Color(0.360, 0.180, 0.340), Color(0.150, 0.330, 0.210),
]
const CAR_COLS: Array[Color] = [
	Color(0.720, 0.720, 0.730), Color(0.140, 0.150, 0.170),
	Color(0.560, 0.170, 0.160), Color(0.170, 0.330, 0.520),
	Color(0.640, 0.600, 0.240), Color(0.250, 0.420, 0.300),
	Color(0.820, 0.800, 0.780),
]

# ── Facades ──────────────────────────────────────────────────────────────────
# Windows and doors are what stop a building reading as a painted box, and at
# this camera height they are the only detail on a wall that is legible at all.

## Floor-to-floor height. Windows are laid out in storeys off this rather than
## spread evenly over whatever height the building happens to be, so a tall
## shop and a low house have windows the same size at the same spacings and the
## street reads as one town.
const STOREY: float = 3.15
const WIN_W: float = 1.16
const WIN_H: float = 1.32
## Sill height above the floor the window belongs to.
const WIN_SILL: float = 0.95
## Nominal spacing between window centres; the real spacing divides the wall.
const WIN_BAY: float = 3.05
## How far the frame stands off the wall. Panes are quads laid ON the wall, not
## holes cut through it — from map distance the difference cannot be seen, and
## the wall stays one box instead of becoming a mesh with openings in it.
const WIN_PROUD: float = 0.035
const DOOR_W: float = 1.08
const DOOR_H: float = 2.15

const GLASS_COL:     Color = Color(0.150, 0.196, 0.250, 1.0)
const GLASS_LIT_COL: Color = Color(0.985, 0.855, 0.590, 1.0)
## Trim comes in two shades and each building takes the one its walls do not
## drown: cream windows are invisible on a cream house.
const TRIM_PALE: Color = Color(0.918, 0.906, 0.878, 1.0)
const TRIM_DARK: Color = Color(0.248, 0.238, 0.252, 1.0)
## A painted front door is the one flash of colour a plain house is allowed.
const DOOR_COLS: Array[Color] = [
	Color(0.560, 0.170, 0.165), Color(0.130, 0.290, 0.420),
	Color(0.150, 0.330, 0.235), Color(0.320, 0.180, 0.320),
	Color(0.640, 0.440, 0.140), Color(0.290, 0.235, 0.205),
	Color(0.860, 0.845, 0.820),
]
## Share of panes with a light behind them.
##
## This used to be 8.5% — right when the map was permanently at midday and a lit
## window was a small daytime accent. The map runs a day/night cycle now, so
## which windows CAN light has to be decided for the darkest hour, not the
## brightest: the share is baked into the mesh surfaces and cannot change at
## runtime. How brightly they burn is what varies — StoryMap drives the shared
## lit material's emission from the clock, and at noon it goes to zero, leaving
## these reading as ordinary pale blinds.
const LIT_SHARE: float = 0.34

var _rng := RandomNumberGenerator.new()
## A second stream, only for where each building's textures start. Kept off
## _rng on purpose: every draw on _rng decides layout, and one extra draw would
## move every building after it — dressing the walls must not rebuild the town.
var _skin_rng := RandomNumberGenerator.new()
## And a third for street furniture and park dressing, for the same reason.
var _prop_rng := RandomNumberGenerator.new()
var _unit_box: BoxMesh = null
var _wall_mats: Array[StandardMaterial3D] = []
var _roof_mats: Array[StandardMaterial3D] = []
var _deck_mats: Array[StandardMaterial3D] = []
var _coping_mat: StandardMaterial3D = null
var _bench_mat: StandardMaterial3D = null
var _shop_mats: Array[StandardMaterial3D] = []
var _car_mats: Array[StandardMaterial3D] = []
var _door_mats: Array[StandardMaterial3D] = []
var _glass_mat: StandardMaterial3D = null
var _glass_lit_mat: StandardMaterial3D = null
var _trim_pale_mat: StandardMaterial3D = null
var _trim_dark_mat: StandardMaterial3D = null
var _leaf_mats: Array[StandardMaterial3D] = []
var _pavement_mat: StandardMaterial3D = null
var _road_mat: StandardMaterial3D = null
var _lane_mat: StandardMaterial3D = null
var _marking_mat: StandardMaterial3D = null
var _grass_mat: StandardMaterial3D = null
var _hedge_mat: StandardMaterial3D = null
var _trunk_mat: StandardMaterial3D = null
var _water_mat: StandardMaterial3D = null
var _path_mat: StandardMaterial3D = null
var _kerb_mat: StandardMaterial3D = null
var _yard_mat: StandardMaterial3D = null
var _yard_grass_mat: StandardMaterial3D = null
var _lawn_mat: StandardMaterial3D = null
var _stone_mat: StandardMaterial3D = null
var _rubber_mat: StandardMaterial3D = null
var _lamp_mesh: ArrayMesh = null
var _pool_mesh: ArrayMesh = null
var _building_count: int = 0
var _block_count: int = 0
var _tree_count: int = 0

## The ground of the block being built: its kerb line, the back of the kerb, the
## inner edge of the pavement, and which street (if any) runs along each side.
## Set by _build_blocks before a block is filled; see _block_ground().
var _ground: Dictionary = {}
## Street trees _build_kerbside planted on the current block, so the lamps can
## keep clear of them.
var _kerb_trees := PackedVector3Array()
## Where cars are already parked along each side of the current block, as
## distance down the kerb — side index -> PackedFloat32Array.
var _bays: Dictionary = {}
## Every park, for the dressing pass once the whole town is standing:
## {"block", "inner", "pond", "streets"}.
var _parks: Array[Dictionary] = []
var _hub_at := Vector3.ZERO
## skins.json, kept for the few materials made after _build_materials.
var _means: Dictionary = {}

var _roads: StoryRoads = null
var _ground_root: Node3D = null
var _road_root: Node3D = null
var _block_root: Node3D = null


# ── Street queries ───────────────────────────────────────────────────────────
## Thin delegates onto StoryRoads, which owns the network itself.
##
## These used to BE the routing: closed-form arithmetic on a perfect lattice —
## nearest centreline, at most two turns, done. That only worked while every
## street existed and ran dead straight. The streets wander and some of them are
## missing now, so the answers come from a graph search instead, and everything
## that used to call into the maths calls through here unchanged.

## Where a rift stands on a block: back from the kerb of the nearest street, on
## the side it was already on, facing the road.
static func street_frontage(pos: Vector3, origin: Vector3) -> Dictionary:
	return StoryRoads.shared(origin).frontage(pos)


## The point on the carriageway a frontage steps out onto — the street on the
## side it faces, which for the plaza is the one side it opens on.
static func frontage_doorstep(pos: Vector3, facing: Vector3, origin: Vector3) -> Vector3:
	return StoryRoads.shared(origin).doorstep(pos, facing)


## Which way a hand-placed point should face: out at whatever street is nearest.
static func nearest_street_facing(pos: Vector3, origin: Vector3) -> Vector3:
	return StoryRoads.shared(origin).frontage(pos)["facing"]


## An on-street polyline between two points.
static func road_route(a: Vector3, b: Vector3, origin: Vector3) -> PackedVector3Array:
	return StoryRoads.shared(origin).route(a, b)


## Drops points that land on top of each other.
static func dedupe_points(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.5:
			out.append(p)
	return out


# ── The hub plaza ────────────────────────────────────────────────────────────
## Calder City's central square: a paved circle under a raised canopy.
##
## It lives here rather than in StoryMap because it is city furniture, and
## because two things build it — the map (when there is no baked scene) and the
## bake itself. One definition, so they cannot drift apart.
##
## Two rules the geometry has to respect:
##
##  * The DECK IS AT y = 0. Meeko stands here and the route trails end here, and
##    everything on the map is authored at ground zero. The paving is layered
##    downward into the pavement rather than stacked up off it.
##  * The MIDDLE STAYS EMPTY. Meeko stands dead centre; a fountain or a plinth
##    there would hide the one thing the screen exists to show. Everything with
##    height sits out at the rim.
##
## Anything overhead is named Roof-something on purpose: StoryMap fades meshes
## matching that when Meeko walks underneath, so the canopy dissolves and leaves
## the columns standing. Rename them and he vanishes under the roof.
const PLAZA_RADIUS: float = 12.0
const CANOPY_RADIUS: float = 14.6
const CANOPY_HEIGHT: float = 10.4
const COLUMN_COUNT: int = 8
const COLUMN_RING: float = 10.4
## The two beds flanking the way in: swung this far further AWAY from the
## opening than their slot, drawn in toward the middle, and turned end-on to it
## — a funnel into the plaza rather than two more beds round the rim.
##
## These are Melody's, from dragging the beds in the baked scene (2026-09-10):
## the code used to swing them TOWARD the entrance, narrowing it, whatever its
## comment claimed. The numbers are the average of the two beds as placed.
const ENTRANCE_SPLAY: float = 0.164
const ENTRANCE_PULL: float = 1.42
## How far off radial the entrance beds are turned, flaring outward.
const ENTRANCE_FLARE: float = 0.301

## `facing` is which way the plaza opens. The gap in the colonnade and the beds
## that frame it are derived from it rather than pinned to a fixed index — flip
## the hub's `facing` in the map JSON and the opening moves with it instead of
## ending up behind a pillar.
static func build_hub(parent: Node3D, at: Vector3, facing: Vector3 = Vector3(0.0, 0.0, 1.0)) -> Node3D:
	var hub := Node3D.new()
	hub.name = "Hub"
	hub.position = at
	parent.add_child(hub)

	# The same colours as ever, now in stone, paving and concrete. All by world
	# position: the plaza is discs, rings and cylinders, none of which comes with
	# UVs a texture could be laid out on, and none of these textures has a grain
	# that minds which way it runs.
	var means: Dictionary = _skin_means()
	var pale   := _skin_mat("stone",    Color(0.545, 0.535, 0.540), means, true)
	var paving := _skin_mat("paving",   Color(0.470, 0.462, 0.470), means, true)
	var canopy := _skin_mat("concrete", Color(0.545, 0.535, 0.540), means, true)
	var beams  := _skin_mat("concrete", Color(0.470, 0.462, 0.470), means, true)
	var dark   := _skin_mat("stone",    Color(0.355, 0.350, 0.358), means, true)
	var accent := _skin_mat("stone",    Color(0.395, 0.372, 0.345), means, true)
	var green  := _skin_mat("foliage",  Color(0.250, 0.305, 0.235), means, true)

	var entrance: float = atan2(facing.z, facing.x)
	_hub_deck(hub, pale, paving, dark)
	_hub_columns(hub, pale, dark, entrance)
	_hub_canopy(hub, canopy, beams, dark)
	_hub_planters(hub, accent, green, entrance)
	return hub


## Paving. Read from directly overhead, so it is a pattern rather than a slab:
## an outer apron, a darker kerb ring, a centre medallion and eight radial
## spokes. All of it within a few centimetres of y = 0.
static func _hub_deck(hub: Node3D, pale: StandardMaterial3D, stone: StandardMaterial3D,
		dark: StandardMaterial3D) -> void:
	var deck := Node3D.new()
	deck.name = "Deck"
	hub.add_child(deck)

	_disc(deck, "Apron", PLAZA_RADIUS, 0.14, -0.04, stone, 40)
	_disc(deck, "Medallion", 6.4, 0.14, -0.01, pale, 32)
	_ring(deck, "Kerb", PLAZA_RADIUS - 0.7, PLAZA_RADIUS + 0.5, 0.02, dark)
	_ring(deck, "MedallionRing", 6.1, 6.7, 0.03, dark)

	for i in COLUMN_COUNT:
		var a: float = TAU * float(i) / float(COLUMN_COUNT) + TAU / (float(COLUMN_COUNT) * 2.0)
		var mid: float = (6.4 + PLAZA_RADIUS) * 0.5
		var spoke := _hub_box(deck, "Spoke_%d" % i,
			Vector3(cos(a) * mid, 0.01, sin(a) * mid),
			Vector3(PLAZA_RADIUS - 6.4, 0.13, 0.55), dark)
		spoke.rotation.y = -a


static func _hub_columns(hub: Node3D, pale: StandardMaterial3D, dark: StandardMaterial3D,
		entrance: float) -> void:
	var ring := Node3D.new()
	ring.name = "Colonnade"
	hub.add_child(ring)

	for i in COLUMN_COUNT:
		var a: float = TAU * float(i) / float(COLUMN_COUNT)
		# Leave the entrance clear. A column dead in the middle of the one way
		# in is exactly where a column should not be.
		if absf(angle_difference(a, entrance)) < TAU / float(COLUMN_COUNT) * 0.5:
			continue
		var col := Node3D.new()
		col.name = "Column_%d" % i
		col.position = Vector3(cos(a) * COLUMN_RING, 0.0, sin(a) * COLUMN_RING)
		ring.add_child(col)

		# Slimmer and more of them than a few heavy piers: from map height eight
		# thin columns read as a colonnade, where four thick ones read as boxes.
		_hub_box(col, "Plinth", Vector3(0.0, 0.22, 0.0), Vector3(1.5, 0.44, 1.5), dark)
		_cylinder(col, "Shaft", 0.40, CANOPY_HEIGHT - 0.9, 0.44 + (CANOPY_HEIGHT - 0.9) * 0.5, pale, 10)
		_hub_box(col, "Capital", Vector3(0.0, CANOPY_HEIGHT - 0.28, 0.0), Vector3(1.35, 0.5, 1.35), dark)


## The canopy: a stepped plate with a fascia band, a raised crown and a lantern.
## Stepping it is what stops the roof reading as one flat disc from above, which
## is the only angle it is ever seen from.
static func _hub_canopy(hub: Node3D, pale: StandardMaterial3D, stone: StandardMaterial3D,
		dark: StandardMaterial3D) -> void:
	var roof := Node3D.new()
	roof.name = "Canopy"
	hub.add_child(roof)

	# Radial beams under the plate, so the underside is structure and not a
	# blank ceiling. Named Roof* so they fade with the canopy above them.
	for i in COLUMN_COUNT:
		var a: float = TAU * float(i) / float(COLUMN_COUNT)
		var beam := _hub_box(roof, "RoofBeam_%d" % i,
			Vector3(0.0, CANOPY_HEIGHT + 0.1, 0.0),
			Vector3(CANOPY_RADIUS * 2.0 - 1.0, 0.32, 0.42), stone)
		beam.rotation.y = -a

	_disc(roof, "RoofPlate", CANOPY_RADIUS, 0.44, CANOPY_HEIGHT + 0.48, pale, 40)
	_ring(roof, "RoofFascia", CANOPY_RADIUS - 0.5, CANOPY_RADIUS + 0.55, CANOPY_HEIGHT + 0.4, dark)
	_disc(roof, "RoofCrown", CANOPY_RADIUS * 0.58, 0.5, CANOPY_HEIGHT + 0.95, stone, 32)
	_ring(roof, "RoofCrownRim", CANOPY_RADIUS * 0.58 - 0.4, CANOPY_RADIUS * 0.58 + 0.45,
		CANOPY_HEIGHT + 0.9, dark)
	_disc(roof, "RoofLantern", 2.3, 1.5, CANOPY_HEIGHT + 1.9, pale, 20)
	_disc(roof, "RoofLanternCap", 3.0, 0.34, CANOPY_HEIGHT + 2.75, dark, 20)


## Planters between the columns. They give the rim something other than columns
## and keep the middle of the deck clear, which is where Meeko has to be seen.
static func _hub_planters(hub: Node3D, accent: StandardMaterial3D, green: StandardMaterial3D,
		entrance: float) -> void:
	var beds := Node3D.new()
	beds.name = "Planters"
	hub.add_child(beds)

	var slot: float = TAU / float(COLUMN_COUNT)
	for i in COLUMN_COUNT:
		var a: float = slot * float(i) + slot * 0.5
		var ring: float = COLUMN_RING
		# Tangent to the rim, like every other bed.
		var turn: float = -a
		# The two beds either side of the entrance: swung away from it and drawn
		# in, and turned to run out from the middle so they frame the way in.
		# angle_difference() is entrance - a, so stepping AGAINST its sign is
		# stepping away from the opening.
		var off: float = angle_difference(a, entrance)
		if absf(off) < slot:
			a -= ENTRANCE_SPLAY * signf(off)
			ring -= ENTRANCE_PULL
			var run_dir: float = a - ENTRANCE_FLARE * signf(off)
			turn = PI * 0.5 - run_dir

		var bed := Node3D.new()
		bed.name = "Planter_%d" % i
		bed.position = Vector3(cos(a) * ring, 0.0, sin(a) * ring)
		bed.rotation.y = turn
		beds.add_child(bed)
		_hub_box(bed, "Kerb", Vector3(0.0, 0.28, 0.0), Vector3(1.1, 0.56, 4.4), accent)
		_hub_box(bed, "Planting", Vector3(0.0, 0.52, 0.0), Vector3(0.82, 0.2, 4.1), green)


# ── Small builders ───────────────────────────────────────────────────────────

static func _disc(parent: Node3D, disc_name: String, radius: float, height: float,
		y: float, mat: StandardMaterial3D, segments: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = disc_name
	var mesh := CylinderMesh.new()
	mesh.top_radius      = radius
	mesh.bottom_radius   = radius
	mesh.height          = height
	mesh.radial_segments = segments
	mesh.rings           = 1
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, y, 0.0)
	parent.add_child(mi)
	return mi


static func _ring(parent: Node3D, ring_name: String, inner: float, outer: float,
		y: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = ring_name
	var mesh := TorusMesh.new()
	mesh.inner_radius  = inner
	mesh.outer_radius  = outer
	mesh.rings         = 40
	mesh.ring_segments = 6
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, y, 0.0)
	parent.add_child(mi)
	return mi


static func _cylinder(parent: Node3D, cyl_name: String, radius: float, height: float,
		y: float, mat: StandardMaterial3D, segments: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = cyl_name
	var mesh := CylinderMesh.new()
	mesh.top_radius      = radius
	mesh.bottom_radius   = radius
	mesh.height          = height
	mesh.radial_segments = segments
	mesh.rings           = 1
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, y, 0.0)
	parent.add_child(mi)
	return mi


static func _hub_box(parent: Node3D, box_name: String, pos: Vector3, size: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = box_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi



## Builds the backdrop out to `radius` metres around `center`.
##
## `keep_clear` is a list of {"pos": Vector3, "radius": float} — the rifts and
## the hub, which must not end up inside a building. `paths` is the list of
## approach spurs, kept clear by PATH_CLEARANCE so the way to a rift stays open.
func build(center: Vector3, radius: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> void:
	_rng.seed = CITY_SEED
	_skin_rng.seed = CITY_SEED + 1
	_prop_rng.seed = CITY_SEED + 2
	_hub_at = center
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_roads = StoryRoads.shared(center)
	_build_materials()
	_lamp_mesh = _build_lamp_mesh()
	_pool_mesh = _build_pool_mesh()

	_ground_root = _group("Ground")
	_road_root   = _group("Roads")
	_block_root  = _group("Blocks")

	_build_ground(center, radius)
	_build_streets(center, radius)
	_build_blocks(center, radius, keep_clear, paths)
	# After every block, not during: dressing a park moves nothing that was
	# placed by _rng, it only takes away the trees its paths now run through —
	# and which park gets the playground depends on all of them existing.
	_dress_parks()
	print("[StoryCity] %d buildings across %d blocks, %.0f m radius." % [
		_building_count, _block_count, radius])


func _group(group_name: String) -> Node3D:
	var n := Node3D.new()
	n.name = group_name
	add_child(n)
	return n


func _build_materials() -> void:
	var means: Dictionary = _skin_means()
	_means = means
	for style: Array in BUILDING_STYLES:
		var wall: StandardMaterial3D = _skin_mat(String(style[2]), style[0] as Color, means)
		# The plinth is this same material, darkened by the mesh's vertex colour.
		wall.vertex_color_use_as_albedo = true
		_wall_mats.append(wall)
		_roof_mats.append(_skin_mat(String(style[3]), style[1] as Color, means))
		# A flat roof in the style's roof colour, so a terrace keeps the tops it
		# has always had from above — felt now instead of a painted lid.
		_deck_mats.append(_skin_mat("membrane", style[1] as Color, means))
	_coping_mat = _skin_mat("concrete", COPING_COL, means)
	# Benches are scaled unit boxes, with no UVs worth laying a texture on, so
	# they keep the flat colour they had when they borrowed a roof material.
	_bench_mat = _flat_mat((BUILDING_STYLES[1] as Array)[1] as Color, 0.80)
	for c: Color in SHOPFRONT_COLS:
		_shop_mats.append(_flat_mat(c, 0.55))
	for c: Color in CAR_COLS:
		_car_mats.append(_flat_mat(c, 0.35))
	for c: Color in DOOR_COLS:
		_door_mats.append(_flat_mat(c, 0.55))

	# Glass is the one thing in this town that is not matte: a low roughness and
	# a little metallic is what makes a dark rectangle read as a window rather
	# than as a hole painted on the wall.
	_glass_mat = _flat_mat(GLASS_COL, 0.14)
	_glass_mat.metallic = 0.42
	_glass_lit_mat = _flat_mat(GLASS_LIT_COL, 0.35)
	_glass_lit_mat.emission_enabled = true
	_glass_lit_mat.emission = GLASS_LIT_COL
	_glass_lit_mat.emission_energy_multiplier = 0.55
	# Named so StoryMap can find this one shared material inside the BAKED city
	# and drive its emission from the time of day. Nothing else identifies it —
	# it is one StandardMaterial3D among hundreds once the scene is packed.
	_glass_lit_mat.resource_name = "LitGlass"
	_trim_pale_mat = _flat_mat(TRIM_PALE, 0.88)
	_trim_dark_mat = _flat_mat(TRIM_DARK, 0.88)

	# Paving and kerbs have a grain to them — flags square to the kerb, joints
	# along it — so they are laid out along each street (_build_block_edge).
	# Everything else on the ground goes on by world position.
	#
	# Slabs are the exception, triplanar or not: they are flat and carry their
	# own x/z as UVs (see _slab), and triplanar samples every texture three
	# times over to blend projections a flat surface never shows. The streets
	# are in world space, so their UVs line up across every junction anyway.
	_pavement_mat   = _skin_mat("paving", PAVEMENT_COL, means)
	_kerb_mat       = _skin_mat("concrete", KERB_COL, means)
	_road_mat       = _skin_mat("asphalt", ROAD_COL, means)
	_lane_mat       = _skin_mat("asphalt", LANE_COL, means)
	_yard_mat       = _skin_mat("asphalt", YARD_COL, means)
	_marking_mat    = _flat_mat(MARKING_COL, 0.9)
	# Gardens are scaled boxes, so this one stays triplanar; the park lawns
	# are slabs and get their own.
	_grass_mat      = _skin_mat("grass", GRASS_COL, means, true)
	_lawn_mat       = _skin_mat("grass", GRASS_COL, means)
	_yard_grass_mat = _skin_mat("grass", YARD_GRASS_COL, means)
	_hedge_mat      = _skin_mat("foliage", HEDGE_COL, means, true)
	for c: Color in [LEAF_COL_A, LEAF_COL_B, LEAF_COL_C]:
		_leaf_mats.append(_skin_mat("foliage", c, means, true))
	_trunk_mat      = _flat_mat(TRUNK_COL, 0.95)
	_water_mat      = _flat_mat(WATER_COL, 0.18)
	_water_mat.metallic = 0.25
	_path_mat       = _skin_mat("gravel", GRAVEL_COL, means, true)
	_stone_mat      = _skin_mat("stone", STONE_COL, means, true)
	_rubber_mat     = _skin_mat("asphalt", RUBBER_COL, means, true)


## Static so the plaza — built by a static function, for the map and the bake
## alike — can use the same materials as the rest of the town.
static func _flat_mat(col: Color, rough: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness    = rough
	return m


## skins.json: the linear-RGB average of every albedo the generator wrote.
static func _skin_means() -> Dictionary:
	var path: String = SKIN_DIR + "skins.json"
	if not FileAccess.file_exists(path):
		push_warning("[StoryCity] %s is missing — buildings fall back to flat colour. Run tools/gen_city_textures.py." % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## A textured material that averages out to `col`.
##
## albedo_color MULTIPLIES the texture, so the tint is the wanted colour divided
## by the texture's own mean. In linear space, because that is where the shader
## does the multiply — divide in sRGB and every style drifts off the colour it
## was tuned to. Done right, the city from map height is the palette it was.
##
## Falls back to the old flat colour if the textures are not there, so a missing
## file costs the look and not the map.
##
## `triplanar` maps the texture by WORLD position instead of UVs. Only for skins
## with no direction to them — grass, asphalt, gravel, foliage — where it means
## a scaled box, a cylinder or a bare slab can wear the texture at the right
## size without anyone building it UVs. A brick wall mapped that way ghosts
## where its projections blend, which is why the buildings are UV'd instead.
static func _skin_mat(skin: String, col: Color, means: Dictionary,
		triplanar: bool = false) -> StandardMaterial3D:
	var spec: Array = SKINS[skin]
	var albedo_path: String = SKIN_DIR + String(spec[0]) + ".webp"
	var normal_path: String = SKIN_DIR + String(spec[1]) + "_n.png"
	if not means.has(spec[0]) or not ResourceLoader.exists(albedo_path):
		return _flat_mat(col, float(spec[3]))

	var mean: Array = means[spec[0]]
	var want: Color = col.srgb_to_linear()
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(albedo_path) as Texture2D
	m.albedo_color = Color(want.r / float(mean[0]), want.g / float(mean[1]),
		want.b / float(mean[2])).linear_to_srgb()
	m.roughness = float(spec[3])
	if ResourceLoader.exists(normal_path):
		m.normal_enabled = true
		m.normal_texture = load(normal_path) as Texture2D
	# UVs are in metres (see _walls_mesh), so this is simply one repeat per tile.
	# Triplanar reads world metres the same way, on all three axes.
	var tile: float = float(spec[2])
	m.uv1_scale = Vector3(1.0 / tile, 1.0 / tile, 1.0 / tile if triplanar else 1.0)
	if triplanar:
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
	# The map camera sees every wall at a steep slant. Plain trilinear picks the
	# mip for the squashed direction and blurs the other; anisotropic keeps the
	# courses along a wall instead of smearing them into its average.
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.resource_name = "Skin_" + skin
	return m


func _box(parent: Node3D, piece_name: String, pos: Vector3, size: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = piece_name
	mi.mesh = _unit_box
	mi.material_override = mat
	mi.scale    = size
	mi.position = pos
	parent.add_child(mi)
	return mi


## A flat polygon lying on the ground. Streets and blocks are arbitrary shapes
## now, so neither can be a scaled box any more.
##
## UVs are the polygon's own x/z in metres, turned by `uv_angle` — so paving on
## a square can run true to one of its edges. Triplanar materials ignore them.
func _slab(parent: Node3D, slab_name: String, poly: PackedVector3Array, y: float,
		mat: StandardMaterial3D, uv_angle: float = 0.0) -> MeshInstance3D:
	if poly.size() < 3:
		return null
	var pts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for p: Vector3 in poly:
		pts.append(Vector3(p.x, y, p.z))
		uvs.append(Vector2(p.x, p.z).rotated(-uv_angle))
	# A fan: every shape here is convex, so this is safe.
	var s := Surf.new()
	s.face(pts, uvs, Vector3.UP)
	var mesh := ArrayMesh.new()
	s.commit(mesh, mat, true)
	return _flat_node(parent, slab_name, mesh)


## A mesh node for something lying flat on the ground. It casts no shadow: there
## is nothing for it to shadow, and every caster is drawn again in each of the
## sun's four shadow splits.
func _flat_node(parent: Node3D, piece_name: String, mesh: Mesh) -> MeshInstance3D:
	var mi := _mesh_node(parent, piece_name, mesh)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Windows, a front door and its doorstep — one mesh for the whole building.
##
## A house carries a dozen panes and a shop closer to forty. A MeshInstance3D
## per pane would take the baked city from four thousand nodes past fifty
## thousand, for detail the map camera reads as texture — so every pane on a
## building goes into ONE ArrayMesh with three surfaces (trim, glass, lit
## glass). That is also why this is the only mesh here that carries surface
## materials instead of a material_override: one node, three materials, still a
## single thing to select and recolour in the editor.
##
## Panes are quads laid a few centimetres ON the wall rather than holes cut
## through it. From map distance the difference cannot be seen, and the wall
## stays a scaled box.
##
## `front` is the local axis the street is on (+1 for local +Z, -1 for -Z): the
## door goes on that wall and nowhere else. `base` is the height the window grid
## starts at, so a shop can carry its glass above its shopfront. `door_skin`
## pushes the door out past anything already panelled onto the front wall.
func _facade(host: Node3D, w: float, h: float, d: float, front: float,
		base: float, wall: Color, shopfront: bool = false,
		door_skin: float = 0.0) -> void:
	# Surface buckets: 0 trim, 1 glass, 2 lit glass.
	var verts: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
	var norms: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
	var tris: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]

	# The door is worked out before the walls are, because the ground floor of
	# the front wall has to leave its bay empty.
	var front_n := Vector3(0.0, 0.0, signf(front))
	var front_r: Vector3 = Vector3.UP.cross(front_n)
	var front_bays: int = maxi(1, int((w - 1.0) / WIN_BAY))
	var door_bay: int = front_bays / 2
	var door_x: float = _door_offset(w)

	var floors: int = int((h - base) / STOREY)
	var sides: Array[Vector3] = [Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, -1.0), Vector3(-1.0, 0.0, 0.0)]
	for normal: Vector3 in sides:
		var across: bool = absf(normal.z) > 0.5
		var span: float = w if across else d
		var out: float = (d if across else w) * 0.5 + WIN_PROUD
		var right: Vector3 = Vector3.UP.cross(normal)
		var is_front: bool = across and is_equal_approx(normal.z, front_n.z)

		var bays: int = maxi(1, int((span - 1.0) / WIN_BAY))
		var pitch: float = span / float(bays)
		if pitch < WIN_W + 0.6:
			continue

		for f in floors:
			var y: float = base + STOREY * float(f) + WIN_SILL + WIN_H * 0.5
			if y + WIN_H * 0.5 > h - 0.3:
				break
			for b in bays:
				if is_front and f == 0 and b == door_bay and base <= 0.01:
					continue
				# A wall with every pane in place reads as an office block. A few
				# missing is what makes it a house.
				if _rng.randf() < 0.09:
					continue
				var cx: float = -span * 0.5 + pitch * (float(b) + 0.5)
				var centre: Vector3 = normal * out + right * cx + Vector3(0.0, y, 0.0)
				_pane(verts, norms, tris, 0, centre, right, normal,
					WIN_W * 0.5 + 0.11, WIN_H * 0.5 + 0.11)
				var glass: int = 2 if _rng.randf() < LIT_SHARE else 1
				_pane(verts, norms, tris, glass, centre + normal * 0.014, right, normal,
					WIN_W * 0.5, WIN_H * 0.5)

	# Shop display glass: one long pane either side of the door, filling the
	# painted band. A shopfront that is only a colour reads as a painted wall.
	if shopfront:
		var band: float = w * 0.45
		var gap: float = DOOR_W * 0.5 + 0.28
		for span_pair: Array in [[-band, door_x - gap], [door_x + gap, band]]:
			var lo: float = span_pair[0]
			var hi: float = span_pair[1]
			if hi - lo < 0.9:
				continue
			var centre_x: float = (lo + hi) * 0.5
			var mid: Vector3 = front_n * (d * 0.5 + door_skin + WIN_PROUD) + front_r * centre_x + Vector3(0.0, 1.78, 0.0)
			_pane(verts, norms, tris, 0, mid, front_r, front_n, (hi - lo) * 0.5, 0.98)
			_pane(verts, norms, tris, 1, mid + front_n * 0.014, front_r, front_n,
				(hi - lo) * 0.5 - 0.12, 0.86)

	# The door leaf is a real box, not a quad: it takes its own paint, and it is
	# the one piece of a house worth being able to find by name in the editor.
	var door_face: float = d * 0.5 + door_skin
	if w > DOOR_W + 0.6:
		_box(host, "Door", front_n * (door_face + 0.06) + front_r * door_x
			+ Vector3(0.0, DOOR_H * 0.5, 0.0), Vector3(DOOR_W, DOOR_H, 0.12),
			_door_mats[_rng.randi() % _door_mats.size()])
		_pane(verts, norms, tris, 0,
			front_n * (door_face + WIN_PROUD) + front_r * door_x
			+ Vector3(0.0, DOOR_H * 0.5 + 0.07, 0.0),
			front_r, front_n, DOOR_W * 0.5 + 0.14, DOOR_H * 0.5 + 0.07)
		# Doorstep: a flat trim quad on the ground, which is what tells the eye
		# the door is a way in rather than a panel.
		_pane(verts, norms, tris, 0,
			front_n * (door_face + 0.58) + front_r * door_x + Vector3(0.0, 0.05, 0.0),
			front_r, Vector3.UP, DOOR_W * 0.5 + 0.34, 0.56)

	var mesh := ArrayMesh.new()
	var mats: Array[StandardMaterial3D] = [_trim_for(wall), _glass_mat, _glass_lit_mat]
	for si in 3:
		if verts[si].is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts[si]
		arrays[Mesh.ARRAY_NORMAL] = norms[si]
		arrays[Mesh.ARRAY_INDEX]  = tris[si]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mats[si])
	if mesh.get_surface_count() == 0:
		return

	var mi := MeshInstance3D.new()
	mi.name = "Windows"
	mi.mesh = mesh
	host.add_child(mi)


## One quad appended to surface `surf`, wound clockwise seen from the normal
## side — Godot's front-face order. `right` is passed in rather than derived
## because a flat quad (the doorstep) has an UP normal, and UP.cross(UP) is
## nothing.
func _pane(verts: Array[PackedVector3Array], norms: Array[PackedVector3Array],
		tris: Array[PackedInt32Array], surf: int, centre: Vector3,
		right: Vector3, normal: Vector3, hw: float, hh: float) -> void:
	var up: Vector3 = normal.cross(right)
	var base: int = verts[surf].size()
	verts[surf].append(centre - right * hw + up * hh)
	verts[surf].append(centre + right * hw + up * hh)
	verts[surf].append(centre + right * hw - up * hh)
	verts[surf].append(centre - right * hw - up * hh)
	for _i in 4:
		norms[surf].append(normal)
	tris[surf].append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## Pale trim on a dark wall, dark trim on a pale one. A cream frame on a cream
## house is a frame nobody can see.
func _trim_for(wall: Color) -> StandardMaterial3D:
	var luma: float = wall.r * 0.299 + wall.g * 0.587 + wall.b * 0.114
	return _trim_dark_mat if luma > 0.60 else _trim_pale_mat


# ── Building meshes ──────────────────────────────────────────────────────────
# Walls, roofs, parapets and chimneys with real UVs, in place of scaled unit
# boxes and a PrismMesh. A scaled box stretches its texture with the building —
# a nine-metre wall and a chimney would carry the same number of bricks. These
# are laid out in METRES, so a brick is one size everywhere in town.
#
# Every building gets its own meshes, like its Windows already do: the sizes
# are all different, so there is nothing to share.

## One surface of a mesh under construction.
class Surf:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var tris := PackedInt32Array()

	## A flat convex polygon facing `normal`, wound to Godot's front face whatever
	## order the corners come in. The pieces here are built from every direction,
	## and winding each by hand is how a wall ends up invisible from the street.
	func face(pts: PackedVector3Array, tex: PackedVector2Array, normal: Vector3,
			shade: Color = Color.WHITE) -> void:
		var base: int = verts.size()
		var area := Vector3.ZERO
		for k in pts.size():
			verts.append(pts[k])
			norms.append(normal)
			uvs.append(tex[k])
			cols.append(shade)
			area += pts[k].cross(pts[(k + 1) % pts.size()])
		# Godot's front face is clockwise seen from outside, which makes the
		# right-handed normal of a front-facing polygon point AWAY from the
		# viewer. Corners that came in the other way round get flipped.
		var flip: bool = area.dot(normal) > 0.0
		for k in range(1, pts.size() - 1):
			if flip:
				tris.append_array(PackedInt32Array([base, base + k + 1, base + k]))
			else:
				tris.append_array(PackedInt32Array([base, base + k, base + k + 1]))

	## Adds this surface to `mesh`. Textured surfaces get tangents, without which
	## a normal map has no idea which way is up; flat ones skip the work.
	func commit(mesh: ArrayMesh, mat: Material, textured: bool, shaded: bool = false) -> void:
		if tris.is_empty():
			return
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		if shaded:
			arrays[Mesh.ARRAY_COLOR] = cols
		arrays[Mesh.ARRAY_INDEX] = tris
		if textured:
			var st := SurfaceTool.new()
			st.create_from_arrays(arrays)
			st.generate_tangents()
			st.set_material(mat)
			st.commit(mesh)
			return
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


const _NO_UV: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]


func _mesh_node(parent: Node3D, piece_name: String, mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = piece_name
	mi.mesh = mesh
	parent.add_child(mi)
	return mi


## The four walls of a w × d footprint as [outward normal, span], in the order
## the perimeter is walked: each wall's right-hand end is the next one's left.
## The same order _facade lays its windows out in.
static func _sides(w: float, d: float) -> Array:
	return [[Vector3(0.0, 0.0, 1.0), w], [Vector3(1.0, 0.0, 0.0), d],
		[Vector3(0.0, 0.0, -1.0), w], [Vector3(-1.0, 0.0, 0.0), d]]


## Where the texture starts along each wall, and how much of it a metre of wall
## covers: [u at the wall's left end, u per metre].
##
## Plain metres, walked on round the corners so the bond carries round them —
## for everything except concrete. Concrete comes in panels, and a joint
## through the middle of a window is the one thing about a precast front that
## looks wrong at a glance. So a concrete wall with windows is stretched to put
## exactly one panel on every bay, and the joints land between the windows the
## way a real one is drawn. `u0` must then be a whole number of panels.
static func _wall_runs(w: float, d: float, u0: float, panel: float) -> Array:
	var runs: Array = []
	var walked: float = u0
	for side: Array in _sides(w, d):
		var span: float = side[1]
		# Exactly _facade's bay arithmetic — the panels have to find its windows.
		var bays: int = maxi(1, int((span - 1.0) / WIN_BAY))
		var pitch: float = span / float(bays)
		if panel > 0.0 and pitch >= WIN_W + 0.6:
			runs.append([u0, panel / pitch])
		else:
			runs.append([walked, 1.0])
		walked += span
	return runs


## Texture V for a height on a wall. Up the image is up the wall, and each floor
## line of the window grid falls on an edge of the tile — which is where the
## generator puts the things that belong at floor level: the stone string
## course, the joints between concrete panels. `lift` is 0 or one STOREY, and
## picks which of the tile's two storeys goes on the ground floor.
static func _wall_v(y: float, base: float, lift: float) -> float:
	return -(y - base) - lift


static func _is_gable_end(normal: Vector3, along_x: bool) -> bool:
	return absf(normal.x) > 0.5 if along_x else absf(normal.z) > 0.5


## The gable under a pitched roof, as points along the wall (x, from its left
## end) and up it (y). It meets the roof's UNDERSIDE, a fascia's depth below the
## tiles. On a shallow roof the underside dips below the wall top before it
## reaches the corners, and the gable is then a triangle standing on the wall
## rather than a pentagon rising out of it.
static func _gable_outline(span: float, h: float, ridge: float) -> PackedVector2Array:
	var half: float = span * 0.5
	var reach: float = half + EAVE
	var apex: float = h + ridge - FASCIA
	var at_corner: float = h + ridge * (1.0 - half / reach) - FASCIA
	if at_corner > h:
		return PackedVector2Array([Vector2(0.0, h), Vector2(span, h),
			Vector2(span, at_corner), Vector2(half, apex), Vector2(0.0, at_corner)])
	var foot: float = reach * (1.0 - FASCIA / ridge)
	return PackedVector2Array([Vector2(half - foot, h), Vector2(half + foot, h),
		Vector2(half, apex)])


## A building's walls: four sides, the darker plinth along their foot, a top,
## and — under a pitched roof — the two gable ends, which are simply more wall.
##
## `base` is where the window grid starts (see _wall_v). `gable` is empty for a
## flat-topped building, or {"ridge", "along_x"} describing the roof above.
func _walls_mesh(w: float, h: float, d: float, mat: Material, runs: Array,
		base: float, lift: float, plinth: float, gable: Dictionary = {}) -> ArrayMesh:
	var s := Surf.new()
	var sides: Array = _sides(w, d)
	var dark := Color(PLINTH_SHADE, PLINTH_SHADE, PLINTH_SHADE)
	var bands: Array = [[0.0, h, Color.WHITE]]
	if plinth > 0.0:
		# Two faces meeting at the plinth line, not one with a gradient: the
		# shade has to change on a crisp line, like a course of different brick.
		bands = [[0.0, plinth, dark], [plinth, h, Color.WHITE]]

	for k in sides.size():
		var n: Vector3 = sides[k][0]
		var span: float = sides[k][1]
		var right: Vector3 = Vector3.UP.cross(n)
		var left: Vector3 = n * ((d if absf(n.z) > 0.5 else w) * 0.5) - right * (span * 0.5)
		var u_at: float = float(runs[k][0])
		var u_end: float = u_at + span * float(runs[k][1])
		for band: Array in bands:
			var y0: float = band[0]
			var y1: float = band[1]
			var v0: float = _wall_v(y0, base, lift)
			var v1: float = _wall_v(y1, base, lift)
			s.face(PackedVector3Array([left + Vector3.UP * y0, left + right * span + Vector3.UP * y0,
					left + right * span + Vector3.UP * y1, left + Vector3.UP * y1]),
				PackedVector2Array([Vector2(u_at, v0), Vector2(u_end, v0),
					Vector2(u_end, v1), Vector2(u_at, v1)]), n, band[2])

		if not gable.is_empty() and _is_gable_end(n, bool(gable["along_x"])):
			var pts := PackedVector3Array()
			var tex := PackedVector2Array()
			for p: Vector2 in _gable_outline(span, h, float(gable["ridge"])):
				pts.append(left + right * p.x + Vector3.UP * p.y)
				tex.append(Vector2(u_at + p.x * float(runs[k][1]), _wall_v(p.y, base, lift)))
			s.face(pts, tex, n)

	# A top, for when a roof overhead fades out or a parapet gets deleted in the
	# editor: an open box looks broken, a flat top just looks flat.
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	s.face(PackedVector3Array([Vector3(-hw, h, -hd), Vector3(hw, h, -hd),
			Vector3(hw, h, hd), Vector3(-hw, h, hd)]),
		PackedVector2Array([Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd),
			Vector2(-hw, hd)]), Vector3.UP)

	var mesh := ArrayMesh.new()
	s.commit(mesh, mat, true, true)
	return mesh


## A pitched roof as a thin slab rather than a solid wedge.
##
## The PrismMesh this replaces closed its own ends in roof colour, so every
## house wore a roof-coloured triangle over its gable wall. As a slab, the ends
## are left to the gables in _walls_mesh, and the slab's edge becomes a fascia:
## a line in the trim colour round every roof, which is what separates a roof
## from its walls from above when both are the same warm brown.
##
## The outline is the old prism's — EAVE past the walls all round, the eaves at
## wall-top height, the ridge `ridge` above them. Courses run along the ridge,
## and V is measured up the slope from the eave, so the eave gets a whole course.
func _roof_mesh(w: float, d: float, h: float, ridge: float, along_x: bool,
		tiles: Material, trim: Material, u0: float) -> ArrayMesh:
	var along: Vector3 = Vector3(1.0, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, 1.0)
	var across: Vector3 = Vector3(0.0, 0.0, 1.0) if along_x else Vector3(1.0, 0.0, 0.0)
	var reach: float = (d if along_x else w) * 0.5 + EAVE
	var run: float = (w if along_x else d) * 0.5 + EAVE
	var slope: float = Vector2(reach, ridge).length()
	var drop: Vector3 = Vector3.UP * FASCIA
	var crest: Vector3 = Vector3.UP * (h + ridge)
	var no_uv := PackedVector2Array(_NO_UV)

	var top := Surf.new()
	var edge := Surf.new()
	for side: float in [-1.0, 1.0]:
		var eave: Vector3 = across * (side * reach) + Vector3.UP * h
		var n: Vector3 = (Vector3.UP * reach + across * (side * ridge)).normalized()
		var e0: Vector3 = eave - along * run
		var e1: Vector3 = eave + along * run
		var c0: Vector3 = crest - along * run
		var c1: Vector3 = crest + along * run
		top.face(PackedVector3Array([e0, e1, c1, c0]),
			PackedVector2Array([Vector2(u0 - run, 0.0), Vector2(u0 + run, 0.0),
				Vector2(u0 + run, -slope), Vector2(u0 - run, -slope)]), n)
		# The underside. Only ever seen from low down, but a roof you can see
		# the sky through from the pavement is worse than one more quad.
		edge.face(PackedVector3Array([e0 - drop, e1 - drop, c1 - drop, c0 - drop]), no_uv, -n)
		# Fascia along the eave.
		edge.face(PackedVector3Array([e0 - drop, e1 - drop, e1, e0]), no_uv, across * side)
		# The slab's cut ends over each gable — the verges.
		for end: float in [-1.0, 1.0]:
			var ev: Vector3 = eave + along * (end * run)
			var cv: Vector3 = crest + along * (end * run)
			edge.face(PackedVector3Array([ev, cv, cv - drop, ev - drop]), no_uv, along * end)

	var mesh := ArrayMesh.new()
	top.commit(mesh, tiles, true)
	edge.commit(mesh, trim, false)
	return mesh


## A shop's flat roof: a parapet round a deck sunk below it, instead of one solid
## slab. From above that is a pale rim round every shop with the roof inside
## it, and a low sun lays a shadow along the inside of the rim — most of what
## makes a flat roof read as a roof rather than the lid of a box.
func _parapet_mesh(w: float, d: float, h: float, coping: Material, deck: Material,
		u0: float) -> ArrayMesh:
	var ow: float = w * 0.5 + PARAPET_LIP
	var od: float = d * 0.5 + PARAPET_LIP
	var iw: float = ow - COPING_W
	var id: float = od - COPING_W
	var cap_y: float = h + PARAPET_H
	var deck_y: float = cap_y - DECK_DROP
	var up := Vector3.UP
	# Walked round in the same order as the walls, so the outside face's
	# texture carries round the corners.
	var outer: Array[Vector3] = [Vector3(-ow, 0.0, od), Vector3(ow, 0.0, od),
		Vector3(ow, 0.0, -od), Vector3(-ow, 0.0, -od)]
	var inner: Array[Vector3] = [Vector3(-iw, 0.0, id), Vector3(iw, 0.0, id),
		Vector3(iw, 0.0, -id), Vector3(-iw, 0.0, -id)]

	var rim := Surf.new()
	var walked: float = u0
	for k in 4:
		var a: Vector3 = outer[k]
		var b: Vector3 = outer[(k + 1) % 4]
		var ia: Vector3 = inner[k]
		var ib: Vector3 = inner[(k + 1) % 4]
		var n: Vector3 = (b - a).cross(up).normalized()
		var span: float = a.distance_to(b)
		var inset: float = ia.distance_to(ib)
		# Outside, from the wall top up to the cap.
		rim.face(PackedVector3Array([a + up * h, b + up * h, b + up * cap_y, a + up * cap_y]),
			PackedVector2Array([Vector2(walked, 0.0), Vector2(walked + span, 0.0),
				Vector2(walked + span, -PARAPET_H), Vector2(walked, -PARAPET_H)]), n)
		# The cap itself.
		rim.face(PackedVector3Array([a + up * cap_y, b + up * cap_y, ib + up * cap_y, ia + up * cap_y]),
			PackedVector2Array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(ib.x, ib.z),
				Vector2(ia.x, ia.z)]), up)
		# Inside, from the cap down to the deck, facing in.
		rim.face(PackedVector3Array([ia + up * deck_y, ib + up * deck_y, ib + up * cap_y, ia + up * cap_y]),
			PackedVector2Array([Vector2(walked, 0.0), Vector2(walked + inset, 0.0),
				Vector2(walked + inset, -DECK_DROP), Vector2(walked, -DECK_DROP)]), -n)
		walked += span

	var floor_s := Surf.new()
	var deck_pts := PackedVector3Array()
	var deck_uv := PackedVector2Array()
	for p: Vector3 in inner:
		deck_pts.append(p + up * deck_y)
		deck_uv.append(Vector2(p.x + u0, p.z))
	floor_s.face(deck_pts, deck_uv, up)

	var mesh := ArrayMesh.new()
	rim.commit(mesh, coping, true)
	floor_s.commit(mesh, deck, true)
	return mesh


## Where one building's textures start, so two houses in the same brick are not
## the same wall twice. Drawn from _skin_rng, never _rng — see there.
func _skin_start(skin: String) -> Dictionary:
	var panel: float = CONCRETE_PANEL if skin == "concrete" else 0.0
	var u0: float = _skin_rng.randf_range(0.0, 6.3)
	if panel > 0.0:
		u0 = panel * float(_skin_rng.randi_range(0, 2))
	var lift: float = STOREY * float(_skin_rng.randi_range(0, 1))
	var roof_u0: float = _skin_rng.randf_range(0.0, 4.2)
	var chimney_u0: float = _skin_rng.randf_range(0.0, 6.3)
	return {"u0": u0, "panel": panel, "lift": lift, "roof_u0": roof_u0,
		"chimney_u0": chimney_u0}


func _build_ground(center: Vector3, radius: float) -> void:
	var ground := MeshInstance3D.new()
	ground.name = "GroundPlane"
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius * 2.6, radius * 2.6)
	ground.mesh = plane
	ground.material_override = _flat_mat(GROUND_COL)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Well below the streets. At 2 cm the two surfaces z-fought over the whole
	# map and the city came out under a grey haze.
	ground.position = center + Vector3(0.0, -ROAD_DROP - 0.6, 0.0)
	_ground_root.add_child(ground)


## Every street in the network, drawn as a quad, plus a patch at each junction
## to fill the wedge the quads leave between them.
func _build_streets(center: Vector3, radius: float) -> void:
	# Every dash and crossing stripe in town, as one mesh. They used to be a box
	# node each — a hundred and more draw calls for paint.
	var marks := Surf.new()
	var paint_y: float = -ROAD_DROP + 0.021

	for ei in _roads.edges.size():
		var e: Vector2i = _roads.edges[ei]
		var a: Vector3 = _roads.points[e.x]
		var b: Vector3 = _roads.points[e.y]
		if Vector2(a.x - center.x, a.z - center.z).length() > radius + StoryRoads.PITCH:
			continue

		var along: Vector3 = (b - a)
		along.y = 0.0
		var length: float = along.length()
		if length < 0.5:
			continue
		along /= length
		var side := Vector3(-along.z, 0.0, along.x) * _roads.half_width(ei)
		var avenue: bool = _roads.major[ei] == 1

		# Streets overlap wherever they meet, and two coplanar quads z-fight into
		# a stair-stepped mess. A few millimetres of separation per street is
		# invisible from map height and enough to settle it.
		_slab(_road_root, "Street_%d" % ei,
			PackedVector3Array([a - side, b - side, b + side, a + side]),
			-ROAD_DROP + float(ei % 3) * 0.005, _road_mat if avenue else _lane_mat)

		if not avenue:
			continue
		var across: Vector3 = side.normalized()
		# Centre dashes, stopping short of both junctions.
		var step: float = 9.0
		var runs: int = int((length - 16.0) / step)
		for k in maxi(runs, 0):
			var t: float = 8.0 + step * (float(k) + 0.5)
			_paint(marks, a + along * t, along, across, 3.6, 0.35, paint_y)

		# A zebra across the mouth of every junction the avenue meets — a real
		# junction, three streets or more, not a bend. From the map camera these
		# are the one road marking bold enough to read, and they say "town" in a
		# way a centre line does not.
		for end in 2:
			var at_point: int = e.x if end == 0 else e.y
			if (_roads.adjacency[at_point] as Array).size() < 3:
				continue
			var from: Vector3 = a if end == 0 else b
			var into: Vector3 = along if end == 0 else -along
			var start: float = _junction_radius(at_point) + 1.2
			if start + ZEBRA_DEPTH > length * 0.5 - 1.0:
				continue
			var stripes: int = int((_roads.half_width(ei) - 0.6) / ZEBRA_STRIPE)
			var span: float = float(stripes * 2 - 1) * ZEBRA_STRIPE
			for sn in stripes:
				var off: float = -span * 0.5 + ZEBRA_STRIPE * (0.5 + 2.0 * float(sn))
				_paint(marks, from + into * (start + ZEBRA_DEPTH * 0.5) + across * off,
					into, across, ZEBRA_DEPTH, ZEBRA_STRIPE, paint_y)

	# Junction fillets. A DISC, sized to the widest street actually meeting at
	# that corner — the first pass used an avenue-sized square, which at a
	# junction of two narrow lanes meeting at an angle jutted out over the
	# pavement and stair-stepped against the streets it was supposed to join.
	# A disc can never reach further than its own radius in any direction, and
	# sitting just above the streets it covers their seams instead of fighting
	# them.
	for pi in _roads.points.size():
		var p: Vector3 = _roads.points[pi]
		if Vector2(p.x - center.x, p.z - center.z).length() > radius + StoryRoads.PITCH:
			continue
		var links: Array = _roads.adjacency[pi]
		if links.is_empty():
			continue
		var w: float = _junction_radius(pi)
		var avenue_here: bool = false
		for link: Array in links:
			if _roads.major[int(link[1])] == 1:
				avenue_here = true

		# A flat polygon in world space, like the streets, so the asphalt runs
		# straight through the junction with no seam. Its top a few millimetres
		# over the highest street, no more: it used to be a disc four
		# centimetres proud, invisible on flat grey and a visible curved step
		# once the asphalt had texture to catch the light.
		var ring := PackedVector3Array()
		for s in 14:
			var ang: float = TAU * float(s) / 14.0
			ring.append(p + Vector3(cos(ang), 0.0, sin(ang)) * w)
		_slab(_road_root, "Junction_%d" % pi, ring, -ROAD_DROP + 0.015,
			_road_mat if avenue_here else _lane_mat)

	var paint := ArrayMesh.new()
	marks.commit(paint, _marking_mat, false)
	_flat_node(self, "Markings", paint)


## Radius of the fillet disc at a junction: the widest street meeting there.
func _junction_radius(point: int) -> float:
	var w: float = 0.0
	for link: Array in (_roads.adjacency[point] as Array):
		w = maxf(w, _roads.half_width(int(link[1])))
	return w


## One painted rectangle on the carriageway: `length` along `dir`, `width` across.
static func _paint(s: Surf, centre: Vector3, dir: Vector3, across: Vector3,
		length: float, width: float, y: float) -> void:
	var c := Vector3(centre.x, y, centre.z)
	var l: Vector3 = dir * (length * 0.5)
	var w: Vector3 = across * (width * 0.5)
	s.face(PackedVector3Array([c - l - w, c + l - w, c + l + w, c - l + w]),
		PackedVector2Array(_NO_UV), Vector3.UP)


func _build_blocks(center: Vector3, radius: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> void:
	var span: int = _roads.slot_span()

	for i in range(-span, span):
		for j in range(-span, span):
			var quad: PackedVector3Array = _roads.buildable_quad(i, j)
			if quad.size() < 4:
				continue
			var mid: Vector3 = _centroid(quad)
			var from_center: float = Vector2(mid.x - center.x, mid.z - center.z).length()
			if from_center > radius:
				continue
			if not _within_view_band(mid, keep_clear):
				continue

			var block := Node3D.new()
			block.name = "Block_%d_%d" % [i, j]
			block.position = mid
			_block_root.add_child(block)
			_block_count += 1

			var local := PackedVector3Array()
			for p: Vector3 in quad:
				local.append(p - mid)
			# Kerb and pavement now; what fills the middle is up to the block
			# kind, which _fill_block has not decided yet.
			_ground = _block_ground(i, j, mid, local)
			_build_block_edge(block)

			# What is already standing on this block. Filled in by whatever fills
			# the block, then read by the kerb — a tree planted at the kerb line
			# was landing inside the shopfront of a terrace set one metre back.
			var taken: Array[Dictionary] = []
			_kerb_trees = PackedVector3Array()
			_bays = {}
			_fill_block(block, mid, local, from_center, radius, keep_clear, paths, taken)
			_build_kerbside(block, mid, local, keep_clear, paths, taken)
			_build_streetlights(block, mid, keep_clear, paths, i + j)


## Where a block's ground actually is, worked out from the street network.
##
## The buildable quad is only an approximation — corners pulled in along their
## diagonals — and it stops about a metre short of the carriageway. So the kerb
## is built from the cell itself: each side offset inward by exactly the
## half-width of ITS street, the sides meeting wherever those offsets cross. That
## lands the kerb on the road's edge all the way round, corners included. A side
## with no street is not offset at all, so a merged block runs straight into its
## neighbour with no seam.
##
## Returns {"ok", "kerb", "back" (behind the kerbstone), "inner" (inside the
## pavement), "streets" (edge index per side, -1 for none)} in block-local
## space. If any of that comes out folded — a narrow cell between wide streets —
## "ok" is false and "inner" is the old buildable quad, so the block still gets
## a ground, just not a pavement.
func _block_ground(i: int, j: int, mid: Vector3, fallback: PackedVector3Array) -> Dictionary:
	var out := {"ok": false, "inner": fallback, "streets": PackedInt32Array([-1, -1, -1, -1])}
	var cell: PackedVector3Array = _roads.cell_corners(i, j)
	if cell.size() != 4:
		return out
	var streets := PackedInt32Array()
	var to_kerb := PackedFloat32Array()
	var to_back := PackedFloat32Array()
	var to_inner := PackedFloat32Array()
	for k in 4:
		var e: int = _roads.side_edge(i, j, k)
		streets.append(e)
		to_kerb.append(_roads.half_width(e) if e >= 0 else 0.0)
		to_back.append(KERB_W if e >= 0 else 0.0)
		to_inner.append(KERB_W + PAVE_W if e >= 0 else 0.0)
	var flat := PackedVector3Array()
	for p: Vector3 in cell:
		flat.append(Vector3(p.x, 0.0, p.z))
	var kerb: PackedVector3Array = _offset_poly(flat, to_kerb)
	var back: PackedVector3Array = _offset_poly(kerb, to_back)
	var inner: PackedVector3Array = _offset_poly(kerb, to_inner)
	if not (_same_shape(flat, kerb) and _same_shape(flat, back) and _same_shape(flat, inner)):
		return out

	var to_local := func(poly: PackedVector3Array) -> PackedVector3Array:
		var l := PackedVector3Array()
		for p: Vector3 in poly:
			l.append(Vector3(p.x - mid.x, 0.0, p.z - mid.z))
		return l
	return {"ok": true, "kerb": to_local.call(kerb), "back": to_local.call(back),
		"inner": to_local.call(inner), "streets": streets}


## Moves each side of a convex polygon inward by its own distance, and returns
## the corners where the moved sides now meet.
static func _offset_poly(poly: PackedVector3Array, insets: PackedFloat32Array) -> PackedVector3Array:
	var n: int = poly.size()
	var turn: float = signf(_signed_area(poly))
	var starts: Array[Vector2] = []
	var dirs: Array[Vector2] = []
	for k in n:
		var a := Vector2(poly[k].x, poly[k].z)
		var b := Vector2(poly[(k + 1) % n].x, poly[(k + 1) % n].z)
		var d: Vector2 = (b - a).normalized()
		starts.append(a + Vector2(-d.y, d.x) * turn * insets[k])
		dirs.append(d)
	var out := PackedVector3Array()
	for k in n:
		var prev: int = (k + n - 1) % n
		var denom: float = dirs[prev].cross(dirs[k])
		var p: Vector2 = starts[k]
		if absf(denom) > 0.0001:
			p = starts[prev] + dirs[prev] * ((starts[k] - starts[prev]).cross(dirs[k]) / denom)
		out.append(Vector3(p.x, 0.0, p.y))
	return out


## True when `b` is still `a` pulled in — same winding, every side still
## pointing the way it did — rather than folded through itself.
static func _same_shape(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size():
		return false
	var sa: float = _signed_area(a)
	var sb: float = _signed_area(b)
	if signf(sa) != signf(sb) or absf(sb) < 25.0:
		return false
	for k in a.size():
		var da: Vector3 = a[(k + 1) % a.size()] - a[k]
		var db: Vector3 = b[(k + 1) % b.size()] - b[k]
		if db.length() < 0.05:
			continue
		if da.normalized().dot(db.normalized()) < 0.5:
			return false
	return true


## The kerb and pavement round a block, on the sides that have a street.
##
## Both are laid out ALONG each street: U runs down the kerb from its corner,
## V in from the road. That is what squares the paving flags to the kerb and
## puts the kerbstone joints across it, whichever way the street runs.
func _build_block_edge(block: Node3D) -> void:
	if not bool(_ground["ok"]):
		return
	var kerb: PackedVector3Array = _ground["kerb"]
	var back: PackedVector3Array = _ground["back"]
	var inner: PackedVector3Array = _ground["inner"]
	var streets: PackedInt32Array = _ground["streets"]
	var turn: float = signf(_signed_area(kerb))
	# Down past the carriageway, so the face closes the step to the road
	# whichever street it is — they sit a few millimetres apart.
	var drop := Vector3(0.0, -(ROAD_DROP + 0.03), 0.0)

	var paving := Surf.new()
	var stone := Surf.new()
	for k in kerb.size():
		if streets[k] < 0:
			continue
		var n: int = kerb.size()
		var a: Vector3 = kerb[k]
		var b: Vector3 = kerb[(k + 1) % n]
		var along: Vector3 = (b - a).normalized()
		var inward := Vector3(-along.z, 0.0, along.x) * turn
		var run: float = a.distance_to(b)
		var ba: Vector3 = back[k]
		var bb: Vector3 = back[(k + 1) % n]
		var ia: Vector3 = inner[k]
		var ib: Vector3 = inner[(k + 1) % n]

		stone.face(PackedVector3Array([a, b, bb, ba]), PackedVector2Array([
			Vector2(0.0, 0.0), Vector2(run, 0.0),
			_along_uv(bb, a, along, inward), _along_uv(ba, a, along, inward)]), Vector3.UP)
		stone.face(PackedVector3Array([a + drop, b + drop, b, a]), PackedVector2Array([
			Vector2(0.0, -drop.y), Vector2(run, -drop.y), Vector2(run, 0.0), Vector2(0.0, 0.0)]),
			-inward)
		paving.face(PackedVector3Array([ba, bb, ib, ia]), PackedVector2Array([
			_along_uv(ba, a, along, inward), _along_uv(bb, a, along, inward),
			_along_uv(ib, a, along, inward), _along_uv(ia, a, along, inward)]), Vector3.UP)

	var pave_mesh := ArrayMesh.new()
	paving.commit(pave_mesh, _pavement_mat, true)
	if pave_mesh.get_surface_count() > 0:
		_flat_node(block, "Pavement", pave_mesh)
	var kerb_mesh := ArrayMesh.new()
	stone.commit(kerb_mesh, _kerb_mat, true)
	if kerb_mesh.get_surface_count() > 0:
		_flat_node(block, "Kerb", kerb_mesh)


static func _along_uv(p: Vector3, origin: Vector3, along: Vector3, inward: Vector3) -> Vector2:
	return Vector2((p - origin).dot(along), (p - origin).dot(inward))


static func _centroid(poly: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for p: Vector3 in poly:
		c += p
	return c / float(poly.size())


## Picks what a block IS, then fills it. A town is not one repeated block type:
## mostly houses, shops toward the middle, greens and squares scattered through.
func _fill_block(block: Node3D, mid: Vector3, quad: PackedVector3Array,
		from_center: float, radius: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array], taken: Array[Dictionary]) -> void:
	var closeness: float = 1.0 - clampf(from_center / maxf(1.0, radius), 0.0, 1.0)
	var roll: float = _rng.randf()
	var world := PackedVector3Array()
	for p: Vector3 in quad:
		world.append(p + mid)

	if not _holds_a_rift(world, keep_clear):
		if roll < 0.14:
			_build_park(block, quad)
			return
		if roll < 0.20:
			_build_square(block, quad)
			return
	if roll < 0.20 + closeness * 0.40:
		_build_terrace(block, mid, quad, closeness, keep_clear, paths, taken)
		return
	_build_houses(block, mid, quad, closeness, keep_clear, paths, taken)


# ── Placing things inside an irregular block ─────────────────────────────────

## Rejection-samples a spot inside the block. Blocks are arbitrary quads now, so
## there is no neat row-and-column arithmetic to lay plots out with — asking for
## a point and testing whether it landed inside is both simpler and adapts to
## whatever shape the streets left behind.
func _spot_in(quad: PackedVector3Array, margin: float) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector3 in quad:
		lo.x = minf(lo.x, p.x); lo.y = minf(lo.y, p.z)
		hi.x = maxf(hi.x, p.x); hi.y = maxf(hi.y, p.z)

	for _try in 24:
		var c := Vector3(_rng.randf_range(lo.x, hi.x), 0.0, _rng.randf_range(lo.y, hi.y))
		if _inside(quad, c, margin):
			return {"ok": true, "pos": c}
	return {"ok": false, "pos": Vector3.ZERO}


## Point-in-convex-polygon, with a margin pulled in from every edge.
##
## The winding is measured rather than assumed. Corner order comes from the
## street graph, and once the intersections are jittered there is no guarantee
## which way round a block comes out — hard-coding one and testing the sign
## against it rejected every point in the town and left it with no buildings
## at all.
static func _inside(poly: PackedVector3Array, p: Vector3, margin: float) -> bool:
	var turn: float = signf(_signed_area(poly))
	if is_zero_approx(turn):
		return false
	for k in poly.size():
		var a: Vector3 = poly[k]
		var b: Vector3 = poly[(k + 1) % poly.size()]
		var edge := Vector2(b.x - a.x, b.z - a.z)
		var to := Vector2(p.x - a.x, p.z - a.z)
		var span: float = edge.length()
		if span < 0.001:
			continue
		if turn * (edge.x * to.y - edge.y * to.x) / span < margin:
			return false
	return true


static func _signed_area(poly: PackedVector3Array) -> float:
	var total: float = 0.0
	for k in poly.size():
		var a: Vector3 = poly[k]
		var b: Vector3 = poly[(k + 1) % poly.size()]
		total += a.x * b.z - b.x * a.z
	return total * 0.5


## The bearing of the block edge nearest a point — what a building on that plot
## should face. Houses turning to follow their own street is a large part of why
## the town stops looking like a grid once the streets stop being straight.
static func _edge_bearing(quad: PackedVector3Array, p: Vector3) -> float:
	var best: float = 0.0
	var best_d: float = INF
	for k in quad.size():
		var a: Vector3 = quad[k]
		var b: Vector3 = quad[(k + 1) % quad.size()]
		var q: Vector3 = StoryRoads._closest_on_segment(p, a, b)
		var d: float = Vector2(p.x - q.x, p.z - q.z).length_squared()
		if d < best_d:
			best_d = d
			best = atan2(b.x - a.x, b.z - a.z)
	return best


## The outward normal of the block edge nearest a point — the way a BUILDING on
## that plot should face. _edge_bearing gives the direction the same edge runs,
## which is what a bench or a parked car lines up with; a house needs the
## perpendicular, and pointing it outward is what puts its door on the street.
static func _edge_outward(quad: PackedVector3Array, p: Vector3) -> Vector3:
	var mid: Vector3 = _centroid(quad)
	var best := Vector3(0.0, 0.0, 1.0)
	var best_d: float = INF
	for k in quad.size():
		var a: Vector3 = quad[k]
		var b: Vector3 = quad[(k + 1) % quad.size()]
		var q: Vector3 = StoryRoads._closest_on_segment(p, a, b)
		var d: float = Vector2(p.x - q.x, p.z - q.z).length_squared()
		if d >= best_d:
			continue
		var along: Vector3 = b - a
		var n := Vector3(along.z, 0.0, -along.x)
		if n.length_squared() < 0.0001:
			continue
		best_d = d
		n = n.normalized()
		# Away from the middle of the block, whichever way the polygon is wound.
		if n.dot((a + b) * 0.5 - mid) < 0.0:
			n = -n
		best = n
	return best


## Where the front door sits along a building's front wall, measured from the
## middle. Shared by the facade that draws the door and by anything that has to
## leave a way through to it.
static func _door_offset(w: float) -> float:
	var bays: int = maxi(1, int((w - 1.0) / WIN_BAY))
	return -w * 0.5 + (w / float(bays)) * (float(bays / 2) + 0.5)


## The rotation.y that aims local +Z along `dir`.
static func _bearing_of(dir: Vector3) -> float:
	return atan2(dir.x, dir.z)


## True when a plot of `radius` at `at` would land on one already placed.
static func _overlaps(taken: Array[Dictionary], at: Vector3, radius: float,
		gap: float) -> bool:
	for t: Dictionary in taken:
		var p: Vector3 = t["pos"]
		if Vector2(at.x - p.x, at.z - p.z).length() < radius + float(t["radius"]) + gap:
			return true
	return false


# ── Block kinds ──────────────────────────────────────────────────────────────

## `taken` is the block's occupancy list — _is_clear only knows about rifts and
## routes, so nothing stopped the sampler dropping a second house inside the
## first, and a merged pair is far more obvious now that walls carry windows.
## More attempts than before, because some of them are now thrown away.
func _build_houses(block: Node3D, mid: Vector3, quad: PackedVector3Array, closeness: float,
		keep_clear: Array[Dictionary], paths: Array[PackedVector3Array],
		taken: Array[Dictionary]) -> void:
	# Back gardens and verges between the houses, where there used to be bare
	# pavement right across the block.
	_block_floor(block, mid, "Lawn", _yard_grass_mat)
	for _lot in _rng.randi_range(10, 16):
		var spot: Dictionary = _spot_in(quad, 5.2)
		if not spot["ok"]:
			continue
		var local: Vector3 = spot["pos"]
		var w: float = _rng.randf_range(7.0, 10.5)
		var d: float = _rng.randf_range(6.5, 9.0)
		if not _is_clear(mid + local, Vector2(w, d).length() * 0.5, keep_clear, paths):
			continue
		# Half the LONGER side rather than half the diagonal: the corners of two
		# neighbours may clip, which reads as a terrace, but their walls may not.
		var foot: float = maxf(w, d) * 0.45
		if _overlaps(taken, local, foot, 0.8):
			continue
		taken.append({"pos": local, "radius": foot})

		var lot := Node3D.new()
		lot.name = "House_%d" % _building_count
		lot.position = local
		# Local +Z faces the street, give or take a few degrees. This used to be
		# _edge_bearing, which is the direction the block edge RUNS — so every
		# house stood side-on to its own road, with the front hedge across the
		# garden instead of along it. Nothing looked wrong while the walls were
		# blank; a door on the flank would have been unmissable.
		var face: float = _bearing_of(_edge_outward(quad, local))
		lot.rotation.y = face + deg_to_rad(_rng.randf_range(-5.0, 5.0))
		block.add_child(lot)
		_building_count += 1

		_box(lot, "Garden", Vector3(0.0, 0.02, 0.0), Vector3(w * 1.24, 0.06, d * 1.30), _grass_mat)
		if _rng.randf() < 0.5:
			# Two runs with a gap at the door. One unbroken hedge across the
			# front was fine while the wall behind it was blank; with a door
			# there it is a house nobody can walk into.
			var gate: float = _door_offset(w)
			var half: float = w * 0.62
			for run: Array in [[-half, gate - 1.05], [gate + 1.05, half]]:
				var lo: float = run[0]
				var hi: float = run[1]
				if hi - lo < 0.6:
					continue
				_box(lot, "Hedge", Vector3((lo + hi) * 0.5, 0.35, d * 0.65),
					Vector3(hi - lo, 0.7, 0.4), _hedge_mat)
		_build_house(lot, w, d, _rng.randf_range(5.0, 8.5) + closeness * 2.5)
		if _rng.randf() < 0.45:
			_tree(lot, Vector3(w * _rng.randf_range(-0.6, 0.6), 0.0, -d * 0.7),
				_rng.randf_range(2.8, 4.2))


## One dwelling: walls, a pitched roof, a chimney. The pitch does the work — a
## flat parapet reads as a city block whatever colour it is painted.
##
## The walls are built AFTER the facade and the ridge now — the gables need the
## ridge — but every draw on _rng happens in exactly the order it always did.
## Reorder those and every house after this one moves.
func _build_house(lot: Node3D, w: float, d: float, h: float) -> void:
	var idx: int = _rng.randi() % _wall_mats.size()
	var style: Array = BUILDING_STYLES[idx]
	var wall_col: Color = style[0]
	var skin: Dictionary = _skin_start(String(style[2]))
	var walls_at: int = lot.get_child_count()
	_facade(lot, w, h, d, 1.0, 0.0, wall_col)

	var along_x: bool = w >= d
	var ridge: float = _rng.randf_range(1.8, 3.0)
	var walls := _mesh_node(lot, "Walls", _walls_mesh(w, h, d, _wall_mats[idx],
		_wall_runs(w, d, skin["u0"], skin["panel"]), 0.0, skin["lift"], PLINTH_H,
		{"ridge": ridge, "along_x": along_x}))
	# Back ahead of the door and windows in the editor tree, where it always was.
	lot.move_child(walls, walls_at)
	_mesh_node(lot, "Roof", _roof_mesh(w, d, h, ridge, along_x, _roof_mats[idx],
		_trim_for(wall_col), skin["roof_u0"]))

	if _rng.randf() < 0.55:
		# In the house's own wall. A red-brick stack on a cream house is what a
		# real one might have, but from map height it is a bright orange square
		# floating on the roof, and it pulls the eye off the rifts.
		var stack := _mesh_node(lot, "Chimney", _walls_mesh(0.7, 2.0, 0.7, _wall_mats[idx],
			_wall_runs(0.7, 0.7, skin["chimney_u0"], 0.0), 0.0, 0.0, 0.0))
		stack.position = Vector3(w * _rng.randf_range(-0.28, 0.28), h + ridge * 0.75 - 1.0, d * 0.18)


## A row of shops along one edge of the block, with a coloured front at street
## level — the one place a mundane town is allowed to be bright.
func _build_terrace(block: Node3D, mid: Vector3, quad: PackedVector3Array, closeness: float,
		keep_clear: Array[Dictionary], paths: Array[PackedVector3Array],
		taken: Array[Dictionary]) -> void:
	var side: int = _rng.randi() % quad.size()
	var a: Vector3 = quad[side]
	var b: Vector3 = quad[(side + 1) % quad.size()]
	var along: Vector3 = b - a
	var run: float = along.length()
	if run < 12.0:
		_build_houses(block, mid, quad, closeness, keep_clear, paths, taken)
		return
	along /= run
	var inward: Vector3 = (_centroid(quad) - (a + b) * 0.5).normalized()
	# Behind a row of shops: the service yard and the parking, in tarmac.
	_block_floor(block, mid, "Yard", _yard_mat)

	var units: int = clampi(int(run / 9.0), 2, 5)
	var unit_w: float = (run - 4.0) / float(units)
	var d: float = _rng.randf_range(8.0, 11.0)

	for i in units:
		var t: float = 2.0 + unit_w * (float(i) + 0.5)
		var local: Vector3 = a + along * t + inward * (d * 0.5 + 1.0)
		if not _inside(quad, local, 2.0):
			continue
		var w: float = unit_w * _rng.randf_range(0.84, 0.97)
		if not _is_clear(mid + local, Vector2(w, d).length() * 0.5, keep_clear, paths):
			continue

		var h: float = _rng.randf_range(8.0, 12.0) + closeness * 5.0
		taken.append({"pos": local, "radius": maxf(w, d) * 0.5})
		var idx: int = _rng.randi() % _wall_mats.size()
		var style: Array = BUILDING_STYLES[idx]
		var skin: Dictionary = _skin_start(String(style[2]))
		var unit := Node3D.new()
		unit.name = "Shop_%d" % _building_count
		unit.position = local
		# Local +Z points into the block, so the shopfront on local -Z faces the
		# road. It used to be the along-the-row bearing, which had every shop
		# showing its window to the back of the one beside it.
		unit.rotation.y = _bearing_of(inward)
		block.add_child(unit)
		_building_count += 1

		# Measured from where the glass starts, so the texture's floor lines sit
		# under the upper-floor windows rather than at pavement level.
		_mesh_node(unit, "Walls", _walls_mesh(w, h, d, _wall_mats[idx],
			_wall_runs(w, d, skin["u0"], skin["panel"]), SHOP_GLASS_BASE, skin["lift"],
			PLINTH_H))
		_box(unit, "Front", Vector3(0.0, 1.6, -d * 0.5 - 0.06),
			Vector3(w * 0.9, 3.2, 0.25), _shop_mats[_rng.randi() % _shop_mats.size()])
		# Glass starts above the painted band, and the door is pushed out past
		# the band's own thickness so it is not buried inside it.
		_facade(unit, w, h, d, -1.0, SHOP_GLASS_BASE, style[0] as Color, true, 0.20)
		_mesh_node(unit, "Parapet", _parapet_mesh(w, d, h, _coping_mat, _deck_mats[idx],
			skin["roof_u0"]))


## The ground inside the pavement. The block the plaza stands on is paved right
## across instead: it is the town square, not somebody's back garden or the
## yard behind the shops, and the plaza sitting in a car park said so.
func _block_floor(block: Node3D, mid: Vector3, floor_name: String,
		mat: StandardMaterial3D) -> void:
	var inner: PackedVector3Array = _ground["inner"]
	if _inside(inner, _hub_at - mid, 0.0):
		var first: Vector3 = inner[1] - inner[0]
		_slab(block, "Square", inner, 0.0, _pavement_mat, atan2(first.z, first.x))
		return
	_slab(block, floor_name, inner, 0.0, mat)


## A lawn, maybe a pond, and trees scattered over it. The paths, benches, beds
## and playground come later, in _dress_parks — see there for why.
func _build_park(block: Node3D, quad: PackedVector3Array) -> void:
	_slab(block, "Lawn", _ground["inner"], 0.0, _lawn_mat)

	var pond_at: Dictionary = {}
	var spot: Dictionary = _spot_in(quad, 4.0)
	if spot["ok"] and _rng.randf() < 0.4:
		var pond := MeshInstance3D.new()
		pond.name = "Pond"
		var disc := CylinderMesh.new()
		disc.top_radius      = _rng.randf_range(4.0, 6.5)
		disc.bottom_radius   = disc.top_radius
		disc.height          = 0.1
		disc.radial_segments = 24
		pond.mesh = disc
		pond.material_override = _water_mat
		pond.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pond.position = (spot["pos"] as Vector3) + Vector3(0.0, 0.06, 0.0)
		block.add_child(pond)
		# A dressed stone edge. Water meeting grass with nothing between reads as
		# a hole in the lawn from above; with a rim it is a pond someone built.
		var rim := MeshInstance3D.new()
		rim.name = "PondRim"
		var ring := CylinderMesh.new()
		ring.top_radius      = disc.top_radius + 0.55
		ring.bottom_radius   = ring.top_radius
		ring.height          = 0.08
		ring.radial_segments = 24
		rim.mesh = ring
		rim.material_override = _stone_mat
		rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rim.position = (spot["pos"] as Vector3) + Vector3(0.0, 0.03, 0.0)
		block.add_child(rim)
		pond_at = {"pos": spot["pos"], "radius": disc.top_radius + 0.55}

	for _t in _rng.randi_range(7, 13):
		var s: Dictionary = _spot_in(quad, 2.5)
		if s["ok"]:
			_tree(block, s["pos"], _rng.randf_range(3.4, 6.0))

	_parks.append({"block": block, "inner": _ground["inner"], "pond": pond_at,
		"streets": _ground["streets"]})


func _build_square(block: Node3D, quad: PackedVector3Array) -> void:
	# Flags true to the square's first side, the way it would have been laid.
	var first: Vector3 = quad[1] - quad[0]
	_slab(block, "Paving", _ground["inner"], 0.0, _pavement_mat, atan2(first.z, first.x))
	_slab(block, "Inlay", _shrink(quad, 7.0), 0.04, _path_mat)

	for i in 4:
		var s: Dictionary = _spot_in(quad, 5.0)
		if not s["ok"]:
			continue
		var bench := _box(block, "Bench_%d" % i, (s["pos"] as Vector3) + Vector3(0.0, 0.28, 0.0),
			Vector3(3.4, 0.5, 0.7), _bench_mat)
		bench.rotation.y = _edge_bearing(quad, s["pos"])
	for _t in _rng.randi_range(3, 5):
		var s2: Dictionary = _spot_in(quad, 3.0)
		if s2["ok"]:
			_tree(block, s2["pos"], _rng.randf_range(3.0, 4.4))


## Pulls a polygon in toward its centre by roughly `amount` metres.
static func _shrink(quad: PackedVector3Array, amount: float) -> PackedVector3Array:
	var mid: Vector3 = _centroid(quad)
	var out := PackedVector3Array()
	for p: Vector3 in quad:
		var dir: Vector3 = mid - p
		var d: float = dir.length()
		out.append(p + dir / maxf(d, 0.001) * minf(amount, d * 0.6))
	return out


## Street trees and parked cars along the block edge.
##
## The cars are the cheapest colour there is — a handful of small bright boxes
## per block, sitting where the eye already is, and they do more against a grey
## town than anything painted on the buildings.
func _build_kerbside(block: Node3D, mid: Vector3, quad: PackedVector3Array,
		keep_clear: Array[Dictionary], paths: Array[PackedVector3Array],
		taken: Array[Dictionary]) -> void:
	for k in quad.size():
		var a: Vector3 = quad[k]
		var b: Vector3 = quad[(k + 1) % quad.size()]
		var along: Vector3 = b - a
		var run: float = along.length()
		if run < 10.0:
			continue
		along /= run
		var inward: Vector3 = (_centroid(quad) - (a + b) * 0.5).normalized()
		var bearing: float = atan2(along.x, along.z)

		var count: int = clampi(int(run / 11.0), 1, 4)
		for i in count:
			var t: float = run * (float(i) + 0.5) / float(count) + _rng.randf_range(-2.5, 2.5)
			var at: Vector3 = a + along * clampf(t, 3.0, run - 3.0) + inward * 1.9
			if not _is_clear(mid + at, 2.2, keep_clear, paths):
				continue
			# A terrace stands one metre back from the kerb, so anything planted
			# on the kerb line ends up inside its display window.
			if _overlaps(taken, at, 1.7, 0.4):
				continue

			if _rng.randf() < 0.42:
				_tree(block, at, _rng.randf_range(3.2, 4.8))
				_kerb_trees.append(at)
				continue
			# Both draws happen whether or not the car is then placed: skipping
			# one would shift every building in every block after this one.
			var yaw: float = bearing + deg_to_rad(_rng.randf_range(-3.0, 3.0))
			var col: StandardMaterial3D = _car_mats[_rng.randi() % _car_mats.size()]
			var bay: Dictionary = _parking_bay(k, at)
			if bay.is_empty():
				continue
			var car := Node3D.new()
			car.name = "Car_%d_%d" % [k, i]
			car.position = bay["pos"]
			car.rotation.y = yaw
			block.add_child(car)
			_box(car, "Body", Vector3(0.0, 0.62, 0.0), Vector3(1.9, 1.05, 4.3), col)
			_box(car, "Cabin", Vector3(0.0, 1.35, -0.25), Vector3(1.7, 0.75, 2.1), col)


## Where a car picked at `at` actually parks: level with it, in the carriageway
## just off the kerb of side `k`, slid back along the kerb if that would put it
## in the mouth of a junction. Empty where that side has no street, or where
## the bay is already taken.
##
## These used to stand where they were picked — on the pavement, two metres in
## from where the kerb is now.
func _parking_bay(k: int, at: Vector3) -> Dictionary:
	if not bool(_ground["ok"]):
		return {"pos": at}
	var streets: PackedInt32Array = _ground["streets"]
	if streets[k] < 0:
		return {}
	var kerb: PackedVector3Array = _ground["kerb"]
	var a: Vector3 = kerb[k]
	var b: Vector3 = kerb[(k + 1) % kerb.size()]
	var run: float = a.distance_to(b)
	if run < PARK_CLEAR * 2.0 + PARK_PITCH:
		return {}
	var along: Vector3 = (b - a) / run
	var t: float = clampf((at - a).dot(along), PARK_CLEAR, run - PARK_CLEAR)
	var parked: PackedFloat32Array = _bays.get(k, PackedFloat32Array())
	for other: float in parked:
		if absf(other - t) < PARK_PITCH:
			return {}
	parked.append(t)
	_bays[k] = parked
	var out: Vector3 = Vector3(along.z, 0.0, -along.x) * signf(_signed_area(kerb))
	var pos: Vector3 = a + along * t + out * PARK_OUT
	return {"pos": Vector3(pos.x, -ROAD_DROP, pos.z)}


## A tree: trunk plus two offset canopy blocks. Two boxes rather than one makes
## the crown read as foliage instead of as a green cube.
func _tree(parent: Node3D, at: Vector3, height: float) -> void:
	var t := Node3D.new()
	# Numbered: a block full of siblings all called "Tree" got auto-renamed to
	# @Node3D@123 in the baked scene, which nobody can find in the editor.
	t.name = "Tree_%d" % _tree_count
	_tree_count += 1
	t.position = at
	t.rotation.y = _rng.randf_range(0.0, TAU)
	parent.add_child(t)

	var leaf: StandardMaterial3D = _leaf_mats[_rng.randi() % _leaf_mats.size()]
	var spread: float = height * _rng.randf_range(0.5, 0.72)
	_box(t, "Trunk", Vector3(0.0, height * 0.3, 0.0), Vector3(0.42, height * 0.6, 0.42), _trunk_mat)
	_box(t, "Crown", Vector3(0.0, height * 0.72, 0.0), Vector3(spread, height * 0.5, spread), leaf)
	_box(t, "CrownTop", Vector3(0.0, height * 0.95, 0.0),
		Vector3(spread * 0.62, height * 0.3, spread * 0.62), leaf)


# ── Dressing the parks ───────────────────────────────────────────────────────

## Paths, benches, flower beds and a fountain for every park, and a playground
## in one of them.
##
## Done once the whole town stands, not inside _build_park. The trees were
## scattered by _rng, and a path laid first would have had to steer round them
## or change how many there are — either of which changes what _rng hands out
## next and moves every building after it. Laid afterwards, the paths go where a
## park's paths belong, and the few trees standing in the way are taken out.
func _dress_parks() -> void:
	if _parks.is_empty():
		return
	# Nearest the plaza first: that park gets the playground if it has room —
	# Meeko starts at the plaza, so it is the one the player passes most.
	var order: Array = range(_parks.size())
	order.sort_custom(func(x: int, y: int) -> bool:
		return _park_distance(x) < _park_distance(y))
	var play_done: bool = false
	for n: int in order:
		var keep_out: Array = _dress_park(_parks[n])
		if not play_done:
			play_done = _place_playground(_parks[n], keep_out)
	if not play_done:
		print("[StoryCity] no park had room for the playground.")


func _park_distance(n: int) -> float:
	var at: Vector3 = (_parks[n]["block"] as Node3D).position
	return Vector2(at.x - _hub_at.x, at.z - _hub_at.z).length()


## Lays one park out and returns what the playground must stay clear of: a list
## of ["seg", a, b, clearance] and ["disc", centre, radius].
func _dress_park(park: Dictionary) -> Array:
	var block: Node3D = park["block"]
	var inner: PackedVector3Array = park["inner"]
	var streets: PackedInt32Array = park["streets"]
	var pond: Dictionary = park["pond"]
	var has_pond: bool = not pond.is_empty()
	var centre: Vector3 = (pond["pos"] as Vector3) if has_pond else _centroid(inner)
	centre.y = 0.0
	var shapes: Array = []

	# Every way in from a street walks to the middle: to a promenade round the
	# pond, or to a gravel round with a fountain on it.
	var ring_r: float = float(pond["radius"]) + 1.3 + PATH_W * 0.5 if has_pond else ROUND_R
	var gravel := Surf.new()
	var spokes: Array = []
	for k in inner.size():
		if streets[k] < 0:
			continue
		var gate: Vector3 = (inner[k] + inner[(k + 1) % inner.size()]) * 0.5
		var to_middle: Vector3 = centre - gate
		var dist: float = to_middle.length()
		if dist < ring_r + 3.0:
			continue
		var dir: Vector3 = to_middle / dist
		# Into the round by half a metre, or to the middle of the promenade.
		var end: Vector3 = centre - dir * (ring_r - (0.0 if has_pond else 0.5))
		_path_strip(gravel, gate - dir * 0.05, end)
		spokes.append([gate, end])
		shapes.append(["seg", gate, end, PATH_W * 0.5 + 0.4])

	if has_pond:
		var segs: int = 28
		for s in segs:
			var a0: float = TAU * float(s) / float(segs)
			var a1: float = TAU * float(s + 1) / float(segs)
			var mid_dir := Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5))
			# Only where it stays on the lawn: a pond near the edge of a park gets
			# a promenade round the side that has room, not one over the kerb.
			if not _inside(inner, centre + mid_dir * ring_r, PATH_W * 0.5 + 0.2):
				continue
			var p0 := Vector3(cos(a0), 0.0, sin(a0))
			var p1 := Vector3(cos(a1), 0.0, sin(a1))
			var lo: float = ring_r - PATH_W * 0.5
			var hi: float = ring_r + PATH_W * 0.5
			gravel.face(PackedVector3Array([centre + p0 * lo + Vector3.UP * 0.012,
				centre + p1 * lo + Vector3.UP * 0.012, centre + p1 * hi + Vector3.UP * 0.012,
				centre + p0 * hi + Vector3.UP * 0.012]), PackedVector2Array(_NO_UV), Vector3.UP)
		shapes.append(["disc", centre, ring_r + PATH_W * 0.5 + 0.5])
	else:
		var round_pts := PackedVector3Array()
		for s in 28:
			var ang: float = TAU * float(s) / 28.0
			round_pts.append(centre + Vector3(cos(ang), 0.0, sin(ang)) * ROUND_R + Vector3.UP * 0.012)
		var round_uv := PackedVector2Array()
		round_uv.resize(round_pts.size())
		gravel.face(round_pts, round_uv, Vector3.UP)
		_fountain(block, centre)
		shapes.append(["disc", centre, ROUND_R + 0.6])

	var paths := ArrayMesh.new()
	gravel.commit(paths, _path_mat, false)
	if paths.get_surface_count() > 0:
		_flat_node(block, "Paths", paths)

	# Benches beside each path, a little way in from the street, facing it.
	for spoke: Array in spokes:
		var gate: Vector3 = spoke[0]
		var end: Vector3 = spoke[1]
		var dir: Vector3 = (end - gate).normalized()
		var side := Vector3(-dir.z, 0.0, dir.x) * (1.0 if _prop_rng.randf() < 0.5 else -1.0)
		var at: Vector3 = gate.lerp(end, 0.45) + side * (PATH_W * 0.5 + 0.55)
		var bench := _box(block, "Bench", at + Vector3(0.0, 0.26, 0.0),
			Vector3(2.0, 0.42, 0.6), _bench_mat)
		bench.rotation.y = atan2(-dir.z, dir.x)
		shapes.append(["disc", at, 1.4])

	# Beds round the fountain, between the paths — the colour a park is for.
	if not has_pond:
		var angles: Array[float] = []
		for spoke: Array in spokes:
			var d: Vector3 = (spoke[0] as Vector3) - centre
			angles.append(atan2(d.z, d.x))
		angles.sort()
		if angles.size() < 2:
			angles = [0.0, PI * 0.5, PI, PI * 1.5]
		for n in angles.size():
			var a: float = angles[n]
			var b: float = angles[(n + 1) % angles.size()] + (TAU if n == angles.size() - 1 else 0.0)
			var mid_a: float = (a + b) * 0.5
			var at: Vector3 = centre + Vector3(cos(mid_a), 0.0, sin(mid_a)) * (ROUND_R + 2.3)
			if not _inside(inner, at, 2.0):
				continue
			_flower_bed(block, at, FLOWER_COLS[_prop_rng.randi() % FLOWER_COLS.size()])
			shapes.append(["disc", at, 2.0])

	# Take out whatever the new layout now runs through.
	var clear: Array = shapes.duplicate()
	if has_pond:
		clear.append(["disc", centre, float(pond["radius"]) + 0.8])
	_clear_trees(block, clear, 0.9)
	return shapes


## A gravel path from `a` to `b`, as one strip on the lawn.
static func _path_strip(s: Surf, a: Vector3, b: Vector3) -> void:
	var dir: Vector3 = (b - a).normalized()
	var w := Vector3(-dir.z, 0.0, dir.x) * (PATH_W * 0.5)
	var y := Vector3.UP * 0.012
	s.face(PackedVector3Array([a - w + y, b - w + y, b + w + y, a + w + y]),
		PackedVector2Array(_NO_UV), Vector3.UP)


## A stone basin with a pedestal and a little upper bowl, on the park's round.
func _fountain(block: Node3D, at: Vector3) -> void:
	var f := Node3D.new()
	f.name = "Fountain"
	f.position = at
	block.add_child(f)
	_disc(f, "Basin", 1.75, 0.5, 0.25, _stone_mat, 24)
	var water := _disc(f, "Water", 1.5, 0.1, 0.47, _water_mat, 24)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cylinder(f, "Pedestal", 0.26, 1.0, 0.9, _stone_mat, 12)
	_disc(f, "Bowl", 0.62, 0.14, 1.42, _stone_mat, 16)


func _flower_bed(block: Node3D, at: Vector3, col: Color) -> void:
	var bed := Node3D.new()
	bed.name = "FlowerBed"
	bed.position = at
	block.add_child(bed)
	_disc(bed, "Edging", 1.45, 0.16, 0.08, _stone_mat, 20)
	_disc(bed, "Flowers", 1.25, 0.3, 0.16, _skin_mat("foliage", col, _means, true), 20)


## Removes every tree on `block` standing inside one of `shapes`, or within
## `margin` of it. Used after the fact, so it costs _rng nothing.
func _clear_trees(block: Node3D, shapes: Array, margin: float) -> void:
	for child: Node in block.get_children():
		if not String(child.name).begins_with("Tree_"):
			continue
		var p: Vector3 = (child as Node3D).position
		p.y = 0.0
		for shape: Array in shapes:
			var hit: bool = false
			if shape[0] == "seg":
				hit = _point_to_segment(p, shape[1], shape[2]) < float(shape[3]) + margin
			else:
				hit = p.distance_to(shape[1] as Vector3) < float(shape[2]) + margin
			if hit:
				block.remove_child(child)
				# free(), not queue_free(): the bake packs the scene in this same
				# frame, and a node only queued for deletion would be packed.
				child.free()
				break


## Finds room for the playground in one quarter of the park, and builds it.
## Tries each quarter at full size and then a little smaller before giving up
## on the park — the caller then tries the next one.
func _place_playground(park: Dictionary, keep_out: Array) -> bool:
	var inner: PackedVector3Array = park["inner"]
	var centre: Vector3 = _centroid(inner)
	for scale: float in [1.0, 0.85]:
		var half := PLAY_SIZE * 0.5 * scale
		for k in inner.size():
			var at: Vector3 = centre.lerp(inner[k], 0.5)
			at.y = 0.0
			var edge: Vector3 = inner[(k + 1) % inner.size()] - inner[k]
			var yaw: float = atan2(-edge.z, edge.x)
			var basis := Basis(Vector3.UP, yaw)
			# Gate side (+Z) toward the middle of the park, where the paths are.
			if basis.z.dot(centre - at) < 0.0:
				yaw += PI
				basis = Basis(Vector3.UP, yaw)
			if _playground_fits(inner, at, basis, half, keep_out):
				_build_playground(park["block"], at, yaw, half)
				return true
	return false


func _playground_fits(inner: PackedVector3Array, at: Vector3, basis: Basis,
		half: Vector2, keep_out: Array) -> bool:
	var ext := Vector2(half.x + 0.6, half.y + 1.8)   # room for the benches at the gate
	for c: Vector3 in [Vector3(-ext.x, 0, -half.y - 0.6), Vector3(ext.x, 0, -half.y - 0.6),
			Vector3(ext.x, 0, ext.y), Vector3(-ext.x, 0, ext.y)]:
		if not _inside(inner, at + basis * c, 0.6):
			return false
	var inv: Basis = basis.inverse()
	for shape: Array in keep_out:
		if shape[0] == "seg":
			var a: Vector3 = shape[1]
			var b: Vector3 = shape[2]
			var steps: int = maxi(2, int(a.distance_to(b) / 0.5))
			for s in steps + 1:
				var local: Vector3 = inv * (a.lerp(b, float(s) / float(steps)) - at)
				if absf(local.x) < ext.x + float(shape[3]) and absf(local.z) < ext.y + float(shape[3]):
					return false
		else:
			var local: Vector3 = inv * ((shape[1] as Vector3) - at)
			var near := Vector2(clampf(local.x, -ext.x, ext.x), clampf(local.z, -ext.y, ext.y))
			if Vector2(local.x, local.z).distance_to(near) < float(shape[2]):
				return false
	return true


## The playground itself: a rubber floor, a low fence with a gate, a slide
## tower, swings, a roundabout, a seesaw and a sandpit, and a pair of benches
## outside the gate for whoever is watching.
##
## All the equipment is ONE mesh, a surface per paint colour — thirty-odd
## pieces as nodes would be thirty draw calls for something a few pixels high.
## Local +Z faces the gate.
func _build_playground(block: Node3D, at: Vector3, yaw: float, half: Vector2) -> void:
	var pg := Node3D.new()
	pg.name = "Playground"
	pg.position = at
	pg.rotation.y = yaw
	block.add_child(pg)

	var floor_mi := _box(pg, "Surface", Vector3(0.0, 0.025, 0.0),
		Vector3(half.x * 2.0, 0.05, half.y * 2.0), _rubber_mat)
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var red := Surf.new()
	var yellow := Surf.new()
	var blue := Surf.new()
	var green := Surf.new()
	var metal := Surf.new()
	var timber := Surf.new()
	var sand := Surf.new()
	var sx: float = half.x / (PLAY_SIZE.x * 0.5)
	var sz: float = half.y / (PLAY_SIZE.y * 0.5)

	# Fence: posts, and two rails with a gap for the gate in the middle of +Z.
	var corners: Array[Vector3] = [Vector3(-half.x, 0, -half.y), Vector3(half.x, 0, -half.y),
		Vector3(half.x, 0, half.y), Vector3(-half.x, 0, half.y)]
	for k in 4:
		var a: Vector3 = corners[k]
		var b: Vector3 = corners[(k + 1) % 4]
		var posts: int = int(ceil(a.distance_to(b) / 2.0))
		for p in posts:
			var pos: Vector3 = a.lerp(b, float(p) / float(posts))
			_box_faces(green, Transform3D(Basis(), pos + Vector3(0, 0.45, 0)), Vector3(0.07, 0.9, 0.07))
		var runs: Array = [[a, b]]
		if k == 2:   # the +Z side, running +X to -X: leave the gate open
			runs = [[a, Vector3(0.8, 0, half.y)], [Vector3(-0.8, 0, half.y), b]]
		for run: Array in runs:
			var r0: Vector3 = run[0]
			var r1: Vector3 = run[1]
			var along: Vector3 = r1 - r0
			var basis := Basis(Vector3.UP, atan2(-along.z, along.x))
			for y: float in [0.45, 0.86]:
				_box_faces(green, Transform3D(basis, (r0 + r1) * 0.5 + Vector3(0, y, 0)),
					Vector3(along.length(), 0.05, 0.05))

	# Slide tower, back left.
	var tower := Vector3(-2.9 * sx, 0.0, -2.1 * sz)
	for c: Vector3 in [Vector3(-0.7, 0, -0.7), Vector3(0.7, 0, -0.7), Vector3(0.7, 0, 0.7), Vector3(-0.7, 0, 0.7)]:
		_box_faces(blue, Transform3D(Basis(), tower + c + Vector3(0, 1.4, 0)), Vector3(0.12, 2.8, 0.12))
	_box_faces(yellow, Transform3D(Basis(), tower + Vector3(0, 1.5, 0)), Vector3(1.6, 0.1, 1.6))
	_box_faces(red, Transform3D(Basis(), tower + Vector3(0, 2.86, 0)), Vector3(1.9, 0.12, 1.9))
	for rung in 5:
		_box_faces(metal, Transform3D(Basis(), tower + Vector3(-0.95, 0.3 + 0.3 * float(rung), 0)),
			Vector3(0.05, 0.04, 0.5))
	for z: float in [-0.26, 0.26]:
		_box_faces(metal, Transform3D(Basis(), tower + Vector3(-0.95, 0.8, z)), Vector3(0.05, 1.6, 0.05))
	var drop: float = 1.35
	var reach: float = 2.4
	var chute_len: float = Vector2(reach, drop).length()
	var chute := Basis(Vector3(0, 0, 1), -atan2(drop, reach))
	var chute_at: Vector3 = tower + Vector3(0.8 + reach * 0.5, 0.15 + drop * 0.5, 0.0)
	_box_faces(yellow, Transform3D(chute, chute_at), Vector3(chute_len, 0.06, 0.6))
	for z: float in [-0.32, 0.32]:
		_box_faces(red, Transform3D(chute, chute_at + Vector3(0, 0.09, z)), Vector3(chute_len, 0.18, 0.05))

	# Swings, back right.
	var swings := Vector3(2.7 * sx, 0.0, -2.0 * sz)
	_box_faces(blue, Transform3D(Basis(), swings + Vector3(0, 2.3, 0)), Vector3(3.4, 0.12, 0.12))
	var lean: float = atan2(0.9, 2.3)
	for x: float in [-1.7, 1.7]:
		for z: float in [-1.0, 1.0]:
			# Each leg stands out at z and leans in to the beam overhead.
			_box_faces(blue, Transform3D(Basis(Vector3(1, 0, 0), -lean * z),
				swings + Vector3(x, 1.15, 0.45 * z)), Vector3(0.1, 2.47, 0.1))
	for x: float in [-0.7, 0.7]:
		_box_faces(red, Transform3D(Basis(), swings + Vector3(x, 0.45, 0)), Vector3(0.46, 0.05, 0.2))
		for cx: float in [-0.2, 0.2]:
			_box_faces(metal, Transform3D(Basis(), swings + Vector3(x + cx, 1.37, 0)),
				Vector3(0.02, 1.8, 0.02))

	# Roundabout, front right.
	var spin := Vector3(3.1 * sx, 0.0, 1.9 * sz)
	_prism_faces(yellow, spin, 1.1, 0.2, 0.3, 12)
	_box_faces(red, Transform3D(Basis(), spin + Vector3(0, 0.75, 0)), Vector3(0.1, 0.9, 0.1))
	for n in 4:
		_box_faces(red, Transform3D(Basis(Vector3.UP, PI * 0.25 * float(n)), spin + Vector3(0, 0.75, 0)),
			Vector3(1.7, 0.05, 0.05))

	# Seesaw, front middle.
	var saw := Vector3(0.5 * sx, 0.0, 2.2 * sz)
	_box_faces(metal, Transform3D(Basis(), saw + Vector3(0, 0.17, 0)), Vector3(0.3, 0.34, 0.3))
	var tilt := Basis(Vector3(0, 0, 1), deg_to_rad(9.0))
	_box_faces(red, Transform3D(tilt, saw + Vector3(0, 0.42, 0)), Vector3(3.0, 0.06, 0.3))
	for x: float in [-1.25, 1.25]:
		_box_faces(blue, Transform3D(tilt, saw + tilt * Vector3(x, 0.2, 0) + Vector3(0, 0.42, 0)),
			Vector3(0.05, 0.3, 0.3))

	# Sandpit, front left.
	var pit := Vector3(-3.0 * sx, 0.0, 2.0 * sz)
	for side: float in [-1.0, 1.0]:
		_box_faces(timber, Transform3D(Basis(), pit + Vector3(0, 0.11, 1.13 * side)), Vector3(2.4, 0.22, 0.14))
		_box_faces(timber, Transform3D(Basis(), pit + Vector3(1.13 * side, 0.11, 0)), Vector3(0.14, 0.22, 2.12))
	_box_faces(sand, Transform3D(Basis(), pit + Vector3(0, 0.07, 0)), Vector3(2.12, 0.08, 2.12))

	var kit := ArrayMesh.new()
	red.commit(kit, _flat_mat(Color(0.720, 0.205, 0.170), 0.55), false)
	yellow.commit(kit, _flat_mat(Color(0.860, 0.660, 0.160), 0.55), false)
	blue.commit(kit, _flat_mat(Color(0.180, 0.380, 0.660), 0.55), false)
	green.commit(kit, _flat_mat(Color(0.200, 0.420, 0.280), 0.60), false)
	metal.commit(kit, _flat_mat(Color(0.560, 0.575, 0.600), 0.45), false)
	timber.commit(kit, _flat_mat(Color(0.460, 0.320, 0.200), 0.90), false)
	sand.commit(kit, _flat_mat(Color(0.820, 0.740, 0.560), 1.00), false)
	_mesh_node(pg, "Equipment", kit)

	for x: float in [-2.2, 2.2]:
		var bench := _box(pg, "Bench", Vector3(x * sx, 0.26, half.y + 1.1),
			Vector3(2.0, 0.42, 0.6), _bench_mat)
		bench.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	var basis := Basis(Vector3.UP, yaw)
	var reach_out: float = Vector2(half.x, half.y + 1.8).length()
	var clear_pts: Array = []
	for c: Vector3 in [Vector3(-half.x, 0, -half.y), Vector3(half.x, 0, -half.y),
			Vector3(half.x, 0, half.y + 1.8), Vector3(-half.x, 0, half.y + 1.8)]:
		clear_pts.append(at + basis * c)
	# Trees out of the fence line and off the gate, by the rectangle's edges.
	var shapes: Array = []
	for k in 4:
		shapes.append(["seg", clear_pts[k], clear_pts[(k + 1) % 4], 0.0])
	shapes.append(["disc", at, reach_out * 0.72])
	_clear_trees(block, shapes, 1.4)


## A flat many-sided disc, as faces: the roundabout's deck.
static func _prism_faces(s: Surf, at: Vector3, r: float, y0: float, y1: float, sides: int) -> void:
	var top := PackedVector3Array()
	var bottom := PackedVector3Array()
	var no_uv := PackedVector2Array()
	no_uv.resize(sides)
	for n in sides:
		var ang: float = TAU * float(n) / float(sides)
		var rim := Vector3(cos(ang), 0.0, sin(ang)) * r
		top.append(at + rim + Vector3.UP * y1)
		bottom.append(at + rim + Vector3.UP * y0)
	s.face(top, no_uv, Vector3.UP)
	s.face(bottom, no_uv, Vector3.DOWN)
	for n in sides:
		var m: int = (n + 1) % sides
		var mid_ang: float = TAU * (float(n) + 0.5) / float(sides)
		s.face(PackedVector3Array([bottom[n], bottom[m], top[m], top[n]]),
			PackedVector2Array(_NO_UV), Vector3(cos(mid_ang), 0.0, sin(mid_ang)))


# ── Streetlights ─────────────────────────────────────────────────────────────

## Lamps down every side of the block that has a street, on the pavement just
## in from the kerb with their arms out over the road.
##
## `parity` staggers the two sides of a street against each other: a lamp
## facing a lamp across the road looks like a gateway, alternating looks like a
## street.
func _build_streetlights(block: Node3D, mid: Vector3, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array], parity: int) -> void:
	if not bool(_ground["ok"]):
		return
	var kerb: PackedVector3Array = _ground["kerb"]
	var streets: PackedInt32Array = _ground["streets"]
	var turn: float = signf(_signed_area(kerb))
	var lamps: Array[Transform3D] = []
	for k in kerb.size():
		if streets[k] < 0:
			continue
		var a: Vector3 = kerb[k]
		var b: Vector3 = kerb[(k + 1) % kerb.size()]
		var run: float = a.distance_to(b)
		var along: Vector3 = (b - a) / run
		var inward := Vector3(-along.z, 0.0, along.x) * turn
		var t: float = LAMP_END + (LAMP_SPACING * 0.5 if (parity + k) % 2 == 1 else 0.0)
		while t <= run - LAMP_END:
			var at: Vector3 = a + along * t + inward * (KERB_W + LAMP_INSET)
			if _lamp_fits(mid + at, at, keep_clear, paths):
				# Local +Z is the arm, so it goes out over the road.
				lamps.append(Transform3D(Basis(Vector3.UP, _bearing_of(-inward)), at))
			t += LAMP_SPACING
	if lamps.is_empty():
		return

	var pools: Array[Transform3D] = []
	for lamp: Transform3D in lamps:
		var under: Vector3 = lamp.origin + lamp.basis.z * (LAMP_REACH - 0.1)
		pools.append(Transform3D(Basis(), Vector3(under.x, 0.035, under.z)))
	_multimesh(block, "Streetlights", _lamp_mesh, lamps, true)
	_multimesh(block, "LampLight", _pool_mesh, pools, false)


## A lamp keeps out of a rift's way, off the spur a route walks up to one, and
## clear of the street trees. Not the full keep-clear radius a building needs:
## a post is thin, and a rift standing on a lit street is the point.
func _lamp_fits(world: Vector3, local: Vector3, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> bool:
	for entry: Dictionary in keep_clear:
		var c: Vector3 = entry.get("pos", Vector3.ZERO)
		var r: float = minf(float(entry.get("radius", 10.0)) * 0.5, 6.0)
		if Vector2(world.x - c.x, world.z - c.z).length() < r:
			return false
	for line: PackedVector3Array in paths:
		for i in range(1, line.size()):
			if _point_to_segment(world, line[i - 1], line[i]) < 1.8:
				return false
	for tree: Vector3 in _kerb_trees:
		if Vector2(local.x - tree.x, local.z - tree.z).length() < 2.8:
			return false
	return true


func _multimesh(parent: Node3D, piece_name: String, mesh: Mesh,
		xforms: Array[Transform3D], shadows: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	# Format before count: changing it afterwards clears the instances.
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for n in xforms.size():
		mm.set_instance_transform(n, xforms[n])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = piece_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)
	return mmi


## One streetlight, shared by every lamp in town: a dark post and arm, and a
## head that is the glowing part.
##
## The WHOLE head glows, not just a lens underneath it. The camera looks down
## from above and would never see a lens; what reads at night from up there is a
## bright point at the end of every arm and the pool of light below it.
func _build_lamp_mesh() -> ArrayMesh:
	var metal := Surf.new()
	var head := Surf.new()
	_box_faces(metal, Transform3D(Basis(), Vector3(0.0, 0.2, 0.0)), Vector3(0.28, 0.4, 0.28))
	_box_faces(metal, Transform3D(Basis(), Vector3(0.0, LAMP_HEIGHT * 0.5, 0.0)),
		Vector3(0.12, LAMP_HEIGHT, 0.12))
	_box_faces(metal, Transform3D(Basis(), Vector3(0.0, LAMP_HEIGHT - 0.05, LAMP_REACH * 0.5)),
		Vector3(0.08, 0.08, LAMP_REACH))
	_box_faces(head, Transform3D(Basis(), Vector3(0.0, LAMP_HEIGHT - 0.12, LAMP_REACH - 0.1)),
		Vector3(0.34, 0.14, 0.62))

	var post_mat := _flat_mat(LAMP_POST_COL, 0.55)
	post_mat.metallic = 0.4
	var glow := _flat_mat(Color(0.86, 0.84, 0.78), 0.4)
	glow.emission_enabled = true
	glow.emission = LAMP_GLOW_COL
	glow.emission_energy_multiplier = 1.0
	# Found by name inside the baked city, like LitGlass, and driven by the clock:
	# StoryMap turns these up at dusk and off at noon.
	glow.resource_name = "LampGlow"

	var mesh := ArrayMesh.new()
	metal.commit(mesh, post_mat, false)
	head.commit(mesh, glow, false)
	return mesh


## The light a lamp throws on the ground: a disc, white in the middle and black
## at the rim, drawn additively. Black adds nothing, so in daylight — when
## StoryMap has its colour at zero — it is simply not there. Real lights would
## cost a clustered light each, two hundred of them; this costs one draw per
## block and reads the same from above.
func _build_pool_mesh() -> ArrayMesh:
	var segments: int = 20
	# Bright in the middle and falling away fast, then a long faint tail — a
	# linear ramp to the rim reads as a flat disc with a soft edge, and two
	# hundred of those from above is a polka-dot street.
	var rings: Array = [[0.38, Color(0.40, 0.40, 0.40)], [1.0, Color.BLACK]]
	var verts := PackedVector3Array([Vector3.ZERO])
	var cols := PackedColorArray([Color.WHITE])
	for ring: Array in rings:
		for s in segments:
			var ang: float = TAU * float(s) / float(segments)
			verts.append(Vector3(cos(ang), 0.0, sin(ang)) * LAMP_POOL_R * float(ring[0]))
			cols.append(ring[1])
	var tris := PackedInt32Array()
	for s in segments:
		var n: int = (s + 1) % segments
		_pool_tri(tris, verts, 0, 1 + s, 1 + n)
		var a: int = 1 + s
		var b: int = 1 + n
		_pool_tri(tris, verts, a, a + segments, b + segments)
		_pool_tri(tris, verts, a, b + segments, b)
	var norms := PackedVector3Array()
	for _v in verts.size():
		norms.append(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = tris

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.BLACK
	# Fog mixes toward its own colour, and on an ADDITIVE material that is fog
	# ADDED to the ground: every pool showed as a grey disc at noon and a violet
	# one at dusk, lamps off.
	mat.disable_fog = true
	mat.resource_name = "LampPool"

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh


## One triangle of the pool disc, wound clockwise seen from above — Godot's
## front face for something facing up.
static func _pool_tri(tris: PackedInt32Array, verts: PackedVector3Array, a: int, b: int, c: int) -> void:
	if (verts[b] - verts[a]).cross(verts[c] - verts[a]).dot(Vector3.UP) > 0.0:
		tris.append_array(PackedInt32Array([a, c, b]))
	else:
		tris.append_array(PackedInt32Array([a, b, c]))


## A box as six faces on a surface under construction, placed by `xf` — for
## props built out of many small parts that should still be one mesh.
static func _box_faces(s: Surf, xf: Transform3D, size: Vector3) -> void:
	var h: Vector3 = size * 0.5
	var no_uv := PackedVector2Array(_NO_UV)
	for axis in 3:
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = 1.0
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = 1.0
			var c: Vector3 = n * h[axis]
			var du: Vector3 = u * h[(axis + 1) % 3]
			var dv: Vector3 = v * h[(axis + 2) % 3]
			var pts := PackedVector3Array([c - du - dv, c + du - dv, c + du + dv, c - du + dv])
			for i in 4:
				pts[i] = xf * pts[i]
			s.face(pts, no_uv, (xf.basis * n).normalized())


## True when one of the keep-clear points (a rift, or the hub) sits on this
## block. Such a block never becomes a park or a square: a wall rift is cut into
## a building, and a building standing alone on a lawn reads as a mistake.
static func _holds_a_rift(quad: PackedVector3Array, keep_clear: Array[Dictionary]) -> bool:
	for entry: Dictionary in keep_clear:
		if _inside(quad, entry.get("pos", Vector3.ZERO) as Vector3, -6.0):
			return true
	return false


## True when a block is close enough to some node to ever be on screen.
func _within_view_band(bc: Vector3, keep_clear: Array[Dictionary]) -> bool:
	for entry: Dictionary in keep_clear:
		var c: Vector3 = entry.get("pos", Vector3.ZERO)
		if Vector2(bc.x - c.x, bc.z - c.z).length() <= VIEW_BAND:
			return true
	return false


## True when a building of `footprint` radius at `pos` clears every rift, the
## hub, and every route trail.
func _is_clear(pos: Vector3, footprint: float, keep_clear: Array[Dictionary],
		paths: Array[PackedVector3Array]) -> bool:
	for entry: Dictionary in keep_clear:
		var c: Vector3 = entry.get("pos", Vector3.ZERO)
		var r: float = float(entry.get("radius", 10.0))
		if Vector2(pos.x - c.x, pos.z - c.z).length() < r + footprint:
			return false

	for line: PackedVector3Array in paths:
		for i in range(1, line.size()):
			if _point_to_segment(pos, line[i - 1], line[i]) < PATH_CLEARANCE + footprint:
				return false
	return true


## Distance from `p` to segment a-b, measured on the XZ plane only.
static func _point_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var pp := Vector2(p.x, p.z)
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	var ab: Vector2 = bb - aa
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return pp.distance_to(aa)
	var t: float = clampf((pp - aa).dot(ab) / len_sq, 0.0, 1.0)
	return pp.distance_to(aa + ab * t)
