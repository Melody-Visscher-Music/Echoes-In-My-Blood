extends Node3D
class_name GrindCinema

## The grind rail, filmed. Smash gates are about power — the build, the
## impact. A grind is about speed and flow, so everything here is about
## riding: nothing in this file changes how a grind plays (the rail, the
## sparks, the timing and the scoring all stay in Section_BeatRunner3d).
##
##   ignition    when the rail appears, a comet of light races down it from
##               the start to the far end — the rail lighting up ahead of him
##   rail cam    once he is on, the camera drops low and swings in over the
##               track to film him side-on against the city, leaning with the
##               rail through the curves. Big tricks (cross-over, cross-under,
##               loop) pull it wide so the whole shape is in shot; the
##               corkscrew rocks the horizon with him
##   letterbox   thin black bars slide in while he rides
##   speed       the view widens as the flow multiplier climbs; speed lines
##               from ×3, afterimages at full flow
##   sparks      a shower off his feet the whole ride, hotter with the flow,
##               and a scrape sound under the music that rises in pitch
##   the beat    the rail kicks brighter on every rap beat, caught or not, so
##               it visibly plays the rhythm he is tapping
##   a catch     a ring bursts off the rail at the spark, a soft chime that
##               climbs with the flow, and a nudge of the view
##   dropped     the sparks cut out, the rail stutters dark and the camera jolts
##   perfect     a burst of gold off the rail as it ends
##
## The section owns one: setup() once, update() every frame, and the on_*
## calls at the matching moments.

const RAIL_COL_HOT: Color = Color(1.0, 0.93, 0.78)
## How far the camera swings round him toward the track while he rides.
const CAM_YAW_DEG: float = 10.0
## Camera dutch roll from the rail's lean, as a share of it.
const CAM_LEAN_SHARE: float = 0.45
## Corkscrew: horizon rocks this far with the rider (not a full barrel roll).
const CAM_CORK_DEG: float = 9.0

var section: Node = null
var _player: Node3D = null

# camera
var _cam: Camera3D = null
var _pivot: Node3D = null
var _rest: Transform3D = Transform3D.IDENTITY
var _w_ride: float = 0.0
var _w_wide: float = 0.0
var _side: float = 0.0
var _roll: float = 0.0
var _cam_on: bool = false
var _jolt: float = 0.0
var _kick: float = 0.0

# state
var _was_riding: bool = false
var _tap_i: int = 0
var _beat_kick: float = 0.0
var _flicker: float = 0.0
var _t: float = 0.0

# fx
var _fx: Node3D = null
var _sparks: CPUParticles3D = null
var _sparks_hot: CPUParticles3D = null
var _burst: CPUParticles3D = null
var _streaks: CPUParticles3D = null
var _ghosts: CPUParticles3D = null
var _feet_light: OmniLight3D = null
var _spark_mat: ShaderMaterial = null
var _ghost_mat: ShaderMaterial = null
var _rings: Array[Dictionary] = []     # {node, mat, t}
var _ring_i: int = 0
var _comet: Node3D = null
var _comet_t: float = -1.0
var _comet_pd0: float = 0.0
var _comet_pd1: float = 0.0
const COMET_S: float = 1.1

# letterbox
var _bars: Array[ColorRect] = []
var _bar_k: float = 0.0

# sound
var _scrape: AudioStreamPlayer = null
var _chime: AudioStreamPlayer = null
var _clank: AudioStreamPlayer = null
const SR: int = 22050


func _init() -> void:
	name = "GrindCinema"


func setup(p_section: Node) -> void:
	section = p_section
	_player = section.get("player") as Node3D
	_build_fx()
	_scrape = _sfx(_gen_scrape(), -60.0)
	(_scrape.stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	(_scrape.stream as AudioStreamWAV).loop_end = int(0.8 * SR)
	_chime = _sfx(_gen_chime(), -19.0)
	_clank = _sfx(_gen_clank(), -12.0)


# ══════════════════════════════════════════════════════════════════════════════
#  Events
# ══════════════════════════════════════════════════════════════════════════════

## The rail has just been built: light it up ahead of him.
func on_rail_spawn(start_pd: float, end_pd: float) -> void:
	_tap_i = 0
	_comet_pd0 = maxf(start_pd, float(section.get("_player_path_dist")) + 6.0)
	_comet_pd1 = end_pd
	_comet_t = 0.0
	if _comet != null:
		_comet.visible = true


func on_catch(pos: Vector3, mult: int) -> void:
	_spawn_ring(pos, mult)
	_kick = 1.0
	if _chime != null:
		_chime.pitch_scale = lerpf(0.9, 1.75, clampf(float(mult - 1) / 7.0, 0.0, 1.0))
		_chime.play()
	if _burst != null:
		_burst.restart()
		_burst.emitting = true


func on_drop() -> void:
	_flicker = 0.55
	_jolt = 1.0
	if _sparks != null:
		_sparks.emitting = false
		_sparks_hot.emitting = false
	if _clank != null:
		_clank.pitch_scale = 0.7
		_clank.play()


func on_rail_end(perfect: bool) -> void:
	_comet_t = -1.0
	if _comet != null:
		_comet.visible = false
	if perfect and _player != null:
		_fireworks(_player.global_position + Vector3(0.0, 1.0, 0.0))
		_kick = 1.6


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(t_s: float, delta: float) -> void:
	_t += delta
	if _player == null or not is_instance_valid(_player):
		return
	var rail_on: bool = bool(section.get("_grind_rail_active"))
	var riding: bool = rail_on and bool(_player.call("is_grinding"))
	var flow: int = int(section.get("_grind_flow_mult"))
	var f: float = clampf(float(flow - 1) / 7.0, 0.0, 1.0)
	var flash: float = GameConfig.flash_scale()

	if riding and not _was_riding:
		_on_mount()
	elif _was_riding and not riding:
		_on_dismount()
	_was_riding = riding

	# The beat: every rap tap kicks the rail, caught or not.
	if rail_on:
		var taps: Array = section.get("_spark_tap_pds")
		var pd: float = float(section.get("_player_path_dist"))
		while _tap_i < taps.size() and pd >= float(taps[_tap_i]):
			_tap_i += 1
			_beat_kick = 1.0
	_beat_kick = maxf(0.0, _beat_kick - delta * 6.0)
	_kick = maxf(0.0, _kick - delta * 5.0)
	_jolt = maxf(0.0, _jolt - delta * 3.5)

	# Rail glow: brighter and faster-flowing the better the ride, a kick on the
	# beat, and a stutter when he is dropped.
	var boost: float = 1.0 + 0.2 * _beat_kick * flash
	if riding:
		boost = (1.0 + 0.035 * float(flow)) + 0.35 * _beat_kick * flash
	if _flicker > 0.0:
		_flicker = maxf(0.0, _flicker - delta)
		var n: float = fposmod(sin(floorf(_t * 30.0) * 12.9898) * 43758.5453, 1.0)
		boost = 0.08 if n < 0.55 else 0.6
	section.set("_grind_rail_boost", boost)
	var rmats: Array = section.get("_grind_rail_mats")
	for m: Material in rmats:
		if m != null:
			NeonMat.set_param(m, "flow_speed", 2.4 + (2.0 + 0.6 * float(flow) if riding else 0.0))

	_update_fx(riding, flow, f, flash)
	_update_comet(delta)
	_update_rings(delta)
	_update_camera(riding, f, delta)
	_update_letterbox(riding, delta)
	_update_sound(riding, flow, delta)


func _on_mount() -> void:
	_kick = 1.2
	if _clank != null:
		_clank.pitch_scale = 1.0
		_clank.play()
	if _burst != null:
		_burst.restart()
		_burst.emitting = true


func _on_dismount() -> void:
	if _sparks != null:
		_sparks.emitting = false
		_sparks_hot.emitting = false
		_streaks.emitting = false
		_ghosts.emitting = false


# ══════════════════════════════════════════════════════════════════════════════
#  Camera
# ══════════════════════════════════════════════════════════════════════════════

func _update_camera(riding: bool, f: float, delta: float) -> void:
	if _pivot == null or not is_instance_valid(_pivot):
		_cam = section.get("_camera") as Camera3D
		if _cam == null:
			return
		_pivot = _cam.get_parent() as Node3D
		if _pivot == null:
			return
		_rest = _pivot.transform
	# A smash owns the camera while it runs.
	var sm: Node = section.get("_smash")
	var smash_on: bool = sm != null and bool(sm.call("is_mashing"))

	var trick: int = int(section.get("_grind_trick"))
	var want_ride: float = 1.0 if riding and not smash_on else 0.0
	var want_wide: float = 0.0
	if riding and not smash_on:
		match trick:
			1, 2, 5: want_wide = 1.0     # cross-over, cross-under, loop: show the shape
			4:       want_wide = 0.45    # wander
	var a: float = minf(1.0, delta * (2.6 if riding else 2.0))
	_w_ride = lerpf(_w_ride, want_ride, a)
	_w_wide = lerpf(_w_wide, want_wide, minf(1.0, delta * 1.6))

	# Which side the track is on, from where he stands (the rail crosses over
	# on some tricks, so this is followed smoothly rather than picked once).
	var pd: float = float(section.get("_player_path_dist"))
	if riding:
		var centre: Vector3 = section.call("_path_world_pos", pd, 0.0, 0.0)
		var lx: float = _player.to_local(centre).x
		_side = lerpf(_side, clampf(lx / 3.0, -1.0, 1.0), minf(1.0, delta * 2.2))
		# Lean with the rail; on a corkscrew rock the horizon with the rider.
		var lean: float = float(section.call("_grind_branch_lean", pd)) * CAM_LEAN_SHARE
		if trick == 3:
			lean += deg_to_rad(CAM_CORK_DEG) * sin(float(section.call("_grind_branch_roll", pd)))
		_roll = lerpf(_roll, lean, minf(1.0, delta * 3.0))
	else:
		_roll = lerpf(_roll, 0.0, minf(1.0, delta * 3.0))

	# FOV: wider with the flow, wider still on big tricks, a nudge per catch.
	section.set("_grind_fov", _w_ride * (1.5 + 4.0 * f) + _w_wide * 4.0 + _kick * 1.2)

	var active: bool = _w_ride > 0.002 or _w_wide > 0.002 or absf(_roll) > 0.002 or _jolt > 0.0
	if not active:
		if _cam_on:
			_cam_on = false
			_pivot.transform = _rest
			if _cam != null:
				_cam.h_offset = 0.0
				_cam.v_offset = 0.0
		return
	if smash_on and _w_ride < 0.002 and _w_wide < 0.002:
		return
	if not _cam_on:
		_cam_on = true
		_rest = _pivot.transform
	var o: Vector3 = _rest.origin
	# Low and a little closer on the rail; pulled back and up for the big shapes.
	o.y *= lerpf(1.0, 0.8, _w_ride) * lerpf(1.0, 1.18, _w_wide)
	o.z *= lerpf(1.0, 0.9, _w_ride) * lerpf(1.0, 1.2, _w_wide)
	var tr := Transform3D(_rest.basis, o)
	var yaw: float = -_side * deg_to_rad(CAM_YAW_DEG) * _w_ride
	tr = Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO) * tr
	tr.basis = tr.basis * Basis(Vector3.BACK, _roll)
	_pivot.transform = tr
	if _cam != null:
		var sh: float = _jolt * _jolt * 0.22 * GameConfig.flash_scale()
		_cam.h_offset = randf_range(-sh, sh)
		_cam.v_offset = randf_range(-sh, sh)


# ══════════════════════════════════════════════════════════════════════════════
#  Effects
# ══════════════════════════════════════════════════════════════════════════════

func _build_fx() -> void:
	_fx = Node3D.new()
	_fx.name = "GrindFX"
	_player.add_child(_fx)
	var rail_col: Color = GameConfig.level_color_rail
	var sm := SphereMesh.new()
	sm.radius = 0.035
	sm.height = 0.07
	sm.radial_segments = 6
	sm.rings = 3
	_spark_mat = NeonMat.orb(rail_col.lerp(RAIL_COL_HOT, 0.4), 3.5)
	sm.material = _spark_mat
	# The shower off his feet, streaming back and bouncing down.
	_sparks = _emitter(sm, 70, 0.42, false)
	_sparks.direction = Vector3(0.0, 0.5, -1.0)
	_sparks.spread = 38.0
	_sparks.initial_velocity_min = 3.0
	_sparks.initial_velocity_max = 7.5
	_sparks.gravity = Vector3(0.0, -14.0, 0.0)
	_fx.add_child(_sparks)
	_sparks_hot = _emitter(sm, 30, 0.30, false)
	_sparks_hot.direction = Vector3(0.0, 0.9, -1.0)
	_sparks_hot.spread = 55.0
	_sparks_hot.initial_velocity_min = 5.0
	_sparks_hot.initial_velocity_max = 10.0
	_sparks_hot.gravity = Vector3(0.0, -12.0, 0.0)
	_fx.add_child(_sparks_hot)
	# Mounting, catching: a quick spray.
	_burst = _emitter(sm, 40, 0.35, true)
	_burst.direction = Vector3(0.0, 1.0, 0.0)
	_burst.spread = 80.0
	_burst.initial_velocity_min = 3.0
	_burst.initial_velocity_max = 8.0
	_burst.gravity = Vector3(0.0, -10.0, 0.0)
	_fx.add_child(_burst)
	# Speed lines past him from ×3.
	var lm := BoxMesh.new()
	lm.size = Vector3(0.025, 0.025, 0.5)
	var lmat: ShaderMaterial = NeonMat.tube(Color(0.85, 0.92, 1.0), 4.0)
	lmat.set_shader_parameter("box_size", lm.size)
	lm.material = lmat
	_streaks = _emitter(lm, 36, 0.4, false)
	_streaks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_streaks.emission_sphere_radius = 2.2
	_streaks.direction = Vector3(0.0, 0.0, -1.0)
	_streaks.spread = 4.0
	_streaks.initial_velocity_min = 14.0
	_streaks.initial_velocity_max = 22.0
	_streaks.gravity = Vector3.ZERO
	_streaks.position = Vector3(0.0, 1.2, 3.0)
	_fx.add_child(_streaks)
	# Afterimages at full flow.
	var gm := CapsuleMesh.new()
	gm.radius = 0.34
	gm.height = 1.3
	gm.radial_segments = 12
	gm.rings = 4
	_ghost_mat = NeonMat.ring(rail_col, 0.5)
	_ghost_mat.set_shader_parameter("alpha", 0.16)
	_ghost_mat.set_shader_parameter("band_amount", 0.0)
	gm.material = _ghost_mat
	_ghosts = _emitter(gm, 4, 0.2, false)
	_ghosts.initial_velocity_min = 0.0
	_ghosts.initial_velocity_max = 0.0
	_ghosts.gravity = Vector3.ZERO
	_ghosts.position = Vector3(0.0, 0.8, 0.0)
	_fx.add_child(_ghosts)
	# Light at the contact point, flickering with the sparks.
	_feet_light = OmniLight3D.new()
	_feet_light.light_color = rail_col
	_feet_light.light_energy = 0.0
	_feet_light.omni_range = 2.5
	_feet_light.position = Vector3(0.0, 0.25, 0.0)
	_fx.add_child(_feet_light)
	# The ignition comet.
	_comet = Node3D.new()
	_comet.visible = false
	var cm := MeshInstance3D.new()
	var cs := SphereMesh.new()
	cs.radius = 0.28
	cs.height = 0.56
	cm.mesh = cs
	cm.material_override = NeonMat.orb(RAIL_COL_HOT, 5.0)
	cm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_comet.add_child(cm)
	var cl := OmniLight3D.new()
	cl.light_color = rail_col
	cl.light_energy = 2.0
	cl.omni_range = 7.0
	_comet.add_child(cl)
	(section.get("world_fx_root") as Node3D).add_child(_comet)


func _emitter(mesh: Mesh, amount: int, life: float, one_shot: bool) -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.one_shot = one_shot
	e.explosiveness = 0.92 if one_shot else 0.0
	e.local_coords = false
	e.mesh = mesh
	e.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	e.emission_sphere_radius = 0.12
	e.particle_flag_align_y = true
	e.scale_amount_curve = _fade_curve()
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.position = Vector3(0.0, 0.08, 0.0)
	e.emitting = false
	return e


func _fade_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	return c


func _update_fx(riding: bool, flow: int, f: float, flash: float) -> void:
	if _sparks == null:
		return
	var dropped: bool = bool(section.get("_grind_failed"))
	var on: bool = riding and not dropped
	# His feet are up on the rail while he rides (BeatRunnerPlayer.GRIND_LIFT),
	# so the shower comes off the rail, not off the floor below it.
	_fx.position.y = (float(_player.get("GRIND_LIFT")) if _player.get("GRIND_LIFT") != null else 0.81) \
		if riding else 0.0
	_sparks.emitting = on
	_sparks_hot.emitting = on and flow >= 4
	_streaks.emitting = on and flow >= 3
	_ghosts.emitting = on and flow >= 8
	_sparks.speed_scale = 1.0 + 0.6 * f
	_streaks.speed_scale = 1.0 + f
	var col: Color = GameConfig.level_color_rail.lerp(RAIL_COL_HOT, 0.3 + 0.6 * f)
	NeonMat.set_tint(_spark_mat, col)
	NeonMat.set_tint(_ghost_mat, col)
	if on:
		var fl: float = randf_range(0.7, 1.15)
		_feet_light.light_energy = (0.5 + 0.7 * f + 0.4 * _beat_kick) * fl * flash
		_feet_light.light_color = col
	else:
		_feet_light.light_energy = 0.0


func _update_comet(delta: float) -> void:
	if _comet_t < 0.0 or _comet == null:
		return
	_comet_t += delta
	var k: float = clampf(_comet_t / COMET_S, 0.0, 1.0)
	var e: float = 1.0 - (1.0 - k) * (1.0 - k)
	var pd: float = lerpf(_comet_pd0, _comet_pd1, e)
	_comet.global_position = section.call("_grind_rail_point", pd)
	if k >= 1.0:
		_comet_t = -1.0
		_comet.visible = false


func _spawn_ring(pos: Vector3, mult: int) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	if _rings.is_empty():
		for k in 8:
			var tm := TorusMesh.new()
			tm.inner_radius = 0.42
			tm.outer_radius = 0.5
			tm.rings = 32
			tm.ring_segments = 6
			var m: ShaderMaterial = NeonMat.ring(GameConfig.level_color_rail, 0.0)
			var n := MeshInstance3D.new()
			n.mesh = tm
			n.material_override = m
			n.set_meta("no_cycle", true)
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = false
			world.add_child(n)
			_rings.append({"node": n, "mat": m, "t": -1.0, "s": 1.0})
	var r: Dictionary = _rings[_ring_i]
	_ring_i = (_ring_i + 1) % _rings.size()
	var node: MeshInstance3D = r["node"]
	node.visible = true
	node.global_position = pos
	# Ring stands across the rail, facing down the track.
	var pd: float = float(section.get("_player_path_dist"))
	node.global_rotation = Vector3(0.0, deg_to_rad(float(section.call("_path_y_rot_at", pd))), 0.0)
	node.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	r["t"] = 0.0
	r["s"] = 1.0 + 0.04 * float(mult)
	NeonMat.set_tint(r["mat"], GameConfig.level_color_rail.lerp(RAIL_COL_HOT,
		clampf(float(mult - 1) / 7.0, 0.0, 1.0)))


func _update_rings(delta: float) -> void:
	for r: Dictionary in _rings:
		var t: float = float(r["t"])
		if t < 0.0:
			continue
		t += delta
		r["t"] = t
		var k: float = t / 0.32
		var node: MeshInstance3D = r["node"]
		if k >= 1.0:
			r["t"] = -1.0
			node.visible = false
			continue
		var sc: float = lerpf(0.3, 1.15, 1.0 - (1.0 - k) * (1.0 - k)) * float(r["s"])
		node.scale = Vector3(sc, 1.0, sc)
		NeonMat.set_energy(r["mat"], (1.0 - k) * 2.2 * GameConfig.flash_scale() + 0.1)


## PERFECT FLOW: gold showering off the end of the rail.
func _fireworks(pos: Vector3) -> void:
	var world: Node3D = section.get("world_fx_root") as Node3D
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = NeonMat.orb(Color(1.0, 0.85, 0.25), 12.0)
	var e := _emitter(sm, 90, 1.1, true)
	e.direction = Vector3(0.0, 1.0, 0.0)
	e.spread = 75.0
	e.initial_velocity_min = 5.0
	e.initial_velocity_max = 11.0
	e.gravity = Vector3(0.0, -7.0, 0.0)
	e.emission_sphere_radius = 0.4
	world.add_child(e)
	e.global_position = pos
	e.emitting = true
	get_tree().create_timer(1.6).timeout.connect(e.queue_free)
	for k in 3:
		_spawn_ring(pos + Vector3(0.0, 0.3 * float(k), 0.0), 8)


# ══════════════════════════════════════════════════════════════════════════════
#  Letterbox
# ══════════════════════════════════════════════════════════════════════════════

func _update_letterbox(riding: bool, delta: float) -> void:
	_bar_k = move_toward(_bar_k, 1.0 if riding else 0.0, delta * 2.5)
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
			root.move_child(b, 0)   # under every HUD widget
			_bars.append(b)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var e: float = _bar_k * _bar_k * (3.0 - 2.0 * _bar_k)
	var h: float = vp.y * 0.06 * e
	_bars[0].position = Vector2(0.0, 0.0)
	_bars[0].size = Vector2(vp.x, h)
	_bars[1].position = Vector2(0.0, vp.y - h)
	_bars[1].size = Vector2(vp.x, h)
	for b: ColorRect in _bars:
		b.visible = h > 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  Sound
# ══════════════════════════════════════════════════════════════════════════════

func _update_sound(riding: bool, flow: int, delta: float) -> void:
	if _scrape == null:
		return
	var on: bool = riding and not bool(section.get("_grind_failed"))
	var want: float = (-17.0 + 0.6 * float(flow)) if on else -60.0
	_scrape.volume_db = move_toward(_scrape.volume_db, want, delta * (90.0 if on else 60.0))
	_scrape.pitch_scale = 0.85 + 0.05 * float(flow) + 0.04 * _beat_kick
	if _scrape.volume_db > -59.0 and not _scrape.playing:
		_scrape.play()
	elif _scrape.volume_db <= -59.0 and _scrape.playing:
		_scrape.stop()


func _sfx(stream: AudioStreamWAV, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	p.max_polyphony = 4
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


## Metal on metal: band-limited noise with a ringing tone under it. Looped.
func _gen_scrape() -> AudioStreamWAV:
	var n: int = int(0.8 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp: float = 0.0
	var hp_prev: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var noise: float = randf_range(-1.0, 1.0)
		lp += (noise - lp) * 0.35
		var band: float = lp - hp_prev * 0.92
		hp_prev = lp
		var ring: float = sin(TAU * 1240.0 * t) * 0.10 + sin(TAU * 1873.0 * t) * 0.06
		var wob: float = 0.8 + 0.2 * sin(TAU * 7.5 * t)
		s[i] = (band * 0.55 * wob + ring) * 0.8
	# Cross-fade the loop seam.
	var fade: int = int(0.03 * SR)
	for i in fade:
		var k: float = float(i) / float(fade)
		s[i] = s[i] * k + s[n - fade + i] * (1.0 - k)
	return _wav(s)


## A soft bell per catch.
func _gen_chime() -> AudioStreamWAV:
	var n: int = int(0.28 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = (sin(TAU * 1320.0 * t) * 0.5 + sin(TAU * 1980.0 * t) * 0.25
			+ sin(TAU * 2640.0 * t) * 0.12) * exp(-t * 14.0)
	return _wav(s)


## Landing on the rail.
func _gen_clank() -> AudioStreamWAV:
	var n: int = int(0.22 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		s[i] = (sin(TAU * 420.0 * t) * 0.5 + sin(TAU * 1130.0 * t) * 0.3) * exp(-t * 22.0) \
			+ randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.4
	return _wav(s)
