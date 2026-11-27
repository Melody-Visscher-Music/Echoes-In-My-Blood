extends Node3D
class_name ChargeCinema

## The charge tunnel, filmed. Nothing here changes how it plays — the weave,
## the alignment tolerance, the fill and the payoff all stay in
## Section_BeatRunner3d. The point is tension then release, and every effect
## also helps read the weave:
##
##   ignition   when the tunnel appears the hoops light one after another from
##              near to far, so the whole weave is drawn before he enters it
##   next hoop  the hoop he has to thread next pulses on the beat and stands
##              out; the ones he has already passed dim right down
##   threading  a clean pass flashes the hoop and throws a ring off it with a
##              tick that climbs in pitch with the charge; clipping the rim
##              flashes it red and spits sparks
##   charging   energy streams into him while he holds clean, an aura grows
##              round him and heats from blue to white, speed lines thicken,
##              letterbox bars close in and a riser climbs under the music
##   camera     a little lower (looking through the hoops), leaning into his
##              steering, a slight look-ahead toward where the weave goes, and
##              the view slowly squeezes in as the charge builds
##   the drop   OVERDRIVE: shockwave, burst, the view punches out wide and the
##              bars snap away. A fizzle just puffs out grey
##   overdrive  while the ×100 window runs, a faint crackling aura stays on him
##              and fades as the window drains
##
## The section owns one: setup() once, update() every frame, on_spawn /
## on_despawn / on_payoff at the matching moments.

const COL_LOW: Color = Color(0.25, 0.75, 1.0)
const COL_HIGH: Color = Color(0.6, 0.95, 1.0)
const COL_BAD: Color = Color(1.0, 0.18, 0.22)
const IGNITE_S: float = 1.0
## Horizon lean from his steering speed, at full steer.
const CAM_BANK_DEG: float = 3.5

var section: Node = null
var _player: CharacterBody3D = null
var _world: Node3D = null

# tunnel
var _hoops: Array[Dictionary] = []     # {pivot, mesh, mat, pd, state, flash}
var _gap_r: float = 1.15
var _ign_t: float = -1.0
var _next_i: int = 0

# camera
var _cam: Camera3D = null
var _pivot: Node3D = null
var _rest: Transform3D = Transform3D.IDENTITY
var _cam_on: bool = false
var _w: float = 0.0
var _bank: float = 0.0
var _punch: float = 0.0
var _shake: float = 0.0
var _prev_lat: float = 0.0

# fx
var _fx: Node3D = null
var _aura: MeshInstance3D = null
var _aura_mat: ShaderMaterial = null
var _aura_light: OmniLight3D = null
var _suck: CPUParticles3D = null
var _suck_mat: ShaderMaterial = null
var _streaks: CPUParticles3D = null
var _rim: CPUParticles3D = null
var _boom: CPUParticles3D = null
var _boom_mat: ShaderMaterial = null
var _crackle: CPUParticles3D = null
var _rings: Array[Dictionary] = []
var _ring_i: int = 0
var _t: float = 0.0
var _aura_flare: float = 0.0

# letterbox
var _bars: Array[ColorRect] = []
var _bar_k: float = 0.0

# sound
var _riser: AudioStreamPlayer = null
var _tick: AudioStreamPlayer = null
var _thud: AudioStreamPlayer = null
var _fizz: AudioStreamPlayer = null
var _clip: AudioStreamPlayer = null
const SR: int = 22050


func _init() -> void:
	name = "ChargeCinema"


func setup(p_section: Node) -> void:
	section = p_section
	_player = section.get("player") as CharacterBody3D
	_world = section.get("world_fx_root") as Node3D
	_build_fx()
	_riser = _sfx(_gen_riser(), -60.0)
	(_riser.stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	(_riser.stream as AudioStreamWAV).loop_end = int(1.0 * SR)
	_tick = _sfx(_gen_tick(), -21.0)
	_thud = _sfx(_gen_boom(), -8.0)
	_fizz = _sfx(_gen_fizz(), -16.0)
	_clip = _sfx(_gen_clip(), -18.0)


# ══════════════════════════════════════════════════════════════════════════════
#  Events
# ══════════════════════════════════════════════════════════════════════════════

## The tunnel has just been built under `root`: one pivot per hoop, spaced
## `spacing` metres from `start_pd`.
func on_spawn(root: Node3D, start_pd: float, spacing: float, gap_radius: float) -> void:
	_hoops.clear()
	_gap_r = gap_radius
	_next_i = 0
	var i: int = 0
	for pv: Node in root.get_children():
		var mi: MeshInstance3D = null
		for c: Node in pv.get_children():
			if c is MeshInstance3D:
				mi = c
				break
		var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D if mi != null else null
		if mat != null:
			mat.emission_energy_multiplier = 0.0
			mat.albedo_color = Color(0.05, 0.08, 0.12)
		_hoops.append({"pivot": pv, "mesh": mi, "mat": mat, "pd": start_pd + float(i) * spacing,
			"state": 0, "flash": 0.0})
		i += 1
	_ign_t = 0.0


func on_despawn() -> void:
	_hoops.clear()
	_ign_t = -1.0


## The drop has landed. `success` = the ×100 window opened.
func on_payoff(success: bool) -> void:
	var p: Vector3 = _player.global_position + Vector3(0.0, 0.9, 0.0)
	var fs: float = GameConfig.flash_scale()
	if success:
		GameConfig.rumble(0.7, 1.0, 0.5)
		_punch = 1.0
		_shake = 1.0 * fs
		_aura_flare = 1.0
		_spawn_ring(p, COL_HIGH, 6.5, 0.6, true)
		_spawn_ring(p, COL_LOW, 4.5, 0.5, true)
		_spawn_ring(p, COL_LOW, 3.5, 0.45, false)
		NeonMat.set_tint(_boom_mat, COL_HIGH)
		NeonMat.set_energy(_boom_mat, 6.0 * maxf(fs, 0.4))
		_boom.global_position = p
		_boom.restart()
		_boom.emitting = true
		if _thud != null:
			_thud.play()
		# The release, as big as the build was long: the picture punches out
		# from him in a chromatic warp, lightning bursts out of him in every
		# direction, a column of light shoots up off the track, a dome of it
		# swells round him, and a sub-boom lands under the drop.
		_punch = 1.4
		var fx: ImpactFx = ImpactFx.for_section(section)
		fx.frame(ImpactFx.STYLE_WARP, COL_HIGH, 1.0, 0.55)
		fx.bolts(p, COL_HIGH, 12, 9.0, 0.45)
		fx.bolts(p, Color(1.0, 1.0, 1.0), 5, 6.0, 0.3)
		fx.pillar(_player.global_position, COL_HIGH, 48.0, 0.9)
		fx.dome(p, COL_LOW, 11.0, 0.6)
		fx.flash(p, COL_HIGH, 10.0, 0.45)
		fx.boom(1.0)
	else:
		NeonMat.set_tint(_boom_mat, Color(0.45, 0.45, 0.55))
		NeonMat.set_energy(_boom_mat, 1.0)
		_boom.global_position = p
		_boom.restart()
		_boom.emitting = true
		GameConfig.rumble(0.2, 0.0, 0.15)
		if _fizz != null:
			_fizz.play()


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(_t_s: float, delta: float) -> void:
	_t += delta
	if _player == null or not is_instance_valid(_player):
		return
	var active: bool = bool(section.get("_charge_active"))
	var building: bool = active and bool(section.get("_charge_building"))
	var charge: float = float(section.get("_charge"))
	var fs: float = GameConfig.flash_scale()
	var pd: float = float(section.get("_player_path_dist"))
	var lat: float = float(_player.call("charge_lateral")) if building else 0.0
	var holding: bool = building and bool(_player.call("grind_held"))
	var aligned: bool = building and absf(lat - float(section.call("_gap_curve_x", pd))) < _gap_r

	_punch = maxf(0.0, _punch - delta * 1.8)
	_shake = maxf(0.0, _shake - delta * 3.0)
	_aura_flare = maxf(0.0, _aura_flare - delta * 1.6)

	if active:
		_update_hoops(pd, lat, charge, building, delta, fs)
	_update_aura(building, holding, aligned, charge, fs, delta)
	_update_rings(delta)
	_update_camera(building, charge, lat, delta)
	_update_letterbox(building, charge, delta)
	_update_sound(building, holding, charge, delta)


func _update_hoops(pd: float, lat: float, charge: float, building: bool, delta: float, fs: float) -> void:
	if _hoops.is_empty():
		return
	if _ign_t >= 0.0:
		_ign_t += delta
	var first_pd: float = float(_hoops[0]["pd"])
	var last_pd: float = float(_hoops[_hoops.size() - 1]["pd"])
	var front: float = lerpf(first_pd - 1.0, last_pd + 1.0, clampf(_ign_t / IGNITE_S, 0.0, 1.0))
	var beat: float = float(section.get("_beat_phase"))
	var col_ahead: Color = COL_LOW.lerp(COL_HIGH, charge)
	# The hoop to aim for: the first one still a few metres off. The one at his
	# body is already decided, and up close it would fill the screen.
	var aim_i: int = _next_i
	while aim_i < _hoops.size() and float(_hoops[aim_i]["pd"]) < pd + 3.0:
		aim_i += 1

	# Passing: judge each hoop as he crosses it (presentation only — the fill
	# itself is the section's).
	while _next_i < _hoops.size() and pd >= float(_hoops[_next_i]["pd"]):
		var h: Dictionary = _hoops[_next_i]
		_next_i += 1
		if not building:
			h["state"] = 1
			continue
		var gx: float = float(section.call("_gap_curve_x", float(h["pd"])))
		var ok: bool = absf(lat - gx) < _gap_r and bool(_player.call("grind_held"))
		h["state"] = 1 if ok else 2
		h["flash"] = 1.0
		var hp: Vector3 = (h["pivot"] as Node3D).global_position
		if ok:
			GameConfig.rumble(0.12 + 0.25 * charge, 0.0, 0.04)
			_spawn_ring(hp, col_ahead, 2.6, 0.35, false, h["pivot"] as Node3D)
			if _tick != null:
				_tick.pitch_scale = lerpf(0.9, 2.0, charge)
				_tick.play()
		else:
			GameConfig.rumble(0.2, 0.35, 0.1)
			_rim.global_position = hp + ((_player.global_position + Vector3(0, 0.9, 0)) - hp).normalized() * _gap_r
			_rim.restart()
			_rim.emitting = true
			if _clip != null:
				_clip.play()

	for i in _hoops.size():
		var h: Dictionary = _hoops[i]
		var mat: StandardMaterial3D = h["mat"]
		var mesh: MeshInstance3D = h["mesh"]
		if mat == null or mesh == null or not is_instance_valid(mesh):
			continue
		var hpd: float = float(h["pd"])
		var fl: float = float(h["flash"])
		if fl > 0.0:
			# Gone before the camera (a few metres behind him) reaches the hoop.
			fl = maxf(0.0, fl - delta * 7.0)
			h["flash"] = fl
		var col: Color
		var e: float
		var sc: float = 1.0
		var st: int = int(h["state"])
		if hpd > front:
			col = Color(0.05, 0.08, 0.12)   # not lit yet
			e = 0.0
		elif st == 0:
			# Ahead of him. Near ones brighter, the far end fading into the dark,
			# the very next one pulsing so it can't be missed.
			var ahead: int = i - aim_i
			col = col_ahead
			e = (1.1 + 0.7 * charge) * clampf(1.1 - float(ahead) * 0.06, 0.5, 1.0)
			if ahead < 0:
				e *= 0.6
			if ahead == 0 and building:
				e *= 1.3 + 0.5 * beat * fs
				sc = 1.0 + 0.10 * beat * fs
			# The moment the ignition front passes: a quick flare.
			var since: float = (front - hpd) / maxf(1.0, (last_pd - first_pd) / IGNITE_S)
			if since < 0.15 and _ign_t < IGNITE_S + 0.2:
				e += 1.6 * (1.0 - since / 0.15) * fs
		elif st == 1:
			col = col_ahead.lerp(Color(1, 1, 1), fl * 0.6)
			e = 0.2 + 1.6 * fl * fs
			sc = 1.0 + 0.2 * fl
		else:
			col = COL_BAD
			e = 0.5 + 1.6 * fl * maxf(fs, 0.4)
		mat.albedo_color = col
		mat.emission = col
		mat.emission_energy_multiplier = e
		mesh.scale = Vector3(sc, sc, sc)


# ══════════════════════════════════════════════════════════════════════════════
#  Aura, energy, speed
# ══════════════════════════════════════════════════════════════════════════════

func _update_aura(building: bool, holding: bool, aligned: bool, charge: float, fs: float, delta: float) -> void:
	if _aura == null:
		return
	var od_t: float = float(section.get("_charge_mult_timer"))
	var od_total: float = maxf(0.01, float(section.get("_charge_mult_total")))
	var od: float = clampf(od_t / od_total, 0.0, 1.0) if od_t > 0.0 else 0.0
	var col: Color = COL_LOW.lerp(COL_HIGH, charge)
	var k: float = 0.0
	if building:
		k = (0.25 + 0.75 * charge) * (1.0 if holding else 0.4)
	k = maxf(k, od * 0.45 * randf_range(0.75, 1.1))
	k = maxf(k, _aura_flare)
	_aura.visible = k > 0.01
	var sc: float = 0.75 + 0.55 * charge + 1.8 * _aura_flare
	_aura.scale = Vector3(sc, sc * 1.25, sc)
	NeonMat.set_tint(_aura_mat, col if od <= 0.0 or building else COL_LOW.lerp(COL_HIGH, 0.4))
	_aura_mat.set_shader_parameter("alpha", (0.03 + 0.08 * k) * maxf(fs, 0.5) * (1.0 - _aura_flare * 0.5))
	NeonMat.set_energy(_aura_mat, 0.4 + 0.7 * k)
	_aura_light.light_color = col
	_aura_light.light_energy = k * 0.6 * fs

	_suck.emitting = building and holding and aligned
	_suck.speed_scale = 1.0 + charge
	NeonMat.set_tint(_suck_mat, col)
	_streaks.emitting = building and charge > 0.25
	_streaks.speed_scale = 0.8 + charge * 0.9
	_crackle.emitting = (building and charge > 0.75) or od > 0.05


func _build_fx() -> void:
	_fx = Node3D.new()
	_fx.name = "ChargeFX"
	_player.add_child(_fx)
	# Aura shell.
	var am := SphereMesh.new()
	am.radius = 0.75
	am.height = 1.5
	am.radial_segments = 24
	am.rings = 12
	_aura_mat = NeonMat.ring(COL_LOW, 1.0)
	_aura_mat.set_shader_parameter("band_amount", 0.0)
	_aura_mat.set_shader_parameter("alpha", 0.0)
	_aura = MeshInstance3D.new()
	_aura.mesh = am
	_aura.material_override = _aura_mat
	_aura.set_meta("no_cycle", true)
	_aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aura.position = Vector3(0.0, 0.85, 0.0)
	_aura.visible = false
	_fx.add_child(_aura)
	_aura_light = OmniLight3D.new()
	_aura_light.light_energy = 0.0
	_aura_light.omni_range = 4.0
	_aura_light.position = Vector3(0.0, 0.9, 0.0)
	_fx.add_child(_aura_light)
	# Energy streaming in from all round him.
	var sm := SphereMesh.new()
	sm.radius = 0.035
	sm.height = 0.07
	sm.radial_segments = 6
	sm.rings = 3
	_suck_mat = NeonMat.orb(COL_LOW, 3.5)
	sm.material = _suck_mat
	_suck = _emitter(sm, 60, 0.45, false)
	_suck.emission_sphere_radius = 3.2
	_suck.position = Vector3(0.0, 0.9, 0.0)
	_suck.initial_velocity_min = 0.0
	_suck.initial_velocity_max = 0.0
	_suck.radial_accel_min = -26.0
	_suck.radial_accel_max = -18.0
	_suck.gravity = Vector3.ZERO
	_suck.local_coords = true     # converge on HIM as he moves, not where he was
	_fx.add_child(_suck)
	# Speed lines.
	var lm := BoxMesh.new()
	lm.size = Vector3(0.025, 0.025, 0.6)
	var lmat: ShaderMaterial = NeonMat.tube(Color(0.8, 0.93, 1.0), 4.0)
	lmat.set_shader_parameter("box_size", lm.size)
	lm.material = lmat
	_streaks = _emitter(lm, 40, 0.4, false)
	_streaks.emission_sphere_radius = 2.4
	_streaks.direction = Vector3(0.0, 0.0, -1.0)
	_streaks.spread = 4.0
	_streaks.initial_velocity_min = 15.0
	_streaks.initial_velocity_max = 24.0
	_streaks.gravity = Vector3.ZERO
	_streaks.position = Vector3(0.0, 1.2, 3.5)
	_fx.add_child(_streaks)
	# Crackle at a high charge / through overdrive.
	var cm := BoxMesh.new()
	cm.size = Vector3(0.02, 0.02, 0.22)
	var cmat: ShaderMaterial = NeonMat.tube(COL_HIGH, 5.0)
	cmat.set_shader_parameter("box_size", cm.size)
	cm.material = cmat
	_crackle = _emitter(cm, 16, 0.12, false)
	_crackle.emission_sphere_radius = 0.7
	_crackle.position = Vector3(0.0, 0.9, 0.0)
	_crackle.spread = 180.0
	_crackle.initial_velocity_min = 2.0
	_crackle.initial_velocity_max = 5.0
	_crackle.gravity = Vector3.ZERO
	_crackle.local_coords = true
	_fx.add_child(_crackle)
	# Rim sparks on a clipped hoop.
	var rm := SphereMesh.new()
	rm.radius = 0.04
	rm.height = 0.08
	rm.radial_segments = 6
	rm.rings = 3
	rm.material = NeonMat.orb(Color(1.0, 0.35, 0.3), 4.0)
	_rim = _emitter(rm, 24, 0.35, true)
	_rim.spread = 180.0
	_rim.initial_velocity_min = 2.0
	_rim.initial_velocity_max = 5.5
	_rim.gravity = Vector3(0.0, -9.0, 0.0)
	_world.add_child(_rim)
	# The drop.
	var bm := SphereMesh.new()
	bm.radius = 0.06
	bm.height = 0.12
	bm.radial_segments = 6
	bm.rings = 3
	_boom_mat = NeonMat.orb(COL_HIGH, 6.0)
	bm.material = _boom_mat
	_boom = _emitter(bm, 90, 0.8, true)
	_boom.spread = 180.0
	_boom.initial_velocity_min = 6.0
	_boom.initial_velocity_max = 14.0
	_boom.damping_min = 6.0
	_boom.damping_max = 10.0
	_boom.gravity = Vector3(0.0, -3.0, 0.0)
	_boom.emission_sphere_radius = 0.5
	_world.add_child(_boom)


func _emitter(mesh: Mesh, amount: int, life: float, one_shot: bool) -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.one_shot = one_shot
	e.explosiveness = 0.92 if one_shot else 0.0
	e.local_coords = false
	e.mesh = mesh
	e.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	e.emission_sphere_radius = 0.15
	e.particle_flag_align_y = true
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	e.scale_amount_curve = c
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.emitting = false
	return e


## Expanding ring. `face_path` = stands across the track like the hoops
## (passed a hoop pivot to copy its facing); otherwise lies flat.
func _spawn_ring(pos: Vector3, col: Color, size: float, life: float, flat: bool, face: Node3D = null) -> void:
	if _rings.is_empty():
		var tm := TorusMesh.new()
		tm.inner_radius = 0.44
		tm.outer_radius = 0.5
		tm.rings = 40
		tm.ring_segments = 6
		for k in 10:
			var m: ShaderMaterial = NeonMat.ring(Color(1, 1, 1), 0.0)
			var n := MeshInstance3D.new()
			n.mesh = tm
			n.material_override = m
			n.set_meta("no_cycle", true)
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = false
			_world.add_child(n)
			_rings.append({"node": n, "mat": m, "t": -1.0, "s": 1.0, "life": 0.4})
	var r: Dictionary = _rings[_ring_i]
	_ring_i = (_ring_i + 1) % _rings.size()
	var node: MeshInstance3D = r["node"]
	node.visible = true
	node.global_position = pos
	if face != null and is_instance_valid(face):
		node.global_rotation = Vector3(0.0, face.global_rotation.y, 0.0)
		node.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	else:
		node.global_rotation = Vector3.ZERO
		if not flat:
			var pd: float = float(section.get("_player_path_dist"))
			node.global_rotation = Vector3(0.0, deg_to_rad(float(section.call("_path_y_rot_at", pd))), 0.0)
			node.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	NeonMat.set_tint(r["mat"], col)
	r["t"] = 0.0
	r["s"] = size
	r["life"] = life


func _update_rings(delta: float) -> void:
	var fs: float = GameConfig.flash_scale()
	for r: Dictionary in _rings:
		var t: float = float(r["t"])
		if t < 0.0:
			continue
		t += delta
		r["t"] = t
		var node: MeshInstance3D = r["node"]
		var k: float = t / float(r["life"])
		if k >= 1.0:
			r["t"] = -1.0
			node.visible = false
			continue
		var sc: float = lerpf(0.45, 1.0, 1.0 - (1.0 - k) * (1.0 - k)) * float(r["s"])
		node.scale = Vector3(sc, 1.0, sc)
		NeonMat.set_energy(r["mat"], (1.0 - k) * 1.8 * fs + 0.1)


# ══════════════════════════════════════════════════════════════════════════════
#  Camera
# ══════════════════════════════════════════════════════════════════════════════

func _update_camera(building: bool, charge: float, lat: float, delta: float) -> void:
	if _pivot == null or not is_instance_valid(_pivot):
		_cam = section.get("_camera") as Camera3D
		if _cam == null:
			return
		_pivot = _cam.get_parent() as Node3D
		if _pivot == null:
			return
	var fs: float = GameConfig.flash_scale()
	_w = move_toward(_w, 1.0 if building else 0.0, delta * (2.0 if building else 1.5))
	# Lean into the steering: lateral speed, normalised to the slide speed.
	var lat_v: float = (lat - _prev_lat) / maxf(delta, 0.001) if building else 0.0
	_prev_lat = lat
	var bank_target: float = clampf(lat_v / 7.0, -1.0, 1.0) * deg_to_rad(CAM_BANK_DEG) * lerpf(0.5, 1.0, fs)
	_bank = lerpf(_bank, bank_target * _w, minf(1.0, delta * 4.0))
	# Tension: the view squeezes in as the charge builds; the drop punches out.
	section.set("_charge_fov", -3.0 * charge * _w + _punch * _punch * 10.0)

	var active: bool = _w > 0.002 or absf(_bank) > 0.002 or _shake > 0.0
	var sm: Node = section.get("_smash")
	if bool(_player.call("is_grinding")) or (sm != null and bool(sm.call("is_mashing"))):
		active = false
	if not active:
		if _cam_on:
			_cam_on = false
			_pivot.transform = _rest
			if _cam != null:
				_cam.h_offset = 0.0
				_cam.v_offset = 0.0
		return
	if not _cam_on:
		_cam_on = true
		_rest = _pivot.transform
	var o: Vector3 = _rest.origin
	o.y *= lerpf(1.0, 0.86, _w)
	# Look-ahead: lean the frame toward where the weave is going.
	if building:
		var pd: float = float(section.get("_player_path_dist"))
		var ahead_x: float = float(section.call("_gap_curve_x", pd + 10.0))
		var centre: Vector3 = section.call("_path_world_pos", pd, ahead_x, 0.0)
		var want: float = _player.to_local(Vector3(centre.x, _player.global_position.y, centre.z)).x
		o.x += clampf(want, -2.5, 2.5) * 0.3 * _w
	var tr := Transform3D(_rest.basis, o)
	tr.basis = tr.basis * Basis(Vector3.BACK, _bank)
	_pivot.transform = tr
	if _cam != null:
		var sh: float = _shake * _shake * 0.25
		_cam.h_offset = randf_range(-sh, sh)
		_cam.v_offset = randf_range(-sh, sh)


# ══════════════════════════════════════════════════════════════════════════════
#  Letterbox
# ══════════════════════════════════════════════════════════════════════════════

func _update_letterbox(building: bool, charge: float, delta: float) -> void:
	# Closes in with the charge; snaps open on the drop.
	var want: float = (0.35 + 0.65 * charge) if building else 0.0
	_bar_k = move_toward(_bar_k, want, delta * (1.5 if building else 5.0))
	if _bars.is_empty():
		if _bar_k <= 0.0:
			return
		var hud: Object = section.get("_hud")
		if hud == null:
			return
		var root: Control = hud.call("overlay_root") as Control
		if root == null:
			return
		for k in 2:
			var b := ColorRect.new()
			b.color = Color(0.0, 0.0, 0.0, 0.92)
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(b)
			root.move_child(b, 0)
			_bars.append(b)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var h: float = vp.y * 0.085 * _bar_k
	_bars[0].position = Vector2.ZERO
	_bars[0].size = Vector2(vp.x, h)
	_bars[1].position = Vector2(0.0, vp.y - h)
	_bars[1].size = Vector2(vp.x, h)
	for b: ColorRect in _bars:
		b.visible = h > 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  Sound
# ══════════════════════════════════════════════════════════════════════════════

func _update_sound(building: bool, holding: bool, charge: float, delta: float) -> void:
	if _riser == null:
		return
	var want: float = lerpf(-30.0, -17.0, charge) if building and holding else -60.0
	_riser.volume_db = move_toward(_riser.volume_db, want, delta * (40.0 if want > -60.0 else 120.0))
	_riser.pitch_scale = 0.7 + 0.9 * charge
	if _riser.volume_db > -59.0 and not _riser.playing:
		_riser.play()
	elif _riser.volume_db <= -59.0 and _riser.playing:
		_riser.stop()


func _sfx(stream: AudioStreamWAV, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	p.max_polyphony = 3
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


## A charging hum: airy noise over a soft saw, looped. Pitch is driven live.
func _gen_riser() -> AudioStreamWAV:
	var n: int = int(1.0 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp: float = 0.0
	var lp2: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		lp += (randf_range(-1.0, 1.0) - lp) * 0.3
		lp2 += (lp - lp2) * 0.2
		var hum: float = (fposmod(t * 220.0, 1.0) * 2.0 - 1.0) * 0.12 + sin(TAU * 440.0 * t) * 0.08
		s[i] = (lp - lp2) * 0.9 + hum
	var fade: int = int(0.03 * SR)
	for i in fade:
		var k: float = float(i) / float(fade)
		s[i] = s[i] * k + s[n - fade + i] * (1.0 - k)
	return _wav(s)


func _gen_tick() -> AudioStreamWAV:
	var n: int = int(0.12 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = (sin(TAU * 1500.0 * t) * 0.5 + sin(TAU * 2250.0 * t) * 0.25) * exp(-t * 35.0)
	return _wav(s)


## The drop: a sub thump that falls, with a burst of noise on top.
func _gen_boom() -> AudioStreamWAV:
	var n: int = int(0.7 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = lerpf(110.0, 38.0, minf(1.0, t / 0.35))
		ph += TAU * f / float(SR)
		s[i] = sin(ph) * exp(-t * 4.5) * 0.9 + randf_range(-1.0, 1.0) * exp(-t * 18.0) * 0.35
	return _wav(s)


func _gen_fizz() -> AudioStreamWAV:
	var n: int = int(0.45 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp: float = 0.0
	for i in n:
		var t: float = float(i) / float(n)
		lp += (randf_range(-1.0, 1.0) - lp) * lerpf(0.4, 0.05, t)
		s[i] = lp * (1.0 - t) * 0.8
	return _wav(s)


func _gen_clip() -> AudioStreamWAV:
	var n: int = int(0.14 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = (sin(TAU * 310.0 * t) * 0.4 + randf_range(-1.0, 1.0) * 0.4) * exp(-t * 30.0)
	return _wav(s)
