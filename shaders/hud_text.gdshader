shader_type canvas_item;
render_mode blend_mix, unshaded;

// ─────────────────────────────────────────────────────────────────────────────
// HUD TEXT — chrome/neon shading for the big numerals (score, HP %, combo).
//
// Deliberately MULTIPLICATIVE and near-greyscale: it shades whatever colour the
// Label already has rather than replacing it. That matters because the score
// and HP readouts drive their colour through `self_modulate` (the signature
// hue drift) and their flash pulse through `modulate` — this shader has to
// compose with both instead of fighting them.
//
// For the same reason it never references MODULATE: leaving the built-in
// modulate pass enabled is what keeps self_modulate/modulate working on text.
//
// UV on a Label is font-atlas space, not label space, so the vertical ramp is
// driven from VERTEX (label-local) passed through a varying.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec2  rect_size   = vec2(200.0, 48.0);
uniform vec3  top_tint    : source_color = vec3(1.00, 1.00, 1.00);
uniform vec3  bottom_tint : source_color = vec3(0.72, 0.60, 0.92);
uniform float top_gain    = 1.42;
uniform float bottom_gain = 0.74;
uniform float sheen_amount : hint_range(0.0, 1.0) = 0.45;
uniform float sheen_speed  = 0.35;
uniform float beat         : hint_range(0.0, 1.0) = 0.0;

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float t = clamp(local_pos.y / max(rect_size.y, 1.0), 0.0, 1.0);

	// Vertical ramp: hot at the top, falling off toward the baseline.
	vec3 ramp = mix(top_tint * top_gain, bottom_tint * bottom_gain, smoothstep(0.0, 1.0, t));

	// A narrow highlight band sweeping down the glyphs — the "polished metal"
	// read. Travels slowly so it never becomes a distraction mid-song.
	float sweep = fract(t - TIME * sheen_speed);
	float sheen = smoothstep(0.5, 0.0, abs(sweep - 0.5) * 2.0);
	sheen = pow(sheen, 6.0) * sheen_amount;

	ramp += vec3(sheen);
	ramp *= 1.0 + clamp(beat, 0.0, 1.0) * 0.18;

	COLOR = vec4(COLOR.rgb * ramp, COLOR.a);
}
