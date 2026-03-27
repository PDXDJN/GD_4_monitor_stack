## GalaxySystem — Rotating spiral galaxy spanning all 4 monitors.
## GPU particles with differential rotation create stable spiral arms.
## Process + draw shaders are inlined; no external .gdshader files required.
extends Node2D

var module_id         := "galaxy_system"
var module_rng:         RandomNumberGenerator
var module_started_at := 0.0

var _manifest:      Dictionary
var _panel_layout:  PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested  := false
var _finished        := false
var _winding_down    := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 3.0

var _particles: GPUParticles2D
var _tween: Tween

# Full 4-panel framebuffer dimensions
const TOTAL_W := 1024
const TOTAL_H := 3072   # 4 × 768

# ── Particle process shader: differential-rotation spiral galaxy ───────────────
const _PROCESS_SHADER := """
shader_type particles;

uniform float rotation_speed = 0.05;
uniform float radial_spread  = 1400.0;
uniform float arm_count      = 4.0;
uniform float spiral_tight   = 0.001;
uniform float arm_width      = 1.0;

float hf(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint s      = NUMBER;
	float arm   = floor(hf(s * 3u) * arm_count);
	float arm_b = arm / arm_count * TAU;

	// Radial distance with scatter — breaks up the clean spiral edge
	float r_base    = pow(hf(s * 7u + 1u), 0.55) * radial_spread;
	float r_scatter = (hf(s * 19u + 8u) - 0.5) * radial_spread * 0.20;
	float r = clamp(r_base + r_scatter, 8.0, radial_spread * 1.05);

	// Angular spread: sum three uniform samples → bell-curve distribution
	// gives dense arm centre with diffuse, ragged edges
	float w1 = hf(s * 11u + 2u) - 0.5;
	float w2 = hf(s * 23u + 5u) - 0.5;
	float w3 = hf(s * 37u + 6u) - 0.5;
	float spread = (w1 + w2 + w3) / 1.5 * arm_width;

	float angle = arm_b + r * spiral_tight + spread;
	CUSTOM.x = r;
	CUSTOM.y = angle;
	CUSTOM.z = hf(s * 13u + 3u);                  // twinkle phase
	CUSTOM.w = 0.35 + hf(s * 17u + 4u) * 0.65;   // base brightness
	TRANSFORM[3].x = cos(angle) * r;
	TRANSFORM[3].y = sin(angle) * r;
	TRANSFORM[3].z = 0.0;
}

void process() {
	float r   = CUSTOM.x;
	float a0  = CUSTOM.y;
	float bri = CUSTOM.w;
	float rn  = clamp(r / radial_spread, 0.0, 1.0);

	// Differential rotation: inner orbits faster
	float av  = rotation_speed / (0.2 + rn * 0.8);
	float ang = a0 + av * TIME;

	// Subtle vertical oscillation for depth illusion
	float drift = sin(TIME * 0.18 + r * 0.003) * r * 0.03;

	TRANSFORM[3].x = cos(ang) * r;
	TRANSFORM[3].y = sin(ang) * r + drift;
	TRANSFORM[3].z = 0.0;

	// Scale: larger/brighter near the core
	float sz = mix(1.0, 3.5, max(0.0, 1.0 - rn * 1.5));
	TRANSFORM[0][0] = sz;
	TRANSFORM[1][1] = sz;

	// Twinkling
	float tw = 1.0 + sin(TIME * 7.0 + CUSTOM.z * TAU) * 0.22;

	// Colour: white core -> pale blue outer arms
	float cb  = max(0.0, 1.0 - rn * 2.5);
	vec3  col = mix(vec3(0.45, 0.65, 1.0), vec3(1.0, 1.0, 1.0), cb);
	float alpha = bri * tw;
	COLOR = vec4(col * alpha, alpha);
}
"""


# ══════════════════════════════════════════════════════════════════════════════
# Module contract
# ══════════════════════════════════════════════════════════════════════════════

func module_configure(ctx: Dictionary) -> void:
	_manifest      = ctx["manifest"]
	module_rng     = RNG.make_rng(ctx["seed"])
	_panel_layout  = ctx["panel_layout"]
	_virtual_space = ctx["virtual_space"]

func module_start() -> void:
	module_started_at = App.station_time
	_stop_requested   = false
	_finished         = false
	_winding_down     = false
	_wind_down_timer  = 0.0
	modulate.a        = 0.0
	_setup_particles()
	_fade_in()

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return
	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true

func _draw() -> void:
	pass

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "particles:%d" % (_particles.amount if _particles else 0),
		"intensity": 0.6,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("GalaxySystem: stop requested", {"reason": reason})
	_fade_out()

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	if _tween:
		_tween.kill()
	if _particles:
		_particles.queue_free()
		_particles = null

# ══════════════════════════════════════════════════════════════════════════════
# Setup
# ══════════════════════════════════════════════════════════════════════════════

func _setup_particles() -> void:
	_particles = GPUParticles2D.new()
	add_child(_particles)

	# Centred on the full 4-panel framebuffer
	_particles.position      = Vector2(TOTAL_W * 0.5, TOTAL_H * 0.5)
	_particles.amount        = 8000
	_particles.lifetime      = 20.0
	_particles.preprocess    = 20.0   # pre-warm so galaxy is fully populated on first frame
	_particles.explosiveness = 0.0
	_particles.randomness    = 0.0
	_particles.fixed_fps     = 30
	_particles.emitting      = true
	_particles.one_shot      = false

	# Process material: custom spiral-orbit shader
	var proc_shader := Shader.new()
	proc_shader.code = _PROCESS_SHADER
	var proc_mat := ShaderMaterial.new()
	proc_mat.shader = proc_shader
	_particles.process_material = proc_mat

	# Soft dot texture — procedurally generated white circle with falloff
	_particles.texture = _make_dot_texture(32)

	# Additive blend so overlapping stars glow brighter (creates the bulge)
	var blend_mat := CanvasItemMaterial.new()
	blend_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_particles.material = blend_mat

# ── Texture helper ────────────────────────────────────────────────────────────

func _make_dot_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx  := size * 0.5
	var cy  := size * 0.5
	var r   := size * 0.5
	for py in size:
		for px in size:
			var d := Vector2(px - cx, py - cy).length() / r
			# smoothstep(0.2, 1.0, d) then invert
			var t     := clampf((d - 0.2) / 0.8, 0.0, 1.0)
			var alpha := 1.0 - t * t * (3.0 - 2.0 * t)
			img.set_pixel(px, py, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(img)

# ── Fade helpers ──────────────────────────────────────────────────────────────

func _fade_in() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 2.0).set_ease(Tween.EASE_IN)

func _fade_out() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, _WIND_DOWN_DUR).set_ease(Tween.EASE_OUT)
