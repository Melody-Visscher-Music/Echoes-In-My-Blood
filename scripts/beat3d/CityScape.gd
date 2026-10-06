extends RefCounted
class_name CityScape

## The skyline standing behind the track: towers, their window materials and
## their roof lights.
##
## It came out of Section_BeatRunner3d, which did not need another 230 lines of
## set dressing in among the chart logic. The split is on who owns what: the
## section owns the beat and says when to strike, the city owns what it is made
## of and how it answers. Nothing in here knows what a gate is.

var _mats:      Array[StandardMaterial3D] = []
var _lights:    Array[OmniLight3D]        = []
var _light_pds: PackedFloat32Array        = PackedFloat32Array()
## Monotonic cursor into _light_pds — the roof lights near the player are the
## only ones worth writing to, and the player only ever moves forwards.
var _cursor:    int   = 0
## 0-1, set to 1 on each beat by strike(), decayed by pulse().
var _pulse_t:   float = 0.0

## Set by build(), so the two halves do not both need the arguments.
var piece_lib: Variant = null
var path_pos:    Callable = Callable()
var path_yrot:   Callable = Callable()
var is_electric: Callable = Callable()
var track_width: float = 0.0
var song_end_z:  float = 0.0


## A beat landed. The decay happens in pulse().
func strike() -> void:
	_pulse_t = 1.0


## Materials whose emission this city drives, for a caller that wants to sweep
## them itself (see Section_BeatRunner3d's colour cycle).
func materials() -> Array:
	return _mats


## Builds the skyline. The callables are the section's own path queries —
## a city that laid itself out in world Z would drift off a track that turns.
func build(root: Node3D, lib: Variant, song_end: float, width: float,
		pos_fn: Callable, yrot_fn: Callable, electric_fn: Callable) -> void:
	piece_lib = lib
	song_end_z = song_end
	track_width = width
	path_pos = pos_fn
	path_yrot = yrot_fn
	is_electric = electric_fn
	# Skyline density is a quality-tier knob (was a hard-coded 18). Each building
	# costs a body mesh, an occluder, a window MultiMesh and a roof light.
	var max_bldgs_per_side: int = maxi(2,
		int(GraphicsQuality.get_setting("city_buildings_per_side", 18)))
	var end_z: float = song_end_z
	var tw:    float = track_width

	var body_col: Color = Color(0.04, 0.02, 0.08, 1.0)
	# Two distance rows — closer row is bigger buildings, far row is taller/thinner
	var dist_rows: Array[float] = [tw * 0.5 + 16.0, tw * 0.5 + 30.0]

	var building_templates: Array = [
		[4.0, 5.0, 14.0], [3.0, 4.0, 10.0], [5.5, 6.0, 20.0],
		[2.5, 3.5,  8.0], [4.5, 5.0, 24.0], [3.5, 4.0, 12.0],
		[6.0, 6.5, 28.0], [2.8, 3.5,  9.0], [4.0, 5.0, 16.0],
	]

	var win_palette: Array[Color] = [
		Color(1.00, 0.25, 0.60, 1.0),
		Color(0.20, 0.80, 1.00, 1.0),
		Color(0.65, 0.10, 1.00, 1.0),
		Color(1.00, 0.85, 0.10, 1.0),
		Color(0.30, 1.00, 0.55, 1.0),
		Color(0.90, 0.25, 1.00, 1.0),
	]

	# Authored Blender buildings ("building") — the game cycles through ALL
	# authored ones; the far row is stretched taller/thinner exactly like the
	# procedural templates. "Windows" emissives pulse with the city beat.
	var bldg_entries: Array = (piece_lib.of_type("building") if piece_lib != null else [])

	# One window material PER PALETTE COLOUR, not per building. Every building
	# picks its colour out of win_palette, and the beat pulse writes the exact same
	# emission energy to all of them, so ~56 identical-behaving materials collapse
	# to 6 with pixel-identical output — and _update_city_pulse's material loop
	# collapses with them.
	var win_mats: Array[StandardMaterial3D] = []
	for pc: Color in win_palette:
		var wm := StandardMaterial3D.new()
		wm.albedo_color               = pc.darkened(0.30)
		wm.emission_enabled           = true
		wm.emission                   = pc
		wm.emission_energy_multiplier = 0.8
		win_mats.append(wm)
		_mats.append(wm)

	# (path distance, light) pairs, sorted at the end — the loops below run
	# side-major then row-major, so bz is not globally increasing as it goes.
	var city_light_pairs: Array = []

	var bldg_i: int = 0

	for side in [-1, 1]:
		for ri in dist_rows.size():
			var dist: float = dist_rows[ri]
			# Spread max_bldgs_per_side buildings evenly across the track length
			var step: float = end_z / float(max_bldgs_per_side)
			for bi in max_bldgs_per_side:
				var bz:   float = step * 0.4 + float(bi) * step + float(ri) * step * 0.5
				if is_electric.call(bz):
					bldg_i += 1
					continue

				if not bldg_entries.is_empty():
					var b_entry: Dictionary = bldg_entries[bldg_i % bldg_entries.size()]
					var b_anchor := Node3D.new()
					b_anchor.position           = path_pos.call(bz, float(side) * dist, 0.0)
					b_anchor.rotation_degrees.y = path_yrot.call(bz)
					if ri == 1:
						b_anchor.scale = Vector3(0.65, 1.4, 1.0)   # far row: taller + thinner
					root.add_child(b_anchor)
					var b_inst: Node3D = piece_lib.instance(b_entry)
					b_inst.rotation_degrees.y = 180.0
					b_anchor.add_child(b_inst)
					_register_emissives(b_inst, _mats)

					var b_h: float = float(b_entry.params.get("height", 14.0)) * b_anchor.scale.y
					var b_rlight := OmniLight3D.new()
					b_rlight.light_color  = win_palette[(bldg_i + ri * 3) % win_palette.size()]
					b_rlight.light_energy = 0.5
					b_rlight.omni_range   = 10.0
					b_rlight.position     = path_pos.call(bz, float(side) * dist, b_h + 0.8)
					# Range 10 m and well past the fog wall for most of the song — let
					# the renderer drop it, like the gem / arch / ambient lights already do.
					b_rlight.distance_fade_enabled = true
					b_rlight.distance_fade_begin   = 140.0
					b_rlight.distance_fade_length  = 40.0
					root.add_child(b_rlight)
					city_light_pairs.append([bz, b_rlight])

					bldg_i += 1
					continue

				var tmpl: Array = building_templates[bldg_i % building_templates.size()]
				var bw: float   = tmpl[0] as float
				var bd: float   = tmpl[1] as float
				var bh: float   = tmpl[2] as float
				# Far row: taller and thinner
				if ri == 1:
					bw *= 0.65; bh *= 1.4
				var blat: float = float(side) * dist

				# ── Dark silhouette ──────────────────────────────────────────
				var body := MeshInstance3D.new()
				var bm   := BoxMesh.new()
				bm.size = Vector3(bw, bh, bd)
				body.mesh = bm
				var body_mat := StandardMaterial3D.new()
				body_mat.albedo_color               = body_col
				body_mat.emission_enabled           = false
				body.material_override = body_mat
				body.position = path_pos.call(bz, blat, bh * 0.5)
				body.rotation_degrees.y = path_yrot.call(bz)
				root.add_child(body)

				# Occluder matched exactly to the opaque body's own bounds —
				# lets Godot's occlusion culling skip rendering anything fully
				# hidden behind a building (from another building, decorations,
				# etc.) without touching frustum culling, which already runs
				# regardless. Only added for procedural bodies, where the exact
				# box dimensions are known; authored buildings are skipped here
				# rather than guessing at bounds and risking something visible
				# getting incorrectly culled.
				var occ := OccluderInstance3D.new()
				var box_occ := BoxOccluder3D.new()
				box_occ.size = Vector3(bw, bh, bd)
				occ.occluder = box_occ
				occ.position = body.position
				occ.rotation_degrees.y = body.rotation_degrees.y
				root.add_child(occ)

				# ── Window strips — one MultiMesh per building instead of one
				# MeshInstance3D per strip. Every strip in a building already
				# shares the same box size and Y-rotation (only its height
				# differs), so batching them is a pure draw-call win — the
				# shared win_mat / _mats pulse system below is
				# completely untouched, it just now recolors a
				# MultiMeshInstance3D's material_override instead of N
				# individual MeshInstance3Ds.
				var win_idx: int   = (bldg_i + ri * 3) % win_palette.size()
				var win_col: Color = win_palette[win_idx]
				var win_mat: StandardMaterial3D = win_mats[win_idx]

				var strip_h:  float = 0.14
				var strip_gap: float = 2.2
				var strip_rot: float = path_yrot.call(bz)
				var strip_positions: Array[Vector3] = []
				var win_y:    float = strip_gap
				while win_y < bh - 0.5:
					strip_positions.append(path_pos.call(bz, blat, win_y + strip_h * 0.5))
					win_y += strip_gap

				if not strip_positions.is_empty():
					var strip_mesh := BoxMesh.new()
					strip_mesh.size = Vector3(bw + 0.04, strip_h, 0.10)

					var strip_mm := MultiMesh.new()
					strip_mm.transform_format = MultiMesh.TRANSFORM_3D
					strip_mm.mesh = strip_mesh
					strip_mm.instance_count = strip_positions.size()
					var strip_basis := Basis.IDENTITY.rotated(Vector3.UP, deg_to_rad(strip_rot))
					for si in range(strip_positions.size()):
						strip_mm.set_instance_transform(si, Transform3D(strip_basis, strip_positions[si]))

					var strip_mmi := MultiMeshInstance3D.new()
					strip_mmi.multimesh = strip_mm
					strip_mmi.material_override = win_mat
					root.add_child(strip_mmi)

				# ── One roof light per building ───────────────────────────────
				var rlight := OmniLight3D.new()
				rlight.light_color  = win_col
				rlight.light_energy = 0.5
				rlight.omni_range   = 10.0
				rlight.position     = path_pos.call(bz, blat, bh + 0.8)
				# Range 10 m and well past the fog wall for most of the song — let the
				# renderer drop it, like the gem / arch / ambient lights already do.
				rlight.distance_fade_enabled = true
				rlight.distance_fade_begin   = 140.0
				rlight.distance_fade_length  = 40.0
				root.add_child(rlight)
				city_light_pairs.append([bz, rlight])

				bldg_i += 1

	# Sort the roof lights by path distance so _update_city_pulse can window them.
	city_light_pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_lights.clear()
	_light_pds = PackedFloat32Array()
	for pair: Array in city_light_pairs:
		_light_pds.append(pair[0])
		_lights.append(pair[1])


## Decays the strike and writes it to the window materials and the roof
## lights near the player. Everything the section knows and the city does
## not comes in as arguments.
## `glow` is how much of the skyline survives — 1.0 normally, near zero inside
## an electric blackout, where the only light allowed is the gates.
func pulse(delta: float, vitality: float, beat_s_in: float, player_pd: float,
		window_behind: float, window_ahead: float, glow: float = 1.0) -> void:
	if _pulse_t <= 0.0:
		return
	var beat_s: float = max(0.18, beat_s_in)
	_pulse_t = maxf(0.0, _pulse_t - delta / (beat_s * 0.55))

	var vit: float = vitality
	# Vitality scales the peak burst: at low vitality buildings barely flicker;
	# at high vitality they strobe hard on every beat.
	var peak_e:  float = lerpf(0.5, 2.5, vit)
	var peak_l:  float = lerpf(0.15, 1.8, vit)
	var energy:  float = lerpf(lerpf(0.1, 0.6, vit), peak_e, _pulse_t)
	var light_e: float = lerpf(lerpf(0.0, 0.3, vit), peak_l, _pulse_t)

	# Six shared palette materials rather than one per building (see
	# _spawn_city_buildings), so this loop is a handful of writes.
	for mat in _mats:
		mat.emission_energy_multiplier = energy * glow

	# Roof lights are per building and every one gets the SAME energy, so walk
	# only the slice near the player — same monotonic cursor + early break as
	# _world_gem_lights in _update_color_cycle.
	var pd: float = player_pd
	var lo: float = pd - window_behind
	var hi: float = pd + window_ahead
	while _cursor < _light_pds.size() \
			and _light_pds[_cursor] < lo:
		_cursor += 1
	for i in range(_cursor, _lights.size()):
		if i >= _light_pds.size() or _light_pds[i] > hi:
			break
		_lights[i].light_energy = light_e * glow

## Walks an authored piece and collects every emissive material it owns, so a
## Blender-made tower pulses with the procedural ones instead of sitting
## stubbornly lit while everything around it breathes.
func _register_emissives(node: Node, into: Array) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for i in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(i)
			var std := mat as StandardMaterial3D
			if std != null and std.emission_enabled and not into.has(std):
				into.append(std)
	for child: Node in node.get_children():
		_register_emissives(child, into)

