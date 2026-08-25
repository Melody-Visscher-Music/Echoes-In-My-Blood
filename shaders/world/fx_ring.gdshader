shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

// ─────────────────────────────────────────────────────────────────────────────
// FX RING — halo rings, gate echoes, hold tunnels.
//
// Additive and unshaded: these are light, not surfaces, so they should never
// take a shadow or write depth (two of them overlapping used to punch a hole in
// each other). cull_disabled keeps a torus readable when the camera passes
// through it.
//
// `wipe` sweeps the ring's brightness around its circumference — the pooled FX
// already tween a value from 0 to 1 for their fade, so they can drive this at
// no extra cost and get motion instead of a flat fade.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec4  tint : source_color = vec4(0.36, 0.86, 1.0, 1.0);
uniform float energy = 5.0;
uniform float detail : hint_range(0.0, 2.0) = 2.0;
uniform float beat   : hint_range(0.0, 1.0) = 0.0;

uniform float wipe      : hint_range(0.0, 1.0) = 1.0;
uniform float wipe_soft : hint_range(0.01, 1.0) = 0.35;
uniform float alpha     : hint_range(0.0, 1.0) = 1.0;
uniform float band_amount : hint_range(0.0, 1.0) = 0.45;
uniform float band_scale  = 8.0;
uniform float band_speed  = 1.4;

// Dual-colour halos bake both colours into a 256x1 stripe rather than
// spawning a second ring. When set, it replaces the flat tint.
uniform sampler2D stripe_tex : source_color, filter_linear, repeat_enable;
uniform bool use_tex = false;


void fragment() {
	// UV.x runs around the ring on a TorusMesh.
	float sweep = 1.0;
	if (wipe < 0.999) {
		sweep = smoothstep(wipe + wipe_soft, wipe - wipe_soft, UV.x);
	}

	float glow = 1.0;

	if (detail > 0.5) {
		float band = 0.5 + 0.5 * sin((UV.x * band_scale + TIME * band_speed) * TAU);
		glow *= 1.0 - band_amount + band_amount * pow(band, 2.0);
	}

	// Fade the tube's own edges so the ring has soft shoulders rather than a
	// hard silhouette against the bloom.
	float tube = 1.0 - pow(abs(UV.y - 0.5) * 2.0, 2.0);

	glow *= sweep * max(tube, 0.0) * (1.0 + beat * 0.4);

	vec3 base = use_tex ? texture(stripe_tex, vec2(UV.x, 0.5)).rgb : tint.rgb;
	vec3 lit  = base * energy * glow;

	// Both, deliberately. Under `unshaded` Godot takes ALBEDO as the final
	// colour, so writing EMISSION alone would have rendered these rings black —
	// and black in an additive pass is invisible, which is a failure that looks
	// exactly like "no ring happened to be on screen".
	ALBEDO   = lit;
	EMISSION = lit;
	ALPHA    = clamp(glow * alpha, 0.0, 1.0);
}
