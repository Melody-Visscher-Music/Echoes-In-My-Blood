shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
	shadows_disabled, fog_disabled;

// ─────────────────────────────────────────────────────────────────────────────
// LASER BEAM — a stage-rig shaft of light.
//
// Drawn on a narrow cone (CylinderMesh with a small bottom radius at the
// emitter and a wider top at the far end), so the geometry alone already has
// the right silhouette. What this shader adds is the reason it reads as LIGHT
// rather than as a glowing cone:
//
//   • Fake volumetrics. Looking down the axis of a tube you see through more of
//     it than you do at its silhouette, so brightness tracks how squarely the
//     surface faces the camera. That one term is what makes a beam look like it
//     has air inside it.
//   • Distance falloff, so the shaft dissipates instead of ending in a hard cap
//     — with the emitter head kept hot regardless.
//   • Haze scrolling along the beam, which is what sells "light in a smoky
//     room" rather than "coloured plastic rod".
//
// Additive with no depth write: beams cross each other and stack brightness the
// way real ones do, and need no back-to-front sort to look right.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec4  tint : source_color = vec4(1.0, 0.22, 0.62, 1.0);
uniform float energy      = 3.2;
uniform float beat        : hint_range(0.0, 1.0) = 0.0;
uniform float alpha       : hint_range(0.0, 1.0) = 1.0;
uniform float beam_len    = 46.0;
uniform float core_pow    = 2.3;   // volumetric falloff sharpness
uniform float fade_pow    = 1.5;   // how fast the shaft dies with distance
uniform float dust_amount : hint_range(0.0, 1.0) = 0.38;
uniform float dust_speed  = 2.4;
uniform int   detail      : hint_range(0, 2) = 2;

varying float along;

void vertex() {
	// Along-length from model-space Y rather than UV: CylinderMesh's V winding
	// is an implementation detail, the vertex position is not.
	along = clamp(VERTEX.y / max(beam_len, 0.001) + 0.5, 0.0, 1.0);
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float shaft  = pow(facing, core_pow);

	float fall = pow(1.0 - along, fade_pow);
	// Keep the emitter head hot even though `along` is 0 there.
	fall = max(fall, smoothstep(0.12, 0.0, along));

	float amp = shaft * fall;

	if (detail > 0 && dust_amount > 0.0) {
		float d = sin(along * 26.0 - TIME * dust_speed) * 0.5 + 0.5;
		amp *= mix(1.0, 0.70 + 0.48 * d, dust_amount);
	}

	float e = energy * (1.0 + clamp(beat, 0.0, 1.0) * 1.35);
	vec3 lit = tint.rgb * e * amp;

	// Both, and ALBEDO is the one that matters: `unshaded` outputs ALBEDO and
	// discards EMISSION entirely, so a beam written only into EMISSION renders
	// pure black — and black added to the scene is nothing at all. EMISSION is
	// set alongside it so this still reads correctly if the mode ever changes.
	ALBEDO   = lit;
	EMISSION = lit;
	ALPHA    = clamp(amp * alpha, 0.0, 1.0);
}
