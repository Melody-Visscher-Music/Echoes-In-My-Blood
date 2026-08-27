shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// ─────────────────────────────────────────────────────────────────────────────
// ENERGY ORB — grind sparks, ambient wisps, collectible gems.
//
// A SphereMesh with flat emission is a flat disc on screen; all the shape
// information is thrown away. Inverting the fresnel puts the hot spot in the
// middle and lets the silhouette fall off, which is what makes a small sphere
// read as a glowing volume rather than a sticker.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec4  tint : source_color = vec4(1.0, 0.55, 0.20, 1.0);
uniform float energy = 8.0;
uniform float detail : hint_range(0.0, 2.0) = 2.0;
uniform float beat   : hint_range(0.0, 1.0) = 0.0;

uniform float core_tight : hint_range(0.5, 6.0) = 2.2;
uniform float corona     : hint_range(0.0, 2.0) = 0.75;
uniform float swirl_speed = 0.9;
uniform float swirl_amount : hint_range(0.0, 1.0) = 0.30;
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
// Fades the silhouette out instead of ending at the mesh edge. Off by default,
// because a gem or a grind spark wants a solid body; the melody wisps turn it
// on, since they now fly right past the lens where a low-poly sphere at full
// alpha to its own rim reads as a hexagon with a glow inside it.
uniform float edge_fade : hint_range(0.0, 1.0) = 0.0;


void fragment() {
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);

	// Inverted fresnel: brightest facing the camera, falling off to the rim.
	float core = pow(ndv, core_tight);
	// A thin bright ring just inside the silhouette reads as a corona.
	float rim  = pow(1.0 - ndv, 3.0) * corona;

	float glow = core + rim;

	if (detail > 0.5) {
		// Slow internal churn so an orb sitting still is not a dead sphere.
		float sw = 0.5 + 0.5 * sin((UV.y * 5.0 + UV.x * 3.0 - TIME * swirl_speed) * TAU);
		glow *= 1.0 - swirl_amount + swirl_amount * sw;
	}

	glow *= 1.0 + beat * 0.5;

	ALBEDO    = tint.rgb * 0.15;
	METALLIC  = 0.0;
	ROUGHNESS = 0.30;
	EMISSION  = tint.rgb * energy * glow;
	ALPHA     = clamp(alpha * mix(1.0, smoothstep(0.0, 0.40, ndv), edge_fade), 0.0, 1.0);
}
