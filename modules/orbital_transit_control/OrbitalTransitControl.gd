## OrbitalTransitControl — Berlin transit rendered as a docking-schedule system.
## Fetches live BVG departures every 30 seconds. Fails gracefully (frozen data).
##
## Panel 0: Strategic header + radar sweep
## Panel 1: Jannowitzbrücke — S-Bahn + U-Bahn
## Panel 2: Heinrich-Heine-Straße — U-Bahn + Bus
## Panel 3: Telemetry / Expanded departure / Flavor (rotating every ~20s)
extends Node2D

var module_id          := "orbital_transit_control"
var module_rng:          RandomNumberGenerator
var module_started_at  := 0.0

# ─── Module lifecycle ──────────────────────────────────────────────────────────
var _manifest:      Dictionary
var _panel_layout:  PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished       := false
var _winding_down   := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 2.0

# ─── API ──────────────────────────────────────────────────────────────────────
const STOP_JANNOWITZ := "900100004"   # S+U Jannowitzbrücke
const STOP_HEINRICH  := "900100008"   # U Heinrich-Heine-Str.

var _deps_j: Array = []   # Jannowitzbrücke filtered departures
var _deps_h: Array = []   # Heinrich-Heine-Straße filtered departures

var _http_j_pending := false
var _http_h_pending := false

var _last_fetch_at   := -999.0
const FETCH_INTERVAL := 30.0

var _api_status      := "CONNECTING"
var _last_sync_str   := "--:--:--"
var _data_age_sec    := 0.0
var _last_good_fetch := -1.0

# ─── Animation ────────────────────────────────────────────────────────────────
var _radar_angle   := 0.0
const RADAR_SPEED  := TAU / 12.0   # 12-second sweep cycle

var _blink         := 0.0          # general phase for pulsing elements

var _row_slide     := 0.0          # 1.0→0.0; drives row slide-in on data refresh
const ROW_SLIDE_DUR := 0.35

var _bottom_mode   := 0            # 0=telemetry  1=expanded  2=flavor
var _bottom_timer  := 0.0
const BOTTOM_DUR   := 20.0

var _flavor_idx    := 0
const _FLAVORS := [
	["COMMUTER ADVISORY:", "YOU ARE CUTTING THIS CLOSE", "", "SYSTEM NOTE:", "PROCRASTINATION DETECTED"],
	["ORBITAL NOTE:", "BOARDING WINDOW IS CLOSING", "", "ADVISORY:", "DELTA-V INSUFFICIENT"],
	["DEPARTURE IMMINENT:", "YOUR HESITATION IS NOTED", "", "SYSTEM:", "PLEASE ACCELERATE"],
	["STATUS REPORT:", "DOCKING WINDOW: NARROW", "", "REASON:", "PASSENGER VECTOR DRIFT"],
]

# ─── Palette ──────────────────────────────────────────────────────────────────
const C_CYAN   := Color(0.00, 0.85, 0.90, 0.90)
const C_GREEN  := Color(0.10, 0.78, 0.42, 0.88)
const C_DIM    := Color(0.00, 0.42, 0.50, 0.52)
const C_AMBER  := Color(0.90, 0.55, 0.00, 0.92)
const C_RED    := Color(0.90, 0.18, 0.08, 0.88)
const C_HEADER := Color(0.18, 1.00, 0.68, 0.95)
const C_BODY   := Color(0.05, 0.72, 0.52, 0.82)
const C_GRID   := Color(0.00, 0.35, 0.42, 0.28)

const PW := 1024
const PH := 768

var _font: Font

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

	_font         = ThemeDB.fallback_font
	_radar_angle  = 0.0
	_blink        = 0.0
	_row_slide    = 0.0
	_bottom_mode  = 0
	_bottom_timer = 0.0
	_flavor_idx   = module_rng.randi() % _FLAVORS.size()

	_deps_j          = []
	_deps_h          = []
	_last_fetch_at   = -999.0
	_last_good_fetch = -1.0
	_data_age_sec    = 0.0
	_api_status      = "CONNECTING"
	_last_sync_str   = "--:--:--"

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	_radar_angle = fmod(_radar_angle + RADAR_SPEED * delta, TAU)
	_blink       = fmod(_blink + delta * 2.5, TAU)

	_bottom_timer += delta
	if _bottom_timer >= BOTTOM_DUR:
		_bottom_timer = 0.0
		_bottom_mode  = (_bottom_mode + 1) % 3
		if _bottom_mode == 2:
			_flavor_idx = (_flavor_idx + 1) % _FLAVORS.size()

	if _row_slide > 0.0:
		_row_slide = maxf(0.0, _row_slide - delta / ROW_SLIDE_DUR)

	var now := App.station_time
	if now - _last_fetch_at >= FETCH_INTERVAL:
		_last_fetch_at = now
		_do_fetch()

	if _last_good_fetch > 0.0:
		_data_age_sec = now - _last_good_fetch

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true

	queue_redraw()

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "api:%s j:%d h:%d" % [_api_status, _deps_j.size(), _deps_h.size()],
		"intensity": 0.5,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("OrbitalTransitControl: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	for child in get_children():
		if child is HTTPRequest:
			child.cancel_request()
			child.queue_free()

# ══════════════════════════════════════════════════════════════════════════════
# HTTP / data layer
# ══════════════════════════════════════════════════════════════════════════════

func _do_fetch() -> void:
	_last_sync_str = Time.get_time_string_from_system()
	if not _http_j_pending:
		_fetch_stop("j", STOP_JANNOWITZ)
	if not _http_h_pending:
		_fetch_stop("h", STOP_HEINRICH)

func _fetch_stop(key: String, stop_id: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0   # don't let a hung request block all future polls
	add_child(http)
	var url := "https://v6.bvg.transport.rest/stops/%s/departures?duration=30&results=14" % stop_id
	var err  := http.request(url)
	if err != OK:
		_api_status = "REQ_ERROR"
		http.queue_free()
		return
	if key == "j":
		_http_j_pending = true
		http.request_completed.connect(_on_j_done.bind(http))
	else:
		_http_h_pending = true
		http.request_completed.connect(_on_h_done.bind(http))

func _on_j_done(result: int, code: int, _h: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	_http_j_pending = false
	http.queue_free()
	var arr: Array = _parse_response(result, code, body)
	if not arr.is_empty():
		_deps_j = _filter_rail(arr)
		_on_good_data()

func _on_h_done(result: int, code: int, _h: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	_http_h_pending = false
	http.queue_free()
	var arr: Array = _parse_response(result, code, body)
	if not arr.is_empty():
		_deps_h = _filter_mixed(arr)
		_on_good_data()

func _parse_response(result: int, code: int, body: PackedByteArray) -> Array:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_api_status = "SIGNAL_DEGRADED"
		return []
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null:
		_api_status = "PARSE_ERROR"
		return []
	if parsed is Array:
		return _normalize(parsed as Array)
	if parsed is Dictionary and (parsed as Dictionary).has("departures"):
		return _normalize((parsed as Dictionary)["departures"] as Array)
	_api_status = "FORMAT_ERROR"
	return []

func _on_good_data() -> void:
	_last_good_fetch = App.station_time
	_data_age_sec    = 0.0
	_api_status      = "OK"
	_row_slide       = 1.0   # trigger slide-in animation

func _normalize(data: Array) -> Array:
	var result   := []
	var now_unix := Time.get_unix_time_from_system()
	for d in data:
		if not (d is Dictionary):
			continue
		var line_obj = d.get("line", null)
		if not (line_obj is Dictionary):
			continue
		var product   := str(line_obj.get("product", ""))
		var line_name := str(line_obj.get("name", "?"))
		var direction := _trunc(str(d.get("direction", "?")), 22)
		# Use "when" (real-time), fall back to "plannedWhen" if null
		var when_raw = d.get("when", null)
		if when_raw == null or str(when_raw) == "null":
			when_raw = d.get("plannedWhen", null)
		var when_unix := 0.0
		if when_raw != null and str(when_raw) != "null":
			when_unix = _iso_to_unix(str(when_raw))
		# Skip entries with no valid timestamp — they'd appear as "99 min" at the top
		if when_unix <= 0.0:
			continue
		var minutes := maxi(0, int((when_unix - now_unix) / 60.0))
		var delay_raw = d.get("delay", null)
		var delay_sec := int(delay_raw) if delay_raw != null else 0
		var delay_min := int(delay_sec / 60)
		result.append({
			"line":      line_name,
			"product":   product,
			"direction": direction,
			"when_unix": when_unix,
			"minutes":   minutes,
			"delay":     delay_min,
			"status":    _get_status(minutes, delay_min),
		})
	result.sort_custom(func(a, b): return float(a["when_unix"]) < float(b["when_unix"]))
	return result

func _filter_rail(arr: Array) -> Array:
	var out: Array = []
	for d in arr:
		if str(d["product"]) in ["suburban", "subway"]:
			out.append(d)
	return out.slice(0, 8)

func _filter_mixed(arr: Array) -> Array:
	var out: Array = []
	for d in arr:
		if str(d["product"]) in ["subway", "bus"]:
			out.append(d)
	return out.slice(0, 8)

func _iso_to_unix(s: String) -> float:
	# Parse "YYYY-MM-DDTHH:MM:SS+HH:MM" robustly using component extraction.
	# get_unix_time_from_datetime_string is unreliable across Godot builds;
	# get_unix_time_from_datetime_dict always treats input as UTC — correct here.
	if s.length() < 19:
		return -1.0
	var dt := {
		"year":   int(s.substr(0, 4)),
		"month":  int(s.substr(5, 2)),
		"day":    int(s.substr(8, 2)),
		"hour":   int(s.substr(11, 2)),
		"minute": int(s.substr(14, 2)),
		"second": int(s.substr(17, 2)),
	}
	var base := Time.get_unix_time_from_datetime_dict(dt)
	if s.length() <= 19:
		return base
	var tz := s.substr(19)
	if tz.begins_with("Z"):
		return base
	var sign   := 1.0 if tz.begins_with("+") else -1.0
	var parts  := tz.substr(1).split(":")
	if parts.size() < 2:
		return base
	# base is localtime treated as UTC; subtract offset to get true UTC unix
	var offset := (int(parts[0]) * 3600 + int(parts[1]) * 60) * sign
	return base - offset

func _get_status(minutes: int, delay: int) -> String:
	if delay > 2:      return "VECTOR_DRIFT"
	if minutes <= 1:   return "DOCKING"
	if minutes <= 5:   return "FINAL_APPROACH"
	return "INBOUND"

func _live_secs(dep: Dictionary, now_unix: float) -> int:
	# Total seconds until departure, computed fresh each frame from the stored timestamp.
	var wu := float(dep.get("when_unix", 0.0))
	if wu <= 0.0:
		return 9999
	return maxi(0, int(wu - now_unix))

func _fmt_eta(secs: int) -> String:
	# Format seconds-until-departure into a display string.
	if secs >= 9999: return "?"
	if secs <= 30:   return "NOW"
	if secs < 120:   return "1 min"         # 31–119s shown as "1 min"
	return "%d min" % (secs / 60)

func _trunc(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n - 2) + ".."

# ══════════════════════════════════════════════════════════════════════════════
# Rendering — dispatched per panel
# ══════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return
	var a := 1.0
	if _winding_down:
		a = clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)
	_draw_panel0(a)
	_draw_panel1(a)
	_draw_panel2(a)
	_draw_panel3(a)
	_draw_seams(a)

# ── Panel 0: Strategic Header ─────────────────────────────────────────────────

func _draw_panel0(a: float) -> void:
	var py := 0
	_bg_dots(py, a * 0.5)
	_panel_frame(py, a)
	_draw_radar(float(PW) - 155.0, float(py) + 145.0, 105.0, a)
	if not _font: return

	var x := 28.0
	var y := float(py) + 36.0
	const LH := 38.0

	_hline(x, y - 12.0, float(PW) - 56.0, C_CYAN, a)
	_text(x, y, "ORBITAL TRANSIT CONTROL", 29, C_HEADER, a)
	y += LH
	_text(x, y, "// BERLIN SECTOR", 29, C_HEADER, a)
	y += LH + 4.0
	_hline(x, y - 3.0, float(PW) - 56.0, C_DIM, a * 0.4)
	y += 8.0

	_text(x, y, "PRIMARY HUB:    JANNOWITZBRÜCKE",        23, C_BODY, a); y += LH
	_text(x, y, "SECONDARY HUB:  HEINRICH-HEINE-STRASSE", 23, C_BODY, a); y += LH + 6.0

	_text(x, y, "LOCAL TIME:  " + Time.get_time_string_from_system(), 23, C_CYAN, a); y += LH
	_text(x, y, "LAST SYNC:   " + _last_sync_str,                     23, C_DIM,  a); y += LH + 6.0

	var s_col := C_GREEN
	if _api_status == "SIGNAL_DEGRADED": s_col = C_RED
	elif _api_status != "OK":             s_col = C_AMBER
	var s_label := "LIVE DATA STREAM" if _api_status == "OK" else _api_status
	_text(x, y, "STATUS:      " + s_label, 23, s_col, a); y += LH

	var dl := _delay_field()
	var dl_col := C_GREEN if dl == "LOW" else (C_RED if dl == "HIGH" else C_AMBER)
	_text(x, y, "DELAY FIELD: " + dl, 23, dl_col, a)

	var by := float(py + PH) - 20.0
	_text(x, by, "BERLIN SECTOR // BVG REST v6 // " + STOP_JANNOWITZ + " / " + STOP_HEINRICH,
			18, C_DIM, a * 0.60)

func _delay_field() -> String:
	var now_unix := Time.get_unix_time_from_system()
	var n := 0
	for d in _deps_j + _deps_h:
		var secs := _live_secs(d, now_unix)
		if _get_status(secs / 60, int(d["delay"])) == "VECTOR_DRIFT":
			n += 1
	if n == 0:  return "LOW"
	if n <= 2:  return "MODERATE"
	return "HIGH"

# ── Panel 1: Jannowitzbrücke ──────────────────────────────────────────────────

func _draw_panel1(a: float) -> void:
	var py := PH
	_bg_dots(py, a * 0.35)
	_panel_frame(py, a)
	_dock_header(py, "JANNOWITZBRÜCKE // RAIL", a)
	_departure_table(py, _deps_j, a)

# ── Panel 2: Heinrich-Heine-Straße ────────────────────────────────────────────

func _draw_panel2(a: float) -> void:
	var py := PH * 2
	_bg_dots(py, a * 0.35)
	_panel_frame(py, a)
	_dock_header(py, "HEINRICH-HEINE-STRASSE // SURFACE + SUBWAY", a)
	_departure_table(py, _deps_h, a)

# ── Panel 3: Rotating telemetry panel ────────────────────────────────────────

func _draw_panel3(a: float) -> void:
	var py := PH * 3
	_bg_dots(py, a * 0.45)
	_panel_frame(py, a)
	match _bottom_mode:
		0: _panel3_telemetry(py, a)
		1: _panel3_expanded(py, a)
		2: _panel3_flavor(py, a)

func _panel3_telemetry(py: int, a: float) -> void:
	var x := 28.0; var y := float(py) + 34.0
	const LH := 26.0
	_hline(x, y - 11.0, float(PW) - 56.0, C_CYAN, a)
	_text(x, y, "[SYSTEM TELEMETRY // FEED STATUS]", 25, C_HEADER, a); y += LH + 5.0
	_hline(x, y - 3.0, float(PW) - 56.0, C_DIM, a * 0.4); y += 7.0

	var age_str := "--" if _last_good_fetch < 0.0 \
			else "%02d:%02d" % [int(_data_age_sec) / 60, int(_data_age_sec) % 60]
	var status_col := C_BODY if _api_status == "OK" else C_AMBER

	var rows := [
		["DATA SOURCE:   BVG REST FEED v6",                C_BODY],
		["",                                               C_DIM],
		["STOP IDS:",                                      C_DIM],
		["  JANNOWITZ:      " + STOP_JANNOWITZ,            C_DIM],
		["  HEINRICH-HEINE: " + STOP_HEINRICH,             C_DIM],
		["",                                               C_DIM],
		["LAST UPDATE:   " + _last_sync_str,               C_BODY],
		["POLL INTERVAL: 30s",                             C_BODY],
		["",                                               C_DIM],
		["API STATUS:    " + _api_status,                  status_col],
		["DATA AGE:      " + age_str,                      C_BODY],
		["",                                               C_DIM],
		["DEPARTURES J:  %d" % _deps_j.size(),             C_BODY],
		["DEPARTURES H:  %d" % _deps_h.size(),             C_BODY],
	]
	for row in rows:
		if y > float(py + PH) - 20.0: break
		_text(x, y, row[0], 22, row[1], a)
		y += LH

func _panel3_expanded(py: int, a: float) -> void:
	var x := 28.0; var y := float(py) + 34.0
	const LH := 42.0
	_hline(x, y - 11.0, float(PW) - 56.0, C_CYAN, a)
	_text(x, y, "[NEXT DEPARTURE // EXPANDED VIEW]", 25, C_HEADER, a); y += LH + 5.0

	# Find earliest departure across both stops (by live when_unix)
	var nd: Dictionary = {}
	var nd_stop := ""
	for d in _deps_j:
		if nd.is_empty() or float(d["when_unix"]) < float(nd["when_unix"]):
			nd = d; nd_stop = "JANNOWITZBRÜCKE"
	for d in _deps_h:
		if nd.is_empty() or float(d["when_unix"]) < float(nd["when_unix"]):
			nd = d; nd_stop = "HEINRICH-HEINE-STRASSE"

	if nd.is_empty():
		_text(x, y + 38.0, "NO DEPARTURE DATA AVAILABLE", 25, C_AMBER, a)
		return

	var now_unix := Time.get_unix_time_from_system()
	var live_secs := _live_secs(nd, now_unix)
	var live_min  := live_secs / 60
	var eta_str   := _fmt_eta(live_secs)
	var sc := _status_col(_get_status(live_min, int(nd["delay"])))
	_text(x, y, "HUB:         " + nd_stop,                    23, C_BODY, a); y += LH
	_text(x, y, "LINE:        " + str(nd["line"]),             31, sc,     a); y += LH + 4.0
	_text(x, y, "DESTINATION: " + str(nd["direction"]),        23, C_BODY, a); y += LH
	_text(x, y, "ETA:         " + eta_str,                     27, sc,     a); y += LH
	_text(x, y, "STATUS:      " + _get_status(live_min, int(nd["delay"])), 23, sc, a); y += LH

	if int(nd["delay"]) > 0:
		_text(x, y, "VECTOR DRIFT: +%d min" % nd["delay"], 23, C_AMBER, a)
	else:
		_text(x, y, "DRIFT:       NOMINAL",                23, C_DIM,   a)
	y += LH + 12.0

	# Approach bar (fills as departure nears — max 15 min = 900s window)
	var bar_w := float(PW) - 56.0
	var prog  := clampf(1.0 - float(live_secs) / 900.0, 0.0, 1.0)
	draw_rect(Rect2(x, y, bar_w,          11.0), Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.22 * a))
	draw_rect(Rect2(x, y, bar_w * prog,   11.0), Color(sc.r,    sc.g,    sc.b,    0.55 * a))
	draw_rect(Rect2(x, y, bar_w,          11.0), Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.35 * a), false)

func _panel3_flavor(py: int, a: float) -> void:
	var x := 28.0; var y := float(py) + 48.0
	const LH := 50.0
	_hline(x, float(py) + 10.0, float(PW) - 56.0, C_AMBER, a * 0.65)
	var msgs: Array = _FLAVORS[_flavor_idx]
	for msg in msgs:
		if y > float(py + PH) - 20.0: break
		if msg == "": y += LH * 0.5; continue
		_text(x, y, msg, 29, C_AMBER if msg.ends_with(":") else C_BODY, a)
		y += LH

# ── Shared departure table ────────────────────────────────────────────────────

func _dock_header(py: int, title: String, a: float) -> void:
	var x := 16.0; var y := float(py) + 34.0
	_hline(x, float(py) + 8.0, float(PW) - 32.0, C_CYAN, a)
	_text(x, y, "[DOCK: " + title + "]", 25, C_HEADER, a)
	y += 28.0
	_hline(x, y - 2.0, float(PW) - 32.0, C_DIM, a * 0.45)
	y += 11.0
	# Column headers — positions must match _departure_table
	_text(x + 4.0,   y, "LINE",        20, C_DIM, a * 0.80)
	_text(x + 220.0, y, "DESTINATION", 20, C_DIM, a * 0.80)
	_text(x + 600.0, y, "STATUS",      20, C_DIM, a * 0.80)
	y += 5.0
	_hline(x, y, float(PW) - 32.0, C_DIM, a * 0.25)

func _departure_table(py: int, deps: Array, a: float) -> void:
	var x        := 16.0
	var y_start  := float(py) + 90.0
	const ROW_H  := 120.0
	const MAX_R  := 5
	# Cache system time once — avoid multiple calls per frame
	var now_unix := Time.get_unix_time_from_system()

	if deps.is_empty():
		var sy := y_start + 36.0
		var degraded := _api_status in ["SIGNAL_DEGRADED", "PARSE_ERROR", "FORMAT_ERROR", "REQ_ERROR"]
		if degraded:
			_text(x + 32.0, sy,        "STATUS: " + _api_status, 23, C_AMBER, a)
			_text(x + 32.0, sy + 36.0,
					"DATA AGE: %02d:%02d" % [int(_data_age_sec) / 60, int(_data_age_sec) % 60],
					22, C_DIM, a)
		else:
			_text(x + 32.0, sy, "AWAITING DATA STREAM...", 22, C_DIM, a * 0.65)
		return

	var shown := mini(deps.size(), MAX_R)
	for i in shown:
		var d: Dictionary  = deps[i]
		var stagger        := 1.0 - float(i) / float(shown)
		var ry             := y_start + float(i) * ROW_H + _row_slide * 18.0 * stagger
		if ry < float(py) or ry > float(py + PH) - 8.0:
			continue

		var secs    := _live_secs(d, now_unix)
		var mins    := secs / 60
		var status  := _get_status(mins, int(d["delay"]))
		var sc      := _status_col(status)
		var ra      := a
		# Pulse rows that are arriving now
		if secs <= 30:
			ra *= 0.65 + 0.35 * absf(sin(_blink))

		# Bracket for next departure
		if i == 0:
			var bx := x - 6.0; var by := ry - 29.0; var bh := ROW_H - 4.0
			var bc := Color(sc.r, sc.g, sc.b, sc.a * ra * 0.70)
			draw_line(Vector2(bx, by),       Vector2(bx, by + bh),       bc, 1.5)
			draw_line(Vector2(bx, by),       Vector2(bx + 8.0, by),      bc, 1.5)
			draw_line(Vector2(bx, by + bh),  Vector2(bx + 8.0, by + bh), bc, 1.5)

		# Top strip: line name + destination
		_text(x + 4.0,   ry,        str(d["line"]),      29, sc,     ra)
		_text(x + 220.0, ry,        str(d["direction"]), 23, C_BODY, ra)

		# Bottom strip: large ETA + status + delay
		var eta_str := _fmt_eta(secs)
		_text(x + 4.0,   ry + 78.0, eta_str,  72, sc,     ra)
		_text(x + 600.0, ry + 78.0, status,   22, sc,     ra * 0.82)
		if int(d["delay"]) > 0:
			_text(x + 600.0, ry + 105.0, "+%d min late" % d["delay"], 20, C_AMBER, ra)

		if i < shown - 1:
			_hline(x + 4.0, ry + ROW_H - 5.0, float(PW) - 40.0, C_DIM, a * 0.18)

func _status_col(status: String) -> Color:
	match status:
		"DOCKING":        return C_GREEN
		"FINAL_APPROACH": return C_CYAN
		"VECTOR_DRIFT":   return C_AMBER
		_:                return C_BODY

# ── Visual primitives ─────────────────────────────────────────────────────────

func _draw_radar(cx: float, cy: float, r: float, a: float) -> void:
	var ctr := Vector2(cx, cy)
	# Rings
	draw_arc(ctr, r,       0.0, TAU, 48, Color(C_DIM.r,  C_DIM.g,  C_DIM.b,  C_DIM.a  * a * 0.55), 1.0, true)
	draw_arc(ctr, r * 0.5, 0.0, TAU, 32, Color(C_DIM.r,  C_DIM.g,  C_DIM.b,  C_DIM.a  * a * 0.28), 0.5, true)
	# Crosshairs
	draw_line(ctr + Vector2(-r, 0), ctr + Vector2(r,  0), Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.30 * a), 0.5)
	draw_line(ctr + Vector2(0, -r), ctr + Vector2(0,  r), Color(C_DIM.r, C_DIM.g, C_DIM.b, 0.30 * a), 0.5)
	# Tick marks
	for ti in 8:
		var ang := TAU * float(ti) / 8.0
		draw_line(ctr + Vector2(cos(ang), sin(ang)) * (r - 6.0),
				ctr + Vector2(cos(ang), sin(ang)) * r,
				Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * a * 0.40), 1.0)
	# Sweep fill
	var s0 := _radar_angle - TAU * 0.22
	draw_arc(ctr, r * 0.97, s0, _radar_angle, 24,
			Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.07 * a), r * 0.97, true)
	# Leading edge
	draw_line(ctr, ctr + Vector2(cos(_radar_angle), sin(_radar_angle)) * r,
			Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, C_CYAN.a * a * 0.72), 1.5, true)

func _bg_dots(py: int, a: float) -> void:
	var c := Color(C_GRID.r, C_GRID.g, C_GRID.b, C_GRID.a * a)
	for ri in 13:
		for ci in 17:
			draw_circle(Vector2(ci * 64.0, float(py) + ri * 64.0), 1.0, c)

func _panel_frame(py: int, a: float) -> void:
	var r := Rect2(4.0, float(py) + 4.0, float(PW) - 8.0, float(PH) - 8.0)
	draw_rect(r, Color(C_DIM.r, C_DIM.g, C_DIM.b, C_DIM.a * a * 0.32), false, 1.0)
	const BL := 18.0; const BT := 1.5
	var cs := [
		[r.position,                   Vector2( 1, 0), Vector2(0,  1)],
		[Vector2(r.end.x, r.position.y), Vector2(-1, 0), Vector2(0,  1)],
		[Vector2(r.position.x, r.end.y), Vector2( 1, 0), Vector2(0, -1)],
		[r.end,                          Vector2(-1, 0), Vector2(0, -1)],
	]
	for corner in cs:
		var p: Vector2  = corner[0]
		var dx: Vector2 = corner[1]
		var dy: Vector2 = corner[2]
		draw_line(p, p + dx * BL, Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, C_CYAN.a * a * 0.55), BT)
		draw_line(p, p + dy * BL, Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, C_CYAN.a * a * 0.55), BT)

func _draw_seams(a: float) -> void:
	for i in 3:
		draw_line(
				Vector2(0.0, float((i + 1) * PH)),
				Vector2(float(PW), float((i + 1) * PH)),
				Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, C_CYAN.a * a * 0.20), 0.5)

func _hline(x: float, y: float, w: float, c: Color, a: float) -> void:
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(c.r, c.g, c.b, c.a * a), 1.0)

func _text(x: float, y: float, s: String, fs: int, c: Color, a: float) -> void:
	if _font and s != "":
		draw_string(_font, Vector2(x, y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(c.r, c.g, c.b, c.a * a))
