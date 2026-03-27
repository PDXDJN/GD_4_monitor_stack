## OrbitalOverview — fully procedural rotating wireframe globe with rich HUD.
## Pure draw_polyline() / draw_arc() / draw_string() — no external assets.
##
## All rendering in identity-space (no canvas transform flip).  The orthographic
## projection negates X and tilted-Y internally so that north = up, and the
## continent layout is correct for the phosphor-green aesthetic.
extends Node2D

var module_id := "orbital_overview"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

# ─── State ──────────────────────────────────────────────────────────────────────
var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished       := false

var _total_size:    Vector2i
var _center:        Vector2
var _sphere_radius: float

var _rotation_speed: float
var _radar_speed:    float
var _radar_angle := 0.0
var _rotation_y  := 0.0

var _wind_down_timer := 0.0
var _wind_down_dur   := 2.5
var _winding_down    := false

var _font: Font

# Precomputed trig for axis tilt
var _tilt_cos := 1.0
var _tilt_sin := 0.0

# Satellites — [{inc, raan, speed, theta, orbit_r, color}]
var _satellites: Array = []

# Surface contact blink phases (one float per _CONTACTS entry)
var _contact_phases: Array = []

# Per-panel telemetry (4 arrays of line strings)
var _telem_panels: Array = [[], [], [], []]
var _telem_timer := 0.0
const _TELEM_INTERVAL := 2.3

# ─── Geometry constants ─────────────────────────────────────────────────────────
const LATITUDES  := 10
const LONGITUDES := 16
const LAT_VERTS  := 64
const LON_VERTS  := 48
const AXIS_TILT  := 0.41   # ~23.5° Earth-like axial tilt

# ─── Palette ────────────────────────────────────────────────────────────────────
const C_GRID   := Color(0.00, 0.85, 0.40, 0.75)
const C_BRIGHT := Color(0.10, 1.00, 0.55, 0.92)
const C_RADAR  := Color(0.00, 1.00, 0.80, 0.82)
const C_SWEEP  := Color(0.00, 0.90, 0.55, 0.14)
const C_DIM    := Color(0.00, 0.55, 0.28, 0.48)
const C_HUD    := Color(0.20, 1.00, 0.60, 0.82)
const C_SAT_A  := Color(0.00, 1.00, 0.90, 0.88)
const C_SAT_B  := Color(0.70, 1.00, 0.30, 0.82)
const C_SAT_C  := Color(1.00, 0.65, 0.15, 0.82)

const _SAT_LABELS := ["A", "B", "C"]
const _SAT_ALTS   := [408, 621, 785]   # display altitudes (km)

# ─── Surface contacts [lon_deg, lat_deg, label] ─────────────────────────────────
const _CONTACTS := [
	[-74.0,  40.7, "NYC"],
	[ 37.6,  55.7, "MSK"],
	[116.4,  39.9, "BJG"],
	[-46.6, -23.5, "SAO"],
	[139.7,  35.7, "TYO"],
	[ -0.1,  51.5, "LON"],
	[ 36.8,  -1.3, "NAI"],
]

# ─── Continental coastlines [lon_deg, lat_deg] ──────────────────────────────────
const _COAST := [
	# North America
	[[-165,62],[-133,55],[-124,47],[-122,37],[-117,32],[-110,23],
	 [-90,16],[-83,10],[-80,25],[-76,35],[-70,42],[-66,44],[-60,44],
	 [-54,47],[-54,52],[-60,56],[-65,62],[-78,63],[-95,63],
	 [-120,70],[-140,70],[-157,71],[-165,65],[-165,62]],
	# South America
	[[-77,8],[-62,11],[-52,4],[-35,-4],[-35,-10],[-40,-20],[-44,-23],
	 [-49,-28],[-52,-33],[-56,-38],[-62,-45],[-65,-55],[-68,-54],
	 [-74,-45],[-72,-35],[-72,-25],[-77,-14],[-80,-4],[-80,1],[-77,8]],
	# Europe
	[[-9,38],[-6,36],[3,41],[5,43],[9,44],[14,44],[14,46],[18,40],
	 [22,37],[26,38],[28,42],[24,56],[22,60],[25,60],[30,65],[25,71],
	 [18,71],[8,70],[5,62],[8,63],[5,57],[10,58],[14,56],[18,58],
	 [24,56],[20,55],[15,54],[8,54],[2,51],[0,51],[-5,50],[-5,48],
	 [-2,44],[-9,44],[-9,38]],
	# Africa
	[[-6,36],[11,37],[15,33],[25,30],[33,31],[36,25],[38,18],[42,12],
	 [44,11],[51,11],[44,2],[41,-2],[40,-10],[36,-18],[31,-25],[27,-32],
	 [20,-34],[18,-34],[14,-30],[12,-18],[9,-6],[8,4],[2,5],[-4,5],
	 [-16,14],[-17,21],[-13,27],[-8,34],[-6,36]],
	# Eurasia
	[[28,42],[40,32],[44,12],[50,22],[56,24],[60,22],[72,20],[73,18],
	 [77,8],[80,14],[80,22],[84,27],[88,22],[100,8],[103,1],[105,-5],
	 [110,-7],[115,-8],[124,-8],[132,-8],[136,-5],[141,-10],[152,-22],
	 [148,-18],[142,-10],[134,-14],[130,-12],[130,0],[122,6],[118,18],
	 [121,24],[120,30],[122,37],[120,40],[114,40],[110,42],[100,52],
	 [90,52],[80,50],[70,54],[60,55],[50,62],[55,65],[60,68],[70,66],
	 [80,68],[90,68],[100,70],[110,68],[120,65],[130,62],[142,52],
	 [130,42],[122,37],[120,30],[118,18],[108,20],[100,14],[96,16],
	 [92,22],[88,22],[80,26],[72,26],[68,24],[62,26],[56,24],[50,22],
	 [48,30],[44,32],[40,32],[38,38],[36,30],[28,42]],
	# Australia
	[[114,-22],[115,-35],[118,-38],[124,-34],[132,-32],[138,-35],
	 [143,-38],[150,-38],[154,-28],[152,-22],[148,-20],[142,-10],
	 [136,-12],[130,-16],[126,-14],[123,-18],[114,-22]],
]

# ═════════════════════════════════════════════════════════════════════════════════
# Module contract
# ═════════════════════════════════════════════════════════════════════════════════

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

	_total_size    = _panel_layout.get_total_real_size()
	_center        = Vector2(_total_size) * 0.5
	_sphere_radius = minf(_total_size.x, _total_size.y) * 0.38

	_tilt_cos = cos(AXIS_TILT)
	_tilt_sin = sin(AXIS_TILT)

	_rotation_speed = module_rng.randf_range(0.06, 0.14)
	_radar_speed    = module_rng.randf_range(0.35, 0.75)
	_radar_angle    = module_rng.randf_range(0.0, TAU)
	_rotation_y     = module_rng.randf_range(0.0, TAU)

	_font = ThemeDB.fallback_font

	# Three satellites on varied orbital planes
	_satellites = [
		{inc=module_rng.randf_range(0.25, 0.55), raan=module_rng.randf_range(0.0, TAU),
		 speed=module_rng.randf_range(0.18, 0.38), theta=module_rng.randf_range(0.0, TAU),
		 orbit_r=1.30, color=C_SAT_A},
		{inc=module_rng.randf_range(0.80, 1.20), raan=module_rng.randf_range(0.0, TAU),
		 speed=module_rng.randf_range(0.12, 0.26), theta=module_rng.randf_range(0.0, TAU),
		 orbit_r=1.43, color=C_SAT_B},
		{inc=module_rng.randf_range(1.30, 1.55), raan=module_rng.randf_range(0.0, TAU),
		 speed=module_rng.randf_range(0.22, 0.46), theta=module_rng.randf_range(0.0, TAU),
		 orbit_r=1.58, color=C_SAT_C},
	]

	_contact_phases = []
	for i in _CONTACTS.size():
		_contact_phases.append(module_rng.randf_range(0.0, TAU))

	_telem_timer = 0.0
	_refresh_telem()

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	_rotation_y  += _rotation_speed * delta
	_radar_angle += _radar_speed    * delta

	for sat in _satellites:
		sat.theta += sat.speed * delta

	for i in _contact_phases.size():
		_contact_phases[i] = fmod(_contact_phases[i] + delta * (1.2 + i * 0.25), TAU)

	_telem_timer += delta
	if _telem_timer >= _TELEM_INTERVAL:
		_telem_timer = 0.0
		_refresh_telem()

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _wind_down_dur:
			_finished = true

	queue_redraw()

func module_status() -> Dictionary:
	return {"ok": true, "notes": "rot %.2f rad" % _rotation_y, "intensity": 0.4}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("OrbitalOverview: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	pass

# ═════════════════════════════════════════════════════════════════════════════════
# Telemetry — per-panel differentiated data
# ═════════════════════════════════════════════════════════════════════════════════

func _refresh_telem() -> void:
	var t       := App.station_time
	var elapsed := t - module_started_at if module_started_at > 0.0 else 0.0
	var lon_deg := fmod(rad_to_deg(_rotation_y), 360.0)

	# Panel 0 — Mission Overview
	_telem_panels[0] = [
		"ORBITAL DISPLAY v2.4",
		"════════════════════",
		"UPTIME  %8.1fs" % t,
		"ELAPSED %8.1fs" % elapsed,
		"",
		"ROT  %+7.3f°/s" % rad_to_deg(_rotation_speed),
		"AZM  %+8.1f°"   % lon_deg,
		"",
		"TRACKS:   3 ACTIVE",
		"CONTACTS: 7 NOMINAL",
		"RADAR:    ACTIVE",
		"SUBSYS:   NOMINAL",
	]

	# Panel 1 — Satellite Tracking
	_telem_panels[1] = [
		"SATELLITE TRACKING",
		"════════════════════",
		" ID  ALT    INC    SPD",
	]
	for si in _satellites.size():
		_telem_panels[1].append(" %s  %dkm %5.1f° %4.1f°/s" % [
			_SAT_LABELS[si], _SAT_ALTS[si],
			rad_to_deg(_satellites[si].inc),
			rad_to_deg(_satellites[si].speed)])
	_telem_panels[1].append_array([
		"",
		"ORBITS:  COMPUTED",
		"QUALITY: HIGH",
		"EPOCH:  +%.0fs" % elapsed,
	])

	# Panel 2 — Contact Matrix
	_telem_panels[2] = ["CONTACT MATRIX", "════════════════════"]
	var flicker := int(fmod(t * 0.3, float(_CONTACTS.size())))
	for ci in _CONTACTS.size():
		var lat_v: float = _CONTACTS[ci][1]
		var lon_v: float = _CONTACTS[ci][0]
		var status := "LINK"
		if ci == flicker and sin(t * 2.0) > 0.7:
			status = "SYNC"
		_telem_panels[2].append("%s %5.1f%s %5.1f%s %s" % [
			_CONTACTS[ci][2],
			absf(lat_v), "N" if lat_v >= 0 else "S",
			absf(lon_v), "E" if lon_v >= 0 else "W",
			status])
	_telem_panels[2].append_array(["", "ALL LINKS NOMINAL"])

	# Panel 3 — System Status
	_telem_panels[3] = [
		"SYSTEM STATUS",
		"════════════════════",
		"RENDER: 30 FPS",
		"SWEEP: %5.2f°/s" % rad_to_deg(_radar_speed),
		"UPLINK: OK",
		"BUFFER: NOMINAL",
		"",
		"TILT:   %+.1f°" % rad_to_deg(AXIS_TILT),
		"PANELS: 4 ACTIVE",
		"",
		"STATUS: OPERATIONAL",
	]

# ═════════════════════════════════════════════════════════════════════════════════
# 3-D projection — identity-space, no canvas transform
# ═════════════════════════════════════════════════════════════════════════════════

# Orthographic projection with axis tilt.  X and tilted-Y are negated so that
# north appears at the top and geographic east appears on the left (the same
# mirror the original flipped-canvas code produced).
func _project_3d(x: float, y: float, z: float) -> Vector2:
	var yt := y * _tilt_cos - z * _tilt_sin
	return _center + Vector2(-x * _sphere_radius, -yt * _sphere_radius)

# Z after tilt: > 0 → front hemisphere (facing viewer).
func _depth_z(x: float, y: float, z: float) -> float:
	return y * _tilt_sin + z * _tilt_cos

# Satellite orbital position (unit-sphere × orbit_r, inertial frame).
func _sat_xyz_at(sat: Dictionary, theta: float) -> Vector3:
	var inc  := float(sat.inc)
	var raan := float(sat.raan)
	var r    := float(sat.orbit_r)
	var u    := Vector3(cos(raan),                       0.0,        sin(raan))
	var v    := Vector3(-sin(raan) * cos(inc), sin(inc), cos(raan) * cos(inc))
	return (u * cos(theta) + v * sin(theta)) * r

func _project_pt(p: Vector3) -> Vector2:
	return _project_3d(p.x, p.y, p.z)

func _depth_pt(p: Vector3) -> float:
	return _depth_z(p.x, p.y, p.z)

# ═════════════════════════════════════════════════════════════════════════════════
# Draw dispatcher — ordered back-to-front
# ═════════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha := 1.0
	if _winding_down:
		alpha = clampf(1.0 - _wind_down_timer / _wind_down_dur, 0.0, 1.0)

	# Background
	_draw_grid_bg(alpha)
	_draw_scanlines(alpha)

	# Globe
	_draw_atmosphere(alpha)
	_draw_sphere_wireframe(alpha)
	_draw_continents(alpha)
	_draw_surface_contacts(alpha)
	_draw_pole_markers(alpha)

	# Orbital elements
	_draw_orbital_tracks(alpha)
	_draw_satellite_blips(alpha)
	_draw_downlinks(alpha)

	# Radar overlay
	_draw_radar(alpha)
	_draw_crosshairs(alpha)
	_draw_compass_rose(alpha)

	# HUD chrome
	_draw_corner_brackets(alpha)
	_draw_panel_seams(alpha)
	_draw_telemetry(alpha)

# ═════════════════════════════════════════════════════════════════════════════════
# Background layers
# ═════════════════════════════════════════════════════════════════════════════════

func _draw_grid_bg(alpha: float) -> void:
	var col     := Color(C_GRID.r, C_GRID.g, C_GRID.b, C_GRID.a * alpha * 0.38)
	var spacing := 48.0
	var cols_n  := int(_total_size.x / spacing) + 1
	var rows_n  := int(_total_size.y / spacing) + 1
	for row in rows_n:
		for ci in cols_n:
			var ox := 0.0 if row % 2 == 0 else spacing * 0.5
			draw_circle(Vector2(ci * spacing + ox, row * spacing), 1.2, col)

func _draw_scanlines(alpha: float) -> void:
	var col := Color(0.0, 0.0, 0.0, 0.16 * alpha)
	var y   := 0.0
	while y < _total_size.y:
		draw_line(Vector2(0.0, y), Vector2(_total_size.x, y), col, 1.0)
		y += 3.0

# ═════════════════════════════════════════════════════════════════════════════════
# Globe layers
# ═════════════════════════════════════════════════════════════════════════════════

func _draw_atmosphere(alpha: float) -> void:
	# Concentric limb-glow arcs — cyan-blue shift, decreasing alpha
	var layers := [
		[1.005, 3.0, Color(0.15, 0.85, 0.65, 0.15 * alpha)],
		[1.020, 2.4, Color(0.10, 0.75, 0.80, 0.10 * alpha)],
		[1.045, 1.8, Color(0.05, 0.60, 0.85, 0.06 * alpha)],
		[1.080, 1.2, Color(0.00, 0.50, 0.90, 0.03 * alpha)],
	]
	for layer in layers:
		draw_arc(_center, _sphere_radius * float(layer[0]), 0.0, TAU, 64,
				layer[2] as Color, float(layer[1]), true)

func _draw_sphere_wireframe(alpha: float) -> void:
	var ry := _rotation_y
	# Longitude lines
	for i in LONGITUDES:
		var lon_angle := (TAU / LONGITUDES) * i
		var pts       := PackedVector2Array()
		for j in LON_VERTS + 1:
			var lat := (PI / LON_VERTS) * j - PI * 0.5
			pts.push_back(_project_3d(
				cos(lat) * cos(lon_angle - ry), sin(lat),
				cos(lat) * sin(lon_angle - ry)))
		var prime := (i % 4 == 0)
		var lc := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, C_BRIGHT.a * alpha) \
				if prime else \
				Color(C_GRID.r, C_GRID.g, C_GRID.b, C_GRID.a * alpha)
		draw_polyline(pts, lc, 1.0 if prime else 0.5, true)
	# Latitude lines
	for i in LATITUDES + 1:
		var lat := (PI / LATITUDES) * i - PI * 0.5
		var pts := PackedVector2Array()
		for j in LAT_VERTS + 1:
			var lon_angle := (TAU / LAT_VERTS) * j
			pts.push_back(_project_3d(
				cos(lat) * cos(lon_angle - ry), sin(lat),
				cos(lat) * sin(lon_angle - ry)))
		var is_eq := (i == LATITUDES / 2)
		var lc := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, C_BRIGHT.a * alpha) \
				if is_eq else \
				Color(C_GRID.r, C_GRID.g, C_GRID.b, C_GRID.a * alpha * 0.65)
		draw_polyline(pts, lc, 1.5 if is_eq else 0.5, true)

func _draw_continents(alpha: float) -> void:
	var col_f := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, alpha * 0.88)
	var col_b := Color(C_GRID.r,   C_GRID.g,   C_GRID.b,   alpha * 0.15)
	for coast in _COAST:
		var pts_f := PackedVector2Array()
		var pts_b := PackedVector2Array()
		for pair in coast:
			var lon := deg_to_rad(float(pair[0]))
			var lat := deg_to_rad(float(pair[1]))
			var x3  := cos(lat) * cos(lon - _rotation_y)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _rotation_y)
			var pt  := _project_3d(x3, y3, z3)
			if _depth_z(x3, y3, z3) >= 0.0:
				if pts_b.size() > 1:
					draw_polyline(pts_b, col_b, 0.5, true)
				pts_b.clear()
				pts_f.push_back(pt)
			else:
				if pts_f.size() > 1:
					draw_polyline(pts_f, col_f, 1.3, true)
				pts_f.clear()
				pts_b.push_back(pt)
		if pts_f.size() > 1:
			draw_polyline(pts_f, col_f, 1.3, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, col_b, 0.5, true)

func _draw_surface_contacts(alpha: float) -> void:
	for i in _CONTACTS.size():
		var lon := deg_to_rad(float(_CONTACTS[i][0]))
		var lat := deg_to_rad(float(_CONTACTS[i][1]))
		var x3  := cos(lat) * cos(lon - _rotation_y)
		var y3  := sin(lat)
		var z3  := cos(lat) * sin(lon - _rotation_y)
		if _depth_z(x3, y3, z3) < 0.05:
			continue   # behind the globe
		var pt    := _project_3d(x3, y3, z3)
		var blink: float = absf(sin(float(_contact_phases[i]) * 2.0))
		var ca:    float = C_BRIGHT.a * alpha * (0.5 + 0.5 * blink)
		var col   := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, ca)
		# Dot + ring
		draw_circle(pt, 3.0, col)
		draw_arc(pt, 8.0, 0.0, TAU, 12,
				Color(col.r, col.g, col.b, col.a * 0.45), 0.8, true)
		# Crosshair ticks
		draw_line(pt + Vector2(-12, 0), pt + Vector2(-5, 0), col, 0.8)
		draw_line(pt + Vector2(  5, 0), pt + Vector2(12, 0), col, 0.8)
		draw_line(pt + Vector2(0, -12), pt + Vector2(0, -5), col, 0.8)
		draw_line(pt + Vector2(0,   5), pt + Vector2(0, 12), col, 0.8)
		# City label (now possible — no canvas flip)
		if _font:
			var label: String = _CONTACTS[i][2]
			draw_string(_font, pt + Vector2(11.0, -5.0), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(col.r, col.g, col.b, col.a * 0.82))

func _draw_pole_markers(alpha: float) -> void:
	var col := Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * alpha)
	for sign_v in [1.0, -1.0]:
		var pp := _project_3d(0.0, sign_v, 0.0)
		draw_line(pp + Vector2(-10, 0), pp + Vector2(10, 0), col, 1.0)
		draw_line(pp + Vector2(0, -10), pp + Vector2(0, 10), col, 1.0)
		draw_arc(pp, 5.0, 0.0, TAU, 8, col, 0.6, true)
	# Dashed polar axis (N→S through the tilt)
	for si in 22:
		if si % 2 == 0:
			var t0 := float(si) / 22.0
			var t1 := float(si + 1) / 22.0
			draw_line(
				_project_3d(0.0, lerp(-1.1, 1.1, t0), 0.0),
				_project_3d(0.0, lerp(-1.1, 1.1, t1), 0.0),
				Color(col.r, col.g, col.b, col.a * 0.5), 0.5)

# ═════════════════════════════════════════════════════════════════════════════════
# Orbital elements
# ═════════════════════════════════════════════════════════════════════════════════

func _draw_orbital_tracks(alpha: float) -> void:
	var N := 96
	for sat in _satellites:
		var col_f := Color(sat.color.r, sat.color.g, sat.color.b, sat.color.a * alpha * 0.52)
		var col_b := Color(sat.color.r, sat.color.g, sat.color.b, sat.color.a * alpha * 0.14)
		var pts_f := PackedVector2Array()
		var pts_b := PackedVector2Array()
		var on_front := true
		for i in N + 1:
			var theta := (TAU / N) * i
			var p     := _sat_xyz_at(sat, theta)
			var proj  := _project_pt(p)
			var dz    := _depth_pt(p)
			if dz >= 0.0:
				if not on_front and pts_b.size() > 1:
					draw_polyline(pts_b, col_b, 0.5, true)
					pts_b.clear()
				pts_f.push_back(proj)
				on_front = true
			else:
				if on_front and pts_f.size() > 1:
					draw_polyline(pts_f, col_f, 1.2, true)
					pts_f.clear()
				pts_b.push_back(proj)
				on_front = false
		if pts_f.size() > 1:
			draw_polyline(pts_f, col_f, 1.2, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, col_b, 0.5, true)

func _draw_satellite_blips(alpha: float) -> void:
	for si in _satellites.size():
		var sat: Dictionary = _satellites[si]
		var p    := _sat_xyz_at(sat, sat.theta)
		var proj := _project_pt(p)
		var dz   := _depth_pt(p)
		var a    := float(sat.color.a) * alpha * (1.0 if dz >= 0.0 else 0.28)
		var col  := Color(sat.color.r, sat.color.g, sat.color.b, a)

		# Diamond marker
		var s := 6.0
		draw_line(proj + Vector2(-s, 0), proj + Vector2(0, -s), col, 1.5, true)
		draw_line(proj + Vector2(0, -s), proj + Vector2(s,  0), col, 1.5, true)
		draw_line(proj + Vector2(s,  0), proj + Vector2(0,  s), col, 1.5, true)
		draw_line(proj + Vector2(0,  s), proj + Vector2(-s, 0), col, 1.5, true)
		draw_circle(proj, 2.5, col)

		# Comet tail — trace back 10 steps along orbit
		var tail := PackedVector2Array()
		tail.push_back(proj)
		for ti in 10:
			tail.push_back(_project_pt(_sat_xyz_at(sat, sat.theta - 0.06 * (ti + 1))))
		if tail.size() > 1:
			draw_polyline(tail, Color(col.r, col.g, col.b, a * 0.45), 0.8, true)

		# Satellite ID label
		if _font:
			draw_string(_font, proj + Vector2(9.0, -4.0), _SAT_LABELS[si],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

func _draw_downlinks(alpha: float) -> void:
	# Draw pulsing dashed lines from front-hemisphere satellites to nearby
	# front-hemisphere contacts (angular proximity < ~35°).
	for si in _satellites.size():
		var sat: Dictionary = _satellites[si]
		var sat_pos := _sat_xyz_at(sat, sat.theta)
		if _depth_pt(sat_pos) < 0.0:
			continue
		var sat_proj := _project_pt(sat_pos)
		var sub_pt   := sat_pos.normalized()

		for ci in _CONTACTS.size():
			var lon := deg_to_rad(float(_CONTACTS[ci][0]))
			var lat := deg_to_rad(float(_CONTACTS[ci][1]))
			var cx  := cos(lat) * cos(lon - _rotation_y)
			var cy  := sin(lat)
			var cz  := cos(lat) * sin(lon - _rotation_y)
			if _depth_z(cx, cy, cz) < 0.0:
				continue
			# Dot product ≈ cos(angle between sub-satellite point and contact)
			var dot_prod := sub_pt.x * cx + sub_pt.y * cy + sub_pt.z * cz
			if dot_prod > 0.82:
				var c_proj := _project_3d(cx, cy, cz)
				var pulse  := 0.5 + 0.5 * sin(App.station_time * 3.0 + float(si * 7 + ci))
				var col    := Color(sat.color.r, sat.color.g, sat.color.b,
						float(sat.color.a) * alpha * 0.42 * pulse)
				_draw_dashed_line(sat_proj, c_proj, col, 6.0, 4.0)

func _draw_dashed_line(from: Vector2, to: Vector2, col: Color,
		dash_len: float, gap_len: float) -> void:
	var dir    := to - from
	var length := dir.length()
	if length < 1.0:
		return
	dir /= length
	var pos := 0.0
	while pos < length:
		var seg_end := minf(pos + dash_len, length)
		draw_line(from + dir * pos, from + dir * seg_end, col, 0.8)
		pos = seg_end + gap_len

# ═════════════════════════════════════════════════════════════════════════════════
# Radar overlay
# ═════════════════════════════════════════════════════════════════════════════════

func _draw_radar(alpha: float) -> void:
	var r        := _sphere_radius * 1.15
	var col_ring := Color(C_RADAR.r, C_RADAR.g, C_RADAR.b, C_RADAR.a * alpha)

	# Glow halo (3 concentric, decreasing alpha)
	for gi in 3:
		var gr := r + float(gi) * 5.0
		var ga := col_ring.a * (1.0 - float(gi) * 0.32) * 0.35
		draw_arc(_center, gr, 0.0, TAU, 64,
				Color(col_ring.r, col_ring.g, col_ring.b, ga),
				float(3 - gi), true)

	# Main ring
	draw_arc(_center, r, 0.0, TAU, 64,
			Color(col_ring.r, col_ring.g, col_ring.b, col_ring.a * 0.58), 1.5, true)

	# Inner reference ring at half radius
	draw_arc(_center, r * 0.5, 0.0, TAU, 48,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * alpha * 0.45), 0.6, true)

	# 24 range tick marks
	var tc := Color(col_ring.r, col_ring.g, col_ring.b, col_ring.a * 0.38)
	for ti in 24:
		var ang  := TAU * float(ti) / 24.0
		var tlen := 9.0 if ti % 6 == 0 else 4.0
		draw_line(
			_center + Vector2(cos(ang), sin(ang)) * (r - tlen),
			_center + Vector2(cos(ang), sin(ang)) * r, tc, 1.0)

	# Radar sweep filled arc
	var sweep_start := _radar_angle - TAU * 0.25
	draw_arc(_center, r * 0.98, sweep_start, _radar_angle, 32,
			Color(C_SWEEP.r, C_SWEEP.g, C_SWEEP.b, C_SWEEP.a * alpha),
			r * 0.98, true)

	# Sweep leading edge line
	var tip := _center + Vector2(cos(_radar_angle), sin(_radar_angle)) * r
	draw_line(_center, tip,
			Color(col_ring.r, col_ring.g, col_ring.b, col_ring.a * alpha), 2.0, true)

func _draw_crosshairs(alpha: float) -> void:
	var col := Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * alpha)
	var gap := 30.0
	var ext := _sphere_radius + 65.0
	draw_line(_center + Vector2(-ext, 0), _center + Vector2(-gap, 0), col, 0.8, true)
	draw_line(_center + Vector2( gap, 0), _center + Vector2( ext, 0), col, 0.8, true)
	draw_line(_center + Vector2(0, -ext), _center + Vector2(0, -gap), col, 0.8, true)
	draw_line(_center + Vector2(0,  gap), _center + Vector2(0,  ext), col, 0.8, true)
	draw_circle(_center, 4.0,
			Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, C_BRIGHT.a * alpha))

func _draw_compass_rose(alpha: float) -> void:
	if not _font:
		return
	var r   := _sphere_radius * 1.24
	var col := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * 0.58)
	# N(top) S(bottom) E(right) W(left)
	var dirs := [
		[Vector2( 0, -1), "N"],
		[Vector2( 0,  1), "S"],
		[Vector2( 1,  0), "E"],
		[Vector2(-1,  0), "W"],
	]
	for d in dirs:
		var dir: Vector2  = d[0]
		var label: String = d[1]
		# Tick mark
		draw_line(_center + dir * (r - 10.0), _center + dir * (r + 4.0), col, 1.5)
		# Text label
		var ts := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		var lp := _center + dir * (r + 16.0) - Vector2(ts.x * 0.5, -ts.y * 0.3)
		draw_string(_font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)

# ═════════════════════════════════════════════════════════════════════════════════
# HUD chrome
# ═════════════════════════════════════════════════════════════════════════════════

func _draw_corner_brackets(alpha: float) -> void:
	var col  := Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * alpha * 0.55)
	var blen := 42.0
	var bt   := 1.5
	var m    := 20.0
	var corners := [
		[Vector2(m, m),                                 Vector2( 1,  0), Vector2( 0,  1)],
		[Vector2(_total_size.x - m, m),                 Vector2(-1,  0), Vector2( 0,  1)],
		[Vector2(m, _total_size.y - m),                 Vector2( 1,  0), Vector2( 0, -1)],
		[Vector2(_total_size.x - m, _total_size.y - m), Vector2(-1,  0), Vector2( 0, -1)],
	]
	for c in corners:
		var p:  Vector2 = c[0]
		var dx: Vector2 = c[1]
		var dy: Vector2 = c[2]
		draw_line(p, p + dx * blen, col, bt)
		draw_line(p, p + dy * blen, col, bt)

func _draw_panel_seams(alpha: float) -> void:
	var col_line := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * 0.32)
	for pi in 3:
		var y := float((pi + 1) * 768)
		draw_line(Vector2(0, y), Vector2(_total_size.x, y), col_line, 0.5)
		# Tick marks
		var x := 0.0
		while x <= _total_size.x:
			draw_line(Vector2(x, y - 5), Vector2(x, y + 5), col_line, 1.0)
			x += 64.0
		# Blinking seam label
		if _font:
			var blink: float = absf(sin(App.station_time * 1.4 + float(pi) * 1.1)) * 0.65
			var lc    := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * blink)
			var label := " P%d | P%d " % [pi, pi + 1]
			var lw    := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			draw_string(_font, Vector2((_total_size.x - lw) * 0.5, y + 5.0),
					label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, lc)

func _draw_telemetry(alpha: float) -> void:
	if not _font:
		return
	var fs     := 11
	var line_h := 14.0
	var x      := 10.0
	var col    := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * 0.72)
	var col_hd := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, C_BRIGHT.a * alpha)

	for panel_i in 4:
		if panel_i >= _telem_panels.size():
			continue
		var panel_top := float(panel_i * 768)
		# Vertical sidebar rule
		draw_line(Vector2(x - 3, panel_top + 10), Vector2(x - 3, panel_top + 758),
				Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * 0.22), 0.5)
		var y := panel_top + 20.0
		var lines: Array = _telem_panels[panel_i]
		for li in lines.size():
			if y > panel_top + 758.0:
				break
			var line_text: String = lines[li]
			var c := col_hd if (li == 0 or line_text.begins_with("═")) else col
			draw_string(_font, Vector2(x, y), line_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
			y += line_h
