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
//   • lightning across the fill, gated by `bolt_amount`. Several short bolts
//     striking independently rather than one long one down the middle, and it
//     dies out completely as the bar empties.
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

float hash11(float x) {
	return fract(sin(x * 12.9898) * 43758.5453);
}

// One lightning channel, sampled at x (0-1 along the bolt). Random heights at
// random nodes, joined by STRAIGHT lines — a bolt is a run of straight segments
// meeting at sharp irregular angles, and that irregularity is the whole tell.
// A triangle or sine wave gives evenly spaced kinks of equal size, which the eye
// reads as a waveform on an oscilloscope no matter how sharp the corners are.
float bolt_path(float x, float nodes, float seed) {
	float u = x * nodes;
	float i = floor(u);
	float f = fract(u);
	float y0 = hash11(i * 1.7 + seed) * 2.0 - 1.0;
	float y1 = hash11((i + 1.0) * 1.7 + seed) * 2.0 - 1.0;
	return mix(y0, y1, f);   // linear on purpose: smoothing would round the kinks
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

	// ── lightning ───────────────────────────────────────────────────────────
	// Three independent bolts on their own clocks, each running the WHOLE length
	// of the fill — from the left end cap to wherever the health currently stops
	// — so a strike measures the bar rather than decorating part of it. Several
	// are usually lit at once, crossing at different heights.
	//
	// Each is built like an actual bolt rather than a squiggle: straight segments
	// at irregular angles (see bolt_path), a fork peeling off partway and dying
	// out, a hot near-white core inside a softer halo, and a sharp attack that
	// decays instead of a square on/off.
	//
	// Everything rides how full the bar is — how many bolts strike, how often,
	// how jagged, how thick, how bright — and it is cut off entirely near empty.
	// A dying bar showing a slow tame ember read as "still fine"; showing nothing
	// is the honest signal, and it hands the low-HP read over to the red strobe.
	if (bolt_amount > 0.001 && fill_m > 0.5) {
		float hp  = clamp(fill_pct, 0.0, 1.0);
		// Reaches zero just above empty and is back to full by a third of a bar:
		// "none left at 1 HP", not "none left at 30".
		float act = smoothstep(0.05, 0.34, hp);
		if (act > 0.001) {
			float rate = mix(3.5, 12.0, hp);   // strikes per second, per bolt
			float lit  = 0.0;

			// Position along the fill: 0 at the left end cap, 1 at the fill head,
			// taken from the sheared axis so the bolt follows the same slant the
			// fill boundary does.
			float lx = clamp(ax / max(fill_pct, 0.001), 0.0, 1.0);

			for (int k = 0; k < 3; k++) {
				float ks   = float(k) * 37.31 + bolt_seed;
				float t    = TIME * rate + float(k) * 0.29;
				float tick = floor(t);
				float ph   = fract(t);

				// Not every bolt strikes on every tick.
				float r1 = hash11(tick * 3.77 + ks);
				if (r1 < mix(0.68, 0.20, hp)) { continue; }

				float r2 = hash11(tick * 9.11 + ks * 1.7);
				float r3 = hash11(tick * 1.93 + ks * 2.3);
				float r4 = hash11(tick * 6.41 + ks * 3.9);

				// Sharp attack, a moment at full, then a quick decay: a strike
				// rather than a square wave. The plateau matters — a pure
				// exponential from the instant of the tick decayed so fast that
				// most frames caught nothing at all and the bar looked dead
				// between flashes.
				float flash = exp(-max(ph - 0.18, 0.0) * mix(12.0, 7.0, hp));

				// Two octaves, not three: at 26 px tall the third only ever
				// showed up as fuzz along the channel, and fuzz is the opposite
				// of the clean angular kink that sells this.
				//
				// Node count tracks the fill so the kinks stay roughly the same
				// distance apart in PIXELS whether the bar is full or a stub —
				// a fixed count would cram the same number of turns into a
				// quarter-length bolt and turn it back into a squiggle.
				float sd   = tick * 1.3 + ks;
				float amp  = mix(0.09, 0.30, hp);
				float n1   = 4.0 + 9.0 * hp;
				float path = bolt_path(lx, n1,       sd)       * 0.70
						   + bolt_path(lx, n1 * 2.6, sd + 5.1) * 0.30;
				float ly   = 0.5 + (r4 - 0.5) * 0.16 + path * amp;

				float dist = abs(UV.y - ly);
				float core = smoothstep(mix(0.026, 0.048, hp), 0.0, dist) * 1.45;
				float halo = smoothstep(mix(0.095, 0.190, hp), 0.0, dist) * 0.40;

				// A fork peeling away from the channel partway along and petering
				// out — thinner and dimmer than the trunk it left.
				float fx  = 0.28 + r3 * 0.34;
				float fk  = smoothstep(fx, fx + 0.05, lx) * smoothstep(fx + 0.38, fx + 0.14, lx);
				float fy  = ly + (bolt_path(lx, 11.0, sd + 21.3) * 0.55
						  + (r2 - 0.5) * 1.6) * amp * 1.4 * fk;
				float fcore = smoothstep(0.016, 0.0, abs(UV.y - fy)) * fk * 0.80;

				lit = max(lit, (core + halo + fcore) * flash);
			}

			float bright = lit * mix(0.70, 1.50, hp) * bolt_amount * act;
			col += vec3(0.86, 0.93, 1.0) * bright;
			a    = max(a, min(bright, 0.95));
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
