class_name GameHud
extends CanvasLayer

## The in-level gameplay HUD: score, combo, health, lives, charge/overdrive,
## flow, song progress and lyrics.
##
## Previously all of this was built inline inside Section_BeatRunner3d.gd — an
## 11k-line gameplay script — out of flat StyleBoxFlat rectangles and Labels in
## Godot's default font. This module owns the whole thing instead, and the
## gameplay script talks to it through the small API below. Every widget is
## drawn by shaders/hud_{plate,bar,text,lyric}.gdshader, so the chassis is
## chamfered rather than rounded and the whole HUD can pulse on the beat.
##
## Construction and layout are deliberately split: _build() creates nodes once,
## _layout() places and sizes them. That is what lets the HUD re-flow on
## viewport resize — the old HUD sized itself once and never reacted again.

# ── Public handles ───────────────────────────────────────────────────────────

## The full-screen tint used for hit/miss/bonus feedback. Section_BeatRunner3d
## keeps its own `_hud_flash` pointed here, because the pause menu, death
## screen, results panel and dev toast all locate their parent Control via
## `_hud_flash.get_parent()`. Prefer overlay_root() in new code.
var flash_rect: ColorRect = null


# ── Tunables ─────────────────────────────────────────────────────────────────

const LOW_HP_THRESHOLD: float = 0.20
const _GHOST_DELAY_S:   float = 0.28   # how long the damage-lag trail lingers
const _GHOST_DRAIN_S:   float = 0.55
const _IDLE_FADE_DELAY: float = 2.2    # score card settles to a quieter opacity
const _IDLE_FADE_ALPHA: float = 0.66

## Where the centre banner sits, as a fraction of viewport height. It used to be
## 0.36, which is exactly where the gates arrive — a streak banner was covering
## the one thing the player cannot afford to lose sight of. Kept high enough to
## clear the wall-jump card above it at full callout intensity.
const _CALLOUT_ROW:     float = 0.22
const _CALLOUT_SHAKE_S: float = 0.34   # how long a high-intensity banner rocks

## The score range the rainbow accelerates across: at RAINBOW_SCORE the hue
## drifts, by RAINBOW_SCORE_MAX it is running flat out and stays there.
##
## The ceiling is deliberately inside what a real run reaches. An open-ended
## curve put full speed somewhere past 10 M, well beyond the ~7.5 M a good run
## actually scores, so the fastest state was one nobody was ever going to see.
## See _update_score_rainbow.
const RAINBOW_SCORE:     int = 1_000_000
const RAINBOW_SCORE_MAX: int = 10_000_000
const _RAINBOW_SLOW: float = 0.50   # hue cycles/sec at the threshold
const _RAINBOW_FAST: float = 3.00   # hue cycles/sec at the ceiling

const _PLATE_SHADER: String = "res://shaders/hud_plate.gdshader"
const _BAR_SHADER:   String = "res://shaders/hud_bar.gdshader"
const _TEXT_SHADER:  String = "res://shaders/hud_text.gdshader"
const _LYRIC_SHADER: String = "res://shaders/hud_lyric.gdshader"


# ── Layout state ─────────────────────────────────────────────────────────────

var _vp: Vector2 = Vector2(1920, 1080)
var _s:  float   = 1.0

var _root: Control = null

# Score / combo
var _score_group:  Control   = null
var _score_plate:  ColorRect = null
var _score_cap:    Label     = null
var _score_value:  Label     = null
var _combo_plate:  ColorRect = null
var _combo_value:  Label     = null
var _combo_cap:    Label     = null
var _combo_mult:   Label     = null
var _combo_tier:   ColorRect = null
var _score_idle_tw:  Tween = null
var _score_flash_tw: Tween = null
var _score_roll_tw:  Tween = null
var _score_target: int = 0
var _score_shown:  int = 0
var _score_font_size: int = 0   # current size bucket — see _apply_score_text
var _score_text_mat: ShaderMaterial = null   # the numerals' chrome shader
var _rainbow_hue: float = 0.0
var _rainbow_on:  bool  = false

# Health / lives
var _hp_group:  Control   = null
var _hp_cap:    Label     = null
var _hp_bar:    ColorRect = null
var _hp_pct:    Label     = null
var _hp_pips:   Array[ColorRect] = []
var _hp_fill_tw:  Tween = null
var _hp_ghost_tw: Tween = null
var _hp_pulse_tw: Tween = null
var _hp_displayed: float = 0.25
var _hp_ghost:     float = 0.25
var _hp_critical:  bool  = false

# Charge / overdrive
var _charge_group: Control   = null
var _charge_plate: ColorRect = null
var _charge_cap:   Label     = null
var _charge_bar:   ColorRect = null
var _charge_pct:   Label     = null
var _charge_state: Label     = null

# Flow (grind rail)
var _flow_group: Control   = null
var _flow_plate: ColorRect = null
var _flow_cap:   Label     = null
var _flow_value: Label     = null
var _flow_bar:   ColorRect = null

# Wall-jump banner + the transient centre-screen callouts
var _wj_label:     Label      = null
var _wj_card:      PlatePanel = null
var _callout_card:      PlatePanel = null
var _callout_label:     Label      = null
var _callout_intensity: float      = 0.0
var _callout_hue:       float      = 0.0
var _callout_shake:     float      = 0.0

# Song progress
var _prog_bg:   ColorRect = null
var _prog_fill: ColorRect = null
var _prog_head: ColorRect = null
var _prog_pct:  float = 0.0

# Lyrics
var _lyrics_root:  Control      = null
var _lyrics_scrim: TextureRect  = null
var _lyrics_rows:  VBoxContainer = null
var _lyric_font:   Font         = null
var _lyric_size:   int          = 40
var _lyric_row_w:  float        = 0.0    # running width of the row being filled
var _lyric_last:   Label        = null   # most recently added word, for the karaoke dim
var _lyric_line_id: int         = 0      # bumped per line; drops stale delayed words
var _lyrics_slide: float        = 0.0

# Shader materials whose `beat` uniform is written every frame.
var _beat_mats: Array[ShaderMaterial] = []
# Plate/bar materials that follow the signature colour drift.
var _chrome_plates: Array[ShaderMaterial] = []

var _shader_cache: Dictionary = {}


# ═════════════════════════════════════════════════════════════════════════════
# Lifecycle
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	layer = 20
	_refresh_vp()
	_build()
	_layout()
	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)


func _on_viewport_resized() -> void:
	_refresh_vp()
	_layout()


## Only two things here need a frame: the rainbow score (a continuous hue whose
## rate depends on the score itself, so it cannot be pre-baked into a tween) and
## the live half of a high-intensity callout. Everything else in this HUD is
## still event-driven.
func _process(delta: float) -> void:
	_update_score_rainbow(delta)
	_update_callout(delta)


func _refresh_vp() -> void:
	var vp: Viewport = get_viewport()
	if vp != null:
		_vp = vp.get_visible_rect().size
	_s = UiStyle.scale_for(_vp)


## The Control that full-screen overlays (pause, death, results) should parent
## themselves to. Anything added here draws above every HUD widget.
func overlay_root() -> Control:
	return _root


# ═════════════════════════════════════════════════════════════════════════════
# Construction
# ═════════════════════════════════════════════════════════════════════════════

func _shader(path: String) -> Shader:
	if _shader_cache.has(path):
		return _shader_cache[path]
	var sh: Shader = load(path) as Shader
	if sh == null:
		push_error("[GameHud] Could not load %s" % path)
	_shader_cache[path] = sh
	return sh


## A chamfered chassis panel. `cuts` is [top-left, top-right, bottom-right,
## bottom-left]; 1.0 slices that corner at 45°, 0.0 leaves it square.
func _make_plate(cuts: Array[float], cut_size: float = 20.0, chrome: bool = true) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color.WHITE          # unused — the shader drives every visible pixel
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = _shader(_PLATE_SHADER)
	m.set_shader_parameter("cut_size", cut_size)
	m.set_shader_parameter("cut_tl", cuts[0])
	m.set_shader_parameter("cut_tr", cuts[1])
	m.set_shader_parameter("cut_br", cuts[2])
	m.set_shader_parameter("cut_bl", cuts[3])
	m.set_shader_parameter("fill_color", UiStyle.INK)
	r.material = m
	_beat_mats.append(m)
	if chrome:
		_chrome_plates.append(m)
	return r


func _make_bar(skew: float = 9.0, ticks: float = 4.0, bolt: float = 0.0) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color.WHITE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = _shader(_BAR_SHADER)
	m.set_shader_parameter("skew_px", skew)
	m.set_shader_parameter("tick_count", ticks)
	m.set_shader_parameter("bolt_amount", bolt)
	m.set_shader_parameter("ghost_color", Color(UiStyle.GHOST.r, UiStyle.GHOST.g, UiStyle.GHOST.b, 0.55))
	m.set_shader_parameter("track_color", Color(0.045, 0.02, 0.10, 0.90))
	r.material = m
	_beat_mats.append(m)
	return r


## Chrome/neon shading for a numeral Label. The shader is multiplicative and
## never touches MODULATE, so self_modulate (colour drift) and modulate (flash
## pulse) both keep working on top of it.
func _apply_text_shader(l: Label) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader(_TEXT_SHADER)
	l.material = m
	_beat_mats.append(m)
	return m


func _set_rect(c: Control, x: float, y: float, w: float, h: float) -> void:
	c.offset_left   = x
	c.offset_top    = y
	c.offset_right  = x + w
	c.offset_bottom = y + h
	var m := c.material as ShaderMaterial
	if m != null:
		m.set_shader_parameter("rect_size", Vector2(w, h))


func _anchor_tl(c: Control) -> void:
	c.anchor_left = 0.0; c.anchor_right = 0.0
	c.anchor_top  = 0.0; c.anchor_bottom = 0.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_score()
	_build_health()
	_build_progress()

	# Flash sits above the readouts but below the callouts and lyrics, matching
	# the original stacking order.
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_rect.color = Color(0, 0, 0, 0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(flash_rect)

	_build_charge()
	_build_flow()
	_build_wall_jump()
	_build_lyrics()


func _build_score() -> void:
	# One group so the whole cluster can settle to a quieter opacity between
	# hits and snap back the instant something happens — see score_bump().
	_score_group = Control.new()
	_score_group.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_score_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_score_group)

	_score_plate = _make_plate([1.0, 0.0, 1.0, 0.0])
	_anchor_tl(_score_plate)
	_score_group.add_child(_score_plate)

	_score_cap = UiStyle.label("SCORE", UiStyle.caption(3.5), 12, Color.WHITE)
	_score_cap.self_modulate = Color(0.78, 0.62, 1.00, 0.80)
	_anchor_tl(_score_cap)
	_score_group.add_child(_score_cap)

	# font_color stays WHITE so the signature drift can ride on self_modulate.
	_score_value = UiStyle.label("0", UiStyle.display(800), 46, Color.WHITE)
	_score_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_score_value.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_score_value.self_modulate = Color(1.00, 0.62, 0.88, 1.0)
	_score_text_mat = _apply_text_shader(_score_value)
	_anchor_tl(_score_value)
	_score_group.add_child(_score_value)

	_combo_plate = _make_plate([1.0, 0.0, 1.0, 0.0], 12.0)
	_combo_plate.material.set_shader_parameter("grid_amount", 0.18)
	_anchor_tl(_combo_plate)
	_combo_plate.visible = false
	_score_group.add_child(_combo_plate)

	_combo_value = UiStyle.label("", UiStyle.display(800), 22, Color.WHITE)
	_combo_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_combo_value.self_modulate = UiStyle.GOLD
	_anchor_tl(_combo_value)
	_combo_value.visible = false
	_score_group.add_child(_combo_value)

	_combo_cap = UiStyle.label("COMBO", UiStyle.caption(3.0), 10, Color.WHITE)
	_combo_cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_combo_cap.self_modulate = Color(0.90, 0.84, 1.00, 0.70)
	_anchor_tl(_combo_cap)
	_combo_cap.visible = false
	_score_group.add_child(_combo_cap)

	_combo_mult = UiStyle.label("", UiStyle.display(900), 17, Color.WHITE)
	_combo_mult.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_combo_mult.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_combo_mult.self_modulate = UiStyle.GOLD
	_anchor_tl(_combo_mult)
	_combo_mult.visible = false
	_score_group.add_child(_combo_mult)

	# Progress toward the next multiplier tier (one tier every 10 combo).
	_combo_tier = _make_bar(4.0, 1.0, 0.0)
	_combo_tier.material.set_shader_parameter("glow_px", 4.0)
	_combo_tier.material.set_shader_parameter("track_color", Color(0.10, 0.05, 0.16, 0.75))
	_anchor_tl(_combo_tier)
	_combo_tier.visible = false
	_score_group.add_child(_combo_tier)


func _build_health() -> void:
	_hp_group = Control.new()
	_hp_group.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hp_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hp_group)

	_hp_cap = UiStyle.label("HP", UiStyle.caption(3.0), 13, Color.WHITE, 3)
	_hp_cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_cap.self_modulate = Color(1.00, 0.62, 0.82, 0.92)
	_anchor_tl(_hp_cap)
	_hp_group.add_child(_hp_cap)

	# The lightning arc from the original bar is kept, at full strength.
	_hp_bar = _make_bar(9.0, 4.0, 1.0)
	_anchor_tl(_hp_bar)
	_hp_group.add_child(_hp_bar)

	_hp_pct = UiStyle.label("25%", UiStyle.display(700), 16, Color.WHITE, 3)
	_hp_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_pct.self_modulate = Color(0.92, 0.92, 0.98, 0.85)
	_anchor_tl(_hp_pct)
	_hp_group.add_child(_hp_pct)


func _build_progress() -> void:
	_prog_bg = ColorRect.new()
	_prog_bg.anchor_left = 0.0; _prog_bg.anchor_right = 1.0
	_prog_bg.anchor_top  = 1.0; _prog_bg.anchor_bottom = 1.0
	_prog_bg.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_prog_bg.color = Color(0.05, 0.02, 0.12, 0.88)
	_prog_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_prog_bg)

	# No ticks and no slant: the progress bar spans the full screen width, so a
	# slanted end would read as a rendering glitch against the screen edge.
	_prog_fill = _make_bar(0.0, 0.0, 0.0)
	_prog_fill.material.set_shader_parameter("track_color", Color(0, 0, 0, 0))
	_prog_fill.material.set_shader_parameter("edge_px", 0.0)
	_prog_fill.material.set_shader_parameter("glow_px", 6.0)
	_anchor_tl(_prog_fill)
	_root.add_child(_prog_fill)

	# All four corners cut on a square plate gives a diamond playhead.
	_prog_head = _make_plate([1.0, 1.0, 1.0, 1.0], 999.0, false)
	_prog_head.material.set_shader_parameter("grid_amount", 0.0)
	_prog_head.material.set_shader_parameter("scan_amount", 0.0)
	_prog_head.material.set_shader_parameter("fill_amount", 0.0)
	_prog_head.material.set_shader_parameter("glow_px", 14.0)
	_anchor_tl(_prog_head)
	_root.add_child(_prog_head)


func _build_charge() -> void:
	_charge_group = Control.new()
	_charge_group.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_charge_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_charge_group.visible = false
	_root.add_child(_charge_group)

	_charge_plate = _make_plate([1.0, 0.0, 1.0, 0.0], 18.0, false)
	_charge_plate.material.set_shader_parameter("edge_color",  UiStyle.CYAN)
	_charge_plate.material.set_shader_parameter("edge_color2", UiStyle.VIOLET)
	_anchor_tl(_charge_plate)
	_charge_group.add_child(_charge_plate)

	_charge_cap = UiStyle.label("CHARGE", UiStyle.caption(4.0), 12, Color.WHITE)
	_charge_cap.self_modulate = Color(0.60, 0.95, 1.00, 0.95)
	_anchor_tl(_charge_cap)
	_charge_group.add_child(_charge_cap)

	_charge_state = UiStyle.label("", UiStyle.caption(3.0), 11, Color.WHITE)
	_charge_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_charge_state.self_modulate = Color(1.00, 0.95, 0.55, 0.95)
	_anchor_tl(_charge_state)
	_charge_group.add_child(_charge_state)

	_charge_bar = _make_bar(7.0, 10.0, 0.0)
	_charge_bar.material.set_shader_parameter("fill_color",  UiStyle.CYAN)
	_charge_bar.material.set_shader_parameter("fill_color2", Color(1.00, 0.95, 0.35))
	_charge_bar.material.set_shader_parameter("edge_color",  UiStyle.CYAN)
	_charge_bar.material.set_shader_parameter("ghost_color", Color(0, 0, 0, 0))
	_anchor_tl(_charge_bar)
	_charge_group.add_child(_charge_bar)

	_charge_pct = UiStyle.label("0%", UiStyle.display(800), 18, Color.WHITE)
	_charge_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_charge_pct.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_charge_pct.self_modulate = Color(0.80, 0.98, 1.00)
	_anchor_tl(_charge_pct)
	_charge_group.add_child(_charge_pct)


func _build_flow() -> void:
	_flow_group = Control.new()
	_flow_group.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flow_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flow_group.visible = false
	_root.add_child(_flow_group)

	_flow_plate = _make_plate([1.0, 0.0, 1.0, 0.0], 14.0, false)
	_flow_plate.material.set_shader_parameter("edge_color",  Color(1.00, 0.60, 0.10))
	_flow_plate.material.set_shader_parameter("edge_color2", UiStyle.GOLD)
	_anchor_tl(_flow_plate)
	_flow_group.add_child(_flow_plate)

	_flow_cap = UiStyle.label("FLOW", UiStyle.caption(4.0), 11, Color.WHITE)
	_flow_cap.self_modulate = Color(1.00, 0.72, 0.35, 0.95)
	_anchor_tl(_flow_cap)
	_flow_group.add_child(_flow_cap)

	_flow_value = UiStyle.label("", UiStyle.display(800), 20, Color.WHITE)
	_flow_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_flow_value.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_flow_value.self_modulate = Color(1.00, 0.82, 0.45)
	_anchor_tl(_flow_value)
	_flow_group.add_child(_flow_value)

	_flow_bar = _make_bar(5.0, 0.0, 0.0)
	_flow_bar.material.set_shader_parameter("fill_color",  Color(1.00, 0.60, 0.10))
	_flow_bar.material.set_shader_parameter("fill_color2", UiStyle.GOLD)
	_flow_bar.material.set_shader_parameter("edge_color",  Color(1.00, 0.60, 0.10, 0.7))
	_flow_bar.material.set_shader_parameter("ghost_color", Color(0, 0, 0, 0))
	_anchor_tl(_flow_bar)
	_flow_group.add_child(_flow_bar)


func _build_wall_jump() -> void:
	# The bonus banner is a plate like everything else now, rather than a bare
	# outlined Label floating over the track.
	_wj_card = PlatePanel.create(int(14 * _s), UiStyle.GOLD, 16.0 * _s)
	_wj_card.set_cuts(1.0, 0.0, 1.0, 0.0)
	_wj_card.anchor_left = 0.5; _wj_card.anchor_right  = 0.5
	_wj_card.anchor_top  = 0.0; _wj_card.anchor_bottom = 0.0
	_wj_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wj_card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_wj_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wj_card.visible = false
	_root.add_child(_wj_card)

	_wj_label = UiStyle.label("WALL JUMP  ×2", UiStyle.display(900, 4.0), int(26 * _s), Color.WHITE)
	_wj_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wj_label.self_modulate = UiStyle.GOLD
	_wj_card.content.add_child(_wj_label)


func _build_lyrics() -> void:
	_lyrics_root = Control.new()
	_lyrics_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lyrics_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lyrics_root.visible = false
	_root.add_child(_lyrics_root)

	# A soft dark blob behind the words. White lyric text over a bright neon
	# tunnel was the one readability problem the old HUD genuinely had.
	var grad := Gradient.new()
	grad.set_color(0, Color(0.02, 0.01, 0.05, 0.62))
	grad.set_color(1, Color(0.02, 0.01, 0.05, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to   = Vector2(1.0, 0.5)
	tex.width  = 256
	tex.height = 128
	_lyrics_scrim = TextureRect.new()
	_lyrics_scrim.texture = tex
	_lyrics_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	_lyrics_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_tl(_lyrics_scrim)
	_lyrics_root.add_child(_lyrics_scrim)

	# A VBox of centred HBoxes, so a long line wraps instead of running off the
	# side of the screen — the old row was a single HBoxContainer with no wrap.
	_lyrics_rows = VBoxContainer.new()
	_lyrics_rows.alignment = BoxContainer.ALIGNMENT_CENTER
	_lyrics_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_tl(_lyrics_rows)
	_lyrics_root.add_child(_lyrics_rows)


# ═════════════════════════════════════════════════════════════════════════════
# Layout — everything positional lives here so a resize can simply re-run it
# ═════════════════════════════════════════════════════════════════════════════

func _layout() -> void:
	if _root == null:
		return
	var s: float = _s
	var m: float = 20.0 * s

	# ── Score plate, top right ───────────────────────────────────────────────
	var pw: float = 272.0 * s
	var ph: float = 104.0 * s
	var px: float = _vp.x - m - pw
	_set_rect(_score_plate, px, m, pw, ph)
	_set_rect(_score_cap,   px + 26.0 * s, m + 14.0 * s, pw - 44.0 * s, 18.0 * s)
	_set_rect(_score_value, px + 20.0 * s, m + 34.0 * s, pw - 42.0 * s, 56.0 * s)

	# Sized for the worst case, not the common one: combo runs past 100 and the
	# multiplier hits ×100 in overdrive, so every column has to hold 3 digits
	# without the three of them running into each other.
	var cw: float = 250.0 * s
	var ch: float = 44.0 * s
	var cx: float = _vp.x - m - cw
	var cy: float = m + ph + 7.0 * s
	var crow: float = 26.0 * s          # text row height, above the tier strip
	_set_rect(_combo_plate, cx, cy, cw, ch)
	_set_rect(_combo_value, cx + 16.0 * s,       cy + 4.0 * s, 86.0 * s, crow)
	_set_rect(_combo_cap,   cx + 104.0 * s,      cy + 4.0 * s, 72.0 * s, crow)
	_set_rect(_combo_mult,  cx + cw - 84.0 * s,  cy + 4.0 * s, 68.0 * s, crow)
	# The tier strip lives on its own line at the very bottom; it used to run
	# straight through the baseline of the text above it.
	_set_rect(_combo_tier,  cx + 16.0 * s, cy + ch - 9.0 * s, cw - 32.0 * s, 4.0 * s)

	# ── Health, top left ─────────────────────────────────────────────────────
	var bw: float = 300.0 * s
	var bh: float = 26.0 * s
	var bx: float = m + 40.0 * s
	_set_rect(_hp_cap, m, m, 36.0 * s, bh)
	_set_rect(_hp_bar, bx, m, bw, bh)
	_set_rect(_hp_pct, bx + bw + 12.0 * s, m, 76.0 * s, bh)
	_layout_pips()

	# ── Song progress, bottom edge ───────────────────────────────────────────
	var gh: float = 10.0 * s
	_prog_bg.offset_top = -gh; _prog_bg.offset_bottom = 0.0
	_set_rect(_prog_fill, 0.0, _vp.y - gh, maxf(_vp.x * _prog_pct, 0.001), gh)
	_prog_fill.anchor_left = 0.0; _prog_fill.anchor_right = 0.0
	var hd: float = 18.0 * s
	_set_rect(_prog_head, _vp.x * _prog_pct - hd * 0.5, _vp.y - gh * 0.5 - hd * 0.5, hd, hd)

	# ── Charge, bottom centre ────────────────────────────────────────────────
	var qw: float = 430.0 * s
	var qh: float = 70.0 * s
	var qx: float = (_vp.x - qw) * 0.5
	var qy: float = _vp.y - 182.0 * s
	_set_rect(_charge_plate, qx, qy, qw, qh)
	_set_rect(_charge_cap,   qx + 24.0 * s, qy + 12.0 * s, 200.0 * s, 16.0 * s)
	_set_rect(_charge_state, qx + qw - 224.0 * s, qy + 12.0 * s, 200.0 * s, 16.0 * s)
	# The readout needs real clearance from the bar's end cap, not just from its
	# text box — the bar draws an outer bloom past its own rect.
	_set_rect(_charge_bar,   qx + 24.0 * s, qy + 36.0 * s, qw - 134.0 * s, 20.0 * s)
	_set_rect(_charge_pct,   qx + qw - 88.0 * s, qy + 33.0 * s, 66.0 * s, 26.0 * s)

	# ── Flow, one row below the charge meter ─────────────────────────────────
	var fw: float = 340.0 * s
	var fh: float = 52.0 * s
	var fx: float = (_vp.x - fw) * 0.5
	var fy: float = _vp.y - 100.0 * s
	_set_rect(_flow_plate, fx, fy, fw, fh)
	_set_rect(_flow_cap,   fx + 20.0 * s, fy + 10.0 * s, 120.0 * s, 16.0 * s)
	_set_rect(_flow_value, fx + fw - 168.0 * s, fy + 6.0 * s, 148.0 * s, 26.0 * s)
	_set_rect(_flow_bar,   fx + 20.0 * s, fy + fh - 16.0 * s, fw - 40.0 * s, 8.0 * s)

	# ── Callout ──────────────────────────────────────────────────────────────
	# The banner sizes itself from its content, so only its anchor row moves.
	_wj_card.offset_top = 118.0 * s

	_layout_fonts()
	_layout_lyrics()


## Font sizes have to scale with the viewport alongside the boxes that hold
## them — otherwise a resize moves every widget but leaves the type at its
## 1080p size, and the text overflows its own chassis.
func _layout_fonts() -> void:
	var s: float = _s
	var sized: Array = [
		[_score_cap, 12], [_combo_value, 22], [_combo_cap, 10], [_combo_mult, 17],
		[_hp_cap, 13], [_hp_pct, 16],
		[_charge_cap, 12], [_charge_state, 11], [_charge_pct, 18],
		[_flow_cap, 11], [_flow_value, 20],
		[_wj_label, 30],
	]
	for e in sized:
		var l: Label = e[0]
		if l != null:
			l.add_theme_font_size_override("font_size", int(round(float(e[1]) * s)))
	# The score's own size is picked per-value in _apply_score_text; clearing the
	# cached bucket makes the next write recompute it against the new scale.
	_score_font_size = 0
	_apply_score_text(float(_score_shown))


## Takes no arguments on purpose: set_lives() can add or remove pips at any
## time and has to place them exactly where _layout() would have, so the origin
## is derived here once rather than being passed in from two places.
func _layout_pips() -> void:
	var s: float = _s
	var x: float = 20.0 * s + 40.0 * s        # HP bar's left edge
	var y: float = 20.0 * s + 26.0 * s + 8.0 * s   # just under the bar
	var w: float = 38.0 * s
	var h: float = 10.0 * s
	var gap: float = 7.0 * s
	for i in range(_hp_pips.size()):
		var pip: ColorRect = _hp_pips[i]
		if pip != null:
			_set_rect(pip, x + float(i) * (w + gap), y, w, h)


func _layout_lyrics() -> void:
	if _lyrics_rows == null:
		return
	var s: float = _s
	_lyric_size = int(round(40.0 * s))
	# Full viewport width, with each row centring itself — so the row never has
	# to be repositioned from its own measured size a frame late.
	var lw: float = _vp.x
	var ly: float = _vp.y * 0.76 + _lyrics_slide
	_set_rect(_lyrics_rows, 0.0, ly, lw, 0.0)
	_lyrics_rows.add_theme_constant_override("separation", int(6 * s))
	for row in _lyrics_rows.get_children():
		var hb := row as HBoxContainer
		if hb != null:
			hb.add_theme_constant_override("separation", int(14 * s))
	_position_scrim()


func _position_scrim() -> void:
	if _lyrics_scrim == null or _lyrics_rows == null:
		return
	var s: float = _s
	var rows: int = maxi(_lyrics_rows.get_child_count(), 1)
	var row_h: float = float(_lyric_size) * 1.35
	var h: float = row_h * float(rows) + 56.0 * s
	var w: float = minf(_vp.x * 0.92, 1180.0 * s)
	_set_rect(_lyrics_scrim,
		(_vp.x - w) * 0.5,
		_vp.y * 0.76 + _lyrics_slide - 28.0 * s,
		w, h)


# ═════════════════════════════════════════════════════════════════════════════
# Score / combo
# ═════════════════════════════════════════════════════════════════════════════

## `delta` is the point change that triggered this update; pass 0 when nothing
## was scored (e.g. the multiplier lapsing) so no "+N" popup is spawned.
func set_score(score: int, combo: int, mult: int, delta: int) -> void:
	if _score_value == null:
		return

	if score != _score_target:
		_score_target = score
		# Roll the DISPLAYED value toward the real one instead of snapping. A
		# six-figure number changing in one frame reads as a glitch; a 0.22 s
		# roll reads as a machine counting up.
		if _score_roll_tw != null and _score_roll_tw.is_valid():
			_score_roll_tw.kill()
		_score_roll_tw = create_tween()
		_score_roll_tw.tween_method(_apply_score_text, float(_score_shown), float(score), 0.22) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		# Punch-scale...
		var stw := create_tween()
		stw.tween_property(_score_value, "scale", Vector2(1.14, 1.14), 0.06) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		stw.tween_property(_score_value, "scale", Vector2.ONE, 0.16) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		# ...plus a brightness pulse, so an increase reads as a beat rather than
		# as new text quietly appearing.
		if _score_flash_tw != null and _score_flash_tw.is_valid():
			_score_flash_tw.kill()
		_score_value.modulate = Color(2.0, 2.0, 2.0, 1.0)
		_score_flash_tw = create_tween()
		_score_flash_tw.tween_property(_score_value, "modulate", Color.WHITE, 0.24) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

		if delta > 0:
			score_popup(delta)

	_apply_combo(combo, mult)
	score_bump()


func _apply_score_text(v: float) -> void:
	_score_shown = int(round(v))
	var txt: String = UiStyle.group_digits(_score_shown)
	_score_value.text = txt

	# Step the size down once the number outgrows the plate. A full run reaches
	# seven figures, and "1,362,500" at the base size ran into the chassis edge.
	# Only written when the bucket actually changes: a font-size override
	# invalidates the shaped-text buffer, and this runs on every frame of the
	# odometer roll.
	var size: int = 46
	if txt.length() > 9:
		size = 32
	elif txt.length() > 7:
		size = 38
	size = int(round(float(size) * _s))
	if size != _score_font_size:
		_score_font_size = size
		_score_value.add_theme_font_size_override("font_size", size)


## Past RAINBOW_SCORE the score readout stops walking the signature band and
## runs the full hue wheel instead - the one place in this HUD where a rotating
## rainbow is earned rather than lazy, because reaching seven figures is the
## point of it. It keeps accelerating up to RAINBOW_SCORE_MAX, so the number
## visibly gets more unhinged the higher it climbs.
##
## Driven off the DISPLAYED score, not the target, so it switches on as the
## odometer rolls through the million rather than the instant the hit lands.
func _update_score_rainbow(delta: float) -> void:
	if _score_value == null:
		return
	var on: bool = _score_shown >= RAINBOW_SCORE
	if on != _rainbow_on:
		_rainbow_on = on
		if not on:
			# Hand the readout back to set_chrome_phase in its default shading.
			_restore_score_tints()
	if not on:
		return

	_rainbow_hue = fposmod(_rainbow_hue + delta * _rainbow_speed(), 1.0)
	var c:  Color = Color.from_hsv(_rainbow_hue, 0.80, 1.0)
	var c2: Color = Color.from_hsv(fposmod(_rainbow_hue + 0.12, 1.0), 0.85, 1.0)
	var c3: Color = Color.from_hsv(fposmod(_rainbow_hue + 0.45, 1.0), 0.75, 1.0)

	_score_value.self_modulate = c
	_score_cap.self_modulate   = Color(c3.r, c3.g, c3.b, 0.90)
	if _score_text_mat != null:
		# The chrome shader's ramp is multiplicative, so feeding it two hues
		# gives the digits a rolling gradient instead of one flat colour.
		_score_text_mat.set_shader_parameter("top_tint",    Vector3(c.r, c.g, c.b))
		_score_text_mat.set_shader_parameter("bottom_tint", Vector3(c2.r, c2.g, c2.b))
	var sm := _score_plate.material as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter("edge_color",  c)
		sm.set_shader_parameter("edge_color2", c3)


## Cycles per second, ramped log-spaced across the decade between the two
## thresholds — every ×10 of score is the same step, so the climb reads as
## steady rather than back-loaded — and held there above the ceiling.
func _rainbow_speed() -> float:
	var over: float = float(maxi(_score_shown, RAINBOW_SCORE)) / float(RAINBOW_SCORE)
	var span: float = float(RAINBOW_SCORE_MAX) / float(RAINBOW_SCORE)
	var t: float = clampf(log(over) / log(maxf(span, 1.0001)), 0.0, 1.0)
	return lerpf(_RAINBOW_SLOW, _RAINBOW_FAST, t)


func _restore_score_tints() -> void:
	if _score_text_mat != null:
		_score_text_mat.set_shader_parameter("top_tint",    Vector3(1.0, 1.0, 1.0))
		_score_text_mat.set_shader_parameter("bottom_tint", Vector3(0.72, 0.60, 0.92))


func _apply_combo(combo: int, mult: int) -> void:
	var show: bool = combo >= 2
	_combo_plate.visible = show
	_combo_value.visible = show
	_combo_cap.visible   = show
	_combo_mult.visible  = show
	_combo_tier.visible  = show
	if not show:
		return
	_combo_value.text = "×%d" % combo
	_combo_mult.text  = "%d✕" % mult if mult > 1 else ""
	# Tiers arrive every 10 combo (see _score_multiplier); show how close the
	# next one is, so the combo number has stakes attached to it.
	var tier: float = float(combo % 10) / 10.0
	var mat := _combo_tier.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_pct", tier)
		mat.set_shader_parameter("ghost_pct", tier)


## Keeps the score cluster at full opacity while things are happening, then lets
## it settle to a translucent idle state a moment after the last hit — so it
## reads clearly in the moment without competing with the lanes during a quiet
## stretch.
func score_bump() -> void:
	if _score_group == null:
		return
	if _score_idle_tw != null and _score_idle_tw.is_valid():
		_score_idle_tw.kill()
	_score_group.modulate.a = 1.0
	_score_idle_tw = create_tween()
	_score_idle_tw.tween_interval(_IDLE_FADE_DELAY)
	_score_idle_tw.tween_property(_score_group, "modulate:a", _IDLE_FADE_ALPHA, 0.5)


## Floating "+N" that rises out of the score plate and fades — so a big hit
## reads as a moment, not just a number changing.
func score_popup(delta_pts: int) -> void:
	if _score_group == null or delta_pts <= 0:
		return
	var s: float = _s
	var lbl := UiStyle.label("+%s" % UiStyle.group_digits(delta_pts),
		UiStyle.display(700), int(17 * s), Color.WHITE, int(4 * s))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_anchor_tl(lbl)
	var m: float = 20.0 * s
	var cw: float = 250.0 * s
	# Below the combo pill, drifting up into it. It used to sit ABOVE the score
	# plate and drift further up, which ran it straight off the top of the screen.
	var y: float = m + 104.0 * s + 7.0 * s + 44.0 * s + 4.0 * s
	# Offsets, not `position`: a freshly added Control has no valid position
	# until the next layout pass, but its offsets are authoritative immediately.
	_set_rect(lbl, _vp.x - m - cw, y, cw - 16.0 * s, 26.0 * s)
	lbl.modulate.a = 0.0
	_score_group.add_child(lbl)

	var top0: float = lbl.offset_top
	var bot0: float = lbl.offset_bottom
	# Bound to the label, not to the HUD: the fade tween below frees the label at
	# the same moment this one ends, and a HUD-owned tween whose lambda captures
	# a freed node spams "Lambda capture at index 0 was freed" every frame it
	# survives. A label-bound tween dies with the label instead.
	var tw_move := lbl.create_tween()
	tw_move.tween_method(func(v: float) -> void:
		lbl.offset_top    = top0 + v
		lbl.offset_bottom = bot0 + v
	, 0.0, -34.0 * s, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

	var tw_fade := lbl.create_tween()
	tw_fade.tween_property(lbl, "modulate:a", 1.0, 0.08)
	tw_fade.tween_interval(0.32)
	tw_fade.tween_property(lbl, "modulate:a", 0.0, 0.30)
	tw_fade.tween_callback(lbl.queue_free)


# ═════════════════════════════════════════════════════════════════════════════
# Health / lives
# ═════════════════════════════════════════════════════════════════════════════

## force_pulse plays the heal flare even when HP cannot visibly increase (i.e.
## already at 100 %), so a clean hit still gives positive feedback at full
## health, where the fill itself has nothing left to show for it.
func set_health(pct: float, force_pulse: bool = false) -> void:
	if _hp_bar == null:
		return
	var p: float = clampf(pct, 0.0, 1.0)
	var healed: bool = p > _hp_displayed + 0.0005

	if force_pulse or healed:
		hp_heal_pulse()

	if _hp_fill_tw != null and _hp_fill_tw.is_valid():
		_hp_fill_tw.kill()
	_hp_fill_tw = create_tween()
	_hp_fill_tw.tween_method(_apply_hp_display, _hp_displayed, p, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	# Damage-lag trail: on a heal the ghost rides up with the fill, but on a hit
	# it stays put briefly and then drains down to meet it. That pause is the
	# whole point — it makes "you just lost some" legible without reading the %.
	if _hp_ghost_tw != null and _hp_ghost_tw.is_valid():
		_hp_ghost_tw.kill()
	if p >= _hp_ghost:
		_hp_ghost_tw = create_tween()
		_hp_ghost_tw.tween_method(_apply_hp_ghost, _hp_ghost, p, 0.55) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_hp_ghost_tw = create_tween()
		_hp_ghost_tw.tween_interval(_GHOST_DELAY_S)
		_hp_ghost_tw.tween_method(_apply_hp_ghost, _hp_ghost, p, _GHOST_DRAIN_S) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)

	set_low_health(p < LOW_HP_THRESHOLD)


func _apply_hp_display(pct: float) -> void:
	_hp_displayed = pct
	if _hp_pct != null:
		_hp_pct.text = "%d%%" % int(round(pct * 100.0))
	var mat := _hp_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_pct", pct)


func _apply_hp_ghost(pct: float) -> void:
	_hp_ghost = pct
	var mat := _hp_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("ghost_pct", pct)


## Punch-scale + brightness flare on the bar when HP goes up — mirrors the
## score's pulse so a heal reads as a beat too. Applied to the bar itself rather
## than to _hp_group, whose modulate belongs to the low-HP warning loop.
func hp_heal_pulse() -> void:
	if _hp_bar == null:
		return
	_hp_bar.pivot_offset = _hp_bar.size * 0.5
	_hp_bar.scale    = Vector2.ONE
	_hp_bar.modulate = Color(1.7, 1.7, 1.7, 1.0)
	var seq := create_tween()
	seq.tween_property(_hp_bar, "scale", Vector2(1.0, 1.30), 0.07) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	seq.tween_property(_hp_bar, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var fade := create_tween()
	fade.tween_property(_hp_bar, "modulate", Color.WHITE, 0.22) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Below the threshold the bar strobes so a distracted player notices. The
## strobe now lives in the shader's `danger` uniform rather than in a modulate
## tween, which leaves modulate free for the heal flare above.
func set_low_health(critical: bool) -> void:
	if _hp_group == null or critical == _hp_critical:
		return
	_hp_critical = critical
	var mat := _hp_bar.material as ShaderMaterial
	if _hp_pulse_tw != null and _hp_pulse_tw.is_valid():
		_hp_pulse_tw.kill()
	if critical:
		_hp_pulse_tw = _hp_group.create_tween().set_loops()
		_hp_pulse_tw.tween_method(_apply_danger, 0.25, 1.0, 0.35) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_hp_pulse_tw.tween_method(_apply_danger, 1.0, 0.25, 0.35) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	elif mat != null:
		mat.set_shader_parameter("danger", 0.0)


func _apply_danger(v: float) -> void:
	var mat := _hp_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("danger", v)


## Lives are tracked in Run.song_lives and were previously invisible until the
## death screen — the player had no way to know how much rope was left.
func set_lives(remaining: int, total: int) -> void:
	if _hp_group == null:
		return
	total = maxi(total, 0)
	if _hp_pips.size() != total:
		for pip in _hp_pips:
			if pip != null:
				pip.queue_free()
		_hp_pips.clear()
		for i in range(total):
			var pip := _make_bar(5.0, 0.0, 0.0)
			pip.material.set_shader_parameter("edge_px", 1.2)
			pip.material.set_shader_parameter("glow_px", 5.0)
			pip.material.set_shader_parameter("ghost_color", Color(0, 0, 0, 0))
			_anchor_tl(pip)
			_hp_group.add_child(pip)
			_hp_pips.append(pip)
		_layout_pips()

	for i in range(_hp_pips.size()):
		var spent: bool = i >= remaining
		var mat := _hp_pips[i].material as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("fill_pct", 0.0 if spent else 1.0)
		mat.set_shader_parameter("ghost_pct", 0.0)
		# A spent pip still has to READ as a spent pip — at 0.30 alpha the empty
		# chassis all but vanished, so three lives looked like one.
		_hp_pips[i].modulate = Color(1, 1, 1, 0.62) if spent else Color.WHITE


# ═════════════════════════════════════════════════════════════════════════════
# Charge / overdrive
# ═════════════════════════════════════════════════════════════════════════════

## The drop-buildup meter. `state` is a short cue such as "HOLD" or "RELEASE".
func set_charge(pct: float, state: String, active: bool) -> void:
	if _charge_group == null:
		return
	_charge_group.visible = active
	if not active:
		return
	var p: float = clampf(pct, 0.0, 1.0)
	_charge_cap.text   = "CHARGE"
	_charge_state.text = state
	_charge_pct.text   = "%d%%" % int(round(p * 100.0))
	var mat := _charge_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_pct", p)
		mat.set_shader_parameter("ghost_pct", p)
		# Cyan while building, whitening to gold as it approaches full.
		mat.set_shader_parameter("fill_color", UiStyle.CYAN.lerp(Color(1.00, 0.95, 0.35), p))
	_charge_pct.self_modulate = Color(0.80, 0.98, 1.00).lerp(Color(1.00, 0.95, 0.35), p)


## The ×100 window after a clean drop release. Reuses the charge meter chassis
## but drains as a countdown, so the player can see the window closing.
func set_overdrive(seconds_left: float, total_seconds: float) -> void:
	if _charge_group == null:
		return
	if seconds_left <= 0.0:
		_charge_group.visible = false
		return
	_charge_group.visible = true
	var f: float = clampf(seconds_left / maxf(total_seconds, 0.001), 0.0, 1.0)
	_charge_cap.text   = "OVERDRIVE"
	_charge_state.text = "×100"
	_charge_pct.text   = "%.1fs" % seconds_left
	_charge_cap.self_modulate   = UiStyle.GOLD
	_charge_state.self_modulate = UiStyle.GOLD
	_charge_pct.self_modulate   = UiStyle.GOLD
	var mat := _charge_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_pct", f)
		mat.set_shader_parameter("ghost_pct", f)
		mat.set_shader_parameter("fill_color", UiStyle.GOLD)
		mat.set_shader_parameter("fill_color2", Color(1.00, 0.55, 0.90))


## Restores the charge meter's normal palette after an overdrive window ends.
func clear_overdrive() -> void:
	if _charge_group == null:
		return
	_charge_cap.self_modulate   = Color(0.60, 0.95, 1.00, 0.95)
	_charge_state.self_modulate = Color(1.00, 0.95, 0.55, 0.95)
	var mat := _charge_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_color2", Color(1.00, 0.95, 0.35))


# ═════════════════════════════════════════════════════════════════════════════
# Flow / wall jump
# ═════════════════════════════════════════════════════════════════════════════

func set_flow(hits: int, total: int, mult: int, active: bool) -> void:
	if _flow_group == null:
		return
	_flow_group.visible = active and total > 0
	if not _flow_group.visible:
		return
	var f: float = float(hits) / float(maxi(total, 1))
	_flow_cap.text   = "FLOW  ×%d" % mult
	_flow_value.text = "%d / %d" % [hits, total]
	var mat := _flow_bar.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill_pct", f)
		mat.set_shader_parameter("ghost_pct", f)


## A one-shot colour punch on the combo readout — gold on a catch, red on a
## drop. Drives modulate rather than a theme override, so it costs one
## RenderingServer call and never re-shapes the text.
func combo_flash(col: Color, hold: float = 0.05, back: float = 0.14) -> void:
	if _combo_value == null or not _combo_value.visible:
		return
	var tw := create_tween()
	tw.tween_property(_combo_value, "modulate", col, hold)
	tw.tween_property(_combo_value, "modulate", Color.WHITE, back)


func set_wall_jump(active: bool, alpha: float = 1.0) -> void:
	if _wj_card == null:
		return
	_wj_card.visible = active
	if active:
		_wj_card.modulate = Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0))


## A transient banner: streak milestones, PERFECT FLOW, OVERDRIVE, DROPPED.
## These were the last things in gameplay still drawn in Godot's default font on
## a bare outline, which is exactly why they looked out of place next to the
## rebuilt HUD.
##
## It hangs at _CALLOUT_ROW, high on the screen rather than across the middle of
## it, because the gates the player is reading arrive through the centre.
##
## `intensity` (0-1) is how big a deal this banner is, and it is not a flag with
## two settings: type size, chamfer depth, edge bloom, entry overshoot, dwell,
## shockwave rings, radial sparks, screen rock and - at the top of the range - a
## running hue all scale off it continuously. A x200 streak is meant to look like
## a different event from a x10, not the same banner in another colour.
##
## Only one is ever on screen: a new banner replaces the one in flight rather
## than stacking on top of it.
func show_callout(text: String, col: Color, hold: float = 0.70,
		intensity: float = 0.0) -> void:
	if _root == null:
		return
	if _callout_card != null and is_instance_valid(_callout_card):
		_callout_card.queue_free()
	var s: float = _s
	var i: float = clampf(intensity, 0.0, 1.0)
	_callout_intensity = i
	_callout_hue       = 0.0
	_callout_shake     = _CALLOUT_SHAKE_S * i

	var card := PlatePanel.create(int((18.0 + 14.0 * i) * s), col, (20.0 + 16.0 * i) * s)
	card.set_cuts(1.0, 0.0, 1.0, 0.0)
	# Written straight onto the plate uniforms rather than through set_accent(),
	# which re-applies the NORMAL state and would flatten the bloom set here.
	card.set_param("edge_color",  col)
	card.set_param("edge_color2", col.lightened(0.35 * i))
	card.set_param("edge_px",     1.7 + 2.6 * i)
	card.set_param("glow_px",     12.0 + 40.0 * i)
	card.set_param("grid_amount", 0.14 + 0.24 * i)
	card.set_param("scan_amount", 0.35 + 0.45 * i)
	card.anchor_left = 0.5; card.anchor_right  = 0.5
	card.anchor_top  = _CALLOUT_ROW; card.anchor_bottom = _CALLOUT_ROW
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.modulate = Color(1, 1, 1, 0)
	_root.add_child(card)
	_callout_card = card

	var lbl := UiStyle.label(text, UiStyle.display(900, 5.0 + 2.5 * i),
		int((34.0 + 17.0 * i) * s), Color.WHITE, int(6.0 * i * s))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.self_modulate = col
	card.content.add_child(lbl)
	_callout_label = lbl

	# The plate's size comes from its content, so the punch pivot can only be set
	# once layout has actually measured it.
	card.resized.connect(func() -> void:
		card.pivot_offset = card.size * 0.5)

	# Shockwave: one ring at the low end, three at the top, each a copy of the
	# banner's own silhouette blown outward on a slight stagger.
	var rings: int = 1 + int(round(i * 2.0))
	for r in rings:
		_callout_ring(card, col, 0.05 * float(r),
			(220.0 + 90.0 * float(r) + 160.0 * i) * s)

	if i > 0.05:
		_callout_sparks(card, col, int(round(6.0 + 16.0 * i)), i)

	var s0: float = 0.82 - 0.26 * i
	card.scale = Vector2(s0, s0)
	# Bound to the card, not to the HUD: a replacement banner frees this one
	# mid-flight, and a HUD-owned tween would then be driving a freed node.
	var tw := card.create_tween()
	tw.set_parallel(true)
	tw.tween_property(card, "modulate", Color.WHITE, 0.10)
	tw.tween_property(card, "scale", Vector2.ONE, 0.28 + 0.14 * i) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	var s1: float = 1.06 + 0.18 * i
	var out := card.create_tween()
	out.tween_interval(0.10 + hold)
	out.tween_property(card, "modulate:a", 0.0, 0.25)
	out.parallel().tween_property(card, "scale", Vector2(s1, s1), 0.25) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	out.tween_callback(card.queue_free)


## One expanding echo of the banner silhouette: fill, grid and scanlines off,
## edge and bloom only, so it reads as a shockwave rather than a second card.
## Parented to the card so it inherits the banner's centre for free.
##
## `pad` is how far past the banner the ring travels, in PIXELS, converted to a
## scale factor once the card has been measured. A fixed scale factor cannot
## work here: the same 2.4x that looks like a shockwave around a "x10 STREAK"
## throws the ring clean off both edges of the screen around the much wider
## "x200 UNSTOPPABLE".
func _callout_ring(card: PlatePanel, col: Color, delay: float, pad: float) -> void:
	var ring := PlateChassis.make_plate(24.0 * _s, false)
	PlateChassis.set_param(ring, "fill_amount", 0.0)
	PlateChassis.set_param(ring, "grid_amount", 0.0)
	PlateChassis.set_param(ring, "scan_amount", 0.0)
	PlateChassis.set_param(ring, "idle_pulse",  0.0)
	PlateChassis.set_param(ring, "edge_px",     2.4)
	PlateChassis.set_param(ring, "glow_px",     28.0)
	PlateChassis.set_param(ring, "edge_color",  col)
	PlateChassis.set_param(ring, "edge_color2", col.lightened(0.4))
	ring.modulate = Color(1, 1, 1, 0)
	card.add_child(ring)
	card.move_child(ring, 0)   # under the plate: only the overhang shows
	card.resized.connect(func() -> void:
		PlateChassis.resize(ring, card.size)
		ring.pivot_offset = card.size * 0.5)

	# Started from the resize, not from here: the card is measured from its own
	# content, so until layout has run there is no width to turn `pad` into a
	# scale factor against.
	card.resized.connect(func() -> void:
		var grow: float = 1.0 + pad / maxf(card.size.x, 1.0)

		var fade := ring.create_tween()
		fade.tween_interval(delay)
		fade.tween_property(ring, "modulate:a", 0.75, 0.06)
		fade.tween_property(ring, "modulate:a", 0.0, 0.50)

		var push := ring.create_tween()
		push.tween_interval(delay)
		push.tween_property(ring, "scale", Vector2(grow, grow), 0.56) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		push.tween_callback(ring.queue_free)
	, CONNECT_ONE_SHOT)


## Radial dashes thrown out of the banner centre. Positioned from the viewport
## rather than from the card, so they can be fired before the plate has been
## measured, and slotted under the card in the draw order so they fly out from
## behind the type instead of across it.
func _callout_sparks(card: PlatePanel, col: Color, count: int, i: float) -> void:
	var s: float = _s
	var cx: float = _vp.x * 0.5
	var cy: float = _vp.y * _CALLOUT_ROW
	for k in count:
		var ang: float = TAU * (float(k) + randf_range(-0.3, 0.3)) / float(count)
		var w: float = (24.0 + 34.0 * randf()) * s * (0.7 + 0.6 * i)
		var h: float = (2.5 + 2.5 * i) * s
		var sp := ColorRect.new()
		sp.color = col.lightened(0.30)
		_anchor_tl(sp)
		_set_rect(sp, cx, cy - h * 0.5, w, h)
		sp.pivot_offset = Vector2(0.0, h * 0.5)
		sp.rotation = ang
		sp.modulate = Color(1, 1, 1, 0)
		_root.add_child(sp)
		_root.move_child(sp, card.get_index())

		var d0: float = (55.0 + 45.0 * i) * s
		var d1: float = d0 + (110.0 + 170.0 * i) * s * randf_range(0.7, 1.25)
		# Offsets, not `position`: a freshly added Control has no valid position
		# until the next layout pass, but its offsets are authoritative at once.
		var mv := sp.create_tween()
		mv.tween_method(func(d: float) -> void:
			_set_rect(sp, cx + cos(ang) * d, cy + sin(ang) * d - h * 0.5, w, h)
		, d0, d1, 0.45 + 0.25 * i).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)

		var fd := sp.create_tween()
		fd.tween_property(sp, "modulate:a", 1.0, 0.06)
		fd.tween_property(sp, "modulate:a", 0.0, 0.40 + 0.25 * i)
		fd.tween_callback(sp.queue_free)


## The part of a banner that cannot be baked into a tween: a damped rock on the
## way in, and a hue that keeps moving for the top tier of streaks.
func _update_callout(delta: float) -> void:
	if _callout_intensity <= 0.05:
		return
	if _callout_card == null or not is_instance_valid(_callout_card):
		_callout_intensity = 0.0
		_callout_label     = null
		return
	var i: float = _callout_intensity

	if _callout_shake > 0.0:
		_callout_shake = maxf(_callout_shake - delta, 0.0)
		# Rotation rather than a position offset: the card is placed by its
		# anchors, so nudging its offsets would fight the next layout pass.
		var amp: float = 0.045 * i * (_callout_shake / _CALLOUT_SHAKE_S)
		_callout_card.rotation = sin(float(Time.get_ticks_msec()) * 0.055) * amp
		if _callout_shake <= 0.0:
			_callout_card.rotation = 0.0

	# Only the top tier runs the hue. Below it the milestone colour is what tells
	# the tiers apart, and a rotating hue would erase that distinction.
	if i >= 0.75:
		_callout_hue = fposmod(_callout_hue + delta * (0.35 + i * 0.85), 1.0)
		var c: Color = Color.from_hsv(_callout_hue, 0.72, 1.0)
		_callout_card.set_param("edge_color",  c)
		_callout_card.set_param("edge_color2",
			Color.from_hsv(fposmod(_callout_hue + 0.35, 1.0), 0.72, 1.0))
		if _callout_label != null and is_instance_valid(_callout_label):
			_callout_label.self_modulate = c


# ═════════════════════════════════════════════════════════════════════════════
# Progress / flash / beat / chrome
# ═════════════════════════════════════════════════════════════════════════════

func set_progress(pct: float) -> void:
	if _prog_fill == null:
		return
	_prog_pct = clampf(pct, 0.0, 1.0)
	var gh: float = 10.0 * _s
	var w: float = maxf(_vp.x * _prog_pct, 0.001)
	_set_rect(_prog_fill, 0.0, _vp.y - gh, w, gh)
	var hd: float = 18.0 * _s
	_set_rect(_prog_head, _vp.x * _prog_pct - hd * 0.5, _vp.y - gh * 0.5 - hd * 0.5, hd, hd)


func flash(col: Color, duration: float) -> void:
	if flash_rect == null:
		return
	flash_rect.color = col
	var tw := create_tween()
	tw.tween_property(flash_rect, "color", Color(col.r, col.g, col.b, 0.0), duration)


## Writes the song's beat into every shader that reacts to it. `phase` is the
## gameplay script's existing _beat_phase: 1.0 on the beat, decaying to 0.
## Uniform writes only — no theme overrides, nothing that dirties layout.
func pulse_beat(phase: float) -> void:
	var b: float = clampf(phase, 0.0, 1.0)
	for m in _beat_mats:
		m.set_shader_parameter("beat", b)


## Walks the HUD chrome along the game's signature colour band. The score plate
## and the HP bar run in opposite directions, so they are never on the same
## colour at once but never leave the band either.
func set_chrome_phase(phase: float) -> void:
	var c_score: Color = UiStyle.signature_color(phase)
	var c_hp:    Color = UiStyle.signature_color(-phase, 0.55)
	var c_prog:  Color = UiStyle.signature_color(phase, 0.30)

	# While the score is in its rainbow state it owns its own colours; the band
	# walk would otherwise overwrite them on the very next frame.
	var sm := _score_plate.material as ShaderMaterial
	if sm != null and not _rainbow_on:
		sm.set_shader_parameter("edge_color", c_score)
		sm.set_shader_parameter("edge_color2", UiStyle.signature_color(phase, 0.22))
	var cm := _combo_plate.material as ShaderMaterial
	if cm != null:
		cm.set_shader_parameter("edge_color", c_score)
		cm.set_shader_parameter("edge_color2", UiStyle.GOLD)
	# self_modulate, never add_theme_color_override: an override fires
	# NOTIFICATION_THEME_CHANGED, discarding the Label's shaped-text buffer and
	# re-sorting its containers. Base font_color is white, so the product is
	# identical, and it still stacks with the score-flash tween on modulate.
	if not _rainbow_on:
		_score_cap.self_modulate   = Color(c_score.r, c_score.g, c_score.b, 0.85)
		_score_value.self_modulate = c_score.lightened(0.25)

	var hm := _hp_bar.material as ShaderMaterial
	if hm != null:
		hm.set_shader_parameter("fill_color", c_hp)
		hm.set_shader_parameter("fill_color2", UiStyle.signature_color(-phase, 0.85))
		hm.set_shader_parameter("edge_color", c_hp)
	_hp_pct.self_modulate = c_hp.lightened(0.35)
	_hp_cap.self_modulate = c_hp.lightened(0.15)
	for pip in _hp_pips:
		var pm := pip.material as ShaderMaterial
		if pm != null:
			pm.set_shader_parameter("fill_color", c_hp)
			pm.set_shader_parameter("fill_color2", c_hp)
			pm.set_shader_parameter("edge_color", c_hp)

	var pm2 := _prog_fill.material as ShaderMaterial
	if pm2 != null:
		pm2.set_shader_parameter("fill_color", c_prog)
		pm2.set_shader_parameter("fill_color2", UiStyle.signature_color(phase, 0.60))
	var hm2 := _prog_head.material as ShaderMaterial
	if hm2 != null:
		var hot: Color = c_prog.lightened(0.45)
		hm2.set_shader_parameter("edge_color", hot)
		hm2.set_shader_parameter("edge_color2", hot)


# ═════════════════════════════════════════════════════════════════════════════
# Lyrics
# ═════════════════════════════════════════════════════════════════════════════

func set_lyric_font(f: Font) -> void:
	_lyric_font = f


func lyrics_visible(v: bool) -> void:
	if _lyrics_root != null:
		_lyrics_root.visible = v


## Clears the row and plays the slide-in entrance for a new line.
func lyrics_begin_line() -> void:
	if _lyrics_rows == null:
		return
	# remove_child BEFORE queue_free. queue_free is deferred to the end of the
	# frame, so a freed-but-still-parented row keeps answering get_child_count()
	# — and lyrics_add_word, called later in this same frame, would parent the
	# word to that doomed row and the word would silently never appear. That is
	# the "skipped word" bug: it only shows on the first word or two of a line,
	# whichever land in the same frame the line changed.
	for row in _lyrics_rows.get_children():
		_lyrics_rows.remove_child(row)
		row.queue_free()
	_lyric_row_w = 0.0
	_lyric_last  = null
	# Invalidate any staggered word still waiting on its delay timer from the
	# line we just replaced, so it cannot land in this one.
	_lyric_line_id += 1
	_lyrics_root.modulate.a = 1.0
	_lyrics_slide = 28.0
	create_tween().tween_method(_apply_lyric_slide, 28.0, 0.0, 0.22) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _apply_lyric_slide(v: float) -> void:
	_lyrics_slide = v
	_layout_lyrics()


func lyrics_set_alpha(a: float) -> void:
	if _lyrics_root != null:
		_lyrics_root.modulate.a = clampf(a, 0.0, 1.0)


## Adds one word. `col` drives its outline/glow; `delay` staggers sung lines,
## which arrive as a whole sentence rather than word by word.
## `wipe_s` is how long the karaoke fill takes; 0 fills instantly.
func lyrics_add_word(w: String, col: Color, delay: float = 0.0, wipe_s: float = 0.28) -> void:
	if _lyrics_rows == null:
		return
	if delay > 0.0:
		# Sung lines stagger their words in, so a word can still be waiting here
		# when the next line starts. Checking is_instance_valid(_lyrics_rows) is
		# not enough — that container lives for the whole song; it is the LINE
		# that changed underneath us.
		var line_id: int = _lyric_line_id
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(_lyrics_rows) or line_id != _lyric_line_id:
			return

	var s: float = _s
	var size: int = _lyric_size
	var lbl := Label.new()
	lbl.text = w
	if _lyric_font != null:
		lbl.add_theme_font_override("font", _lyric_font)
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", col)
	lbl.add_theme_constant_override("outline_size", int(10 * s))
	lbl.add_theme_color_override("font_shadow_color", Color(col.r, col.g, col.b, 0.55))
	lbl.add_theme_constant_override("shadow_offset_x", 0)
	lbl.add_theme_constant_override("shadow_offset_y", 0)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Measure before adding, so wrapping is decided this frame rather than a
	# frame after the container has already overflowed.
	var word_w: float = 0.0
	if _lyric_font != null:
		word_w = _lyric_font.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	else:
		word_w = float(w.length()) * float(size) * 0.55
	word_w += 14.0 * s

	var max_w: float = _vp.x * 0.86
	var row: HBoxContainer = _lyrics_rows.get_child(_lyrics_rows.get_child_count() - 1) as HBoxContainer \
		if _lyrics_rows.get_child_count() > 0 else null
	if row == null or (_lyric_row_w + word_w > max_w and _lyric_row_w > 0.0):
		row = HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", int(14 * s))
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lyrics_rows.add_child(row)
		_lyric_row_w = 0.0
	_lyric_row_w += word_w

	# Karaoke wipe: the word starts unsung and fills left to right.
	var wm := ShaderMaterial.new()
	wm.shader = _shader(_LYRIC_SHADER)
	wm.set_shader_parameter("word_width", word_w)
	wm.set_shader_parameter("wipe", 0.0)
	lbl.material = wm

	row.add_child(lbl)
	_position_scrim()

	# The previously sung word steps back so the current one leads.
	if _lyric_last != null and is_instance_valid(_lyric_last):
		var prev: Label = _lyric_last
		create_tween().tween_property(prev, "modulate:a", 0.78, 0.18)
	_lyric_last = lbl

	if wipe_s > 0.0:
		# Captures only the material (a RefCounted the lambda keeps alive), never
		# the Label — capturing a node here would go stale the moment the line is
		# cleared mid-wipe. Bound to the label so it stops when the word goes.
		var wtw := lbl.create_tween()
		wtw.tween_method(func(v: float) -> void:
			wm.set_shader_parameter("wipe", v)
		, 0.0, 1.0, wipe_s).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		wm.set_shader_parameter("wipe", 1.0)

	# Entrance: rise, fade in, elastic settle.
	lbl.position.y = 32.0 * s
	lbl.modulate.a = 0.0
	lbl.scale      = Vector2(1.15, 1.15)
	var tw := lbl.create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", 0.0, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 1.0, 0.16)
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	# Gentle idle float once landed, bound to the label so it stops on free.
	await get_tree().create_timer(0.26).timeout
	if not is_instance_valid(lbl):
		return
	var ph: float = randf() * TAU   # stagger so words do not all bob in sync
	var float_tw := lbl.create_tween().set_loops()
	float_tw.tween_property(lbl, "position:y", -5.0 + sin(ph) * 2.0, 0.85 + randf() * 0.15) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	float_tw.tween_property(lbl, "position:y", 0.0 + sin(ph) * 2.0, 0.85 + randf() * 0.15) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
