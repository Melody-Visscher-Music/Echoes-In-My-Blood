extends Node3D
class_name ImpactFx

## Big moments, shared: the charge tunnel's drop and the grind's mount, flow
## level-ups and finale use these (the smash wall has its own, built first).
## All of it is cosmetic and none of it touches time — slowing the clock
## would put him behind the music and throw off the gates that follow.
##
##   frame()   a screen punch: STYLE_WARP (the drop — chromatic split, the
##             picture bulging out from the centre, a white-blue flash) or
##             STYLE_GLOW (the grind — a warm bloom with a radial streak),
##             settling out over a few tenths of a second
##   bolts()   lightning bursting out from a point in every direction
##   pillar()  a column of light shooting up from a point
##   dome()    a sphere of light swelling out round a point and thinning
##   flash()   a big light that lights him and the street, then dies
##   boom()    a deep falling sub-boom under whatever else is playing
##
## Everything that flashes is scaled by GameConfig.flash_scale(); with reduced
## flashing the screen punch is a gentle blur only.

const STYLE_WARP: int = 0
const STYLE_GLOW: int = 1
const SR: int = 22050
const BOLT_SEGS: int = 9

var section: Node = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _bolts: Array[Dictionary] = []     # {segs, mat, life, max, a, dir, len, col}
var _seg_mesh: BoxMesh = null
var _sub: AudioStreamPlayer = null
var _shimmer: AudioStreamPlayer = null


## One per section, made on first use.
static func for_section(s: Node) -> ImpactFx:
	var n: Node = s.get_node_or_null("ImpactFx")
	if n != null:
		return n as ImpactFx
	var fx := ImpactFx.new()
	fx.name = "ImpactFx"
	fx.section = s
	s.add_child(fx)
	return fx


func _ready() -> void:
	_seg_mesh = BoxMesh.new()
	_seg_mesh.size = Vector3.ONE
	_sub = _player_for(_gen_boom(), -2.0)
	_shimmer = _player_for(_gen_shimmer(), -9.0)


# ── Screen punch ─────────────────────────────────────────────────────────────

const SHADER: String = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform int style = 0;
uniform float k = 0.0;          // 1 at the hit, easing to 0
uniform vec2 centre = vec2(0.5, 0.5);
uniform vec4 tint : source_color = vec4(0.6, 0.9, 1.0, 1.0);
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - centre;
	float r = length(d * vec2(1.7, 1.0));
	vec3 c;
	if (style == 0) {
		// Bulge out from the centre, split the channels radially, blur outward.
		vec2 b = d * (1.0 - 0.10 * k * (1.0 - smoothstep(0.0, 0.8, r)));
		vec2 base = centre + b;
		float ca = 0.018 * k;
		c = vec3(0.0);
		for (int i = 0; i < 6; i++) {
			float f = float(i) / 5.0;
			vec2 o = -d * 0.06 * k * f;
			c.r += texture(screen_tex, base + o + d * ca).r;
			c.g += texture(screen_tex, base + o).g;
			c.b += texture(screen_tex, base + o - d * ca).b;
		}
		c /= 6.0;
		c = mix(c, tint.rgb * 1.3, 0.22 * k * k * smoothstep(0.45, 0.0, r));
	} else {
		c = vec3(0.0);
		for (int i = 0; i < 6; i++) {
			c += texture(screen_tex, uv - d * 0.05 * k * float(i) / 5.0).rgb;
		}
		c /= 6.0;
		c += tint.rgb * 0.22 * k * smoothstep(0.5, 0.0, r);
	}
	COLOR = vec4(c, 1.0);
}
"""


func frame(style: int, tint: Color, strength: float = 1.0, dur: float = 0.45) -> void:
	var hud: Object = section.get("_hud")
	if hud == null:
		return
	if _rect == null:
		var root: Control = hud.call("overlay_root") as Control
		if root == null:
			return
		_rect = ColorRect.new()
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = SHADER
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_rect.material = _mat
		root.add_child(_rect)
		root.move_child(_rect, 0)
	var fs: float = GameConfig.flash_scale()
	_mat.set_shader_parameter("style", style)
	_mat.set_shader_parameter("tint", tint)
	# Where he is on screen, so the punch comes out of him.
	var cam: Camera3D = section.get_viewport().get_camera_3d()
	var p: Node3D = section.get("player") as Node3D
	if cam != null and p != null and not cam.is_position_behind(p.global_position):
		var sp: Vector2 = cam.unproject_position(p.global_position + Vector3(0, 0.9, 0))
		var vp: Vector2 = section.get_viewport().get_visible_rect().size
		_mat.set_shader_parameter("centre", Vector2(sp.x / vp.x, sp.y / vp.y))
	_rect.visible = true
	var top: float = strength * lerpf(0.35, 1.0, fs)
	var tw: Tween = _rect.create_tween()
	tw.tween_method(func(v: float) -> void: _mat.set_shader_parameter("k", v), top, 0.0, dur) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_callback(func() -> void: _rect.visible = false)


# ── Lightning ────────────────────────────────────────────────────────────────

func bolts(centre: Vector3, col: Color, count: int, length: float, life: float = 0.4) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	for k in count:
		var b: Dictionary = _free_bolt(world)
		var ang: float = TAU * float(k) / float(count) + randf_range(-0.25, 0.25)
		var up: float = randf_range(-0.25, 0.75)
		var dir := Vector3(cos(ang), up, sin(ang)).normalized()
		# Nothing back at the lens: a bolt aimed toward the camera is mirrored
		# away from it, so they burst out round him instead of across the screen.
		var fwd: Vector3 = section.call("_path_forward_at", float(section.get("_player_path_dist")))
		var back: float = dir.dot(fwd)
		if back < -0.15:
			dir = (dir - fwd * 2.0 * back).normalized()
		b["a"] = centre
		b["dir"] = dir
		b["len"] = length * randf_range(0.6, 1.1)
		b["life"] = life * randf_range(0.8, 1.1)
		b["max"] = b["life"]
		var m: StandardMaterial3D = b["mat"]
		m.albedo_color = col
		m.emission = col


func _free_bolt(world: Node3D) -> Dictionary:
	for b: Dictionary in _bolts:
		if float(b["life"]) <= 0.0:
			return b
	var root := Node3D.new()
	root.top_level = true
	world.add_child(root)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.emission_enabled = true
	m.emission_energy_multiplier = 6.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var segs: Array[MeshInstance3D] = []
	for s in BOLT_SEGS:
		var mi := MeshInstance3D.new()
		mi.mesh = _seg_mesh
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("no_cycle", true)
		mi.visible = false
		root.add_child(mi)
		segs.append(mi)
	var b: Dictionary = {"segs": segs, "mat": m, "life": 0.0, "max": 1.0, "a": Vector3.ZERO,
		"dir": Vector3.UP, "len": 1.0, "re": 0.0}
	_bolts.append(b)
	return b


func _process(delta: float) -> void:
	var fs: float = GameConfig.flash_scale()
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
		var k: float = clampf(life / float(b["max"]), 0.0, 1.0)
		var m: StandardMaterial3D = b["mat"]
		m.albedo_color.a = k
		m.emission_energy_multiplier = (2.0 + 8.0 * k) * maxf(fs, 0.35)
		b["re"] = float(b["re"]) - delta
		if float(b["re"]) > 0.0 and life > 0.0:
			continue
		b["re"] = 0.03
		# Grows out fast, then flickers in place.
		var reach: float = float(b["len"]) * minf(1.0, (1.0 - k) * 4.0 + 0.25)
		var a: Vector3 = b["a"]
		var dir: Vector3 = b["dir"]
		var pts: Array[Vector3] = []
		var side: Vector3 = dir.cross(Vector3.UP).normalized() if absf(dir.y) < 0.95 else Vector3.RIGHT
		var up2: Vector3 = side.cross(dir).normalized()
		for i in BOLT_SEGS + 1:
			var f: float = float(i) / float(BOLT_SEGS)
			var p: Vector3 = a + dir * reach * f
			if i > 0 and i < BOLT_SEGS:
				var j: float = 0.18 * reach * 0.2
				p += side * randf_range(-j, j) * 2.0 + up2 * randf_range(-j, j) * 2.0
			pts.append(p)
		var th: float = lerpf(0.04, 0.11, k)
		for i in BOLT_SEGS:
			var s2: MeshInstance3D = segs[i]
			var d: Vector3 = pts[i + 1] - pts[i]
			var l: float = d.length()
			if l < 0.001 or life <= 0.0:
				s2.visible = false
				continue
			var z: Vector3 = d / l
			var upv: Vector3 = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
			var x: Vector3 = upv.cross(z).normalized()
			var y: Vector3 = z.cross(x)
			s2.global_transform = Transform3D(Basis(x * th, y * th, z * l), (pts[i] + pts[i + 1]) * 0.5)
			s2.visible = true


# ── Shapes of light ──────────────────────────────────────────────────────────

func pillar(base: Vector3, col: Color, height: float = 40.0, life: float = 0.8) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.5
	cm.bottom_radius = 1.2
	cm.height = 1.0
	cm.radial_segments = 16
	cm.rings = 1
	cm.cap_top = false
	cm.cap_bottom = false
	mi.mesh = cm
	var m: ShaderMaterial = NeonMat.ring(col, 0.0)
	m.set_shader_parameter("alpha", 0.3)
	mi.material_override = m
	mi.set_meta("no_cycle", true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mi)
	mi.global_position = base
	var fs: float = maxf(GameConfig.flash_scale(), 0.35)
	var tw: Tween = mi.create_tween()
	tw.tween_method(func(v: float) -> void:
		var h: float = height * minf(1.0, v * 5.0)
		var w: float = lerpf(1.0, 2.6, v)
		mi.scale = Vector3(w, h, w)
		mi.global_position = base + Vector3(0, h * 0.5, 0)
		NeonMat.set_energy(m, (1.0 - v) * 3.5 * fs), 0.0, 1.0, life)
	tw.tween_callback(mi.queue_free)


func dome(centre: Vector3, col: Color, radius: float = 9.0, life: float = 0.55) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 24
	sm.rings = 12
	mi.mesh = sm
	var m: ShaderMaterial = NeonMat.ring(col, 0.0)
	m.set_shader_parameter("alpha", 0.16)
	m.set_shader_parameter("band_amount", 0.6)
	mi.material_override = m
	mi.set_meta("no_cycle", true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mi)
	mi.global_position = centre
	var fs: float = maxf(GameConfig.flash_scale(), 0.35)
	var tw: Tween = mi.create_tween()
	tw.tween_method(func(v: float) -> void:
		mi.scale = Vector3.ONE * lerpf(0.5, radius, 1.0 - pow(1.0 - v, 3.0))
		NeonMat.set_energy(m, (1.0 - v) * (1.0 - v) * 2.5 * fs), 0.0, 1.0, life)
	tw.tween_callback(mi.queue_free)


func flash(pos: Vector3, col: Color, energy: float = 24.0, life: float = 0.5) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy * lerpf(0.25, 1.0, GameConfig.flash_scale())
	l.omni_range = 24.0
	world.add_child(l)
	l.global_position = pos
	var tw: Tween = l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, life).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	tw.tween_callback(l.queue_free)


func boom(pitch: float = 1.0) -> void:
	if _sub != null:
		_sub.pitch_scale = pitch
		_sub.play()


func shimmer(pitch: float = 1.0) -> void:
	if _shimmer != null:
		_shimmer.pitch_scale = pitch
		_shimmer.play()


# ── Sound ────────────────────────────────────────────────────────────────────

func _player_for(stream: AudioStreamWAV, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	add_child(p)
	return p


func _wav(s: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	return w


func _gen_boom() -> AudioStreamWAV:
	var n: int = int(1.3 * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = lerpf(110.0, 30.0, minf(1.0, t / 0.7))
		ph += TAU * f / float(SR)
		var body: float = sin(ph) * exp(-t * 2.8)
		var click: float = randf_range(-1.0, 1.0) * exp(-t * 70.0) * 0.7
		out[i] = clampf((body * 1.5 + click) * minf(1.0, t * 600.0), -1.0, 1.0) * 0.9
	return _wav(out)


## A bright rising shimmer: stacked sines sweeping up, for the grind's flares.
func _gen_shimmer() -> AudioStreamWAV:
	var n: int = int(0.7 * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph: Array[float] = [0.0, 0.0, 0.0]
	for i in n:
		var t: float = float(i) / float(SR)
		var v: float = 0.0
		for h in 3:
			var f: float = (660.0 + 220.0 * float(h)) * (1.0 + 0.8 * t)
			ph[h] += TAU * f / float(SR)
			v += sin(ph[h]) * (0.22 - 0.05 * float(h))
		out[i] = v * exp(-t * 4.0) * minf(1.0, t * 80.0)
	return _wav(out)
