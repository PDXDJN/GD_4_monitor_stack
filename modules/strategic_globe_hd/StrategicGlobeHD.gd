## StrategicGlobeHD — Full-framebuffer NORAD strategic globe display.
##
## A single orthographic-projected Earth fills all 4 panels (centre at 512,1536,
## radius 480 px).  The continent outlines are ~3× higher resolution than the
## base ColdWarGlobe, with separate polylines for every major landmass:
##   North America, Greenland, South America, Europe, British Isles,
##   Scandinavia, Africa, Madagascar, Arabian Peninsula,
##   Indian Subcontinent, SE Asia / Indochina, China–Korea coast,
##   Japan, Australia, Russia Arctic coast.
##
## Panel 0 : Title bar + strategic status readout
## Panel 1 : Lower-hemisphere globe half + left-side telemetry
## Panel 2 : Upper-hemisphere globe half + right-side telemetry
## Panel 3 : Scrolling contact / threat log

extends Node2D

var module_id         := "strategic_globe_hd"
var module_rng        : RandomNumberGenerator
var module_started_at := 0.0

var _manifest      : Dictionary
var _panel_layout  : PanelLayout
var _virtual_space : VirtualSpace
var _stop_requested := false
var _finished       := false
var _winding_down   := false
var _wd_timer       := 0.0
const WD_DUR        := 2.5

var _panel_rects : Array[Rect2] = []
var _pw          := 0.0
var _ph          := 0.0
var _font        : Font

# ── Globe geometry ─────────────────────────────────────────────────────────────
const GLOBE_CX     := 512.0     # screen x
const GLOBE_CY     := 1536.0    # screen y — vertical midpoint of 3072px fb
const GLOBE_R      := 480.0     # fills 1024px width with 32px margin each side
const TILT         := 0.44      # ~25° viewing tilt (same as ColdWarGlobe)
const LATS         := 12        # latitude bands
const LONS         := 18        # longitude lines
const VERTS        := 80        # points per lat/lon line (smoother than 60)
const GLOBE_ROT_SPD := 0.055    # rad/sec (slightly slower = more stately)

var _globe_rot := 0.0

# ── Missiles ───────────────────────────────────────────────────────────────────
var _missiles     : Array[Dictionary] = []
var _next_missile := 0.0

# ── Telemetry log ──────────────────────────────────────────────────────────────
var _log_lines  : Array[String] = []
var _log_timer  := 0.0
var _cursor_t   := 0.0
const LOG_INT   := 1.6
const MAX_LINES := 14

const _LOG_MSGS := [
	"NORAD TRACK 7721 — UNKNOWN OBJECT",
	"BALLISTIC TRAJECTORY DETECTED — SECTOR 7",
	"RADAR LOCK ACQUIRED — TARGET ALPHA",
	"AWACS SIGNAL RECEIVED — UPLINK OK",
	"STRATEGIC LAUNCH DETECTED — 42N 071W",
	"INTERCEPTOR DELTA FLIGHT SCRAMBLED",
	"UPLINK TO CHEYENNE MTN — ESTABLISHED",
	"MINUTEMAN SILOS — ARMED AND READY",
	"DEW LINE STATION ALPHA — CONTACT LOST",
	"SUBMARINE DETECTION — GRID NOV-7",
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
	"PATTERN MATCH: POSSIBLE ICBM LAUNCH",
	"NORAD CONFIRMED — LAUNCH DETECTED",
	"> DEFCON LEVEL 3 — CONFIRMED",
	"> AUTHENTICATION CODE REQUIRED",
	"> FAIL-SAFE ENGAGED — AWAITING ORDERS",
	"SECTOR 9 SWEEP COMPLETE — CLEAR",
	"SAT-COMM ENCRYPTION HANDSHAKE OK",
	"TRACKING SAT FOXTROT-392-A...",
]

# ── Palette ────────────────────────────────────────────────────────────────────
const C_BRIGHT := Color(0.20, 1.00, 0.60, 1.00)
const C_MID    := Color(0.10, 0.95, 0.52, 0.92)
const C_DIM    := Color(0.00, 0.82, 0.38, 0.72)
const C_BG     := Color(0.00, 0.65, 0.28, 0.35)
const C_SCAN   := Color(0.00, 0.08, 0.03, 0.055)
const C_AMBER  := Color(1.00, 0.72, 0.15, 0.88)
const C_RED    := Color(1.00, 0.18, 0.08, 0.95)
const C_CYAN   := Color(0.30, 0.95, 1.00, 0.90)

# ══════════════════════════════════════════════════════════════════════════════
# HD Coastline data  (~3× resolution of base ColdWarGlobe)
# Coordinate format: [lon_deg, lat_deg]
# Each inner array is one closed or open polyline segment.
# ══════════════════════════════════════════════════════════════════════════════
const _COAST := [

	# ── North America (main exterior) ──────────────────────────────────────
	# Alaska → Pacific coast → Baja → Gulf → Florida → East Coast →
	# Maritimes → Labrador → Arctic → back to Alaska
	[
		[-168,56],[-164,54],[-160,58],[-154,58],[-150,59],[-148,61],
		[-146,62],[-142,60],[-140,58],[-137,58],[-134,56],[-132,54],
		[-130,52],[-128,50],[-126,48],[-124,46],[-124,44],[-124,42],
		[-124,38],[-122,37],[-120,35],[-118,34],[-117,32],[-116,30],
		[-113,27],[-110,24],[-107,20],[-104,19],[-100,18],[-96,18],
		[-92,16],[-90,16],[-88,15],[-86,14],[-84,12],[-82,10],
		[-80,9], [-78,9], [-76,10],[-74,11],[-75,15],[-82,22],
		[-80,24],[-80,26],[-81,29],[-80,31],[-80,33],[-79,34],
		[-76,35],[-75,37],[-74,39],[-72,41],[-70,42],[-70,43],
		[-68,44],[-67,44],[-64,44],[-62,44],[-60,44],[-58,46],
		[-56,47],[-54,47],[-54,49],[-55,51],[-57,52],[-60,54],
		[-64,57],[-66,60],[-66,62],[-65,63],[-68,63],[-74,63],
		[-78,63],[-84,62],[-88,62],[-94,62],[-100,62],[-106,62],
		[-110,64],[-116,66],[-120,68],[-126,68],[-132,68],[-138,69],
		[-140,70],[-146,70],[-152,70],[-156,70],[-162,71],[-165,68],
		[-166,65],[-168,62],[-168,56],
	],

	# ── Alaska Peninsula / Kodiak area (separate lobe) ─────────────────────
	[
		[-156,58],[-154,58],[-152,57],[-154,56],[-156,56],
		[-158,56],[-158,58],[-156,58],
	],

	# ── Greenland ──────────────────────────────────────────────────────────
	[
		[-46,60],[-44,62],[-42,64],[-40,65],[-38,66],[-36,68],
		[-30,70],[-24,72],[-20,74],[-18,76],[-18,78],[-18,80],
		[-20,82],[-26,83],[-34,83],[-42,82],[-46,82],[-50,80],
		[-52,78],[-54,76],[-56,74],[-58,72],[-62,70],[-64,68],
		[-66,66],[-66,64],[-66,62],[-64,60],[-60,62],[-56,62],
		[-52,62],[-50,62],[-48,62],[-46,60],
	],

	# ── South America ──────────────────────────────────────────────────────
	[
		[-80,10],[-78,8], [-76,6], [-74,4], [-72,2], [-70,0],
		[-70,-2],[-68,-4],[-66,-2],[-64,0], [-62,2], [-60,6],
		[-58,8], [-54,6], [-52,4], [-50,2], [-48,0], [-46,-2],
		[-44,-3],[-40,-4],[-38,-6],[-36,-10],[-35,-10],[-35,-12],
		[-36,-14],[-38,-16],[-38,-18],[-40,-20],[-42,-22],[-44,-23],
		[-46,-24],[-48,-26],[-50,-28],[-52,-30],[-52,-32],[-52,-34],
		[-54,-36],[-56,-38],[-58,-40],[-60,-42],[-62,-44],[-64,-46],
		[-65,-48],[-66,-50],[-66,-52],[-66,-54],[-68,-54],[-68,-52],
		[-70,-50],[-72,-48],[-74,-44],[-74,-42],[-74,-38],[-74,-36],
		[-73,-32],[-72,-28],[-72,-24],[-72,-20],[-72,-18],[-74,-14],
		[-76,-10],[-78,-6], [-80,-2],[-80,2], [-80,6], [-80,10],
	],

	# ── Europe — Atlantic and Mediterranean coasts (excl. UK, Scandinavia) ─
	[
		[-9,38], [-8,38], [-8,40], [-6,42], [-4,44], [-2,44],
		[0,44],  [2,44],  [4,44],  [6,44],  [8,44],  [10,44],
		[12,44], [14,44], [14,46], [16,44], [16,42], [18,40],
		[20,38], [22,38], [24,38], [26,38], [26,40], [28,40],
		[28,42], [26,42], [28,44], [30,44], [30,46], [28,46],
		[28,48], [26,50], [24,50], [22,52], [22,54], [22,56],
		[20,56], [18,58], [16,58], [14,56], [14,54], [12,54],
		[10,54], [8,54],  [6,54],  [6,52],  [4,52],  [2,52],
		[0,51],  [-2,50], [-4,50], [-4,48], [-2,46], [-2,44],
		[-4,44], [-6,44], [-8,44], [-8,42], [-8,40], [-8,38],[-9,38],
	],

	# ── British Isles ──────────────────────────────────────────────────────
	[
		[-6,50],[-5,50],[-4,50],[-3,51],[-2,52],[-2,53],[-2,54],
		[-4,54],[-4,56],[-4,58],[-2,58],[0,58],[2,58],[2,56],
		[0,56],[0,54],[-2,54],[-2,52],[-2,50],[-4,50],[-6,50],
	],
	# Ireland
	[
		[-10,52],[-10,54],[-8,54],[-6,54],[-6,56],[-8,56],
		[-10,54],[-10,52],
	],

	# ── Scandinavia (Norway + Sweden) ─────────────────────────────────────
	[
		[4,58],[6,58],[8,58],[10,58],[12,58],[14,58],[16,58],
		[18,60],[20,60],[22,60],[24,60],[24,62],[26,62],[28,62],
		[28,64],[26,66],[24,68],[22,70],[20,70],[18,72],[20,72],
		[22,72],[24,72],[26,70],[28,70],[30,70],[30,68],[28,68],
		[26,66],[24,66],[22,64],[20,64],[18,64],[16,66],[14,66],
		[12,64],[10,62],[8,62],[6,60],[4,58],
	],

	# ── Africa ─────────────────────────────────────────────────────────────
	[
		[-6,36],[-4,36],[0,36],[4,36],[8,38],[10,37],[12,37],
		[14,36],[16,34],[18,32],[20,32],[22,32],[26,32],[28,30],
		[30,30],[32,28],[34,26],[34,24],[36,22],[36,20],[38,18],
		[38,16],[40,14],[42,12],[44,12],[46,11],[48,11],[50,12],
		[52,12],[48,8], [44,4], [42,2], [40,-2],[38,-4],
		[38,-6],[36,-10],[34,-14],[32,-18],[30,-22],[28,-28],
		[26,-30],[24,-32],[22,-34],[20,-34],[18,-34],[16,-32],
		[16,-28],[14,-24],[12,-18],[10,-12],[10,-6],[10,-2],
		[10,2], [8,4],  [6,5],  [4,6],  [2,6],  [0,6],
		[-2,5], [-4,4], [-6,4], [-8,4], [-10,4],[-12,6],
		[-14,10],[-16,12],[-16,14],[-16,18],[-16,20],[-14,24],
		[-12,26],[-10,28],[-8,30],[-6,32],[-6,34],[-6,36],
	],

	# ── Madagascar ─────────────────────────────────────────────────────────
	[
		[44,-12],[46,-14],[48,-16],[48,-18],[50,-20],[50,-22],
		[48,-24],[46,-26],[44,-26],[44,-24],[44,-20],[44,-16],
		[44,-12],
	],

	# ── Arabian Peninsula ──────────────────────────────────────────────────
	[
		[36,30],[38,28],[40,28],[40,24],[42,18],[44,14],[46,14],
		[48,16],[50,18],[52,20],[54,22],[56,22],[58,22],[60,22],
		[58,24],[56,24],[56,26],[54,26],[52,26],[50,28],[48,30],
		[46,30],[44,30],[42,30],[40,30],[38,30],[36,30],
	],

	# ── Indian Subcontinent ────────────────────────────────────────────────
	[
		[60,24],[62,22],[64,22],[66,22],[68,22],[70,22],[72,22],
		[72,20],[74,20],[74,18],[76,16],[76,14],[78,12],[80,10],
		[80,8], [80,10],[78,12],[76,14],[74,16],[74,18],[76,20],
		[76,22],[74,22],[72,22],[70,24],[68,24],[66,24],[64,24],
		[62,24],[60,24],
	],

	# ── Sri Lanka ──────────────────────────────────────────────────────────
	[
		[80,10],[80,8],[82,8],[82,10],[80,10],
	],

	# ── Southeast Asia / Indochina Peninsula ───────────────────────────────
	[
		[98,16],[100,16],[102,14],[104,12],[104,10],[104,8],
		[104,6],[104,4],[104,2],[104,0],[104,-2],[106,-4],
		[108,-6],[110,-8],[112,-8],[114,-6],[116,-4],[118,-4],
		[120,-4],[120,-6],[122,-8],[124,-8],[126,-8],[128,-6],
		[130,-4],[132,-4],[130,-2],[128,0],[126,2],[124,4],
		[122,6],[120,8],[118,10],[116,12],[114,14],[112,16],
		[110,20],[108,20],[106,20],[104,20],[102,20],[100,20],
		[100,18],[100,16],[98,16],
	],

	# ── Sumatra ────────────────────────────────────────────────────────────
	[
		[96,4],[98,2],[100,0],[102,-2],[104,-4],[106,-4],
		[104,-2],[102,0],[100,2],[98,4],[96,4],
	],

	# ── Borneo (Kalimantan) ────────────────────────────────────────────────
	[
		[108,2],[110,2],[112,2],[114,4],[116,4],[118,4],
		[118,2],[116,0],[114,-2],[112,-4],[110,-4],[108,-2],
		[108,0],[108,2],
	],

	# ── China coast + Korea ────────────────────────────────────────────────
	[
		[108,20],[110,20],[112,22],[114,22],[116,24],[118,26],
		[118,24],[120,28],[120,30],[122,30],[122,32],[122,36],
		[120,38],[120,40],[122,40],[124,38],[126,36],[128,36],
		[128,38],[126,40],[124,40],[122,38],[120,36],[120,40],
		[122,42],[124,42],[126,42],[128,40],[130,40],[132,38],
		[132,36],[130,34],[130,32],[128,32],[126,32],[126,30],
		[124,28],[122,26],[120,26],[118,24],[116,22],[114,20],
		[112,20],[110,20],[108,20],
	],

	# ── Japan (Honshu + Kyushu + Shikoku) ─────────────────────────────────
	[
		[130,32],[132,32],[134,34],[134,36],[136,36],[138,36],
		[138,38],[140,38],[140,40],[142,40],[142,42],[140,42],
		[138,40],[138,38],[136,36],[134,36],[132,34],[130,32],
	],

	# ── Japan (Hokkaido) ──────────────────────────────────────────────────
	[
		[140,42],[142,44],[144,44],[144,42],[142,42],[140,42],
	],

	# ── Russia — Arctic coastline (simplified W→E) ─────────────────────────
	[
		[28,70],[36,70],[44,68],[48,68],[52,68],[56,70],
		[60,70],[64,68],[68,68],[72,68],[80,72],[84,72],
		[90,72],[96,70],[100,70],[106,70],[110,68],[116,68],
		[120,66],[124,64],[128,60],[132,56],[134,54],[136,50],
		[138,46],[140,46],[142,48],[142,52],[140,54],[138,56],
		[136,56],[132,58],[128,58],[124,60],[120,62],[116,64],
		[112,64],[108,64],[104,64],[100,64],[96,66],[90,66],
		[84,68],[80,66],[74,66],[68,66],[62,66],[56,66],
		[50,64],[44,66],[38,68],[28,70],
	],

	# ── Australia ──────────────────────────────────────────────────────────
	[
		[114,-22],[114,-26],[114,-28],[114,-30],[116,-32],[118,-34],
		[120,-34],[122,-34],[124,-34],[126,-34],[128,-34],[130,-34],
		[132,-34],[134,-36],[136,-36],[138,-36],[140,-36],[142,-38],
		[144,-38],[146,-38],[148,-38],[150,-36],[152,-34],[152,-30],
		[154,-28],[154,-24],[152,-22],[150,-20],[150,-18],[148,-18],
		[146,-18],[144,-16],[142,-14],[142,-12],[140,-12],[138,-12],
		[136,-12],[134,-14],[132,-14],[130,-16],[128,-14],[126,-14],
		[124,-16],[122,-18],[120,-20],[118,-20],[116,-20],[114,-22],
	],

	# ── Tasmania ──────────────────────────────────────────────────────────
	[
		[144,-40],[146,-40],[148,-42],[146,-44],[144,-44],
		[144,-42],[144,-40],
	],

	# ── New Zealand — North Island ─────────────────────────────────────────
	[
		[174,-36],[176,-36],[178,-36],[178,-38],[176,-40],
		[174,-40],[172,-38],[174,-36],
	],

	# ── New Zealand — South Island ─────────────────────────────────────────
	[
		[166,-44],[168,-44],[170,-44],[172,-44],[172,-46],
		[170,-48],[168,-46],[166,-44],
	],

	# ── Iceland ────────────────────────────────────────────────────────────
	[
		[-24,64],[-22,64],[-18,64],[-14,64],[-14,66],
		[-16,66],[-18,66],[-20,66],[-22,66],[-24,66],[-24,64],
	],

]

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
	_wd_timer         = 0.0

	_panel_rects.clear()
	for i in _panel_layout.panel_count:
		_panel_rects.append(_panel_layout.get_panel_rect(i))
	_pw   = float(_panel_layout.panel_w)
	_ph   = float(_panel_layout.panel_h)
	_font = ThemeDB.fallback_font

	_globe_rot    = module_rng.randf() * TAU
	_missiles.clear()
	_next_missile = App.station_time + module_rng.randf_range(3.0, 6.0)

	_log_lines.clear()
	_log_timer = 0.0
	_cursor_t  = 0.0
	for _i in 6:
		_push_log()

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "rot %.2f" % _globe_rot,
		"intensity": 0.60,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down   = true
	_wd_timer       = 0.0
	Log.debug("StrategicGlobeHD: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_missiles.clear()
	_log_lines.clear()

# ══════════════════════════════════════════════════════════════════════════════
# Process
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wd_timer += delta
		if _wd_timer >= WD_DUR:
			_finished = true
		queue_redraw()
		return

	_globe_rot  += GLOBE_ROT_SPD * delta
	_cursor_t   += delta
	_log_timer  += delta
	if _log_timer >= LOG_INT:
		_log_timer = 0.0
		_push_log()

	var now := App.station_time
	if now >= _next_missile:
		_next_missile = now + module_rng.randf_range(4.0, 9.0)
		_spawn_missile()
	_update_missiles(delta)

	queue_redraw()

# ══════════════════════════════════════════════════════════════════════════════
# Draw
# ══════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var a := 1.0
	if _winding_down:
		a = clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)

	# Draw per-panel backgrounds + chrome first
	for i in _panel_rects.size():
		_draw_panel_bg(_panel_rects[i], a)

	# Globe — drawn once across the full framebuffer
	_draw_grid_sphere(a)
	_draw_continents_hd(a)
	_draw_globe_atmosphere(a)
	_draw_missiles(a)

	# Per-panel overlays on top
	_draw_panel0_overlay(a)
	_draw_panel1_overlay(a)
	_draw_panel2_overlay(a)
	_draw_panel3_overlay(a)

# ── Per-panel background dot grid and scanlines ───────────────────────────────

func _draw_panel_bg(rect: Rect2, a: float) -> void:
	var spacing := 40.0
	var col     := Color(C_BG.r, C_BG.g, C_BG.b, C_BG.a * a)
	for row in int(rect.size.y / spacing) + 1:
		for ci in int(rect.size.x / spacing) + 1:
			var ox := 0.0 if row % 2 == 0 else spacing * 0.5
			draw_circle(Vector2(rect.position.x + ci * spacing + ox,
								rect.position.y + row * spacing), 1.2, col)
	# Scanlines
	var sc := Color(C_SCAN.r, C_SCAN.g, C_SCAN.b, C_SCAN.a * a)
	var y  := rect.position.y
	while y < rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), sc, 0.5)
		y += 5.0

# ── Globe wireframe ───────────────────────────────────────────────────────────

func _draw_grid_sphere(a: float) -> void:
	var cx     := GLOBE_CX
	var cy     := GLOBE_CY
	var r      := GLOBE_R
	var cos_t  := cos(TILT)
	var sin_t  := sin(TILT)

	# Longitude lines
	for i in LONS:
		var lon    := (TAU / LONS) * i
		var prime  := (i % 3 == 0)
		var pts_f  := PackedVector2Array()
		var pts_b  := PackedVector2Array()
		for j in VERTS + 1:
			var lat := PI * float(j) / float(VERTS) - PI * 0.5
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_t - z3 * sin_t
			var z4  := y3 * sin_t + z3 * cos_t
			var pt  := Vector2(cx - x3 * r, cy - y4 * r)
			if z4 >= 0.0:
				if pts_b.size() > 1:
					draw_polyline(pts_b, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.20), 0.4, true)
				pts_b.clear()
				pts_f.push_back(pt)
			else:
				if pts_f.size() > 1:
					var w := 1.0 if prime else 0.5
					draw_polyline(pts_f, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * (0.72 if prime else 0.52)), w, true)
				pts_f.clear()
				pts_b.push_back(pt)
		if pts_f.size() > 1:
			var w := 1.0 if prime else 0.5
			draw_polyline(pts_f, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * (0.72 if prime else 0.52)), w, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.20), 0.4, true)

	# Latitude lines
	for i in LATS + 1:
		var lat   := PI * float(i) / float(LATS) - PI * 0.5
		var is_eq := (i == LATS / 2)
		var is_tropic := (i == LATS / 2 - 2 or i == LATS / 2 + 2)
		var pts   := PackedVector2Array()
		for j in VERTS + 1:
			var lon := TAU * float(j) / float(VERTS)
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_t - z3 * sin_t
			var z4  := y3 * sin_t + z3 * cos_t
			var pt  := Vector2(cx - x3 * r, cy - y4 * r)
			if z4 >= 0.0:
				pts.push_back(pt)
			else:
				if pts.size() > 1:
					var lw  := 2.0 if is_eq else (1.0 if is_tropic else 0.6)
					var la  := (0.95 if is_eq else (0.70 if is_tropic else 0.52)) * a
					var col := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, la) if is_eq \
							 else Color(C_DIM.r, C_DIM.g, C_DIM.b, la)
					draw_polyline(pts, col, lw, true)
				pts.clear()
		if pts.size() > 1:
			var lw  := 2.0 if is_eq else (1.0 if is_tropic else 0.6)
			var la  := (0.95 if is_eq else (0.70 if is_tropic else 0.52)) * a
			var col := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, la) if is_eq \
					 else Color(C_DIM.r, C_DIM.g, C_DIM.b, la)
			draw_polyline(pts, col, lw, true)

	# Globe rim
	draw_arc(Vector2(cx, cy), r, 0.0, TAU, 128, Color(C_MID.r, C_MID.g, C_MID.b, a * 0.85), 1.8, true)

# ── HD continent outlines ─────────────────────────────────────────────────────

func _draw_continents_hd(a: float) -> void:
	var cos_t := cos(TILT)
	var sin_t := sin(TILT)
	var col_f := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.92)
	var col_b := Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.16)

	for segment in _COAST:
		var pts_f := PackedVector2Array()
		var pts_b := PackedVector2Array()
		for pair in segment:
			var lon := deg_to_rad(float(pair[0]))
			var lat := deg_to_rad(float(pair[1]))
			var x3  := cos(lat) * cos(lon - _globe_rot)
			var y3  := sin(lat)
			var z3  := cos(lat) * sin(lon - _globe_rot)
			var y4  := y3 * cos_t - z3 * sin_t
			var z4  := y3 * sin_t + z3 * cos_t
			var pt  := Vector2(GLOBE_CX - x3 * GLOBE_R, GLOBE_CY - y4 * GLOBE_R)
			if z4 >= 0.0:
				if pts_b.size() > 1:
					draw_polyline(pts_b, col_b, 0.6, true)
				pts_b.clear()
				pts_f.push_back(pt)
			else:
				if pts_f.size() > 1:
					draw_polyline(pts_f, col_f, 1.5, true)
				pts_f.clear()
				pts_b.push_back(pt)
		if pts_f.size() > 1:
			draw_polyline(pts_f, col_f, 1.5, true)
		if pts_b.size() > 1:
			draw_polyline(pts_b, col_b, 0.6, true)

# ── Globe atmosphere glow ─────────────────────────────────────────────────────

func _draw_globe_atmosphere(a: float) -> void:
	var layers := [
		[1.006, 3.0, Color(0.15, 0.85, 0.55, 0.14 * a)],
		[1.020, 2.0, Color(0.10, 0.75, 0.65, 0.09 * a)],
		[1.044, 1.4, Color(0.05, 0.60, 0.80, 0.05 * a)],
	]
	for layer in layers:
		draw_arc(Vector2(GLOBE_CX, GLOBE_CY), GLOBE_R * float(layer[0]),
				0.0, TAU, 80, layer[2] as Color, float(layer[1]), true)

# ── Missile arcs ──────────────────────────────────────────────────────────────

func _spawn_missile() -> void:
	if _missiles.size() >= 6:
		return
	var center := Vector2(GLOBE_CX, GLOBE_CY)
	var r      := GLOBE_R * 0.92
	var ang_a  := module_rng.randf() * TAU
	var ang_b  := ang_a + module_rng.randf_range(PI * 0.3, PI * 1.1)
	_missiles.append({
		"start":    center + Vector2(cos(ang_a), sin(ang_a)) * r,
		"end":      center + Vector2(cos(ang_b), sin(ang_b)) * r,
		"progress": 0.0,
		"speed":    module_rng.randf_range(0.06, 0.16),
		"arc_h":    module_rng.randf_range(80.0, 200.0),
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
			draw_polyline(pts, Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, a * 0.78), 1.5, true)
		var warhead_pos := _bezier(start, end_, arc_h, prog)
		draw_circle(warhead_pos, 4.5, Color(C_RED.r, C_RED.g, C_RED.b, a * 0.95))

# ── Panel overlays ────────────────────────────────────────────────────────────

func _draw_panel0_overlay(a: float) -> void:
	if _panel_rects.size() < 1:
		return
	var rect := _panel_rects[0]
	_draw_corner_brackets(rect, a)
	if not _font:
		return
	var t := App.station_time
	# Title
	draw_string(_font, Vector2(rect.position.x + 20.0, rect.position.y + 30.0),
			"STRATEGIC GLOBE DISPLAY v3.0", HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.95))
	# Divider
	draw_line(Vector2(rect.position.x + 14.0, rect.position.y + 42.0),
			  Vector2(rect.end.x - 14.0, rect.position.y + 42.0),
			  Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55), 0.7)
	# Status columns
	var col_l := Color(C_MID.r, C_MID.g, C_MID.b, a * 0.80)
	var col_v := Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.65)
	var fields := [
		["UPTIME",    "%.0fs"   % t],
		["TRACKS",    "%02d"    % (_missiles.size() + 3)],
		["ROT/SEC",   "%+.3f°" % rad_to_deg(GLOBE_ROT_SPD)],
		["DEF-CON",   "3"],
		["AUTH",      "ALPHA-NINER"],
		["UPLINK",    "NOMINAL"],
	]
	var x1 := rect.position.x + 20.0
	var x2 := rect.position.x + 180.0
	var y0 := rect.position.y + 60.0
	var lh := 16.0
	for fi in fields.size():
		var fy := y0 + float(fi) * lh
		if fy > rect.end.y - 10.0:
			break
		draw_string(_font, Vector2(x1, fy), fields[fi][0],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col_l)
		draw_string(_font, Vector2(x2, fy), fields[fi][1],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col_v)
	# Right column — object count
	var blink := absf(sin(t * 1.3)) * 0.7 + 0.3
	draw_string(_font, Vector2(rect.end.x - 200.0, rect.position.y + 60.0),
			"ACTIVE MISSILES: %02d" % _missiles.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, a * blink))
	draw_string(_font, Vector2(rect.end.x - 200.0, rect.position.y + 78.0),
			"LAUNCH SITES:    04",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(C_RED.r, C_RED.g, C_RED.b, a * 0.80))
	draw_string(_font, Vector2(rect.end.x - 200.0, rect.position.y + 96.0),
			"SAT COVERAGE:    96%",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, a * 0.75))
	# Continent resolution badge
	draw_string(_font, Vector2(rect.end.x - 200.0, rect.position.y + 120.0),
			"COAST RES: HIGH",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55))
	draw_string(_font, Vector2(rect.end.x - 200.0, rect.position.y + 134.0),
			"POLYS: %03d" % _COAST.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55))

func _draw_panel1_overlay(a: float) -> void:
	# Panel 1 holds the lower-hemisphere (South pole side) of the globe.
	# Side telemetry: global threat assessment.
	if _panel_rects.size() < 2:
		return
	var rect := _panel_rects[1]
	_draw_corner_brackets(rect, a)
	if not _font:
		return
	_draw_panel_header(rect, "SOUTHERN HEMISPHERE", "THREAT LEVEL: MODERATE", a)
	var t     := App.station_time
	var lines := [
		"SOUTH ATLANTIC:  CLEAR",
		"SOUTHERN OCEAN:  CLEAR",
		"AFRICA SECTOR:   NOMINAL",
		"INDIAN OCEAN:    MONITORING",
		"ANTARCTICA:      RESTRICTED",
		"",
		"DETECTED TRACKS: %02d" % _missiles.size(),
		"LAST UPDATE: %.0fs" % t,
	]
	var col  := Color(C_MID.r, C_MID.g, C_MID.b, a * 0.72)
	var y    := rect.position.y + 54.0
	for line in lines:
		if y > rect.end.y - 10.0:
			break
		draw_string(_font, Vector2(rect.position.x + 20.0, y),
				line, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		y += 14.0

func _draw_panel2_overlay(a: float) -> void:
	# Panel 2 holds the upper-hemisphere (North pole side).
	if _panel_rects.size() < 3:
		return
	var rect := _panel_rects[2]
	_draw_corner_brackets(rect, a)
	if not _font:
		return
	_draw_panel_header(rect, "NORTHERN HEMISPHERE", "DEW LINE: ACTIVE", a)
	var t     := App.station_time
	var lines := [
		"NORTH AMERICA:   MONITORING",
		"NORTH ATLANTIC:  CLEAR",
		"ARCTIC SECTOR:   ALERT",
		"EURASIA:         TRACKING",
		"N PACIFIC:       NOMINAL",
		"",
		"ROT AZM: %.1f°" % fmod(rad_to_deg(_globe_rot), 360.0),
		"TILT:    %.1f°" % rad_to_deg(TILT),
	]
	var col := Color(C_MID.r, C_MID.g, C_MID.b, a * 0.72)
	var y   := rect.position.y + 54.0
	for line in lines:
		if y > rect.end.y - 10.0:
			break
		draw_string(_font, Vector2(rect.position.x + 20.0, y),
				line, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		y += 14.0

func _draw_panel3_overlay(a: float) -> void:
	if _panel_rects.size() < 4:
		return
	var rect   := _panel_rects[3]
	var margin := 22.0
	var line_h := 23.0
	_draw_corner_brackets(rect, a)
	_draw_panel_header(rect, "CONTACT LOG", "ENCRYPTION: AES-256", a)
	var start_y := rect.position.y + 52.0
	for i in _log_lines.size():
		var line : String = _log_lines[i]
		var ly   := start_y + float(i) * line_h
		if ly + line_h > rect.end.y - margin:
			break
		var lc : Color
		if line.begins_with(">") or line.contains("DEFCON") or line.contains("LAUNCH") \
				or line.contains("IMPACT") or line.contains("CONFIRM"):
			lc = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, a * 0.95)
		elif line.contains("NOMINAL") or line.contains(" OK") or line.contains("CLEAR") \
				or line.contains("VERIFIED") or line.contains("ESTABLISHED"):
			lc = Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.85)
		else:
			lc = Color(C_MID.r, C_MID.g, C_MID.b, a * 0.80)
		draw_string(_font, Vector2(rect.position.x + margin, ly), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17, lc)
	# Cursor
	var cur_y := start_y + float(_log_lines.size()) * line_h
	if cur_y < rect.end.y - margin and fmod(_cursor_t, 1.0) < 0.52:
		draw_string(_font, Vector2(rect.position.x + margin, cur_y), "_",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
				Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.90))

# ── Shared helpers ─────────────────────────────────────────────────────────────

func _push_log() -> void:
	_log_lines.append(_LOG_MSGS[module_rng.randi() % _LOG_MSGS.size()])
	while _log_lines.size() > MAX_LINES:
		_log_lines.remove_at(0)

func _draw_panel_header(rect: Rect2, title: String, subtitle: String, a: float) -> void:
	if not _font:
		return
	var div_y := rect.position.y + 40.0
	draw_line(Vector2(rect.position.x + 12.0, div_y),
			  Vector2(rect.end.x - 12.0, div_y),
			  Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.55), 0.7)
	draw_string(_font, Vector2(rect.position.x + 18.0, rect.position.y + 28.0),
			title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
			Color(C_BRIGHT.r, C_BRIGHT.g, C_BRIGHT.b, a * 0.95))
	draw_string(_font, Vector2(rect.position.x + 18.0, rect.position.y + 28.0),
			subtitle, HORIZONTAL_ALIGNMENT_RIGHT,
			int(rect.size.x - 36.0), 12,
			Color(C_DIM.r, C_DIM.g, C_DIM.b, a * 0.68))

func _draw_corner_brackets(rect: Rect2, a: float) -> void:
	var col  := Color(C_MID.r, C_MID.g, C_MID.b, a * 0.50)
	var blen := 36.0
	var m    := 14.0
	var bw   := 1.4
	var corners: Array = [
		[rect.position + Vector2(m, m),                              1.0,  1.0],
		[Vector2(rect.end.x - m, rect.position.y + m),             -1.0,  1.0],
		[Vector2(rect.position.x + m, rect.end.y - m),              1.0, -1.0],
		[rect.end - Vector2(m, m),                                  -1.0, -1.0],
	]
	for corner in corners:
		var pos : Vector2 = corner[0]
		var dx  : float   = corner[1]
		var dy  : float   = corner[2]
		draw_line(pos, pos + Vector2(dx * blen, 0.0), col, bw)
		draw_line(pos, pos + Vector2(0.0, dy * blen), col, bw)
