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
const C_BRIGHT := Color(0.20, 1.00, 0.55, 1.00)   # bright phosphor green
const C_MID    := Color(0.10, 0.85, 0.45, 0.80)   # mid green
const C_DIM    := Color(0.00, 0.55, 0.22, 0.40)   # dim green
const C_SCAN   := Color(0.00, 0.08, 0.03, 0.055)  # scanline overlay tint
const C_BG     := Color(0.00, 0.30, 0.12, 0.12)   # background dot grid
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
var _globe_rot     := 0.0
const GLOBE_ROT_SPD := 0.07   # rad/sec

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

	# Panel 0 — large rotating globe sprite (z_index=-1 → behind _draw() overlays)
	_free_sprite(_globe_sprite)
	_globe_rot = module_rng.randf() * TAU
	if _globe_tex and _panel_rects.size() > 0:
		var center0 := _panel_rects[0].get_center()
		var gs      := minf(_pw, _ph) * 0.88
		var tex_sz  := float(maxi(_globe_tex.get_width(), _globe_tex.get_height()))
		_globe_sprite = _make_globe_sprite(_globe_tex, center0, gs / tex_sz,
				Color(C_MID.r, C_MID.g, C_MID.b, 0.90))
		_globe_sprite.rotation = _globe_rot
		add_child(_globe_sprite)

	# Panel 2 — small globe sprite
	_free_sprite(_globe_sprite2)
	if _globe_tex and _panel_rects.size() > 2:
		var center2 := _panel_rects[2].get_center()
		var sg      := 160.0
		var tex_sz  := float(maxi(_globe_tex.get_width(), _globe_tex.get_height()))
		_globe_sprite2 = _make_globe_sprite(_globe_tex, center2, sg / tex_sz,
				Color(C_MID.r, C_MID.g, C_MID.b, 0.65))
		_globe_sprite2.rotation = _globe_rot * 0.25
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
		if is_instance_valid(_globe_sprite2): _globe_sprite2.modulate.a = a
		if _wd_timer >= WD_DUR:
			_finished = true
		queue_redraw()
		return

	var now := App.station_time

	# Globe rotation
	_globe_rot += GLOBE_ROT_SPD * delta
	if is_instance_valid(_globe_sprite):
		_globe_sprite.rotation = _globe_rot
	if is_instance_valid(_globe_sprite2):
		_globe_sprite2.rotation = _globe_rot * 0.25

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

	# When SVG not loaded, draw procedural wireframe sphere
	if not _globe_tex:
		_draw_fallback_sphere(center, gs * 0.5, a)

	# Globe outline ring (on top of sprite via z-order)
	draw_arc(center, gs * 0.495, 0.0, TAU, 80,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55), 1.2, true)

	# Targeting crosshairs
	var cr  := gs * 0.5 + 20.0
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
	var col := Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.50)
	draw_arc(center, r, 0.0, TAU, 64, col, 1.0, true)
	for i in 7:
		var ly := (float(i) - 3.0) / 3.0 * r
		var lr := sqrt(maxf(0.0, r * r - ly * ly))
		if lr > 4.0:
			draw_arc(center + Vector2(0.0, ly), lr, 0.0, TAU, 32, col, 0.5, true)
	for i in 10:
		var lng := (TAU / 10.0) * i + _globe_rot
		var pts := PackedVector2Array()
		for j in 33:
			var lat := (PI / 32.0) * j - PI * 0.5
			pts.push_back(center + Vector2(cos(lat) * cos(lng), sin(lat)) * r)
		draw_polyline(pts, col, 0.5, true)

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
	_free_sprite(_globe_sprite2)
	_globe_sprite2 = null
	_missiles.clear()
	_contacts.clear()
	_sats.clear()
	_lines.clear()
	_globe_tex    = null
	_globe_shader = null
