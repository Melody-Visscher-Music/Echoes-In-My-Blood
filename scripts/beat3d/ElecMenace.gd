extends Node3D
class_name ElecMenace

## Things in an electric zone that are only there to make it feel worse.
##
## Nothing in here touches gameplay: no hitbox, no timing, no gate visibility,
## nothing in a lane. The zone already hides the floor cues and limits the
## preview, and that is the whole of its difficulty. This adds the sound of the
## room, the weather above it and what it does to the runner, and nothing else.
##
## Two rules kept everything here from making the zone harder:
##   1. Every sound that can land near a judgement lands ON a beat. A crack
##      between beats in a rhythm game reads as a timing cue, and a wrong one.
##      Gate snaps are queued to the next beat, surges pass the runner on a
##      beat, sky strikes start on one. Only the hum, the whine (both
##      continuous) and the breaker cascade (it plays during the preroll,
##      before the first gate) run off the grid.
##   2. Everything visual stays out of the lanes. Near lightning stays on the
##      pylon lines beside the track (arcs between pylons, pylons earthing
##      outward); far lightning is 55+ m off to the side or 60+ m up and 180+ m
##      out. Ground arcs beside the track keep 3+ m outside its edge. The
##      lightning halos take the tori's exact place, size and lifetime.
##      The surges ride the conduits on the outer edges, and the signs
##      stand off the track before the zone.
##
## Flashing elements are scaled by GameConfig.flash_scale() like every other
## pulse in the level.
##
## The section owns this node and feeds it: tick() every frame, on_beat() on
## every beat, and the event calls (breaker, gate_ignited, shock, graze) as
## things happen.

const SR: int = 22050

# ── Setup inputs ─────────────────────────────────────────────────────────────
var _path_pos: Callable      # (pd, lateral, y) -> Vector3
var _path_fwd: Callable      # (pd) -> Vector3
var _is_elec_pd: Callable    # (pd) -> bool
var _rail_lat: float = 6.2

# ── Audio ────────────────────────────────────────────────────────────────────
var _hum: AudioStreamPlayer = null
var _whine: AudioStreamPlayer = null
var _snap: AudioStreamPlayer = null
var _zap: AudioStreamPlayer = null
var _graze_sfx: AudioStreamPlayer = null
var _surge_sfx: AudioStreamPlayer = null
var _sky_sfx: AudioStreamPlayer = null
var _clunks: Array[AudioStreamPlayer] = []
var _clunk_next: int = 0
var _clunk_cool: float = 0.0
var _snap_pending: bool = false

## Loudest the hum gets, as linear gain. It is meant to be noticed when it
## stops more than while it plays.
const _HUM_GAIN: float = 0.42
const _WHINE_GAIN: float = 0.20
var _hum_level: float = 0.0
var _whine_level: float = 0.0

# ── Sky lightning between pylon tips ─────────────────────────────────────────
var _tips_l: Array[Vector3] = []
var _tips_l_pd: PackedFloat32Array = PackedFloat32Array()
var _tips_r: Array[Vector3] = []
var _tips_r_pd: PackedFloat32Array = PackedFloat32Array()
## Segments per bolt node: a main channel plus up to two forks.
const _BOLT_MAIN: int = 20
const _BOLT_FORK: int = 10
const _BOLT_POOL: int = 18
var _bolts: Array[Node3D] = []
var _bolt_mats: Array[StandardMaterial3D] = []
var _bolt_life: PackedFloat32Array = PackedFloat32Array()
var _bolt_max: PackedFloat32Array = PackedFloat32Array()
var _bolt_gain: PackedFloat32Array = PackedFloat32Array()   # flash light energy at full
var _bolt_flash: Array[OmniLight3D] = []
var _bolt_next: int = 0
var _bolt_mesh: BoxMesh = null
var _rumble: AudioStreamPlayer = null

# ── Conduit surges ───────────────────────────────────────────────────────────
## Surges come at the runner along the rails and pass him exactly on a beat.
## Fixed rhythm, never aimed at a gate, so they cannot be read as a lane hint.
const _SURGE_SPEED: float = 70.0     # m/s toward the runner, along the path
const _SURGE_EVERY: int = 4          # beats between surges
const _SURGE_BEATS: int = 2          # beats from spawn to passing the runner
var _surges: Array[Dictionary] = []  # {pd, nodes: Array[MeshInstance3D], passed}
var _surge_beat: int = 0
var _surge_mat_head: StandardMaterial3D = null
var _surge_mat_tail: StandardMaterial3D = null

# ── Signs ────────────────────────────────────────────────────────────────────
var _beacon_mats: Array[StandardMaterial3D] = []
var _beacon_lights: Array[OmniLight3D] = []
var _t: float = 0.0

# ── On the runner ────────────────────────────────────────────────────────────
var _shock_sparks: CPUParticles3D = null
var _shock_smoke: CPUParticles3D = null
var _graze_sparks: CPUParticles3D = null


func _init() -> void:
	name = "ElecMenace"
	# The section runs PROCESS_MODE_ALWAYS while paused so its menu works. This
	# must not inherit that, or the hum keeps buzzing over the pause screen.
	process_mode = Node.PROCESS_MODE_PAUSABLE


func setup(path_pos: Callable, path_fwd: Callable, is_elec_pd: Callable,
		rail_lateral: float) -> void:
	_path_pos = path_pos
	_path_fwd = path_fwd
	_is_elec_pd = is_elec_pd
	_rail_lat = rail_lateral
	_build_audio()
	_build_bolts()
	_build_surge_mats()


# ══════════════════════════════════════════════════════════════════════════════
#  Per-frame
# ══════════════════════════════════════════════════════════════════════════════

## dark: the section's _elec_dark. approach: 0..1, how close the blackout front
## is to reaching the runner (0 when no front is running). ignite: 0..1, how far
## the next gate is through its ignite band.
func tick(delta: float, dark: float, approach: float, player_pd: float,
		ignite: float) -> void:
	_t += delta
	_clunk_cool = maxf(0.0, _clunk_cool - delta)

	# Hum swells as the front comes in, then holds with the dark.
	var hum_want: float = maxf(dark, approach * 0.8)
	_hum_level = move_toward(_hum_level, hum_want, delta * 1.6)
	_set_loop(_hum, _hum_level * _HUM_GAIN)
	if _hum != null and _hum.playing:
		# A slow sag in pitch, like a transformer under load.
		_hum.pitch_scale = 1.0 + 0.012 * sin(_t * 0.7)

	var whine_want: float = ignite * dark
	_whine_level = move_toward(_whine_level, whine_want, delta * 4.0)
	_set_loop(_whine, _whine_level * _WHINE_GAIN)
	if _whine != null and _whine.playing:
		_whine.pitch_scale = lerpf(0.65, 1.30, ignite)

	_update_bolts(delta)
	_update_rings(delta)
	_update_surges(delta, player_pd, dark)
	_update_beacons()


func _set_loop(p: AudioStreamPlayer, gain: float) -> void:
	if p == null:
		return
	if gain <= 0.002:
		if p.playing:
			p.stop()
		return
	p.volume_db = linear_to_db(gain)
	if not p.playing:
		p.play(randf() * 0.9)


## Every beat. in_zone is the real zone (not the preroll).
func on_beat(in_zone: bool, beat_s: float, player_pd: float, player_speed: float,
		dark: float) -> void:
	if _snap_pending:
		_snap_pending = false
		if in_zone and _snap != null:
			_snap.pitch_scale = randf_range(0.92, 1.08)
			_snap.play()
	if not in_zone or dark < 0.5:
		_surge_beat = 0
		return

	_surge_beat += 1
	if _surge_beat % _SURGE_EVERY == 1:
		_spawn_surge(player_pd, player_speed, beat_s)

	_storm_beat(player_pd)


# ══════════════════════════════════════════════════════════════════════════════
#  Events
# ══════════════════════════════════════════════════════════════════════════════

## A lamp just went out, `ahead_m` metres up the track.
func breaker(ahead_m: float) -> void:
	if _clunks.is_empty() or _clunk_cool > 0.0:
		return
	_clunk_cool = 0.035
	var p: AudioStreamPlayer = _clunks[_clunk_next]
	_clunk_next = (_clunk_next + 1) % _clunks.size()
	var near: float = clampf(1.0 - ahead_m / 220.0, 0.0, 1.0)
	p.volume_db = lerpf(-30.0, -7.0, near * near)
	p.pitch_scale = randf_range(0.85, 1.12)
	p.play()


## A gate finished igniting. Its snap is held for the next beat.
func gate_ignited() -> void:
	_snap_pending = true


## A miss in the zone. Nothing here changes the damage; it is how it looks.
func shock(player: Node3D) -> void:
	if _zap != null:
		_zap.pitch_scale = randf_range(0.95, 1.05)
		_zap.play()
	_ensure_player_fx(player)
	if _shock_sparks != null:
		_shock_sparks.restart()
		_shock_sparks.emitting = true
	if _shock_smoke != null:
		_shock_smoke.restart()
		_shock_smoke.emitting = true
	if player.has_method("electrocute"):
		player.electrocute()


## A clean pass through a live gate: it reaches for him and misses.
func graze(player: Node3D) -> void:
	if _graze_sfx != null:
		_graze_sfx.pitch_scale = randf_range(0.9, 1.15)
		_graze_sfx.play()
	_ensure_player_fx(player)
	if _graze_sparks != null:
		_graze_sparks.restart()
		_graze_sparks.emitting = true


# ══════════════════════════════════════════════════════════════════════════════
#  Sky lightning
# ══════════════════════════════════════════════════════════════════════════════

## Pylon insulator tips, in increasing path order per side.
func add_pylon_tip(pd: float, side: int, pos: Vector3) -> void:
	if side < 0:
		_tips_l.append(pos)
		_tips_l_pd.append(pd)
	else:
		_tips_r.append(pos)
		_tips_r_pd.append(pd)


func _build_bolts() -> void:
	# Thick on purpose: the nearest of these are 30 m off and the furthest a
	# few hundred, where anything thinner than a third of a metre is a pixel or
	# two and reads as nothing. Distant bolts scale this up further.
	_bolt_mesh = BoxMesh.new()
	_bolt_mesh.size = Vector3(0.62, 0.62, 1.0)
	for b in _BOLT_POOL:
		var root := Node3D.new()
		root.name = "SkyBolt%d" % b
		root.visible = false
		var mat := StandardMaterial3D.new()
		# Shaded, not unshaded: Godot drops emission on unshaded materials, and
		# emission is the only way to get light brighter than white into the bloom.
		# Black albedo and no specular, so what shows is the emission alone.
		mat.metallic_specular = 0.0
		mat.roughness = 1.0
		mat.albedo_color = Color.BLACK
		mat.emission_enabled = true
		mat.emission = Color(0.55, 0.80, 1.0)
		mat.emission_energy_multiplier = 6.0
		for s in _BOLT_MAIN + _BOLT_FORK * 2:
			var seg := MeshInstance3D.new()
			seg.mesh = _bolt_mesh
			seg.material_override = mat
			seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(seg)
		# A flash at the strike. Every kind of strike sets its range so it
		# lights the steel or the skyline around it and stops short of the lanes.
		var fl := OmniLight3D.new()
		fl.name = "Flash"
		fl.light_color = Color(0.6, 0.82, 1.0)
		fl.light_energy = 0.0
		fl.omni_range = 15.0
		fl.shadow_enabled = false
		root.add_child(fl)
		add_child(root)
		_bolts.append(root)
		_bolt_mats.append(mat)
		_bolt_life.append(0.0)
		_bolt_max.append(0.42)
		_bolt_gain.append(5.0)
		_bolt_flash.append(fl)


## One beat of the storm. Most beats strike something, some strike two or
## three things at once. Every strike STARTS on the beat; the re-strike
## flicker that follows is the only thing off the grid, and it makes no sound.
## Reduced flashing thins the storm out as well as dimming it.
func _storm_beat(player_pd: float) -> void:
	if _bolts.is_empty():
		return
	var fs: float = GameConfig.flash_scale()
	var r: float = randf()
	var n: int = 0
	if r < 0.30:
		n = 0
	elif r < 0.72:
		n = 1
	elif r < 0.93:
		n = 2
	else:
		n = 3
	if fs < 1.0:
		n = mini(n, 1) if randf() < fs + 0.3 else 0
	var loud_done: bool = false
	# Ground arcs beside the track roll separately, on top of the sky.
	var r2: float = randf()
	var n_side: int = 0 if r2 < 0.35 else (1 if r2 < 0.78 else 2)
	if fs < 1.0:
		n_side = mini(n_side, 1)
	for k in n_side:
		_strike_side(player_pd)
		if not loud_done and _sky_sfx != null:
			loud_done = true
			_sky_sfx.volume_db = randf_range(-22.0, -16.0)
			_sky_sfx.pitch_scale = randf_range(0.9, 1.25)
			_sky_sfx.play()
	for k in n:
		var kind: float = randf()
		var near: bool = false
		if kind < 0.30:
			near = _strike_span(player_pd)
		elif kind < 0.50:
			near = _strike_ground(player_pd)
		elif kind < 0.85:
			_strike_distant(player_pd)
		else:
			_strike_spider(player_pd)
		# One crackle per beat at most, however many bolts — a stack of them
		# turns into noise on top of the song.
		if near and not loud_done and _sky_sfx != null:
			loud_done = true
			_sky_sfx.volume_db = randf_range(-22.0, -15.0)
			_sky_sfx.pitch_scale = randf_range(0.8, 1.1)
			_sky_sfx.play()
	if n > 0 and not loud_done and _rumble != null and not _rumble.playing:
		_rumble.volume_db = randf_range(-26.0, -19.0)
		_rumble.pitch_scale = randf_range(0.85, 1.1)
		_rumble.play()


## Pylon tip candidates on one side, 30-170 m ahead. Returns indices.
func _tip_candidates(pds: PackedFloat32Array, player_pd: float, need_next: bool) -> Array[int]:
	var out: Array[int] = []
	for i in range(pds.size() - (1 if need_next else 0)):
		var a: float = pds[i] - player_pd
		if a < 30.0:
			continue
		if a > 170.0:
			break
		if need_next and pds[i + 1] - pds[i] > 80.0:
			continue   # the next pylon is in another zone
		out.append(i)
	return out


func _outward(pd: float, at: Vector3) -> Vector3:
	var centre: Vector3 = _path_pos.call(pd, 0.0, at.y)
	var o: Vector3 = at - centre
	o.y = 0.0
	return o.normalized()


## Along the pylon line: tip to the next tip on the same side.
func _strike_span(player_pd: float) -> bool:
	var left: bool = randf() < 0.5
	var tips: Array[Vector3] = _tips_l if left else _tips_r
	var pds: PackedFloat32Array = _tips_l_pd if left else _tips_r_pd
	var c: Array[int] = _tip_candidates(pds, player_pd, true)
	if c.is_empty():
		return false
	var k: int = c[randi() % c.size()]
	var main: Array[Vector3] = _jag(tips[k], tips[k + 1], _BOLT_MAIN, 1.6, 3.0)
	var out: Vector3 = _outward(pds[k], tips[k])
	var forks: Array = [_fork(main, randi_range(4, 8), out, 4.0, 7.0, 5.0, 9.0, 0.9)]
	_fire(main, forks, 1.0, 0.45, 18.0, 9.0)
	return true


## A pylon tip earthing itself: tip down to the ground outside the pylon
## line, away from the track.
func _strike_ground(player_pd: float) -> bool:
	var left: bool = randf() < 0.5
	var tips: Array[Vector3] = _tips_l if left else _tips_r
	var pds: PackedFloat32Array = _tips_l_pd if left else _tips_r_pd
	var c: Array[int] = _tip_candidates(pds, player_pd, false)
	if c.is_empty():
		return false
	var k: int = c[randi() % c.size()]
	var top: Vector3 = tips[k]
	var out: Vector3 = _outward(pds[k], top)
	var ground: Vector3 = top + out * randf_range(14.0, 24.0)
	ground.y = 0.0
	ground += Vector3(randf_range(-6.0, 6.0), 0.0, randf_range(-6.0, 6.0))
	var main: Array[Vector3] = _jag(top, ground, _BOLT_MAIN, 1.4, -2.0)
	var forks: Array = [_fork(main, randi_range(5, 11), out, 3.0, 6.0, 4.0, 8.0, 0.8)]
	_fire(main, forks, 1.0, 0.40, 12.0, 8.0)
	return true


## A big bolt out in the background, cloud to ground, well off either side of
## the track — too far out to light anything the runner has to read.
func _strike_distant(player_pd: float) -> void:
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var pd: float = player_pd + randf_range(120.0, 320.0)
	var lat: float = side * randf_range(55.0, 140.0)
	var top: Vector3 = _path_pos.call(pd, lat + side * randf_range(-15.0, 15.0),
		randf_range(85.0, 135.0))
	var ground: Vector3 = _path_pos.call(pd + randf_range(-20.0, 20.0), lat, 0.0)
	var main: Array[Vector3] = _jag(top, ground, _BOLT_MAIN, 6.0, 0.0)
	var out: Vector3 = _outward(pd, ground)
	var forks: Array = [_fork(main, randi_range(3, 8), out, 10.0, 22.0, 14.0, 30.0, 3.5)]
	if randf() < 0.6:
		forks.append(_fork(main, randi_range(6, 13), -out, 8.0, 18.0, 12.0, 26.0, 3.0))
	_fire(main, forks, randf_range(3.6, 5.2), 0.55, 60.0, 16.0)


## An arc hopping along the ground beside the track: from one point to
## another, bowing up a few metres between them. Both ends are at least 3 m
## outside the track edge, and its flash is too short-ranged to reach the lanes.
func _strike_side(player_pd: float) -> void:
	var side: float = -1.0 if randf() < 0.5 else 1.0
	var edge: float = _rail_lat + 3.0
	var pd: float = player_pd + randf_range(12.0, 110.0)
	var a: Vector3 = _path_pos.call(pd, side * (edge + randf_range(0.0, 12.0)), 0.1)
	var b: Vector3 = _path_pos.call(pd + randf_range(4.0, 15.0),
		side * (edge + randf_range(0.0, 12.0)), 0.1)
	var main: Array[Vector3] = _jag(a, b, _BOLT_MAIN, 0.55, -randf_range(2.0, 5.5))
	var out: Vector3 = _outward(pd, a)
	var forks: Array = [_fork(main, randi_range(6, 14), out, 1.5, 4.0, 1.0, 4.0, 0.4)]
	_fire(main, forks, randf_range(0.55, 0.8), 0.32, 5.5, 4.0)


## Sheet-style "spider" lightning crawling sideways across the sky, high and
## far up the track — sky, not lanes: it is 60 m up and 180 m out at least.
func _strike_spider(player_pd: float) -> void:
	var pd: float = player_pd + randf_range(180.0, 340.0)
	var y: float = randf_range(70.0, 110.0)
	var a_lat: float = randf_range(-130.0, -30.0)
	var b_lat: float = randf_range(30.0, 130.0)
	if randf() < 0.5:
		var t: float = a_lat
		a_lat = b_lat
		b_lat = t
	var a: Vector3 = _path_pos.call(pd, a_lat, y)
	var b: Vector3 = _path_pos.call(pd + randf_range(-40.0, 40.0), b_lat, y + randf_range(-12.0, 8.0))
	var main: Array[Vector3] = _jag(a, b, _BOLT_MAIN, 7.0, -6.0)
	var forks: Array = [
		_fork(main, randi_range(3, 9), Vector3.ZERO, 0.0, 0.0, 10.0, 22.0, 3.5),
		_fork(main, randi_range(11, 17), Vector3.ZERO, 0.0, 0.0, 8.0, 18.0, 3.0)]
	_fire(main, forks, randf_range(3.0, 4.2), 0.6, 65.0, 14.0)


## A branch off `main` at index `at`, going `out` sideways and down.
func _fork(main: Array[Vector3], at: int, out: Vector3, side_min: float,
		side_max: float, drop_min: float, drop_max: float, jitter: float) -> Array[Vector3]:
	var from: Vector3 = main[clampi(at, 1, main.size() - 2)]
	var lateral: Vector3 = out
	if lateral == Vector3.ZERO:
		lateral = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()
	var to: Vector3 = from + lateral * randf_range(side_min, side_max) \
		+ Vector3(0.0, -randf_range(drop_min, drop_max), 0.0)
	to.y = maxf(to.y, 0.0)
	return _jag(from, to, _BOLT_FORK, jitter, 0.0)


## Lays a bolt into the next free pool slot and lights it.
func _fire(main: Array[Vector3], forks: Array, thick: float, life: float,
		flash_range: float, flash_energy: float) -> void:
	var bi: int = _bolt_next
	_bolt_next = (_bolt_next + 1) % _bolts.size()
	var root: Node3D = _bolts[bi]
	var segs: Array[Node] = root.get_children().filter(
		func(c: Node) -> bool: return c is MeshInstance3D)
	var si: int = 0
	var lines: Array = [main]
	lines.append_array(forks)
	for li in lines.size():
		var line: Array[Vector3] = lines[li]
		var w: float = thick * (1.0 if li == 0 else 0.6)
		for i in range(line.size() - 1):
			if si >= segs.size():
				break
			_place_seg(segs[si] as MeshInstance3D, line[i], line[i + 1], w)
			si += 1
	while si < segs.size():
		(segs[si] as Node3D).visible = false
		si += 1
	var flash := root.get_node_or_null("Flash") as OmniLight3D
	if flash != null:
		flash.global_position = main[main.size() >> 1]
		flash.omni_range = flash_range
	root.visible = true
	_bolt_life[bi] = life
	_bolt_max[bi] = life
	_bolt_gain[bi] = flash_energy


func _jag(a: Vector3, b: Vector3, n: int, jitter: float, sag: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in n + 1:
		var f: float = float(i) / float(n)
		var p: Vector3 = a.lerp(b, f)
		p.y -= sag * 4.0 * f * (1.0 - f)
		if i > 0 and i < n:
			p += Vector3(randf_range(-jitter, jitter), randf_range(-jitter, jitter),
				randf_range(-jitter, jitter))
		out.append(p)
	return out


func _place_seg(seg: MeshInstance3D, a: Vector3, b: Vector3, thick: float) -> void:
	if (b - a).length() < 0.001:
		seg.visible = false
		return
	seg.visible = true
	seg.global_transform = _seg_xform(a, b, thick)


## A box stretched from a to b, `thick` times its own cross-section.
func _seg_xform(a: Vector3, b: Vector3, thick: float) -> Transform3D:
	var d: Vector3 = b - a
	var l: float = maxf(d.length(), 0.001)
	var z: Vector3 = d / l
	var up: Vector3 = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x: Vector3 = up.cross(z).normalized()
	var y: Vector3 = z.cross(x)
	return Transform3D(Basis(x * thick, y * thick, z * l), (a + b) * 0.5)


func _update_bolts(delta: float) -> void:
	var fs: float = GameConfig.flash_scale()
	for i in _bolts.size():
		if _bolt_life[i] <= 0.0:
			continue
		_bolt_life[i] -= delta
		if _bolt_life[i] <= 0.0:
			_bolts[i].visible = false
			_bolt_flash[i].light_energy = 0.0
			continue
		# Strike, die, re-strike: lightning flickers on its channel two or three
		# times before it lets go. Re-strikes are damped with everything else.
		var age: float = _bolt_max[i] - _bolt_life[i]
		var on: float = 1.0
		if age > 0.07 and age < 0.12:
			on = 0.15
		elif age > 0.19 and age < 0.23:
			on = 0.25
		elif age > 0.31 and age < 0.34:
			on = 0.3
		var fade: float = clampf(_bolt_life[i] / 0.25, 0.0, 1.0)
		var e: float = 14.0 * on * fade
		_bolt_mats[i].emission_energy_multiplier = lerpf(e * 0.35, e, fs)
		_bolt_flash[i].light_energy = lerpf(0.3, 1.0, fs) * _bolt_gain[i] * on * fade


# ══════════════════════════════════════════════════════════════════════════════
#  Surges
# ══════════════════════════════════════════════════════════════════════════════

## ── Lightning halos ──────────────────────────────────────────────────────────
## Inside a dark zone the melody halos are rings of lightning instead of neon
## tori: two jagged strands round the same circle the torus would have drawn,
## re-struck twenty times a second, with short arcs spitting off the rim.
## Same place, same size and the same lifetime as the halo they replace, so
## they cover no more of the track than the tori did.
const _RING_POOL: int = 16
const _RING_SEGS: int = 36
const _RING_SPIKES: int = 4          # outward spits per strike, 2 segments each
const _RING_REJAG_S: float = 0.05
var _rings: Array[Dictionary] = []
var _ring_next: int = 0
var _ring_radius: float = 4.0
var _ring_box: BoxMesh = null


func setup_rings(radius: float) -> void:
	_ring_radius = maxf(radius, 0.5)
	_ring_box = BoxMesh.new()
	_ring_box.size = Vector3.ONE
	for k in _RING_POOL:
		var root := Node3D.new()
		root.name = "LightningHalo%d" % k
		root.visible = false
		# MultiMesh instances are in the node's local space; pin it to world
		# space so the ring lands where the torus would have, whatever the
		# section's own transform is.
		root.top_level = true
		add_child(root)
		var strands: Array[MultiMeshInstance3D] = []
		var mats: Array[StandardMaterial3D] = []
		for s in 2:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _ring_box
			mm.instance_count = _RING_SEGS + (_RING_SPIKES * 2 if s == 0 else 0)
			var mat := StandardMaterial3D.new()
			mat.metallic_specular = 0.0   # emission only — see _build_bolts
			mat.roughness = 1.0
			mat.albedo_color = Color.BLACK   # emission only — see _build_bolts
			mat.emission_enabled = true
			mat.emission_energy_multiplier = 0.0
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mmi)
			strands.append(mmi)
			mats.append(mat)
		_rings.append({"root": root, "strands": strands, "mats": mats,
			"life": 0.0, "max": 1.0, "centre": Vector3.ZERO,
			"right": Vector3.RIGHT, "up": Vector3.UP, "fwd": Vector3.FORWARD,
			"jag_t": 0.0, "phase": 0.0, "spin": 1.0})


## Arms a lightning halo at `centre`, facing down the track along `fwd`.
func spawn_ring(centre: Vector3, fwd: Vector3, col_a: Color, col_b: Color,
		life_s: float) -> void:
	if _rings.is_empty():
		return
	var r: Dictionary = _rings[_ring_next]
	_ring_next = (_ring_next + 1) % _rings.size()
	var f: Vector3 = fwd.normalized()
	var right: Vector3 = Vector3.UP.cross(f).normalized()
	r["centre"] = centre
	r["fwd"] = f
	r["right"] = right
	r["up"] = f.cross(right).normalized()
	r["life"] = life_s + 0.2
	r["max"] = life_s + 0.2
	r["jag_t"] = 0.0
	r["phase"] = randf() * TAU
	r["spin"] = randf_range(0.6, 1.6) * (1.0 if randf() < 0.5 else -1.0)
	var mats: Array[StandardMaterial3D] = r["mats"]
	mats[0].emission = col_a
	mats[1].emission = col_b
	(r["root"] as Node3D).visible = true
	_jag_ring(r)


## Live halos follow the halo colour cycle like the tori do.
func set_ring_colors(col_a: Color, col_b: Color) -> void:
	for r: Dictionary in _rings:
		if float(r["life"]) <= 0.0:
			continue
		var mats: Array[StandardMaterial3D] = r["mats"]
		mats[0].emission = col_a
		mats[1].emission = col_b


func _jag_ring(r: Dictionary) -> void:
	var c: Vector3 = r["centre"]
	var rt: Vector3 = r["right"]
	var up: Vector3 = r["up"]
	var fw: Vector3 = r["fwd"]
	var ph: float = float(r["phase"])
	var strands: Array[MultiMeshInstance3D] = r["strands"]
	for s in 2:
		var mm: MultiMesh = strands[s].multimesh
		var rad: float = _ring_radius * (1.0 if s == 0 else 0.93)
		var jit: float = _ring_radius * (0.07 if s == 0 else 0.10)
		var thick: float = 0.15 if s == 0 else 0.10
		var pts: Array[Vector3] = []
		for i in _RING_SEGS:
			var a: float = ph + TAU * float(i) / float(_RING_SEGS)
			var rr: float = rad + randf_range(-jit, jit)
			pts.append(c + (rt * cos(a) + up * sin(a)) * rr
				+ fw * randf_range(-0.18, 0.18))
		for i in _RING_SEGS:
			mm.set_instance_transform(i,
				_seg_xform(pts[i], pts[(i + 1) % _RING_SEGS], thick))
		if s == 0:
			# Short arcs spitting off the rim, outward, two kinks each.
			for k in _RING_SPIKES:
				var p0: Vector3 = pts[randi() % _RING_SEGS]
				var out: Vector3 = (p0 - c).normalized()
				var p1: Vector3 = p0 + out * randf_range(0.25, 0.6) \
					+ (rt * randf_range(-0.3, 0.3) + up * randf_range(-0.3, 0.3))
				var p2: Vector3 = p1 + out * randf_range(0.25, 0.7) \
					+ (rt * randf_range(-0.3, 0.3) + up * randf_range(-0.3, 0.3))
				mm.set_instance_transform(_RING_SEGS + k * 2, _seg_xform(p0, p1, 0.10))
				mm.set_instance_transform(_RING_SEGS + k * 2 + 1, _seg_xform(p1, p2, 0.07))


func _update_rings(delta: float) -> void:
	var fs: float = GameConfig.flash_scale()
	# A held note stacks a tunnel of these, and at full brightness each the
	# bloom from nine or ten at once whited out the middle of the frame —
	# gates included. Dim them as they stack so the tunnel stays a tunnel.
	var live: int = 0
	for r0: Dictionary in _rings:
		if float(r0["life"]) > 0.0:
			live += 1
	var stack: float = 1.0 / sqrt(maxf(1.0, float(live) / 2.0))
	for r: Dictionary in _rings:
		var life: float = float(r["life"])
		if life <= 0.0:
			continue
		life -= delta
		r["life"] = life
		var root: Node3D = r["root"]
		if life <= 0.0:
			root.visible = false
			continue
		r["phase"] = float(r["phase"]) + float(r["spin"]) * delta
		r["jag_t"] = float(r["jag_t"]) - delta
		if float(r["jag_t"]) <= 0.0:
			r["jag_t"] = _RING_REJAG_S
			_jag_ring(r)
		var age: float = float(r["max"]) - life
		var env: float = clampf(age / 0.10, 0.0, 1.0) * clampf(life / 0.2, 0.0, 1.0)
		# Crackle in brightness too, damped by the photosensitivity setting.
		var crackle: float = lerpf(1.0, randf_range(0.6, 1.25), fs)
		var mats: Array[StandardMaterial3D] = r["mats"]
		mats[0].emission_energy_multiplier = 5.0 * env * crackle * stack
		mats[1].emission_energy_multiplier = 3.2 * env * crackle * stack


func _build_surge_mats() -> void:
	_surge_mat_head = StandardMaterial3D.new()
	_surge_mat_head.metallic_specular = 0.0
	_surge_mat_head.albedo_color = Color.BLACK
	_surge_mat_head.emission_enabled = true
	_surge_mat_head.emission = Color(0.6, 0.9, 1.0)
	_surge_mat_head.emission_energy_multiplier = 11.0
	_surge_mat_tail = StandardMaterial3D.new()
	_surge_mat_tail.metallic_specular = 0.0
	_surge_mat_tail.albedo_color = Color.BLACK
	_surge_mat_tail.emission_enabled = true
	_surge_mat_tail.emission = Color(0.3, 0.65, 1.0)
	_surge_mat_tail.emission_energy_multiplier = 3.5
	# Fatter than the rail it rides (0.10 x 0.16), so it reads as something
	# travelling along it rather than as a brighter stretch of the rail itself.
	var head := BoxMesh.new()
	head.size = Vector3(0.30, 0.42, 3.0)
	var tail := BoxMesh.new()
	tail.size = Vector3(0.20, 0.28, 9.0)
	for k in 3:
		var nodes: Array[MeshInstance3D] = []
		for side in 2:
			for part in 2:
				var m := MeshInstance3D.new()
				m.mesh = head if part == 0 else tail
				m.material_override = _surge_mat_head if part == 0 else _surge_mat_tail
				m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				m.visible = false
				add_child(m)
				nodes.append(m)
		_surges.append({"pd": -1.0, "nodes": nodes, "passed": true, "speed": _SURGE_SPEED})


func _spawn_surge(player_pd: float, player_speed: float, beat_s: float) -> void:
	# Pick the closing speed so it reaches the runner exactly _SURGE_BEATS later.
	var travel_s: float = beat_s * float(_SURGE_BEATS)
	var closing: float = _SURGE_SPEED + player_speed
	var start_pd: float = player_pd + closing * travel_s
	for s: Dictionary in _surges:
		if float(s["pd"]) < 0.0:
			s["pd"] = start_pd
			s["passed"] = false
			s["speed"] = _SURGE_SPEED
			return


func _update_surges(delta: float, player_pd: float, dark: float) -> void:
	for s: Dictionary in _surges:
		var pd: float = float(s["pd"])
		var nodes: Array[MeshInstance3D] = s["nodes"]
		if pd < 0.0:
			continue
		pd -= float(s["speed"]) * delta
		s["pd"] = pd
		if not bool(s["passed"]) and pd <= player_pd + 0.5:
			s["passed"] = true
			if _surge_sfx != null:
				_surge_sfx.play()
		var alive: bool = pd > player_pd - 25.0 and dark > 0.3
		var in_zone: bool = _is_elec_pd.is_valid() and bool(_is_elec_pd.call(pd))
		if not alive:
			s["pd"] = -1.0
		for m: MeshInstance3D in nodes:
			m.visible = alive and in_zone
		if not (alive and in_zone):
			continue
		var fwd: Vector3 = _path_fwd.call(pd)
		var basis := Basis(Vector3.UP, atan2(fwd.x, fwd.z))
		var i: int = 0
		for side: float in [-1.0, 1.0]:
			# Head, then the tail trailing behind it (further up the track,
			# since the surge is travelling back toward the runner).
			nodes[i].global_transform = Transform3D(basis,
				_path_pos.call(pd, side * _rail_lat, 0.55))
			nodes[i + 1].global_transform = Transform3D(basis,
				_path_pos.call(pd + 6.0, side * _rail_lat, 0.55))
			i += 2


# ══════════════════════════════════════════════════════════════════════════════
#  Signs
# ══════════════════════════════════════════════════════════════════════════════

## A pair of DANGER / HIGH VOLTAGE boards and a red beacon at a zone entrance,
## standing just outside the track. `yrot_deg` is the path heading at `pd`.
func build_signs(pd: float, lateral: float, yrot_deg: float) -> void:
	var tex: ImageTexture = _sign_texture()
	var stripe: ImageTexture = _stripe_texture()
	for side: float in [-1.0, 1.0]:
		var root := Node3D.new()
		root.name = "HighVoltageSign"
		add_child(root)
		root.global_position = _path_pos.call(pd, side * lateral, 0.0)
		# Face the oncoming runner, angled a little toward the track.
		root.rotation_degrees.y = yrot_deg + 180.0 + side * 18.0

		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.14, 2.9, 0.14)
		post.mesh = pm
		var post_mat := StandardMaterial3D.new()
		post_mat.albedo_texture = stripe
		post_mat.uv1_scale = Vector3(1.0, 6.0, 1.0)
		post_mat.emission_enabled = true
		post_mat.emission_texture = stripe
		post_mat.emission_energy_multiplier = 0.25
		post.material_override = post_mat
		post.position = Vector3(0.0, 1.45, -0.05)
		root.add_child(post)

		var board := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(1.5, 1.15)
		board.mesh = qm
		var bm := StandardMaterial3D.new()
		bm.albedo_texture = tex
		bm.emission_enabled = true
		bm.emission_texture = tex
		bm.emission_energy_multiplier = 0.55
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		board.material_override = bm
		board.position = Vector3(0.0, 2.15, 0.03)
		root.add_child(board)

		var top := Label3D.new()
		top.text = "DANGER"
		top.font_size = 64
		top.pixel_size = 0.0042
		top.modulate = Color(1.0, 0.86, 0.10)
		top.outline_size = 0
		top.shaded = false
		top.position = Vector3(0.0, 2.55, 0.045)
		root.add_child(top)

		var bottom := Label3D.new()
		bottom.text = "HIGH VOLTAGE"
		bottom.font_size = 48
		bottom.pixel_size = 0.0040
		bottom.modulate = Color(0.05, 0.05, 0.05)
		bottom.outline_size = 0
		bottom.shaded = false
		bottom.position = Vector3(0.0, 1.73, 0.045)
		root.add_child(bottom)

		# Beacon on top of the post.
		var bulb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.11
		sm.height = 0.22
		bulb.mesh = sm
		var lm := StandardMaterial3D.new()
		lm.albedo_color = Color(1.0, 0.15, 0.1)
		lm.emission_enabled = true
		lm.emission = Color(1.0, 0.08, 0.04)
		lm.emission_energy_multiplier = 3.0
		bulb.material_override = lm
		bulb.position = Vector3(0.0, 2.98, -0.05)
		root.add_child(bulb)
		var bl := OmniLight3D.new()
		bl.light_color = Color(1.0, 0.12, 0.06)
		bl.light_energy = 1.0
		bl.omni_range = 5.0
		bl.position = bulb.position
		bl.distance_fade_enabled = true
		bl.distance_fade_begin = 120.0
		bl.distance_fade_length = 30.0
		root.add_child(bl)
		_beacon_mats.append(lm)
		_beacon_lights.append(bl)


func _update_beacons() -> void:
	if _beacon_mats.is_empty():
		return
	# A slow warning pulse, not a strobe: ~1.1 Hz, eased, and the trough is
	# raised under reduced flashing.
	var w: float = 0.5 + 0.5 * sin(_t * TAU * 1.1)
	w = w * w
	w = lerpf(0.6, w, GameConfig.flash_scale())
	for m: StandardMaterial3D in _beacon_mats:
		m.emission_energy_multiplier = lerpf(0.4, 4.0, w)
	for l: OmniLight3D in _beacon_lights:
		l.light_energy = lerpf(0.1, 1.6, w)


func _sign_texture() -> ImageTexture:
	const W: int = 192
	const H: int = 148
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	var yellow := Color(1.0, 0.80, 0.05)
	var black := Color(0.04, 0.04, 0.04)
	img.fill(yellow)
	# Black border and black header band (the DANGER label sits on it).
	for y in H:
		for x in W:
			if x < 6 or x >= W - 6 or y < 6 or y >= H - 6 or (y >= 6 and y < 46):
				img.set_pixel(x, y, black)
	# Lightning bolt between the bands.
	var bolt: PackedVector2Array = PackedVector2Array([
		Vector2(104, 52), Vector2(78, 92), Vector2(96, 92), Vector2(84, 122),
		Vector2(118, 80), Vector2(100, 80), Vector2(114, 52)])
	for y in range(50, 124):
		for x in range(70, 124):
			if Geometry2D.is_point_in_polygon(Vector2(x, y), bolt):
				img.set_pixel(x, y, black)
	return ImageTexture.create_from_image(img)


func _stripe_texture() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var band: bool = ((x + y) / 4) % 2 == 0
			img.set_pixel(x, y, Color(1.0, 0.8, 0.05) if band else Color(0.04, 0.04, 0.04))
	return ImageTexture.create_from_image(img)


# ══════════════════════════════════════════════════════════════════════════════
#  Runner effects
# ══════════════════════════════════════════════════════════════════════════════

func _ensure_player_fx(player: Node3D) -> void:
	if _shock_sparks != null and is_instance_valid(_shock_sparks):
		return
	_shock_sparks = _sparks(46, 0.55, 3.0, 7.5, Color(0.75, 0.9, 1.0), 9.0)
	_shock_sparks.name = "ShockSparks"
	player.add_child(_shock_sparks)
	_graze_sparks = _sparks(14, 0.30, 1.5, 3.5, Color(0.45, 0.8, 1.0), 6.0)
	_graze_sparks.name = "GrazeSparks"
	player.add_child(_graze_sparks)

	var smoke := CPUParticles3D.new()
	smoke.name = "ShockSmoke"
	smoke.one_shot = true
	smoke.emitting = false
	smoke.amount = 18
	smoke.lifetime = 1.6
	smoke.explosiveness = 0.35
	smoke.local_coords = false
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = 0.35
	smoke.direction = Vector3.UP
	smoke.spread = 25.0
	smoke.initial_velocity_min = 0.5
	smoke.initial_velocity_max = 1.3
	smoke.gravity = Vector3(0.0, 0.6, 0.0)
	smoke.scale_amount_min = 0.5
	smoke.scale_amount_max = 0.9
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.4))
	grow.add_point(Vector2(1.0, 1.6))
	smoke.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.55, 0.6, 0.7, 0.55))
	ramp.set_color(1, Color(0.3, 0.32, 0.36, 0.0))
	smoke.color_ramp = ramp
	var qm := QuadMesh.new()
	qm.size = Vector2(0.6, 0.6)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_dot()
	# A little emission, or in the dark the smoke is invisible.
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.3, 0.4)
	mat.emission_energy_multiplier = 0.5
	qm.material = mat
	smoke.mesh = qm
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smoke.position = Vector3(0.0, 0.9, 0.0)
	_shock_smoke = smoke
	player.add_child(smoke)


func _sparks(amount: int, life: float, vmin: float, vmax: float, col: Color,
		energy: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	p.explosiveness = 0.95
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.35
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = vmin
	p.initial_velocity_max = vmax
	p.gravity = Vector3(0.0, -9.0, 0.0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var m := BoxMesh.new()
	m.size = Vector3(0.025, 0.025, 0.14)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = energy
	m.material = mat
	p.mesh = m
	p.particle_flag_align_y = true
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(0.0, 0.9, 0.0)
	return p


static var _soft_dot_tex: ImageTexture = null

## A soft round blob, shared by every smoke particle in the zone.
static func _soft_dot() -> ImageTexture:
	if _soft_dot_tex != null:
		return _soft_dot_tex
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d: float = Vector2(x - 15.5, y - 15.5).length() / 15.5
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	_soft_dot_tex = ImageTexture.create_from_image(img)
	return _soft_dot_tex


# ══════════════════════════════════════════════════════════════════════════════
#  Sound synthesis — everything is generated, nothing ships as a file
# ══════════════════════════════════════════════════════════════════════════════

func _build_audio() -> void:
	_hum = _player(_gen_hum(), -80.0)
	_whine = _player(_gen_whine(), -80.0)
	_snap = _player(_gen_snap(), -11.0)
	_zap = _player(_gen_zap(), -3.0)
	_graze_sfx = _player(_gen_crackle(0.16, 0.7), -15.0)
	_surge_sfx = _player(_gen_crackle(0.22, 0.45), -19.0)
	_sky_sfx = _player(_gen_crackle(0.45, 0.35), -20.0)
	_rumble = _player(_gen_rumble(), -22.0)
	var clunk: AudioStreamWAV = _gen_clunk()
	for i in 4:
		_clunks.append(_player(clunk, -12.0))


func _player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.bus = _zone_bus()
	add_child(p)
	return p


## Every electric-zone sound plays through one bus of its own, which sends into
## SFX — so the player's SFX volume and mute still apply on top, and the whole
## zone's level is this one number.
const ZONE_BUS: String = "ElecZone"
## The zone's overall level, as linear gain. 0.35 = 65% quieter than authored.
const ZONE_GAIN: float = 0.35

func _zone_bus() -> String:
	var idx: int = AudioServer.get_bus_index(ZONE_BUS)
	if idx < 0:
		if AudioServer.get_bus_index("SFX") < 0:
			return "Master"
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, ZONE_BUS)
		AudioServer.set_bus_send(idx, "SFX")
	AudioServer.set_bus_volume_db(idx, linear_to_db(ZONE_GAIN))
	return ZONE_BUS


func _wav(s: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	return w


## Mains hum: 50 Hz and its harmonics, a soft-clipped 100 Hz buzz on top, a
## slow throb, and sparse crackle. Four seconds, every component a whole
## number of cycles, so the loop point is seamless.
func _gen_hum() -> AudioStreamWAV:
	var n: int = SR * 4
	var s := PackedFloat32Array()
	s.resize(n)
	var pops: Array[Vector2] = []  # (start sample, strength)
	for k in 22:
		pops.append(Vector2(randi() % n, randf_range(0.2, 0.6)))
	for i in n:
		var t: float = float(i) / float(SR)
		var v: float = 0.34 * sin(TAU * 50.0 * t) \
			+ 0.22 * sin(TAU * 100.0 * t + 0.4) \
			+ 0.12 * sin(TAU * 150.0 * t + 1.1) \
			+ 0.07 * sin(TAU * 250.0 * t + 2.0)
		v += 0.16 * tanh(4.0 * sin(TAU * 100.0 * t))
		v *= 0.82 + 0.18 * sin(TAU * 0.5 * t)
		s[i] = v * 0.7
	for p: Vector2 in pops:
		var st: int = int(p.x)
		for j in 90:
			var idx: int = (st + j) % n
			s[idx] += randf_range(-1.0, 1.0) * p.y * exp(-float(j) / 18.0)
	return _wav(s, true)


## A charging whine. Pitch is swept by the player's pitch_scale, not baked in.
func _gen_whine() -> AudioStreamWAV:
	var n: int = SR
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		var vib: float = 0.004 * sin(TAU * 6.0 * t)
		var v: float = 0.55 * sin(TAU * 880.0 * (t + vib)) \
			+ 0.25 * sin(TAU * 1320.0 * (t + vib)) \
			+ 0.12 * sin(TAU * 1760.0 * t)
		v += randf_range(-0.06, 0.06)
		s[i] = v * 0.6
	return _wav(s, true)


## A gate striking to full: sharp crack and a short body.
func _gen_snap() -> AudioStreamWAV:
	var n: int = int(0.26 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var prev: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var noise: float = randf_range(-1.0, 1.0)
		var hp: float = noise - prev   # crude high-pass: brighter crack
		prev = noise
		var crack: float = hp * exp(-t * 38.0) * 0.8
		var body: float = sin(TAU * 120.0 * t) * exp(-t * 18.0) * 0.45
		var buzz: float = tanh(5.0 * sin(TAU * 60.0 * t)) * exp(-t * 12.0) * 0.18
		s[i] = crack + body + buzz
	return _wav(s, false)


## Electrocution: a hard buzz chopped by crackle, falling off over half a second.
func _gen_zap() -> AudioStreamWAV:
	var n: int = int(0.62 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var gate: float = 1.0
	var prev: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = t / 0.62
		var env: float = pow(1.0 - f, 1.4)
		if i % 160 == 0:
			gate = 1.0 if randf() < 0.7 else 0.25
		var buzz: float = tanh(7.0 * sin(TAU * 60.0 * t)) * 0.45 \
			+ tanh(4.0 * sin(TAU * 180.0 * t + 0.3)) * 0.22
		var noise: float = randf_range(-1.0, 1.0)
		var hp: float = noise - prev
		prev = noise
		var hiss: float = hp * 0.55 * exp(-t * 6.0)
		var hit: float = sin(TAU * 70.0 * t) * exp(-t * 22.0) * 0.6
		s[i] = (buzz * gate + hiss) * env + hit
	return _wav(s, false)


## Sparse electrical crackle, `dur` seconds long.
func _gen_crackle(dur: float, density: float) -> AudioStreamWAV:
	var n: int = int(dur * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var i: int = 0
	while i < n:
		if randf() < density * 0.02:
			var len_s: int = randi_range(30, 140)
			var amp: float = randf_range(0.3, 0.9)
			for j in len_s:
				if i + j >= n:
					break
				var f: float = float(i + j) / float(n)
				s[i + j] += randf_range(-1.0, 1.0) * amp * exp(-float(j) / 25.0) * (1.0 - f)
			i += len_s
		else:
			i += 8
	return _wav(s, false)


## Distant thunder: low filtered noise that swells and rolls off over a second
## and a half. Played for far-off strikes, which have no crackle of their own.
func _gen_rumble() -> AudioStreamWAV:
	var n: int = int(1.5 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp1: float = 0.0
	var lp2: float = 0.0
	for i in n:
		var t: float = float(i) / float(SR)
		var f: float = t / 1.5
		# Two one-pole low-passes in series: noise down to a rumble.
		lp1 += (randf_range(-1.0, 1.0) - lp1) * 0.035
		lp2 += (lp1 - lp2) * 0.035
		var env: float = clampf(t / 0.12, 0.0, 1.0) * pow(1.0 - f, 1.8)
		var roll: float = 0.75 + 0.25 * sin(TAU * 3.1 * t + sin(TAU * 0.7 * t) * 2.0)
		s[i] = lp2 * 9.0 * env * roll
	return _wav(s, false)


## A breaker tripping: a click, a dull mechanical thunk and a short ring.
func _gen_clunk() -> AudioStreamWAV:
	var n: int = int(0.22 * SR)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t: float = float(i) / float(SR)
		var click: float = randf_range(-1.0, 1.0) * exp(-t * 400.0) * 0.8
		var thunk: float = sin(TAU * 68.0 * t) * exp(-t * 26.0) * 0.75
		var ring: float = sin(TAU * 1420.0 * t) * exp(-t * 45.0) * 0.12
		s[i] = click + thunk + ring
	return _wav(s, false)
