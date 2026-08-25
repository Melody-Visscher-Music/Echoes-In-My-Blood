shader_type canvas_item;
render_mode blend_mix, unshaded;

// ─────────────────────────────────────────────────────────────────────────────
// HUD PLATE — the angular chassis behind every gameplay readout.
//
// Draws a chamfered box (corners sliced at 45°) with a dark translucent fill,
// a faint holo grid, drifting scanlines, a bright inner edge and an outer
// bloom. `beat` is written once per frame from the gameplay script's existing
// _beat_phase, so the whole HUD breathes on the song's BPM.
//
// The silhouette is an SDF rather than a StyleBoxFlat because StyleBoxFlat can
// only round corners, never cut them — and the cut corner is the entire point
// of the look.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec2  rect_size    = vec2(268.0, 112.0);
uniform float cut_size     = 20.0;                                  // chamfer depth, px
uniform vec4  edge_color   : source_color = vec4(1.00, 0.35, 0.68, 1.0);
uniform vec4  edge_color2  : source_color = vec4(0.36, 0.86, 1.00, 1.0);
uniform vec4  fill_color   : source_color = vec4(0.035, 0.018, 0.085, 0.88);
uniform float beat         : hint_range(0.0, 1.0) = 0.0;
// Menus have no music to pulse against, and pause/death/results all run with the
// track stopped. Setting this makes the plate derive its own slow breathe from
// TIME instead of reading `beat` — so a screen full of plates costs zero
// per-frame uniform writes on the CPU side.
uniform float idle_pulse   : hint_range(0.0, 1.0) = 0.0;
uniform float idle_speed   = 1.5;
uniform float edge_px      = 1.7;
uniform float glow_px      = 12.0;
uniform float grid_px      = 15.0;
uniform float scan_speed   = 11.0;
uniform float scan_amount  : hint_range(0.0, 1.0) = 0.35;
uniform float grid_amount  : hint_range(0.0, 1.0) = 0.30;
uniform float fill_amount  : hint_range(0.0, 1.0) = 1.0;

// Which corners get sliced. 1.0 = cut, 0.0 = square.
uniform float cut_tl = 1.0;
uniform float cut_tr = 0.0;
uniform float cut_br = 1.0;
uniform float cut_bl = 0.0;

const float INV_SQRT2 = 0.70710678;

float sd_box(vec2 p, vec2 h) {
	vec2 q = abs(p) - h;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Slices one 45° corner off an SDF. `n` points outward along the corner
// diagonal; the plane is placed so it removes `cut` px from each adjacent edge.
float slice(float d, vec2 p, vec2 h, vec2 n, float cut, float enabled) {
	if (enabled < 0.5) {
		return d;
	}
	// Distance from the plane through the corner, pulled inward by cut.
	float c = (h.x + h.y - cut) * INV_SQRT2;
	return max(d, dot(p, n) - c);
}

void fragment() {
	// Incoming COLOR carries the rect colour and, on this renderer, the
	// CanvasItem modulate chain. Multiplying the result by it means fades
	// via modulate/self_modulate work whether or not the renderer applies
	// modulate again afterwards - these rects are white, so it is a no-op
	// in the case where it does. (MODULATE does not exist in this build.)
	vec4 src = COLOR;
	vec2 h = rect_size * 0.5;
	vec2 p = (UV - 0.5) * rect_size;

	float cut = min(cut_size, min(h.x, h.y));
	float d = sd_box(p, h);
	d = slice(d, p, h, vec2(-INV_SQRT2, -INV_SQRT2), cut, cut_tl);
	d = slice(d, p, h, vec2( INV_SQRT2, -INV_SQRT2), cut, cut_tr);
	d = slice(d, p, h, vec2( INV_SQRT2,  INV_SQRT2), cut, cut_br);
	d = slice(d, p, h, vec2(-INV_SQRT2,  INV_SQRT2), cut, cut_bl);

	float b = clamp(beat, 0.0, 1.0);
	// Sharp attack, slow decay — the same shape _beat_phase has, so an idling
	// menu plate and a beating HUD plate read as the same material.
	float idle = pow(0.5 + 0.5 * sin(TIME * idle_speed), 3.0);
	b = mix(b, idle, clamp(idle_pulse, 0.0, 1.0));

	// ── interior ────────────────────────────────────────────────────────────
	float inside = smoothstep(0.0, -1.2, d);

	// Holo grid: thin lines on a fixed pixel pitch, brightest near the edges so
	// the middle of the plate stays quiet behind the numerals.
	vec2 g = abs(fract(p / grid_px) - 0.5) / fwidth(p / grid_px);
	float grid = 1.0 - min(min(g.x, g.y), 1.0);

	// Scanlines drifting upward, plus a single brighter sweep line.
	float scan_y = p.y - TIME * scan_speed;
	float scan = 0.5 + 0.5 * sin(scan_y * 1.15);
	scan = pow(scan, 3.0);
	float sweep = smoothstep(0.92, 1.0, fract(-TIME * 0.11 + UV.y * 0.5 + 0.5));

	// Edge falloff for the interior detail — detail hugs the chassis outline.
	float rim = smoothstep(-26.0, -2.0, d);

	vec3 tint = mix(edge_color.rgb, edge_color2.rgb, clamp(UV.x * 0.65 + UV.y * 0.35, 0.0, 1.0));

	vec3 interior = fill_color.rgb;
	interior += tint * grid   * grid_amount * (0.25 + rim * 0.75);
	interior += tint * scan   * scan_amount * 0.16;
	interior += tint * sweep  * 0.10;
	interior += tint * b * 0.05;

	float interior_a = fill_color.a * fill_amount;

	// ── edge ────────────────────────────────────────────────────────────────
	// A bright hairline just inside the outline, brightening on the beat.
	float ew = edge_px * (1.0 + b * 0.35);
	float edge = smoothstep(-ew, -ew * 0.35, d) * smoothstep(0.6, -0.2, d);
	edge = clamp(edge, 0.0, 1.0);

	// ── outer bloom ─────────────────────────────────────────────────────────
	float gw = glow_px * (1.0 + b * 0.55);
	float glow = smoothstep(gw, 0.0, d) * (1.0 - inside);
	glow *= 0.30 + b * 0.30;

	vec3  col = interior * inside;
	float a   = interior_a * inside;

	vec3 edge_rgb = tint * (1.5 + b * 1.1);
	col = mix(col, edge_rgb, edge);
	a   = max(a, edge * edge_color.a);

	col += tint * glow;
	a    = max(a, glow * 0.85);

	if (a <= 0.002) {
		discard;
	}
	COLOR = vec4(col, a) * src;
}
