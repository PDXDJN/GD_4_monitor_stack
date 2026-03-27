## OrbitalTraffic — ambient vertical orbital lane spanning all 4 panels.
##
## Ships, drones, cargo pods, and debris drift from Monitor 1 (Inbound) down
## through Monitors 2–3 to Monitor 4 (Outbound), using VirtualSpace so objects
## disappear cleanly in the bezel gaps and re-appear at the next panel.
##
## Three parallax layers give depth:
##   Layer 0 (background) — slow satellites/debris, dim and small
##   Layer 1 (mid)        — ships at cruise speed
##   Layer 2 (foreground) — fast cargo pods / drones, slight x-bobbing
##
## Occasional events reward attention:
##   • Signal ping ripple
##   • Near-collision dodge
##   • Personality text flash

extends Node2D

var module_id          := "orbital_traffic"
var module_rng:          RandomNumberGenerator
var module_started_at  := 0.0

var _manifest:     Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished       := false
var _winding_down   := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 2.5

var _total_size: Vector2i
var _virtual_h:  float
var _font:        Font

# ── Object pool ────────────────────────────────────────────────────────────────
# Each object: { type, layer, vy, x, speed, phase, bob_amp, bob_freq,
#                angle, rot_speed, col, size, label, near_offset }
var _objects: Array = []
const MAX_OBJECTS := 38

# ── Signal pings ───────────────────────────────────────────────────────────────
# { x, real_y, timer, dur, col }
var _pings: Array = []

# ── Near-collision state ───────────────────────────────────────────────────────
# Applied to a pair of objects for a short window
var _nc_timer  := 0.0
var _nc_active := false

# ── Random-event scheduler ─────────────────────────────────────────────────────
var _event_timer    := 0.0
var _next_event_sec := 0.0

# ── Personality flash ──────────────────────────────────────────────────────────
var _flash_text  := ""
var _flash_timer := 0.0
var _flash_panel := 0
const _FLASH_DUR := 4.5

# index cycles through the list; shuffled once at start
var _personality_order: Array = []
var _personality_pos   := 0

const _PERSONALITY := [
	"Tracking system nominal (definition of nominal disputed)",
	"Object 4421: probably harmless",
	"Collision avoidance: optimistic",
	"I am not paid enough for orbital logistics",
	"TRANSPONDER: OFFLINE  (this is fine)",
	"No unauthorized vessels detected (search radius: 12 km)",
	"Traffic density: concerning",
	"Filing incident report... eventually",
	"Avoidance window: narrowing",
	"Signal integrity: theoretical",
	"Re-routing: not really",
	"Object count: several",
]

# ── Palette ────────────────────────────────────────────────────────────────────
const C_CYAN  := Color(0.20, 0.90, 1.00, 1.0)
const C_AMBER := Color(1.00, 0.72, 0.15, 1.0)
const C_WHITE := Color(0.88, 0.92, 0.95, 1.0)
const C_DIM   := Color(0.30, 0.52, 0.62, 1.0)
const C_HUD   := Color(0.15, 0.75, 0.88, 1.0)
const C_ALERT := Color(1.00, 0.32, 0.18, 1.0)

# ── Object types ───────────────────────────────────────────────────────────────
enum ObjType { DEBRIS = 0, SATELLITE = 1, SHIP = 2, DRONE = 3, CARGO_POD = 4 }

# Parallax layer params [speed_min, speed_max, alpha, size_scale, bob_amp]
const _LAYERS := [
	[30.0,  65.0,  0.28, 0.72, 3.0],   # 0 = background
	[85.0, 140.0,  0.62, 1.00, 7.0],   # 1 = mid
	[170.0, 225.0, 0.90, 1.20, 14.0],  # 2 = foreground
]

# Zone identity per panel
const _ZONE_LABELS := [
	["INBOUND ZONE",       "TRANSPONDER: OFFLINE",  "VECTOR UNVERIFIED"],
	["MID-ORBIT",          "DENSITY: HIGH",         "TRACKING NOMINAL"],
	["STATION PROXIMITY",  "REDUCE SPEED",          "AVOIDANCE ACTIVE"],
	["OUTBOUND DRIFT",     "SIGNAL DEGRADING",      "TRACKING ABANDONED"],
]
const _ZONE_COLS := [C_CYAN, C_WHITE, C_AMBER, C_DIM]

# Lane x-band: objects scattered in a 700px wide band centred at 512
const _LANE_CX   := 512.0
const _LANE_HALF := 350.0

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

	_total_size = _panel_layout.get_total_real_size()
	_virtual_h  = _virtual_space.virtual_height()
	_font       = ThemeDB.fallback_font

	_objects.clear()
	_pings.clear()
	_nc_active = false

	# Pre-populate objects spread across virtual space
	for i in MAX_OBJECTS:
		_spawn_object(module_rng.randf() * _virtual_h)

	# Shuffle personality list
	_personality_order = range(_PERSONALITY.size())
	for i in range(_personality_order.size() - 1, 0, -1):
		var j := module_rng.randi_range(0, i)
		var tmp: int = _personality_order[i]
		_personality_order[i] = _personality_order[j]
		_personality_order[j] = tmp
	_personality_pos = 0

	# First event in 20–50 seconds
	_event_timer    = 0.0
	_next_event_sec = module_rng.randf_range(20.0, 50.0)
	_flash_timer    = 0.0
	_flash_text     = ""

func module_status() -> Dictionary:
	return {"ok": true, "notes": "%d objects" % _objects.size(), "intensity": 0.35}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("OrbitalTraffic: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_objects.clear()
	_pings.clear()

# ══════════════════════════════════════════════════════════════════════════════
# Update
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true
		queue_redraw()
		return

	_update_objects(delta)
	_update_pings(delta)
	_update_events(delta)
	_update_flash(delta)
	queue_redraw()

func _update_objects(delta: float) -> void:
	var t := App.station_time
	for obj in _objects:
		obj.vy    += float(obj.speed) * delta
		obj.angle += float(obj.rot_speed) * delta
		# Near-miss offset decays back to zero
		if absf(float(obj.near_offset)) > 0.5:
			obj.near_offset = lerpf(float(obj.near_offset), 0.0, delta * 1.5)
		# x bobbing — foreground layer and drones
		var bx := 0.0
		if int(obj.layer) >= 1:
			bx = sin(t * float(obj.bob_freq) + float(obj.phase)) * float(obj.bob_amp)
		obj.draw_x = float(obj.x) + bx + float(obj.near_offset)
		# Wrap when past virtual bottom
		if float(obj.vy) > _virtual_h + 50.0:
			_respawn_object(obj)

func _update_pings(delta: float) -> void:
	for i in range(_pings.size() - 1, -1, -1):
		_pings[i].timer += delta
		if float(_pings[i].timer) >= float(_pings[i].dur):
			_pings.remove_at(i)

func _update_events(delta: float) -> void:
	_event_timer += delta
	if _event_timer < _next_event_sec:
		return
	_event_timer = 0.0
	_next_event_sec = module_rng.randf_range(30.0, 90.0)

	var roll := module_rng.randf()
	if roll < 0.40:
		_fire_signal_ping()
	elif roll < 0.70:
		_fire_near_collision()
	else:
		_fire_personality_flash()

func _update_flash(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta

# ══════════════════════════════════════════════════════════════════════════════
# Object spawning
# ══════════════════════════════════════════════════════════════════════════════

func _spawn_object(start_vy: float) -> void:
	var layer := module_rng.randi_range(0, 2)
	var lp: Array = _LAYERS[layer]
	# Weight type toward debris/ships for authenticity
	var type_roll := module_rng.randf()
	var obj_type: int
	if type_roll < 0.30:
		obj_type = ObjType.DEBRIS
	elif type_roll < 0.50:
		obj_type = ObjType.SATELLITE
	elif type_roll < 0.70:
		obj_type = ObjType.SHIP
	elif type_roll < 0.85:
		obj_type = ObjType.DRONE
	else:
		obj_type = ObjType.CARGO_POD

	# Colour by layer/type
	var col: Color
	match obj_type:
		ObjType.DEBRIS:    col = C_DIM
		ObjType.SATELLITE: col = C_WHITE
		ObjType.SHIP:      col = C_CYAN
		ObjType.DRONE:     col = C_AMBER
		ObjType.CARGO_POD: col = C_WHITE
	col = Color(col.r, col.g, col.b, col.a * float(lp[2]))

	# x scattered across the lane band
	var x := _LANE_CX + module_rng.randf_range(-_LANE_HALF, _LANE_HALF)
	var obj := {
		type       = obj_type,
		layer      = layer,
		vy         = start_vy,
		x          = x,
		draw_x     = x,
		speed      = module_rng.randf_range(float(lp[0]), float(lp[1])),
		phase      = module_rng.randf_range(0.0, TAU),
		bob_amp    = float(lp[4]) * module_rng.randf_range(0.6, 1.4),
		bob_freq   = module_rng.randf_range(0.4, 1.2),
		angle      = module_rng.randf_range(0.0, TAU),
		rot_speed  = module_rng.randf_range(-0.4, 0.4) if obj_type == ObjType.SATELLITE else 0.0,
		col        = col,
		size       = _base_size(obj_type) * float(lp[3]),
		near_offset = 0.0,
	}
	_objects.append(obj)

func _respawn_object(obj: Dictionary) -> void:
	# Reset to just above the virtual top with fresh parameters
	var layer: int = int(obj.layer)
	var lp: Array  = _LAYERS[layer]
	obj.vy         = module_rng.randf_range(-150.0, -10.0)
	obj.x          = _LANE_CX + module_rng.randf_range(-_LANE_HALF, _LANE_HALF)
	obj.draw_x     = float(obj.x)
	obj.speed      = module_rng.randf_range(float(lp[0]), float(lp[1]))
	obj.phase      = module_rng.randf_range(0.0, TAU)
	obj.angle      = module_rng.randf_range(0.0, TAU)
	obj.near_offset = 0.0

func _base_size(obj_type: int) -> float:
	match obj_type:
		ObjType.DEBRIS:    return 4.0
		ObjType.SATELLITE: return 10.0
		ObjType.SHIP:      return 14.0
		ObjType.DRONE:     return 6.0
		ObjType.CARGO_POD: return 11.0
	return 8.0

# ══════════════════════════════════════════════════════════════════════════════
# Events
# ══════════════════════════════════════════════════════════════════════════════

func _fire_signal_ping() -> void:
	# Place ping at a random real position visible in one of the 4 panels
	var panel := module_rng.randi_range(0, 3)
	var rect  := _panel_layout.get_panel_rect(panel)
	_pings.append({
		x     = rect.position.x + module_rng.randf_range(80.0, rect.size.x - 80.0),
		real_y = rect.position.y + module_rng.randf_range(80.0, rect.size.y - 80.0),
		timer = 0.0,
		dur   = 2.8,
		col   = C_CYAN,
	})
	Log.debug("OrbitalTraffic: signal ping", {})

func _fire_near_collision() -> void:
	if _objects.size() < 4:
		return
	# Find two mid-layer objects close in vy
	for _try in 8:
		var ai := module_rng.randi_range(0, _objects.size() - 1)
		var bi := module_rng.randi_range(0, _objects.size() - 1)
		if ai == bi:
			continue
		var a: Dictionary = _objects[ai]
		var b: Dictionary = _objects[bi]
		if absf(float(a.vy) - float(b.vy)) < 400.0:
			a.near_offset = module_rng.randf_range(25.0, 55.0) * (1.0 if module_rng.randf() > 0.5 else -1.0)
			b.near_offset = -float(a.near_offset)
			Log.debug("OrbitalTraffic: near-collision dodge", {})
			break

func _fire_personality_flash() -> void:
	if _flash_timer > 0.0:
		return
	var idx: int    = _personality_order[_personality_pos % _personality_order.size()]
	_personality_pos += 1
	_flash_text  = _PERSONALITY[idx]
	_flash_timer = _FLASH_DUR
	_flash_panel = module_rng.randi_range(0, 3)

# ══════════════════════════════════════════════════════════════════════════════
# Draw
# ══════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha := 1.0
	if _winding_down:
		alpha = clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)

	_draw_background(alpha)
	_draw_lane_guides(alpha)
	# Draw layers back to front
	_draw_objects_layer(0, alpha)
	_draw_objects_layer(1, alpha)
	_draw_pings(alpha)
	_draw_objects_layer(2, alpha)
	_draw_zone_labels(alpha)
	_draw_panel_seams(alpha)
	_draw_hud_chrome(alpha)
	_draw_flash_text(alpha)

# ── Background dot grid ───────────────────────────────────────────────────────

func _draw_background(alpha: float) -> void:
	var col := Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.10 * alpha)
	var spacing := 56.0
	var cols_n   := int(_total_size.x / spacing) + 2
	var rows_n   := int(_total_size.y / spacing) + 2
	for ri in rows_n:
		for ci in cols_n:
			var offset := spacing * 0.5 if ri % 2 == 1 else 0.0
			draw_circle(Vector2(ci * spacing + offset, ri * spacing), 1.0, col)

# ── Lane guide lines ──────────────────────────────────────────────────────────

func _draw_lane_guides(alpha: float) -> void:
	var col  := Color(C_HUD.r, C_HUD.g, C_HUD.b, 0.18 * alpha)
	var col2 := Color(C_HUD.r, C_HUD.g, C_HUD.b, 0.06 * alpha)
	var h    := float(_total_size.y)
	# Outer lane edges
	draw_line(Vector2(_LANE_CX - _LANE_HALF, 0.0),
			  Vector2(_LANE_CX - _LANE_HALF, h), col, 0.6, true)
	draw_line(Vector2(_LANE_CX + _LANE_HALF, 0.0),
			  Vector2(_LANE_CX + _LANE_HALF, h), col, 0.6, true)
	# Centre dashed line
	var seg := 20.0
	var gap := 14.0
	var y := 0.0
	while y < h:
		var ye := minf(y + seg, h)
		draw_line(Vector2(_LANE_CX, y), Vector2(_LANE_CX, ye), col2, 0.5)
		y += seg + gap

# ── Object rendering ──────────────────────────────────────────────────────────

func _draw_objects_layer(layer: int, alpha: float) -> void:
	for obj in _objects:
		if int(obj.layer) != layer:
			continue
		var result := _virtual_space.virtual_to_real(float(obj.vy))
		if not bool(result.visible):
			continue
		var px := float(obj.draw_x)
		var py := float(result.real_y)
		var col := (obj.col as Color).darkened(0.0)
		col = Color(col.r, col.g, col.b, col.a * alpha)
		_draw_object_shape(px, py, int(obj.type), float(obj.size),
				float(obj.angle), col)

func _draw_object_shape(px: float, py: float, obj_type: int,
		sz: float, angle: float, col: Color) -> void:
	match obj_type:
		ObjType.DEBRIS:
			_draw_debris(px, py, sz, col)
		ObjType.SATELLITE:
			_draw_satellite(px, py, sz, angle, col)
		ObjType.SHIP:
			_draw_ship(px, py, sz, col)
		ObjType.DRONE:
			_draw_drone(px, py, sz, col)
		ObjType.CARGO_POD:
			_draw_cargo_pod(px, py, sz, col)

func _draw_debris(px: float, py: float, sz: float, col: Color) -> void:
	# Tiny irregular polygon — diamond-ish
	draw_line(Vector2(px - sz, py), Vector2(px, py - sz * 0.6), col, 0.8)
	draw_line(Vector2(px, py - sz * 0.6), Vector2(px + sz * 0.8, py), col, 0.8)
	draw_line(Vector2(px + sz * 0.8, py), Vector2(px, py + sz * 0.7), col, 0.8)
	draw_line(Vector2(px, py + sz * 0.7), Vector2(px - sz, py), col, 0.8)

func _draw_satellite(px: float, py: float, sz: float, angle: float, col: Color) -> void:
	# Tumbling: body + solar panels rotated by angle
	var ca := cos(angle) * sz
	var sa := sin(angle) * sz
	# Body (cross)
	draw_line(Vector2(px - ca, py - sa), Vector2(px + ca, py + sa), col, 1.5)
	draw_line(Vector2(px - sa, py + ca), Vector2(px + sa, py - ca), col, 1.5)
	# Solar panels (perpendicular to body, longer)
	var pnx := cos(angle + PI * 0.5) * sz * 2.0
	var pny := sin(angle + PI * 0.5) * sz * 2.0
	draw_line(Vector2(px - pnx, py - pny), Vector2(px + pnx, py + pny),
			Color(col.r, col.g, col.b, col.a * 0.55), 1.0)
	draw_circle(Vector2(px, py), sz * 0.28, col)

func _draw_ship(px: float, py: float, sz: float, col: Color) -> void:
	# Arrow/capsule shape pointing downward (direction of travel)
	var hw := sz * 0.45
	var ht := sz
	# Outline: narrow top, wide body, tapered bottom
	var pts := PackedVector2Array([
		Vector2(px,        py - ht),          # nose
		Vector2(px + hw,   py - ht * 0.2),    # shoulder R
		Vector2(px + hw,   py + ht * 0.5),    # mid R
		Vector2(px + hw * 0.4, py + ht),      # tail R
		Vector2(px - hw * 0.4, py + ht),      # tail L
		Vector2(px - hw,   py + ht * 0.5),    # mid L
		Vector2(px - hw,   py - ht * 0.2),    # shoulder L
	])
	draw_polyline(pts, col, 1.2, true)
	draw_line(pts[6], pts[0], col, 1.2)  # close top
	# Engine glow at tail
	var glow_col := Color(col.r, col.g, col.b, col.a * 0.45)
	draw_circle(Vector2(px, py + ht), sz * 0.18, glow_col)

func _draw_drone(px: float, py: float, sz: float, col: Color) -> void:
	# Small circle + cross
	draw_circle(Vector2(px, py), sz, Color(col.r, col.g, col.b, col.a * 0.15))
	draw_arc(Vector2(px, py), sz, 0.0, TAU, 12, col, 0.8, true)
	draw_line(Vector2(px - sz * 1.5, py), Vector2(px + sz * 1.5, py), col, 0.7)
	draw_line(Vector2(px, py - sz * 1.5), Vector2(px, py + sz * 1.5), col, 0.7)

func _draw_cargo_pod(px: float, py: float, sz: float, col: Color) -> void:
	# Wide rectangle outline (cargo box, wider than tall)
	var hw := sz * 0.75
	var hh := sz * 0.5
	draw_rect(Rect2(px - hw, py - hh, hw * 2.0, hh * 2.0),
			Color(col.r, col.g, col.b, col.a * 0.12), true)
	draw_rect(Rect2(px - hw, py - hh, hw * 2.0, hh * 2.0), col, false, 1.2)
	# Centre divider lines
	draw_line(Vector2(px, py - hh), Vector2(px, py + hh),
			Color(col.r, col.g, col.b, col.a * 0.35), 0.6)
	draw_line(Vector2(px - hw, py), Vector2(px + hw, py),
			Color(col.r, col.g, col.b, col.a * 0.35), 0.6)

# ── Signal ping ripples ───────────────────────────────────────────────────────

func _draw_pings(alpha: float) -> void:
	for ping in _pings:
		var t_n   := float(ping.timer) / float(ping.dur)
		var r_max := 120.0
		var r     := t_n * r_max
		var a_in  := sin(t_n * PI)   # fade in/out arc
		var col   := ping.col as Color
		# 3 concentric expanding rings with decreasing alpha
		for ri in 3:
			var rr := r * (1.0 - float(ri) * 0.18)
			var ra := a_in * alpha * (1.0 - float(ri) * 0.30) * 0.80
			draw_arc(Vector2(float(ping.x), float(ping.real_y)), rr, 0.0, TAU, 32,
					Color(col.r, col.g, col.b, ra), 1.0, true)
		# Central dot blink
		draw_circle(Vector2(float(ping.x), float(ping.real_y)), 3.0,
				Color(col.r, col.g, col.b, a_in * alpha * 0.9))

# ── Zone labels ───────────────────────────────────────────────────────────────

func _draw_zone_labels(alpha: float) -> void:
	if not _font:
		return
	var t := App.station_time
	for pi in 4:
		var panel_top := float(pi * 768)
		var zone_col  := _ZONE_COLS[pi] as Color
		var lines:Array = _ZONE_LABELS[pi]
		# Right-side column at x=940
		var x  := 940.0
		var y  := panel_top + 30.0
		var fs := 10
		var lh := 13.0
		# Zone header
		var hcol := Color(zone_col.r, zone_col.g, zone_col.b,
				zone_col.a * alpha * 0.85)
		draw_string(_font, Vector2(x, y), lines[0],
				HORIZONTAL_ALIGNMENT_RIGHT, -1, fs + 1, hcol)
		y += lh + 2.0
		# Sub-lines with gentle blink
		var dcol := Color(zone_col.r, zone_col.g, zone_col.b,
				zone_col.a * alpha * 0.55)
		for li in range(1, lines.size()):
			var blink_phase := t * 0.8 + float(pi * 3 + li) * 1.1
			var blink := 0.6 + 0.4 * absf(sin(blink_phase))
			var lc := Color(dcol.r, dcol.g, dcol.b, dcol.a * blink)
			draw_string(_font, Vector2(x, y), lines[li],
					HORIZONTAL_ALIGNMENT_RIGHT, -1, fs, lc)
			y += lh
		# Object count for mid-orbit panel
		if pi == 1:
			var mid_count := 0
			for obj in _objects:
				var r := _virtual_space.virtual_to_real(float(obj.vy))
				if bool(r.visible) and int(r.panel) == 1:
					mid_count += 1
			var cnt_col := Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, alpha * 0.70)
			draw_string(_font, Vector2(x, y + 8.0), "CONTACTS: %02d" % mid_count,
					HORIZONTAL_ALIGNMENT_RIGHT, -1, fs, cnt_col)

# ── Panel seam markers ────────────────────────────────────────────────────────

func _draw_panel_seams(alpha: float) -> void:
	var t   := App.station_time
	var col := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * 0.28)
	for pi in 3:
		var y := float((pi + 1) * 768)
		draw_line(Vector2(0, y), Vector2(float(_total_size.x), y), col, 0.5)
		var x := 0.0
		while x <= float(_total_size.x):
			draw_line(Vector2(x, y - 4.0), Vector2(x, y + 4.0), col, 0.8)
			x += 80.0
		# Zone transition label
		if _font:
			var blink := absf(sin(t * 1.1 + float(pi) * 0.9)) * 0.55
			var lc    := Color(C_HUD.r, C_HUD.g, C_HUD.b, C_HUD.a * alpha * blink)
			var label := " Z%d → Z%d " % [pi, pi + 1]
			var lw    := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			draw_string(_font, Vector2((float(_total_size.x) - lw) * 0.5, y + 4.0),
					label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, lc)

# ── HUD chrome ────────────────────────────────────────────────────────────────

func _draw_hud_chrome(alpha: float) -> void:
	# Corner brackets per-panel
	var col  := Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * alpha * 0.42)
	var blen := 28.0
	var bt   := 1.2
	for pi in 4:
		var pt := Vector2(0.0, float(pi * 768))
		var pb := Vector2(0.0, float((pi + 1) * 768))
		var pw := float(_total_size.x)
		# Top-left + top-right of each panel
		_draw_bracket(pt + Vector2(14, 14),  Vector2( 1,  0), Vector2( 0,  1), blen, bt, col)
		_draw_bracket(pt + Vector2(pw - 14, 14), Vector2(-1, 0), Vector2( 0,  1), blen, bt, col)
		# Bottom-left + bottom-right
		_draw_bracket(pb + Vector2(14, -14),    Vector2( 1,  0), Vector2( 0, -1), blen, bt, col)
		_draw_bracket(pb + Vector2(pw - 14, -14), Vector2(-1, 0), Vector2( 0, -1), blen, bt, col)

func _draw_bracket(p: Vector2, dx: Vector2, dy: Vector2,
		blen: float, bt: float, col: Color) -> void:
	draw_line(p, p + dx * blen, col, bt)
	draw_line(p, p + dy * blen, col, bt)

# ── Personality text flash ────────────────────────────────────────────────────

func _draw_flash_text(alpha: float) -> void:
	if _flash_timer <= 0.0 or not _font:
		return
	var t_n  := _flash_timer / _FLASH_DUR
	var fade := sin(t_n * PI)
	var panel_top := float(_flash_panel * 768)
	var col := Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, alpha * fade * 0.88)
	# Box background
	var fs   := 11
	var tw   := _font.get_string_size(_flash_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0
	var th   := 20.0
	var tx   := (_LANE_CX - tw * 0.5)
	var ty   := panel_top + 768.0 * 0.5 - th * 0.5
	draw_rect(Rect2(tx - 2.0, ty - 2.0, tw + 4.0, th + 4.0),
			Color(0.0, 0.0, 0.0, fade * alpha * 0.75), true)
	draw_rect(Rect2(tx - 2.0, ty - 2.0, tw + 4.0, th + 4.0),
			Color(col.r, col.g, col.b, col.a * 0.55), false, 0.8)
	draw_string(_font, Vector2(tx + 8.0, ty + th * 0.75), _flash_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
