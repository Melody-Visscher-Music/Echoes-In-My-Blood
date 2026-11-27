extends Node3D
class_name ComboShield

## Combo shields: rare pickups that absorb one miss.
##
## They are placed just before the hardest stretches of the chart — the densest
## runs of gates and the way into each electric zone — so one slip in a hard
## pattern does not cost a whole run. Each one floats in the lane he should be
## in at that moment, so playing the chart right is what picks it up.
##
## A held shield is a small orb circling him at the waist (up to MAX_HELD). A
## miss with one in hand still counts as a miss for the results, but the combo,
## the health and the combo multiplier survive it.
##
## The section owns one: setup() once the chart and path exist, update() every
## frame, and try_absorb() at the top of a miss.

const MAX_HELD: int = 2
const MAX_PER_SONG: int = 6
const MIN_SPACING_S: float = 22.0
const LEAD_S: float = 1.2           # how long before the hard part it sits
const DENSE_N: int = 5              # gates ...
const DENSE_WINDOW_S: float = 2.4   # ... within this long count as hard
const COL: Color = Color(0.45, 0.95, 1.0)
const SR: int = 22050

var section: Node = null
var player: Node3D = null
var held: int = 0

var _picks: Array[Dictionary] = []   # {pd, lane, node, taken}
var _pick_i: int = 0
var _orbs: Array[MeshInstance3D] = []
var _t: float = 0.0
var _burst: CPUParticles3D = null
var _pop: MeshInstance3D = null
var _pop_mat: ShaderMaterial = null
var _pop_t: float = -1.0
var _sfx_get: AudioStreamPlayer = null
var _sfx_pop: AudioStreamPlayer = null


func _init() -> void:
	name = "ComboShield"


func setup(p_section: Node) -> void:
	section = p_section
	player = section.get("player") as Node3D
	var world: Node3D = section.get("world_fx_root") as Node3D
	_place(world)
	_build_fx(world)
	_sfx_get = _sfx(_gen_get(), -8.0)
	_sfx_pop = _sfx(_gen_pop(), -6.0)


# ── Placement ────────────────────────────────────────────────────────────────

func _place(world: Node3D) -> void:
	var plan: Array = section.get("runner_plan")
	var zs: PackedFloat32Array = section.get("gate_world_zs")
	var spd: float = float(player.get("forward_speed"))
	var hard_ts: Array[float] = []
	# Dense runs of ordinary gates.
	var ts: Array[float] = []
	for e: Dictionary in plan:
		if String(e.get("action", "")) in ["left", "right", "jump", "slide"]:
			ts.append(float(e.get("t", 0.0)))
	var j: int = 0
	for i in ts.size():
		while ts[i] - ts[j] > DENSE_WINDOW_S:
			j += 1
		if i - j + 1 >= DENSE_N:
			hard_ts.append(ts[j])
	# The way into each electric zone.
	for z: Dictionary in (section.get("_electric_zones") as Array):
		hard_ts.append(float(z.get("start_t", 0.0)))
	hard_ts.sort()

	var last_t: float = -INF
	for ht: float in hard_ts:
		if _picks.size() >= MAX_PER_SONG:
			break
		var t: float = ht - LEAD_S
		if t < 4.0 or t - last_t < MIN_SPACING_S:
			continue
		if not _clear_at(t, plan):
			continue
		# The lane he should be standing in then: the one the next gate expects
		# him to start from (after a smash that is the middle, whatever the gate
		# before it said).
		var lane: int = 1
		for e2: Dictionary in plan:
			if float(e2.get("t", 0.0)) > t:
				lane = int(e2.get("pre_lane", e2.get("post_lane", lane)))
				break
			lane = int(e2.get("post_lane", lane))
		lane = clampi(lane, 0, (player.get("lane_xs") as PackedFloat32Array).size() - 1)
		var pd: float = _pd_at(t, plan, zs, spd)
		_picks.append({"pd": pd, "lane": lane, "node": _make_pick(world), "taken": false, "t": t})
		last_t = t


## Path distance at song time t, from the gates either side of it (the chart's
## own time-to-distance mapping, whatever offset the level started with).
func _pd_at(t: float, plan: Array, zs: PackedFloat32Array, spd: float) -> float:
	for i in mini(plan.size(), zs.size()):
		var gt: float = float(plan[i].get("t", 0.0))
		if gt >= t:
			return zs[i] - (gt - t) * spd
	return t * spd


## Nowhere special: not on a rail, in a tunnel, near a smash or a climb, and
## not right on top of a gate.
func _clear_at(t: float, plan: Array) -> bool:
	if bool(section.call("_is_in_rap_segment", t)):
		return false
	for seg: Dictionary in (section.get("_drop_buildups") as Array):
		if t > float(seg.get("start_t", 0.0)) - 3.0 and t < float(seg.get("end_t", 0.0)) + 1.0:
			return false
	for h: Dictionary in (section.get("_smash_holds") as Array):
		if absf(t - float(h.get("t0", -99.0))) < 3.0:
			return false
	for e: Dictionary in plan:
		var et: float = float(e.get("t", 0.0))
		if et > t + 0.4:
			break
		var a: String = String(e.get("action", ""))
		if a.begins_with("wall") and absf(et - t) < 8.0:
			return false
		if absf(et - t) < 0.35:
			return false
	return true


func _make_pick(world: Node3D) -> Node3D:
	var root := Node3D.new()
	world.add_child(root)
	root.visible = false
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.36
	tm.outer_radius = 0.44
	tm.rings = 6
	tm.ring_segments = 6      # a hexagon
	ring.mesh = tm
	ring.material_override = NeonMat.ring(COL, 5.0)
	ring.rotation_degrees = Vector3(90, 0, 0)
	ring.set_meta("no_cycle", true)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var core := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.16
	sm.height = 0.32
	sm.radial_segments = 12
	sm.rings = 6
	core.mesh = sm
	core.material_override = NeonMat.orb(COL.lerp(Color.WHITE, 0.4), 7.0)
	core.set_meta("no_cycle", true)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(core)
	return root


# ── Per frame ────────────────────────────────────────────────────────────────

func update(delta: float) -> void:
	_t += delta
	if player == null or not is_instance_valid(player):
		return
	var pd: float = float(section.get("_player_path_dist"))
	var lanes: PackedFloat32Array = player.get("lane_xs")
	# Pickups: shown from 90 m out, collected on contact.
	while _pick_i < _picks.size() and float(_picks[_pick_i]["pd"]) < pd - 4.0:
		_hide(_picks[_pick_i])
		_pick_i += 1
	for k in range(_pick_i, mini(_pick_i + 3, _picks.size())):
		var pk: Dictionary = _picks[k]
		if bool(pk["taken"]):
			continue
		var ppd: float = float(pk["pd"])
		var node: Node3D = pk["node"]
		if ppd > pd + 90.0:
			node.visible = false
			continue
		node.visible = true
		var lx: float = lanes[int(pk["lane"])]
		node.global_position = section.call("_path_world_pos", ppd, lx, 1.05 + 0.12 * sin(_t * 3.0 + float(k)))
		node.rotation_degrees.y = float(section.call("_path_y_rot_at", ppd)) + _t * 120.0
		if absf(ppd - pd) < 1.0 and _lateral_to(lx) < 1.0:
			_collect(pk)
	_update_orbs(delta)
	_update_pop(delta)


func _lateral_to(lx: float) -> float:
	var segs: Array = section.get("_track_segs")
	if segs.is_empty():
		return 0.0
	var cs = segs[int(section.get("_last_seg_idx"))]
	var pd: float = float(section.get("_player_path_dist"))
	var ctr: Vector3 = cs.origin + cs.direction * (pd - cs.path_start)
	return absf((player.global_position - ctr).dot(cs.right) - lx)


func _collect(pk: Dictionary) -> void:
	pk["taken"] = true
	_hide(pk)
	if held < MAX_HELD:
		held += 1
	_burst.global_position = player.global_position + Vector3(0, 1.0, 0)
	_burst.restart()
	_burst.emitting = true
	_sfx_get.play()
	GameConfig.rumble(0.4, 0.0, 0.08)
	var hud: Object = section.get("_hud")
	if hud != null and hud.has_method("show_callout"):
		hud.call("show_callout", "SHIELD", COL, 0.5, 0.2)
	_refresh_hud()


func _hide(pk: Dictionary) -> void:
	var node: Node3D = pk["node"]
	if is_instance_valid(node):
		node.visible = false


## Called at the top of a miss. True if a shield took it.
func try_absorb() -> bool:
	if held <= 0:
		return false
	held -= 1
	_pop_t = 0.0
	_pop.visible = true
	_sfx_pop.play()
	GameConfig.rumble(0.3, 0.3, 0.12)
	_refresh_hud()
	return true


func _refresh_hud() -> void:
	var hud: Object = section.get("_hud")
	if hud != null and hud.has_method("set_shields"):
		hud.call("set_shields", held, MAX_HELD)


# ── Effects ──────────────────────────────────────────────────────────────────

func _build_fx(world: Node3D) -> void:
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	sm.radial_segments = 10
	sm.rings = 5
	for k in MAX_HELD:
		var o := MeshInstance3D.new()
		o.mesh = sm
		o.material_override = NeonMat.orb(COL, 6.0)
		o.set_meta("no_cycle", true)
		o.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		o.visible = false
		o.top_level = true
		player.add_child(o)
		_orbs.append(o)
	var bm := SphereMesh.new()
	bm.radius = 0.04
	bm.height = 0.08
	bm.radial_segments = 6
	bm.rings = 3
	bm.material = NeonMat.orb(COL, 7.0)
	_burst = CPUParticles3D.new()
	_burst.one_shot = true
	_burst.emitting = false
	_burst.amount = 30
	_burst.lifetime = 0.45
	_burst.explosiveness = 0.95
	_burst.local_coords = false
	_burst.mesh = bm
	_burst.direction = Vector3.UP
	_burst.spread = 180.0
	_burst.initial_velocity_min = 2.5
	_burst.initial_velocity_max = 5.0
	_burst.gravity = Vector3.ZERO
	_burst.damping_min = 4.0
	_burst.damping_max = 6.0
	_burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(_burst)
	# The bubble that takes the hit: a hex sphere that flashes up round him
	# and bursts.
	_pop = MeshInstance3D.new()
	var ps := SphereMesh.new()
	ps.radius = 1.0
	ps.height = 2.0
	ps.radial_segments = 6
	ps.rings = 4
	_pop.mesh = ps
	_pop_mat = NeonMat.ring(COL, 0.0)
	_pop_mat.set_shader_parameter("alpha", 0.5)
	_pop.material_override = _pop_mat
	_pop.set_meta("no_cycle", true)
	_pop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pop.visible = false
	player.add_child(_pop)
	_pop.position = Vector3(0, 0.9, 0)


func _update_orbs(delta: float) -> void:
	var c: Vector3 = player.global_position + Vector3(0, 0.75, 0)
	for k in _orbs.size():
		var o: MeshInstance3D = _orbs[k]
		o.visible = k < held
		if not o.visible:
			continue
		var a: float = _t * 3.2 + PI * float(k)
		o.global_position = c + Vector3(cos(a) * 0.62, 0.12 * sin(a * 2.0), sin(a) * 0.62)


func _update_pop(delta: float) -> void:
	if _pop_t < 0.0:
		return
	_pop_t += delta
	var k: float = _pop_t / 0.35
	if k >= 1.0:
		_pop_t = -1.0
		_pop.visible = false
		return
	_pop.scale = Vector3.ONE * lerpf(0.7, 1.5, 1.0 - (1.0 - k) * (1.0 - k))
	NeonMat.set_energy(_pop_mat, (1.0 - k) * 5.0 * maxf(GameConfig.flash_scale(), 0.35))


# ── Sound ────────────────────────────────────────────────────────────────────

func _sfx(stream: AudioStreamWAV, db: float) -> AudioStreamPlayer:
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


## Pick-up: two quick rising notes.
func _gen_get() -> AudioStreamWAV:
	var n: int = int(0.32 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = 988.0 if t < 0.08 else 1480.0
		var t2: float = t if t < 0.08 else t - 0.08
		s[i] = (sin(TAU * f * t) + 0.4 * sin(TAU * f * 2.0 * t)) * 0.3 * exp(-t2 * 9.0) * minf(1.0, t2 * 300.0)
	return _wav(s)


## The bubble taking a hit: a glassy downward chirp with a crack of noise.
func _gen_pop() -> AudioStreamWAV:
	var n: int = int(0.4 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = lerpf(1800.0, 420.0, minf(1.0, t / 0.3))
		ph += TAU * f / float(SR)
		var crack: float = randf_range(-1.0, 1.0) * exp(-t * 40.0) * 0.5
		s[i] = (sin(ph) * 0.35 * exp(-t * 7.0) + crack) * minf(1.0, t * 400.0)
	return _wav(s)
