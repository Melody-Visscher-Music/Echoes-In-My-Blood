shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Light running along a fracture in the pavement.
//
// A travelling pulse cannot be done by driving material brightness from script:
// the whole crack shares one material, so every point of it would brighten at
// once. Splitting each crack into lit segments would mean a material per
// segment and hundreds of per-frame writes. Here the position of the surge is a
// single uniform and the shader decides, per pixel, how near it is — one float
// written per rift per frame, however long the crack is.
//
// UV.x runs 0 at the rift to 1 at the tip, which _crack_mesh() writes when it
// builds the fissure.

uniform vec4 tint : source_color = vec4(1.0);
uniform float energy = 3.0;
// Where the surge has reached, 0..1. Anything outside that means none running.
uniform float surge = -1.0;
uniform float surge_width = 0.24;
uniform float surge_gain = 2.5;
// How far the seam dims toward the far end. Cracks fade out along their length
// because they carry less light the further they get from the rift; the tear's
// own core does not, so it passes 1.0 and stays even.
uniform float falloff_to = 0.22;

void fragment() {
	// A crack carries less light the further it gets from the rift that made
	// it, so the seam fades out toward the tip even at rest.
	float falloff = mix(1.0, falloff_to, UV.x);

	float band = 0.0;
	if (surge >= 0.0) {
		band = smoothstep(surge_width, 0.0, abs(UV.x - surge));
		// The pulse dies as it runs out of crack rather than blinking off the
		// end of it.
		band *= 1.0 - smoothstep(0.7, 1.0, surge);
	}

	ALBEDO   = tint.rgb * 0.10;
	EMISSION = tint.rgb * energy * (falloff + band * surge_gain);
}
