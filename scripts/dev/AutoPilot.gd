extends Node

## TEMPORARY — part of the DevTools testing console. Delete with it.
##
## Plays the runner section by itself. It goes through the player's own
## request_action() — the same entry point the controls use — so the runner
## animates exactly as if someone were playing, the gates judge him exactly as
## they judge a player, and the HUD shows real hits and real misses. Nothing in
## judging is bypassed except in the charge tunnel, where it steers him along
## the hoop line because there is no button press to make there.
##
## Where the song offers a choice, he takes the special move: grind rails over
## the gates beneath them (see _grind), the sparks on the descent ramp, the
## hoop line in the charge tunnel. Wall-jump climbs are played from their
## ledges (see _wall_jumps).
##
## ── Skill ────────────────────────────────────────────────────────────────────
## DevTools.autoplay_skill picks a level from God (0) to Noob (4). Every gate
## gets a plan the first time it comes into view, decided once so it cannot
## flicker between frames:
##   * a timing error, drawn from the level's spread — late or early presses
##     that a jump or slide window may or may not forgive
##   * a chance to fumble the gate outright: no press, a badly mistimed press,
##     or (lane gates) the wrong lane
##   * how early lane changes start — a slow reader can arrive too late
## God has zero error, zero fumbles and the earliest lane read: a perfect run.

var section: Node = null

## Per level, God .. Noob.
const FUMBLE:    PackedFloat32Array = [0.00, 0.02, 0.07, 0.15, 0.30]
const TIMING_SD: PackedFloat32Array = [0.00, 0.02, 0.045, 0.07, 0.11]
## Seconds before the beat a lane change starts. The game grades a lane press
## against 0.10 s before the beat (Section_BeatRunner3d._GRADE_LANE_LEAD_S), so
## God sits right on it; the others drift off it the way a person would.
const LANE_LEAD: PackedFloat32Array = [0.12, 0.16, 0.22, 0.28, 0.21]
var _skill: int = 0
const WJ_NONE: int = 0
const WJ_STEER: int = 1   # owns the steering only
const WJ_ALL: int = 2     # owns everything

var _wj_launched: Dictionary = {}   # wall-jump slot -> true once jumped from (or given up)
var _wj_base_y: float = NAN         # his standing height at the foot of the climb
var _grind_held: bool = false       # whether we are holding the grind action down
var _acted: Dictionary = {}   # gate index -> true once its press has been made
var _plans: Dictionary = {}   # gate index -> {fumble: bool, offset: float, lane: int}


func _ready() -> void:
	name = "DevAutoPilot"
	# Physics order: decide before the player integrates this tick.
	process_physics_priority = -10
	_skill = clampi(int(DevTools.autoplay_skill), 0, FUMBLE.size() - 1)


func _plan(i: int, action: String, safe_lane: int, lanes: int) -> Dictionary:
	if _plans.has(i):
		return _plans[i]
	var fumble: bool = randf() < FUMBLE[_skill]
	var offset: float = randfn(0.0, TIMING_SD[_skill]) if TIMING_SD[_skill] > 0.0 else 0.0
	var lane: int = safe_lane
	if fumble:
		match action:
			"left", "right":
				# Half the time freeze, half the time pick a wrong lane.
				if randf() < 0.5 and lanes > 1:
					var others: Array[int] = []
					for l in lanes:
						if l != safe_lane:
							others.append(l)
					lane = others[randi() % others.size()]
				else:
					lane = -1   # does not move for this one
			"jump", "slide":
				# Half the time no press at all, half the time a press far off.
				if randf() < 0.5:
					offset = INF
				else:
					offset = (0.32 if randf() < 0.5 else -0.32)
	var p: Dictionary = {"fumble": fumble, "offset": offset, "lane": lane}
	_plans[i] = p
	return p


func _physics_process(_delta: float) -> void:
	if section == null or not is_instance_valid(section):
		return
	var p: Node = section.get("player")
	if p == null:
		return
	# Locks the real controls out for as long as the autopilot exists — set
	# before anything else, so not even the countdown frame lets a press in.
	p.set("dev_autopilot", true)
	if not bool(section.get("_level_started")) or bool(section.get("_paused")):
		return
	# Smash gate: mash. Runs before the input_disabled check below, because the
	# smash itself is what disables the normal controls for its window.
	var smash: Node = section.get("_smash")
	if smash != null and bool(smash.call("is_mashing")):
		_mash(smash, _delta)
		# Until the smash has taken his lane (he may still be finishing a wall
		# jump or the ramp), keep playing everything else as well.
		if bool(smash.get("_locked")):
			return
	else:
		_mash_acc = 0.0
	if bool(p.get("input_disabled")):
		return

	# The charge tunnel: no gates, just a weaving hoop line. Hold him on it,
	# less tightly the worse the player.
	if p.call("is_charge_sliding"):
		var pd0: float = float(section.get("_player_path_dist"))
		# The exact spot the section checks alignment at — it compares his
		# lateral with the hoop line at his own path distance, not ahead of it.
		var x: float = float(section.call("_gap_curve_x", pd0))
		x += sin(pd0 * 0.37) * 0.25 * float(_skill)
		var lim: float = float(p.get("_charge_max_lat"))
		p.set("_charge_lateral", clampf(x, -lim, lim))
		# The meter only fills while the grind button is HELD (and he is lined
		# up), and the payoff is best when it is let go right on the drop —
		# still holding at the drop only pays half. So: hold through the tunnel,
		# release on the drop, early or late by this player's timing error.
		var seg: Dictionary = section.get("_charge_seg")
		var drop_t: float = float(seg.get("end_t", 0.0))
		var pl: Dictionary = _plan_wall("ch%d" % int(drop_t * 10.0))
		var release_at: float = drop_t - 0.03 - float(pl["offset"])
		var t_now: float = float(section.call("_song_time"))
		var hold: bool = t_now < release_at and not bool(pl["skip"])
		if hold and not _grind_held:
			_set_hold(true)
			_grind_held = true
		elif not hold and _grind_held:
			_set_hold(false)
			_grind_held = false
		return

	var speed: float = maxf(float(p.get("forward_speed")), 0.1)
	var pd: float = float(section.get("_player_path_dist"))
	var zs: PackedFloat32Array = section.get("gate_world_zs")
	var judged: Array = section.get("gate_judged")
	var actions: PackedStringArray = section.get("gate_actions")
	var plan: Array = section.get("runner_plan")
	var depth: float = float(section.get("gate_depth"))
	var start: int = int(section.get("_judge_index"))
	var lanes: int = (p.get("lane_xs") as PackedFloat32Array).size() \
		if p.get("lane_xs") is PackedFloat32Array else 3

	# Jumps peak, and slides are at their middle, as the gate arrives — which is
	# also what the game grades as PERFECT.
	var air_s: float = 2.0 * float(p.get("jump_velocity")) / maxf(float(p.get("gravity")), 0.1)
	var slide_s: float = float(p.get("slide_duration"))

	if _grind(p, pd, speed):
		return
	var wj: int = _wall_jumps(p, pd, speed)
	if wj == WJ_ALL:
		return

	# On the climb's runway the climb logic owns the steering (the runway is one
	# lane wide), but a jump or slide gate placed there still has to be played.
	var lane_set: bool = wj == WJ_STEER
	for i in range(start, mini(start + 8, zs.size())):
		if i >= judged.size() or bool(judged[i]):
			continue
		var ahead: float = zs[i] - pd
		if ahead < -depth:
			continue
		var t_to: float = ahead / speed
		if t_to > 1.5:
			break
		var action: String = String(actions[i]) if i < actions.size() else ""
		var safe: int = int((plan[i] as Dictionary).get("post_lane", 1))
		var pl: Dictionary = _plan(i, action, safe, lanes)
		var off: float = float(pl["offset"])
		match action:
			"left", "right":
				# Only the nearest lane gate steers him, once it is close enough
				# for this level of player to have read it.
				if not lane_set and t_to <= LANE_LEAD[_skill] + minf(off, 0.0):
					lane_set = true
					var want: int = int(pl["lane"])
					if want >= 0:
						_steer_to(p, want)
			"jump":
				if not _acted.has(i) and is_finite(off) \
						and t_to <= air_s * 0.5 + off and p.call("is_on_floor"):
					_acted[i] = true
					p.call("request_action", "jump")
			"slide":
				if not _acted.has(i) and is_finite(off) and t_to <= slide_s * 0.5 + off:
					if p.call("is_on_floor") and float(p.get("slide_cooldown_timer")) <= 0.0:
						_acted[i] = true
						p.call("request_action", "slide")
			# Wall gates are not played from here — see _wall_jumps(). They are
			# judged on LANDING, so by the time a ledge's jump is due its gate
			# has already been marked and dropped out of this list.
		# Only the very next press matters for timing-critical gates; a lane
		# gate further on can still be looked at for steering.
		if action in ["jump", "slide"] and not _acted.has(i) and is_finite(off):
			break


## The wall-jump climb, played from its ledges rather than its gates.
##
## The geometry tunes the wall-jump launch speed so that leaving slot k at
## slot k's own path distance lands exactly on slot k+1 — so the right moment
## to press is "standing on ledge k, at ledge k". That is when he lands from the
## jump before, which is why it cannot be driven from the gate list (the gate
## for ledge k is judged on that landing and is gone by then).
##
## Returns WJ_ALL while he is inside the climb, so the gate loop stays out of
## it; WJ_STEER on the runway before the first ledge, where it only owns the
## steering; WJ_NONE elsewhere.
func _wall_jumps(p: Node, pd_tracked: float, speed: float) -> int:
	var zs: Array = section.get("_wj_slot_zs")
	if zs.is_empty():
		return WJ_NONE
	# His position projected onto the path right now. The section's tracked
	# distance only updates once per rendered frame, so after a hitch several
	# physics steps in a row all read the same stale value.
	var pd: float = float(section.call("_path_dist_of_player_unclamped")) \
		if section.has_method("_path_dist_of_player_unclamped") else pd_tracked
	var acts: Array = section.get("_wj_slot_acts")
	var half: float = float(section.get("_wj_ledge_half_z"))
	var max_lane: int = (p.get("lane_xs") as PackedFloat32Array).size() - 1
	var n: int = zs.size()
	var top_z: float = float(section.get("_wj_climb_top_z"))
	var slide_z: float = float(section.get("_wj_slide_start_z"))

	# Before the climb: be in the take-off lane for the first jump by the time
	# he reaches the approach runway (the chart's own lane gates lead there too).
	if pd < float(zs[0]) - 12.0:
		return WJ_NONE
	var take_off: int = 0 if String(acts[0]) == "wall_left" else max_lane
	if pd < float(zs[0]) - 6.0:
		_steer_to(p, take_off)
		return WJ_STEER
	if not _wj_launched.has(0):
		_steer_to(p, take_off)   # the runway is one lane wide

	# On the platform at the top: line up with the one way down, and stay in
	# that lane the whole way down it — the ramp is one lane wide over a void,
	# so a lane gate further on must not pull him off its side.
	if pd >= top_z - 1.0:
		var slide_end: float = float(section.get("_wj_slide_end_z"))
		if pd < maxf(slide_z + 2.0, slide_end + 1.0):
			var ramp: int = int(section.get("_wj_ramp_lane"))
			if ramp >= 0:
				_steer_to(p, ramp)
			return WJ_ALL
		return WJ_NONE

	# The next ledge he has not jumped from yet. One he has already overshot
	# (fell, or a late landing past its far end) is given up on.
	var k: int = -1
	for s in n:
		if _wj_launched.has(s):
			continue
		if pd > float(zs[s]) + half:
			_wj_launched[s] = true
			continue
		k = s
		break
	if k < 0:
		return WJ_ALL

	var key: String = "wj%d" % k
	var pl: Dictionary = _plan_wall(key)
	var on_floor: bool = p.call("is_on_floor")
	var y: float = (p as Node3D).global_position.y
	if k == 0 and on_floor:
		_wj_base_y = y   # standing height on the runway = height 0 of the climb
	var buffered: bool = false
	if not on_floor:
		# Coming down onto ledge k: a press now is held by the game's wall-jump
		# buffer and fires on the landing tick itself. Waiting to see the floor
		# first costs a physics step or two of sliding forward before take-off.
		var vy: float = (p as CharacterBody3D).velocity.y
		if k == 0 or vy >= 0.0 or is_nan(_wj_base_y) or _skill >= 3:
			return WJ_ALL   # beginners and noobs do not buffer
		var hts: Array = section.get("_wj_slot_heights")
		var h: float = y - (_wj_base_y + float(hts[k]))
		if h < -0.3:
			return WJ_ALL   # below the ledge: falling past it, nothing to press for
		var gg: float = maxf(float(p.get("gravity")), 0.1)
		var t_land: float = (vy + sqrt(maxf(vy * vy + 2.0 * gg * maxf(h, 0.0), 0.0))) / gg
		if t_land > 0.12:
			return WJ_ALL
		buffered = true

	# Aim the LANDING, not the take-off. The geometry tunes the jump for the
	# nominal forward speed, but his real speed drifts (the song sync speeds
	# him up or slows him down to stay on the music, hardest after a hitch),
	# and a jump that travels a metre or two further than planned sails off
	# the far end of the next ledge. So: how long will this jump be in the air
	# before it comes down to the next surface, how far will he go in that
	# time at the speed he is actually doing, and does that land on target?
	var heights: Array = section.get("_wj_slot_heights")
	var step: float = 0.0
	var target: float = top_z + 3.0               # last jump: onto the platform
	if k + 1 < n:
		step = float(heights[k + 1]) - float(heights[k])
		# The near part of the next ledge, not its middle. When his jumps run
		# long, every one lands a little further along than the last (he can
		# only push off once he is down), and aiming at the middle used that
		# slack up by the fifth ledge. Aiming short leaves room for it.
		target = float(zs[k + 1]) - half * 0.6
	var v: float = float(p.get("wall_jump_velocity"))
	var g: float = maxf(float(p.get("gravity")), 0.1)
	var disc: float = maxf(v * v - 2.0 * g * step, 0.0)
	var air_t: float = (v + sqrt(disc)) / g       # the descending crossing
	var real_speed: float = speed * maxf(float(p.get("sync_speed_scale")), 0.1)
	var from_pd: float = pd
	if buffered:
		from_pd = pd + real_speed * 0.06   # roughly where he touches down
	var lands_at: float = from_pd + real_speed * air_t
	# Timing error in metres: positive offset = early, as everywhere else here.
	var early_m: float = float(pl["offset"]) * real_speed
	if lands_at + early_m < target:
		# Still on the runway before the first take-off: gates there still count.
		return WJ_STEER if k == 0 else WJ_ALL
	_wj_launched[k] = true
	if bool(pl["skip"]):
		return WJ_ALL   # froze: stands there and runs off the end of the ledge
	var a: String = String(acts[k])
	if bool(pl["wrong"]):
		a = "wall_right" if a == "wall_left" else "wall_left"
	p.call("request_action", a)
	return WJ_ALL


## Grind rails, and the spark taps on the wall-jump descent ramp.
##
## Where the song offers a rail, he always takes it: the rail is the special
## move, the gates under it are the default. Holding the grind button while on
## the floor near the rail is what mounts it (BeatRunnerPlayer), so the hold
## goes through Input like a real press, and nothing jumps or slides him off
## the floor while he is waiting to get on. Once on, each spark is tapped on
## its beat — with the same timing error and fumbles as every other press.
##
## Returns true while the rail owns him, so the gate logic stays out of it.
func _grind(p: Node, pd: float, speed: float) -> bool:
	var avail: bool = bool(p.get("_grind_rail_available"))
	var grinding: bool = bool(p.call("is_grinding"))
	var descent: bool = p.has_method("is_wj_descent") and bool(p.call("is_wj_descent"))

	var want_hold: bool = (avail and not grinding) or grinding or descent
	if want_hold and not _grind_held:
		_set_hold(true)
		_grind_held = true
	elif not want_hold and _grind_held:
		_set_hold(false)
		_grind_held = false

	if grinding:
		_tap_sparks(p, pd, speed, "_spark_tap_pds", "_spark_caught", "grind_tap_pressed", "g")
		return true
	if descent:
		_tap_sparks(p, pd, speed, "_desc_spark_pds", "_desc_spark_caught", "descent_tap_pressed", "d")
		return false   # the wall-jump logic still keeps him in the ramp lane
	# Waiting to mount: stay planted. Steering is still allowed, presses are not.
	return avail


func _tap_sparks(p: Node, pd: float, speed: float, pds_name: String,
		caught_name: String, sig: String, tag: String) -> void:
	var pds: Array = section.get(pds_name)
	var caught: Array = section.get(caught_name)
	for i in mini(pds.size(), caught.size()):
		if bool(caught[i]):
			continue
		var spd: float = float(pds[i])
		var key: String = "%s%d" % [tag, int(spd * 10.0)]
		if _acted.has(key):
			continue
		if spd < pd - speed * 0.25:
			continue   # long gone
		var pl: Dictionary = _plan_wall(key)   # same shape: offset + fumble
		if pd < spd - float(pl["offset"]) * speed:
			return   # the next one is not due yet
		_acted[key] = true
		if not bool(pl["skip"]) and not bool(pl["wrong"]):
			p.emit_signal(sig)
		return


func _exit_tree() -> void:
	_set_hold(false)
	_grind_held = false
	var p: Node = section.get("player") if section != null and is_instance_valid(section) else null
	if p != null:
		p.set("dev_autopilot", false)


## The grind button, held or let go — as the player's virtual hold, never as a
## real input event, so it cannot mix with whatever the keyboard is doing.
func _set_hold(on: bool) -> void:
	if section == null or not is_instance_valid(section):
		return
	var p: Node = section.get("player")
	if p != null:
		p.set("dev_grind_hold", on)


func _plan_wall(key: String) -> Dictionary:
	if _plans.has(key):
		return _plans[key]
	var fumble: bool = randf() < FUMBLE[_skill]
	var p: Dictionary = {
		"offset": randfn(0.0, TIMING_SD[_skill]) if TIMING_SD[_skill] > 0.0 else 0.0,
		"skip": fumble and randf() < 0.5,
		"wrong": false,
	}
	p["wrong"] = fumble and not bool(p["skip"])
	_plans[key] = p
	return p


## Mash speed as a fraction of the smash target, God .. Noob. God beats the
## target (no damage), Pro scrapes past it, Average falls just short, and the
## rest pay for it.
const MASH_FACTOR: PackedFloat32Array = [1.35, 1.12, 0.92, 0.72, 0.48]
var _mash_acc: float = 0.0


func _mash(smash: Node, delta: float) -> void:
	var info: Dictionary = smash.call("active_info")
	if info.is_empty():
		return
	var dur: float = maxf(float(info["t1"]) - float(info["t0"]), 0.1)
	var rate: float = float(info["target"]) / dur * MASH_FACTOR[_skill]
	# A little unevenness per press, more for worse players — fingers, not a clock.
	_mash_acc += delta * rate * randf_range(1.0 - 0.08 * float(_skill + 1), 1.0 + 0.08 * float(_skill + 1))
	while _mash_acc >= 1.0:
		_mash_acc -= 1.0
		smash.call("press")


func _steer_to(p: Node, lane: int) -> void:
	var guard: int = 0
	while int(p.get("target_lane")) != lane and guard < 6:
		guard += 1
		# request_action("left") steps the lane index DOWN, "right" steps it UP.
		if int(p.get("target_lane")) > lane:
			p.call("request_action", "left")
		else:
			p.call("request_action", "right")
