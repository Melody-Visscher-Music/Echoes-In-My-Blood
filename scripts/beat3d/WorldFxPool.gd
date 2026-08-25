## WorldFxPool — reusable node/resource pool for the melody-driven world FX.
##
## _pulse_world() fires on every melody / fx chart event — roughly four times a
## second on a dense chart (echoes_in_my_blood: 1108 events over 280 s). It used
## to allocate, per event, ~15 MeshInstance3D + ~15 brand-new mesh resources +
## ~15 StandardMaterial3D + ~20 Tweens, then queue_free the lot a fraction of a
## second later. That is ~60 nodes, ~60 mesh resources (each one a CPU surface
## build plus a RenderingServer mesh create and vertex-buffer upload) and ~80
## tweens created and destroyed every single second, forever — exactly the churn
## Section_BeatRunner3d's own comment above _fx_step_lights calls out as "some of
## the most expensive things you can do per frame in Godot". That fix was only
## ever applied to the footstep and beat lights; this file finishes the job for
## the rest of the world FX.
##
## Nothing here is per-event any more:
##   - Meshes are shared unit primitives (a 1 m cube and a 1 m sphere) and the
##     per-instance size lives in scale, which is geometrically identical to
##     baking it into a fresh BoxMesh / SphereMesh.
##   - Each pooled node owns ONE ShaderMaterial for its whole life; arming it
##     writes uniforms instead of constructing a new material. Because uniforms
##     are not properties, the fade tweens go through _tw_param rather than
##     tween_property.
##   - Halo ring geometry is built once per slot from GameConfig's halo shape and
##     size, which cannot change mid-run.
##   - The dual-colour halo stripe texture (a 256x1 Image built pixel-by-pixel in
##     GDScript, then uploaded to the GPU) is cached and only rebuilt when the
##     colour cycle has actually drifted a perceptible amount.
##
## Each pool is a ring buffer: _next_slot takes the next index and, if that slot
## is still in flight, force-releases it first. So the pool never allocates during
## play, and an unusually dense burst recycles its oldest FX rather than growing.
class_name WorldFxPool
extends RefCounted

# ── Pool sizes ────────────────────────────────────────────────────────────────
# Sized from the real worst case rather than guessed. At ~4 events/s: spires live
# 0.75 s (~6 in flight), wisps 0.55-0.95 s at up to 10 per event (~40 in flight),
# halos ~1.4 s (~6 in flight). Headroom on top of that so recycling stays rare.
const SPIRE_SLOTS: int = 16
const LIGHT_SLOTS: int = 16
const WISP_SLOTS:  int = 72
const HALO_SLOTS:  int = 32

# Colour quantisation for the dual-colour halo stripe texture. The colour cycle
# takes color_cycle_period_s (14 s by default) to travel its whole range, so 1/64
# steps rebuild the texture ~0.3 times a second instead of ~4 — while never
# letting the stripe drift more than a step away from the live cycle colour.
const _STRIPE_QUANT: float = 64.0

var _fx_root:    Node3D = null
var _tween_host: Node   = null

# Shared geometry. Unit-sized; instances carry their real size in scale.
var _unit_box:    BoxMesh    = null   # 1 m cube — spires + halo shape segments
var _unit_sphere: SphereMesh = null   # 1 m diameter sphere — wisps
var _halo_torus:  TorusMesh  = null   # built once from GameConfig.halo_size

# ── Spires ────────────────────────────────────────────────────────────────────
var _spire_nodes: Array[MeshInstance3D]      = []
var _spire_mats:  Array[ShaderMaterial]  = []
var _spire_tws:   Array[Tween]               = []
var _spire_busy:  Array[bool]                = []
var _spire_cur:   int = 0

# ── One-shot FX lights (spire blooms) ─────────────────────────────────────────
var _light_nodes: Array[OmniLight3D] = []
var _light_tws:   Array[Tween]       = []
var _light_busy:  Array[bool]        = []
var _light_cur:   int = 0

# ── Wisps ─────────────────────────────────────────────────────────────────────
var _wisp_nodes: Array[MeshInstance3D]     = []
var _wisp_mats:  Array[ShaderMaterial] = []
var _wisp_tws:   Array[Tween]              = []
var _wisp_busy:  Array[bool]               = []
var _wisp_cur:   int = 0

# ── Halo rings ────────────────────────────────────────────────────────────────
var _halo_pivots: Array[Node3D]              = []
var _halo_mats_a: Array[ShaderMaterial]  = []
var _halo_mats_b: Array[ShaderMaterial]  = []   # entries may be null (mono)
var _halo_tws:    Array[Tween]               = []   # fade-in / fade-out chain
var _halo_spins:  Array[Tween]               = []   # pivot spin
var _halo_busy:   Array[bool]                = []
var _halo_cur:    int = 0

## True when halos are circles carrying a baked two-colour stripe texture. Those
## are driven by the texture, not by material colour, so update_halo_colors()
## must leave their albedo/emission alone — the same rule the old
## _texture_dual_circle flag enforced.
var _halo_textured: bool = false
var _stripe_tex:    ImageTexture = null
var _stripe_img:    Image        = null
var _stripe_key:    int          = -1

# ── Tier knobs (see GraphicsQuality.PRESETS) ──────────────────────────────────
var wisps_per_side: int  = 5
var spires_enabled: bool = true


## Builds every pooled node and shared resource. shape_pts comes from
## Section_BeatRunner3d._get_shape_points() for the configured halo shape — an
## empty array means the plain circle/torus halo. Call once, from _ready().
func setup(fx_root: Node3D, tween_host: Node, shape_pts: Array,
		halo_radius: float, halo_tube_r: float, dual_color: bool,
		p_wisps_per_side: int, p_spires_enabled: bool) -> void:
	_fx_root    = fx_root
	_tween_host = tween_host
	wisps_per_side = maxi(0, p_wisps_per_side)
	spires_enabled = p_spires_enabled

	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	# radius 0.5 / height 1.0 = a 1 m sphere, so scale == the old radius * 2.
	# Segment counts match the meshes this replaces exactly.
	_unit_sphere = SphereMesh.new()
	_unit_sphere.radius          = 0.5
	_unit_sphere.height          = 1.0
	_unit_sphere.radial_segments = 6
	_unit_sphere.rings           = 3

	_build_spires()
	_build_lights()
	_build_wisps()
	_build_halos(shape_pts, halo_radius, halo_tube_r, dual_color)


## Shared material factories. Every pooled FX material is built once here and
## then only ever has its uniforms rewritten.
##
## These are ShaderMaterials now, which is why the fade tweens below go through
## _tw_param instead of tween_property: a uniform is not a property, so
## tween_property("albedo_color:a") has nothing to bind to.
func _fx_beam_material() -> ShaderMaterial:
	# Spires are light columns, so fx_ring's additive, unshaded, depth-write-free
	# pass is exactly right — same reasoning the old StandardMaterial3D used
	# SHADING_MODE_UNSHADED + BLEND_MODE_ADD.
	var m: ShaderMaterial = NeonMat.ring(Color.WHITE, 4.0)
	m.set_shader_parameter("band_amount", 0.0)   # no travelling band on a column
	return m


func _fx_orb_material() -> ShaderMaterial:
	return NeonMat.orb(Color.WHITE, 4.0)


## Tweens a shader uniform. The material is a Resource, so capturing it in the
## lambda is safe — unlike capturing a node, which the pool may recycle.
func _tw_param(tw: Tween, mat: ShaderMaterial, pname: String,
		from_v: float, to_v: float, dur: float, parallel: bool = true) -> void:
	var t: Tween = tw.parallel() if parallel else tw
	t.tween_method(func(v: float) -> void:
		mat.set_shader_parameter(pname, v), from_v, to_v, dur)


## Returns the next slot index, force-releasing it first if it is still in
## flight. Recycling the oldest FX is always preferable to allocating mid-song.
func _next_slot(busy: Array[bool], cur: int, tws: Array[Tween]) -> int:
	var idx: int = cur % busy.size()
	if busy[idx]:
		var old: Tween = tws[idx]
		if old != null and old.is_valid():
			old.kill()
		tws[idx] = null
	return idx


func _new_tween() -> Tween:
	return _tween_host.create_tween()


# ═════════════════════════════════════════════════════════════════════════════
# SPIRES — tall thin columns that erupt beside the track and dissolve upward
# ═════════════════════════════════════════════════════════════════════════════

func _build_spires() -> void:
	for i in range(SPIRE_SLOTS):
		var mat: ShaderMaterial = _fx_beam_material()
		var mi := MeshInstance3D.new()
		mi.mesh              = _unit_box
		mi.scale             = Vector3(0.10, 5.5, 0.10)   # was BoxMesh.size
		mi.material_override = mat
		mi.visible           = false
		_fx_root.add_child(mi)
		_spire_nodes.append(mi)
		_spire_mats.append(mat)
		_spire_tws.append(null)
		_spire_busy.append(false)


## Arms one spire at pos and plays the rise + dissolve. No-op when the quality
## tier has spires switched off.
func spawn_spire(pos: Vector3, col: Color, energy: float) -> void:
	if not spires_enabled or _spire_nodes.is_empty():
		return
	var i: int = _next_slot(_spire_busy, _spire_cur, _spire_tws)
	_spire_cur = i + 1

	var mat: ShaderMaterial = _spire_mats[i]
	NeonMat.set_tint(mat, col)
	NeonMat.set_energy(mat, energy)
	mat.set_shader_parameter("alpha", 0.90)

	var mi: MeshInstance3D = _spire_nodes[i]
	mi.position = pos
	mi.visible  = true
	_spire_busy[i] = true

	var tw: Tween = _new_tween()
	tw.parallel().tween_property(mi,  "position:y", 3.2, 0.22)
	_tw_param(tw, mat, "energy", energy, 0.0, 0.75)
	_tw_param(tw, mat, "alpha",  0.90,   0.0, 0.70)
	tw.tween_callback(func() -> void:
		mi.visible = false
		_spire_busy[i] = false
	)
	_spire_tws[i] = tw


# ═════════════════════════════════════════════════════════════════════════════
# ONE-SHOT LIGHTS — the bloom at each spire's peak
# ═════════════════════════════════════════════════════════════════════════════

func _build_lights() -> void:
	for i in range(LIGHT_SLOTS):
		var l := OmniLight3D.new()
		l.light_energy = 0.0
		l.omni_range   = 11.0
		l.visible      = false
		_fx_root.add_child(l)
		_light_nodes.append(l)
		_light_tws.append(null)
		_light_busy.append(false)


func spawn_fx_light(pos: Vector3, col: Color, energy: float, fade_s: float) -> void:
	if not spires_enabled or _light_nodes.is_empty():
		return
	var i: int = _next_slot(_light_busy, _light_cur, _light_tws)
	_light_cur = i + 1

	var l: OmniLight3D = _light_nodes[i]
	l.position     = pos
	l.light_color  = col
	l.light_energy = energy
	l.visible      = true
	_light_busy[i] = true

	var tw: Tween = _new_tween()
	tw.tween_property(l, "light_energy", 0.0, fade_s)
	tw.tween_callback(func() -> void:
		l.visible = false
		_light_busy[i] = false
	)
	_light_tws[i] = tw


# ═════════════════════════════════════════════════════════════════════════════
# WISPS — small glowing orbs that drift up from the track edges
# ═════════════════════════════════════════════════════════════════════════════

func _build_wisps() -> void:
	for i in range(WISP_SLOTS):
		var mat: ShaderMaterial = _fx_orb_material()
		var mi := MeshInstance3D.new()
		mi.mesh              = _unit_sphere
		mi.material_override = mat
		mi.visible           = false
		_fx_root.add_child(mi)
		_wisp_nodes.append(mi)
		_wisp_mats.append(mat)
		_wisp_tws.append(null)
		_wisp_busy.append(false)


## radius reproduces the old per-wisp SphereMesh radius through scale on the
## shared unit sphere (scale = radius * 2 because the shared mesh is 1 m across).
## drift_x / rise / dur keep the original tween shape exactly.
func spawn_wisp(pos: Vector3, radius: float, col: Color, energy: float,
		rise: float, drift_x: float, dur: float) -> void:
	if _wisp_nodes.is_empty():
		return
	var i: int = _next_slot(_wisp_busy, _wisp_cur, _wisp_tws)
	_wisp_cur = i + 1

	var mat: ShaderMaterial = _wisp_mats[i]
	NeonMat.set_tint(mat, col)
	NeonMat.set_energy(mat, energy)
	mat.set_shader_parameter("alpha", 0.92)

	var mi: MeshInstance3D = _wisp_nodes[i]
	mi.position = pos
	mi.scale    = Vector3.ONE * (radius * 2.0)
	mi.visible  = true
	_wisp_busy[i] = true

	var tw: Tween = _new_tween()
	tw.parallel().tween_property(mi,  "position:y", pos.y + rise, dur)
	tw.parallel().tween_property(mi,  "position:x", drift_x, dur)
	_tw_param(tw, mat, "energy", energy, 0.0, dur * 0.90)
	_tw_param(tw, mat, "alpha",  0.92,   0.0, dur * 0.88)
	tw.tween_callback(func() -> void:
		mi.visible = false
		_wisp_busy[i] = false
	)
	_wisp_tws[i] = tw


# ═════════════════════════════════════════════════════════════════════════════
# HALO RINGS
# ═════════════════════════════════════════════════════════════════════════════

## One pivot per slot, geometry built once. Shape and radius come from
## GameConfig and are fixed for the whole run, so nothing here can go stale.
func _build_halos(shape_pts: Array, radius: float, tube_r: float, dual_color: bool) -> void:
	_halo_textured = dual_color and shape_pts.is_empty()

	if shape_pts.is_empty():
		_halo_torus = TorusMesh.new()
		_halo_torus.inner_radius  = radius - tube_r
		_halo_torus.outer_radius  = radius + tube_r
		_halo_torus.rings         = 12
		_halo_torus.ring_segments = 48

	for i in range(HALO_SLOTS):
		var pivot := Node3D.new()
		pivot.visible = false
		_fx_root.add_child(pivot)

		var mat_a: ShaderMaterial = _halo_material()
		var mat_b: ShaderMaterial = null

		if shape_pts.is_empty():
			# Circle. Dual colour is baked into a stripe texture on ONE ring
			# rather than a second ring — same as before.
			var ring := MeshInstance3D.new()
			ring.mesh              = _halo_torus
			ring.rotation_degrees  = Vector3(90.0, 0.0, 0.0)
			ring.material_override = mat_a
			pivot.add_child(ring)
		else:
			if dual_color:
				mat_b = _halo_material()
			_build_shape_segments(pivot, shape_pts, mat_a, mat_b, tube_r)

		_halo_pivots.append(pivot)
		_halo_mats_a.append(mat_a)
		_halo_mats_b.append(mat_b)
		_halo_tws.append(null)
		_halo_spins.append(null)
		_halo_busy.append(false)


## Pure glow rings, not lit geometry. fx_ring declares
## `blend_add, unshaded, depth_draw_never` in its render_mode, which is the same
## bargain the old StandardMaterial3D struck by hand: skip the PBR lighting
## model (no SSAO / SSR / shadow lookup per fragment) and composite additively,
## so hundreds of overlapping rings need no back-to-front sort to look right.
func _halo_material() -> ShaderMaterial:
	var m: ShaderMaterial = NeonMat.ring(Color.WHITE, 4.0)
	m.set_shader_parameter("alpha", 0.0)
	return m


## Traces a closed outline through pts using the shared unit cube, one child per
## edge. When mat_even is non-null the edges alternate materials, giving the
## striped dual-colour look.
func _build_shape_segments(root: Node3D, pts: Array, mat_odd: ShaderMaterial,
		mat_even: ShaderMaterial, tube_r: float) -> void:
	var n: int = pts.size()
	var side: float = tube_r * 2.0
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var seg := MeshInstance3D.new()
		seg.mesh              = _unit_box
		seg.scale             = Vector3(side, a.distance_to(b), side)
		seg.material_override = mat_odd if (mat_even == null or i % 2 == 0) else mat_even
		var mid: Vector2 = (a + b) * 0.5
		seg.position   = Vector3(mid.x, mid.y, 0.0)
		seg.rotation.z = atan2(b.y - a.y, b.x - a.x) - PI * 0.5
		root.add_child(seg)


## Arms one halo. col_a / col_b are the live cycle colours; life_s is how long it
## stays up before fading (the caller's time_to_cam_pass), spin_s the full spin
## duration. inner_spin_s <= 0 skips the counter-rotation.
func spawn_halo(pos: Vector3, y_rot_deg: float, col_a: Color, col_b: Color,
		life_s: float, spin_deg: float, spin_s: float,
		inner_spin_deg: float, inner_spin_s: float) -> void:
	if _halo_pivots.is_empty():
		return
	var i: int = _next_slot(_halo_busy, _halo_cur, _halo_tws)
	var old_spin: Tween = _halo_spins[i]
	if old_spin != null and old_spin.is_valid():
		old_spin.kill()
	_halo_cur = i + 1

	var mat_a: ShaderMaterial = _halo_mats_a[i]
	var mat_b: ShaderMaterial = _halo_mats_b[i]

	if _halo_textured:
		# The stripe texture carries both colours; use_tex makes the shader read
		# it instead of the flat tint.
		mat_a.set_shader_parameter("stripe_tex", _stripe_texture(col_a, col_b))
		mat_a.set_shader_parameter("use_tex", true)
	else:
		mat_a.set_shader_parameter("use_tex", false)
		NeonMat.set_tint(mat_a, col_a)
	NeonMat.set_energy(mat_a, 4.0)
	mat_a.set_shader_parameter("alpha", 0.0)

	if mat_b != null:
		NeonMat.set_tint(mat_b, col_b)
		NeonMat.set_energy(mat_b, 4.0)
		mat_b.set_shader_parameter("alpha", 0.0)

	var pivot: Node3D = _halo_pivots[i]
	pivot.position         = pos
	pivot.rotation_degrees = Vector3(0.0, y_rot_deg, 0.0)
	pivot.visible          = true
	_halo_busy[i] = true

	var tw_in: Tween = _new_tween()
	_tw_param(tw_in, mat_a, "alpha", 0.0, 0.80, 0.15, false)
	if mat_b != null:
		_tw_param(tw_in, mat_b, "alpha", 0.0, 0.70, 0.15)

	var spin: Tween = _new_tween()
	spin.tween_property(pivot, "rotation_degrees:z", spin_deg, spin_s)
	if mat_b != null and inner_spin_s > 0.0:
		spin.parallel().tween_property(pivot, "rotation_degrees:y",
			y_rot_deg + inner_spin_deg, inner_spin_s)
	_halo_spins[i] = spin

	var tw_out: Tween = _new_tween()
	tw_out.tween_interval(life_s)
	_tw_param(tw_out, mat_a, "alpha",  0.80, 0.0, 0.18, false)
	_tw_param(tw_out, mat_a, "energy", 4.0,  0.0, 0.18)
	if mat_b != null:
		_tw_param(tw_out, mat_b, "alpha",  0.70, 0.0, 0.22)
		_tw_param(tw_out, mat_b, "energy", 4.0,  0.0, 0.22)
	tw_out.tween_callback(func() -> void:
		pivot.visible = false
		_halo_busy[i] = false
		var s: Tween = _halo_spins[i]
		if s != null and s.is_valid():
			s.kill()
	)
	_halo_tws[i] = tw_out


## Re-tints every live halo to the current cycle colours. Replaces the old
## per-frame walk over _active_halo_mats / _active_halo_mats_b, and needs no
## is_instance_valid() check — the pool owns these materials for the whole run.
## Alpha is preserved so the fade tweens keep working.
func update_halo_colors(col_a: Color, col_b: Color) -> void:
	if _halo_textured:
		return   # stripe texture drives the colour; material tint stays neutral
	for i in range(_halo_pivots.size()):
		if not _halo_busy[i]:
			continue
		# Alpha is a separate uniform now, so retinting cannot disturb the fade.
		NeonMat.set_tint(_halo_mats_a[i], col_a)
		var mb: ShaderMaterial = _halo_mats_b[i]
		if mb != null:
			NeonMat.set_tint(mb, col_b)


## 256x1 alternating-stripe texture for dual-colour circle halos. Rebuilt only
## when the primary colour has drifted a quantisation step — the old code built
## a fresh Image plus a fresh GPU texture on EVERY melody event.
func _stripe_texture(col_a: Color, col_b: Color) -> ImageTexture:
	var key: int = (int(col_a.r * _STRIPE_QUANT) << 16) \
				 | (int(col_a.g * _STRIPE_QUANT) << 8) \
				 |  int(col_a.b * _STRIPE_QUANT)
	if _stripe_tex != null and key == _stripe_key:
		return _stripe_tex

	if _stripe_img == null:
		_stripe_img = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for x in 256:
		_stripe_img.set_pixel(x, 0, col_a if int(float(x) / 256.0 * 12.0) % 2 == 0 else col_b)

	if _stripe_tex == null:
		_stripe_tex = ImageTexture.create_from_image(_stripe_img)
	else:
		_stripe_tex.update(_stripe_img)   # in-place GPU update, no new resource
	_stripe_key = key
	return _stripe_tex
