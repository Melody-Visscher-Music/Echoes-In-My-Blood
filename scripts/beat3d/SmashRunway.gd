extends RefCounted
class_name SmashRunway

## The stretch of track in front of a smash wall — the run-up Meeko mashes
## down. Without it a long roll is seconds of empty floor and a wall far away.
## Three things live on it, all laid out in advance along the path so they are
## visible from the start of the hold:
##
##   * the tunnel: neon frames on every beat between the start of the hold and
##     the wall, each one tighter than the last, so the track closes in on the
##     wall. A frame lights as he passes through it.
##   * the edge light: neon strips down both edges of the track that fill from
##     the start of the hold toward the wall at the rate of the mash. Ahead of
##     pace the light runs ahead of him and reaches the wall early; behind it,
##     the strips ahead stay dark. The bright head is where the mash has got to.
##   * the melody pylons: the melody notes under the hold no longer have a gate
##     to belong to, so each fires a pylon beside the track — dark until its
##     note, then a flash and a beam into the sky — alternating sides.
##
## SmashGate owns one per smash: build() when the wall is built, update() every
## frame while it is the active (or upcoming) smash, finish() at the impact.

const FRAME_STEP_BEATS: float = 1.0
const EDGE_SEG_M: float = 1.5
## Pylons stand this long ahead of their note, so the flash is in front of him
## (in the middle of the view) rather than at his shoulder.
const PYLON_LEAD_S: float = 0.30

var section: Node = null
var root: Node3D = null
var pd0: float = 0.0
var pd1: float = 0.0
var t0: float = 0.0
var t1: float = 0.0

var _frames: Array[Dictionary] = []      # {pd, mat, lit}
var _edge_segs: Array[MeshInstance3D] = []
var _edge_pds: PackedFloat32Array = PackedFloat32Array()
var _edge_dark: ShaderMaterial = null
var _edge_lit: ShaderMaterial = null
var _edge_head: ShaderMaterial = null
var _pylons: Array[Dictionary] = []      # {t, mat, beam, beam_mat, fired}
var _done: bool = false
var _fade: float = 1.0


func build(p_section: Node, p_t0: float, p_t1: float, melody: PackedFloat32Array,
		pieces: GatePieces, track_width: float, wall_h: float, tint: Color, beat_s: float) -> void:
	section = p_section
	t0 = p_t0
	t1 = p_t1
	var v: float = float(section.get("player").get("forward_speed"))
	pd0 = t0 * v
	pd1 = t1 * v
	root = Node3D.new()
	root.name = "SmashRunway"
	(section.get("world_fx_root") as Node3D).add_child(root)

	# ── The tunnel ──────────────────────────────────────────────────────────
	var step: float = maxf(beat_s * FRAME_STEP_BEATS, 0.15)
	var n: int = int(floor((t1 - t0) / step))
	for k in n:
		var tk: float = t0 + float(k) * step
		var pd: float = tk * v
		if pd > pd1 - 3.0:
			break
		var close: float = float(k) / maxf(float(n - 1), 1.0)   # 0 far, 1 at the wall
		var w: float = lerpf(track_width + 4.2, track_width + 0.7, close)
		var h: float = lerpf(wall_h + 3.4, wall_h + 0.6, close)
		var mat: ShaderMaterial = NeonMat.tube(tint, 0.5)
		var fr := Node3D.new()
		fr.position = _pos(pd, 0.0, 0.0)
		fr.rotation_degrees.y = _rot(pd)
		root.add_child(fr)
		var pw: float = lerpf(0.09, 0.13, close)
		for bar: Array in [
				[Vector3(pw, h, pw), Vector3(-w * 0.5, h * 0.5, 0.0)],
				[Vector3(pw, h, pw), Vector3(w * 0.5, h * 0.5, 0.0)],
				[Vector3(w + pw, pw, pw), Vector3(0.0, h, 0.0)]]:
			var mi := MeshInstance3D.new()
			mi.mesh = pieces.shared_box(bar[0])
			var own: ShaderMaterial = mat if bar[0].x < w else mat.duplicate()
			own.set_shader_parameter("box_size", bar[0])
			mi.material_override = own
			mi.set_meta("no_cycle", true)
			mi.position = bar[1]
			fr.add_child(mi)
			if own != mat:
				_frames.append({"pd": pd, "mat": own, "lit": 0.0, "top": true})
		_frames.append({"pd": pd, "mat": mat, "lit": 0.0, "top": false})

	# ── The edge light ──────────────────────────────────────────────────────
	var seg_size := Vector3(0.10, 0.06, EDGE_SEG_M * 0.86)
	_edge_dark = NeonMat.tube(tint, 0.35)
	_edge_lit = NeonMat.tube(tint, 3.2)
	_edge_head = NeonMat.tube(Color(1.0, 0.92, 0.97), 10.0)
	for m: ShaderMaterial in [_edge_dark, _edge_lit, _edge_head]:
		m.set_shader_parameter("box_size", seg_size)
	var edge_x: float = track_width * 0.5 + 0.18
	var pd: float = pd0 + EDGE_SEG_M * 0.5
	while pd < pd1 - 0.8:
		for side: float in [-1.0, 1.0]:
			var mi := MeshInstance3D.new()
			mi.mesh = pieces.shared_box(seg_size)
			mi.material_override = _edge_dark
			mi.set_meta("no_cycle", true)
			mi.position = _pos(pd, side * edge_x, 0.05)
			mi.rotation_degrees.y = _rot(pd)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
			_edge_segs.append(mi)
			_edge_pds.append(pd)
		pd += EDGE_SEG_M

	# ── Melody pylons ───────────────────────────────────────────────────────
	var mcol: Color = section.get("melody_world_color")
	mcol.a = 1.0
	var px: float = track_width * 0.5 + 1.7
	for k in melody.size():
		var tm: float = melody[k]
		var ppd: float = minf((tm + PYLON_LEAD_S) * v, pd1 - 2.0)
		var side: float = -1.0 if k % 2 == 0 else 1.0
		var base: Vector3 = _pos(ppd, side * px, 0.0)
		var pmat: ShaderMaterial = NeonMat.tube(mcol, 0.6)
		var post := MeshInstance3D.new()
		post.mesh = pieces.shared_box(Vector3(0.14, 3.0, 0.14))
		pmat.set_shader_parameter("box_size", Vector3(0.14, 3.0, 0.14))
		post.material_override = pmat
		post.set_meta("no_cycle", true)
		post.position = base + Vector3(0.0, 1.5, 0.0)
		root.add_child(post)
		var cap := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.22
		sm.height = 0.44
		sm.radial_segments = 12
		sm.rings = 6
		cap.mesh = sm
		var cap_mat: ShaderMaterial = NeonMat.orb(mcol, 1.0)
		cap.material_override = cap_mat
		cap.set_meta("no_cycle", true)
		cap.position = base + Vector3(0.0, 3.15, 0.0)
		root.add_child(cap)
		var beam := MeshInstance3D.new()
		beam.mesh = pieces.shared_box(Vector3(0.16, 1.0, 0.16))
		var beam_mat: ShaderMaterial = NeonMat.tube(mcol.lightened(0.3), 0.0)
		beam_mat.set_shader_parameter("box_size", Vector3(0.16, 1.0, 0.16))
		beam.material_override = beam_mat
		beam.set_meta("no_cycle", true)
		beam.position = base + Vector3(0.0, 3.2, 0.0)
		beam.scale = Vector3(1.0, 0.01, 1.0)
		beam.visible = false
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(beam)
		_pylons.append({"t": tm, "mat": pmat, "cap": cap_mat, "beam": beam,
			"beam_mat": beam_mat, "fired": false, "base_y": base.y + 3.2})


func _pos(pd: float, lat: float, h: float) -> Vector3:
	return section.call("_path_world_pos", pd, lat, h)


func _rot(pd: float) -> float:
	return float(section.call("_path_y_rot_at", pd))


## `progress`: mash progress 0..1+. `col`: the charge colour (rainbow or tint).
func update(t_s: float, delta: float, progress: float, col: Color, level: float) -> void:
	if root == null:
		return
	var player_pd: float = float(section.get("_player_path_dist"))
	var flash: float = GameConfig.flash_scale()
	if _done:
		_fade = maxf(0.0, _fade - delta * 1.6)
		if _fade <= 0.0 or player_pd > pd1 + 30.0:
			root.queue_free()
			root = null
			return

	# Tunnel: a frame flashes as he goes through it, then settles to a glow.
	# Frames ahead breathe with the build-up so the corridor feels charged.
	for f: Dictionary in _frames:
		var m: ShaderMaterial = f["mat"]
		var lit: float = float(f["lit"])
		if lit <= 0.0 and player_pd >= float(f["pd"]) and t_s >= t0 - 0.3:
			lit = 1.0
		elif lit > 0.0:
			lit = maxf(0.25, lit - delta * 2.4)
		f["lit"] = lit
		var e: float = 1.6 + 2.2 * level
		if lit > 0.0:
			e = lerpf(2.0, 9.0 * flash + 2.0, clampf((lit - 0.25) / 0.75, 0.0, 1.0))
		NeonMat.set_energy(m, e * _fade)
		NeonMat.set_tint(m, col)

	# Edge light: lit up to where the mash has got, with a bright head.
	var fill_pd: float = lerpf(pd0, pd1, clampf(progress, 0.0, 1.0))
	if t_s < t0 - 0.3:
		fill_pd = pd0 - 1.0
	for i in _edge_segs.size():
		var spd: float = _edge_pds[i]
		var mat: ShaderMaterial = _edge_dark
		if spd <= fill_pd:
			mat = _edge_head if fill_pd - spd < EDGE_SEG_M * 2.0 else _edge_lit
		if _edge_segs[i].material_override != mat:
			_edge_segs[i].material_override = mat
	var over: float = clampf(progress - 1.0, 0.0, 1.0)
	NeonMat.set_tint(_edge_lit, col)
	NeonMat.set_energy(_edge_lit, (3.2 + 3.0 * over) * _fade)
	NeonMat.set_energy(_edge_head, (10.0 * flash + 2.0) * _fade)
	NeonMat.set_energy(_edge_dark, (0.8 + 0.6 * level) * _fade)

	# Pylons fire on their melody note.
	for p: Dictionary in _pylons:
		var pm: ShaderMaterial = p["mat"]
		var cm: ShaderMaterial = p["cap"]
		if not bool(p["fired"]):
			if t_s >= float(p["t"]):
				p["fired"] = true
				_fire_pylon(p)
			else:
				NeonMat.set_energy(pm, 0.6 * _fade)
				NeonMat.set_energy(cm, 1.0 * _fade)
		else:
			NeonMat.set_energy(pm, maxf(1.2, NeonMat.get_energy(pm) - delta * 18.0) * _fade)
			NeonMat.set_energy(cm, maxf(2.0, NeonMat.get_energy(cm) - delta * 30.0) * _fade)


func _fire_pylon(p: Dictionary) -> void:
	var flash: float = GameConfig.flash_scale()
	NeonMat.set_energy(p["mat"], 8.0 * flash + 1.5)
	NeonMat.set_energy(p["cap"], 16.0 * flash + 3.0)
	var beam: MeshInstance3D = p["beam"]
	var bm: ShaderMaterial = p["beam_mat"]
	beam.visible = true
	var by: float = float(p["base_y"])
	var tw: Tween = beam.create_tween()
	tw.set_parallel(true)
	# Shoots up, then thins out and fades.
	tw.tween_method(func(ln: float) -> void:
		beam.scale = Vector3(1.0, ln, 1.0)
		beam.global_position.y = by + ln * 0.5, 0.5, 16.0, 0.16) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_method(func(e: float) -> void: NeonMat.set_energy(bm, e),
		9.0 * flash + 2.0, 0.0, 0.5).set_delay(0.08)
	tw.tween_property(beam, "scale:x", 0.2, 0.5).set_delay(0.08)
	tw.tween_property(beam, "scale:z", 0.2, 0.5).set_delay(0.08)
	tw.chain().tween_callback(func() -> void: beam.visible = false)


## The wall has gone: everything fades over a moment and is freed once he is
## well past it.
func finish() -> void:
	_done = true
