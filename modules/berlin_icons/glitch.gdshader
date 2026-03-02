shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float time_seed = 0.0;

// Hash function for pseudo-random noise
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	float t = time_seed;

	// Static snow noise
	float noise = hash(UV * vec2(1024.0, 3072.0) + vec2(t * 1347.3, t * 2591.7));
	float snow = step(0.92, noise) * 0.4 * intensity;

	// Horizontal scanline bands that shift
	float scanline_pos = fract(t * 3.7);
	float band = smoothstep(0.0, 0.02, abs(UV.y - scanline_pos));
	float scanline_noise = (1.0 - band) * 0.15 * intensity;

	// Thin horizontal lines (CRT feel)
	float thin_line = step(0.98, fract(UV.y * 1536.0 + t * 100.0)) * 0.08 * intensity;

	// Combine: white noise blips on black
	float alpha = snow + scanline_noise + thin_line;
	COLOR = vec4(vec3(1.0), alpha);
}
