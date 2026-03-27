## WaterShimmer — Caustic light shimmer on deep water.
## Three layers: animated caustic background, GPU shimmer particles, expanding
## ripple rings drawn in GDScript. Depth gradient darkens the lower panels.
extends Node2D

var module_id         := "water_shimmer"
var module_rng:         RandomNumberGenerator
var module_started_at := 0.0

# ── Runtime tweakables ────────────────────────────────────────────────────────
@export var wave_speed:          float = 0.65   # overall motion pace
@export var caustic_intensity:   float = 0.20   # background caustic brightness
@export var current_speed:       float = 6.0    # px/s horizontal current bias
@export var ripple_interval:     float = 1.8    # seconds between new ripple events
@export var ripple_max_per_event: int  = 3      # rings spawned per event
@export var fine_particle_count: int  = 9000
@export var glow_particle_count: int  = 120

var _manifest:      Dictionary
var _panel_layout:  PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested  := false
var _finished        := false
var _winding_down    := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 3.0

var _bg:             ColorRect
var _bg_shader_mat:  ShaderMaterial
var _particles_fine: GPUParticles2D
var _particles_glow: GPUParticles2D
var _tween:          Tween

# Ripple rings — each entry: [px, py, radius, expand_speed, alpha, width]
var _ripples:       Array = []
var _ripple_timer:  float = 0.0

const TOTAL_W := 1024
const TOTAL_H := 3072

# ── Background canvas shader ───────────────────────────────────────────────────
# Four-wave caustic interference + depth gradient (top = surface, bottom = abyss)
const _BG_SHADER := """
shader_type canvas_item;

uniform float wave_speed      : hint_range(0.1, 2.0) = 0.35;
uniform float intensity       : hint_range(0.0, 1.0) = 0.20;
uniform float depth_exponent  : hint_range(0.5, 4.0) = 1.8;

void fragment() {
	vec2 p = UV * vec2(1024.0, 3072.0);
	float t = TIME * wave_speed;

	// Four wave layers — different frequencies and diagonal directions
	float w1 = sin(p.x * 0.012 + p.y * 0.004 + t        ) * 0.5 + 0.5;
	float w2 = sin(p.x * 0.007 - p.y * 0.009 + t * 1.30 ) * 0.5 + 0.5;
	float w3 = sin((p.x + p.y) * 0.008       + t * 0.80 ) * 0.5 + 0.5;
	float w4 = sin((p.x - p.y) * 0.010       + t * 1.10 ) * 0.5 + 0.5;

	// Multiplicative interference → bright caustic points
	float caustic = w1 * w2 * w3 * w4;
	caustic = pow(caustic, 1.6);

	// Slow vertical sunbeam bands sweeping across
	float beam = sin(p.x * 0.003 + t * 0.25) * 0.5 + 0.5;
	beam = pow(beam, 3.0) * 0.38;

	// Depth gradient: UV.y=0 is top (near surface), UV.y=1 is bottom (abyss)
	float depth = pow(UV.y, depth_exponent);   // 0 bright top → 1 dark bottom

	// Colour palette
	vec3 surface = vec3(0.02, 0.10, 0.22);    // near-surface blue
	vec3 deep    = vec3(0.005, 0.015, 0.045); // deep abyss almost black
	vec3 caustic_col = vec3(0.18, 0.54, 0.80);

	vec3 col = mix(surface, deep, depth);
	col = mix(col, col + caustic_col, caustic * intensity * (1.0 - depth * 0.6));
	col += vec3(0.04, 0.12, 0.22) * beam * (1.0 - depth * 0.8);

	COLOR = vec4(col, 1.0);
}
"""

# ── Fine caustic dot particles ─────────────────────────────────────────────────
const _FINE_SHADER := """
shader_type particles;

uniform float screen_w    = 1024.0;
uniform float screen_h    = 3072.0;
uniform float wave_spd    = 0.65;
uniform float wave_scl    = 0.0055;
uniform float drift_amp   = 28.0;
uniform float current_spd = 6.0;   // px/s horizontal current

float hf(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint s = NUMBER;
	CUSTOM.x = hf(s * 7u)        * screen_w;
	CUSTOM.y = hf(s * 11u)       * screen_h;
	CUSTOM.z = hf(s * 13u) * TAU;
	CUSTOM.w = 0.25 + hf(s * 17u) * 0.75;
	TRANSFORM[3].x = CUSTOM.x;
	TRANSFORM[3].y = CUSTOM.y;
	TRANSFORM[3].z = 0.0;
}

void process() {
	float bx    = CUSTOM.x;
	float by    = CUSTOM.y;
	float phase = CUSTOM.z;
	float bri   = CUSTOM.w;
	float t     = TIME * wave_spd;

	// Horizontal current — wraps around so particles stay on screen
	float cx = mod(bx + TIME * current_spd, screen_w);

	// Two-wave caustic displacement
	float dx1 = sin(by * wave_scl + t              + phase       ) * drift_amp;
	float dy1 = sin(cx * wave_scl * 1.3 + t * 0.7 + phase * 1.5 ) * drift_amp * 0.55;
	float dx2 = sin((cx + by) * wave_scl * 0.75 + t * 1.25 + phase * 2.1) * drift_amp * 0.35;
	float dy2 = sin((cx - by) * wave_scl * 0.85 + t * 0.90 + phase * 0.7) * drift_amp * 0.25;

	TRANSFORM[3].x = cx + dx1 + dx2;
	TRANSFORM[3].y = by + dy1 + dy2;
	TRANSFORM[3].z = 0.0;

	// Caustic brightness from wave interference
	float ci = (sin(by * wave_scl + t + phase) + sin(cx * wave_scl * 1.3 + t * 0.7 + phase * 1.5)) * 0.5;
	ci = max(0.0, ci);

	// Depth fade: particles near bottom are dimmer
	float depth_fade = 1.0 - pow(by / screen_h, 1.4) * 0.65;

	float flicker = 1.0 + sin(TIME * 4.5 + phase) * 0.28;
	float alpha   = clamp(bri * depth_fade * (0.25 + ci * 0.75) * flicker, 0.0, 1.0);

	float sz = 1.2 + ci * 2.8;
	TRANSFORM[0][0] = sz;
	TRANSFORM[1][1] = sz;

	// Aqua → icy white at caustic peaks; slightly warmer (greener) near surface
	float surf = 1.0 - by / screen_h;
	vec3 aqua  = mix(vec3(0.05, 0.45, 0.80), vec3(0.05, 0.55, 0.72), surf * 0.4);
	vec3 white = vec3(0.72, 0.91, 1.00);
	vec3 col   = mix(aqua, white, ci);
	COLOR = vec4(col * alpha, alpha);
}
"""

# ── Large diffuse glow blobs ───────────────────────────────────────────────────
const _GLOW_SHADER := """
shader_type particles;

uniform float screen_w    = 1024.0;
uniform float screen_h    = 3072.0;
uniform float drift_spd   = 0.18;
uniform float drift_amp   = 80.0;
uniform float current_spd = 6.0;

float hf(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint s = NUMBER;
	CUSTOM.x = hf(s * 5u)        * screen_w;
	CUSTOM.y = hf(s * 9u)        * screen_h;
	CUSTOM.z = hf(s * 13u) * TAU;
	CUSTOM.w = 0.08 + hf(s * 23u) * 0.14;
	TRANSFORM[3].x = CUSTOM.x;
	TRANSFORM[3].y = CUSTOM.y;
	TRANSFORM[3].z = 0.0;
}

void process() {
	float bx    = CUSTOM.x;
	float by    = CUSTOM.y;
	float phase = CUSTOM.z;
	float bri   = CUSTOM.w;
	float t     = TIME * drift_spd;

	// Current + slow undulation
	float cx = mod(bx + TIME * current_spd * 0.4, screen_w);
	float dx = sin(by * 0.0012 + t + phase             ) * drift_amp;
	float dy = sin(cx * 0.0009 + t * 0.65 + phase + 1.0) * drift_amp * 0.6;
	dx      += sin(t * 0.8 + phase * 2.0) * drift_amp * 0.3;

	TRANSFORM[3].x = cx + dx;
	TRANSFORM[3].y = by + dy;
	TRANSFORM[3].z = 0.0;

	float pulse = 0.5 + sin(TIME * 0.9 + phase) * 0.5;

	// Depth fade: blobs near bottom are much dimmer
	float depth_fade = 1.0 - pow(by / screen_h, 1.2) * 0.75;
	float alpha = bri * pulse * depth_fade;

	float sz = 180.0 + pulse * 60.0;
	TRANSFORM[0][0] = sz;
	TRANSFORM[1][1] = sz;

	vec3 col = vec3(0.10, 0.38, 0.68);
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
	_ripples.clear()
	_ripple_timer     = 0.0
	modulate.a        = 0.0
	_setup_scene()
	_fade_in()

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return
	_update_ripples(delta)
	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true

func _draw() -> void:
	for rip in _ripples:
		var pos    := Vector2(rip[0], rip[1])
		var radius := rip[2] as float
		var alpha  := rip[4] as float
		var width  := rip[5] as float
		if radius < 1.0 or alpha <= 0.0:
			continue
		var c1 := Color(0.45, 0.78, 1.00, alpha * 0.70)
		var c2 := Color(0.20, 0.55, 0.85, alpha * 0.30)
		draw_arc(pos, radius,          0.0, TAU, 56, c1, width)
		draw_arc(pos, radius * 0.80,   0.0, TAU, 48, c2, width * 0.5)

func module_status() -> Dictionary:
	var cnt := 0
	if _particles_fine: cnt += _particles_fine.amount
	if _particles_glow: cnt += _particles_glow.amount
	return {
		"ok":        true,
		"notes":     "p:%d rings:%d" % [cnt, _ripples.size()],
		"intensity": 0.4,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("WaterShimmer: stop requested", {"reason": reason})
	_fade_out()

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	if _tween:
		_tween.kill()
	if _bg:
		_bg.queue_free()
		_bg = null
	if _particles_fine:
		_particles_fine.queue_free()
		_particles_fine = null
	if _particles_glow:
		_particles_glow.queue_free()
		_particles_glow = null
	_ripples.clear()


# ══════════════════════════════════════════════════════════════════════════════
# Ripple system
# ══════════════════════════════════════════════════════════════════════════════
# Each ripple: [px, py, current_radius, expand_speed, alpha, line_width]

func _update_ripples(delta: float) -> void:
	_ripple_timer += delta
	if _ripple_timer >= ripple_interval:
		_ripple_timer -= ripple_interval
		_spawn_ripple_event()

	var i := _ripples.size() - 1
	while i >= 0:
		var rip      = _ripples[i]
		var max_r    := rip[3] as float   # stored as max_radius in slot 3
		rip[2] = (rip[2] as float) + (rip[3] as float) * delta   # grow

		# Re-use slot 3 for max_radius tracking — overwrite only alpha
		var progress := (rip[2] as float) / (max_r * 8.0)        # 0→1 over lifetime
		rip[4] = clampf(1.0 - progress, 0.0, 1.0) * (rip[5] as float)
		if rip[4] <= 0.01:
			_ripples.remove_at(i)
		i -= 1

	queue_redraw()

func _spawn_ripple_event() -> void:
	var count := 1 + module_rng.randi_range(0, ripple_max_per_event - 1)
	for _k in count:
		var px        := module_rng.randf() * TOTAL_W
		var py        := module_rng.randf() * TOTAL_H
		var max_r     := 80.0 + module_rng.randf() * 340.0
		# expand_speed so ring reaches max_r in ~5-8 seconds
		var spd       := max_r / (5.0 + module_rng.randf() * 3.0)
		var base_alpha := 0.55 + module_rng.randf() * 0.45
		var width      := 1.0 + module_rng.randf() * 1.5
		# [px, py, radius, expand_speed, alpha, line_width]
		# Note: alpha slot is used as BASE alpha; _update multiplies by (1-progress)
		_ripples.append([px, py, 4.0, spd, base_alpha, width])


# ══════════════════════════════════════════════════════════════════════════════
# Setup
# ══════════════════════════════════════════════════════════════════════════════

func _setup_scene() -> void:
	_setup_background()
	_setup_glow_particles()
	_setup_fine_particles()

func _setup_background() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0.01, 0.04, 0.10)
	_bg.size  = Vector2(TOTAL_W, TOTAL_H)

	var bg_shader := Shader.new()
	bg_shader.code = _BG_SHADER
	_bg_shader_mat = ShaderMaterial.new()
	_bg_shader_mat.shader = bg_shader
	_bg_shader_mat.set_shader_parameter("wave_speed", wave_speed * 0.54)
	_bg_shader_mat.set_shader_parameter("intensity",  caustic_intensity)
	_bg.material = _bg_shader_mat

	add_child(_bg)

func _setup_glow_particles() -> void:
	_particles_glow = GPUParticles2D.new()
	add_child(_particles_glow)

	_particles_glow.position      = Vector2.ZERO
	_particles_glow.amount        = glow_particle_count
	_particles_glow.lifetime      = 30.0
	_particles_glow.preprocess    = 30.0
	_particles_glow.explosiveness = 0.0
	_particles_glow.randomness    = 0.0
	_particles_glow.fixed_fps     = 30
	_particles_glow.emitting      = true
	_particles_glow.one_shot      = false

	var shader := Shader.new()
	shader.code = _GLOW_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("current_spd", current_speed)
	_particles_glow.process_material = mat
	_particles_glow.texture = _make_dot_texture(128)

	var blend_mat := CanvasItemMaterial.new()
	blend_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_particles_glow.material = blend_mat

func _setup_fine_particles() -> void:
	_particles_fine = GPUParticles2D.new()
	add_child(_particles_fine)

	_particles_fine.position      = Vector2.ZERO
	_particles_fine.amount        = fine_particle_count
	_particles_fine.lifetime      = 25.0
	_particles_fine.preprocess    = 25.0
	_particles_fine.explosiveness = 0.0
	_particles_fine.randomness    = 0.0
	_particles_fine.fixed_fps     = 30
	_particles_fine.emitting      = true
	_particles_fine.one_shot      = false

	var shader := Shader.new()
	shader.code = _FINE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("wave_spd",    wave_speed)
	mat.set_shader_parameter("current_spd", current_speed)
	_particles_fine.process_material = mat
	_particles_fine.texture = _make_dot_texture(24)

	var blend_mat := CanvasItemMaterial.new()
	blend_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_particles_fine.material = blend_mat


# ── Texture helper ─────────────────────────────────────────────────────────────

func _make_dot_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx  := size * 0.5
	var cy  := size * 0.5
	var r   := size * 0.5
	for py in size:
		for px in size:
			var d     := Vector2(px - cx, py - cy).length() / r
			var t     := clampf((d - 0.15) / 0.85, 0.0, 1.0)
			var alpha := 1.0 - t * t * (3.0 - 2.0 * t)
			img.set_pixel(px, py, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(img)


# ── Fade helpers ───────────────────────────────────────────────────────────────

func _fade_in() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 2.5).set_ease(Tween.EASE_IN)

func _fade_out() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, _WIND_DOWN_DUR).set_ease(Tween.EASE_OUT)
