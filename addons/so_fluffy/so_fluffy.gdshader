shader_type spatial;

// blend_mix: smooth alpha for anti-aliased strand edges
// depth_draw_always: each shell writes depth even at semi-transparent fringes,
// preventing inner shells from bleeding through the outer shell's edge pixels.
render_mode cull_disabled, blend_mix, depth_draw_always;

uniform float height = 0;
uniform float normal_strength = 1.0;
uniform vec3 static_direction_local = vec3(0.0,0.0,0.0);
uniform vec3 static_direction_world = vec3(0.0,0.0,0.0);
uniform float h = 0;
uniform float density = 1.0;
uniform bool render_skin = true;
uniform int seed = 0;
uniform float scruffiness = 0.5;
uniform sampler2D heightmap_texture : source_color, filter_linear_mipmap_anisotropic;
uniform bool use_heightmap_texture = false;
uniform sampler2D turbulence_texture : filter_linear;
uniform float turbulence_strength = 0.5;
uniform sampler2D jitter_texture : filter_linear;
uniform float jitter_strength = 0;
uniform bool curls_enabled = true;
uniform float curls_twist = 24.0;
uniform float curls_fill = 0.7853981634;



uniform vec3 color: source_color;
uniform sampler2D height_gradient: source_color, filter_linear_mipmap;
uniform bool use_height_gradient = false;
uniform bool scale_height_gradient = true;
uniform bool use_albedo_texture = false;
uniform sampler2D albedo_texture : source_color;

uniform bool use_emission = false;
uniform vec3 emission_color: source_color;
uniform float emission_energy_multiplier;
uniform bool use_emission_texture = false;
uniform sampler2D emission_texture : source_color;


uniform sampler2D thickness_curve;
uniform bool use_thickness_curve = false;
uniform float thickness_scale = 1.0;

// physics
uniform vec3 physics_pos_offset = vec3(0.0, 0.0, 0.0);
uniform mat3 physics_rot_offset;

// ── Realism ───────────────────────────────────────────────────────────────
/// Root-to-tip ambient occlusion. Higher = darker roots, brighter tips.
uniform float root_darkening : hint_range(0.5, 4.0) = 1.5;
/// SSS approximation: fur tips glow at grazing angles (backlit translucency).
/// Keep this very small (0.02–0.08) — it adds subtle life, not a glow effect.
uniform float tip_glow_strength : hint_range(0.0, 0.5) = 0.03;

// Gold Noise ©2015 dcerisano@standard3d.com
// - based on the Golden Ratio
// - uniform normalized distribution
// - fastest static noise generator function (also runs at low precision)
// - use with indicated fractional seeding method. 
// @see https://www.shadertoy.com/view/ltB3zD
float gold_noise(vec2 p) {
	p = p + vec2(float(seed), float(seed));
	vec3 p3  = fract(vec3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float atan2(in float y, in float x) {
    bool s = (abs(x) > abs(y));
    return mix(PI/2.0 - atan(x,y), atan(y,x), float(s));
}

// fast atan2 approximation, returns an angle in the range -PI..PI
// @see https://www.shadertoy.com/view/WtyyWD
float atan2_approximation2( float x, float y ) {
	if ( x == 0.0f ) {
		if ( y > 0.0f ) return PI/2.0;
		if ( y == 0.0f ) return 0.0f;
		return -PI/2.0;
	}
	float atan;
	float z = y/x;
	if ( abs( z ) < 1.0f ) {
		atan = z/(1.0f + 0.28f*z*z);
		if ( x < 0.0f ) {
			if ( y < 0.0f ) return atan - PI;
			return atan + PI;
		}
	}
	else {
		atan = PI/2.0 - z/(z*z + 0.28f);
		if ( y < 0.0f ) return atan - PI;
	}
	return atan;
}

void vertex() {	
	vec3 physics_pos_offset_world = (vec4(physics_pos_offset, 0.0) * MODEL_MATRIX).xyz * h * 0.2;
	vec3 direction = static_direction_local + (vec4(static_direction_world, 0.0) * MODEL_MATRIX).xyz;
	VERTEX += (NORMAL * normal_strength + direction * (1.0 - normal_strength)) * height * h + physics_pos_offset_world;
	VERTEX = VERTEX * physics_rot_offset;
}

void fragment() {	
	vec2 uv = UV * density; // current pixel UV, scaled by density
	
	float ts = 256.0;  // 256 = 4× larger strands → visible clumps instead of sub-pixel noise
	vec2 xy = uv;
	
	if(turbulence_strength > 0.0) {
		vec2 turbulence = texture(turbulence_texture, uv).xy - vec2(0.5, 0.5);
	
		vec2 displacement = turbulence * turbulence_strength * 0.1;
		xy = xy + displacement * pow((1.0 - h * 0.5), 1.0 * turbulence_strength) * 1.0;
	}
	
	xy = xy + (texture(jitter_texture, UV).xy - vec2(0.5, 0.5)) * jitter_strength / 200.0;
	
	// density noise
	float noise = 0.0;
	
	if (scruffiness > 0.0 || curls_enabled) {
		noise = gold_noise(floor(xy * ts));  // match noise cell size to strand cell size
	}
	float len = scruffiness <= 0.0 ? 1.0 : pow(noise, scruffiness);
	
	if(use_heightmap_texture) {
		vec3 val = texture(heightmap_texture, UV).rgb; // sample heightmap length texture at original UV - we don't care how far the strand has been displaced
		len *= val.r;
	}
	
	// calculate distance of current pixel from center of texture pixel
	vec2 center = vec2(0.5, 0.5);
	vec2 center_offset = fract(xy * ts) - center;
	float relDist = length(center_offset) / thickness_scale * 2.0;

	// Distance LOD — at far pixels (large fwidth footprint) the discard threshold
	// relaxes so strands merge into a smooth silhouette rather than graining out.
	float _fw  = max(fwidth(uv.x), fwidth(uv.y));
	float _lod = smoothstep(0.0005, 0.004, _fw);
	float eff_relDist = relDist * (1.0 - _lod * 0.5);

	float thickness;
	if(use_thickness_curve) {
		thickness = texture(thickness_curve, vec2(clamp(h / len, 0.0, 0.99), 0.0)).r * len;
	} else {
		thickness = h;
	}
	
	// calculate curls - circle segments and angle offsets
	bool curl = true;
	if (curls_enabled) {
		float a = mod(atan2_approximation2(center_offset.y, center_offset.x) + h * curls_twist + noise * 1024.0, 2.0 * PI);
		curl = a > 0.0 && a < curls_fill;
	}
	
	// ── Strand boundary — smooth anti-aliased edges ──────────────────────────
	// Hard-discard pixels that are completely outside any strand or skin area.
	bool in_strand = curl && (len - thickness >= eff_relDist) && (h < len);
	bool is_skin   = render_skin && (h == 0.0);
	if (!in_strand && !is_skin) { discard; }

	// Compute a smooth per-pixel alpha that feathers the strand edge over roughly
	// 1 screen pixel using fwidth(). This replaces the hard discard boundary with
	// a sub-pixel anti-aliased transition — no more jagged strand silhouettes.
	float edge_fw      = clamp(fwidth(eff_relDist) * 3.0, 0.01, 0.25);
	float strand_alpha = is_skin ? 1.0 : smoothstep(1.0 + edge_fw, 1.0 - edge_fw, eff_relDist);
	if (strand_alpha < 0.003) { discard; }

	if(!FRONT_FACING) NORMAL = -NORMAL;
	vec3 col = color;

	// sample height gradient
	float grad_h = h;
	if(scale_height_gradient) {
		grad_h /= len;
	}

	vec3 height_col;
	if(use_height_gradient) {
		height_col = texture(height_gradient, vec2(grad_h * 0.999, 0.0)).rgb;
	} else {
		// Root-to-tip ambient occlusion: roots are occluded by overlying fur and
		// should appear darker. mix(0.20, 1.0) keeps roots from going pitch-black.
		// grad_h = position along strand (0=root, 1=tip), normalised by strand length.
		float hg = mix(0.20, 1.0, pow(grad_h, root_darkening));
		height_col = vec3(hg, hg, hg);
	}
	col *= height_col;

	if(use_albedo_texture) {
		col *= texture(albedo_texture, UV).rgb;
	}
	ALBEDO    = col;
	// Matte at roots (high ROUGHNESS), slight specular sheen at tips
	ROUGHNESS = mix(0.85, 0.55, h);
	ALPHA     = strand_alpha;

	if(use_emission) {
		vec3 emission = emission_color;
		if(use_emission_texture) {
			emission += texture(emission_texture, UV).rgb;
		}
		EMISSION = emission * emission_energy_multiplier;
	}
	// SSS approximation: at grazing angles, light scatters through thin fur tips.
	// Produces the subtle warm halo real fur shows when backlit or rim-lit.
	float rim_sss = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	EMISSION += col * rim_sss * (h * h) * tip_glow_strength;
}

void light() {
	// HALF-LAMBERT
	float d = dot(NORMAL, LIGHT) / 2.0 + 0.5;
	DIFFUSE_LIGHT += d * d * ATTENUATION * LIGHT_COLOR;
}