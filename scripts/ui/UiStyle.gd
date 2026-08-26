class_name UiStyle
extends RefCounted

## Shared visual language for SIAG's UI — fonts, palette, stylebox factories and
## the viewport scale rule, in one place.
##
## Before this existed, every screen invented its own: Main.gd, HowToPlay.gd and
## Section_BeatRunner3d.gd each carried a near-identical _ui_s()/_card_style()
## pair, and the gameplay HUD used Godot's DEFAULT FONT for every label while 45
## display faces sat unused in res://fonts/. That is the single biggest reason
## the HUD read as placeholder art next to the 3D work.
##
## Everything here is static — call it as UiStyle.display(48), never instance it.


# ── Fonts ────────────────────────────────────────────────────────────────────
# Loaded once on first use and shared. FontVariation wrappers are cached per
# configuration because building one per Label would defeat the point: Godot
# caches shaped text per (font, size) pair, and a fresh FontVariation instance
# is a cache miss every time.

const _FONT_DIR: String = "res://fonts/"

const _DISPLAY_TTF: String = "Orbitron-VariableFont_wght.ttf"
const _CAPTION_TTF: String = "Syncopate-Bold.ttf"
const _BODY_TTF:    String = "Exo2-SemiBold.ttf"

static var _base_cache: Dictionary = {}
static var _var_cache:  Dictionary = {}


static func _base(file: String) -> FontFile:
	if _base_cache.has(file):
		return _base_cache[file]
	var path: String = _FONT_DIR + file
	var f: FontFile = null
	if ResourceLoader.exists(path):
		f = load(path) as FontFile
	if f == null:
		push_warning("[UiStyle] Missing font %s - falling back to the theme default." % path)
	_base_cache[file] = f
	return f


## Wide display face for numerals — score, HP %, combo, multipliers.
## `weight` maps onto Orbitron's variable weight axis (400–900).
static func display(weight: int = 700, tracking: float = 0.0) -> Font:
	return _variation(_DISPLAY_TTF, weight, tracking)


## All-caps caption face for labels: "SCORE", "HP", "COMBO", "CHARGE".
## Tracked out by default — letterspacing is what makes small caps read as a
## designed label rather than as leftover debug text.
static func caption(tracking: float = 3.0) -> Font:
	return _variation(_CAPTION_TTF, 0, tracking)


## Body face for callouts and hints.
static func body(tracking: float = 0.0) -> Font:
	return _variation(_BODY_TTF, 0, tracking)


static func _variation(file: String, weight: int, tracking: float) -> Font:
	var base: FontFile = _base(file)
	if base == null:
		return null
	if weight <= 0 and is_zero_approx(tracking):
		return base
	var key: String = "%s|%d|%.2f" % [file, weight, tracking]
	if _var_cache.has(key):
		return _var_cache[key]
	var fv := FontVariation.new()
	fv.base_font = base
	if weight > 0:
		# Real variable-font axis, not a faux-bold — Orbitron carries a wght axis.
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("weight"): weight}
	if not is_zero_approx(tracking):
		fv.spacing_glyph = int(round(tracking))
	_var_cache[key] = fv
	return fv


# ── Palette ──────────────────────────────────────────────────────────────────
# Anchored to GameConfig's level colours so the HUD and the track agree. Held as
# plain constants rather than read from the GameConfig autoload, so this module
# stays dependency-free and loadable on its own; if the HUD ever needs to follow
# the player's edited level colours, read GameConfig at the call site.

const INK:      Color = Color(0.035, 0.018, 0.085, 1.0)   # plate fill
const INK_DEEP: Color = Color(0.020, 0.010, 0.050, 1.0)   # veils, track interiors
const PINK:     Color = Color(1.00, 0.35, 0.68, 1.0)
const VIOLET:   Color = Color(0.65, 0.22, 1.00, 1.0)
const CYAN:     Color = Color(0.36, 0.86, 1.00, 1.0)
const GOLD:     Color = Color(1.00, 0.82, 0.18, 1.0)      # wall-jump bonus
const DANGER:   Color = Color(1.00, 0.24, 0.30, 1.0)      # low HP, miss
const GHOST:    Color = Color(1.00, 0.92, 0.96, 1.0)      # damage-lag trail
const TEXT_DIM: Color = Color(0.82, 0.76, 0.95, 1.0)


# ── Signature colour drift ───────────────────────────────────────────────────

## The HUD's chrome never settles on one colour — but it no longer sweeps the
## full 360° hue wheel either. A constantly rotating fully-saturated hue is what
## made the old HUD read as a default demo; this walks the game's OWN band
## (pink → violet → cyan) and ping-pongs back, so the drift always looks
## deliberate and always belongs to this game.
##
## `phase` is a free-running 0–1 value; `offset` shifts an element along the
## band so the score card and the HP bar are never on the same colour at once.
## Negate the phase to run an element backwards through the band.
const _BAND: Array[Color] = [PINK, VIOLET, CYAN]

static func signature_color(phase: float, offset: float = 0.0) -> Color:
	# Ping-pong 0→1→0 so the walk reverses instead of snapping back to pink.
	var t: float = fposmod(phase + offset, 2.0)
	if t > 1.0:
		t = 2.0 - t
	var span: float = float(_BAND.size() - 1)
	var f: float = clampf(t, 0.0, 1.0) * span
	var i: int = clampi(int(f), 0, _BAND.size() - 2)
	return _BAND[i].lerp(_BAND[i + 1], f - float(i))


# ── Scale ────────────────────────────────────────────────────────────────────

## Viewport-relative UI scale against the 1920×1080 authoring reference.
## Clamped so the UI never grows large enough to crowd the play lanes on an
## ultrawide, nor shrinks to unreadable in a small window.
static func scale_for(vp: Vector2) -> float:
	return clampf(minf(vp.x / 1920.0, vp.y / 1080.0), 0.75, 1.3)


# ── Styleboxes ───────────────────────────────────────────────────────────────
# Kept for the flat/rounded chrome that does not need the plate shader — small
# chips, pills and menu panels. Anything with a CUT corner has to come from
# shaders/hud_plate.gdshader instead: StyleBoxFlat can only round corners.

static func card(border_col: Color, radius: int = 10,
		bg: Color = Color(0.04, 0.02, 0.10, 0.90)) -> StyleBoxFlat:
	var sf := StyleBoxFlat.new()
	sf.bg_color     = bg
	sf.border_color = border_col
	sf.border_width_left = 1; sf.border_width_right  = 1
	sf.border_width_top  = 1; sf.border_width_bottom = 1
	sf.corner_radius_top_left     = radius; sf.corner_radius_top_right    = radius
	sf.corner_radius_bottom_left  = radius; sf.corner_radius_bottom_right = radius
	sf.shadow_color = Color(border_col.r, border_col.g, border_col.b, 0.35)
	sf.shadow_size  = 8
	return sf


static func pill(fill_col: Color, radius: float, border_col: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	return pill_sides(fill_col, radius, true, true, border_col)


## Pill with independently rounded ends, so several can sit flush and still read
## as one continuous bar.
static func pill_sides(fill_col: Color, radius: float, round_left: bool, round_right: bool,
		border_col: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sf := StyleBoxFlat.new()
	sf.bg_color = fill_col
	var r: int = int(radius)
	sf.corner_radius_top_left     = r if round_left  else 0
	sf.corner_radius_bottom_left  = r if round_left  else 0
	sf.corner_radius_top_right    = r if round_right else 0
	sf.corner_radius_bottom_right = r if round_right else 0
	if border_col.a > 0.0:
		sf.border_color = border_col
		sf.border_width_left = 1; sf.border_width_right  = 1
		sf.border_width_top  = 1; sf.border_width_bottom = 1
	return sf


# ── Label helpers ────────────────────────────────────────────────────────────

## Builds a Label with font, size and colour in one call.
##
## Pass Color.WHITE for `col` on anything whose colour will drift at runtime,
## and drive the visible colour through self_modulate instead. Per-frame
## recolouring MUST NOT use add_theme_color_override: an override fires
## NOTIFICATION_THEME_CHANGED, which throws away the Label's shaped-text buffer
## AND calls update_minimum_size(), dirtying every enclosing container and
## queueing a layout sort. Doing that once a frame means re-shaping text at the
## render rate. self_modulate is a plain CanvasItem property — one
## RenderingServer call, no re-shape, no re-sort.
static func label(text: String, font: Font, size: int, col: Color,
		outline: int = 0, outline_col: Color = Color(0, 0, 0, 0.65)) -> Label:
	var l := Label.new()
	l.text = text
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", outline_col)
		l.add_theme_constant_override("outline_size", outline)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ── Engine widgets ───────────────────────────────────────────────────────────
# HSlider and OptionButton ship with Godot's default grey chrome, which is the
# most conspicuously unstyled thing left on a settings panel once everything
# around it is neon. Neither can take the plate shader (they draw through the
# theme), so they get styleboxes in the palette instead.

static func style_slider(sl: HSlider, s: float = 1.0) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.09, 0.05, 0.16, 1.0)
	track.border_color = Color(VIOLET.r, VIOLET.g, VIOLET.b, 0.55)
	track.border_width_top = 1; track.border_width_bottom = 1
	track.border_width_left = 1; track.border_width_right = 1
	track.content_margin_top = 4.0 * s; track.content_margin_bottom = 4.0 * s
	sl.add_theme_stylebox_override("slider", track)

	var fill := StyleBoxFlat.new()
	fill.bg_color = PINK
	fill.content_margin_top = 4.0 * s; fill.content_margin_bottom = 4.0 * s
	sl.add_theme_stylebox_override("grabber_area", fill)
	sl.add_theme_stylebox_override("grabber_area_highlight", fill)

	# No grabber texture in the theme, so draw the knob as a small bright box.
	var knob := StyleBoxFlat.new()
	knob.bg_color = Color(1.0, 0.92, 1.0)
	knob.content_margin_left = 3.0 * s; knob.content_margin_right = 3.0 * s
	knob.content_margin_top = 9.0 * s;  knob.content_margin_bottom = 9.0 * s
	sl.add_theme_stylebox_override("grabber", knob)
	sl.add_theme_stylebox_override("grabber_highlight", knob)

	# Focus feedback. A mouse user always knows which slider they grabbed; a
	# keyboard or gamepad user had nothing at all to go on, because Slider's
	# focus stylebox is empty in the default theme and the knob never changed.
	# Repaint the track and the fill instead — that reads at a glance.
	var track_focus := StyleBoxFlat.new()
	track_focus.bg_color = Color(0.13, 0.07, 0.22, 1.0)
	track_focus.border_color = CYAN
	track_focus.border_width_top = 1; track_focus.border_width_bottom = 1
	track_focus.border_width_left = 1; track_focus.border_width_right = 1
	track_focus.content_margin_top = 4.0 * s; track_focus.content_margin_bottom = 4.0 * s

	var fill_focus := StyleBoxFlat.new()
	fill_focus.bg_color = CYAN
	fill_focus.content_margin_top = 4.0 * s; fill_focus.content_margin_bottom = 4.0 * s

	sl.focus_entered.connect(func() -> void:
		sl.add_theme_stylebox_override("slider", track_focus)
		sl.add_theme_stylebox_override("grabber_area", fill_focus)
		sl.add_theme_stylebox_override("grabber_area_highlight", fill_focus))
	sl.focus_exited.connect(func() -> void:
		sl.add_theme_stylebox_override("slider", track)
		sl.add_theme_stylebox_override("grabber_area", fill)
		sl.add_theme_stylebox_override("grabber_area_highlight", fill))


static func style_option(ob: OptionButton, s: float = 1.0) -> void:
	var mk := func(bg: Color, border: Color) -> StyleBoxFlat:
		var sf := StyleBoxFlat.new()
		sf.bg_color = bg
		sf.border_color = border
		sf.border_width_left = 1; sf.border_width_right = 1
		sf.border_width_top  = 1; sf.border_width_bottom = 1
		sf.content_margin_left   = 14.0 * s
		sf.content_margin_right  = 14.0 * s
		sf.content_margin_top    = 7.0 * s
		sf.content_margin_bottom = 7.0 * s
		return sf
	var edge: Color = Color(VIOLET.r, VIOLET.g, VIOLET.b, 0.75)
	ob.add_theme_stylebox_override("normal",  mk.call(Color(0.07, 0.035, 0.14, 0.95), edge))
	ob.add_theme_stylebox_override("hover",   mk.call(Color(0.16, 0.07, 0.28, 0.95), PINK))
	ob.add_theme_stylebox_override("pressed", mk.call(Color(0.22, 0.09, 0.36, 1.0), PINK))
	ob.add_theme_stylebox_override("focus",   mk.call(Color(0.07, 0.035, 0.14, 0.95), PINK))
	ob.add_theme_font_override("font", body())
	ob.add_theme_font_size_override("font_size", int(15 * s))
	ob.add_theme_color_override("font_color",       TEXT_DIM)
	ob.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 1.0))

	# The dropdown is a separate PopupMenu with its own theme.
	var pop: PopupMenu = ob.get_popup()
	if pop != null:
		var panel := StyleBoxFlat.new()
		panel.bg_color = Color(0.045, 0.022, 0.10, 0.98)
		panel.border_color = edge
		panel.border_width_left = 1; panel.border_width_right = 1
		panel.border_width_top  = 1; panel.border_width_bottom = 1
		pop.add_theme_stylebox_override("panel", panel)
		var hover := StyleBoxFlat.new()
		hover.bg_color = Color(0.28, 0.10, 0.46, 1.0)
		pop.add_theme_stylebox_override("hover", hover)
		pop.add_theme_font_override("font", body())
		pop.add_theme_font_size_override("font_size", int(15 * s))
		pop.add_theme_color_override("font_color",       TEXT_DIM)
		pop.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 1.0))


## Thousands separators. The score passes six digits in a normal run, and
## "1362500" is genuinely hard to read at a glance mid-song; "1,362,500" is not.
static func group_digits(n: int) -> String:
	var neg: bool = n < 0
	var s: String = str(absi(n))
	var out: String = ""
	var c: int = 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if neg else out
