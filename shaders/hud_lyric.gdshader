shader_type canvas_item;
render_mode blend_mix, unshaded;

// ─────────────────────────────────────────────────────────────────────────────
// LYRIC WORD — karaoke wipe.
//
// A word starts "unsung" (dimmed, desaturated) and is filled left-to-right as
// `wipe` is driven 0→1 over the word's duration. Previously it only popped in,
// so a line gave no read on where in the bar the vocal actually was.
//
// Like hud_text.gdshader this shades multiplicatively and never touches
// MODULATE, so the per-word entrance tweens (modulate:a, scale) and the line's
// fade-out keep working untouched.
//
// UV on a Label is font-atlas space, so the horizontal position of a fragment
// within the word comes from VERTEX (label-local) via a varying.
// ─────────────────────────────────────────────────────────────────────────────

uniform float word_width = 100.0;
uniform float wipe       : hint_range(0.0, 1.0) = 1.0;
uniform float unsung_dim : hint_range(0.0, 1.0) = 0.55;   // brightness before the wipe
uniform float edge_glow  = 1.85;                          // hot band at the wipe front
uniform float beat       : hint_range(0.0, 1.0) = 0.0;

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float x = clamp(local_pos.x / max(word_width, 1.0), 0.0, 1.0);

	// Soft boundary so the front edge does not stair-step on large glyphs.
	float sung = smoothstep(wipe + 0.045, wipe - 0.045, x);

	// A narrow hot band riding the wipe front.
	float front = smoothstep(0.10, 0.0, abs(x - wipe)) * step(0.001, wipe) * step(wipe, 0.999);

	float gain = mix(unsung_dim, 1.0, sung);
	gain += front * (edge_glow - 1.0);
	gain *= 1.0 + clamp(beat, 0.0, 1.0) * 0.10 * sung;

	// Unsung text also loses a little saturation, so the sung part reads as the
	// one carrying the colour rather than just being slightly brighter.
	vec3 rgb = COLOR.rgb;
	float lum = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb = mix(vec3(lum), rgb, mix(0.45, 1.0, sung));

	COLOR = vec4(rgb * gain, COLOR.a);
}
