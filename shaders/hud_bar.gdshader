shader_type canvas_item;
render_mode blend_mix, unshaded;

// ─────────────────────────────────────────────────────────────────────────────
// HUD BAR — one shader for every meter in the HUD (health, charge, flow).
//
// Silhouette is a parallelogram (slanted ends) rather than a pill, matching the
// chamfered plates. Beyond the plain fill it draws:
//
//   • a GHOST bar — a pale trail left behind when the value drops, draining
//     toward the real fill a beat later. Standard fighting-game damage lag: it
//     makes "you just lost some" legible without reading the number.
//   • tick marks at even fractions, so the fill has a scale to read against.
//   • diagonal energy stripes scrolling inside the fill.
//   • the lightning bolt from the original HP bar, kept intact and gated by
//     `bolt_amount` — its HP-reactive tuning (sluggish ember when low, frantic
//     arcing when full) was worth preserving.
//   • a red edge strobe driven by `danger` for the low-health warning.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec2  rect_size    = vec2(300.0, 26.0);
uniform float fill_pct     : hint_range(0.0, 1.0) = 1.0;
uniform float ghost_pct    : hint_range(0.0, 1.0) = 1.0;
uniform vec4  fill_color   : source_color = vec4(1.00, 0.35, 0.68, 1.0);
uniform vec4  fill_color2  : source_color = vec4(0.65, 0.22, 1.00, 1.0);
uniform vec4  ghost_color  : source_color = vec4(1.00, 0.92, 0.96, 0.55);
uniform vec4  track_color  : source_color = vec4(0.045, 0.02, 0.10, 0.90);
uniform vec4  edge_color   : source_color = vec4(1.00, 0.35, 0.68, 0.85);
uniform float beat         : hint_range(0.0, 1.0) = 0.0;
uniform float danger       : hint_range(0.0, 1.0) = 0.0;
uniform float bolt_amount  : hint_range(0.0, 1.0) = 1.0;
uniform float bolt_seed    = 0.0;
uniform float skew_px      = 9.0;    // end slant; 0 = square ends
uniform float edge_px      = 1.6;
uniform float glow_px      = 9.0;
uniform float tick_count   = 4.0;    // ticks at 1/4, 2/4, 3/4
uniform float stripe_px    = 13.0;
uniform float stripe_speed = 22.0;

float sd_box(vec2 p, vec2 h) {
	vec2 q = abs(p) - h;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
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

	// Shear so the ends slant. Done in the SDF's input space, which keeps the
	// fill boundary, ticks and edge all following the same slant for free.
	float sk = min(skew_px, h.x);
	p.x += sk * (p.y / max(rect_size.y, 0.001));

	vec2 hb = vec2(max(h.x - sk * 0.5, 0.5), h.y);
	float d = sd_box(p, hb);

	float b   = clamp(beat, 0.0, 1.0);
	float dng = clamp(danger, 0.0, 1.0);

	// Progress axis: 0 at the left end, 1 at the right, in sheared space.
	float ax = clamp((p.x + hb.x) / (2.0 * hb.x), 0.0, 1.0);
	float aw = fwidth(ax) + 0.0004;   // one pixel, in axis units

	float inside = smoothstep(0.0, -1.2, d);

	float fill_m  = smoothstep(fill_pct + aw, fill_pct - aw, ax);
	float ghost_m = smoothstep(ghost_pct + aw, ghost_pct - aw, ax) * (1.0 - fill_m);

	// ── track ───────────────────────────────────────────────────────────────
	vec3  col = track_color.rgb;
	float a   = track_color.a;

	// Tick marks — thin verticals on the empty track, dimmer under the fill.
	float tick_u = ax * tick_count;
	float tick = 1.0 - min(abs(fract(tick_u) - 0.5) / (fwidth(tick_u) + 0.0001) * 0.9, 1.0);
	// Suppress the tick sitting exactly on either end cap.
	tick *= step(0.012, ax) * step(ax, 0.988);
	col += edge_color.rgb * tick * 0.35;

	// ── ghost trail ─────────────────────────────────────────────────────────
	// Slow pulse so a lingering trail reads as "recently lost", not as fill.
	float ghost_pulse = 0.65 + 0.35 * sin(TIME * 7.0);
	col = mix(col, ghost_color.rgb * ghost_pulse, ghost_m * ghost_color.a);
	a   = max(a, ghost_m * ghost_color.a);

	// ── fill ────────────────────────────────────────────────────────────────
	vec3 grad = mix(fill_color.rgb, fill_color2.rgb, ax);

	// Diagonal stripes scrolling along the bar.
	float stripe_u = (p.x + p.y * 1.6 - TIME * stripe_speed) / stripe_px;
	float stripe = smoothstep(0.45, 0.5, abs(fract(stripe_u) - 0.5));

	// Vertical shading: bright core line, darker toward the rails.
	float vshade = 1.0 - pow(abs(p.y) / hb.y, 2.2) * 0.55;

	vec3 fill_rgb = grad * vshade * (1.0 + b * 0.30);
	fill_rgb += grad * stripe * 0.22;
	// Leading-edge hot cap.
	fill_rgb += grad * smoothstep(fill_pct - 0.045, fill_pct, ax) * fill_m * 1.4;

	col = mix(col, fill_rgb, fill_m);
	a   = max(a, fill_m * fill_color.a);

	// ── lightning bolt (ported from the original HP bar) ─────────────────────
	// A single bolt across the bar's mid-height, striking in short random
	// bursts. Activity scales with how full the bar is: a rare, dim, nearly
	// straight ember when low; fast, bright and jagged when full.
	if (bolt_amount > 0.001 && fill_m > 0.5) {
		float hp    = clamp(fill_pct, 0.0, 1.0);
		float speed = mix(1.5, 9.0, hp);
		float t     = TIME * speed;

		float flick_thresh = mix(0.93, 0.55, hp);
		float flick = step(flick_thresh, fract(sin(floor(t) * 12.9898 + bolt_seed) * 43758.5453));

		if (flick > 0.5) {
			// Three overlapping sines at rising frequency and falling weight —
			// a hand-drawn zigzag rather than one smooth curve.
			float wob_amp = mix(0.05, 0.20, hp);
			float wob = sin(UV.x * 14.0 + t * 3.0 + bolt_seed)            * wob_amp
					  + sin(UV.x * 33.0 - t * 5.0 + bolt_seed * 2.0)      * wob_amp * 0.55
					  + sin(UV.x * 71.0 + t * 8.0 + bolt_seed * 3.0)      * wob_amp * 0.25;
			float ly   = clamp(0.5 + wob, 0.0, 1.0);
			float dist = abs(UV.y - ly);

			float core = smoothstep(0.11, 0.0, dist);
			float glowb = smoothstep(0.24, 0.0, dist) * 0.5;
			float bright = mix(0.35, 1.0, hp) * bolt_amount;

			col += vec3(0.85, 0.94, 1.0) * (core + glowb) * bright;
			a    = max(a, min((core + glowb) * bright, 0.9));
		}
	}

	// ── danger strobe ───────────────────────────────────────────────────────
	vec3 edge_rgb = edge_color.rgb;
	if (dng > 0.001) {
		float strobe = 0.5 + 0.5 * sin(TIME * 9.0);
		edge_rgb = mix(edge_rgb, vec3(1.0, 0.16, 0.22), dng * (0.45 + 0.55 * strobe));
		// Push the FILL toward red too, not just the outline. The chrome drift
		// owns fill_color, so tinting only the edge left a critical bar looking
		// much the same as a healthy one.
		vec3 danger_rgb = vec3(1.0, 0.18, 0.24) * (0.85 + 0.55 * strobe);
		col = mix(col, danger_rgb, dng * fill_m * 0.80);
		col = mix(col, col * vec3(1.25, 0.55, 0.62), dng * 0.35 * strobe);
	}

	col *= inside;
	a   *= inside;

	// ── edge + bloom ────────────────────────────────────────────────────────
	float ew = edge_px * (1.0 + b * 0.30);
	float edge = smoothstep(-ew, -ew * 0.35, d) * smoothstep(0.6, -0.2, d);
	col = mix(col, edge_rgb * (1.45 + b * 0.9 + dng * 0.8), edge);
	a   = max(a, edge * edge_color.a);

	float gw = glow_px * (1.0 + b * 0.5 + dng * 0.6);
	float glow = smoothstep(gw, 0.0, d) * (1.0 - inside) * (0.28 + b * 0.22 + dng * 0.30);
	col += edge_rgb * glow;
	a    = max(a, glow * 0.8);

	if (a <= 0.002) {
		discard;
	}
	COLOR = vec4(col, a) * src;
}
