extends Node3D
class_name RunnerFlair

## The ordinary running, dressed up. Grinds are filmed for flow and smash
## gates for impact; running is about rhythm and momentum, so this file makes
## the world play the song and lets Meeko's run build up visibly as the combo
## climbs. Nothing here touches the camera, the gates' timing, judging or
## scoring — every piece is cosmetic.
##
##   gates       turn green on a pass (the section does that) and break into
##               neon shards on a miss; breathe on every beat
##               as they come in and flash once a beat before they arrive;
##               a pattern's gates are linked by light ribbons on the floor;
##               a near miss throws a spray of sparks off the gate he scraped
##   Meeko       a combo trail (faint at ×2, brighter at ×10, rainbow at ×20);
##               a puff of air on take-off, a ring on landing, sparks on a roll
##   the city    windows and lasers come up with the combo; fireworks over the
##               skyline on streak milestones
##   the sky     a pulsing moon-hologram on the horizon, aurora rings in calm
##               stretches, shooting stars as phrases begin
##   trackside   light trains, drone swarms, sweeping searchlights, and neon
##               billboards that flash the key word of each lyric line
##   a miss      a short glitch over the screen: colour drains, bands tear
##
## Electric zones are dark on purpose — everything up in the world here fades
## out with the blackout. The section owns one: setup() once, update() every
## frame, and on_gate / on_near_miss / on_milestone at those moments.

const GATE_KINDS: PackedStringArray = ["left", "right", "jump", "slide"]
const SHARD_POOL: int = 48
const SHARDS_PER_HIT: int = 9
const RIBBON_AHEAD_M: float = 170.0

var section: Node = null
var player: Node3D = null
var world: Node3D = null
var beat_s: float = 0.5
var _t: float = 0.0
var _flash: float = 1.0
var _lit: float = 1.0        # 1 outside electric zones, fading to 0 in them

# gates
var _shards: Array[Dictionary] = []
var _shard_i: int = 0
var _spark_pool: Array[CPUParticles3D] = []
var _spark_i: int = 0
var _locked: Dictionary = {}       # gate index -> true once its one-beat flash fired
var _breathed: Dictionary = {}     # gate index -> true while scaled

# pattern ribbons
var _rib_next: int = 0
var _ribbons: Array[Dictionary] = []   # {node, end_pd}
var _rib_mats: Dictionary = {}         # colour key -> material

# trail
var _trail_mi: MeshInstance3D = null
var _trail_mesh: ImmediateMesh = null
var _trail_pts: Array[Dictionary] = []   # {p, t}
var _trail_k: float = 0.0

# jump / slide
var _was_air: bool = false
var _puff: CPUParticles3D = null
var _slide_sparks: CPUParticles3D = null
var _land_rings: Array[Dictionary] = []
var _land_i: int = 0

# city heat
var _heat: float = 0.0

# sky
var _moon: Node3D = null
var _moon_mat: ShaderMaterial = null
var _moon_ring: MeshInstance3D = null
var _moon_ring_mat: ShaderMaterial = null
var _moon_dir: Vector3 = Vector3.ZERO
var _aurora: Array[Dictionary] = []
var _calm: float = 0.0
var _stars: Array[Dictionary] = []
var _star_i: int = 0
var _last_phrase: int = -999
var _phrase_scan: int = 0

# trackside
var _trains: Array[Dictionary] = []
var _train_cd: float = 6.0
var _drones: Array[Dictionary] = []
var _drone_cd: float = 3.0
var _beams: Array[Dictionary] = []
var _boards: Array[Dictionary] = []
var _lyric_i: int = 0
var _last_board_t: float = -99.0
var _board_side: float = 1.0

# glitch
var _glitch: ColorRect = null
var _glitch_mat: ShaderMaterial = null
var _glitch_t: float = 0.0
const GLITCH_S: float = 0.32


func _init() -> void:
	name = "RunnerFlair"


func setup(p_section: Node) -> void:
	section = p_section
	player = section.get("player") as Node3D
	world = section.get("world_fx_root") as Node3D
	beat_s = maxf(float(section.get("_runner_avg_beat_s")), 0.2)
	_build_gate_fx()
	_build_trail()
	_build_jump_fx()
	_build_sky()
	_build_beams()


# ══════════════════════════════════════════════════════════════════════════════
#  Events
# ══════════════════════════════════════════════════════════════════════════════

func on_gate(idx: int, success: bool, col: Color) -> void:
	var nodes: Array = section.get("gate_nodes")
	var acts: Array = section.get("gate_actions")
	if idx < 0 or idx >= nodes.size():
		return
	var gate: Node3D = nodes[idx]
	var action: String = String(acts[idx]) if idx < acts.size() else ""
	if gate != null and is_instance_valid(gate):
		gate.scale = Vector3.ONE
	# A pass leaves the gate standing (the section already turns it green). A
	# miss breaks it — he went straight through it — with the screen glitch.
	if success:
		return
	if not bool(section.call("_is_electric_at", float(section.call("_song_time")))):
		_start_glitch()
	if action in GATE_KINDS and gate != null and is_instance_valid(gate):
		_shatter(gate, col)
		var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
		if vis != null:
			vis.visible = false


func on_near_miss(idx: int) -> void:
	var nodes: Array = section.get("gate_nodes")
	if idx < 0 or idx >= nodes.size() or nodes[idx] == null:
		return
	var gate: Node3D = nodes[idx]
	# Between the gate and him, at shoulder height: where he scraped it.
	var p: Vector3 = gate.global_position.lerp(player.global_position, 0.5) + Vector3(0.0, 1.2, 0.0)
	var e: CPUParticles3D = _spark_pool[_spark_i]
	_spark_i = (_spark_i + 1) % _spark_pool.size()
	e.global_position = p
	e.restart()
	e.emitting = true


func on_milestone(combo: int) -> void:
	if _lit < 0.5:
		return
	var n: int = 1
	if combo >= 200: n = 5
	elif combo >= 100: n = 4
	elif combo >= 50: n = 3
	elif combo >= 25: n = 2
	for k in n:
		get_tree().create_timer(0.16 * float(k)).timeout.connect(_firework)


# ══════════════════════════════════════════════════════════════════════════════
#  Per frame
# ══════════════════════════════════════════════════════════════════════════════

func update(t_s: float, delta: float) -> void:
	_t += delta
	if player == null or not is_instance_valid(player):
		return
	_flash = GameConfig.flash_scale()
	_lit = 1.0 - float(section.get("_elec_dark"))
	var pd: float = float(section.get("_player_path_dist"))
	var beat: float = float(section.get("_beat_phase"))
	var combo: int = int(section.get("_combo"))
	var mult: int = mini(combo / 10 + 1, 20)

	_update_gates(t_s, pd, beat)
	_update_shards(delta)
	_update_ribbons(pd)
	_update_trail(delta, mult)
	_update_jump_fx(delta)
	_update_heat(delta, mult)
	_update_sky(t_s, delta, pd, beat)
	_update_trackside(t_s, delta, pd, beat)
	_update_glitch(delta)


# ══════════════════════════════════════════════════════════════════════════════
#  Gates
# ══════════════════════════════════════════════════════════════════════════════

func _build_gate_fx() -> void:
	var pieces_mesh := BoxMesh.new()
	pieces_mesh.size = Vector3(1, 1, 1)
	for k in SHARD_POOL:
		var mi := MeshInstance3D.new()
		mi.mesh = pieces_mesh
		var m: ShaderMaterial = NeonMat.tube(Color.WHITE, 0.0)
		mi.material_override = m
		mi.set_meta("no_cycle", true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		world.add_child(mi)
		_shards.append({"node": mi, "mat": m, "vel": Vector3.ZERO, "spin": Vector3.ZERO,
			"life": 0.0, "size": Vector3.ONE})
	var sm := SphereMesh.new()
	sm.radius = 0.04
	sm.height = 0.08
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = NeonMat.orb(Color(1.0, 0.6, 0.2), 6.0)
	for k in 3:
		var e := _emitter(sm, 26, 0.35, true)
		e.direction = Vector3(0, 0.6, -1)
		e.spread = 70.0
		e.initial_velocity_min = 3.0
		e.initial_velocity_max = 8.0
		e.gravity = Vector3(0, -12, 0)
		world.add_child(e)
		_spark_pool.append(e)


func _shatter(gate: Node3D, col: Color) -> void:
	var fwd: Vector3 = section.call("_path_forward_at", float(section.get("_player_path_dist")))
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var base: Vector3 = gate.global_position
	for k in SHARDS_PER_HIT:
		var s: Dictionary = _shards[_shard_i]
		_shard_i = (_shard_i + 1) % _shards.size()
		var node: MeshInstance3D = s["node"]
		var size := Vector3(randf_range(0.06, 0.12), randf_range(0.25, 0.6), 0.06)
		s["size"] = size
		node.scale = size
		node.visible = true
		node.global_position = base + right * randf_range(-1.1, 1.1) + Vector3(0.0, randf_range(0.4, 2.4), 0.0)
		node.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		var m: ShaderMaterial = s["mat"]
		m.set_shader_parameter("box_size", size)
		NeonMat.set_tint(m, col.lightened(randf_range(0.0, 0.35)))
		NeonMat.set_energy(m, 6.0 * _flash + 1.5)
		# Slower than he runs, so they fly back past him on both sides.
		s["vel"] = right * randf_range(-6.0, 6.0) + Vector3(0.0, randf_range(1.0, 4.5), 0.0) \
			+ fwd * randf_range(3.0, 11.0)
		s["spin"] = Vector3(randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12))
		s["life"] = 0.65


func _update_shards(delta: float) -> void:
	for s: Dictionary in _shards:
		var life: float = float(s["life"])
		if life <= 0.0:
			continue
		life -= delta
		s["life"] = life
		var node: MeshInstance3D = s["node"]
		if life <= 0.0:
			node.visible = false
			continue
		var v: Vector3 = s["vel"]
		v.y -= 11.0 * delta
		s["vel"] = v
		node.global_position += v * delta
		node.rotation += (s["spin"] as Vector3) * delta
		node.scale = (s["size"] as Vector3) * clampf(life / 0.25, 0.0, 1.0)


## Breathing on the beat, and the one-beat-out flash.
func _update_gates(t_s: float, pd: float, beat: float) -> void:
	var nodes: Array = section.get("gate_nodes")
	var zs: Array = section.get("gate_world_zs")
	var judged: Array = section.get("gate_judged")
	var acts: Array = section.get("gate_actions")
	var plan: Array = section.get("runner_plan")
	var mats_all: Array = section.get("_gate_cycle_mats")
	var start: int = int(section.get("_vis_start_idx"))
	var b2: float = beat * beat * _flash
	for i in range(start, nodes.size()):
		if i >= zs.size():
			break
		var dz: float = float(zs[i]) - pd
		if dz > 55.0:
			break
		var gate: Node3D = nodes[i]
		if gate == null or not is_instance_valid(gate) or not gate.visible:
			continue
		if i < judged.size() and bool(judged[i]):
			if _breathed.has(i):
				gate.scale = Vector3.ONE
				_breathed.erase(i)
			continue
		var action: String = String(acts[i]) if i < acts.size() else ""
		if not action in GATE_KINDS:
			continue
		gate.scale = Vector3.ONE * (1.0 + 0.045 * b2)
		_breathed[i] = true
		# One beat before it arrives: a bright flash, once — "here it comes".
		if not _locked.has(i) and i < plan.size():
			var dt: float = float(plan[i].get("t", 0.0)) - t_s
			if dt > 0.0 and dt <= beat_s:
				_locked[i] = true
				if i < mats_all.size():
					for m: Material in (mats_all[i] as Array):
						if m == null:
							continue
						if not m.has_meta("flair_e"):
							m.set_meta("flair_e", NeonMat.get_energy(m))
						var base_e: float = float(m.get_meta("flair_e"))
						var tw: Tween = create_tween()
						tw.tween_method(func(e: float) -> void: NeonMat.set_energy(m, e),
							base_e * (1.0 + 0.9 * _flash), base_e, 0.22)


# ══════════════════════════════════════════════════════════════════════════════
#  Pattern ribbons
# ══════════════════════════════════════════════════════════════════════════════

func _update_ribbons(pd: float) -> void:
	var plan: Array = section.get("runner_plan")
	var zs: Array = section.get("gate_world_zs")
	var lanes: PackedFloat32Array = player.get("lane_xs")
	while _rib_next < plan.size() - 1 and _rib_next < zs.size() - 1:
		var a: Dictionary = plan[_rib_next]
		var a_pd: float = float(zs[_rib_next])
		if a_pd > pd + RIBBON_AHEAD_M:
			break
		var b: Dictionary = plan[_rib_next + 1]
		var b_pd: float = float(zs[_rib_next + 1])
		_rib_next += 1
		if a_pd < pd:
			continue
		var pa: int = int(a.get("phrase_index", -1))
		if pa < 0 or pa != int(b.get("phrase_index", -2)):
			continue
		if not String(a.get("action", "")) in GATE_KINDS or not String(b.get("action", "")) in GATE_KINDS:
			continue
		if b_pd - a_pd > 40.0 or b_pd - a_pd < 3.0:
			continue
		if bool(section.call("_is_in_rap_segment", float(a.get("t", 0.0)))):
			continue
		var la: float = lanes[clampi(int(a.get("post_lane", 1)), 0, lanes.size() - 1)]
		var lb: float = lanes[clampi(int(b.get("post_lane", 1)), 0, lanes.size() - 1)]
		var col: Color = section.call("_action_color", String(b.get("action", "")))
		_build_ribbon(a_pd + 1.2, b_pd - 1.2, la, lb, col)
	# Free the ones behind him; dim with the blackout.
	var i: int = 0
	while i < _ribbons.size():
		if float(_ribbons[i]["end_pd"]) < pd - 8.0:
			(_ribbons[i]["node"] as Node3D).queue_free()
			_ribbons.remove_at(i)
		else:
			i += 1
	for key in _rib_mats:
		var m: StandardMaterial3D = _rib_mats[key]
		m.emission_energy_multiplier = 1.6 * maxf(0.15, _lit)


func _build_ribbon(pd0: float, pd1: float, la: float, lb: float, col: Color) -> void:
	const SEGS: int = 10
	const W: float = 0.09
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for k in SEGS + 1:
		var u: float = float(k) / float(SEGS)
		var e: float = u * u * (3.0 - 2.0 * u)
		var p_pd: float = lerpf(pd0, pd1, u)
		var lat: float = lerpf(la, lb, e)
		var c: Vector3 = section.call("_path_world_pos", p_pd, lat, 0.035)
		var r: Vector3 = section.call("_path_right_at", p_pd)
		st.add_vertex(c - r * W)
		st.add_vertex(c + r * W)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _ribbon_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("no_cycle", true)
	world.add_child(mi)
	_ribbons.append({"node": mi, "end_pd": pd1})


func _ribbon_mat(col: Color) -> StandardMaterial3D:
	var key: String = col.to_html(false)
	if _rib_mats.has(key):
		return _rib_mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.BLACK
	m.metallic_specular = 0.0
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.6
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rib_mats[key] = m
	return m


# ══════════════════════════════════════════════════════════════════════════════
#  Combo trail
# ══════════════════════════════════════════════════════════════════════════════

func _build_trail() -> void:
	_trail_mesh = ImmediateMesh.new()
	_trail_mi = MeshInstance3D.new()
	_trail_mi.mesh = _trail_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_trail_mi.material_override = m
	_trail_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail_mi.top_level = true
	world.add_child(_trail_mi)


func _update_trail(delta: float, mult: int) -> void:
	var busy: bool = bool(player.call("is_grinding")) or bool(player.call("is_charge_sliding"))
	var smash: Node = section.get("_smash")
	if smash != null and bool(smash.call("is_mashing")):
		busy = true
	var want: float = 0.0 if busy or mult < 2 else 1.0
	_trail_k = move_toward(_trail_k, want, delta * 3.0)
	_trail_pts.push_front({"p": player.global_position + Vector3(0.0, 0.78, 0.0), "t": _t})
	var life: float = lerpf(0.16, 0.42, clampf(float(mult - 2) / 8.0, 0.0, 1.0))
	while _trail_pts.size() > 2 and _t - float(_trail_pts.back()["t"]) > life:
		_trail_pts.pop_back()
	_trail_mesh.clear_surfaces()
	if _trail_k <= 0.01 or _trail_pts.size() < 2:
		return
	var right: Vector3 = player.get("right_dir")
	if right == Vector3.ZERO:
		right = Vector3.RIGHT
	var bright: float = lerpf(0.35, 0.85, clampf(float(mult - 2) / 8.0, 0.0, 1.0)) * _trail_k
	var rainbow: bool = mult >= 20
	var base_col: Color = GameConfig.level_color_a.lerp(Color(1, 1, 1), 0.25)
	if mult >= 10 and not rainbow:
		base_col = GameConfig.level_color_b.lerp(Color(1, 1, 1), 0.35)
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var n: int = _trail_pts.size()
	for k in n:
		var u: float = float(k) / float(n - 1)
		var p: Vector3 = _trail_pts[k]["p"]
		var w: float = lerpf(0.30, 0.04, u)
		var col: Color = base_col
		if rainbow:
			col = Color.from_hsv(fposmod(_t * 0.8 + u * 0.9, 1.0), 0.85, 1.0)
		col.a = (1.0 - u) * bright * _lit
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p - right * w)
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p + right * w)
	_trail_mesh.surface_end()


# ══════════════════════════════════════════════════════════════════════════════
#  Jump & slide
# ══════════════════════════════════════════════════════════════════════════════

func _build_jump_fx() -> void:
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.1
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = NeonMat.orb(Color(0.8, 0.95, 1.0), 4.0)
	_puff = _emitter(sm, 22, 0.32, true)
	_puff.direction = Vector3(0, 0.15, 0)
	_puff.spread = 180.0
	_puff.flatness = 0.85
	_puff.initial_velocity_min = 3.0
	_puff.initial_velocity_max = 5.5
	_puff.gravity = Vector3.ZERO
	world.add_child(_puff)
	var sp := SphereMesh.new()
	sp.radius = 0.03
	sp.height = 0.06
	sp.radial_segments = 6
	sp.rings = 3
	sp.material = NeonMat.orb(GameConfig.level_color_slide.lerp(Color.WHITE, 0.3), 6.0)
	_slide_sparks = _emitter(sp, 40, 0.3, false)
	_slide_sparks.direction = Vector3(0, 0.5, -1)
	_slide_sparks.spread = 40.0
	_slide_sparks.initial_velocity_min = 3.0
	_slide_sparks.initial_velocity_max = 6.0
	_slide_sparks.gravity = Vector3(0, -12, 0)
	player.add_child(_slide_sparks)
	_slide_sparks.position = Vector3(0, 0.08, 0)
	for k in 3:
		var tm := TorusMesh.new()
		tm.inner_radius = 0.55
		tm.outer_radius = 0.65
		tm.rings = 32
		tm.ring_segments = 6
		var m: ShaderMaterial = NeonMat.ring(GameConfig.level_color_jump, 0.0)
		var n := MeshInstance3D.new()
		n.mesh = tm
		n.material_override = m
		n.set_meta("no_cycle", true)
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.visible = false
		world.add_child(n)
		_land_rings.append({"node": n, "mat": m, "t": -1.0})


func _update_jump_fx(delta: float) -> void:
	var busy: bool = bool(player.call("is_grinding"))
	var air: bool = bool(player.call("is_airborne"))
	if air and not _was_air and not busy:
		_puff.global_position = player.global_position + Vector3(0, 0.1, 0)
		_puff.restart()
		_puff.emitting = true
	elif _was_air and not air and not busy:
		var r: Dictionary = _land_rings[_land_i]
		_land_i = (_land_i + 1) % _land_rings.size()
		var node: MeshInstance3D = r["node"]
		node.visible = true
		node.global_position = player.global_position + Vector3(0, 0.05, 0)
		r["t"] = 0.0
	_was_air = air
	_slide_sparks.emitting = bool(player.call("is_sliding")) and not busy
	for r: Dictionary in _land_rings:
		var t: float = float(r["t"])
		if t < 0.0:
			continue
		t += delta
		r["t"] = t
		var k: float = t / 0.35
		var node: MeshInstance3D = r["node"]
		if k >= 1.0:
			r["t"] = -1.0
			node.visible = false
			continue
		var sc: float = lerpf(0.4, 2.6, 1.0 - (1.0 - k) * (1.0 - k))
		node.scale = Vector3(sc, 1.0, sc)
		NeonMat.set_energy(r["mat"], (1.0 - k) * 3.0 * _flash + 0.2)


# ══════════════════════════════════════════════════════════════════════════════
#  City heat & fireworks
# ══════════════════════════════════════════════════════════════════════════════

func _update_heat(delta: float, mult: int) -> void:
	var want: float = clampf(float(mult - 1) / 9.0, 0.0, 1.0)
	_heat = move_toward(_heat, want, delta * (0.6 if want > _heat else 2.0))
	section.set("_flair_city_glow", lerpf(0.75, 1.5, _heat))
	section.set("_flair_laser_k", lerpf(0.55, 1.0, _heat))


func _firework() -> void:
	if player == null:
		return
	var pd: float = float(section.get("_player_path_dist"))
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var pos: Vector3 = section.call("_path_world_pos", pd + randf_range(60.0, 130.0),
		side * randf_range(14.0, 34.0), randf_range(16.0, 30.0))
	var col: Color = Color.from_hsv(randf(), 0.75, 1.0)
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.36
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = NeonMat.orb(col, 9.0)
	var e := _emitter(sm, 80, 1.4, true)
	e.direction = Vector3.UP
	e.spread = 180.0
	e.initial_velocity_min = 7.0
	e.initial_velocity_max = 12.0
	e.gravity = Vector3(0, -4.0, 0)
	e.damping_min = 2.0
	e.damping_max = 3.0
	e.emission_sphere_radius = 0.3
	world.add_child(e)
	e.global_position = pos
	e.emitting = true
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = 4.0 * _flash
	l.omni_range = 40.0
	world.add_child(l)
	l.global_position = pos
	# Each cleans itself up, so nothing is left waiting on a level that has gone.
	var tw: Tween = l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.8)
	tw.tween_callback(l.queue_free)
	e.finished.connect(e.queue_free)


# ══════════════════════════════════════════════════════════════════════════════
#  Sky
# ══════════════════════════════════════════════════════════════════════════════

func _build_sky() -> void:
	_moon = Node3D.new()
	_moon.name = "HorizonMoon"
	world.add_child(_moon)
	var disc := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 26.0
	sm.height = 52.0
	sm.radial_segments = 32
	sm.rings = 16
	disc.mesh = sm
	_moon_mat = NeonMat.orb(Color(1.0, 0.55, 0.85), 1.5)
	_moon_mat.set_shader_parameter("edge_fade", 0.6)
	disc.material_override = _moon_mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.set_meta("no_cycle", true)
	_moon.add_child(disc)
	_moon_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 36.0
	tm.outer_radius = 38.0
	tm.rings = 64
	tm.ring_segments = 8
	_moon_ring.mesh = tm
	_moon_ring_mat = NeonMat.ring(Color(0.45, 0.85, 1.0), 2.0)
	_moon_ring.material_override = _moon_ring_mat
	_moon_ring.set_meta("no_cycle", true)
	_moon_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_ring.rotation_degrees = Vector3(80, 0, 12)
	_moon.add_child(_moon_ring)
	# Aurora: two great rings round the horizon, faint, banded and drifting.
	for k in 2:
		var am := MeshInstance3D.new()
		var at := TorusMesh.new()
		at.inner_radius = 210.0 + 30.0 * float(k)
		at.outer_radius = 226.0 + 30.0 * float(k)
		at.rings = 96
		at.ring_segments = 6
		am.mesh = at
		var amat: ShaderMaterial = NeonMat.ring(
			Color(0.3, 1.0, 0.7) if k == 0 else Color(0.65, 0.4, 1.0), 0.0)
		amat.set_shader_parameter("band_amount", 0.85)
		amat.set_shader_parameter("band_scale", 18.0)
		amat.set_shader_parameter("band_speed", 0.35 + 0.2 * float(k))
		amat.set_shader_parameter("alpha", 0.5)
		am.material_override = amat
		am.set_meta("no_cycle", true)
		am.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(am)
		_aurora.append({"node": am, "mat": amat, "tilt": 6.0 + 5.0 * float(k)})
	# Shooting stars.
	for k in 3:
		var star := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.35, 0.35, 14.0)
		star.mesh = bm
		var smat: ShaderMaterial = NeonMat.tube(Color(0.9, 0.95, 1.0), 0.0)
		smat.set_shader_parameter("box_size", bm.size)
		star.material_override = smat
		star.set_meta("no_cycle", true)
		star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		star.visible = false
		world.add_child(star)
		_stars.append({"node": star, "mat": smat, "t": -1.0, "a": Vector3.ZERO, "b": Vector3.ZERO})


func _update_sky(t_s: float, delta: float, pd: float, beat: float) -> void:
	var fwd: Vector3 = section.call("_path_forward_at", pd)
	var base: Vector3 = player.global_position
	# The moon-hologram: far off on the horizon, pulsing with the beat. Like a
	# real moon it keeps its distance as he runs but holds its place in the sky:
	# a fixed world direction (where the track pointed at the start), so it does
	# not swing round with him through a turn.
	if _moon_dir == Vector3.ZERO:
		_moon_dir = Vector3(fwd.x, 0.0, fwd.z).normalized()
		if _moon_dir == Vector3.ZERO:
			_moon_dir = Vector3.FORWARD
		_moon.global_position = base + _moon_dir * 330.0 + Vector3(0.0, 50.0, 0.0)
		_moon.look_at(base, Vector3.UP)
	_moon.global_position = base + _moon_dir * 330.0 + Vector3(0.0, 50.0, 0.0)
	var b2: float = beat * beat * _flash
	NeonMat.set_energy(_moon_mat, (1.1 + 1.6 * b2) * maxf(0.2, _lit))
	NeonMat.set_energy(_moon_ring_mat, (1.4 + 2.0 * b2) * _lit)
	_moon_ring.rotation_degrees.z += delta * 6.0

	# Aurora in the calm: few gates in the next few seconds.
	var plan: Array = section.get("runner_plan")
	var count: int = 0
	var j: int = _phrase_scan
	while j < plan.size() and float(plan[j].get("t", 0.0)) < t_s:
		j += 1
	_phrase_scan = j
	var k: int = j
	while k < plan.size() and float(plan[k].get("t", 0.0)) < t_s + 3.0:
		count += 1
		k += 1
	var want_calm: float = 1.0 if count <= 3 else 0.0
	_calm = move_toward(_calm, want_calm, delta * 0.5)
	for a: Dictionary in _aurora:
		var node: MeshInstance3D = a["node"]
		node.global_position = base + Vector3(0.0, 26.0, 0.0)
		node.rotation_degrees = Vector3(float(a["tilt"]) + 3.0 * sin(_t * 0.2), _t * 2.0, 0.0)
		NeonMat.set_energy(a["mat"], 1.6 * _calm * _lit)
		node.visible = _calm * _lit > 0.02

	# Shooting stars as a new phrase begins (where the crash usually lands).
	if j < plan.size():
		var ph: int = int(plan[j].get("phrase_index", -1))
		if ph != _last_phrase and ph >= 0:
			if _last_phrase != -999 and randf() < 0.7 and _lit > 0.5:
				_shooting_star(base, fwd)
			_last_phrase = ph
	for s: Dictionary in _stars:
		var t: float = float(s["t"])
		if t < 0.0:
			continue
		t += delta
		s["t"] = t
		var node: MeshInstance3D = s["node"]
		var kk: float = t / 0.9
		if kk >= 1.0:
			s["t"] = -1.0
			node.visible = false
			continue
		var p: Vector3 = (s["a"] as Vector3).lerp(s["b"], kk)
		node.global_position = p
		node.look_at(p + ((s["b"] as Vector3) - (s["a"] as Vector3)), Vector3.UP)
		NeonMat.set_energy(s["mat"], sin(kk * PI) * 7.0 * _flash + 0.5)


func _shooting_star(base: Vector3, fwd: Vector3) -> void:
	var s: Dictionary = _stars[_star_i]
	_star_i = (_star_i + 1) % _stars.size()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var a: Vector3 = base + fwd * randf_range(180.0, 260.0) + right * side * randf_range(40.0, 110.0) \
		+ Vector3(0.0, randf_range(38.0, 62.0), 0.0)
	var b: Vector3 = a - right * side * randf_range(90.0, 150.0) + Vector3(0.0, -randf_range(14.0, 26.0), 0.0)
	s["a"] = a
	s["b"] = b
	s["t"] = 0.0
	(s["node"] as Node3D).visible = true


# ══════════════════════════════════════════════════════════════════════════════
#  Trackside
# ══════════════════════════════════════════════════════════════════════════════

func _build_beams() -> void:
	for k in 4:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.2, 140.0, 2.2)
		mi.mesh = bm
		var m: ShaderMaterial = NeonMat.ring(Color(0.75, 0.85, 1.0), 0.0)
		m.set_shader_parameter("alpha", 0.22)
		m.set_shader_parameter("band_amount", 0.0)
		mi.material_override = m
		mi.set_meta("no_cycle", true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pivot := Node3D.new()
		world.add_child(pivot)
		pivot.add_child(mi)
		mi.position = Vector3(0.0, 70.0, 0.0)
		_beams.append({"pivot": pivot, "mat": m, "pd": -1.0, "side": -1.0 if k % 2 == 0 else 1.0,
			"phase": float(k) * 1.7})


func _update_trackside(t_s: float, delta: float, pd: float, beat: float) -> void:
	var half_w: float = float(section.call("_track_full_width")) * 0.5
	var spd: float = float(player.get("forward_speed"))
	# ── Searchlights: four beams that leapfrog ahead of him and sweep the sky.
	for i in _beams.size():
		var bm: Dictionary = _beams[i]
		if float(bm["pd"]) < pd + 15.0:
			bm["pd"] = pd + 110.0 + 55.0 * float(i)
		var pivot: Node3D = bm["pivot"]
		pivot.global_position = section.call("_path_world_pos", float(bm["pd"]),
			float(bm["side"]) * (half_w + 34.0), -2.0)
		var ph: float = _t * 0.45 + float(bm["phase"])
		pivot.rotation = Vector3(deg_to_rad(18.0 * sin(ph * 0.7)), 0.0,
			deg_to_rad(-float(bm["side"]) * (14.0 + 18.0 * sin(ph))))
		NeonMat.set_energy(bm["mat"], (0.9 + 0.5 * beat * _flash) * _lit)
		pivot.visible = _lit > 0.05

	# ── Trains of light on an elevated line beside the track, coming at him.
	_train_cd -= delta
	if _train_cd <= 0.0 and _lit > 0.5:
		_train_cd = randf_range(9.0, 16.0)
		_spawn_train(pd, half_w)
	var i2: int = 0
	while i2 < _trains.size():
		var tr: Dictionary = _trains[i2]
		tr["pd"] = float(tr["pd"]) - 32.0 * delta
		var cars: Array = tr["cars"]
		for c in cars.size():
			var cpd: float = float(tr["pd"]) + float(c) * 7.2
			var car: Node3D = cars[c]
			car.global_position = section.call("_path_world_pos", cpd, float(tr["lat"]), float(tr["h"]))
			car.rotation_degrees.y = float(section.call("_path_y_rot_at", cpd))
		if float(tr["pd"]) + 7.2 * float(cars.size()) < pd - 30.0:
			for car2: Node3D in cars:
				car2.queue_free()
			_trains.remove_at(i2)
		else:
			i2 += 1

	# ── Drone swarms hovering beside the track, blinking on the beat.
	_drone_cd -= delta
	if _drone_cd <= 0.0 and _lit > 0.5:
		_drone_cd = randf_range(5.0, 9.0)
		_spawn_drones(pd, half_w)
	var i3: int = 0
	while i3 < _drones.size():
		var sw: Dictionary = _drones[i3]
		if float(sw["pd"]) < pd - 15.0:
			(sw["root"] as Node3D).queue_free()
			_drones.remove_at(i3)
			continue
		var root: Node3D = sw["root"]
		var list: Array = sw["list"]
		for d in list.size():
			var dr: Node3D = list[d]
			var ph2: float = _t * 1.6 + float(d) * 1.3
			dr.position = (sw["offs"] as Array)[d] + Vector3(sin(ph2) * 0.6, sin(ph2 * 1.7) * 0.4, cos(ph2) * 0.6)
		NeonMat.set_energy(sw["mat"], (2.0 + 6.0 * beat * beat * _flash) * _lit)
		root.visible = _lit > 0.05
		i3 += 1

	# ── Lyric billboards: the key word of each line, up beside the track as
	# it is sung.
	var lyrics: Array = section.get("_lyrics")
	while _lyric_i < lyrics.size():
		var line: Dictionary = lyrics[_lyric_i]
		var ts: float = float(line.get("t_start", 0.0))
		if t_s < ts - 2.2:
			break
		_lyric_i += 1
		if ts - _last_board_t < 3.0 or t_s > ts:
			continue
		var word: String = _key_word(line)
		if word == "":
			continue
		_last_board_t = ts
		_spawn_board(word, (ts + 0.35) * spd, half_w)
	var i4: int = 0
	while i4 < _boards.size():
		var bd: Dictionary = _boards[i4]
		var node: Node3D = bd["node"]
		bd["age"] = float(bd["age"]) + delta
		var fade_in: float = clampf(float(bd["age"]) / 0.25, 0.0, 1.0)
		var lbl: Label3D = bd["label"]
		var c: Color = bd["col"]
		c.a = fade_in * maxf(0.1, _lit)
		lbl.modulate = c
		for fmat: ShaderMaterial in (bd["mats"] as Array):
			NeonMat.set_energy(fmat, (3.0 + 2.0 * beat * _flash) * fade_in * _lit)
		if float(bd["pd"]) < pd - 12.0:
			node.queue_free()
			_boards.remove_at(i4)
		else:
			i4 += 1


func _spawn_train(pd: float, half_w: float) -> void:
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var lat: float = side * (half_w + randf_range(16.0, 24.0))
	var h: float = randf_range(7.0, 11.0)
	var col: Color = Color(0.4, 0.9, 1.0) if randf() < 0.5 else Color(1.0, 0.45, 0.8)
	var cars: Array = []
	var m: ShaderMaterial = NeonMat.panel(col, 3.0)
	var nose: ShaderMaterial = NeonMat.tube(Color(1.0, 0.95, 0.85), 8.0)
	for c in 6:
		var car := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.0, 1.6, 6.6)
		car.mesh = bm
		car.material_override = nose if c == 0 else m
		if c == 0:
			nose.set_shader_parameter("box_size", bm.size)
		else:
			m.set_shader_parameter("box_size", bm.size)
		car.set_meta("no_cycle", true)
		car.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(car)
		cars.append(car)
	_trains.append({"pd": pd + 280.0, "lat": lat, "h": h, "cars": cars})


func _spawn_drones(pd: float, half_w: float) -> void:
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var spd_pd: float = pd + randf_range(110.0, 150.0)
	var root := Node3D.new()
	world.add_child(root)
	root.global_position = section.call("_path_world_pos", spd_pd,
		side * (half_w + randf_range(6.0, 11.0)), randf_range(4.5, 7.5))
	var col: Color = Color.from_hsv(randf(), 0.6, 1.0)
	var m: ShaderMaterial = NeonMat.orb(col, 3.0)
	var body_m: ShaderMaterial = NeonMat.panel(Color(0.12, 0.12, 0.16), 0.4)
	var list: Array = []
	var offs: Array = []
	for d in 5:
		var dr := Node3D.new()
		root.add_child(dr)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.7, 0.14, 0.7)
		body.mesh = bm
		body.material_override = body_m
		body_m.set_shader_parameter("box_size", bm.size)
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dr.add_child(body)
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = 0.14
		em.height = 0.28
		em.radial_segments = 8
		em.rings = 4
		eye.mesh = em
		eye.material_override = m
		eye.position = Vector3(0, -0.1, 0)
		eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dr.add_child(eye)
		for n: Node in [body, eye]:
			n.set_meta("no_cycle", true)
		list.append(dr)
		offs.append(Vector3(randf_range(-2.5, 2.5), randf_range(-1.2, 1.2), randf_range(-2.5, 2.5)))
	_drones.append({"root": root, "list": list, "offs": offs, "mat": m, "pd": spd_pd})


func _key_word(line: Dictionary) -> String:
	var best: String = ""
	var words: Array = line.get("words", [])
	var texts: PackedStringArray = []
	if not words.is_empty():
		for w: Variant in words:
			if w is Dictionary:
				texts.append(String((w as Dictionary).get("w", "")))
	else:
		texts = String(line.get("text", "")).split(" ", false)
	for w2: String in texts:
		var clean: String = ""
		for ch in w2:
			if ch.to_upper() != ch.to_lower() or ch == "'":
				clean += ch
		if clean.length() > best.length():
			best = clean
	return best.to_upper() if best.length() >= 3 else ""


func _spawn_board(word: String, bpd: float, half_w: float) -> void:
	_board_side = -_board_side
	var side: float = _board_side
	var node := Node3D.new()
	world.add_child(node)
	node.global_position = section.call("_path_world_pos", bpd, side * (half_w + 5.0), 3.2)
	# Facing back down the track at him, angled in toward the lanes.
	node.rotation_degrees.y = float(section.call("_path_y_rot_at", bpd)) + 180.0 - side * 24.0
	var col: Color = Color.from_hsv(randf(), 0.7, 1.0)
	var lbl := Label3D.new()
	lbl.text = word
	lbl.font_size = 160
	lbl.pixel_size = 0.012
	lbl.outline_size = 18
	lbl.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	var f: Font = section.get("_lyric_font")
	if f != null:
		lbl.font = f
	lbl.modulate = col
	lbl.shaded = false
	lbl.double_sided = false
	node.add_child(lbl)
	# A neon frame round it, sized to the word.
	var w: float = maxf(2.5, float(word.length()) * 1.05)
	var h: float = 2.4
	# One material per bar shape: neon_tube reads its core from box_size.
	var fm_h: ShaderMaterial = NeonMat.tube(col, 3.0)
	var fm_v: ShaderMaterial = NeonMat.tube(col, 3.0)
	fm_h.set_shader_parameter("box_size", Vector3(w, 0.1, 0.1))
	fm_v.set_shader_parameter("box_size", Vector3(0.1, h, 0.1))
	for bar: Array in [[Vector3(w, 0.1, 0.1), Vector3(0, h * 0.5, 0)], [Vector3(w, 0.1, 0.1), Vector3(0, -h * 0.5, 0)],
			[Vector3(0.1, h, 0.1), Vector3(-w * 0.5, 0, 0)], [Vector3(0.1, h, 0.1), Vector3(w * 0.5, 0, 0)]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = bar[0]
		mi.mesh = bm
		mi.material_override = fm_h if bar[0].x > 0.5 else fm_v
		mi.position = bar[1]
		mi.set_meta("no_cycle", true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
	var post := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.16, 3.2, 0.16)
	post.mesh = pm
	post.material_override = NeonMat.panel(Color(0.15, 0.15, 0.2), 0.3)
	post.position = Vector3(0, -h * 0.5 - 1.6, 0)
	node.add_child(post)
	_boards.append({"node": node, "label": lbl, "mats": [fm_h, fm_v], "col": col, "pd": bpd, "age": 0.0})


# ══════════════════════════════════════════════════════════════════════════════
#  Miss glitch
# ══════════════════════════════════════════════════════════════════════════════

const GLITCH_SHADER: String = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount = 0.0;
uniform float seed = 0.0;
float h(float n) { return fract(sin(n) * 43758.5453); }
void fragment() {
	vec2 uv = SCREEN_UV;
	float band = floor(uv.y * 26.0 + seed * 7.0);
	float r = h(band * 1.37 + seed);
	float shift = (r > 0.62 ? (r - 0.62) * 0.09 : 0.0) * amount * (h(band + 3.1) > 0.5 ? 1.0 : -1.0);
	float ca = 0.005 * amount;
	vec2 o = vec2(shift, 0.0);
	vec3 c = vec3(texture(screen_tex, uv + o + vec2(ca, 0.0)).r,
		texture(screen_tex, uv + o).g,
		texture(screen_tex, uv + o - vec2(ca, 0.0)).b);
	float grey = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(grey) * vec3(1.0, 0.82, 0.88), 0.5 * amount);
	c *= mix(1.0, 0.9 + 0.1 * sin(uv.y * 900.0 + seed * 40.0), amount);
	COLOR = vec4(c, 1.0);
}
"""


func _start_glitch() -> void:
	if _glitch == null:
		var hud: Object = section.get("_hud")
		if hud == null:
			return
		var root: Control = hud.call("overlay_root") as Control
		if root == null:
			return
		_glitch = ColorRect.new()
		_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_glitch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = GLITCH_SHADER
		_glitch_mat = ShaderMaterial.new()
		_glitch_mat.shader = sh
		_glitch.material = _glitch_mat
		root.add_child(_glitch)
		root.move_child(_glitch, 0)   # under every HUD widget
	_glitch_t = GLITCH_S
	_glitch_mat.set_shader_parameter("seed", randf() * 100.0)
	var hud2: Object = section.get("_hud")
	if hud2 != null and hud2.has_method("interference_spike"):
		hud2.call("interference_spike", 0.7, 0.25)


func _update_glitch(delta: float) -> void:
	if _glitch == null:
		return
	if _glitch_t <= 0.0:
		_glitch.visible = false
		return
	_glitch_t = maxf(0.0, _glitch_t - delta)
	var k: float = _glitch_t / GLITCH_S
	_glitch.visible = true
	_glitch_mat.set_shader_parameter("amount", k * k * _flash)
	# Re-roll the tear a few times across its life.
	if fposmod(_t, 0.06) < delta:
		_glitch_mat.set_shader_parameter("seed", randf() * 100.0)


# ══════════════════════════════════════════════════════════════════════════════

func _emitter(mesh: Mesh, amount: int, life: float, one_shot: bool) -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.one_shot = one_shot
	e.explosiveness = 0.95 if one_shot else 0.0
	e.local_coords = false
	e.mesh = mesh
	e.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	e.emission_sphere_radius = 0.15
	var c := Curve.new()
	c.add_point(Vector2(0, 1))
	c.add_point(Vector2(1, 0))
	e.scale_amount_curve = c
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.emitting = false
	return e
