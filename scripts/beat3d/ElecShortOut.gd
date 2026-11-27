extends Node3D
class_name ElecShortOut

## A missed gate in an electric zone does not shatter like the others: it
## shorts out. The gate strobes, arcs jump off its bars into Meeko as he runs
## on through it, it blows in a spray of molten sparks and goes dark. Arcs keep
## crawling over him for a moment afterwards, lit by their own flicker.
##
## Purely cosmetic, like the rest of RunnerFlair: the miss, its damage and its
## sound are the section's. RunnerFlair owns one and calls fire() instead of
## its shard burst when the missed gate is a live one.
##
## Everything that flashes is scaled by GameConfig.flash_scale(); with reduced
## flashing the gate fades out instead of strobing and the arcs do not flicker.

const _COL_ARC: Color = Color(0.72, 0.9, 1.0)
const _COL_CORE: Color = Color(0.95, 0.98, 1.0)

const _BOLT_POOL: int = 7
const _BOLT_SEGS: int = 12
const _REJAG_S: float = 0.035

## The gate's life after the miss: strobe, then blow, then gone.
const _STROBE_S: float = 0.30
const _DEAD_S: float = 0.55

var section: Node = null
var player: Node3D = null
var world: Node3D = null

var _seg_mesh: BoxMesh = null
var _bolts: Array[Dictionary] = []
var _bolt_i: int = 0
var _gates: Array[Dictionary] = []      # {gate, idx, mats, base_e, t, blown, pts}
var _molten: CPUParticles3D = null
var _pops: Array[Dictionary] = []       # {node, mat, t}
var _pop_i: int = 0
var _body_light: OmniLight3D = null
var _body_t: float = 0.0
var _gate_light: OmniLight3D = null
var _gate_light_t: float = 0.0


func _init() -> void:
	name = "ElecShortOut"


func setup(p_section: Node, p_player: Node3D, p_world: Node3D) -> void:
	section = p_section
	player = p_player
	world = p_world
	_seg_mesh = BoxMesh.new()
	_seg_mesh.size = Vector3.ONE
	for k in _BOLT_POOL:
		var root := Node3D.new()
		root.top_level = true
		world.add_child(root)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = _COL_ARC
		mat.emission_enabled = true
		mat.emission = _COL_ARC
		mat.emission_energy_multiplier = 6.0
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var segs: Array[MeshInstance3D] = []
		for s in _BOLT_SEGS:
			var mi := MeshInstance3D.new()
			mi.mesh = _seg_mesh
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_meta("no_cycle", true)
			mi.visible = false
			root.add_child(mi)
			segs.append(mi)
		_bolts.append({"root": root, "mat": mat, "segs": segs, "life": 0.0, "max": 1.0,
			"a": Vector3.ZERO, "a_off": Vector3.ZERO, "on_body": false, "thick": 0.05,
			"rejag": 0.0, "jitter": 0.3})

	# Molten metal off the bars: white-hot drops that cool to orange and fall.
	var sm := SphereMesh.new()
	sm.radius = 0.035
	sm.height = 0.07
	sm.radial_segments = 6
	sm.rings = 3
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.vertex_color_use_as_albedo = true
	dm.emission_enabled = true
	dm.emission = Color(1.0, 0.65, 0.3)
	dm.emission_energy_multiplier = 5.0
	sm.material = dm
	_molten = CPUParticles3D.new()
	_molten.one_shot = true
	_molten.emitting = false
	_molten.amount = 70
	_molten.lifetime = 0.9
	_molten.explosiveness = 0.9
	_molten.local_coords = false
	_molten.mesh = sm
	_molten.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_molten.emission_box_extents = Vector3(1.6, 1.0, 0.25)
	# Thrown forward along the track, so the spray overtakes the camera and
	# arcs out past him into view before it falls behind.
	_molten.direction = Vector3(0, 0.55, -1)
	_molten.spread = 30.0
	_molten.initial_velocity_min = 9.0
	_molten.initial_velocity_max = 17.0
	_molten.gravity = Vector3(0, -16, 0)
	_molten.scale_amount_min = 0.6
	_molten.scale_amount_max = 1.4
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 1.0, 0.95))
	ramp.add_point(0.25, Color(0.7, 0.9, 1.0))
	ramp.set_color(ramp.get_point_count() - 1, Color(1.0, 0.35, 0.05))
	_molten.color_ramp = ramp
	var shrink := Curve.new()
	shrink.add_point(Vector2(0, 1))
	shrink.add_point(Vector2(1, 0.2))
	_molten.scale_amount_curve = shrink
	_molten.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(_molten)

	# The blow: a flat ring of light snapping out from the gate.
	for k in 2:
		var tm := TorusMesh.new()
		tm.inner_radius = 0.9
		tm.outer_radius = 1.0
		tm.rings = 40
		tm.ring_segments = 6
		var rm: ShaderMaterial = NeonMat.ring(_COL_ARC, 0.0)
		var n := MeshInstance3D.new()
		n.mesh = tm
		n.material_override = rm
		n.set_meta("no_cycle", true)
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.visible = false
		world.add_child(n)
		_pops.append({"node": n, "mat": rm, "t": -1.0})

	# He is the brightest thing in the blackout for a moment: the arcs light him.
	_body_light = OmniLight3D.new()
	_body_light.light_color = _COL_ARC
	_body_light.light_energy = 0.0
	_body_light.omni_range = 7.0
	_body_light.visible = false
	player.add_child(_body_light)
	_body_light.position = Vector3(0.0, 1.0, 0.0)
	_gate_light = OmniLight3D.new()
	_gate_light.light_color = _COL_ARC
	_gate_light.light_energy = 0.0
	_gate_light.omni_range = 12.0
	_gate_light.visible = false
	world.add_child(_gate_light)


## The missed gate `gate` (index `idx`) shorts out.
func fire(gate: Node3D, idx: int) -> void:
	if gate == null or not is_instance_valid(gate):
		return
	var mats: Array = []
	var all: Array = section.get("_gate_cycle_mats")
	if idx < all.size():
		mats = (all[idx] as Array).duplicate()
	var base_e: Array = []
	for m: Material in mats:
		base_e.append(NeonMat.get_energy(m) if m != null else 0.0)
	# Where the arcs leave from: the gate's own bars, nearest him first.
	var pts: Array[Vector3] = []
	var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
	if vis != null:
		for mi: Node in vis.find_children("*", "MeshInstance3D", true, false):
			var m3: MeshInstance3D = mi as MeshInstance3D
			if m3.mesh == null:
				continue
			var bb: AABB = m3.get_aabb()
			var c: Vector3 = m3.global_transform * bb.get_center()
			pts.append(c)
	if pts.is_empty():
		pts.append(gate.global_position + Vector3(0.0, 1.2, 0.0))
	# The gate is level with the camera by the time a miss is judged, so its
	# low middle is under the bottom of the screen. Its top corners and top bar
	# are what is still in view: the arcs leave from those, grabbing at him
	# from both sides and from above.
	var fwd0: Vector3 = section.call("_path_forward_at", float(section.get("_player_path_dist")))
	var right0: Vector3 = fwd0.cross(Vector3.UP).normalized()
	var g0: Vector3 = gate.global_position
	var left_pt: Vector3 = pts[0]
	var right_pt: Vector3 = pts[0]
	var top_pt: Vector3 = pts[0]
	for p: Vector3 in pts:
		var lat: float = (p - g0).dot(right0)
		var hy: float = p.y - g0.y
		if hy - lat > (left_pt.y - g0.y) - (left_pt - g0).dot(right0):
			left_pt = p
		if hy + lat > (right_pt.y - g0.y) + (right_pt - g0).dot(right0):
			right_pt = p
		if hy > top_pt.y - g0.y:
			top_pt = p
	pts.assign([left_pt, right_pt, top_pt])
	_gates.append({"gate": gate, "idx": idx, "mats": mats, "base_e": base_e, "t": 0.0,
		"blown": false, "pts": pts})

	# Three arcs into him from the nearest bars, then two crawling over him.
	var fs: float = GameConfig.flash_scale()
	for k in 3:
		var a: Vector3 = pts[k] + Vector3(0.0, randf_range(0.0, 0.3), 0.0)
		_start_bolt(a, Vector3.ZERO, false, 0.42 + 0.06 * float(k), 0.055, 0.45)
	for k in 2:
		_start_bolt(Vector3.ZERO, _body_offset(), true, 0.65, 0.03, 0.14)
	_body_t = 0.65
	_body_light.visible = true
	_gate_light.global_position = gate.global_position + Vector3(0.0, 1.4, 0.0)
	_gate_light.visible = true
	_gate_light_t = _STROBE_S
	# A buzz that crackles: three short pulses rather than one long one.
	GameConfig.rumble(0.9, 0.5, 0.10)
	for k in 2:
		get_tree().create_timer(0.11 * float(k + 1)).timeout.connect(
			func() -> void: GameConfig.rumble(0.7 - 0.25 * float(k), 0.4, 0.08))


func update(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var fs: float = GameConfig.flash_scale()
	var calm: bool = GameConfig.reduced_flashing
	_update_gates(delta, fs, calm)
	_update_bolts(delta, fs, calm)
	_update_pops(delta, fs)
	if _body_t > 0.0:
		_body_t = maxf(0.0, _body_t - delta)
		var k: float = _body_t / 0.65
		var flick: float = 1.0 if calm else randf_range(0.35, 1.0)
		_body_light.light_energy = 3.5 * k * flick * fs
		_body_light.visible = _body_t > 0.0
	if _gate_light_t > 0.0:
		_gate_light_t = maxf(0.0, _gate_light_t - delta)
		var k2: float = _gate_light_t / _STROBE_S
		_gate_light.light_energy = 4.0 * k2 * (1.0 if calm else randf_range(0.2, 1.0)) * fs
		_gate_light.visible = _gate_light_t > 0.0


func _update_gates(delta: float, fs: float, calm: bool) -> void:
	var i: int = 0
	while i < _gates.size():
		var g: Dictionary = _gates[i]
		var gate: Node3D = g["gate"]
		if not is_instance_valid(gate):
			_gates.remove_at(i)
			continue
		var t: float = float(g["t"]) + delta
		g["t"] = t
		var mats: Array = g["mats"]
		var base_e: Array = g["base_e"]
		if t < _STROBE_S:
			# Strobing as the current fights its way through: full white-blue,
			# out, back, in a ragged rhythm. Reduced flashing: it just fades.
			for j in mats.size():
				var m: Material = mats[j]
				if m == null:
					continue
				NeonMat.set_tint(m, _COL_CORE if j % 2 == 0 else _COL_ARC)
				var e0: float = maxf(float(base_e[j]), 2.0)
				var e: float
				if calm:
					e = e0 * (1.0 - t / _STROBE_S)
				else:
					e = e0 * (randf_range(0.0, 2.6) if randf() < 0.7 else 0.0) * fs + e0 * 0.1
				NeonMat.set_energy(m, e)
		elif not bool(g["blown"]):
			g["blown"] = true
			_blow(gate, g["pts"], fs)
			for m2: Material in mats:
				if m2 != null:
					NeonMat.set_tint(m2, Color(0.25, 0.28, 0.32))
					NeonMat.set_energy(m2, 0.15)
		if t >= _DEAD_S:
			# Gone. The meta keeps the blackout preview from bringing it back.
			gate.set_meta("shorted", true)
			var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
			if vis != null:
				vis.visible = false
			_gates.remove_at(i)
			continue
		i += 1


func _blow(gate: Node3D, pts: Array, fs: float) -> void:
	var c: Vector3 = gate.global_position + Vector3(0.0, 1.0, 0.0)
	if not pts.is_empty():
		c = Vector3.ZERO
		for p: Vector3 in pts:
			c += p
		c /= float(pts.size())
	_molten.global_position = c
	var fwd: Vector3 = section.call("_path_forward_at", float(section.get("_player_path_dist")))
	_molten.global_basis = Basis.looking_at(fwd, Vector3.UP)
	_molten.restart()
	_molten.emitting = true
	# The ring of the blow goes round him, where it can be seen.
	var r: Dictionary = _pops[_pop_i]
	_pop_i = (_pop_i + 1) % _pops.size()
	var n: MeshInstance3D = r["node"]
	n.visible = true
	n.global_position = player.global_position + Vector3(0.0, 0.85, 0.0)
	n.global_basis = Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
	r["t"] = 0.0
	# One last arc to him as it goes, from the top bar.
	_start_bolt(pts[pts.size() - 1] if not pts.is_empty() else c, Vector3.ZERO, false, 0.22, 0.08, 0.6)
	_gate_light_t = 0.18
	_gate_light.visible = true
	_gate_light.light_energy = 6.0 * fs


func _update_pops(delta: float, fs: float) -> void:
	for r: Dictionary in _pops:
		var t: float = float(r["t"])
		if t < 0.0:
			continue
		t += delta
		r["t"] = t
		var k: float = t / 0.28
		var n: MeshInstance3D = r["node"]
		if k >= 1.0:
			r["t"] = -1.0
			n.visible = false
			continue
		var sc: float = lerpf(0.4, 2.4, 1.0 - (1.0 - k) * (1.0 - k))
		n.scale = Vector3(sc, 1.0, sc)
		NeonMat.set_energy(r["mat"], (1.0 - k) * 6.0 * fs + 0.2)


# ── Bolts ────────────────────────────────────────────────────────────────────

func _body_offset() -> Vector3:
	var v := Vector3(randf_range(-1, 1), randf_range(-0.6, 1.0), randf_range(-1, 1))
	return v.normalized() * randf_range(0.25, 0.5)


## `a` is a world point (a gate bar) unless `on_body`, when both ends ride on
## him. The far end is always on him, wherever he has got to by now.
func _start_bolt(a: Vector3, a_off: Vector3, on_body: bool, life: float, thick: float,
		jitter: float) -> void:
	var b: Dictionary = _bolts[_bolt_i]
	_bolt_i = (_bolt_i + 1) % _bolts.size()
	b["a"] = a
	b["a_off"] = a_off
	b["on_body"] = on_body
	b["life"] = life
	b["max"] = life
	b["thick"] = thick
	b["jitter"] = jitter
	b["rejag"] = 0.0


func _update_bolts(delta: float, fs: float, calm: bool) -> void:
	var chest: Vector3 = player.global_position + Vector3(0.0, 0.9, 0.0)
	for b: Dictionary in _bolts:
		var life: float = float(b["life"])
		var segs: Array = b["segs"]
		if life <= 0.0:
			if (segs[0] as MeshInstance3D).visible:
				for s: MeshInstance3D in segs:
					s.visible = false
			continue
		life -= delta
		b["life"] = life
		if life <= 0.0:
			for s: MeshInstance3D in segs:
				s.visible = false
			continue
		var k: float = life / float(b["max"])
		var mat: StandardMaterial3D = b["mat"]
		var flick: float = 1.0 if calm else randf_range(0.5, 1.0)
		mat.emission_energy_multiplier = (2.0 + 7.0 * k * flick) * maxf(fs, 0.35)
		mat.albedo_color.a = clampf(k * 1.6, 0.0, 1.0)
		b["rejag"] = float(b["rejag"]) - delta
		if float(b["rejag"]) > 0.0:
			continue
		b["rejag"] = _REJAG_S * (2.0 if calm else 1.0)
		var p0: Vector3
		var p1: Vector3
		if bool(b["on_body"]):
			# Crawling over him: from one point on his body to another, both
			# re-picked every few flickers so it skitters about.
			if randf() < 0.4:
				b["a_off"] = _body_offset()
			p0 = chest + (b["a_off"] as Vector3)
			p1 = chest + _body_offset()
		else:
			p0 = b["a"]
			p1 = chest + Vector3(randf_range(-0.25, 0.25), randf_range(-0.4, 0.3), randf_range(-0.2, 0.2))
		var n: int = segs.size()
		var pts: Array[Vector3] = []
		var span: float = p0.distance_to(p1)
		var jit: float = float(b["jitter"]) * clampf(span / 3.0, 0.35, 1.6)
		for i in n + 1:
			var f: float = float(i) / float(n)
			var p: Vector3 = p0.lerp(p1, f)
			if i > 0 and i < n:
				p += Vector3(randf_range(-jit, jit), randf_range(-jit, jit), randf_range(-jit, jit))
			pts.append(p)
		var th: float = float(b["thick"]) * lerpf(0.5, 1.0, k)
		for i in n:
			var s: MeshInstance3D = segs[i]
			var d: Vector3 = pts[i + 1] - pts[i]
			var l: float = d.length()
			if l < 0.001:
				s.visible = false
				continue
			var z: Vector3 = d / l
			var up: Vector3 = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
			var x: Vector3 = up.cross(z).normalized()
			var y: Vector3 = z.cross(x)
			s.global_transform = Transform3D(Basis(x * th, y * th, z * l), (pts[i] + pts[i + 1]) * 0.5)
			s.visible = true
