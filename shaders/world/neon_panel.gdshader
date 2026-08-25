shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// ─────────────────────────────────────────────────────────────────────────────
// NEON PANEL — lane blockers, jump hurdles, slide bars, wall-jump plates, and
// the flat floor pieces (approach marks, safe-lane strip).
//
// These are the surfaces the player reads to decide what to do, so the job is
// legibility first: a bright border that states the panel's extent, scanlines
// so the face is not dead flat, and diagonal hazard stripes on anything that
// must not be touched.
//
// `danger` drives the electric-zone treatment — the same panels, but strobing
// red-hot, so an electric gate is unmistakable without new geometry.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec4  tint : source_color = vec4(1.0, 0.35, 0.68, 1.0);
uniform float energy = 2.2;
uniform float detail : hint_range(0.0, 2.0) = 2.0;
uniform float beat   : hint_range(0.0, 1.0) = 0.0;
uniform float danger : hint_range(0.0, 1.0) = 0.0;

uniform float border_px   : hint_range(0.0, 0.5)  = 0.055;
uniform float scan_amount : hint_range(0.0, 1.0)  = 0.30;
uniform float scan_scale  = 42.0;
uniform float scan_speed  = 0.55;
uniform float stripe_amount : hint_range(0.0, 1.0) = 0.0;   // >0 = hazard stripes
uniform float stripe_scale  = 13.0;
uniform float stripe_speed  = 0.35;
uniform float fill_amount : hint_range(0.0, 1.0) = 0.30;


void fragment() {
	// Distance to the nearest edge of the face, in UV.
	vec2 e2 = min(UV, vec2(1.0) - UV);
	float edge_d = min(e2.x, e2.y);
	float border = 1.0 - smoothstep(border_px, border_px * 2.2, edge_d);

	float face = fill_amount;

	if (detail > 0.5) {
		float scan = 0.5 + 0.5 * sin((UV.y * scan_scale - TIME * scan_speed) * TAU);
		face += pow(scan, 2.5) * scan_amount;
	}

	if (detail > 1.5 && stripe_amount > 0.001) {
		float s = fract((UV.x + UV.y) * stripe_scale - TIME * stripe_speed);
		face += step(0.5, s) * stripe_amount;
	}

	// Grazing-angle flare, so a panel edge-on still announces itself.
	float fres = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	fres = pow(fres, 3.0) * 0.6;

	vec3 col = tint.rgb;
	float glow = face + border * 1.5 + fres;

	if (danger > 0.001) {
		float strobe = 0.5 + 0.5 * sin(TIME * 9.0);
		col = mix(col, vec3(1.0, 0.16, 0.20), danger * (0.45 + 0.55 * strobe));
		glow *= 1.0 + danger * strobe * 0.8;
	}

	glow *= 1.0 + beat * 0.35;

	ALBEDO    = col * 0.10;
	METALLIC  = 0.0;
	ROUGHNESS = 0.55;
	EMISSION  = col * energy * glow;
}
