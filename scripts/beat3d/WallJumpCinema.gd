extends Node3D
class_name WallJumpCinema

## The wall-jump climb, filmed. Nothing in here changes how the climb plays:
## the ledges, the jump arcs, the timing and the scoring all stay in
## Section_BeatRunner3d / BeatRunnerPlayer. Everything is chosen so the next
## ledge stays easier to read, not harder:
##
##   crane cam   on the climb the camera rises smoothly up the staircase
##               instead of bouncing with every jump arc, slides toward the
##               middle of the corridor so BOTH walls (and the next ledges) are
##               in frame, and pulls back a little. A jump leans the horizon a
##               touch toward where he is going
##   footprints  every kick leaves a glowing print on the wall in the colour of
##               the ledge he is heading for — the rainbow climbs the walls
##               behind him
##   afterimage  a ghost of him at each take-off, so the zig-zag reads as one
##               move
##   ribbon      a rainbow ribbon follows his path up the corridor
##   target      a ring pulses on the beat on the ledge he has to land on next,
##               and bursts when he lands on it
##   updraft     motes rise past him the whole climb
##   summit      reaching the top: a burst of light, a chime, and the camera
##               cranes up to show the ramp down
##   descent     the dive: wider view, speed lines, thin letterbox, sparks off
##               his feet down the deck
##
## The section owns one: setup() once, update() every frame.

const LEDGE_COLORS: Array[Color] = [
	Color(1.00, 0.10, 0.10), Color(1.00, 0.50, 0.00), Color(1.00, 0.95, 0.00),
	Color(0.10, 0.85, 0.20), Color(0.10, 0.45, 1.00), Color(0.60, 0.10, 1.00),
	Color(1.00, 0.30, 0.80), Color(1.00, 1.00, 1.00),
]
## Share of his sideways offset the camera gives back toward the corridor centre.
const CAM_CENTRE_SHARE: float = 0.55
## How far the horizon leans toward the side he jumps to.
const CAM_JUMP_ROLL_DEG: float = 3.0
## Crane at the summit: extra height (m) and downward tilt (deg).
const SUMMIT_RISE_M: float = 1.3
const SUMMIT_TILT_DEG: float = 6.0
const LEDGE_NUDGE: float = 0.6   # mirrors ledge_wall_nudge in the section

var section: Node = null
var _player: CharacterBody3D = null
var _world: Node3D = null

# camera
var _cam: Camera3D = null
var _pivot: Node3D = null
var _rest: Transform3D = Transform3D.IDENTITY
var _cam_on: bool = false
var _w_climb: float = 0.0
var _w_summit: float = 0.0
var _w_dive: float = 0.0
var _roll: float = 0.0
var _roll_v: float = 0.0
var _kick: float = 0.0
var _base_y: float = NAN

# state
var _t: float = 0.0
var _step: int = 0
var _summit_done: bool = false
var _was_on_floor: bool = true
var _target_k: int = -1

# fx
var _fx: Node3D = null
var _motes: CPUParticles3D = null
var _mote_mat: ShaderMaterial = null
var _bursts: Array[CPUParticles3D] = []
var _burst_mats: Array[ShaderMaterial] = []
var _burst_i: int = 0
var _sparks: CPUParticles3D = null
var _streaks: CPUParticles3D = null
var _prints: Array[Dictionary] = []     # {node, mat, t}
var _print_i: int = 0
var _ghosts: Array[Dictionary] = []     # {node, mat, t}
var _ghost_i: int = 0
var _rings: Array[Dictionary] = []      # {node, mat, t, s}
var _ring_i: int = 0
var _target: MeshInstance3D = null
var _target_mat: ShaderMaterial = null
var _ribbon: ImmediateMesh = null
var _ribbon_pts: Array[Dictionary] = []

# letterbox
var _bars: Array[ColorRect] = []
var _bar_k: float = 0.0

# sound
var _whoosh: AudioStreamPlayer = null
var _chime: AudioStreamPlayer = null
const SR: int = 22050


func _init() -> void:
	name = "WallJumpCinema"


func setup(p_section: Node) -> void:
	section = p_section
	_player = section.get("player") as CharacterBody3D
	_world = section.get("world_fx_root") as Node3D
	_build_fx()
	if _player.has_signal("wall_jumped"):
		_player.connect("wall_jumped", _on_wall_jump)
	_whoosh = _sfx(_gen_whoosh(), -15.0)
	_chime = _sfx(_gen_chime(), -14.0)


func _slots() -> Array:
	return section.get("_wj_slot_zs") as Array


# ══════════════════════════════════════════════════════════════════════════════
#  Events
# ══════════════════════════════════════════════════════════════════════════════

func _on_wall_jump(action: String) -> void:
	if _slots().is_empty() or _w_climb < 0.05:
		return
	_step += 1
	var col: Color = _ledge_col(_step)
	var fs: float = GameConfig.flash_scale()
	var pd: float = float(section.get("_player_path_dist"))
	var right: Vector3 = _player.get("right_dir")
	var centre: Vector3 = section.call("_path_world_pos", pd, 0.0, 0.0)
	var lat: float = (_player.global_position - centre).dot(right)
	var side: float = signf(lat) if absf(lat) > 0.3 else (-1.0 if action == "wall_left" else 1.0)
	var half: float = float(section.call("_track_full_width")) * 0.5
	# The print goes on the wall he pushed off.
	var wall_p: Vector3 = section.call("_path_world_pos", pd, side * (half - 0.02), 0.0)
	wall_p.y = _player.global_position.y + 0.9
	_spawn_print(wall_p, right * -side, col)
	_spawn_ghost(_player.global_position, _player.global_rotation.y, col)
	_burst(_player.global_position + Vector3(0.0, 0.3, 0.0) + right * side * 0.5, col, Vector3(-side, 0.6, 0.0))
	# Lean toward where he is heading.
	_roll_v += -side * deg_to_rad(CAM_JUMP_ROLL_DEG) * 6.0 * fs
	_kick = 1.0
	GameConfig.rumble(0.4, 0.2, 0.08)
	if _whoosh != null:
		_whoosh.pitch_scale = 0.85 + 0.07 * float(mini(_step, 8))
		_whoosh.play()


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(_t_s: float, delta: float) -> void:
	_t += delta
	if _player == null or not is_instance_valid(_player):
		return
	var slots: Array = _slots()
	if slots.is_empty():
		return
	var pd: float = float(section.get("_player_path_dist"))
	var z0: float = float(section.get("_wj_zone_start_z"))
	var top: float = float(section.get("_wj_climb_top_z"))
	var rs: float = float(section.get("_wj_slide_start_z"))
	var re: float = float(section.get("_wj_slide_end_z"))
	var in_climb: bool = pd >= z0 and pd < rs
	var in_summit: bool = pd >= top and pd < rs
	var in_dive: bool = pd >= rs and pd < re + 3.0
	if in_climb and _w_climb < 0.01 and not in_summit:
		_step = 0
		_summit_done = false
		_base_y = _player.global_position.y
	var on_floor: bool = _player.is_on_floor()

	_w_climb = move_toward(_w_climb, 1.0 if in_climb else 0.0, delta * 1.8)
	_w_summit = move_toward(_w_summit, 1.0 if in_summit else 0.0, delta * (2.2 if in_summit else 1.4))
	_w_dive = move_toward(_w_dive, 1.0 if in_dive else 0.0, delta * 2.0)
	_kick = maxf(0.0, _kick - delta * 4.0)

	# Summit: first time he stands on the top floor.
	if in_summit and on_floor and not _summit_done:
		_summit_done = true
		_on_summit()

	# Target ledge: the next one ahead of him that he has not reached.
	# A ledge stops being the target once he is over its front edge.
	var k_next: int = -1
	var half: float = float(section.get("_wj_ledge_half_z"))
	if in_climb and pd < top:
		for k in range(1, slots.size()):
			if float(slots[k]) - half * 0.8 > pd:
				k_next = k
				break
	# Landed on the one we were pointing at: burst it.
	if on_floor and not _was_on_floor and _target_k > 0 and pd >= float(slots[_target_k]) - 7.0:
		_spawn_ring(_ledge_pos(_target_k) + Vector3(0.0, 0.05, 0.0), _ledge_col(_target_k), 1.6, true)
		_burst(_player.global_position + Vector3(0.0, 0.15, 0.0), _ledge_col(_target_k), Vector3.UP)
	_was_on_floor = on_floor
	_target_k = k_next
	_update_target(delta)

	_update_motes(in_climb and pd < top)
	_update_dive_fx(in_dive, on_floor)
	_update_ribbon(in_climb and pd < top + 4.0)
	_update_pools(delta)
	_update_camera(pd, rs, delta)
	_update_letterbox(delta)


func _on_summit() -> void:
	GameConfig.rumble(0.5, 0.5, 0.25)
	var p: Vector3 = _player.global_position + Vector3(0.0, 0.6, 0.0)
	_spawn_ring(p, Color(1.0, 1.0, 1.0), 4.0, true)
	_spawn_ring(p + Vector3(0.0, 0.3, 0.0), LEDGE_COLORS[2], 3.0, true)
	_spawn_ring(p + Vector3(0.0, 0.6, 0.0), LEDGE_COLORS[5], 2.2, true)
	_burst(p, Color(1.0, 0.95, 0.85), Vector3.UP)
	_burst(p, LEDGE_COLORS[4], Vector3.UP)
	if _chime != null:
		_chime.play()


# ══════════════════════════════════════════════════════════════════════════════
#  Camera
# ══════════════════════════════════════════════════════════════════════════════

func _update_camera(pd: float, rs: float, delta: float) -> void:
	if _pivot == null or not is_instance_valid(_pivot):
		_cam = section.get("_camera") as Camera3D
		if _cam == null:
			return
		_pivot = _cam.get_parent() as Node3D
		if _pivot == null:
			return
	var fs: float = GameConfig.flash_scale()
	# Jump lean: a spring, so it swings in and settles rather than snapping.
	_roll_v += (-_roll * 40.0 - _roll_v * 9.0) * delta
	_roll += _roll_v * delta
	section.set("_wj_fov", _w_climb * 5.0 * (1.0 - _w_dive) + _w_summit * 2.0 + _w_dive * 6.0 + _kick * 0.8 * fs)

	var active: bool = _w_climb > 0.002 or _w_dive > 0.002 or absf(_roll) > 0.002
	# Never fight the rail cam or a smash for the pivot.
	var sm: Node = section.get("_smash")
	if bool(_player.call("is_grinding")) or (sm != null and bool(sm.call("is_mashing"))):
		active = false
	if not active:
		if _cam_on:
			_cam_on = false
			_pivot.transform = _rest
		return
	if not _cam_on:
		_cam_on = true
		_rest = _pivot.transform

	var o: Vector3 = _rest.origin
	var py: float = _player.global_position.y
	# Back toward the corridor centre so both walls stay in shot.
	var centre: Vector3 = section.call("_path_world_pos", pd, 0.0, 0.0)
	var cx: float = _player.to_local(Vector3(centre.x, _player.global_position.y, centre.z)).x
	o.x += cx * CAM_CENTRE_SHARE * _w_climb
	# Crane: follow the staircase line, not each jump arc.
	if pd < rs and not is_nan(_base_y):
		var want_y: float = lerpf(py, _base_y + _stair_h(pd + 2.5), 0.75)
		o.y += clampf(want_y - py, -2.5, 2.5) * _w_climb
	o.y += 0.35 * _w_climb + SUMMIT_RISE_M * _summit_ease()
	o.z *= lerpf(1.0, 1.12, _w_climb) * lerpf(1.0, 1.12, _summit_ease())
	# Dive: a touch lower and closer down the ramp.
	o.y -= 0.45 * _w_dive
	o.z *= lerpf(1.0, 0.93, _w_dive)
	var tr := Transform3D(_rest.basis, o)
	tr.basis = tr.basis * Basis(Vector3.RIGHT, -deg_to_rad(SUMMIT_TILT_DEG) * _summit_ease())
	tr.basis = tr.basis * Basis(Vector3.BACK, _roll)
	_pivot.transform = tr


func _summit_ease() -> float:
	var k: float = _w_summit
	return k * k * (3.0 - 2.0 * k)


## The staircase as one smooth line: ledge height interpolated along the path.
func _stair_h(pd: float) -> float:
	var slots: Array = _slots()
	var hs: Array = section.get("_wj_slot_heights")
	if slots.is_empty() or hs.size() != slots.size():
		return 0.0
	if pd <= float(slots[0]):
		return 0.0
	for k in range(1, slots.size()):
		if pd < float(slots[k]):
			var a: float = float(slots[k - 1])
			var b: float = float(slots[k])
			return lerpf(float(hs[k - 1]), float(hs[k]), (pd - a) / maxf(0.01, b - a))
	return float(hs[hs.size() - 1])


# ══════════════════════════════════════════════════════════════════════════════
#  Ledges
# ══════════════════════════════════════════════════════════════════════════════

func _ledge_col(k: int) -> Color:
	return LEDGE_COLORS[clampi(k, 0, LEDGE_COLORS.size() - 1)]


## World position of the top-centre of ledge k (same placement as the section).
func _ledge_pos(k: int) -> Vector3:
	var slots: Array = _slots()
	var acts: Array = section.get("_wj_slot_acts")
	var hs: Array = section.get("_wj_slot_heights")
	var lanes: PackedFloat32Array = _player.get("lane_xs")
	var maxl: int = lanes.size() - 1
	var li: int
	if k == 0:
		li = 0 if String(acts[0]) == "wall_left" else maxl
	else:
		li = maxl if String(acts[k - 1]) == "wall_left" else 0
	var lx: float = lanes[li] + LEDGE_NUDGE * (1.0 if li == maxl else -1.0)
	return section.call("_path_world_pos", float(slots[k]), lx, float(hs[k]))


func _update_target(delta: float) -> void:
	if _target == null:
		return
	if _target_k <= 0:
		_target.visible = false
		return
	var col: Color = _ledge_col(_target_k)
	var fs: float = GameConfig.flash_scale()
	_target.visible = true
	var slots: Array = _slots()
	_target.global_position = _ledge_pos(_target_k) + Vector3(0.0, 0.16, 0.0)
	_target.global_rotation = Vector3(0.0, deg_to_rad(float(section.call("_path_y_rot_at", float(slots[_target_k])))), 0.0)
	var beat: float = float(section.get("_beat_phase"))
	var sc: float = 1.0 + 0.18 * beat * fs
	_target.scale = Vector3(sc, 1.0, sc)
	NeonMat.set_tint(_target_mat, col.lerp(Color(1, 1, 1), 0.25))
	NeonMat.set_energy(_target_mat, (1.4 + 1.6 * beat * fs) * _w_climb)


# ══════════════════════════════════════════════════════════════════════════════
#  Effects
# ══════════════════════════════════════════════════════════════════════════════

func _build_fx() -> void:
	_fx = Node3D.new()
	_fx.name = "WallJumpFX"
	_player.add_child(_fx)
	var sm := SphereMesh.new()
	sm.radius = 0.04
	sm.height = 0.08
	sm.radial_segments = 6
	sm.rings = 3
	# Updraft: motes rising past him up the corridor.
	_mote_mat = NeonMat.orb(Color(1, 1, 1), 2.5)
	var mm := SphereMesh.new()
	mm.radius = 0.03
	mm.height = 0.06
	mm.radial_segments = 6
	mm.rings = 3
	mm.material = _mote_mat
	_motes = _emitter(mm, 48, 1.1, false)
	_motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_motes.emission_box_extents = Vector3(3.2, 0.5, 5.0)
	_motes.position = Vector3(0.0, -1.5, 4.0)
	_motes.direction = Vector3(0.0, 1.0, 0.0)
	_motes.spread = 8.0
	_motes.initial_velocity_min = 5.0
	_motes.initial_velocity_max = 9.0
	_motes.gravity = Vector3.ZERO
	_fx.add_child(_motes)
	# Kick / landing bursts — a small pool so they can overlap.
	for k in 4:
		var bm := SphereMesh.new()
		bm.radius = 0.045
		bm.height = 0.09
		bm.radial_segments = 6
		bm.rings = 3
		var mat: ShaderMaterial = NeonMat.orb(Color(1, 1, 1), 4.0)
		bm.material = mat
		var b := _emitter(bm, 26, 0.45, true)
		b.spread = 55.0
		b.initial_velocity_min = 2.5
		b.initial_velocity_max = 6.0
		b.gravity = Vector3(0.0, -9.0, 0.0)
		_world.add_child(b)
		_bursts.append(b)
		_burst_mats.append(mat)
	# Sparks off his feet down the ramp.
	var spm := SphereMesh.new()
	spm.radius = 0.035
	spm.height = 0.07
	spm.radial_segments = 6
	spm.rings = 3
	spm.material = NeonMat.orb(Color(0.45, 0.95, 1.0), 3.5)
	_sparks = _emitter(spm, 50, 0.38, false)
	_sparks.direction = Vector3(0.0, 0.5, -1.0)
	_sparks.spread = 35.0
	_sparks.initial_velocity_min = 3.0
	_sparks.initial_velocity_max = 7.0
	_sparks.gravity = Vector3(0.0, -14.0, 0.0)
	_sparks.position = Vector3(0.0, 0.08, 0.0)
	_fx.add_child(_sparks)
	# Speed lines down the ramp.
	var lm := BoxMesh.new()
	lm.size = Vector3(0.025, 0.025, 0.55)
	var lmat: ShaderMaterial = NeonMat.tube(Color(0.85, 0.95, 1.0), 4.0)
	lmat.set_shader_parameter("box_size", lm.size)
	lm.material = lmat
	_streaks = _emitter(lm, 34, 0.4, false)
	_streaks.emission_sphere_radius = 2.4
	_streaks.direction = Vector3(0.0, 0.0, -1.0)
	_streaks.spread = 4.0
	_streaks.initial_velocity_min = 14.0
	_streaks.initial_velocity_max = 22.0
	_streaks.gravity = Vector3.ZERO
	_streaks.position = Vector3(0.0, 1.2, 3.0)
	_fx.add_child(_streaks)
	# Target ring on the next ledge.
	var tm := TorusMesh.new()
	tm.inner_radius = 0.82
	tm.outer_radius = 0.92
	tm.rings = 40
	tm.ring_segments = 6
	_target_mat = NeonMat.ring(Color(1, 1, 1), 0.0)
	_target = MeshInstance3D.new()
	_target.mesh = tm
	_target.material_override = _target_mat
	_target.set_meta("no_cycle", true)
	_target.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_target.visible = false
	_world.add_child(_target)
	# Ribbon.
	_ribbon = ImmediateMesh.new()
	var rmi := MeshInstance3D.new()
	rmi.mesh = _ribbon
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	rmi.material_override = m
	rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rmi.top_level = true
	_world.add_child(rmi)


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


func _burst(pos: Vector3, col: Color, dir: Vector3) -> void:
	var b: CPUParticles3D = _bursts[_burst_i]
	var mat: ShaderMaterial = _burst_mats[_burst_i]
	_burst_i = (_burst_i + 1) % _bursts.size()
	NeonMat.set_tint(mat, col.lerp(Color(1, 1, 1), 0.2))
	NeonMat.set_energy(mat, 4.0 * maxf(GameConfig.flash_scale(), 0.4))
	b.global_position = pos
	b.direction = dir.normalized() if dir != Vector3.ZERO else Vector3.UP
	b.restart()
	b.emitting = true


func _update_motes(on: bool) -> void:
	if _motes == null:
		return
	_motes.emitting = on
	if on:
		NeonMat.set_tint(_mote_mat, _ledge_col(maxi(_target_k, _step)).lerp(Color(1, 1, 1), 0.35))


func _update_dive_fx(in_dive: bool, on_floor: bool) -> void:
	if _sparks == null:
		return
	_sparks.emitting = in_dive and on_floor
	_streaks.emitting = in_dive


## A glowing print on the wall, facing into the corridor. Fades over a second
## and a half — long enough that the prints stack up the walls behind him.
func _spawn_print(pos: Vector3, normal: Vector3, col: Color) -> void:
	if _prints.is_empty():
		for k in 10:
			var q := QuadMesh.new()
			q.size = Vector2(0.75, 1.1)
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			m.albedo_texture = _print_tex()
			var n := MeshInstance3D.new()
			n.mesh = q
			n.material_override = m
			n.set_meta("no_cycle", true)
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = false
			_world.add_child(n)
			_prints.append({"node": n, "mat": m, "t": -1.0})
	var p: Dictionary = _prints[_print_i]
	_print_i = (_print_i + 1) % _prints.size()
	var node: MeshInstance3D = p["node"]
	node.visible = true
	node.global_position = pos
	var z: Vector3 = normal.normalized()
	var x: Vector3 = Vector3.UP.cross(z).normalized()
	node.global_basis = Basis(x, Vector3.UP, z)
	p["t"] = 0.0
	p["col"] = col


func _spawn_ghost(pos: Vector3, yaw: float, col: Color) -> void:
	if _ghosts.is_empty():
		var gm := CapsuleMesh.new()
		gm.radius = 0.34
		gm.height = 1.3
		gm.radial_segments = 12
		gm.rings = 4
		for k in 8:
			var m: ShaderMaterial = NeonMat.ring(Color(1, 1, 1), 0.6)
			m.set_shader_parameter("band_amount", 0.0)
			var n := MeshInstance3D.new()
			n.mesh = gm
			n.material_override = m
			n.set_meta("no_cycle", true)
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = false
			_world.add_child(n)
			_ghosts.append({"node": n, "mat": m, "t": -1.0})
	var g: Dictionary = _ghosts[_ghost_i]
	_ghost_i = (_ghost_i + 1) % _ghosts.size()
	var node: MeshInstance3D = g["node"]
	node.visible = true
	node.global_position = pos + Vector3(0.0, 0.8, 0.0)
	node.global_rotation = Vector3(0.0, yaw, 0.0)
	NeonMat.set_tint(g["mat"], col)
	g["t"] = 0.0


func _spawn_ring(pos: Vector3, col: Color, size: float, flat: bool) -> void:
	if _rings.is_empty():
		var tm := TorusMesh.new()
		tm.inner_radius = 0.44
		tm.outer_radius = 0.5
		tm.rings = 40
		tm.ring_segments = 6
		for k in 8:
			var m: ShaderMaterial = NeonMat.ring(Color(1, 1, 1), 0.0)
			var n := MeshInstance3D.new()
			n.mesh = tm
			n.material_override = m
			n.set_meta("no_cycle", true)
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = false
			_world.add_child(n)
			_rings.append({"node": n, "mat": m, "t": -1.0, "s": 1.0})
	var r: Dictionary = _rings[_ring_i]
	_ring_i = (_ring_i + 1) % _rings.size()
	var node: MeshInstance3D = r["node"]
	node.visible = true
	node.global_position = pos
	node.global_rotation = Vector3.ZERO
	if not flat:
		node.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	NeonMat.set_tint(r["mat"], col)
	r["t"] = 0.0
	r["s"] = size


func _update_pools(delta: float) -> void:
	var fs: float = GameConfig.flash_scale()
	for p: Dictionary in _prints:
		var t: float = float(p["t"])
		if t < 0.0:
			continue
		t += delta
		p["t"] = t
		var node: MeshInstance3D = p["node"]
		if t >= 1.6:
			p["t"] = -1.0
			node.visible = false
			continue
		var c: Color = p["col"]
		# Hot white on contact, settling into the ledge colour, then fading.
		var hot: float = clampf(1.0 - t / 0.15, 0.0, 1.0)
		var a: float = clampf(1.0 - (t - 0.4) / 1.2, 0.0, 1.0)
		var col: Color = c.lerp(Color(1, 1, 1), hot * 0.6)
		col.a = a * lerpf(0.75, 1.0, hot) * maxf(fs, 0.5)
		(p["mat"] as StandardMaterial3D).albedo_color = col
		var sc: float = 1.0 + 0.25 * hot
		node.scale = Vector3(sc, sc, sc)
	for g: Dictionary in _ghosts:
		var t: float = float(g["t"])
		if t < 0.0:
			continue
		t += delta
		g["t"] = t
		var node: MeshInstance3D = g["node"]
		if t >= 0.5:
			g["t"] = -1.0
			node.visible = false
			continue
		var k: float = t / 0.5
		(g["mat"] as ShaderMaterial).set_shader_parameter("alpha", 0.22 * (1.0 - k))
		node.scale = Vector3.ONE * (1.0 + 0.15 * k)
	for r: Dictionary in _rings:
		var t: float = float(r["t"])
		if t < 0.0:
			continue
		t += delta
		r["t"] = t
		var node: MeshInstance3D = r["node"]
		var k: float = t / 0.45
		if k >= 1.0:
			r["t"] = -1.0
			node.visible = false
			continue
		var sc: float = lerpf(0.4, 1.0, 1.0 - (1.0 - k) * (1.0 - k)) * float(r["s"])
		node.scale = Vector3(sc, 1.0, sc)
		NeonMat.set_energy(r["mat"], (1.0 - k) * 2.6 * fs + 0.1)


func _update_ribbon(on: bool) -> void:
	if _ribbon == null:
		return
	if on:
		_ribbon_pts.push_front({"p": _player.global_position + Vector3(0.0, 0.8, 0.0), "t": _t,
			"c": _ledge_col(maxi(_target_k, _step))})
	while _ribbon_pts.size() > 0 and _t - float(_ribbon_pts.back()["t"]) > 0.7:
		_ribbon_pts.pop_back()
	_ribbon.clear_surfaces()
	if _ribbon_pts.size() < 2 or _cam == null:
		return
	var cam_p: Vector3 = _cam.global_position
	var fs: float = maxf(GameConfig.flash_scale(), 0.5)
	_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var n: int = _ribbon_pts.size()
	for k in n:
		var p: Vector3 = _ribbon_pts[k]["p"]
		var q: Vector3 = _ribbon_pts[mini(k + 1, n - 1)]["p"] if k < n - 1 else _ribbon_pts[k - 1]["p"]
		var tan: Vector3 = (q - p) if k < n - 1 else (p - q)
		var side: Vector3 = tan.cross(cam_p - p)
		side = side.normalized() if side.length() > 0.0001 else Vector3.UP
		var age: float = (_t - float(_ribbon_pts[k]["t"])) / 0.7
		var w: float = lerpf(0.10, 0.015, age)
		var col: Color = _ribbon_pts[k]["c"]
		col.a = (1.0 - age) * 0.42 * fs
		_ribbon.surface_set_color(col)
		_ribbon.surface_add_vertex(p - side * w)
		_ribbon.surface_set_color(col)
		_ribbon.surface_add_vertex(p + side * w)
	_ribbon.surface_end()


## Soft round footprint glow, made once.
var _ptex: ImageTexture = null
func _print_tex() -> ImageTexture:
	if _ptex != null:
		return _ptex
	var w: int = 32
	var h: int = 48
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var u: float = (float(x) + 0.5) / float(w) * 2.0 - 1.0
			var v: float = (float(y) + 0.5) / float(h) * 2.0 - 1.0
			# A sole: an oval with a brighter rim.
			var d: float = sqrt(u * u + v * v * 0.9)
			var body: float = clampf(1.0 - d, 0.0, 1.0)
			var rim: float = clampf(1.0 - absf(d - 0.78) / 0.12, 0.0, 1.0)
			var a: float = clampf(body * 0.55 + rim * 0.9, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_ptex = ImageTexture.create_from_image(img)
	return _ptex


# ══════════════════════════════════════════════════════════════════════════════
#  Letterbox (the dive only — the climb needs every pixel of height)
# ══════════════════════════════════════════════════════════════════════════════

func _update_letterbox(delta: float) -> void:
	_bar_k = move_toward(_bar_k, _w_dive if _w_dive > 0.5 else 0.0, delta * 2.5)
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
	var e: float = _bar_k * _bar_k * (3.0 - 2.0 * _bar_k)
	var h: float = vp.y * 0.055 * e
	_bars[0].position = Vector2.ZERO
	_bars[0].size = Vector2(vp.x, h)
	_bars[1].position = Vector2(0.0, vp.y - h)
	_bars[1].size = Vector2(vp.x, h)
	for b: ColorRect in _bars:
		b.visible = h > 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  Sound
# ══════════════════════════════════════════════════════════════════════════════

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


## Air past him on a kick: noise through a band that sweeps upward.
func _gen_whoosh() -> AudioStreamWAV:
	var n: int = int(0.26 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp: float = 0.0
	var lp2: float = 0.0
	for i in n:
		var t: float = float(i) / float(n)
		var a: float = lerpf(0.05, 0.45, t)
		lp += (randf_range(-1.0, 1.0) - lp) * a
		lp2 += (lp - lp2) * a * 0.8
		var env: float = sin(PI * pow(t, 0.6))
		s[i] = (lp - lp2) * 1.6 * env
	return _wav(s)


## The top: a bright open chord.
func _gen_chime() -> AudioStreamWAV:
	var n: int = int(0.9 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		var v: float = 0.0
		for f: float in [880.0, 1108.7, 1318.5, 1760.0]:
			v += sin(TAU * f * t) * 0.18
		s[i] = v * exp(-t * 4.5) * minf(1.0, t * 200.0)
	return _wav(s)
