shader_type sky;

// ─────────────────────────────────────────────────────────────────────────────
// NIGHT SKY — replaces the flat BG_COLOR the level used to render behind
// everything. That single colour was most of why the background read as empty:
// above the skyline there was literally nothing to look at.
//
// Four cheap layers, no textures:
//   • a vertical gradient from a warm horizon to a near-black zenith
//   • a horizon glow band, so the city sits in light-pollution rather than on a
//     hard edge
//   • hash-cell stars with a slow twinkle, faded out near the horizon where the
//     haze would swallow them
//   • two slow nebula bands, which stop the upper sky being a flat wash
//
// A sky shader runs once per sky pixel with no geometry behind it, so all of
// this is close to free next to the track itself.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec3  horizon_col : source_color = vec3(0.105, 0.035, 0.215);
uniform vec3  zenith_col  : source_color = vec3(0.012, 0.006, 0.038);
uniform vec3  glow_col    : source_color = vec3(0.62, 0.14, 0.85);
uniform vec3  nebula_col  : source_color = vec3(0.30, 0.10, 0.55);
uniform vec3  star_col    : source_color = vec3(0.78, 0.85, 1.00);

uniform float glow_amount   : hint_range(0.0, 2.0) = 0.42;
uniform float star_amount   : hint_range(0.0, 2.0) = 1.0;
uniform float nebula_amount : hint_range(0.0, 1.0) = 0.35;
uniform float star_scale    = 92.0;
uniform float star_cut      : hint_range(0.90, 0.999) = 0.978;
uniform float beat          : hint_range(0.0, 1.0) = 0.0;
uniform int   detail        : hint_range(0, 2) = 2;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h  = dir.y;
	float b  = clamp(beat, 0.0, 1.0);

	// ── gradient ────────────────────────────────────────────────────────────
	vec3 col = mix(horizon_col, zenith_col, smoothstep(-0.06, 0.72, h));

	// ── horizon glow ────────────────────────────────────────────────────────
	// Tightest right at the skyline and pulsing gently with the track.
	float band = exp(-abs(h) * 8.5);
	col += glow_col * band * glow_amount * (0.85 + b * 0.45);

	if (detail > 0) {
		// ── nebula bands ────────────────────────────────────────────────────
		// Two overlapping low-frequency sine sheets. Cheaper than noise and,
		// smeared across a whole sky, indistinguishable from it.
		float n = sin(dir.x * 2.1 + dir.z * 1.4) * 0.5 + 0.5;
		n *= sin(dir.z * 1.7 - dir.x * 2.6 + 1.3) * 0.5 + 0.5;
		n *= smoothstep(0.0, 0.55, h);
		col += nebula_col * n * nebula_amount;
	}

	// ── stars ───────────────────────────────────────────────────────────────
	// One candidate per hash cell; most cells fail the cut, which is what makes
	// the field look scattered rather than gridded.
	if (detail > 0 && h > 0.0) {
		vec3 sp   = dir * star_scale;
		vec3 cell = floor(sp);
		vec3 f    = fract(sp) - 0.5;
		float r   = hash13(cell);
		if (r > star_cut) {
			float mag  = hash13(cell + 7.13);
			float star = smoothstep(0.32, 0.0, length(f));
			float tw   = 0.62 + 0.38 * sin(TIME * 1.5 + mag * 42.0);
			// Fade in above the haze layer.
			col += star_col * star * pow(mag, 2.0) * 1.7 * tw
				 * smoothstep(0.0, 0.26, h) * star_amount;
		}
	}

	COLOR = col;
}
