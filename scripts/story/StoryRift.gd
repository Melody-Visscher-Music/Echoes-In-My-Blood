class_name StoryRift
extends Node3D

## One echo rift on the Story Mode map — the map's stand-in for a level.
##
## PLACEHOLDER ART. Every mesh in here is a primitive (torus, box, cylinder)
## standing in for real rift art. Two variants exist:
##
##   * GROUND — a tear lying open in the street, ringed by a flat halo.
##   * WALL   — the same tear set into a building facade, so a cluster does not
##              read as three identical decals on the tarmac.
##
## The variant is PURELY visual variety: nothing downstream branches on it.
## StoryMap picks one per node ("auto" alternates) and that is the end of it.
##
## TODO(art): replace _build_ground()/_build_wall() with the authored rift
## meshes + the rift shader once they exist. The public surface here — setup(),
## set_revealed(), set_selected(), set_hovered(), pick_radius() — is what the
## map talks to, so real art can land behind it without touching StoryMap.gd.
##
## The city around a rift stays mundane on purpose: no debris, no cracks, no
## decay props. A rift is inconvenient, not destructive — it is the only
## saturated thing in an otherwise muted scene, and that contrast is the whole
## visual idea.

## Emitted when the player clicks this rift. StoryMap does the picking (screen
## space, not physics) and calls `press()`, so this stays a pure visual.
signal picked(node_id: String)

const VARIANT_GROUND: String = "ground"
const VARIANT_WALL:   String = "wall"

## Metres of slack around the rift's screen position that still counts as a
## click on it. Generous on purpose — the camera sits at map distance, so a
## rift is only a handful of pixels across.
const PICK_RADIUS_M: float = 5.5

var node_id: String = ""
var title: String = ""
var variant: String = VARIANT_GROUND
var accent: Color = Color(0.72, 0.30, 1.00)

var _revealed: bool = false
var _selected: bool = false
var _hovered: bool = false
## Meeko has closed this one. It stays on the map — it is still a place, and
## still somewhere to walk back to — but it is no longer a live tear in the
## city, so it must not read as one.
var _closed: bool = false

var _pulse_t: float = 0.0
var _glow_mats: Array[StandardMaterial3D] = []
var _light: OmniLight3D = null
var _ring: MeshInstance3D = null
var _shaft: MeshInstance3D = null
var _content: Node3D = null

# Emission energy the pulse oscillates around. Selection and hover both nudge
# this rather than swapping materials, so a rift never pops between two looks.
var _energy_base: float = 2.6

## How far a closed rift is knocked back: glow, light and the vertical beacon.
## Dimmed rather than removed — the player still has to find it to walk back to
## it, and an emptied-out map late game would read as unfinished rather than as
## progress. The beacon takes the hardest cut, because its whole job is saying
## "there is something live here" and there no longer is.
const CLOSED_GLOW: float = 0.26
const CLOSED_LIGHT: float = 0.22
const CLOSED_SHAFT: float = 0.22
## Closed rifts breathe slower too. Same colour, much less urgency.
const CLOSED_PULSE_RATE: float = 0.45

var _shaft_alpha: float = 0.085


## Builds the rift. `accent_col` is the saturated rift colour — the one thing on
## the map allowed to be bright.
func setup(id: String, node_title: String, node_variant: String, accent_col: Color) -> void:
	node_id = id
	title   = node_title
	variant = node_variant if node_variant in [VARIANT_GROUND, VARIANT_WALL] else VARIANT_GROUND
	accent  = accent_col

	_content = Node3D.new()
	_content.name = "Content"
	add_child(_content)

	if variant == VARIANT_WALL:
		_build_wall()
	else:
		_build_ground()

	_build_shared()
	# Hidden until the map says otherwise: locked rifts are not on the map at
	# all, so nothing here may be visible before set_revealed() allows it.
	visible = false


## Turns the rift to face `target` on the XZ plane. Only the wall variant really
## cares (its facade has a front), but both are called the same way so the map
## does not have to know which variant it built.
func face_toward(target: Vector3) -> void:
	var to: Vector3 = target - global_position
	to.y = 0.0
	if to.length_squared() < 0.001:
		return
	rotation.y = atan2(to.x, to.z)


# ── Variants ─────────────────────────────────────────────────────────────────

func _build_ground() -> void:
	# Flat halo lying in the street.
	var halo := MeshInstance3D.new()
	var halo_mesh := TorusMesh.new()
	halo_mesh.inner_radius = 2.1
	halo_mesh.outer_radius = 3.0
	halo_mesh.rings = 20
	halo_mesh.ring_segments = 10
	halo.mesh = halo_mesh
	halo.material_override = _glow_mat(accent, 2.2)
	halo.position = Vector3(0.0, 0.12, 0.0)
	_content.add_child(halo)

	# The tear itself — a thin vertical sliver standing in the halo.
	var tear := MeshInstance3D.new()
	var tear_mesh := BoxMesh.new()
	tear_mesh.size = Vector3(0.55, 4.4, 0.55)
	tear.mesh = tear_mesh
	tear.material_override = _glow_mat(accent.lightened(0.25), 4.0)
	tear.position = Vector3(0.0, 2.2, 0.0)
	tear.rotation_degrees.z = 6.0
	_content.add_child(tear)


func _build_wall() -> void:
	# TODO(art): the real wall rift is cut into an actual building. Until the
	# city is authored art, the rift brings its own placeholder facade so it has
	# something to be set into — StoryCity keeps its blocks clear of node
	# positions, so this slab never fights a procedural building for the spot.
	var facade := MeshInstance3D.new()
	var facade_mesh := BoxMesh.new()
	facade_mesh.size = Vector3(11.0, 17.0, 8.0)
	facade.mesh = facade_mesh
	facade.material_override = StoryCity.facade_material()
	facade.position = Vector3(0.0, 8.5, -4.6)
	_content.add_child(facade)

	# The gash in the facade.
	var gash := MeshInstance3D.new()
	var gash_mesh := BoxMesh.new()
	gash_mesh.size = Vector3(1.0, 6.4, 0.4)
	gash.mesh = gash_mesh
	gash.material_override = _glow_mat(accent.lightened(0.25), 4.0)
	gash.position = Vector3(0.0, 5.4, -0.75)
	gash.rotation_degrees.z = -8.0
	_content.add_child(gash)

	# Spill on the pavement in front of it, so the rift still reads from above.
	var spill := MeshInstance3D.new()
	var spill_mesh := TorusMesh.new()
	spill_mesh.inner_radius = 1.3
	spill_mesh.outer_radius = 2.6
	spill_mesh.rings = 20
	spill_mesh.ring_segments = 10
	spill.mesh = spill_mesh
	spill.material_override = _glow_mat(accent, 1.8)
	spill.position = Vector3(0.0, 0.12, 0.1)
	_content.add_child(spill)


## Parts every variant shares: the light, the vertical shaft that makes the rift
## findable from map distance, and the flat selection ring.
func _build_shared() -> void:
	# A faint column of light so a rift is findable from map distance. It is NOT
	# registered in _glow_mats: the pulse writes emission energy to everything in
	# that list, and an emissive additive column comes out as a solid pink beam
	# that swallows the rift it is supposed to point at. Additive alpha only,
	# fixed and low — a hint of haze, not a searchlight.
	_shaft = MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius    = 1.5
	shaft_mesh.bottom_radius = 0.9
	shaft_mesh.height        = 15.0
	shaft_mesh.radial_segments = 10
	shaft_mesh.rings = 1
	_shaft.mesh = shaft_mesh
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	shaft_mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	shaft_mat.blend_mode    = BaseMaterial3D.BLEND_MODE_ADD
	shaft_mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	shaft_mat.albedo_color  = Color(accent.r, accent.g, accent.b, _shaft_alpha)
	_shaft.material_override = shaft_mat
	_shaft.position = Vector3(0.0, 7.5, 0.0)
	_content.add_child(_shaft)

	_light = OmniLight3D.new()
	_light.light_color  = accent
	_light.light_energy = 3.0
	_light.omni_range   = 22.0
	_light.position     = Vector3(0.0, 3.0, 0.0)
	_content.add_child(_light)

	# Selection ring — flat on the ground, brightens and widens when this rift
	# is the current target. Kept separate from the rift glow so hover feedback
	# never reads as "the rift changed".
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 4.2
	ring_mesh.outer_radius = 4.8
	ring_mesh.rings = 24
	ring_mesh.ring_segments = 8
	_ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color               = Color.WHITE
	ring_mat.emission_enabled           = true
	ring_mat.emission                   = Color.WHITE
	ring_mat.emission_energy_multiplier = 1.0
	ring_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring.material_override = ring_mat
	_ring.position = Vector3(0.0, 0.08, 0.0)
	_ring.visible  = false
	_content.add_child(_ring)


func _glow_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color               = col.darkened(0.2)
	m.emission_enabled           = true
	m.emission                   = col
	m.emission_energy_multiplier = energy
	m.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mats.append(m)
	return m


# ── State ────────────────────────────────────────────────────────────────────

func is_revealed() -> bool:
	return _revealed


## Shows or hides the rift. `animate` plays the reveal flourish — the map passes
## false when it is building the already-unlocked part of the world on load, and
## true for the one node that just opened up after a clear.
func set_revealed(on: bool, animate: bool = false) -> void:
	_revealed = on
	visible = on
	if not on:
		return
	if not animate:
		_content.scale = Vector3.ONE
		return

	# TODO(cutscene): the real reveal is a cutscene beat — a rift tearing open
	# with camera and audio. This scale-and-flare stands in for the timing so
	# the rest of the flow (path light-up, re-selection) can be built against it.
	_content.scale = Vector3(0.05, 0.05, 0.05)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_content, "scale", Vector3.ONE, 0.85)
	tw.parallel().tween_method(_set_flare, 4.0, 1.0, 1.1)


## Marks the rift as closed (or re-opens it). Only the shaft needs touching
## here — the glow and the light are written every frame by _process, which
## reads _closed itself.
func set_closed(on: bool) -> void:
	_closed = on
	if _shaft != null:
		var m := _shaft.material_override as StandardMaterial3D
		if m != null:
			var a: float = _shaft_alpha * (CLOSED_SHAFT if on else 1.0)
			m.albedo_color = Color(accent.r, accent.g, accent.b, a)


func is_closed() -> bool:
	return _closed


func set_selected(on: bool) -> void:
	_selected = on
	if _ring != null:
		_ring.visible = on or _hovered


func set_hovered(on: bool) -> void:
	_hovered = on
	if _ring != null:
		_ring.visible = on or _selected


## Called by StoryMap when its screen-space pick lands on this rift.
func press() -> void:
	picked.emit(node_id)


## Radius in metres that counts as a hit for picking. The wall variant is
## physically bigger, so it gets a slightly wider one.
func pick_radius() -> float:
	return PICK_RADIUS_M * (1.25 if variant == VARIANT_WALL else 1.0)


## Where a screen-space label or pick test should anchor — head height, not the
## origin, so a rift on a facade still points at the rift and not at the kerb.
func anchor_point() -> Vector3:
	return global_position + Vector3(0.0, 3.0, 0.0)


func _set_flare(mult: float) -> void:
	for m: StandardMaterial3D in _glow_mats:
		m.emission_energy_multiplier = _energy_base * mult
	if _light != null:
		_light.light_energy = 3.0 * mult


func _process(delta: float) -> void:
	if not _revealed:
		return
	_pulse_t += delta

	# A slow breathing pulse — enough to say "this is alive and wrong" from map
	# distance without turning into a strobe. A closed rift breathes slower.
	var rate: float = 1.9 * (CLOSED_PULSE_RATE if _closed else 1.0)
	var pulse: float = 0.85 + 0.15 * sin(_pulse_t * rate)
	var boost: float = 1.35 if _selected else (1.15 if _hovered else 1.0)
	# Selection still lifts a closed rift, so the cursor is never invisible on
	# one — it lifts from a much lower floor.
	var dim: float = CLOSED_GLOW if _closed else 1.0
	for m: StandardMaterial3D in _glow_mats:
		m.emission_energy_multiplier = _energy_base * pulse * boost * dim
	if _light != null:
		_light.light_energy = 3.0 * pulse * boost * (CLOSED_LIGHT if _closed else 1.0)

	if _shaft != null:
		_shaft.rotation.y += delta * (0.12 if _closed else 0.35)

	if _ring != null and _ring.visible:
		var r: float = 1.0 + 0.04 * sin(_pulse_t * 4.0)
		_ring.scale = Vector3(r, 1.0, r)
		var ring_mat := _ring.material_override as StandardMaterial3D
		if ring_mat != null:
			var col: Color = Color.WHITE if _selected else accent.lightened(0.4)
			ring_mat.emission = col
			ring_mat.albedo_color = col
			ring_mat.emission_energy_multiplier = (1.6 if _selected else 0.9) * pulse
