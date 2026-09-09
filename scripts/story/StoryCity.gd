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

## Each style is [wall, roof]. Brick, cream stucco, sage render, sandstone,
## blue-grey and ochre — a terrace of houses that were not all built at once.
const BUILDING_STYLES: Array = [
	[Color(0.605, 0.408, 0.330), Color(0.430, 0.235, 0.190)],
	[Color(0.760, 0.712, 0.605), Color(0.352, 0.330, 0.342)],
	[Color(0.548, 0.575, 0.512), Color(0.330, 0.302, 0.272)],
	[Color(0.700, 0.622, 0.510), Color(0.412, 0.352, 0.310)],
	[Color(0.470, 0.512, 0.572), Color(0.312, 0.334, 0.372)],
	[Color(0.660, 0.500, 0.412), Color(0.398, 0.222, 0.182)],
	[Color(0.792, 0.760, 0.700), Color(0.372, 0.352, 0.340)],
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
var _unit_box: BoxMesh = null
var _wall_mats: Array[StandardMaterial3D] = []
var _roof_mats: Array[StandardMaterial3D] = []
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
var _building_count: int = 0
var _block_count: int = 0

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
## How far the two beds flanking the way in are swung aside and drawn back.
const ENTRANCE_SPLAY: float = 0.21
const ENTRANCE_PULL: float = 1.45

## `facing` is which way the plaza opens. The gap in the colonnade and the beds
## that frame it are derived from it rather than pinned to a fixed index — flip
## the hub's `facing` in the map JSON and the opening moves with it instead of
## ending up behind a pillar.
static func build_hub(parent: Node3D, at: Vector3, facing: Vector3 = Vector3(0.0, 0.0, 1.0)) -> Node3D:
	var hub := Node3D.new()
	hub.name = "Hub"
	hub.position = at
	parent.add_child(hub)

	var pale   := _hub_mat(Color(0.545, 0.535, 0.540), 0.82)
	var stone  := _hub_mat(Color(0.470, 0.462, 0.470), 0.90)
	var dark   := _hub_mat(Color(0.355, 0.350, 0.358), 0.95)
	var accent := _hub_mat(Color(0.395, 0.372, 0.345), 0.90)
	var green  := _hub_mat(Color(0.250, 0.305, 0.235), 1.00)

	var entrance: float = atan2(facing.z, facing.x)
	_hub_deck(hub, pale, stone, dark)
	_hub_columns(hub, pale, dark, entrance)
	_hub_canopy(hub, pale, stone, dark)
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
		# The two beds either side of the entrance are swung wider and drawn in,
		# so they frame the opening instead of narrowing it.
		var off: float = angle_difference(a, entrance)
		if absf(off) < slot:
			a += ENTRANCE_SPLAY * signf(off)
			ring -= ENTRANCE_PULL

		var bed := Node3D.new()
		bed.name = "Planter_%d" % i
		bed.position = Vector3(cos(a) * ring, 0.0, sin(a) * ring)
		bed.rotation.y = -a
		beds.add_child(bed)
		_hub_box(bed, "Kerb", Vector3(0.0, 0.28, 0.0), Vector3(1.1, 0.56, 4.4), accent)
		_hub_box(bed, "Planting", Vector3(0.0, 0.52, 0.0), Vector3(0.82, 0.2, 4.1), green)


# ── Small builders ───────────────────────────────────────────────────────────

static func _hub_mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness    = rough
	return m


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
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_roads = StoryRoads.shared(center)
	_build_materials()

	_ground_root = _group("Ground")
	_road_root   = _group("Roads")
	_block_root  = _group("Blocks")

	_build_ground(center, radius)
	_build_streets(center, radius)
	_build_blocks(center, radius, keep_clear, paths)
	print("[StoryCity] %d buildings across %d blocks, %.0f m radius." % [
		_building_count, _block_count, radius])


func _group(group_name: String) -> Node3D:
	var n := Node3D.new()
	n.name = group_name
	add_child(n)
	return n


func _build_materials() -> void:
	for style: Array in BUILDING_STYLES:
		_wall_mats.append(_flat_mat(style[0] as Color, 0.86))
		_roof_mats.append(_flat_mat(style[1] as Color, 0.80))
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

	_pavement_mat = _flat_mat(PAVEMENT_COL, 1.0)
	_road_mat     = _flat_mat(ROAD_COL, 1.0)
	_lane_mat     = _flat_mat(LANE_COL, 1.0)
	_marking_mat  = _flat_mat(MARKING_COL, 0.9)
	_grass_mat    = _flat_mat(GRASS_COL, 1.0)
	_hedge_mat    = _flat_mat(HEDGE_COL, 1.0)
	_leaf_mats.append(_flat_mat(LEAF_COL_A, 0.95))
	_leaf_mats.append(_flat_mat(LEAF_COL_B, 0.95))
	_leaf_mats.append(_flat_mat(LEAF_COL_C, 0.95))
	_trunk_mat    = _flat_mat(TRUNK_COL, 0.95)
	_water_mat    = _flat_mat(WATER_COL, 0.18)
	_water_mat.metallic = 0.25
	_path_mat     = _flat_mat(GRAVEL_COL, 1.0)


func _flat_mat(col: Color, rough: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness    = rough
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
func _slab(parent: Node3D, slab_name: String, poly: PackedVector3Array, y: float,
		mat: StandardMaterial3D) -> MeshInstance3D:
	if poly.size() < 3:
		return null
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	for p: Vector3 in poly:
		verts.append(Vector3(p.x, y, p.z))
	# Fan from the first corner: every shape here is convex, so this is safe.
	for i in range(1, poly.size() - 1):
		indices.append_array([0, i, i + 1])

	var normals := PackedVector3Array()
	for _i in verts.size():
		normals.append(Vector3.UP)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX]  = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = slab_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
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


func _build_ground(center: Vector3, radius: float) -> void:
	var ground := MeshInstance3D.new()
	ground.name = "GroundPlane"
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius * 2.6, radius * 2.6)
	ground.mesh = plane
	ground.material_override = _flat_mat(GROUND_COL)
	# Well below the streets. At 2 cm the two surfaces z-fought over the whole
	# map and the city came out under a grey haze.
	ground.position = center + Vector3(0.0, -ROAD_DROP - 0.6, 0.0)
	_ground_root.add_child(ground)


## Every street in the network, drawn as a quad, plus a patch at each junction
## to fill the wedge the quads leave between them.
func _build_streets(center: Vector3, radius: float) -> void:
	var marks := _group("Markings")

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
		# Centre dashes, stopping short of both junctions.
		var step: float = 9.0
		var runs: int = int((length - 16.0) / step)
		for k in maxi(runs, 0):
			var t: float = 8.0 + step * (float(k) + 0.5)
			var mid: Vector3 = a + along * t
			var dash := _box(marks, "Dash_%d_%d" % [ei, k],
				mid + Vector3(0.0, -ROAD_DROP + 0.02, 0.0),
				Vector3(0.35, 0.02, 3.6), _marking_mat)
			dash.rotation.y = atan2(along.x, along.z)

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
		var w: float = 0.0
		var avenue_here: bool = false
		for link: Array in links:
			var hw: float = _roads.half_width(int(link[1]))
			w = maxf(w, hw)
			if _roads.major[int(link[1])] == 1:
				avenue_here = true

		var fillet := MeshInstance3D.new()
		fillet.name = "Junction_%d" % pi
		var disc := CylinderMesh.new()
		disc.top_radius      = w
		disc.bottom_radius   = w
		disc.height          = 0.04
		disc.radial_segments = 14
		disc.rings           = 1
		fillet.mesh = disc
		fillet.material_override = _road_mat if avenue_here else _lane_mat
		fillet.position = p + Vector3(0.0, -ROAD_DROP + 0.018, 0.0)
		_road_root.add_child(fillet)


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
			_slab(block, "Pavement", local, 0.0, _pavement_mat)

			# What is already standing on this block. Filled in by whatever fills
			# the block, then read by the kerb — a tree planted at the kerb line
			# was landing inside the shopfront of a terrace set one metre back.
			var taken: Array[Dictionary] = []
			_fill_block(block, mid, local, from_center, radius, keep_clear, paths, taken)
			_build_kerbside(block, mid, local, keep_clear, paths, taken)


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
func _build_house(lot: Node3D, w: float, d: float, h: float) -> void:
	var idx: int = _rng.randi() % _wall_mats.size()
	_box(lot, "Walls", Vector3(0.0, h * 0.5, 0.0), Vector3(w, h, d), _wall_mats[idx])
	_facade(lot, w, h, d, 1.0, 0.0, (BUILDING_STYLES[idx] as Array)[0] as Color)

	var roof := MeshInstance3D.new()
	roof.name = "Roof"
	var pm := PrismMesh.new()
	var along_x: bool = w >= d
	var ridge: float = _rng.randf_range(1.8, 3.0)
	pm.size = Vector3(d + 0.7, ridge, w + 0.7) if along_x else Vector3(w + 0.7, ridge, d + 0.7)
	roof.mesh = pm
	roof.material_override = _roof_mats[idx]
	roof.position = Vector3(0.0, h + ridge * 0.5, 0.0)
	if along_x:
		roof.rotation.y = PI * 0.5
	lot.add_child(roof)

	if _rng.randf() < 0.55:
		_box(lot, "Chimney", Vector3(w * _rng.randf_range(-0.28, 0.28), h + ridge * 0.75, d * 0.18),
			Vector3(0.7, 2.0, 0.7), _roof_mats[idx])


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
		var unit := Node3D.new()
		unit.name = "Shop_%d" % _building_count
		unit.position = local
		# Local +Z points into the block, so the shopfront on local -Z faces the
		# road. It used to be the along-the-row bearing, which had every shop
		# showing its window to the back of the one beside it.
		unit.rotation.y = _bearing_of(inward)
		block.add_child(unit)
		_building_count += 1

		_box(unit, "Walls", Vector3(0.0, h * 0.5, 0.0), Vector3(w, h, d), _wall_mats[idx])
		_box(unit, "Front", Vector3(0.0, 1.6, -d * 0.5 - 0.06),
			Vector3(w * 0.9, 3.2, 0.25), _shop_mats[_rng.randi() % _shop_mats.size()])
		# Glass starts above the painted band, and the door is pushed out past
		# the band's own thickness so it is not buried inside it.
		_facade(unit, w, h, d, -1.0, 3.5, (BUILDING_STYLES[idx] as Array)[0] as Color,
			true, 0.20)
		_box(unit, "Parapet", Vector3(0.0, h + 0.3, 0.0),
			Vector3(w + 0.5, 0.6, d + 0.5), _roof_mats[idx])


func _build_park(block: Node3D, quad: PackedVector3Array) -> void:
	_slab(block, "Lawn", _shrink(quad, 1.2), 0.03, _grass_mat)

	var spot: Dictionary = _spot_in(quad, 4.0)
	if spot["ok"] and _rng.randf() < 0.4:
		var pond := MeshInstance3D.new()
		pond.name = "Pond"
		var disc := CylinderMesh.new()
		disc.top_radius      = _rng.randf_range(4.0, 6.5)
		disc.bottom_radius   = disc.top_radius
		disc.height          = 0.1
		disc.radial_segments = 16
		pond.mesh = disc
		pond.material_override = _water_mat
		pond.position = (spot["pos"] as Vector3) + Vector3(0.0, 0.06, 0.0)
		block.add_child(pond)

	for _t in _rng.randi_range(7, 13):
		var s: Dictionary = _spot_in(quad, 2.5)
		if s["ok"]:
			_tree(block, s["pos"], _rng.randf_range(3.4, 6.0))


func _build_square(block: Node3D, quad: PackedVector3Array) -> void:
	_slab(block, "Paving", _shrink(quad, 1.0), 0.02, _pavement_mat)
	_slab(block, "Inlay", _shrink(quad, 7.0), 0.04, _path_mat)

	for i in 4:
		var s: Dictionary = _spot_in(quad, 5.0)
		if not s["ok"]:
			continue
		var bench := _box(block, "Bench_%d" % i, (s["pos"] as Vector3) + Vector3(0.0, 0.28, 0.0),
			Vector3(3.4, 0.5, 0.7), _roof_mats[1])
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
				continue
			var car := Node3D.new()
			car.name = "Car_%d_%d" % [k, i]
			car.position = at
			car.rotation.y = bearing + deg_to_rad(_rng.randf_range(-3.0, 3.0))
			block.add_child(car)
			var col: StandardMaterial3D = _car_mats[_rng.randi() % _car_mats.size()]
			_box(car, "Body", Vector3(0.0, 0.62, 0.0), Vector3(1.9, 1.05, 4.3), col)
			_box(car, "Cabin", Vector3(0.0, 1.35, -0.25), Vector3(1.7, 0.75, 2.1), col)


## A tree: trunk plus two offset canopy blocks. Two boxes rather than one makes
## the crown read as foliage instead of as a green cube.
func _tree(parent: Node3D, at: Vector3, height: float) -> void:
	var t := Node3D.new()
	t.name = "Tree"
	t.position = at
	t.rotation.y = _rng.randf_range(0.0, TAU)
	parent.add_child(t)

	var leaf: StandardMaterial3D = _leaf_mats[_rng.randi() % _leaf_mats.size()]
	var spread: float = height * _rng.randf_range(0.5, 0.72)
	_box(t, "Trunk", Vector3(0.0, height * 0.3, 0.0), Vector3(0.42, height * 0.6, 0.42), _trunk_mat)
	_box(t, "Crown", Vector3(0.0, height * 0.72, 0.0), Vector3(spread, height * 0.5, spread), leaf)
	_box(t, "CrownTop", Vector3(0.0, height * 0.95, 0.0),
		Vector3(spread * 0.62, height * 0.3, spread * 0.62), leaf)


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
