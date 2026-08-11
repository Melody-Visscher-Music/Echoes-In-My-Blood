## BeatPreviewControl.gd
## Scrolling beat-timeline preview rendered inside the ManualMapper preview window.
## • X axis = time (seconds).  Playhead is pinned at PLAYHEAD_X from the left edge.
## • Y axis = lane (0 at bottom, 2 at top).
## • Mouse-wheel to zoom in/out.
## • Cyan dot at the playhead shows Meeko's lane (last event before now).
extends Control

## Set by ManualMapper after creation.
var mapper: Node = null

const PLAYHEAD_X : float = 200.0   # pixels from left where cursor lives
const DOT_R      : float = 8.0

const _LANE_COL : Array[Color] = [
	Color(0.30, 0.70, 1.00),   # lane 0 — blue
	Color(0.45, 1.00, 0.40),   # lane 1 — green
	Color(1.00, 0.45, 0.80),   # lane 2 — pink
]

var _zoom : float = 1.0   # pixels-per-second = 100 × _zoom

# ── lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP   # receive scroll events

func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_zoom = minf(_zoom * 1.35, 10.0)
				MOUSE_BUTTON_WHEEL_DOWN:
					_zoom = maxf(_zoom / 1.35, 0.15)

# ── drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	if mapper == null:
		return

	var now    : float = mapper._play_time()
	var evts   : Array = mapper.events
	var bpm    : float = maxf(60.0, float(mapper.bpm))
	var beat_s : float = 60.0 / bpm
	var w      : float = size.x
	var h      : float = size.y
	var pxs    : float = 100.0 * _zoom     # pixels per second

	const TOP  : float = 28.0
	const BOT_PAD : float = 20.0
	var bot    : float = h - BOT_PAD
	var th     : float = bot - TOP          # usable track height
	var lh     : float = th / 3.0          # height of one lane band
	var font   : Font  = ThemeDB.fallback_font

	# ── background ──────────────────────────────────────────────────────────
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.04, 0.09))

	# ── lane bands ──────────────────────────────────────────────────────────
	for ln in range(3):
		var ly0 : float = TOP + (2 - ln) * lh
		var bg  : Color = Color(0.09, 0.07, 0.15) if ln % 2 == 0 else Color(0.12, 0.09, 0.18)
		draw_rect(Rect2(0.0, ly0, w, lh), bg)
		draw_line(Vector2(0.0, ly0 + lh), Vector2(w, ly0 + lh),
				  Color(0.22, 0.18, 0.30), 1.0)
		draw_string(font, Vector2(6.0, ly0 + lh * 0.5 + 5.0),
				  "L%d" % ln, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				  _LANE_COL[ln].darkened(0.25))

	# ── beat grid ───────────────────────────────────────────────────────────
	var t_lo   : float = now - PLAYHEAD_X / pxs
	var t_hi   : float = now + (w - PLAYHEAD_X) / pxs
	var bi     : int   = maxi(0, int(t_lo / beat_s))
	while float(bi) * beat_s <= t_hi:
		var bt  : float = float(bi) * beat_s
		var bx  : float = PLAYHEAD_X + (bt - now) * pxs
		var bar : bool  = (bi % 4 == 0)
		var gc  : Color = Color(0.35, 0.30, 0.50, 0.70) if bar \
						else Color(0.18, 0.15, 0.28, 0.50)
		draw_line(Vector2(bx, TOP), Vector2(bx, bot), gc, 1.5 if bar else 0.5)
		if bar:
			draw_string(font, Vector2(bx + 3.0, TOP - 5.0),
					  "%.1fs" % bt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					  Color(0.50, 0.46, 0.65))
		bi += 1

	# ── events ──────────────────────────────────────────────────────────────
	var meeko_lane : int = 1   # default centre; updated by past events
	for e in evts:
		var et   : float  = float(e.get("t",    0.0))
		var ln   : int    = int(e.get("lane",   1))
		var kind : String = String(e.get("type", "lane"))
		var dur  : float  = float(e.get("dur",  0.10))
		if ln < 0 or ln > 2:
			continue

		# Track Meeko's lane even for off-screen past events
		if et <= now:
			meeko_lane = ln

		var ex : float = PLAYHEAD_X + (et - now) * pxs
		if ex < -60.0 or ex > w + 60.0:
			continue

		var cy  : float = TOP + (2 - ln) * lh + lh * 0.5
		var col : Color = _LANE_COL[ln]

		if kind == "hold":
			# Hold bar
			var bar_w : float = maxf(10.0, dur * pxs)
			draw_rect(Rect2(ex, cy - 6.0, bar_w, 12.0), col.darkened(0.40))
			draw_line(Vector2(ex,           cy - 6.0), Vector2(ex + bar_w, cy - 6.0), col, 2.0)
			draw_line(Vector2(ex,           cy + 6.0), Vector2(ex + bar_w, cy + 6.0), col, 2.0)
			draw_circle(Vector2(ex, cy), DOT_R * 0.75, col)
		else:
			# Tap dot
			draw_circle(Vector2(ex, cy), DOT_R, col)
			draw_arc(Vector2(ex, cy), DOT_R + 2.5, 0.0, TAU, 12,
					 col.lightened(0.3), 1.5)

	# ── Meeko dot ───────────────────────────────────────────────────────────
	var mcy : float = TOP + (2 - meeko_lane) * lh + lh * 0.5
	draw_circle(Vector2(PLAYHEAD_X, mcy), DOT_R + 5.0, Color(0.0, 1.0, 0.85, 0.18))
	draw_circle(Vector2(PLAYHEAD_X, mcy), DOT_R + 3.0, Color(0.0, 1.0, 0.85, 0.60))
	draw_circle(Vector2(PLAYHEAD_X, mcy), DOT_R,       Color(0.0, 1.0, 0.85))

	# ── playhead line ────────────────────────────────────────────────────────
	draw_line(Vector2(PLAYHEAD_X, TOP - 10.0), Vector2(PLAYHEAD_X, bot),
			  Color(1.0, 1.0, 1.0, 0.45), 1.5)
	# Downward triangle marker at top
	var tri := PackedVector2Array([
		Vector2(PLAYHEAD_X,       TOP - 10.0),
		Vector2(PLAYHEAD_X - 7.0, TOP - 22.0),
		Vector2(PLAYHEAD_X + 7.0, TOP - 22.0),
	])
	draw_colored_polygon(tri, Color(1.0, 1.0, 1.0, 0.80))

	# ── zoom hint ────────────────────────────────────────────────────────────
	draw_string(font, Vector2(w - 90.0, h - 5.0),
			  "scroll to zoom  ×%.1f" % _zoom, HORIZONTAL_ALIGNMENT_LEFT,
			  -1, 10, Color(0.38, 0.35, 0.50))
