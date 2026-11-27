extends Node
class_name ReplayMoments

## The run's best moment, replayed in slow motion behind the results.
##
## While he runs, the last few seconds are kept in a ring: his whole skeleton
## pose, where he is, and where the camera is, thirty times a second. The big
## moments call mark() with how big they were — a smash, a clean overdrive
## drop, the top of a climb, FEVER, a long PERFECT chain — and the biggest one
## keeps a clip of the seconds around it. When the results open, a camera of
## its own plays that clip back at a third of the speed, looping, with every
## sample blended into the next so it stays smooth that slowly.
##
## Only Meeko and the camera are replayed; the world is whatever stands there
## now. Gates he passed have been put away, so the moment plays on a clean
## track — which reads as a highlight rather than as a recording.

const RATE: float = 30.0
const KEEP_S: float = 6.0
const BEFORE_S: float = 2.0
const AFTER_S: float = 1.6
const PLAY_SPEED: float = 0.35

var section: Node = null
var player: Node3D = null
var _skel: Skeleton3D = null
var _root: Node3D = null      # the character's root (lean, bob)
var _model: Node3D = null     # the model inside it (jolts)
var _nb: int = 0

var _ring: Array[Dictionary] = []
var _acc: float = 0.0
var _pending: Dictionary = {}     # {score, label, t}
var clip: Array[Dictionary] = []
var clip_score: float = -1.0
var clip_label: String = ""

var _playing: bool = false
var _play_t: float = 0.0
var _cam: Camera3D = null
var _tag: Label = null

# The world in the moment. Gates, smash walls and the charge tunnel are put
# away as he passes them; for the replay they are put back as they were and
# taken away again as the replayed Meeko goes through each one.
var _snap_cursor: int = 0
var _gate_snaps: Dictionary = {}     # gate index -> {mats, tints, energies}
var _smash_snaps: Dictionary = {}    # gate index -> Array of [block, Transform3D]
var _smash_mat_snaps: Dictionary = {} # gate index -> Array of [Material, tint, energy]
var _tunnels: Array[Dictionary] = [] # {root, start_pd, spacing}
var _shown_gates: Array[int] = []
var _shown_tunnels: Array[Dictionary] = []
var _pd_now: float = 0.0


func _init() -> void:
	name = "ReplayMoments"


func setup(p_section: Node) -> void:
	section = p_section
	player = section.get("player") as Node3D
	_skel = player.get("_char_skeleton") as Skeleton3D
	_root = player.get("_char_root") as Node3D
	_model = player.get("_char_model") as Node3D
	if _skel != null:
		_nb = _skel.get_bone_count()


## A moment worth keeping, scored by how big it was. The clip is cut once the
## seconds after it have been recorded too.
func mark(score: float, label: String, t_s: float) -> void:
	if score <= clip_score:
		return
	if not _pending.is_empty() and score <= float(_pending["score"]):
		return
	_pending = {"score": score, "label": label, "t": t_s}


func record(delta: float, t_s: float) -> void:
	if _playing or _skel == null:
		return
	_acc += delta
	if _acc < 1.0 / RATE:
		return
	_acc = 0.0
	var cam: Camera3D = section.get_viewport().get_camera_3d()
	if cam == null:
		return
	var bones := PackedFloat32Array()
	bones.resize(_nb * 10)
	for b in _nb:
		var p: Vector3 = _skel.get_bone_pose_position(b)
		var q: Quaternion = _skel.get_bone_pose_rotation(b)
		var s: Vector3 = _skel.get_bone_pose_scale(b)
		var o: int = b * 10
		bones[o] = p.x; bones[o + 1] = p.y; bones[o + 2] = p.z
		bones[o + 3] = q.x; bones[o + 4] = q.y; bones[o + 5] = q.z; bones[o + 6] = q.w
		bones[o + 7] = s.x; bones[o + 8] = s.y; bones[o + 9] = s.z
	_snapshot_ahead()
	_ring.append({"t": t_s, "pd": float(section.get("_player_path_dist")), "xf": player.global_transform,
		"root": _root.transform if _root != null else Transform3D.IDENTITY,
		"model": _model.transform if _model != null else Transform3D.IDENTITY,
		"cam": cam.global_transform, "fov": cam.fov, "bones": bones})
	while not _ring.is_empty() and t_s - float(_ring[0]["t"]) > KEEP_S:
		_ring.pop_front()
	if not _pending.is_empty() and t_s >= float(_pending["t"]) + AFTER_S:
		_cut()


func _cut() -> void:
	if _pending.is_empty():
		return
	var t0: float = float(_pending["t"]) - BEFORE_S
	var out: Array[Dictionary] = []
	for smp: Dictionary in _ring:
		if float(smp["t"]) >= t0:
			out.append(smp)
	if out.size() >= 8:
		clip = out
		clip_score = float(_pending["score"])
		clip_label = String(_pending["label"])
	_pending = {}


## Remembers how each gate and smash wall looks before he gets to it — once,
## well ahead of him, before a hit, a miss, FEVER's gold or a shatter changes it.
func _snapshot_ahead() -> void:
	var zs: Array = section.get("gate_world_zs")
	var mats_all: Array = section.get("_gate_cycle_mats")
	var acts: Array = section.get("gate_actions")
	var pd: float = float(section.get("_player_path_dist"))
	while _snap_cursor < zs.size() and float(zs[_snap_cursor]) < pd + 150.0:
		var i: int = _snap_cursor
		_snap_cursor += 1
		if float(zs[i]) < pd - 2.0:
			continue   # already behind him (a practice start): nothing to keep
		if i < mats_all.size():
			var mats: Array = (mats_all[i] as Array).duplicate()
			var tints: Array = []
			var es: Array = []
			for m: Material in mats:
				tints.append(NeonMat.get_tint(m) if m != null else Color.WHITE)
				es.append(NeonMat.get_energy(m) if m != null else 0.0)
			_gate_snaps[i] = {"mats": mats, "tints": tints, "energies": es}
		if i < acts.size() and String(acts[i]) == "smash":
			var smash: Node = section.get("_smash")
			if smash != null:
				for sm: Dictionary in (smash.get("_smashes") as Array):
					if int(sm["gi"]) == i and sm.has("vis") and not (sm["vis"] as Dictionary).is_empty():
						var list: Array = []
						for b: Node3D in ((sm["vis"] as Dictionary)["blocks"] as Array):
							list.append([b, b.transform])
						_smash_snaps[i] = list
						# The wall's own neon, which the mash pumps and the shatter kills.
						var mlist: Array = []
						for m: Variant in ((sm["vis"] as Dictionary).get("block_mats", []) as Array):
							if m is Material:
								mlist.append([m, NeonMat.get_tint(m), NeonMat.get_energy(m)])
						_smash_mat_snaps[i] = mlist


## The section hands over each charge tunnel as it ends instead of freeing it.
## The last two are kept, hidden.
func keep_tunnel(root: Node3D, start_pd: float, spacing: float) -> void:
	root.visible = false
	_tunnels.append({"root": root, "start_pd": start_pd, "spacing": spacing})
	while _tunnels.size() > 2:
		var old: Node3D = _tunnels.pop_front()["root"]
		if is_instance_valid(old):
			old.queue_free()


func has_clip() -> bool:
	if not _pending.is_empty():
		_cut()
	return clip.size() >= 8


## Starts the loop: freezes the real runner, takes over the view with a camera
## of its own, and labels the moment.
func play(label_host: Control) -> void:
	if not has_clip() or _playing:
		return
	_playing = true
	_play_t = 0.0
	player.process_mode = Node.PROCESS_MODE_DISABLED
	# ...but the skeleton has to keep applying the poses set on it.
	_skel.process_mode = Node.PROCESS_MODE_ALWAYS
	var anim: AnimationPlayer = player.get("_char_anim_player") as AnimationPlayer
	if anim != null:
		anim.pause()
	_cam = Camera3D.new()
	_cam.name = "ReplayCam"
	section.add_child(_cam)
	var live: Camera3D = section.get_viewport().get_camera_3d()
	if live != null:
		_cam.near = live.near
		_cam.far = live.far
		_cam.environment = live.environment
		_cam.attributes = live.attributes
	_cam.current = true
	for n: String in ["_flair", "_fever"]:
		var o: Object = section.get(n)
		if o != null and o.has_method("hide_overlays"):
			o.call("hide_overlays")
	var hud: Object = section.get("_hud")
	if hud != null and hud.has_method("set_readouts_visible"):
		hud.call("set_readouts_visible", false)
	if label_host != null:
		var vp: Vector2 = section.get_viewport().get_visible_rect().size
		var sc: float = UiStyle.scale_for(vp)
		_tag = UiStyle.label("REPLAY  ·  " + clip_label, UiStyle.caption(6.0), int(20 * sc), Color.WHITE)
		_tag.self_modulate = Color(1.0, 0.92, 0.6, 1.0)
		_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Over the left of the screen, where the moment plays.
		_tag.position = Vector2(vp.x * 0.04, vp.y * 0.12)
		_tag.size = Vector2(vp.x * 0.36, 30.0 * sc)
		_tag.z_index = 50
		label_host.add_child(_tag)
	_restore_world()
	_apply(0.0)


## Puts back everything in the moment's stretch of track as it was before he
## reached it. _apply() then takes each piece away again as he passes it.
func _restore_world() -> void:
	var lo: float = INF
	var hi: float = -INF
	for smp: Dictionary in clip:
		lo = minf(lo, float(smp["pd"]))
		hi = maxf(hi, float(smp["pd"]))
	lo -= 2.0
	hi += 90.0
	var zs: Array = section.get("gate_world_zs")
	var nodes: Array = section.get("gate_nodes")
	for i in mini(zs.size(), nodes.size()):
		var z: float = float(zs[i])
		if z < lo:
			continue
		if z > hi:
			break
		var gate: Node3D = nodes[i]
		if gate == null or not is_instance_valid(gate) or gate.has_meta("wj_culled"):
			continue
		_shown_gates.append(i)
		if _gate_snaps.has(i):
			var sn: Dictionary = _gate_snaps[i]
			var mats: Array = sn["mats"]
			for j in mats.size():
				if mats[j] != null:
					NeonMat.set_tint(mats[j], sn["tints"][j])
					NeonMat.set_energy(mats[j], float(sn["energies"][j]))
		if _smash_snaps.has(i):
			for pair: Array in (_smash_snaps[i] as Array):
				var b: Node3D = pair[0]
				if is_instance_valid(b):
					b.transform = pair[1]
		if _smash_mat_snaps.has(i):
			for mt: Array in (_smash_mat_snaps[i] as Array):
				NeonMat.set_tint(mt[0], mt[1])
				NeonMat.set_energy(mt[0], float(mt[2]))
	for tn: Dictionary in _tunnels:
		var root: Node3D = tn["root"]
		if not is_instance_valid(root):
			continue
		var n: int = root.get_child_count()
		var t_lo: float = float(tn["start_pd"])
		var t_hi: float = t_lo + float(n) * float(tn["spacing"])
		if t_hi < lo or t_lo > hi:
			continue
		root.visible = true
		# The cinema left each hoop dimmed or flashed; light them all evenly.
		for mi: Node in root.find_children("*", "MeshInstance3D", true, false):
			var m: Material = (mi as MeshInstance3D).material_override
			if m is StandardMaterial3D:
				var sm3: StandardMaterial3D = m
				var hc: Color = Color(0.35, 0.82, 1.0)
				sm3.albedo_color = hc
				sm3.emission = hc
				sm3.emission_energy_multiplier = 2.2
		_shown_tunnels.append(tn)


## Each piece stands until the replayed Meeko has gone through it.
func _sync_world(pd: float) -> void:
	var zs: Array = section.get("gate_world_zs")
	var nodes: Array = section.get("gate_nodes")
	var acts: Array = section.get("gate_actions")
	for i: int in _shown_gates:
		var gate: Node3D = nodes[i]
		if not is_instance_valid(gate):
			continue
		var a: String = String(acts[i]) if i < acts.size() else ""
		# A smash wall goes the moment he hits it; a gate once he is through.
		var gone_at: float = float(zs[i]) + (-0.6 if a == "smash" else 0.9)
		var show: bool = pd < gone_at
		gate.visible = show
		gate.scale = Vector3.ONE
		var vis: Node3D = gate.get_node_or_null("VisRoot") as Node3D
		if vis != null:
			vis.visible = show
		if _smash_snaps.has(i):
			for pair: Array in (_smash_snaps[i] as Array):
				var b: Node3D = pair[0]
				if is_instance_valid(b):
					b.visible = show
	for tn: Dictionary in _shown_tunnels:
		var root: Node3D = tn["root"]
		if not is_instance_valid(root):
			continue
		var start: float = float(tn["start_pd"])
		var sp: float = float(tn["spacing"])
		for k in root.get_child_count():
			(root.get_child(k) as Node3D).visible = pd < start + float(k) * sp + 0.5


func _process(delta: float) -> void:
	update(delta)


func update(delta: float) -> void:
	if not _playing:
		return
	var span: float = float(clip[clip.size() - 1]["t"]) - float(clip[0]["t"])
	_play_t = fposmod(_play_t + delta * PLAY_SPEED, maxf(span + 0.4, 0.5))
	_apply(minf(_play_t, span))
	if _tag != null:
		_tag.modulate.a = 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.004)


func _apply(t: float) -> void:
	var t_abs: float = float(clip[0]["t"]) + t
	var i: int = 0
	while i < clip.size() - 2 and float(clip[i + 1]["t"]) < t_abs:
		i += 1
	var a: Dictionary = clip[i]
	var b: Dictionary = clip[mini(i + 1, clip.size() - 1)]
	var dt: float = float(b["t"]) - float(a["t"])
	var k: float = clampf((t_abs - float(a["t"])) / dt, 0.0, 1.0) if dt > 0.0001 else 0.0
	_pd_now = lerpf(float(a["pd"]), float(b["pd"]), k)
	_sync_world(_pd_now)
	player.global_transform = (a["xf"] as Transform3D).interpolate_with(b["xf"], k)
	if _root != null:
		_root.transform = (a["root"] as Transform3D).interpolate_with(b["root"], k)
	if _model != null:
		_model.transform = (a["model"] as Transform3D).interpolate_with(b["model"], k)
	_cam.fov = lerpf(float(a["fov"]), float(b["fov"]), k)
	# The recorded camera had him centred; the results card now covers the
	# centre, so turn the view right until he sits in the left third.
	var xf: Transform3D = (a["cam"] as Transform3D).interpolate_with(b["cam"], k)
	var vp: Vector2 = section.get_viewport().get_visible_rect().size
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var yaw: float = atan(0.55 * tan(deg_to_rad(_cam.fov) * 0.5) * aspect)
	xf.basis = xf.basis.rotated(xf.basis.y.normalized(), -yaw)
	_cam.global_transform = xf
	var ba: PackedFloat32Array = a["bones"]
	var bb: PackedFloat32Array = b["bones"]
	for n in _nb:
		var o: int = n * 10
		_skel.set_bone_pose_position(n, Vector3(ba[o], ba[o + 1], ba[o + 2]).lerp(
			Vector3(bb[o], bb[o + 1], bb[o + 2]), k))
		_skel.set_bone_pose_rotation(n, Quaternion(ba[o + 3], ba[o + 4], ba[o + 5], ba[o + 6]).slerp(
			Quaternion(bb[o + 3], bb[o + 4], bb[o + 5], bb[o + 6]), k))
		_skel.set_bone_pose_scale(n, Vector3(ba[o + 7], ba[o + 8], ba[o + 9]).lerp(
			Vector3(bb[o + 7], bb[o + 8], bb[o + 9]), k))
