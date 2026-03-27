## ColdWarGlobe — 4-panel NORAD Cold War command console.
## Panel 0 : Strategic Globe Display   — rotating SVG wireframe Earth + missile arcs
## Panel 1 : Radar Sweep Display       — sweep arm + contact blips
## Panel 2 : Satellite Orbit Tracker   — SVG globe + orbital ellipses + satellites
## Panel 3 : Command Terminal          — scrolling military alerts + blinking cursor
##
## SVG asset: res://assets/images/Wireframe-Earth-Globe.svg
##   The SVG has black strokes on transparent background.
##   A Sprite2D child with an inline shader converts black→phosphor-green.
##   The sprite uses z_index=-1 so _draw() overlays (crosshairs, labels, etc.)
##   appear on top of the globe texture.
extends Node2D

var module_id         := "cold_war_globe"
var module_rng        : RandomNumberGenerator
var module_started_at := 0.0

# ── Module context ──────────────────────────────────────────────────────────────
var _manifest      : Dictionary
var _panel_layout  : PanelLayout
var _virtual_space : VirtualSpace
var _stop_requested := false
var _finished       := false

# ── Palette — phosphor green + cold war amber/red ───────────────────────────────
const C_BRIGHT := Color(0.20, 1.00, 0.60, 1.00)   # bright phosphor green
const C_MID    := Color(0.10, 0.95, 0.52, 0.92)   # mid green
const C_DIM    := Color(0.00, 0.82, 0.38, 0.72)   # dim green
const C_SCAN   := Color(0.00, 0.08, 0.03, 0.055)  # scanline overlay tint
const C_BG     := Color(0.00, 0.65, 0.28, 0.35)   # background dot grid
const C_AMBER  := Color(1.00, 0.72, 0.15, 0.88)   # missile arc / alert amber
const C_RED    := Color(1.00, 0.18, 0.08, 0.95)   # hostile / warhead red
const C_CYAN   := Color(0.30, 0.95, 1.00, 0.90)   # satellite / friendly contact

# ── Inline shader: black SVG strokes → phosphor green ───────────────────────────
# Converts black-on-transparent SVG to tinted glow lines.
const GLOBE_SHADER_SRC := """
shader_type canvas_item;
uniform vec4 tint_color : source_color = vec4(0.1, 0.85, 0.45, 1.0);
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
	// "blackness" = how dark the pixel is (1.0 for pure black, 0.0 for white)
    float blackness = 1.0 - max(max(tex.r, tex.g), tex.b);
    // Reconstruct alpha: use the tex alpha AND the darkness so only strokes show
    COLOR = vec4(tint_color.rgb, tex.a * blackness * tint_color.a);
}
"""

# Sphere-mapping shader: inverse-orthographic-projects each screen pixel onto a
# virtual sphere, recovers geographic (lon, lat), and samples the equirectangular
# SVG map there — producing a true 3D rotating globe appearance.
const GLOBE_MAP_SHADER_SRC := """
shader_type canvas_item;
uniform vec4  tint_color : source_color = vec4(0.1, 0.90, 0.48, 0.88);
uniform float rot_y = 0.0;   // Y-axis rotation matching _globe_rot
uniform float tilt  = 0.44;  // viewing tilt in radians, matching TILT constant
void fragment() {
    vec2  uv = UV * 2.0 - 1.0;
    float r2 = dot(uv, uv);
    if (r2 > 1.0) { COLOR = vec4(0.0); return; }
    float z4    = sqrt(1.0 - r2);
    float cos_t = cos(tilt);
    float sin_t = sin(tilt);
    float x3 =  uv.x;
    float y3 =  uv.y * cos_t + z4 * sin_t;
    float z3 = -uv.y * sin_t + z4 * cos_t;
    float lon   = atan(z3, x3) + rot_y;
    float lat   = asin(clamp(y3, -1.0, 1.0));
    float tex_u = fract(lon / (2.0 * 3.14159265) + 0.5);
    float tex_v = lat / 3.14159265 + 0.5;
    vec4  tex      = texture(TEXTURE, vec2(tex_u, tex_v));
    float blackness = 1.0 - max(max(tex.r, tex.g), tex.b);
    float edge      = smoothstep(1.0, 0.88, sqrt(r2));
    COLOR = vec4(tint_color.rgb, tex.a * blackness * tint_color.a * edge);
}
"""

# Simplified continental coastlines [lon_deg, lat_deg].
# Projected with the same tilted orthographic math as the wireframe grid so they
# rotate in perfect sync with it.  Each inner array is one continuous polyline.
const _COAST := [
	# ── North America ──────────────────────────────────────────────────────────
	[[-165,62],[-133,55],[-124,47],[-122,37],[-117,32],[-110,23],
	 [-90,16],[-83,10],[-80,25],[-76,35],[-70,42],[-66,44],[-60,44],
	 [-54,47],[-54,52],[-60,56],[-65,62],[-78,63],[-95,63],
	 [-120,70],[-140,70],[-157,71],[-165,65],[-165,62]],
	# ── South America ──────────────────────────────────────────────────────────
	[[-77,8],[-62,11],[-52,4],[-35,-4],[-35,-10],[-40,-20],[-44,-23],
	 [-49,-28],[-52,-33],[-56,-38],[-62,-45],[-65,-55],[-68,-54],
	 [-74,-45],[-72,-35],[-72,-25],[-77,-14],[-80,-4],[-80,1],[-77,8]],
	# ── Europe ─────────────────────────────────────────────────────────────────
	[[-9,38],[-6,36],[3,41],[5,43],[9,44],[14,44],[14,46],[18,40],
	 [22,37],[26,38],[28,42],[24,56],[22,60],[25,60],[30,65],[25,71],
	 [18,71],[8,70],[5,62],[8,63],[5,57],[10,58],[14,56],[18,58],
	 [24,56],[20,55],[15,54],[8,54],[2,51],[0,51],[-5,50],[-5,48],
	 [-2,44],[-9,44],[-9,38]],
	# ── Africa ─────────────────────────────────────────────────────────────────
	[[-6,36],[11,37],[15,33],[25,30],[33,31],[36,25],[38,18],[42,12],
	 [44,11],[51,11],[44,2],[41,-2],[40,-10],[36,-18],[31,-25],[27,-32],
	 [20,-34],[18,-34],[14,-30],[12,-18],[9,-6],[8,4],[2,5],[-4,5],
	 [-16,14],[-17,21],[-13,27],[-8,34],[-6,36]],
	# ── Eurasia ────────────────────────────────────────────────────────────────
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
	# ── Australia ──────────────────────────────────────────────────────────────
	[[114,-22],[115,-35],[118,-38],[124,-34],[132,-32],[138,-35],
	 [143,-38],[150,-38],[154,-28],[152,-22],[148,-20],[142,-10],
	 [136,-12],[130,-16],[126,-14],[123,-18],[114,-22]],
]

# ── Cached layout ───────────────────────────────────────────────────────────────
var _panel_rects : Array[Rect2] = []
var _pw          := 0.0
var _ph          := 0.0

# ── Wind-down ───────────────────────────────────────────────────────────────────
var _winding_down := false
var _wd_timer     := 0.0
const WD_DUR      := 2.5

# ══════════════════════════════════════════════════════════════════════════════════
# Panel 0 — Strategic Globe Display
# ══════════════════════════════════════════════════════════════════════════════════
var _globe_tex     : Texture2D = null
var _globe_shader  : Shader    = null
var _globe_sprite  : Sprite2D  = null   # large rotating globe
var _map_sprite    : Sprite2D  = null   # sphere-mapped SVG earth texture
var _map_shader    : Shader    = null
var _globe_rot      := 0.0
const GLOBE_ROT_SPD  := 0.07  # rad/sec

var _missiles     : Array[Dictionary] = []
var _next_missile := 0.0

# ══════════════════════════════════════════════════════════════════════════════════
# Panel 1 — Radar Sweep Display
# ══════════════════════════════════════════════════════════════════════════════════
const RADAR_R  := 295.0

var _radar_ang    := 0.0
const RADAR_SPD   := 1.15   # rad/sec

var _contacts     : Array[Dictionary] = []
var _next_contact := 0.0

# ══════════════════════════════════════════════════════════════════════════════════
# Panel 2 — Satellite Orbit Tracker
# ══════════════════════════════════════════════════════════════════════════════════
const ORBIT_SPD   := 0.40
var _orbit_t      := 0.0
var _globe_sprite2 : Sprite2D = null   # small globe for panel 2
var _sats          : Array[Dictionary] = []

# ══════════════════════════════════════════════════════════════════════════════════
# Panel 3 — Command Terminal
# ══════════════════════════════════════════════════════════════════════════════════
var _lines      : Array[String] = []
var _line_timer := 0.0
var _cursor_t   := 0.0
const LINE_INT  := 1.8
const MAX_LINES := 16

const TERMINAL_MESSAGES := [
	"NORAD TRACK 7721 — UNKNOWN OBJECT",
	"BALLISTIC TRAJECTORY DETECTED — SECTOR 7",
	"RADAR LOCK ACQUIRED — TARGET ALPHA",
	"AWACS SIGNAL RECEIVED — UPLINK OK",
	"STRATEGIC LAUNCH DETECTED — GRID 42N 071W",
	"INTERCEPTOR DELTA FLIGHT SCRAMBLED",
	"UPLINK TO CHEYENNE MTN — ESTABLISHED",
	"MINUTEMAN SILOS — ARMED AND READY",
	"DEW LINE STATION ALPHA — CONTACT LOST",
	"SUBMARINE DETECTION — GRID NOVEMBER-7",
	"AUTH CODE ALPHA-BRAVO-NINER VERIFIED",
	"STRATEGIC AIR COMMAND — AIRBORNE",
	"THERMAL SIGNATURE — SIBERIAN SECTOR 3",
	"TARGET ACQUISITION SEQUENCE INITIATED",
	"FAIL-SAFE PROTOCOL ENGAGED",
	"EMP BURST DETECTED — GRID CHARLIE-4",
	"IMPACT ESTIMATE T-MINUS 18:34",
	"COMM RELAY SIERRA NOMINAL",
	"EARLY WARNING RADAR — CONTACT",
	"ICBM TRACK CONFIRMED — UPDATING...",
	"SAT-COMM ENCRYPTION HANDSHAKE OK",
	"SECTOR 9 SWEEP COMPLETE — CLEAR",
	"TRACKING SAT FOXTROT-392-A...",
	"PATTERN MATCH: POSSIBLE ICBM LAUNCH",
	"NORAD CONFIRMED — LAUNCH DETECTED",
	"> DEFCON LEVEL 3 — CONFIRMED",
	"> AUTHENTICATION CODE REQUIRED",
	"> LAUNCH KEY INSERTED — CONFIRM? Y/N",
	"> FAIL-SAFE ENGAGED — AWAITING ORDERS",
]

# ─────────────────────────────────────────────────────────────────────────────
#  Module interface
# ─────────────────────────────────────────────────────────────────────────────

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
	_wd_timer         = 0.0

	# Cache panel geometry
	_panel_rects.clear()
	for i in _panel_layout.panel_count:
		_panel_rects.append(_panel_layout.get_panel_rect(i))
	_pw = float(_panel_layout.panel_w)
	_ph = float(_panel_layout.panel_h)

	# Load wireframe SVG
	var svg := "res://assets/images/Wireframe-Earth-Globe.svg"
	_globe_tex = null
	if ResourceLoader.exists(svg):
		var res := load(svg)
		if res is Texture2D:
			_globe_tex = res as Texture2D
		else:
			Log.warn("ColdWarGlobe: resource loaded but is not Texture2D: " + svg)
	else:
		Log.warn("ColdWarGlobe: SVG not found — using procedural globe: " + svg)

	# Build inline shader once
	if _globe_tex and _globe_shader == null:
		_globe_shader = Shader.new()
		_globe_shader.code = GLOBE_SHADER_SRC

	# Panel 0 — procedural 3D wireframe + continent overlay
	_free_sprite(_globe_sprite)
	_free_sprite(_map_sprite)
	_map_sprite = null
	_globe_rot  = module_rng.randf() * TAU

	# Panel 2 — small globe sprite
	_free_sprite(_globe_sprite2)
	if _globe_tex and _panel_rects.size() > 2:
		var center2 := _panel_rects[2].get_center()
		var sg      := 160.0
		var tex_sz  := float(maxi(_globe_tex.get_width(), _globe_tex.get_height()))
		_globe_sprite2 = _make_globe_sprite(_globe_tex, center2, sg / tex_sz,
				Color(C_MID.r, C_MID.g, C_MID.b, 0.65))
		add_child(_globe_sprite2)

	# Panel 0 — missiles
	_missiles.clear()
	_next_missile = App.station_time + module_rng.randf_range(2.0, 5.0)

	# Panel 1 — radar
	_radar_ang    = module_rng.randf() * TAU
	_contacts.clear()
	_next_contact = App.station_time + module_rng.randf_range(1.0, 3.5)

	# Panel 2 — satellites
	_orbit_t = module_rng.randf() * TAU
	_init_satellites()

	# Panel 3 — terminal
	_lines.clear()
	_line_timer = 0.0
	_cursor_t   = 0.0
	for _i in 5:
		_push_line()

func _make_globe_sprite(tex: Texture2D, pos: Vector2, scale_f: float, tint: Color) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture     = tex
	sp.position    = pos
	sp.scale       = Vector2.ONE * scale_f
	sp.z_index     = -1    # draws behind parent _draw() content
	sp.z_as_relative = true
	var mat := ShaderMaterial.new()
	mat.shader = _globe_shader
	mat.set_shader_parameter("tint_color", tint)
	sp.material = mat
	return sp

func _free_sprite(sp: Sprite2D) -> void:
	if is_instance_valid(sp):
		sp.queue_free()

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wd_timer += delta
		var a := clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)
		if is_instance_valid(_globe_sprite):  _globe_sprite.modulate.a  = a
		if is_instance_valid(_map_sprite):    _map_sprite.modulate.a    = a
		if is_instance_valid(_globe_sprite2): _globe_sprite2.modulate.a = a
		if _wd_timer >= WD_DUR:
			_finished = true
		queue_redraw()
		return

	var now := App.station_time

	# Globe rotation — drives the procedural wireframe and continent overlay
	_globe_rot += GLOBE_ROT_SPD * delta

	# Missiles
	if now >= _next_missile:
		_next_missile = now + module_rng.randf_range(3.5, 7.5)
		_spawn_missile()
	_update_missiles(delta)

	# Radar
	_radar_ang += RADAR_SPD * delta
	if now >= _next_contact:
		_next_contact = now + module_rng.randf_range(2.0, 5.5)
		_spawn_contact()
	_update_contacts(delta)

	# Satellites
	_orbit_t += ORBIT_SPD * delta

	# Terminal
	_cursor_t   += delta
	_line_timer += delta
	if _line_timer >= LINE_INT:
		_line_timer = 0.0
		_push_line()

	queue_redraw()

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var a := 1.0
	if _winding_down:
		a = clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)

	for i in _panel_rects.size():
		match i:
			0: _draw_panel0_globe(a)
			1: _draw_panel1_radar(a)
			2: _draw_panel2_orbits(a)
			3: _draw_panel3_terminal(a)

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 0 — Strategic Globe Display
# ─────────────────────────────────────────────────────────────────────────────

func _draw_panel0_globe(a: float) -> void:
	var rect   := _panel_rects[0]
	var center := rect.get_center()
	_draw_bg(rect, a)
	_draw_scanlines(rect, a)
	_draw_panel_header(rect, "STRATEGIC GLOBE DISPLAY", "TRACKING ACTIVE", a)
	_draw_corner_brackets(rect, a)

	var gs := minf(_pw, _ph) * 0.88

	# Procedural 3D globe — includes its own boundary circle
	_draw_fallback_sphere(center, gs * 0.5, a)
	# Continent outlines — same projection, same rotation, drawn on top
	_draw_continents(center, gs * 0.5, a)

	# Targeting crosshairs (contained within the globe boundary)
	var cr  := gs * 0.5 - 8.0
	var gap := 22.0
	var xc  := Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.45)
	draw_line(center + Vector2(-cr, 0.0),  center + Vector2(-gap, 0.0), xc, 0.7)
	draw_line(center + Vector2( gap, 0.0), center + Vector2( cr,  0.0), xc, 0.7)
	draw_line(center + Vector2(0.0, -cr),  center + Vector2(0.0, -gap), xc, 0.7)
	draw_line(center + Vector2(0.0,  gap), center + Vector2(0.0,  cr),  xc, 0.7)

	_draw_missiles(a)

func _spawn_missile() -> void:
	if _missiles.size() >= 5 or _panel_rects.is_empty():
		return
	var center := _panel_rects[0].get_center()
	var r      := minf(_pw, _ph) * 0.88 * 0.46
	var ang_a  := module_rng.randf() * TAU
	var ang_b  := ang_a + module_rng.randf_range(PI * 0.35, PI * 1.15)
	_missiles.append({
		"start":    center + Vector2(cos(ang_a), sin(ang_a)) * r,
		"end":      center + Vector2(cos(ang_b), sin(ang_b)) * r,
		"progress": 0.0,
		"speed":    module_rng.randf_range(0.07, 0.18),
		"arc_h":    module_rng.randf_range(90.0, 220.0),
	})

func _update_missiles(delta: float) -> void:
	for i in range(_missiles.size() - 1, -1, -1):
		_missiles[i]["progress"] = float(_missiles[i]["progress"]) + float(_missiles[i]["speed"]) * delta
		if float(_missiles[i]["progress"]) >= 1.0:
			_missiles.remove_at(i)

func _bezier(s: Vector2, e: Vector2, h: float, t: float) -> Vector2:
	var mid := (s + e) * 0.5 + Vector2(0.0, -h)
	return (1.0 - t) * (1.0 - t) * s + 2.0 * (1.0 - t) * t * mid + t * t * e

func _draw_missiles(a: float) -> void:
	for m in _missiles:
		var prog  : float   = m["progress"]
		var start : Vector2 = m["start"]
		var end_  : Vector2 = m["end"]
		var arc_h : float   = m["arc_h"]
		var pts   := PackedVector2Array()
		for s in 33:
			pts.push_back(_bezier(start, end_, arc_h, float(s) / 32.0 * prog))
		if pts.size() > 1:
			draw_polyline(pts, Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, a * 0.75), 1.5, true)
		draw_circle(_bezier(start, end_, arc_h, prog), 4.5,
				Color(C_RED.r, C_RED.g, C_RED.b, a * 0.95))

func _draw_fallback_sphere(center: Vector2, r: float, a: float) -> void:
	# Tilted orthographic projection — tilt gives latitude lines visible curvature.
	# TILT rotates the view ~25° above the equatorial plane (Earth-like presentation).
	const LATS  := 8    # latitude bands
	const LONS  := 12   # longitude lines
	const VERTS := 60   # points per line
	const TILT  := 0.44 # radians (~25°)

	var cos_tilt := cos(TILT)
	var sin_tilt := sin(TILT)

	# Longitude lines — front half brighter, back half dimmer
	for i in LONS:
		var lon   := (TAU / LONS) * i
		var pts_f := PackedVector2Array()
		var pts_b := PackedVector2Array()
		for j in VERTS + 1:
			var lat := PI * float(j) / float(VERTS) - PI * 0.5
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_tilt - z3 * sin_tilt
			var z4  := y3 * sin_tilt + z3 * cos_tilt
			var pt  := center + Vector2(-x3, -y4) * r
			if z4 >= 0.0:
				if pts_b.size() > 1:
					draw_polyline(pts_b, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.22), 0.5, true)
				pts_b.clear()
				pts_f.push_back(pt)
			else:
				if pts_f.size() > 1:
					draw_polyline(pts_f, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.72), 1.0, true)
				pts_f.clear()
				pts_b.push_back(pt)
		if pts_f.size() > 1:
			draw_polyline(pts_f, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.72), 1.0, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.22), 0.5, true)

	# Latitude lines — front hemisphere only (appear as natural arcs)
	for i in LATS + 1:
		var lat   := PI * float(i) / float(LATS) - PI * 0.5
		var is_eq := (i == LATS / 2)
		var pts   := PackedVector2Array()
		for j in VERTS + 1:
			var lon := TAU * float(j) / float(VERTS)
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_tilt - z3 * sin_tilt
			var z4  := y3 * sin_tilt + z3 * cos_tilt
			var pt  := center + Vector2(-x3, -y4) * r
			if z4 >= 0.0:
				pts.push_back(pt)
			else:
				if pts.size() > 1:
					var lw  := 1.8 if is_eq else 0.7
					var col := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.95) if is_eq \
							 else Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.62)
					draw_polyline(pts, col, lw, true)
				pts.clear()
		if pts.size() > 1:
			var lw  := 1.8 if is_eq else 0.7
			var col := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.95) if is_eq \
					 else Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.62)
			draw_polyline(pts, col, lw, true)

	# Globe boundary circle
	draw_arc(center, r, 0.0, TAU, 64, Color(C_MID.r, C_MID.g, C_MID.b, a * 0.82), 1.6, true)

func _draw_continents(center: Vector2, r: float, a: float) -> void:
	var cos_tilt := cos(0.44)
	var sin_tilt := sin(0.44)
	var col_f    := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.90)
	var col_b    := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.18)
	for coast in _COAST:
		var pts_f := PackedVector2Array()
		var pts_b := PackedVector2Array()
		for pair in coast:
			var lon := deg_to_rad(float(pair[0]))
			var lat := deg_to_rad(float(pair[1]))
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_tilt - z3 * sin_tilt
			var z4  := y3 * sin_tilt + z3 * cos_tilt
			var pt  := center + Vector2(-x3, -y4) * r
			if z4 >= 0.0:
				if pts_b.size() > 1:
					draw_polyline(pts_b, col_b, 0.6, true)
				pts_b.clear()
				pts_f.push_back(pt)
			else:
				if pts_f.size() > 1:
					draw_polyline(pts_f, col_f, 1.4, true)
				pts_f.clear()
				pts_b.push_back(pt)
		if pts_f.size() > 1:
			draw_polyline(pts_f, col_f, 1.4, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, col_b, 0.6, true)

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 1 — Radar Sweep Display
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_contact() -> void:
	if _contacts.size() >= 12:
		return
	_contacts.append({
		"angle":    module_rng.randf() * TAU,
		"radius":   module_rng.randf_range(RADAR_R * 0.12, RADAR_R * 0.88),
		"life":     module_rng.randf_range(7.0, 16.0),
		"age":      0.0,
		"lit_time": -99.0,
		"hostile":  module_rng.randf() < 0.28,
	})

func _update_contacts(delta: float) -> void:
	var sweep := fmod(_radar_ang, TAU)
	for i in range(_contacts.size() - 1, -1, -1):
		var c := _contacts[i]
		c["age"] = float(c["age"]) + delta
		if fmod(sweep - fmod(float(c["angle"]), TAU) + TAU * 2.0, TAU) < 0.11:
			c["lit_time"] = App.station_time
		if float(c["age"]) >= float(c["life"]):
			_contacts.remove_at(i)

func _draw_panel1_radar(a: float) -> void:
	var rect   := _panel_rects[1]
	var center := rect.get_center()
	_draw_bg(rect, a)
	_draw_scanlines(rect, a)
	_draw_panel_header(rect, "RADAR SWEEP DISPLAY", "AIR DEFENCE SECTOR 7", a)
	_draw_corner_brackets(rect, a)

	# Range rings
	for i in 5:
		var r   := RADAR_R * float(i + 1) / 5.0
		var col := Color(C_DIM.r, C_DIM.g, C_DIM.b, a * (0.60 if i == 4 else 0.30))
		draw_arc(center, r, 0.0, TAU, 64, col, 1.2 if i == 4 else 0.7, true)

	# Cardinal axes
	var ax := Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.26)
	draw_line(center + Vector2(-RADAR_R, 0.0), center + Vector2(RADAR_R, 0.0), ax, 0.6)
	draw_line(center + Vector2(0.0, -RADAR_R), center + Vector2(0.0, RADAR_R), ax, 0.6)

	# Sweep glow wedge
	draw_arc(center, RADAR_R * 0.97, _radar_ang - TAU * 0.20, _radar_ang, 40,
			Color(C_MID.r, C_MID.g, C_MID.b, a * 0.12), RADAR_R * 0.97, true)

	# Sweep arm
	draw_line(center,
			center + Vector2(cos(_radar_ang), sin(_radar_ang)) * RADAR_R,
			Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.90), 2.0, true)

	# Contact blips
	for c in _contacts:
		var lit_age : float = App.station_time - float(c["lit_time"])
		var ba      := clampf(1.0 - lit_age / 5.5, 0.0, 1.0) * a
		if ba < 0.02:
			continue
		var cp  := center + Vector2(cos(float(c["angle"])), sin(float(c["angle"]))) * float(c["radius"])
		var cc  := C_RED if c["hostile"] else C_CYAN
		var dc  := Color(cc.r, cc.g, cc.b, ba)
		draw_circle(cp, 4.0, dc)
		draw_arc(cp, 11.0, 0.0, TAU, 12, Color(dc.r, dc.g, dc.b, dc.a * 0.40), 1.0, true)

	# Tick marks
	for i in 36:
		var ang := (TAU / 36.0) * i
		var tl  := 8.0 if i % 9 == 0 else 4.0
		draw_line(center + Vector2(cos(ang), sin(ang)) * (RADAR_R - tl),
				  center + Vector2(cos(ang), sin(ang)) * RADAR_R,
				  Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.52), 0.8)

	draw_string(ThemeDB.fallback_font,
			center + Vector2(-7.0, -RADAR_R - 10.0), "N",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55))

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 2 — Satellite Orbit Tracker
# ─────────────────────────────────────────────────────────────────────────────

func _init_satellites() -> void:
	_sats.clear()
	var defs := [
		{"a": 210.0, "b":  75.0, "incl":  0.0,       "spd": 0.65, "lbl": "FOXTROT-392"},
		{"a": 270.0, "b": 105.0, "incl":  PI * 0.25, "spd": 0.48, "lbl": "SAT-COMM-7"},
		{"a": 175.0, "b":  65.0, "incl": -PI * 0.40, "spd": 0.85, "lbl": "DELTA-11"},
		{"a": 325.0, "b": 140.0, "incl":  PI * 0.60, "spd": 0.38, "lbl": "ALPHA-RELAY"},
		{"a": 145.0, "b":  52.0, "incl":  PI * 0.15, "spd": 1.10, "lbl": "SPY-9"},
	]
	for d in defs:
		_sats.append({
			"a":     d["a"],
			"b":     d["b"],
			"incl":  d["incl"],
			"spd":   d["spd"],
			"lbl":   d["lbl"],
			"phase": module_rng.randf() * TAU,
		})

func _draw_panel2_orbits(a: float) -> void:
	var rect   := _panel_rects[2]
	var center := rect.get_center()
	_draw_bg(rect, a)
	_draw_scanlines(rect, a)
	_draw_panel_header(rect, "SATELLITE ORBIT TRACKER", "ACTIVE ASSETS: 5", a)
	_draw_corner_brackets(rect, a)

	# Fallback globe if SVG not loaded
	if not _globe_tex:
		draw_arc(center, 80.0, 0.0, TAU, 48,
				Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.60), 1.5, true)

	# Orbital paths + satellites
	var font := ThemeDB.fallback_font
	for sat in _sats:
		var sa   : float  = sat["a"]
		var sb   : float  = sat["b"]
		var incl : float  = sat["incl"]
		var spd  : float  = sat["spd"]
		var ph   : float  = sat["phase"]
		var lbl  : String = sat["lbl"]

		# Orbit ellipse
		var opts := PackedVector2Array()
		for j in 65:
			var t   := (TAU / 64.0) * j
			var ox  := sa * cos(t)
			var oy  := sb * sin(t)
			opts.push_back(center + Vector2(ox * cos(incl) - oy * sin(incl),
											ox * sin(incl) + oy * cos(incl)))
		draw_polyline(opts, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.45), 0.8, true)

		# Satellite
		var st  := _orbit_t * spd + ph
		var sx  := sa * cos(st)
		var sy  := sb * sin(st)
		var sp  := center + Vector2(sx * cos(incl) - sy * sin(incl),
									sx * sin(incl) + sy * cos(incl))
		var sc  := Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, a * 0.90)
		draw_circle(sp, 4.0, sc)
		draw_arc(sp, 8.5, 0.0, TAU, 6, Color(sc.r, sc.g, sc.b, a * 0.35), 1.0, true)
		draw_string(font, sp + Vector2(10.0, -6.0), lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(C_MID.r, C_MID.g, C_MID.b, a * 0.70))

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 3 — Command Terminal
# ─────────────────────────────────────────────────────────────────────────────

func _push_line() -> void:
	_lines.append(TERMINAL_MESSAGES[module_rng.randi() % TERMINAL_MESSAGES.size()])
	while _lines.size() > MAX_LINES:
		_lines.remove_at(0)

func _draw_panel3_terminal(a: float) -> void:
	var rect   := _panel_rects[3]
	var font   := ThemeDB.fallback_font
	var margin := 24.0
	var line_h := 23.0

	_draw_bg(rect, a)
	_draw_scanlines(rect, a)
	_draw_panel_header(rect, "COMMAND TERMINAL", "ENCRYPTION: AES-256", a)
	_draw_corner_brackets(rect, a)

	var start_y := rect.position.y + 52.0

	for i in _lines.size():
		var line : String = _lines[i]
		var ly   := start_y + float(i) * line_h
		if ly + line_h > rect.end.y - margin:
			break

		var lc : Color
		if line.begins_with(">") or line.contains("DEFCON") \
				or line.contains("IMPACT") or line.contains("LAUNCH") \
				or line.contains("AUTHENTICATION") or line.contains("CONFIRM"):
			lc = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, a * 0.95)
		elif line.contains("NOMINAL") or line.contains(" OK") \
				or line.contains("ESTABLISHED") or line.contains("CLEAR") \
				or line.contains("VERIFIED"):
			lc = Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.85)
		else:
			lc = Color(C_MID.r, C_MID.g, C_MID.b, a * 0.80)

		draw_string(font, Vector2(margin, ly), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17, lc)

	# Blinking cursor
	var cur_y := start_y + float(_lines.size()) * line_h
	if cur_y < rect.end.y - margin and fmod(_cursor_t, 1.0) < 0.52:
		draw_string(font, Vector2(margin, cur_y), "_",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
				Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.90))

# ─────────────────────────────────────────────────────────────────────────────
#  Shared drawing helpers
# ─────────────────────────────────────────────────────────────────────────────

func _draw_bg(rect: Rect2, a: float) -> void:
	var spacing := 40.0
	var col     := Color(C_BG.r, C_BG.g, C_BG.b, C_BG.a * a)
	for row in int(rect.size.y / spacing) + 1:
		for ci in int(rect.size.x / spacing) + 1:
			var ox := 0.0 if row % 2 == 0 else spacing * 0.5
			draw_circle(Vector2(rect.position.x + ci * spacing + ox,
								rect.position.y + row * spacing), 1.2, col)

func _draw_scanlines(rect: Rect2, a: float) -> void:
	if a < 0.04:
		return
	var col := Color(C_SCAN.r, C_SCAN.g, C_SCAN.b, C_SCAN.a * a)
	var y   := rect.position.y
	while y < rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), col, 0.5)
		y += 5.0

func _draw_panel_header(rect: Rect2, title: String, subtitle: String, a: float) -> void:
	var font  := ThemeDB.fallback_font
	var div_y := rect.position.y + 40.0
	draw_line(Vector2(rect.position.x + 12.0, div_y),
			  Vector2(rect.end.x - 12.0, div_y),
			  Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.60), 0.8)
	draw_string(font, Vector2(rect.position.x + 18.0, rect.position.y + 28.0),
			title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.95))
	draw_string(font, Vector2(rect.position.x + 18.0, rect.position.y + 28.0),
			subtitle, HORIZONTAL_ALIGNMENT_RIGHT,
			int(rect.size.x - 36.0), 13,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.70))

func _draw_corner_brackets(rect: Rect2, a: float) -> void:
	var col  := Color(C_MID.r, C_MID.g, C_MID.b, a * 0.52)
	var blen := 34.0
	var m    := 14.0
	var bw   := 1.4
	var tl   := rect.position + Vector2(m, m)
	var tr   := Vector2(rect.end.x - m, rect.position.y + m)
	var bl   := Vector2(rect.position.x + m, rect.end.y - m)
	var br   := rect.end - Vector2(m, m)
	for corner: Array in [[tl, 1.0, 1.0], [tr, -1.0, 1.0], [bl, 1.0, -1.0], [br, -1.0, -1.0]]:
		var pos : Vector2 = corner[0]
		var dx  : float   = corner[1]
		var dy  : float   = corner[2]
		draw_line(pos, pos + Vector2(dx * blen, 0.0), col, bw)
		draw_line(pos, pos + Vector2(0.0, dy * blen), col, bw)

# ─────────────────────────────────────────────────────────────────────────────
#  Module lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "missiles:%d contacts:%d sats:%d" % [_missiles.size(), _contacts.size(), _sats.size()],
		"intensity": 0.65,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down   = true
	_wd_timer       = 0.0
	Log.debug("ColdWarGlobe: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_free_sprite(_globe_sprite)
	_globe_sprite = null
	_free_sprite(_map_sprite)
	_map_sprite   = null
	_map_shader   = null
	_free_sprite(_globe_sprite2)
	_globe_sprite2 = null
	_missiles.clear()
	_contacts.clear()
	_sats.clear()
	_lines.clear()
	_globe_tex    = null
	_globe_shader = null
