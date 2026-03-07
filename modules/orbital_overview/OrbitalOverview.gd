## OrbitalOverview — slowly rotating 3D wireframe sphere + radar sweep.
## Drawn via _draw() using phosphor green/cyan palette.
## Covers the full 1024×3072 framebuffer across all 4 panels.
extends Node2D

var module_id := "orbital_overview"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

# ─── Private state ────────────────────────────────────────────────────────────
var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false

# Render geometry
var _total_size: Vector2i
var _center: Vector2
var _sphere_radius: float

# Animation params
var _rotation_speed: float      # radians/sec around Y
var _radar_speed: float         # radians/sec
var _radar_angle: float = 0.0
var _rotation_y: float = 0.0    # current Y-axis rotation

# Sphere wireframe — latitude/longitude lines
const LATITUDES := 10
const LONGITUDES := 16
const SPHERE_VERTS_LAT := 64    # points per latitude circle
const SPHERE_VERTS_LON := 64    # points per longitude line

# Colors
const COLOR_GRID := Color(0.0, 0.7, 0.3, 0.5)
const COLOR_EQUATOR := Color(0.0, 1.0, 0.5, 0.9)
const COLOR_RADAR := Color(0.0, 1.0, 0.8, 0.85)
const COLOR_RADAR_SWEEP := Color(0.0, 1.0, 0.6, 0.2)
const COLOR_CROSSHAIR := Color(0.0, 0.8, 0.4, 0.6)
const COLOR_DOT := Color(0.3, 1.0, 0.5, 1.0)

# Winddown
var _wind_down_timer: float = 0.0
var _wind_down_dur: float = 2.0
var _winding_down := false

# SVG globe sprite — black strokes recoloured to phosphor green via inline shader
const GLOBE_SHADER_SRC := """
shader_type canvas_item;
uniform vec4 tint_color : source_color = vec4(0.0, 0.85, 0.45, 0.85);
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float blackness = 1.0 - max(max(tex.r, tex.g), tex.b);
    COLOR = vec4(tint_color.rgb, tex.a * blackness * tint_color.a);
}
"""
var _globe_tex    : Texture2D = null
var _globe_shader : Shader    = null
var _globe_sprite : Sprite2D  = null

func module_configure(ctx: Dictionary) -> void:
	_manifest = ctx["manifest"]
	module_rng = RNG.make_rng(ctx["seed"])
	_panel_layout = ctx["panel_layout"]
	_virtual_space = ctx["virtual_space"]

func module_start() -> void:
	module_started_at = App.station_time
	_stop_requested = false
	_finished = false
	_winding_down = false
	_wind_down_timer = 0.0

	_total_size = _panel_layout.get_total_real_size()
	_center = Vector2(_total_size.x * 0.5, _total_size.y * 0.5)
	# Sphere fits within the narrower dimension with some margin
	_sphere_radius = minf(_total_size.x, _total_size.y) * 0.38

	# Randomise animation params from seed
	_rotation_speed = module_rng.randf_range(0.08, 0.18)  # slow rotation
	_radar_speed = module_rng.randf_range(0.4, 0.9)
	_radar_angle = module_rng.randf_range(0.0, TAU)
	_rotation_y = module_rng.randf_range(0.0, TAU)

	# Load SVG wireframe earth and attach as a Sprite2D child (z_index=-1 so
	# _draw() overlays — radar ring, crosshairs, brackets — appear on top).
	_free_globe_sprite()
	_globe_tex = null
	var svg := "res://assets/images/Wireframe-Earth-Globe.svg"
	if ResourceLoader.exists(svg):
		var res := load(svg)
		if res is Texture2D:
			_globe_tex = res as Texture2D
		else:
			Log.warn("OrbitalOverview: SVG is not Texture2D: " + svg)
	else:
		Log.warn("OrbitalOverview: SVG not found — using procedural wireframe")

	if _globe_tex:
		if _globe_shader == null:
			_globe_shader = Shader.new()
			_globe_shader.code = GLOBE_SHADER_SRC
		var tex_sz   := float(maxi(_globe_tex.get_width(), _globe_tex.get_height()))
		var globe_px := _sphere_radius * 2.0
		_globe_sprite          = Sprite2D.new()
		_globe_sprite.texture  = _globe_tex
		_globe_sprite.position = _center
		_globe_sprite.scale    = Vector2.ONE * globe_px / tex_sz
		_globe_sprite.rotation = _rotation_y
		_globe_sprite.z_index  = -1
		_globe_sprite.z_as_relative = true
		var mat := ShaderMaterial.new()
		mat.shader = _globe_shader
		mat.set_shader_parameter("tint_color",
				Color(COLOR_EQUATOR.r, COLOR_EQUATOR.g, COLOR_EQUATOR.b, 0.85))
		_globe_sprite.material = mat
		add_child(_globe_sprite)

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	_rotation_y  += _rotation_speed * delta
	_radar_angle += _radar_speed * delta

	if is_instance_valid(_globe_sprite):
		_globe_sprite.rotation = _rotation_y

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _wind_down_dur:
			_finished = true

	queue_redraw()

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha_scale := 1.0
	if _winding_down:
		alpha_scale = clampf(1.0 - _wind_down_timer / _wind_down_dur, 0.0, 1.0)

	# Fade the globe sprite to match wind-down alpha
	if is_instance_valid(_globe_sprite):
		_globe_sprite.modulate.a = alpha_scale

	_draw_grid_background(alpha_scale)
	# Procedural wireframe only when SVG sprite is not available
	if not is_instance_valid(_globe_sprite):
		_draw_sphere_wireframe(alpha_scale)
	_draw_radar_circle(alpha_scale)
	_draw_crosshairs(alpha_scale)
	_draw_corner_brackets(alpha_scale)

func _draw_grid_background(alpha_scale: float) -> void:
	# Subtle hex-grid style background dots
	var col := Color(COLOR_GRID.r, COLOR_GRID.g, COLOR_GRID.b, COLOR_GRID.a * alpha_scale * 0.3)
	var spacing := 48.0
	var cols_count := int(_total_size.x / spacing) + 1
	var rows_count := int(_total_size.y / spacing) + 1
	for row in rows_count:
		for col_i in cols_count:
			var ox := 0.0 if row % 2 == 0 else spacing * 0.5
			var pt := Vector2(col_i * spacing + ox, row * spacing)
			draw_circle(pt, 1.5, col)

func _draw_sphere_wireframe(alpha_scale: float) -> void:
	var ry := _rotation_y

	# Draw longitude lines
	for i in LONGITUDES:
		var lon_angle := (TAU / LONGITUDES) * i
		var pts: PackedVector2Array = PackedVector2Array()
		for j in SPHERE_VERTS_LON + 1:
			var lat := (PI / SPHERE_VERTS_LON) * j - PI * 0.5
			var x3 := cos(lat) * cos(lon_angle + ry)
			var y3 := sin(lat)
			var z3 := cos(lat) * sin(lon_angle + ry)
			var pt := _project_3d(x3, y3, z3)
			pts.push_back(pt)

		var is_prime := (i % 4 == 0)
		var col_lon: Color
		if is_prime:
			col_lon = Color(COLOR_EQUATOR.r, COLOR_EQUATOR.g, COLOR_EQUATOR.b, COLOR_EQUATOR.a * alpha_scale)
		else:
			col_lon = Color(COLOR_GRID.r, COLOR_GRID.g, COLOR_GRID.b, COLOR_GRID.a * alpha_scale)
		draw_polyline(pts, col_lon, 1.0 if is_prime else 0.5, true)

	# Draw latitude lines
	for i in LATITUDES + 1:
		var lat := (PI / LATITUDES) * i - PI * 0.5
		var pts: PackedVector2Array = PackedVector2Array()
		for j in SPHERE_VERTS_LAT + 1:
			var lon_angle := (TAU / SPHERE_VERTS_LAT) * j
			var x3 := cos(lat) * cos(lon_angle + ry)
			var y3 := sin(lat)
			var z3 := cos(lat) * sin(lon_angle + ry)
			var pt := _project_3d(x3, y3, z3)
			pts.push_back(pt)

		var is_equator := (i == LATITUDES / 2)
		var col_lat: Color
		if is_equator:
			col_lat = Color(COLOR_EQUATOR.r, COLOR_EQUATOR.g, COLOR_EQUATOR.b, COLOR_EQUATOR.a * alpha_scale)
		else:
			col_lat = Color(COLOR_GRID.r, COLOR_GRID.g, COLOR_GRID.b, COLOR_GRID.a * alpha_scale * 0.7)
		draw_polyline(pts, col_lat, 1.5 if is_equator else 0.5, true)

func _project_3d(x: float, y: float, z: float) -> Vector2:
	# Simple orthographic projection onto 2D
	# Scale by sphere_radius and offset to center
	return _center + Vector2(x * _sphere_radius, y * _sphere_radius)

func _draw_radar_circle(alpha_scale: float) -> void:
	var radar_r := _sphere_radius * 1.15
	var col_ring := Color(COLOR_RADAR.r, COLOR_RADAR.g, COLOR_RADAR.b, COLOR_RADAR.a * alpha_scale * 0.5)
	draw_arc(_center, radar_r, 0.0, TAU, 64, col_ring, 1.5, true)

	# Radar sweep — a filled arc segment
	var sweep_arc := TAU * 0.25
	var sweep_start := _radar_angle - sweep_arc
	var col_sweep_outer := Color(COLOR_RADAR_SWEEP.r, COLOR_RADAR_SWEEP.g, COLOR_RADAR_SWEEP.b,
								 COLOR_RADAR_SWEEP.a * alpha_scale)
	draw_arc(_center, radar_r * 0.95, sweep_start, _radar_angle, 32, col_sweep_outer, radar_r * 0.95, true)

	# Sweep line
	var sweep_end_pt := _center + Vector2(cos(_radar_angle), sin(_radar_angle)) * radar_r
	var col_line := Color(COLOR_RADAR.r, COLOR_RADAR.g, COLOR_RADAR.b, COLOR_RADAR.a * alpha_scale)
	draw_line(_center, sweep_end_pt, col_line, 2.0, true)

func _draw_crosshairs(alpha_scale: float) -> void:
	var col := Color(COLOR_CROSSHAIR.r, COLOR_CROSSHAIR.g, COLOR_CROSSHAIR.b, COLOR_CROSSHAIR.a * alpha_scale)
	var gap := 30.0
	var len := 60.0
	# Horizontal
	draw_line(_center + Vector2(-_sphere_radius - len, 0), _center + Vector2(-gap, 0), col, 0.8, true)
	draw_line(_center + Vector2(gap, 0), _center + Vector2(_sphere_radius + len, 0), col, 0.8, true)
	# Vertical
	draw_line(_center + Vector2(0, -_sphere_radius - len), _center + Vector2(0, -gap), col, 0.8, true)
	draw_line(_center + Vector2(0, gap), _center + Vector2(0, _sphere_radius + len), col, 0.8, true)

	# Center dot
	draw_circle(_center, 4.0, Color(COLOR_DOT.r, COLOR_DOT.g, COLOR_DOT.b, COLOR_DOT.a * alpha_scale))

func _draw_corner_brackets(alpha_scale: float) -> void:
	var col := Color(COLOR_CROSSHAIR.r, COLOR_CROSSHAIR.g, COLOR_CROSSHAIR.b, COLOR_CROSSHAIR.a * alpha_scale * 0.6)
	var blen := 40.0
	var bthick := 1.5
	var margin := 20.0

	# Top-left
	var tl := Vector2(margin, margin)
	draw_line(tl, tl + Vector2(blen, 0), col, bthick)
	draw_line(tl, tl + Vector2(0, blen), col, bthick)

	# Top-right
	var tr := Vector2(_total_size.x - margin, margin)
	draw_line(tr, tr + Vector2(-blen, 0), col, bthick)
	draw_line(tr, tr + Vector2(0, blen), col, bthick)

	# Bottom-left
	var bl := Vector2(margin, _total_size.y - margin)
	draw_line(bl, bl + Vector2(blen, 0), col, bthick)
	draw_line(bl, bl + Vector2(0, -blen), col, bthick)

	# Bottom-right
	var br := Vector2(_total_size.x - margin, _total_size.y - margin)
	draw_line(br, br + Vector2(-blen, 0), col, bthick)
	draw_line(br, br + Vector2(0, -blen), col, bthick)

func module_status() -> Dictionary:
	return {
		"ok": true,
		"notes": "rotating %.1f rad" % _rotation_y,
		"intensity": 0.4
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down = true
	_wind_down_timer = 0.0
	Log.debug("OrbitalOverview: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_free_globe_sprite()
	_globe_tex    = null
	_globe_shader = null

func _free_globe_sprite() -> void:
	if is_instance_valid(_globe_sprite):
		_globe_sprite.queue_free()
	_globe_sprite = null
