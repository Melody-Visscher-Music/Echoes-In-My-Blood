class_name StoryRift
extends Node3D

## One echo rift on the Story Mode map — the map's stand-in for a level.
##
## PLACEHOLDER ART, except the tear itself, which is real swept geometry — see
## _build_tear(). Everything around it (halo, shaft, ring) is still a primitive.
##
## ONE kind of rift. There used to be two, GROUND and WALL, differing only in
## how tall the tear was and where its cracks started; that existed to stop a
## cluster reading as three identical decals on the tarmac, back when the tear
## was a flat card and a card is all it could ever look like. A solid tear that
## wanders differently every frame does that job on its own.
##
## TODO(art): replace _build_rift() with the authored rift meshes + the rift
## shader once they exist. The public surface here — setup(),
## set_revealed(), set_selected(), set_hovered(), pick_radius() — is what the
## map talks to, so real art can land behind it without touching StoryMap.gd.
##
## The city around a rift stays mundane on purpose: no debris, no decay props,
## no ruined blocks. The ONE exception is the ground a rift opens in, which is
## genuinely fractured — see _build_cracks(). Everything past those cracks is an
## ordinary intact street, and that contrast is the whole visual idea.

## Emitted when the player clicks this rift. StoryMap does the picking (screen
## space, not physics) and calls `press()`, so this stays a pure visual.
signal picked(node_id: String)

## Metres of slack around the rift's screen position that still counts as a
## click on it. Generous on purpose — the camera sits at map distance, so a
## rift is only a handful of pixels across.
const PICK_RADIUS_M: float = 5.5

## The hot centre of every tear, shared across rifts. The node's own accent is
## the EDGE colour, so rifts stay tellable apart while the core reads as the
## same energy in all of them — bright enough that it has stopped having a hue.
const CORE_COL: Color = Color(1.00, 0.78, 0.42)
## The opening behind the glow. Not pure black: a rift is a hole into somewhere,
## and somewhere is never quite nothing.
const VOID_COL: Color = Color(0.030, 0.020, 0.055)

var node_id: String = ""
var title: String = ""
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

# ── Flicker ──────────────────────────────────────────────────────────────────
## How many alternative bolt shapes are built per rift. Cheap — each frame is a
## couple of dozen vertices — and five is enough that the cycle never reads as a
## loop at the rate they are swapped.
## Frames in the animation LOOP, played in order.
##
## These used to be 1500 unrelated shapes jumped between at random, which is
## what made the tear read as snapping rather than moving. They are now one
## continuous cycle: frame f is a smooth function of f, and the last frame joins
## the first, so playing them in sequence is smooth motion and the loop never
## shows a seam. Far fewer are needed for that — a hundred and twenty related
## shapes animate better than fifteen hundred unrelated ones, and cost a
## twelfth of the meshes to build.
const FLICKER_FRAMES: int = 120
## Frames per second of playback. With FLICKER_FRAMES above, the loop runs
## three seconds; the wobble harmonics in _zigzag_line are set against that.
const FLICKER_FPS: float = 40.0
## A closed rift barely moves. It is sealed, not dead.
const FLICKER_CLOSED_SCALE: float = 15.0
## Extra emission laid on by a scripted beat, decaying away.
const FLICKER_FLASH: float = 0.55
const FLICKER_FLASH_DECAY: float = 7.0

# ── Crack surges ─────────────────────────────────────────────────────────────
const CRACK_SHADER: String = "res://shaders/story/rift_crack.gdshader"
const CRACK_ENERGY: float = 7.5
## The tear's core runs hotter than the cracks it feeds — but only a little.
## Giving the core its own material meant it could finally outrun the shared
## pulse, and the first go at that overshot: the centre blew out and took the
## edge colour with it, so the rift stopped reading as two tones.
const CORE_ENERGY: float = 3.2
## How far a crack's seam dims toward its tip. The core uses 1.0 — no fade.
const CRACK_FALLOFF: float = 0.22
## Crack-lengths per second the pulse travels. Fast enough to read as a
## discharge rather than as something crawling.
const SURGE_SPEED: float = 1.15
## Quiet time between surges. Long compared with the tear's flicker on purpose:
## the bolt is continuously unstable, but the ground only takes a hit now and
## then, and a constant stream of pulses turns the cracks into fairy lights.
const SURGE_GAP_MIN: float = 0.7
const SURGE_GAP_MAX: float = 2.1
## A closed rift discharges into the ground far less often.
const SURGE_CLOSED_SCALE: float = 4.0

## Each entry: {"instances": Array[MeshInstance3D], "frames": Array[ArrayMesh]}
var _flicker_layers: Array[Dictionary] = []
var _flicker_t: float = 0.0
var _flicker_frame: int = 0
var _flash: float = 0.0
## Extra output laid over the breathing pulse by a scripted beat - 1.0 is the
## rift behaving normally. Beats drive THIS rather than writing the emission
## straight onto the materials, because _process rewrites those every frame:
## the reveal flourish used to tween the materials directly and was overwritten
## before it could be seen.
var _drive: float = 1.0
var _rng := RandomNumberGenerator.new()

## Prebuilt shapes this rift flickers between. FLICKER_FRAMES on the map, which
## can afford them; a level asks for far fewer — see setup().
var _frames: int = FLICKER_FRAMES


## Crack seams. One ShaderMaterial per rift; the surge position is a uniform, so
## animating a fracture costs one float per frame no matter how long it is.
var _crack_mats: Array[ShaderMaterial] = []
## The tear's core. Same shader, same surge value — one discharge lights the
## bolt and then races out along the ground, instead of two effects that happen
## to look alike.
var _core_mats: Array[ShaderMaterial] = []
## Where the current surge has reached, 0..1, or negative while none is running.
var _surge: float = -1.0
var _surge_wait: float = 0.0


## Builds the rift. `accent_col` is the saturated rift colour — the one thing on
## the map allowed to be bright.
##
## `frames` is how many tear shapes to prebuild. Every one of them is three
## meshes generated at load, so the map's full FLICKER_FRAMES is a few thousand
## meshes per rift — worth it there, where the rifts ARE the screen and there
## are ten of them to tell apart. A level uses the same rift as a doorway for a
## few seconds at each end, so it asks for a fraction of that. The flicker steps
## by a random amount rather than in sequence, so a short list still never
## visibly repeats.
func setup(id: String, node_title: String, accent_col: Color,
		frames: int = FLICKER_FRAMES) -> void:
	node_id = id
	title   = node_title
	accent  = accent_col
	_frames = maxi(2, frames)

	_content = Node3D.new()
	_content.name = "Content"
	add_child(_content)

	_build_rift()
	_build_shared()
	# Offset per rift, so a cluster of three does not run in unison and read as
	# one animation playing on three objects.
	_rng.seed = hash(id) ^ 0x5EED
	_flicker_t = _rng.randf() * float(_frames)
	# Hidden until the map says otherwise: locked rifts are not on the map at
	# all, so nothing here may be visible before set_revealed() allows it.
	visible = false


## Turns the rift to face `target` on the XZ plane. The tear has no front any
## more, but the cracks and the halo do, and a rift still wants to open toward
## its street rather than across it.
func face_toward(target: Vector3) -> void:
	var to: Vector3 = target - global_position
	to.y = 0.0
	if to.length_squared() < 0.001:
		return
	rotation.y = atan2(to.x, to.z)



## The tear is a generated zigzag ribbon, not a primitive. Nothing in the box
## library makes a lightning-bolt silhouette, and that hard angular break is the
## whole read of a rift — a smooth wedge looked like a lamppost.
##
## Three layers, back to front:
##
##   VOID  — widest, near-black. The opening itself. Without it the glow floats
##           on the city instead of being a hole in it.
##   EDGE  — the node's accent colour, additive, flanking the core.
##   CORE  — narrow and near-white hot. Colour lives in the edge; the core is
##           the part that is too bright to have a colour.
##
## Each layer is a SWEPT PRISM around a path that wanders in all three axes —
## real geometry, not cards. Everything before it was a flat ribbon dressed up:
## first turned to face the camera, then crossed with a second ribbon, then
## fanned into three. All of those are the same trick, and at the distance a
## level puts the player from a rift the trick is what you see.
##
## The three layers are concentric tubes, so their CULL MODES are what let all
## three be visible at once — see the materials below.


func _build_rift() -> void:
	# One standing tear, no floor copy. It is tall and wide enough that what
	# survives the map camera's foreshortening is still a bolt, and the cracks
	# spreading from its foot are what locate it from directly above.
	_build_tear(_content, Vector3(0.0, 0.0, 0.0), 10.4, 1.8, 1.05, 11)

	_ring_mesh("Halo", 3.2, 3.8, Vector3(0.0, 0.04, 0.0), accent, 0.9)
	_build_cracks(_content, Vector3(0.0, 0.05, 0.0), 8)


## Builds one three-layer tear at `at`, `height` tall.
##
## Each layer is a SWEPT PRISM around a path that wanders in all three axes.
##
## This was a flat card for a long time, with three goes at making a card look
## three-dimensional — turned to face the camera, then crossed with a second
## card, then fanned into three. All the same trick, and from a camera that
## comes anywhere close the trick is what you see.
##
## The three layers are concentric tubes, so their CULL MODES are what let all
## three be visible at once — see the materials below.
func _build_tear(parent: Node3D, at: Vector3, height: float, width: float,
		jag: float, steps: int) -> void:
	var tear := Node3D.new()
	tear.name = "Tear"
	tear.position = at
	parent.add_child(tear)

	# One centreline per frame of the loop, shared by all three layers.
	var lines: Array = []
	for f in _frames:
		lines.append(_zigzag_line(height, jag, steps, float(f) / float(_frames)))

	var layers: Array = [
		["Void", width * 1.95, jag, VOID_COL, 0.0, false],
		["Edge", width * 1.15, jag, accent, 4.2, true],
		["Core", width * 0.40, jag, CORE_COL, 9.0, true],
	]
	for layer: Array in layers:
		var frames: Array = []
		for line: PackedVector3Array in lines:
			frames.append(_zigzag_mesh(line, float(layer[1])))
		var mesh: ArrayMesh = frames[0]
		# OPAQUE, not additive. The reference gets its punch from glow over a
		# black room; Calder City is a bright grey daylight street, and additive
		# over that just washes to pale lavender — every early pass of this came
		# out looking bleached. Solid unshaded colour holds its saturation
		# against a light background, and the bloom still catches the core.
		var mat: Material
		if String(layer[0]) == "Core":
			# Only the core carries the surge. Putting it on the edge too made
			# the whole bolt strobe; confined to the centre it reads as
			# something travelling THROUGH the tear, which is the point.
			var sm := ShaderMaterial.new()
			sm.shader = load(CRACK_SHADER) as Shader
			sm.set_shader_parameter("tint", layer[3] as Color)
			sm.set_shader_parameter("energy", CORE_ENERGY)
			sm.set_shader_parameter("surge", -1.0)
			# The tear is evenly lit end to end; only cracks fade along their run.
			sm.set_shader_parameter("falloff_to", 1.0)
			_core_mats.append(sm)
			mat = sm
		elif bool(layer[5]):
			mat = _glow_mat(layer[3] as Color, float(layer[4]))
			(mat as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_FRONT
		else:
			# The void is a real hole, so it is unlit as well as unshaded.
			var vm := StandardMaterial3D.new()
			vm.albedo_color = layer[3] as Color
			vm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			# Near wall culled, which is the trick that makes three concentric
			# opaque tubes work at all: the void is the widest, so drawn
			# normally it is a black shell hiding the edge and the core inside
			# it. Showing only each layer's FAR wall stacks them back to front
			# the way the old flat ribbons did, but in the round — and without
			# transparency, which the bright map background would wash out.
			vm.cull_mode    = BaseMaterial3D.CULL_FRONT
			mat = vm

		# No depth nudge: the layers are nested tubes of different radii and
		# never share a surface to fight over.
		var mi := MeshInstance3D.new()
		mi.name = String(layer[0])
		mi.mesh = mesh
		mi.material_override = mat
		tear.add_child(mi)
		_flicker_layers.append({"instances": [mi] as Array[MeshInstance3D], "frames": frames})


## The tear's centreline at `phase` (0-1 through the loop): one turning point
## per step, wandering in all three axes.
##
## The centreline is generated ONCE per frame and all three layers are built
## from it, so the core always sits inside the edge and the edge inside the
## void. Generating them separately let the layers drift apart and the tear came
## out looking like three unrelated bolts stacked up.
##
## Every turning point moves on its OWN pair of sine waves, seeded from the rift
## id and the point's index so they are stable across frames. Two things follow
## from that, and both matter:
##
##   * the shape at phase f is a small step from the shape at phase f-1, so
##     playing the frames in order is smooth motion rather than snapping;
##   * the harmonics are WHOLE numbers of cycles per loop, so phase 1 lands
##     exactly on phase 0 and the loop closes with no seam.
func _zigzag_line(height: float, jag: float, steps: int, phase: float) -> PackedVector3Array:
	var line := PackedVector3Array()
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		# Fat in the middle, pinched at both ends, so the tear closes rather
		# than stopping dead.
		var taper: float = pow(sin(t * PI), 0.45)

		var rng := RandomNumberGenerator.new()
		rng.seed = hash(node_id) ^ (i * 7919 + 13)
		# Two harmonics per point, one slow and one quick, so the wander never
		# settles into an obvious rhythm. Against a three-second loop these run
		# at roughly 0.7-1.3 Hz and 1.3-2.7 Hz — a live shimmer rather than a
		# sway, and slow enough that no vertex crosses much more than a tenth of
		# a metre between frames.
		var f1: float = float(rng.randi_range(2, 4))
		var f2: float = float(rng.randi_range(4, 8))
		var p1: float = rng.randf_range(0.0, TAU)
		var p2: float = rng.randf_range(0.0, TAU)
		var w: float = 0.76 * sin(TAU * phase * f1 + p1) \
			+ 0.24 * sin(TAU * phase * f2 + p2)

		# The kick alternates sides the way a bolt does, then swings OUT of that
		# plane by a per-point amount. A planar zigzag is a flat object however
		# it is meshed, so the swing is half of what makes this
		# three-dimensional — the swept prism alone would not have got there.
		#
		# It is deliberately not a full coil. Spreading the turning points right
		# around the axis (the golden angle) is more three-dimensional and reads
		# WORSE: from map distance it projects as a compact tangle instead of a
		# tall zigzag, and the zigzag is the shape doing the work. Alternating
		# with depth keeps the silhouette and is still solid from every bearing.
		var side: float = 0.0 if i % 2 == 0 else PI
		var ang: float = side + rng.randf_range(-1.05, 1.05) + w * 0.45
		var off: float = jag * taper * (0.95 + 0.40 * w)
		# The height of each turning point is FIXED across the loop. Letting it
		# breathe as well made the whole bolt bob up and down, which reads as the
		# object moving rather than the lightning inside it.
		var y: float = t * height + rng.randf_range(-0.18, 0.18) * height / float(steps)
		line.append(Vector3(cos(ang) * off, y, sin(ang) * off))
	return line


## Sides on the swept prism. Three, not more: a lightning bolt wants flat
## facets meeting at hard angles, and every extra side rounds it toward a pipe.
const TEAR_SIDES: int = 3

## A solid prism of the given width swept along a 3D centreline.
##
## The cross-section is carried by a PARALLEL-TRANSPORT frame rather than being
## rebuilt from a fixed up-vector at each ring. A fixed reference makes the
## prism spin about its own axis wherever the path turns steeply — which this
## path does at every single turning point, by design — and the twisting shows
## up as the facets shearing along the bolt. Transport carries the previous
## ring's orientation forward through the turn, so the facets stay aligned.
func _zigzag_mesh(line: PackedVector3Array, width: float) -> ArrayMesh:
	var count: int = line.size()
	if count < 2:
		return ArrayMesh.new()

	# Tangents, from the neighbours on either side.
	var tans := PackedVector3Array()
	for i in count:
		var a: Vector3 = line[maxi(i - 1, 0)]
		var b: Vector3 = line[mini(i + 1, count - 1)]
		var d: Vector3 = b - a
		tans.append(d.normalized() if d.length_squared() > 0.000001 else Vector3.UP)

	# Seed the frame with any vector perpendicular to the first tangent.
	var n: Vector3 = tans[0].cross(Vector3.RIGHT)
	if n.length_squared() < 0.001:
		n = tans[0].cross(Vector3.FORWARD)
	n = n.normalized()

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var last: int = count - 1

	for i in count:
		var tan: Vector3 = tans[i]
		if i > 0:
			# Rotate the frame by the same turn the path just took.
			var axis: Vector3 = tans[i - 1].cross(tan)
			var s: float = axis.length()
			if s > 0.0001:
				n = n.rotated(axis / s, asin(clampf(s, -1.0, 1.0)))
			# Re-orthogonalise: the rotation above is exact, floating point is not.
			n = (n - tan * n.dot(tan)).normalized()
		var bi: Vector3 = tan.cross(n).normalized()

		var t: float = float(i) / float(last)
		var taper: float = pow(sin(t * PI), 0.45)
		var r: float = width * 0.5 * maxf(taper, 0.12)
		for k in TEAR_SIDES:
			var a: float = TAU * float(k) / float(TEAR_SIDES)
			var dir: Vector3 = n * cos(a) + bi * sin(a)
			verts.append(line[i] + dir * r)
			normals.append(dir)
			# u runs 0 at the foot of the tear to 1 at its top, so the surge
			# shader can send a pulse climbing it exactly as it sends one along
			# a crack. v goes round the prism.
			uvs.append(Vector2(t, float(k) / float(TEAR_SIDES)))

	for i in last:
		var b0: int = i * TEAR_SIDES
		var b1: int = (i + 1) * TEAR_SIDES
		for k in TEAR_SIDES:
			var k2: int = (k + 1) % TEAR_SIDES
			indices.append_array([
				b0 + k, b1 + k, b1 + k2,
				b0 + k, b1 + k2, b0 + k2,
			])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Fractures spreading out from the foot of the tear.
##
## These ARE damage — the pavement is genuinely split here, which is the one
## place the city is allowed to be broken. Everywhere else it stays an ordinary
## intact street; a rift tears the ground it opens in and nothing further.
##
## Each crack is a tapering fissure that closes to a point, built in two layers:
## a dark gap and a narrower glowing seam sitting just inside it. The dark layer
## is what makes it a crack rather than a painted line — light on its own reads
## as a decal, but a black split with light down the middle reads as depth.
##
## Their wander is random per vertex rather than a regular zigzag: the tear is
## deliberately rhythmic because it is not of this world, and the cracks it
## causes should not share that rhythm.
func _build_cracks(parent: Node3D, at: Vector3, count: int) -> void:
	var root := Node3D.new()
	root.name = "Cracks"
	root.position = at
	parent.add_child(root)

	# Seeded off the node id, so a given rift always fractures the same way but
	# no two rifts fracture alike.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(node_id)

	var gap: StandardMaterial3D = StandardMaterial3D.new()
	gap.albedo_color = VOID_COL
	gap.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gap.cull_mode    = BaseMaterial3D.CULL_DISABLED
	var seam := ShaderMaterial.new()
	seam.shader = load(CRACK_SHADER) as Shader
	seam.set_shader_parameter("tint", accent.lightened(0.2))
	seam.set_shader_parameter("energy", CRACK_ENERGY)
	seam.set_shader_parameter("surge", -1.0)
	# Set rather than left to the shader's default, so the two users of this
	# shader both state what they want and neither drifts if the default moves.
	seam.set_shader_parameter("falloff_to", CRACK_FALLOFF)
	_crack_mats.append(seam)

	for i in count:
		var a: float = TAU * float(i) / float(count) + rng.randf_range(-0.22, 0.22)
		_crack_arm(root, rng, gap, seam, a, rng.randf_range(4.6, 8.2),
			rng.randf_range(0.55, 0.85), 0)


## One fissure, plus whatever it forks into.
func _crack_arm(parent: Node3D, rng: RandomNumberGenerator, gap: StandardMaterial3D,
		seam: ShaderMaterial, angle: float, length: float, width: float,
		depth: int) -> void:
	var arm := Node3D.new()
	arm.name = "Crack"
	arm.rotation.y = -angle
	parent.add_child(arm)

	var start: float = 1.9 if depth == 0 else 0.0
	var jag: float = width * 0.85
	var steps: int = maxi(4, int(length * 1.3))

	var fissure := MeshInstance3D.new()
	fissure.name = "Gap"
	fissure.mesh = _crack_mesh(rng.randi(), length, width, jag, steps)
	fissure.material_override = gap
	fissure.position = Vector3(start, 0.0, 0.0)
	arm.add_child(fissure)

	# The seam re-uses the same wander (same sub-seed) at a narrower width, so
	# the light sits inside the gap instead of wandering out of it.
	var light := MeshInstance3D.new()
	light.name = "Seam"
	light.mesh = _crack_mesh(rng.get_seed(), length * 0.94, width * 0.38, jag, steps)
	light.material_override = seam
	light.position = Vector3(start, 0.012, 0.0)
	arm.add_child(light)

	if depth == 0 and rng.randf() < 0.7:
		for _f in rng.randi_range(1, 2):
			var t: float = rng.randf_range(0.35, 0.68)
			var branch := Node3D.new()
			branch.name = "Fork"
			branch.position = Vector3(start + length * t, 0.0, 0.0)
			arm.add_child(branch)
			_crack_arm(branch, rng, gap, seam,
				rng.randf_range(0.45, 1.0) * (1.0 if rng.randf() < 0.5 else -1.0),
				length * rng.randf_range(0.35, 0.55), width * 0.55, 1)


## A flat fissure lying in the XZ plane, running out along +X and closing to a
## point at the tip. `sub_seed` drives the wander so two meshes can be given the
## same crooked centreline at different widths.
func _crack_mesh(sub_seed: int, length: float, width: float, jag: float,
		steps: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = sub_seed

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var drift: float = 0.0
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		# Tapers to nothing, so a crack ends rather than stopping.
		var taper: float = pow(1.0 - t, 0.75)
		var half: float = maxf(width * 0.5 * taper, 0.012)
		# The centreline drifts by a random step each vertex and is pulled back
		# toward straight, which wanders without ever doubling back on itself.
		drift = drift * 0.62 + rng.randf_range(-jag, jag) * 0.5
		var across: float = drift * (0.35 + 0.65 * t)
		verts.append(Vector3(t * length, 0.0, across - half))
		verts.append(Vector3(t * length, 0.0, across + half))
		normals.append(Vector3(0.0, 1.0, 0.0))
		normals.append(Vector3(0.0, 1.0, 0.0))
		# u runs 0 at the rift to 1 at the tip; the surge shader reads it.
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))

	for i in steps:
		var b: int = i * 2
		indices.append_array([b, b + 1, b + 3, b, b + 3, b + 2])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A flat glowing ring lying on the ground.
func _ring_mesh(ring_name: String, inner: float, outer: float, pos: Vector3,
		col: Color, energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = ring_name
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 28
	mesh.ring_segments = 8
	mi.mesh = mesh
	mi.material_override = _glow_mat(col, energy)
	mi.position = pos
	_content.add_child(mi)
	return mi


func _disc(disc_name: String, radius: float, pos: Vector3, col: Color,
		energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = disc_name
	var mesh := CylinderMesh.new()
	mesh.top_radius      = radius
	mesh.bottom_radius   = radius
	mesh.height          = 0.05
	mesh.radial_segments = 20
	mesh.rings           = 1
	mi.mesh = mesh
	mi.material_override = _glow_mat(col, energy)
	mi.position = pos
	_content.add_child(mi)
	return mi


func _box(parent: Node3D, piece_name: String, pos: Vector3, size: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = piece_name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


## Parts outside the tear itself: the light, the vertical shaft that makes the rift
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


func _glow_mat(col: Color, energy: float, track: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color               = col.darkened(0.2)
	m.emission_enabled           = true
	m.emission                   = col
	m.emission_energy_multiplier = energy
	m.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	# `track` off means the caller drives this one itself — the crack seams run
	# on their own delayed phase and must not be overwritten by the shared pulse.
	if track:
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
	_drive = 4.0
	tw.parallel().tween_property(self, "_drive", 1.0, 1.1)


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


## Radius in metres that counts as a hit for picking.
func pick_radius() -> float:
	return PICK_RADIUS_M


## Where a screen-space label or pick test should anchor — head height, not the
## origin, so a rift set against a wall still points at the rift, not the kerb.
func anchor_point() -> Vector3:
	return global_position + Vector3(0.0, 3.0, 0.0)


## The entry beat: the rift opening up to take Meeko in. A swell and a surge,
## where the reveal is a pop - the reveal says "this is new", this says "this is
## taking you".
##
## TODO(cutscene): the real beat is a cutscene. This stands in for its timing so
## the flow around it (camera move, walker, scene change) is already correct.
## `delay` holds the rift at its normal output while Meeko takes his last step
## — the surge belongs to him going through, not to him walking up.
func open_for_entry(delay: float, seconds: float) -> void:
	if _content == null:
		return
	# The selection ring is a cursor, and a cursor has done its job by now.
	# Left on, it swells with the rest of the rift and ends up a white hoop
	# filling the screen.
	if _ring != null:
		_ring.visible = false
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_interval(delay)
	tw.tween_callback(func() -> void: _flash = FLICKER_FLASH)
	tw.tween_property(_content, "scale", Vector3.ONE * 1.45, seconds)
	tw.parallel().tween_property(self, "_drive", 3.2, seconds)


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

	_update_flicker(delta)
	# The flash rides on top of the breathing pulse rather than replacing it, so
	# a snap brightens whatever the rift was already doing.
	var lit: float = pulse * boost * dim * (1.0 + _flash) * _drive

	for m: StandardMaterial3D in _glow_mats:
		m.emission_energy_multiplier = _energy_base * lit
	if _light != null:
		var closed_light: float = CLOSED_LIGHT if _closed else 1.0
		_light.light_energy = 3.0 * pulse * boost * (1.0 + _flash * 0.6) * closed_light * _drive

	_update_surge(delta)
	# Cracks run a quarter-cycle behind the tear, which reads as the discharge
	# reaching the ground a moment after the bolt rather than everything in the
	# rift breathing as one object.
	var crack_pulse: float = 0.7 + 0.3 * sin(_pulse_t * rate - PI * 0.5)
	var crack_energy: float = CRACK_ENERGY * crack_pulse * boost * dim * (1.0 + _flash * 0.5) * _drive
	for cm: ShaderMaterial in _crack_mats:
		cm.set_shader_parameter("energy", crack_energy)
		cm.set_shader_parameter("surge", _surge)

	for core: ShaderMaterial in _core_mats:
		core.set_shader_parameter("energy", CORE_ENERGY * lit)
		core.set_shader_parameter("surge", _surge)

	if _ring != null and _ring.visible:
		var r: float = 1.0 + 0.04 * sin(_pulse_t * 4.0)
		_ring.scale = Vector3(r, 1.0, r)
		var ring_mat := _ring.material_override as StandardMaterial3D
		if ring_mat != null:
			var col: Color = Color.WHITE if _selected else accent.lightened(0.4)
			ring_mat.emission = col
			ring_mat.albedo_color = col
			ring_mat.emission_energy_multiplier = (1.6 if _selected else 0.9) * pulse


## Runs a pulse of light out along the cracks, then waits before the next one.
##
## The surge is a position, not a brightness: the shader turns it into a band
## and every crack of the rift reads the same number, so one float per frame
## animates all of them however many segments they have.
func _update_surge(delta: float) -> void:
	if _crack_mats.is_empty():
		return

	if _surge >= 0.0:
		_surge += SURGE_SPEED * delta
		if _surge <= 1.0:
			return
		# Past the tips — go quiet until the next discharge.
		_surge = -1.0
		var scale: float = SURGE_CLOSED_SCALE if _closed else 1.0
		_surge_wait = _rng.randf_range(SURGE_GAP_MIN, SURGE_GAP_MAX) * scale
		return

	_surge_wait -= delta
	if _surge_wait <= 0.0:
		_surge = 0.0


## Snaps the tear to a different shape at irregular intervals.
##
## Every layer of every tear shows the SAME frame index, so the core, edge and
## void stay nested. Swapping a prebuilt mesh is effectively free — no vertices
## are touched at runtime, only which mesh each instance points at.
func _update_flicker(delta: float) -> void:
	_flash = maxf(0.0, _flash - _flash * FLICKER_FLASH_DECAY * delta - 0.01 * delta)
	if _flicker_layers.is_empty():
		return

	# Straight through the loop at a steady rate. This used to jump to a random
	# frame at a random interval, which is what made the tear snap; the frames
	# are a continuous cycle now, so playing them in order is the whole of the
	# smooth motion.
	var rate: float = FLICKER_FPS / (FLICKER_CLOSED_SCALE if _closed else 1.0)
	_flicker_t = fposmod(_flicker_t + delta * rate, float(_frames))
	var f: int = clampi(int(_flicker_t), 0, _frames - 1)
	if f == _flicker_frame:
		return
	_flicker_frame = f

	for layer: Dictionary in _flicker_layers:
		var frames: Array = layer["frames"]
		for mi: MeshInstance3D in (layer["instances"] as Array[MeshInstance3D]):
			mi.mesh = frames[_flicker_frame]
