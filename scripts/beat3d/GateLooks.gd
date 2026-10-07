extends RefCounted
class_name GateLooks

## What a gate LOOKS like: the lane blockers, the hurdle, the slide bar, the
## wall plates, and the electrified versions of each.
##
## Lifted out of Section_BeatRunner3d, which had the look of a gate, the rules
## for judging one, the HUD, the pause menu and the track generator all in the
## same eleven thousand lines. The look is the part that gets changed most
## often and depends on the least, so it is the part worth being able to open
## on its own.
##
## It builds out of GatePieces and knows nothing else about the level: the
## measurements come in at construction, and `build()` is the only way in.
##
## ── The electric arcs ────────────────────────────────────────────────────────
## Arc spark lights are collected here as they are made, each tagged with the
## gate it belongs to, so the section can window them to the gates near the
## player instead of lighting the whole song at once. The section reads
## `arc_lights` and `arc_gate_idx` and does that windowing; this only records.

## The geometry this builds out of.
var pieces: GatePieces = null

## Track measurements, from the section that owns this.
var gate_depth: float = 1.1
var lane_blocker_width: float = 1.7
var lane_blocker_height: float = 2.5
var jump_hurdle_height: float = 0.9
var slide_bar_y: float = 1.65
var slide_bar_height: float = 0.45
var track_width: float = 12.0
## Lane centres, in metres from the middle of the track.
var lane_xs: PackedFloat32Array = PackedFloat32Array()

## Every arc spark light built so far, and the gate each one belongs to.
var arc_lights: Array[OmniLight3D] = []
var arc_gate_idx: PackedInt32Array = PackedInt32Array()

## The gate currently being built, so arcs can tag themselves. -1 between gates.
var _building_gate: int = -1
## 1 x 0.055 x 0.055 unit box, scaled per arc segment.
var _seg_mesh: BoxMesh = null


func _init(p_pieces: GatePieces, measurements: Dictionary) -> void:
	pieces = p_pieces
	gate_depth = float(measurements.get("gate_depth", gate_depth))
	lane_blocker_width = float(measurements.get("lane_blocker_width", lane_blocker_width))
	lane_blocker_height = float(measurements.get("lane_blocker_height", lane_blocker_height))
	jump_hurdle_height = float(measurements.get("jump_hurdle_height", jump_hurdle_height))
	slide_bar_y = float(measurements.get("slide_bar_y", slide_bar_y))
	slide_bar_height = float(measurements.get("slide_bar_height", slide_bar_height))
	track_width = float(measurements.get("track_width", track_width))
	lane_xs = measurements.get("lane_xs", lane_xs)


## Builds one gate's look into `vis_root`.
##
## `gate_index` is only for the arcs to tag themselves with; everything else
## about which gate this is stays with the section.
func build(vis_root: Node3D, action: String, safe_lane: int, tint: Color,
		electric: bool, gate_index: int) -> void:
	_building_gate = gate_index
	if electric:
		match action:
			"left", "right":           _vis_elec_lane_gate(vis_root, safe_lane, tint, track_width)
			"jump":                    _vis_elec_jump_gate(vis_root, tint, track_width)
			"slide":                   _vis_elec_slide_gate(vis_root, tint, track_width)
			"wall_left", "wall_right": _vis_elec_wall_gate(vis_root, action, tint)
	else:
		match action:
			"left", "right":           _vis_lane_gate(vis_root, safe_lane, tint, track_width)
			"jump":                    _vis_jump_gate(vis_root, tint, track_width)
			"slide":                   _vis_slide_gate(vis_root, tint, track_width)
			"wall_left", "wall_right": _vis_wall_gate(vis_root, action, tint)
	_building_gate = -1


func _vis_lane_gate(root: Node3D, safe_lane: int, tint: Color, _tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Collect blocked lane indices and group consecutive runs into merged walls.
	var blocked: Array[int] = []
	for ln in range(lane_xs.size()):
		if ln != safe_lane:
			blocked.append(ln)

	# Each consecutive group of blocked lanes becomes one building facade.
	var gi: int = 0
	while gi < blocked.size():
		var group_start: int = gi
		while gi + 1 < blocked.size() and blocked[gi + 1] == blocked[gi] + 1:
			gi += 1
		var group_end: int = gi

		var x_left:  float = lane_xs[blocked[group_start]]
		var x_right: float = lane_xs[blocked[group_end]]
		var cx:      float = (x_left + x_right) * 0.5
		var wall_w:  float = (x_right - x_left) + lane_blocker_width

		# Building facade — dark body + horizontal neon window strips + rooftop cap
		var facade := pieces.facade(
			Vector3(cx, lane_blocker_height * 0.5, 0.0),
			Vector3(wall_w, lane_blocker_height, gate_depth),
			tint, 0.12, 0.45)
		root.add_child(facade)

		gi += 1

	# Neon arch frames the safe-lane opening — the portal the player runs through
	var safe_x: float = lane_xs[safe_lane]
	pieces.arch(root, safe_x, lane_blocker_width * 0.88,
		0.0, lane_blocker_height, bright)

	# Approach runway marks aimed at the safe lane
	pieces.approach_marks(root, safe_x, lane_blocker_width * 0.80, tint)

	# Glowing floor strip in the safe lane — tells the player exactly where to go
	root.add_child(pieces.safe_strip(safe_x, bright))


func _vis_jump_gate(root: Node3D, tint: Color, tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Low building barrier — the obstacle the player jumps over.
	var barrier_facade := pieces.facade(
		Vector3(0.0, jump_hurdle_height * 0.5, 0.0),
		Vector3(tw, jump_hurdle_height, gate_depth),
		tint, 0.11, 0.40)
	root.add_child(barrier_facade)

	# Tall skyscraper towers flanking the gate — same building language as the
	# city backdrop, making the gate feel like it's part of the cityscape.
	# strip_gap 0.90 keeps each tower to ~4 strips max regardless of height.
	var tower_w: float = 1.0
	var tower_h: float = jump_hurdle_height * 3.2
	for side in [-1, 1]:
		var tower := pieces.facade(
			Vector3(side * (tw * 0.5 + tower_w * 0.5 + 0.08), tower_h * 0.5, 0.0),
			Vector3(tower_w, tower_h, gate_depth * 0.75),
			tint.lightened(0.08), 0.10, 0.90)
		root.add_child(tower)

	# Angled kick-plate across the foot of the barrier. A hurdle whose face runs
	# straight down to the floor reads as a wall; a ramped foot reads as
	# something built to be cleared, and the tilt catches light the flat face
	# cannot. Purely visual — it sits inside the existing footprint.
	var kick := pieces.box_mesh(
		Vector3(tw * 0.98, jump_hurdle_height * 0.42, 0.07),
		bright, NeonMat.PANEL, 2.4)
	kick.position   = Vector3(0.0, jump_hurdle_height * 0.16,
		-gate_depth * 0.5 - jump_hurdle_height * 0.10)
	kick.rotation.x = deg_to_rad(-26.0)
	root.add_child(kick)

	# Neon arch framing the airspace the player clears on a good jump.
	# Sits just above the barrier top — clear landmark that says "jump through here".
	pieces.arch(root, 0.0, tw, jump_hurdle_height, jump_hurdle_height + 2.0, tint)

	# Floor approach marks — three hash lines leading up to the barrier
	pieces.approach_marks(root, 0.0, tw, tint)

	# Upward V-chevrons — neon arrow signs on the face of the barrier building
	var chev_size: Vector3 = Vector3(tw * 0.42, 0.11, gate_depth * 0.5)
	var chev_y: float      = jump_hurdle_height + 0.40
	var chev_offset: float = tw * 0.17

	var chev_l := pieces.box_mesh(chev_size, bright)
	chev_l.position   = Vector3(-chev_offset, chev_y, -gate_depth * 0.5 - 0.05)
	chev_l.rotation.z = deg_to_rad(32.0)
	root.add_child(chev_l)

	var chev_r := pieces.box_mesh(chev_size, bright)
	chev_r.position   = Vector3(chev_offset, chev_y, -gate_depth * 0.5 - 0.05)
	chev_r.rotation.z = deg_to_rad(-32.0)
	root.add_child(chev_r)

	# Second smaller chevron above — stacked arrow for readability at speed
	var chev2_l := pieces.box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
	chev2_l.position   = Vector3(-chev_offset * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
	chev2_l.rotation.z = deg_to_rad(32.0)
	root.add_child(chev2_l)

	var chev2_r := pieces.box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
	chev2_r.position   = Vector3(chev_offset * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
	chev2_r.rotation.z = deg_to_rad(-32.0)
	root.add_child(chev2_r)


func _vis_slide_gate(root: Node3D, tint: Color, tw: float) -> void:
	var bright: Color = tint.lightened(0.06)

	# Clearance edge — bottom of the solid overhead wall.
	var clearance_y: float = slide_bar_y - slide_bar_height * 0.5

	# Overhead building facade — the low-ceiling slab the player slides under.
	var solid_h:  float = lane_blocker_height - clearance_y
	var solid_cy: float = clearance_y + solid_h * 0.5
	var overhead_facade := pieces.facade(
		Vector3(0.0, solid_cy, 0.0),
		Vector3(tw, solid_h, gate_depth),
		tint, 0.10, 0.50)
	root.add_child(overhead_facade)

	# Tall flanking towers — frame the gate like a city overpass
	var tower_w: float = 1.0
	var tower_h: float = lane_blocker_height * 1.6
	for side in [-1, 1]:
		var tower := pieces.facade(
			Vector3(side * (tw * 0.5 + tower_w * 0.5 + 0.08), tower_h * 0.5, 0.0),
			Vector3(tower_w, tower_h, gate_depth * 0.75),
			tint.lightened(0.08), 0.10, 0.90)
		root.add_child(tower)

	# Neon arch framing the crawl zone — shows the player exactly the safe gap
	pieces.arch(root, 0.0, tw, 0.0, clearance_y, tint)

	# Floor approach marks leading to the slide zone
	pieces.approach_marks(root, 0.0, tw, tint)

	# Bright limbo bar — the dangerous bottom edge the player has to duck below
	var bar := pieces.box_mesh(
		Vector3(tw + 0.06, 0.10, gate_depth + 0.06), bright)
	bar.position = Vector3(0.0, clearance_y, 0.0)
	root.add_child(bar)

	# Hanging supports dropping from the slab to the limbo bar. The overhang used
	# to float with nothing tying it to the bar beneath it; these give the gap an
	# actual structure and make the clearance line read as engineered.
	var hang_mat: ShaderMaterial = NeonMat.tube(bright, 3.0)
	var hang_size := Vector3(0.07, clearance_y * 0.30, 0.07)
	hang_mat.set_shader_parameter("box_size", hang_size)
	var hang_mesh: BoxMesh = pieces.shared_box(hang_size)
	for hx: float in [-0.62, -0.21, 0.21, 0.62]:
		var hang := MeshInstance3D.new()
		hang.mesh = hang_mesh
		hang.material_override = hang_mat
		hang.position = Vector3(hx * tw * 0.5, clearance_y + hang_size.y * 0.5, 0.0)
		root.add_child(hang)

	# Hazard teeth along the underside of the slab — the surface the player is
	# ducking beneath, and previously the one blank face in the whole gate.
	var tooth_mat: ShaderMaterial = NeonMat.panel(bright, 2.2)
	var tooth_mesh: BoxMesh = pieces.shared_box(Vector3(tw * 0.055, 0.05, gate_depth * 0.5))
	for ti in range(-4, 5):
		var tooth := MeshInstance3D.new()
		tooth.mesh = tooth_mesh
		tooth.material_override = tooth_mat
		tooth.position = Vector3(float(ti) * tw * 0.10, clearance_y + 0.055, 0.0)
		root.add_child(tooth)

	# Downward-pointing indicator below the limbo bar — "duck here" signal
	for side: float in [-1.0, 0.0, 1.0]:
		var arr := pieces.box_mesh(Vector3(0.08, clearance_y * 0.35, 0.06), bright)
		arr.position = Vector3(side * tw * 0.28, clearance_y * 0.5, -gate_depth * 0.5 - 0.04)
		root.add_child(arr)

	# Ground floor strip — shows the safe crawl zone beneath the facade
	var floor_strip := pieces.box_mesh(
		Vector3(tw, 0.04, gate_depth * 0.6), bright)
	floor_strip.position = Vector3(0.0, 0.02, 0.0)
	root.add_child(floor_strip)


# ── Left / Right gate ───────────────────────────────────────────────────────
# Solid walls block the wrong lanes. The safe lane has an open corridor with
# a glowing floor strip and a connecting top-beam tying the walls together.
# ── Jump gate ───────────────────────────────────────────────────────────────
# A full-width ground barrier spans all lanes — player must jump over it.
# Upward chevrons above it make the "jump" intent unambiguous at speed.
# ── Slide gate ──────────────────────────────────────────────────────────────
# A full-width overhead beam spans all lanes — player must slide under it.
# Side pillars support the beam and make it look like a real low obstacle.
func _vis_wall_gate(root: Node3D, action: String, tint: Color) -> void:
	# In a wall_jump section the corridor walls provide the main structural visual.
	# Individual beat gates are large glowing face-plates flush with the corridor wall's
	# inner surface, with directional chevrons so the player knows where to jump.
	var tw: float      = track_width
	var half_tw: float = tw * 0.5
	var is_left: bool  = (action == "wall_left")
	# wall_sign: -1 for left wall (face at -half_tw), +1 for right wall (face at +half_tw)
	var wall_sign: float = -1.0 if is_left else 1.0
	var face_x: float    = wall_sign * half_tw
	# inward: direction from wall toward track centre
	var inward: float    = -wall_sign

	# Large glowing plate — wide enough to read at a glance
	var plate: MeshInstance3D = pieces.box_mesh(
		Vector3(0.38, lane_blocker_height * 1.55, gate_depth * 2.0),
		tint
	)
	plate.position = Vector3(face_x, lane_blocker_height * 0.78, 0.0)
	var pmat: StandardMaterial3D = plate.material_override as StandardMaterial3D
	if pmat != null:
		pmat.emission_energy_multiplier = 4.2
	root.add_child(plate)

	# Point light so it casts colour onto the surrounding corridor
	var pl := OmniLight3D.new()
	pl.light_color  = tint
	pl.light_energy = 1.0
	pl.omni_range   = 9.0
	pl.position = Vector3(face_x + inward * 0.4, lane_blocker_height * 0.78, 0.0)
	root.add_child(pl)

	# Directional chevrons pointing inward — larger than before
	var chev_size: Vector3  = Vector3(0.14, lane_blocker_height * 0.38, gate_depth * 0.55)
	var chev_cx: float      = face_x + inward * 0.55
	var cy: float           = lane_blocker_height * 0.78
	var chev_off: float     = lane_blocker_height * 0.17

	var bright: Color = tint.lightened(0.04)
	var chev_top: MeshInstance3D = pieces.box_mesh(chev_size, bright)
	chev_top.position = Vector3(chev_cx, cy + chev_off, 0.0)
	chev_top.rotation.z = deg_to_rad(-wall_sign * 30.0)
	var ctmat: StandardMaterial3D = chev_top.material_override as StandardMaterial3D
	if ctmat != null: ctmat.emission_energy_multiplier = 5.5
	root.add_child(chev_top)

	var chev_bot: MeshInstance3D = pieces.box_mesh(chev_size, bright)
	chev_bot.position = Vector3(chev_cx, cy - chev_off, 0.0)
	chev_bot.rotation.z = deg_to_rad(wall_sign * 30.0)
	var cbmat: StandardMaterial3D = chev_bot.material_override as StandardMaterial3D
	if cbmat != null: cbmat.emission_energy_multiplier = 5.5
	root.add_child(chev_bot)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ELECTRIC THEME — obstacles + environment                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝


# ── Arc helper ──────────────────────────────────────────────────────────────────
# Four pre-built zigzag "frames" cycle at irregular intervals — the shape snaps
# like real lightning that never holds one form.  A spark sweeps left↔right with
# its own light, so coloured light travels across nearby geometry.
func _make_elec_arc(parent: Node3D, from_x: float, to_x: float, y: float,
		tint: Color, seg_count: int = 8, z_pos: float = 0.0) -> StandardMaterial3D:

	# Shared material — all frames use this; crackle tween drives emission.
	#
	# Electric-zone energies are scaled to ~0.45 of what they were. They were
	# authored against a glow pass that never actually ran (the WorldEnvironment
	# was dead code), so once real bloom arrived, values in the 13-25 range
	# cleared the HDR threshold by more than twenty times over and washed the
	# whole zone white. The crackle RANGE is preserved proportionally, so the
	# lightning still reads as lightning — it just no longer saturates.
	var mat := StandardMaterial3D.new()
	mat.albedo_color               = Color.WHITE
	mat.emission_enabled           = true
	mat.emission                   = tint.lightened(0.4)
	mat.emission_energy_multiplier = 3.2

	# Four distinct zigzag shapes — snapping between them mimics lightning reshaping
	var zz_variants: Array = [
		[0.0,  0.18, -0.12,  0.22, -0.16,  0.14, -0.20,  0.10,  0.0],
		[0.0, -0.16,  0.20, -0.08,  0.18, -0.24,  0.12, -0.15,  0.0],
		[0.0,  0.22, -0.18,  0.10, -0.22,  0.16, -0.08,  0.20,  0.0],
		[0.0, -0.10,  0.24, -0.20,  0.08, -0.18,  0.22, -0.12,  0.0],
	]
	# Irregular display durations — organic, not metronomic
	var frame_times: Array[float] = [0.055, 0.040, 0.070, 0.045]

	var frame_roots: Array[Node3D] = []
	var seg_w: float = (to_x - from_x) / float(seg_count)

	for fi in range(zz_variants.size()):
		var fr := Node3D.new()
		fr.visible = (fi == 0)
		parent.add_child(fr)
		frame_roots.append(fr)

		var zz: Array  = zz_variants[fi]
		var px: float  = from_x
		var py: float  = y + float(zz[0])

		for i in range(seg_count):
			var nx: float  = from_x + seg_w * float(i + 1)
			var ny: float  = y + float(zz[mini(i + 1, zz.size() - 1)])
			var cx: float  = (px + nx) * 0.5
			var cy_: float = (py + ny) * 0.5
			var dx: float  = nx - px
			var dy: float  = ny - py

			var seg := MeshInstance3D.new()
			# Shared unit mesh — scale X instead of allocating a new BoxMesh per segment.
			# Godot 4 can GPU-instance all segments that share this resource.
			if _seg_mesh == null:
				_seg_mesh = BoxMesh.new()
				_seg_mesh.size = Vector3(1.0, 0.055, 0.055)
			seg.mesh = _seg_mesh
			seg.scale.x = sqrt(dx*dx + dy*dy)
			seg.material_override = mat
			seg.position = Vector3(cx, cy_, z_pos)
			seg.rotation.z = atan2(dy, dx)
			fr.add_child(seg)

			px = nx
			py = ny

	# Frame-flip tween — show each frame for its irregular interval, then next.
	# .bind() pins the target index at tween-build time (safe lambda capture).
	var n_frames: int = frame_roots.size()
	var flip_tween := parent.create_tween().set_loops()
	for fi in range(n_frames):
		flip_tween.tween_interval(frame_times[fi])
		var next_fi: int = (fi + 1) % n_frames
		var cb := func(idx: int, roots: Array) -> void:
			for k in range(roots.size()):
				roots[k].visible = (k == idx)
		flip_tween.tween_callback(cb.bind(next_fi, frame_roots))

	# Background crackle on the shared material
	var energies: Array[float] = [3.2, 5.4, 2.3, 4.5, 2.9, 5.9, 2.0, 4.1, 3.4, 5.0]
	var times:    Array[float] = [0.06, 0.03, 0.08, 0.04, 0.065, 0.025, 0.09, 0.04, 0.05, 0.03]
	var ctw := parent.create_tween().set_loops()
	for ei in range(energies.size()):
		ctw.tween_property(mat, "emission_energy_multiplier", energies[ei], times[ei])

	# Traveling spark — sweeps X while frames snap, giving the illusion the spark
	# is always riding a different wire.  Carries OmniLight3D so light moves too.
	var spark := MeshInstance3D.new()
	var sm    := SphereMesh.new()
	sm.radius = 0.08; sm.height = 0.16
	spark.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.albedo_color               = Color.WHITE
	smat.emission_enabled           = true
	smat.emission                   = tint.lightened(0.6)
	smat.emission_energy_multiplier = 11.0   # was 25.0 — see the note on `mat` above
	spark.material_override = smat
	spark.position = Vector3(from_x, y, z_pos)
	parent.add_child(spark)

	# Traveling light — child of spark so it follows automatically; smaller range
	# than before so it only illuminates immediately surrounding geometry.
	var sl := OmniLight3D.new()
	sl.light_color  = tint
	sl.light_energy = 5.0
	sl.omni_range   = 2.5
	spark.add_child(sl)
	# Register in pulse array so the beat flash also hits the traveling light.
	arc_lights.append(sl)
	arc_gate_idx.append(_building_gate)

	var stw := parent.create_tween().set_loops()
	stw.tween_property(spark, "position:x", to_x,   0.20).set_trans(Tween.TRANS_LINEAR)
	stw.tween_property(spark, "position:x", from_x, 0.20).set_trans(Tween.TRANS_LINEAR)

	# No static ambient fill light — the emissive material + traveling spark
	# are sufficient; one fewer OmniLight3D per arc = significant GPU savings.
	return mat


# ── Electric lane gate (left / right) ────────────────────────────────────────
# Fence posts on blocked lane edges; arcing electricity spans the blocked span.
# Safe lane keeps approach marks + floor strip just like the city theme.
func _vis_elec_lane_gate(root: Node3D, safe_lane: int, tint: Color, _tw: float) -> void:
	var blocked: Array[int] = []
	for ln in range(lane_xs.size()):
		if ln != safe_lane:
			blocked.append(ln)

	var gi: int = 0
	while gi < blocked.size():
		var group_start: int = gi
		while gi + 1 < blocked.size() and blocked[gi + 1] == blocked[gi] + 1:
			gi += 1
		var group_end: int = gi

		var x_left:  float = lane_xs[blocked[group_start]] - lane_blocker_width * 0.5
		var x_right: float = lane_xs[blocked[group_end]]   + lane_blocker_width * 0.5

		# Fence posts at group edges
		for px: float in [x_left, x_right]:
			var post := pieces.fence_post(lane_blocker_height)
			post.position.x = px
			root.add_child(post)

		# Mid-height arc
		_make_elec_arc(root, x_left, x_right, lane_blocker_height * 0.52, tint)
		# Upper arc near post caps
		_make_elec_arc(root, x_left, x_right, lane_blocker_height * 0.90, tint, 6, -0.02)

		gi += 1

	# No floor cues in here. Everywhere else the three approach marks and the
	# safe-lane strip paint the way through; an electric zone is a blackout lit
	# only by the gates themselves, and reading the gate IS the challenge. The
	# arch stays — it is part of the gate, not a hint about which lane to take.
	var safe_x: float = lane_xs[safe_lane]
	pieces.arch(root, safe_x, lane_blocker_width * 0.88, 0.0, lane_blocker_height, tint)


# ── Electric jump gate ────────────────────────────────────────────────────────
# Low live-wire arc across the full track — player jumps over it.
func _vis_elec_jump_gate(root: Node3D, tint: Color, tw: float) -> void:
	var from_x: float = -tw * 0.5 - 0.4
	var to_x:   float =  tw * 0.5 + 0.4
	var bright: Color = tint.lightened(0.06)

	# Outer frame posts
	for px: float in [from_x - 0.1, to_x + 0.1]:
		var post := pieces.fence_post(lane_blocker_height)
		post.position.x = px
		root.add_child(post)

	# The low arc the player must jump over
	_make_elec_arc(root, from_x, to_x, jump_hurdle_height * 0.55, tint)
	# Ground crackle — low voltage context strip
	_make_elec_arc(root, from_x, to_x, jump_hurdle_height * 0.20, tint, 6, 0.02)

	# Upward V-chevrons (same read as city jump gate)
	var chev_size: Vector3 = Vector3(tw * 0.42, 0.11, gate_depth * 0.5)
	var chev_y: float      = jump_hurdle_height + 0.40
	var chev_off: float    = tw * 0.17
	for sign: float in [-1.0, 1.0]:
		var chev := pieces.box_mesh(chev_size, bright)
		chev.position   = Vector3(sign * chev_off, chev_y, -gate_depth * 0.5 - 0.05)
		chev.rotation.z = deg_to_rad(-sign * 32.0)
		root.add_child(chev)
		var chev2 := pieces.box_mesh(chev_size * Vector3(0.7, 0.8, 1.0), bright)
		chev2.position   = Vector3(sign * chev_off * 0.7, chev_y + 0.32, -gate_depth * 0.5 - 0.05)
		chev2.rotation.z = deg_to_rad(-sign * 32.0)
		root.add_child(chev2)


# ── Electric slide gate ───────────────────────────────────────────────────────
# High overhead live-wire arc — player slides under it.
func _vis_elec_slide_gate(root: Node3D, tint: Color, tw: float) -> void:
	# Visual bar sits higher than the physics clearance so it reads unambiguously
	# as "ceiling overhead" rather than "low wire on ground". The hitbox is still
	# governed by slide_bar_y in the physics — this is display only.
	var clearance_y: float = lane_blocker_height * 0.82   # ~2.05 — clearly overhead
	var from_x: float = -tw * 0.5 - 0.4
	var to_x:   float =  tw * 0.5 + 0.4
	var bright: Color = tint.lightened(0.06)

	# SHORT posts — only up to clearance_y, NOT full height.
	# This is the key visual distinction from the jump gate:
	# jump = tall posts + low wire at ground (go OVER)
	# slide = short posts + ceiling wire at head height (go UNDER)
	for px: float in [from_x - 0.1, to_x + 0.1]:
		var post := pieces.fence_post(clearance_y)
		post.position.x = px
		root.add_child(post)

	# Solid limbo bar at clearance_y — the hard electric ceiling
	var bar := pieces.box_mesh(Vector3(tw + 0.10, 0.10, gate_depth + 0.10), bright)
	bar.position = Vector3(0.0, clearance_y, 0.0)
	var bmat := bar.material_override as StandardMaterial3D
	if bmat != null: bmat.emission_energy_multiplier = 5.5
	root.add_child(bar)

	# Live-wire arcs sizzling along the bar (on top of the solid obstacle)
	_make_elec_arc(root, from_x, to_x, clearance_y + 0.06, tint)
	_make_elec_arc(root, from_x, to_x, clearance_y + 0.22, tint, 6, -0.02)

	# Large downward-pointing chevrons — "DUCK DOWN" signal
	var chev_h: float  = clearance_y * 0.40
	var chev_offset: float = tw * 0.22
	for sign: float in [-1.0, 0.0, 1.0]:
		var chev := pieces.box_mesh(Vector3(0.10, chev_h, 0.07), bright)
		chev.position = Vector3(sign * chev_offset, clearance_y * 0.45, -gate_depth * 0.5 - 0.05)
		root.add_child(chev)

	# Floor strip — bright crawl zone marker
	var floor_strip := pieces.box_mesh(Vector3(tw, 0.05, gate_depth * 0.7), bright)
	floor_strip.position = Vector3(0.0, 0.025, 0.0)
	var fsmat := floor_strip.material_override as StandardMaterial3D
	if fsmat != null: fsmat.emission_energy_multiplier = 2.5
	root.add_child(floor_strip)


# ── Electric wall gate ────────────────────────────────────────────────────────
# Stacked horizontal arcs on the correct corridor wall — wall-jump target.
func _vis_elec_wall_gate(root: Node3D, action: String, tint: Color) -> void:
	var tw: float        = track_width
	var half_tw: float   = tw * 0.5
	var is_left: bool    = (action == "wall_left")
	var wall_sign: float = -1.0 if is_left else 1.0
	var face_x: float    = wall_sign * half_tw
	var inward: float    = -wall_sign

	# Wall post / anchor
	var post := pieces.fence_post(lane_blocker_height * 1.6)
	post.position.x = face_x
	root.add_child(post)

	# Three stacked horizontal arcs extending inward from wall face
	var arc_ys: Array[float] = [
		lane_blocker_height * 0.38,
		lane_blocker_height * 0.78,
		lane_blocker_height * 1.18,
	]
	var arm_len: float = 0.90
	for ay: float in arc_ys:
		var ax0: float = face_x
		var ax1: float = face_x + inward * arm_len
		_make_elec_arc(root, minf(ax0, ax1), maxf(ax0, ax1), ay, tint, 5, 0.0)

	# Colour light thrown into the corridor
	var light := OmniLight3D.new()
	light.light_color  = tint
	light.light_energy = 1.0
	light.omni_range   = 9.0
	light.position     = Vector3(face_x + inward * 0.5, lane_blocker_height * 0.78, 0.0)
	root.add_child(light)
