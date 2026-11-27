extends Node
class_name FeverMode

## FEVER: a run of PERFECTs fills a meter; when it is full the next stretch of
## the song is a few seconds of double score with golden gates and a camera that
## rides the beat.
##
## It goes off on its own the moment the meter fills — there is no button for
## it, because every button is already a move and a rhythm game cannot ask for a
## free press in the middle of a pattern. It waits, full, while he is in the
## charge tunnel, on a rail, in a smash or on a climb, and starts as soon as he
## is back on the ordinary track.
##
## The section owns one: on_grade() for every graded hit, on_miss() for every
## miss, update() every frame, and reads `active`, multiplier(), fov_add and
## roll_deg back.

const DURATION_S: float = 7.0
## Meter per grade: 14 PERFECTs from empty, or 28 GREATs.
const GAIN: Array[float] = [1.0 / 14.0, 1.0 / 28.0, 0.0]
## A miss halves what is in the meter; it does not end a fever already running.
const MISS_KEEP: float = 0.5
const GOLD: Color = Color(1.0, 0.80, 0.25)
const GOLD_HOT: Color = Color(1.0, 0.93, 0.55)

var section: Node = null
var meter: float = 0.0
var active: bool = false
var time_left: float = 0.0
var fov_add: float = 0.0
var roll_deg: float = 0.0
var _k: float = 0.0              # 0..1 eased in/out of fever
var _gilded: Dictionary = {}     # gate index -> original tints (Array[Color])
var _vignette: ColorRect = null
var _vig_mat: ShaderMaterial = null
var _ready_flash: float = 0.0


func _init() -> void:
	name = "FeverMode"


func setup(p_section: Node) -> void:
	section = p_section


func on_grade(g: int) -> void:
	if active or g < 0 or g >= GAIN.size():
		return
	var was: float = meter
	meter = minf(1.0, meter + GAIN[g])
	if was < 1.0 and meter >= 1.0:
		_ready_flash = 1.0


func on_miss() -> void:
	if not active:
		meter *= MISS_KEEP


func multiplier() -> int:
	return 2 if active else 1


func update(delta: float) -> void:
	if section == null:
		return
	var p: Node = section.get("player")
	if not active and meter >= 1.0 and _can_start(p):
		_start()
	if active:
		time_left -= delta
		meter = clampf(time_left / DURATION_S, 0.0, 1.0)
		_gild_ahead()
		if time_left <= 0.0:
			_end()
	_k = move_toward(_k, 1.0 if active else 0.0, delta * (2.5 if active else 1.6))
	var e: float = _k * _k * (3.0 - 2.0 * _k)
	var fs: float = GameConfig.flash_scale()
	# The camera rides the beat: a little wider, and rocking side to side once
	# per beat (left on one, right on the next), easing in and out with fever.
	fov_add = 5.0 * e
	var beat_i: int = int(section.get("_fever_beat_count"))
	var side: float = 1.0 if beat_i % 2 == 0 else -1.0
	roll_deg = lerpf(roll_deg, side * 1.6 * e * fs, clampf(delta * 7.0, 0.0, 1.0))
	_ready_flash = maxf(0.0, _ready_flash - delta * 2.0)
	_update_hud(e)


func _can_start(p: Node) -> bool:
	if p == null:
		return false
	if bool(p.call("is_charge_sliding")) or bool(p.call("is_grinding")):
		return false
	if float(section.get("_charge_mult_timer")) > 0.0:
		return false   # overdrive's ×100 already owns the score
	var smash: Node = section.get("_smash")
	if smash != null and bool(smash.call("is_mashing")):
		return false
	var top: float = float(section.get("_wj_climb_top_z"))
	var zs: float = float(section.get("_wj_zone_start_z"))
	var pd: float = float(section.get("_player_path_dist"))
	if top >= 0.0 and is_finite(zs) and pd >= zs - 10.0 and pd < float(section.get("_wj_slide_end_z")) + 4.0:
		return false
	return true


func _start() -> void:
	active = true
	time_left = DURATION_S
	var hud: Object = section.get("_hud")
	if hud != null and hud.has_method("show_callout"):
		hud.call("show_callout", "FEVER  ×2", GOLD, 0.9, 1.0)
	GameConfig.rumble(0.5, 0.8, 0.35)
	section.call("_fever_started")


func _end() -> void:
	active = false
	time_left = 0.0
	meter = 0.0
	# Gates still ahead go back to their own colours.
	var mats_all: Array = section.get("_gate_cycle_mats")
	var judged: Array = section.get("gate_judged")
	for idx: int in _gilded:
		if idx < judged.size() and bool(judged[idx]):
			continue
		if idx >= mats_all.size():
			continue
		var tints: Array = _gilded[idx]
		var mats: Array = mats_all[idx]
		for j in mini(mats.size(), tints.size()):
			if mats[j] != null:
				NeonMat.set_tint(mats[j], tints[j])
	_gilded.clear()


## Turns the gates he will reach before fever ends gold — and only those, so
## the colour also tells him where it stops.
func _gild_ahead() -> void:
	var zs: Array = section.get("gate_world_zs")
	var judged: Array = section.get("gate_judged")
	var acts: Array = section.get("gate_actions")
	var mats_all: Array = section.get("_gate_cycle_mats")
	var start: int = int(section.get("_judge_index"))
	var pd: float = float(section.get("_player_path_dist"))
	var p: Node = section.get("player")
	var reach: float = pd + time_left * float(p.get("forward_speed"))
	for i in range(start, zs.size()):
		if float(zs[i]) > reach:
			break
		if _gilded.has(i) or (i < judged.size() and bool(judged[i])):
			continue
		var a: String = String(acts[i]) if i < acts.size() else ""
		if not a in ["left", "right", "jump", "slide"] or i >= mats_all.size():
			continue
		var tints: Array = []
		for m: Material in (mats_all[i] as Array):
			if m == null:
				tints.append(Color.WHITE)
				continue
			tints.append(NeonMat.get_tint(m))
			NeonMat.set_tint(m, GOLD_HOT if tints.size() % 2 == 0 else GOLD)
		_gilded[i] = tints


func hide_overlays() -> void:
	if _vignette != null:
		_vignette.queue_free()
		_vignette = null
		_vig_mat = null
	_overlays_off = true


var _overlays_off: bool = false


func _update_hud(e: float) -> void:
	if _overlays_off:
		return
	var hud: Object = section.get("_hud")
	if hud != null and hud.has_method("set_fever"):
		hud.call("set_fever", meter, active, time_left, _ready_flash)
	# A warm edge on the screen while it lasts.
	if _vignette == null and hud != null and hud.has_method("overlay_root"):
		var root: Control = hud.call("overlay_root") as Control
		if root != null:
			_vignette = ColorRect.new()
			_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			var sh := Shader.new()
			sh.code = """
shader_type canvas_item;
uniform float amount = 0.0;
uniform float pulse = 0.0;
uniform vec4 col : source_color = vec4(1.0, 0.8, 0.25, 1.0);
void fragment() {
	vec2 d = UV - 0.5;
	d.x *= 1.6;
	float v = smoothstep(0.38, 0.85, length(d));
	COLOR = vec4(col.rgb, v * amount * (0.55 + 0.45 * pulse));
}
"""
			_vig_mat = ShaderMaterial.new()
			_vig_mat.shader = sh
			_vignette.material = _vig_mat
			root.add_child(_vignette)
			root.move_child(_vignette, 0)
	if _vig_mat != null:
		_vignette.visible = e > 0.01
		_vig_mat.set_shader_parameter("amount", 0.32 * e * maxf(GameConfig.flash_scale(), 0.4))
		_vig_mat.set_shader_parameter("pulse", float(section.get("_beat_phase")))
