extends RefCounted
class_name GatePieces

## The pieces a track is built out of: boxes, building facades, neon arches,
## floor marks. Everything that turns numbers into geometry, with no opinion
## about what the geometry is for.
##
## This used to live in Section_BeatRunner3d with everything else. It is the
## part that gets edited whenever a gate or a prop should look different, so it
## is the part worth being able to open on its own — and nothing in here reads
## the level, only the handful of measurements handed over at construction.
##
## Meshes and materials are cached and shared: a level asks for the same box and
## the same facade hundreds of times, and the gates have no randomness in them.
## One of these per level; it goes away with the level.

## Track measurements, from the section that owns this.
var gate_depth: float = 1.1
var lane_blocker_width: float = 1.7
## Graphics tier: 0 cuts the trimmings, 2 is everything.
var detail: int = 2
## Lane centres, in metres from the middle of the track.
var lane_xs: PackedFloat32Array = PackedFloat32Array()
## Authored Blender pieces, when the level found any. May be null.
var pieces: TrackPieceLibrary = null

## Shared box meshes by size, and merged multi-box meshes by shape.
var _box_mesh_cache: Dictionary = {}
var _merged_mesh_cache: Dictionary = {}
## The dark body every building facade shares.
var _facade_body_mat: StandardMaterial3D = null


func _init(p_gate_depth: float, p_blocker_width: float, p_detail: int,
		p_lane_xs: PackedFloat32Array, p_pieces: TrackPieceLibrary = null) -> void:
	gate_depth = p_gate_depth
	lane_blocker_width = p_blocker_width
	detail = p_detail
	lane_xs = p_lane_xs
	pieces = p_pieces


func box_mesh(size: Vector3, color: Color,
		role: String = NeonMat.TUBE, energy: float = 3.0) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = shared_box(size)
	var mat: ShaderMaterial = NeonMat.make(role, color, energy)
	# neon_tube derives its core from the bar's long axis in object space, which
	# it can only know from the box's own dimensions — a BoxMesh's per-face UVs
	# carry no consistent orientation.
	mat.set_shader_parameter("box_size", size)
	mi.material_override = mat

	# store original color so color cycling can preserve shape identity
	mi.set_meta("base_color", color)

	return mi


func shared_box(size: Vector3) -> BoxMesh:
	var key: String = "%d,%d,%d" % [
		int(round(size.x * 1000.0)), int(round(size.y * 1000.0)), int(round(size.z * 1000.0))]
	if _box_mesh_cache.has(key):
		return _box_mesh_cache[key]
	var bm := BoxMesh.new()
	bm.size = size
	_box_mesh_cache[key] = bm
	return bm


## `role` picks the shader: NeonMat.TUBE for bars, posts and beams (hot core,
## falls off to the edges) or NeonMat.PANEL for flat faces (border, scanlines).
## Defaults to TUBE because most callers are bars.


## Several boxes of one material as a SINGLE mesh, cached by shape.
##
## A level's gates were 75 nodes each — 31,000 of them — and almost all of that
## was rows of window strips and corner pillars, one MeshInstance3D per box, all
## sharing one material. Merged they are one node and one draw call, and the
## pixels are the same: every box keeps its own 0..1 UVs, which is all the neon
## shaders read. Nothing in a gate is randomised, so the same facade on the next
## gate is the same mesh and comes back out of this cache.
##
## `boxes` is an array of [size: Vector3, offset: Vector3].
func merged_boxes(key: String, boxes: Array) -> ArrayMesh:
	if _merged_mesh_cache.has(key):
		return _merged_mesh_cache[key]

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tris := PackedInt32Array()
	for box: Array in boxes:
		var bm := BoxMesh.new()
		bm.size = box[0] as Vector3
		var arrays: Array = bm.get_mesh_arrays()
		var at: Vector3 = box[1]
		var base: int = verts.size()
		for v: Vector3 in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			verts.append(v + at)
		norms.append_array(arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)
		uvs.append_array(arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array)
		for i: int in (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array):
			tris.append(base + i)

	var out := ArrayMesh.new()
	var surface: Array = []
	surface.resize(Mesh.ARRAY_MAX)
	surface[Mesh.ARRAY_VERTEX] = verts
	surface[Mesh.ARRAY_NORMAL] = norms
	surface[Mesh.ARRAY_TEX_UV] = uvs
	surface[Mesh.ARRAY_INDEX] = tris
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
	_merged_mesh_cache[key] = out
	return out


# ── Building-facade helper ────────────────────────────────────────────────────
# The shared body of every lane blocker, jump barrier, slide overhang and
# flanking tower. Improving this one function reaches all of them at once, which
# is why the geometry work concentrates here.
#
# It used to be a dark box with horizontal strips on the front face and a bright
# cap — literally a black cube with coloured stripes, and worse, one that only
# read as anything from dead ahead: the sides were bare, so a facade flattened
# out the moment it entered peripheral vision.
#
# What actually breaks the cube read, in order of how much each contributes:
#   • CORNER PILLARS. Four lit vertical edges describe the volume from every
#     angle, so the shape survives being passed at speed. Biggest single win.
#   • A SETBACK CROWN. An inset upper block under the cap gives a stepped
#     silhouette instead of one flat top line.
#   • A PLINTH. A short base block grounds it rather than letting it float.
#   • A CENTRE SPINE and SIDE STRIPS, which break the horizontal banding and
#     stop the sides being dead.
#
# The outer bound never exceeds `size` on X — the pillars sit flush with the
# body's own corners and the crown insets inward — so nothing here implies a
# bigger obstacle than the gameplay footprint the player is judging.
func facade(pos: Vector3, size: Vector3, win_col: Color,
		strip_h: float = 0.12, strip_gap: float = 0.45) -> Node3D:
	var node     := Node3D.new()
	node.position = pos

	var detail: int = detail
	var half_y: float = size.y * 0.5
	var front_z: float = -size.z * 0.5

	# Dark silhouette body — gives the obstacle mass without bleeding emission
	var body     := MeshInstance3D.new()
	body.mesh     = shared_box(size)
	# The same near-black for every facade in the level, so it is made once
	# rather than a thousand times over.
	if _facade_body_mat == null:
		_facade_body_mat = StandardMaterial3D.new()
		_facade_body_mat.albedo_color     = Color(0.045, 0.025, 0.09, 1.0)
		_facade_body_mat.emission_enabled = false
	body.material_override    = _facade_body_mat
	body.set_meta("no_cycle", true)   # never recolored by the color cycle system
	node.add_child(body)

	# One shared material for every strip on this facade (no per-strip overhead)
	var win_mat: ShaderMaterial = NeonMat.panel(win_col, 2.0)

	# Front-face strips — one mesh per row, facing the approaching player. Inset
	# from the full width so the corner pillars below frame them rather than
	# colliding with them.
	var strip_w: float = size.x - (0.16 if detail > 0 else -0.02)
	var y_local: float = -half_y + strip_gap
	var strip_boxes: Array = []
	while y_local < half_y - strip_h:
		strip_boxes.append([Vector3(strip_w, strip_h, 0.06),
			Vector3(0.0, y_local, front_z - 0.03)])

		# Matching stubs on the left/right faces, so the facade still reads as a
		# solid object once it is beside the player instead of in front of them.
		if detail > 1:
			for sx: float in [-1.0, 1.0]:
				strip_boxes.append([Vector3(0.05, strip_h, size.z * 0.55),
					Vector3(sx * (size.x * 0.5 + 0.02), y_local, 0.0)])

		y_local += strip_gap

	if not strip_boxes.is_empty():
		var strips := MeshInstance3D.new()
		strips.mesh = merged_boxes("strips|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%d" % [
			size.x, size.y, size.z, strip_w, strip_h, strip_gap, detail], strip_boxes)
		strips.material_override = win_mat
		node.add_child(strips)

	if detail > 0:
		# ── Corner pillars ──────────────────────────────────────────────────
		# One material and one mesh shared by all four: neon_tube needs box_size
		# to find its core axis, and identical dimensions mean identical
		# uniforms, so this stays a single draw setup.
		var pillar_size := Vector3(0.075, size.y * 0.99, 0.075)
		var pillar_mat: ShaderMaterial = NeonMat.tube(win_col.lightened(0.18), 3.2)
		pillar_mat.set_shader_parameter("box_size", pillar_size)
		var pillar_boxes: Array = []
		for px: float in [-1.0, 1.0]:
			for pz: float in [-1.0, 1.0]:
				pillar_boxes.append([pillar_size, Vector3(px * (size.x * 0.5 - 0.03), 0.0,
					pz * (size.z * 0.5 - 0.03))])
		var pillars := MeshInstance3D.new()
		pillars.mesh = merged_boxes("pillars|%.3f,%.3f,%.3f" % [size.x, size.y, size.z],
			pillar_boxes)
		pillars.material_override = pillar_mat
		node.add_child(pillars)

		# ── Base plinth ─────────────────────────────────────────────────────
		var plinth := MeshInstance3D.new()
		plinth.mesh = shared_box(Vector3(size.x * 0.99, 0.14, size.z * 1.05))
		plinth.material_override = _facade_body_mat
		plinth.position = Vector3(0.0, -half_y + 0.07, 0.0)
		plinth.set_meta("no_cycle", true)
		node.add_child(plinth)

	# ── Vertical spine ──────────────────────────────────────────────────────
	# Only on facades tall enough to have a middle worth breaking up.
	if detail > 1 and size.y > 0.9:
		var spine := MeshInstance3D.new()
		spine.mesh = shared_box(Vector3(0.10, size.y * 0.72, 0.05))
		spine.material_override = win_mat
		spine.position = Vector3(0.0, 0.0, front_z - 0.05)
		node.add_child(spine)

	# ── Setback crown + cap ─────────────────────────────────────────────────
	# Short facades (jump hurdles, slide overhangs) skip the setback: on those
	# the cap IS the readable edge and insetting it would soften the very line
	# the player is judging their clearance against.
	var cap_w: float = size.x + 0.06
	var cap_d: float = size.z + 0.06
	var cap_y: float = half_y + 0.04
	if detail > 0 and size.y > 1.6:
		var crown_h: float = size.y * 0.09
		var crown := MeshInstance3D.new()
		crown.mesh = shared_box(Vector3(size.x * 0.76, crown_h, size.z * 0.80))
		crown.material_override = _facade_body_mat
		crown.position = Vector3(0.0, half_y + crown_h * 0.5, 0.0)
		crown.set_meta("no_cycle", true)
		node.add_child(crown)
		cap_w = size.x * 0.76 + 0.06
		cap_d = size.z * 0.80 + 0.06
		cap_y = half_y + crown_h + 0.04

	# Bright rooftop cap — same cap style as city buildings
	var cap := box_mesh(Vector3(cap_w, 0.08, cap_d),
		win_col.lightened(0.30), NeonMat.TUBE, 4.5)
	cap.position = Vector3(0.0, cap_y, 0.0)
	node.add_child(cap)

	return node


## Shared BoxMesh cache, keyed on size to the millimetre.
##
## Every part of every gate used to allocate its own BoxMesh, so a level built
## thousands of byte-identical meshes that the renderer had no way to batch.
## Nothing mutates a mesh after _make_box_mesh returns (callers only touch
## transform and material_override), so one instance per distinct size is safe.
## The dictionary lives on the section node, which is rebuilt per level.


# ── Gate arch helper ─────────────────────────────────────────────────────────
# Draws a bright neon rectangular frame (two posts + top beam) around the zone
# the player must pass through.  Makes gates feel like designed track landmarks
# rather than background props.
func arch(root: Node3D, cx: float, width: float,
		bot_y: float, top_y: float, tint: Color) -> void:
	var bright := tint.lightened(0.04)
	var pw     := 0.10            # post / beam cross-section
	var h      := top_y - bot_y
	var cy     := bot_y + h * 0.5

	# Posts and beam are tubes: hot core, falling off to the edges, so the
	# portal reads as lit neon rather than three glowing bricks.
	const ARCH_E: float = 5.5

	# Left post
	var lp := box_mesh(Vector3(pw, h, pw), bright, NeonMat.TUBE, ARCH_E)
	lp.position = Vector3(cx - width * 0.5 - pw * 0.5, cy, 0.0)
	root.add_child(lp)
	# Right post
	var rp := box_mesh(Vector3(pw, h, pw), bright, NeonMat.TUBE, ARCH_E)
	rp.position = Vector3(cx + width * 0.5 + pw * 0.5, cy, 0.0)
	root.add_child(rp)
	# Top beam
	var tb := box_mesh(Vector3(width + pw * 2.0 + 0.08, pw, pw), bright, NeonMat.TUBE, ARCH_E)
	tb.position = Vector3(cx, top_y + pw * 0.5, 0.0)
	root.add_child(tb)
	# Corner caps — brighter and slightly proud of the join, so the frame reads
	# as assembled hardware rather than three bars that happen to touch.
	for sx: float in [-1.0, 1.0]:
		var corner := box_mesh(
			Vector3(pw * 1.9, pw * 1.9, pw * 1.9), bright.lightened(0.25), NeonMat.TUBE, ARCH_E * 1.4)
		corner.position = Vector3(cx + sx * (width * 0.5 + pw * 0.5), top_y + pw * 0.5, 0.0)
		root.add_child(corner)


# ── Approach runway helper ────────────────────────────────────────────────────
# Three neon hash marks on the floor extending toward the player, clearly
# marking "gate ahead" on the track surface.
func approach_marks(root: Node3D, cx: float, width: float, tint: Color) -> void:
	# Authored Blender "ApproachMarks" replace the procedural hash lines —
	# stretched sideways so they fit lane-width AND full-track gates alike.
	var entry: Dictionary = (pieces.first_of("marks") if pieces != null else {})
	if not entry.is_empty():
		var auth_w: float = maxf(0.1, float(entry.params.get("width", 5.2)))
		var inst: Node3D = pieces.instance(entry)
		inst.position           = Vector3(cx, 0.0, 0.0)
		inst.rotation_degrees.y = 180.0
		inst.scale.x            = width / auth_w
		root.add_child(inst)
		return
	# Flat floor pieces are the ideal panel case — the scrolling scanline gives
	# the "gate ahead" cue actual motion for one extra instruction, no texture.
	#
	# One MultiMeshInstance3D rather than three MeshInstance3Ds: the three hash
	# marks are the same mesh and the same material, and there are three of them
	# on every gate in the song. Same pattern as _spawn_floor_grid.
	var bright := tint.darkened(0.05)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = shared_box(Vector3(width * 0.80, 0.03, 0.14))
	mm.instance_count = 3
	for i: int in 3:
		mm.set_instance_transform(i,
			Transform3D(Basis(), Vector3(cx, 0.015, -(1.2 + float(i) * 1.3))))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mark_mat: ShaderMaterial = NeonMat.panel(bright, 3.4)
	mark_mat.set_shader_parameter("scan_speed", 1.6)
	mark_mat.set_shader_parameter("scan_scale", 6.0)
	mmi.material_override = mark_mat
	root.add_child(mmi)


# Glowing safe-lane floor strip — authored Blender "SafeStrip" when present
# (author it centred at lane x = 0; the game positions it per gate).


func safe_strip(safe_x: float, tint: Color) -> Node3D:
	var entry: Dictionary = (pieces.first_of("strip") if pieces != null else {})
	if not entry.is_empty():
		var wrap := Node3D.new()
		wrap.position = Vector3(safe_x, 0.01, 0.0)
		var inst: Node3D = pieces.instance(entry)
		inst.rotation_degrees.y = 180.0
		wrap.add_child(inst)
		return wrap
	var strip := box_mesh(
		Vector3(lane_blocker_width * 0.7, 0.04, gate_depth * 1.2), tint, NeonMat.PANEL, 3.0)
	NeonMat.set_param(strip.material_override, "scan_speed", 1.2)
	strip.position = Vector3(safe_x, 0.02, 0.0)
	return strip


# Slim dark-metal fence post at local origin; caller must set .position.x
# Authored "fence_post" pieces replace the procedural box, stretched to `height`.
func fence_post(height: float) -> Node3D:
	var entry: Dictionary = (pieces.first_of("fence_post") if pieces != null else {})
	if not entry.is_empty():
		var auth_h: float = maxf(0.1, float(entry.params.get("height", 2.5)))
		@warning_ignore("shadowed_global_identifier")
		var wrap := Node3D.new()
		var inst: Node3D = pieces.instance(entry)
		inst.rotation_degrees.y = 180.0
		inst.scale.y = height / auth_h
		wrap.add_child(inst)
		return wrap

	var post := MeshInstance3D.new()
	var bm   := BoxMesh.new()
	bm.size  = Vector3(0.14, height, 0.14)
	post.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.14, 0.18, 1.0)
	mat.metallic     = 0.80
	mat.roughness    = 0.30
	post.material_override = mat
	post.position.y = height * 0.5
	return post
