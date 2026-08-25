shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// ─────────────────────────────────────────────────────────────────────────────
// NEON TUBE — rails, gate posts, top beams, arcs, fence posts.
//
// The problem this solves: every bar in the game was a BoxMesh with a flat
// emission colour, so it read as a glowing brick. Real neon has a hot core
// running down its length that falls off across its cross-section, and flares
// at grazing angles. Two cheap terms give a box that read without adding a
// single vertex.
//
// The core runs along the bar's LONG axis, worked out from `box_size` in object
// space. It cannot come from UV: a BoxMesh gives every face its own 0..1 UV
// with no consistent orientation, so a UV band lights a vertical post across
// its middle height instead of down its length — which is exactly the wrong
// axis, and looked it.
//
// Set `use_uv` for the swept rail mesh, whose UVs are authored deliberately:
// UV.x along the rail, UV.y around the ring.
// ─────────────────────────────────────────────────────────────────────────────

uniform vec4  tint : source_color = vec4(1.0, 0.35, 0.68, 1.0);
uniform float energy = 4.0;
uniform float detail : hint_range(0.0, 2.0) = 2.0;
uniform float beat   : hint_range(0.0, 1.0) = 0.0;

uniform vec3  box_size = vec3(1.0, 1.0, 1.0);
uniform bool  use_uv   = false;

uniform float core_width  : hint_range(0.05, 2.0) = 0.85;
uniform float rim_amount  : hint_range(0.0, 2.0)  = 0.85;
uniform float flow_speed  = 1.1;
uniform float flow_amount : hint_range(0.0, 1.0)  = 0.35;
uniform float flow_scale  = 4.0;

varying vec3 v_obj;

void vertex() {
	v_obj = VERTEX;
}

void fragment() {
	float section;   // 0 on the centre line, 1 at the bar's surface
	float along;     // 0..1 down the bar's length

	if (use_uv) {
		section = abs(UV.y - 0.5) * 2.0;
		along   = UV.x;
	} else {
		vec3 h = max(box_size * 0.5, vec3(0.0001));
		vec3 n = clamp(abs(v_obj) / h, 0.0, 1.0);
		// Long axis = the largest half-extent; the other two are the section.
		if (h.x >= h.y && h.x >= h.z) {
			section = max(n.y, n.z);
			along   = v_obj.x / h.x * 0.5 + 0.5;
		} else if (h.y >= h.z) {
			section = max(n.x, n.z);
			along   = v_obj.y / h.y * 0.5 + 0.5;
		} else {
			section = max(n.x, n.y);
			along   = v_obj.z / h.z * 0.5 + 0.5;
		}
	}

	float band = 1.0 - clamp(section / core_width, 0.0, 1.0);
	band = pow(band, 1.7);

	// Silhouette flare. NORMAL and VIEW are already view-space here.
	float fres = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	fres = pow(fres, 2.6) * rim_amount;

	float glow = band * 0.85 + fres;

	// Energy travelling down the bar. Only worth its cost above the low tier.
	if (detail > 0.5) {
		float flow = 0.5 + 0.5 * sin((along * flow_scale - TIME * flow_speed) * TAU);
		glow += pow(flow, 3.0) * flow_amount;
	}

	glow *= 1.0 + beat * 0.45;

	// Dark body so unlit parts still read as solid geometry against the bloom.
	ALBEDO    = tint.rgb * 0.12;
	METALLIC  = 0.0;
	ROUGHNESS = 0.42;
	EMISSION  = tint.rgb * energy * glow;
}
