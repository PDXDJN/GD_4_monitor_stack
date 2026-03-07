## NoradSituationBoard — Dense classified ops-room briefing wall.
## Strategic header + animated radar, regional threat table, event log,
## active track table, telemetry charts, relay network, scrolling ticker.
extends Node2D

var module_id         := "norad_situation_board"
var module_rng        : RandomNumberGenerator
var module_started_at := 0.0

# ── Module context ─────────────────────────────────────────────────────────────
var _manifest      : Dictionary
var _panel_layout  : PanelLayout
var _virtual_space : VirtualSpace
var _stop_requested := false
var _finished       := false

# ── Render geometry ────────────────────────────────────────────────────────────
var _total_size : Vector2i
var _w          : float
var _h          : float

const P0Y := 0.0
const P1Y := 768.0
const P2Y := 1536.0
const P3Y := 2304.0
const PH  := 768.0

# ── Palette ────────────────────────────────────────────────────────────────────
const C_SCAN  := Color(0.00, 0.08, 0.03, 0.055)
const C_PRIME := Color(0.10, 1.00, 0.45, 0.80)
const C_DIM   := Color(0.00, 0.55, 0.22, 0.38)
const C_HUD   := Color(0.00, 0.92, 0.42, 0.85)
const C_DEFCON:= Color(1.00, 0.18, 0.08, 0.95)
const C_AMBER := Color(1.00, 0.70, 0.05, 0.90)
const C_CYAN  := Color(0.20, 0.85, 0.85, 0.75)

# ── Wind-down ──────────────────────────────────────────────────────────────────
var _wd_timer     : float = 0.0
const WD_DUR      := 2.5
var _winding_down := false
var _alpha_scale  := 1.0

# ── Time reference ─────────────────────────────────────────────────────────────
var _time_ref : float = 0.0

# ── Panel 0 state ──────────────────────────────────────────────────────────────
var _op_name       : String = ""
var _condition     : int    = 3
var _net_integrity : float  = 94.0
var _last_station  : String = ""
var _radar_blips   : Array  = []   # [{angle, dist, label, flash_phase}]

# ── Panel 1: regions ───────────────────────────────────────────────────────────
var _regions            : Array = []
var _region_shift_timer : float = 0.0

const REGION_NAMES := [
	"ARCTIC", "NORTH ATLANTIC", "EUROPE", "PACIFIC",
	"N. AMERICA", "SIBERIAN CORR.", "POLAR APPROACH"
]

# ── Panel 1: event log ─────────────────────────────────────────────────────────
var _events      : Array = []
var _event_timer : float = 0.0

# ── Panel 2: tracks ────────────────────────────────────────────────────────────
var _tracks             : Array = []
var _selected_track_idx : int   = -1

# ── Panel 3: telemetry ─────────────────────────────────────────────────────────
const TELEM_BUF   := 64
const TELEM_INT   := 0.25
var _telem_signal : Array = []
var _telem_radar  : Array = []
var _telem_uplink : Array = []
var _telem_head   : int   = 0
var _telem_timer  : float = 0.0

# ── Panel 3: relay network ─────────────────────────────────────────────────────
var _relay_nodes : Array = []   # [{label, nx, ny, active, flash_phase}]
# Edge pairs by node index
const RELAY_EDGES := [[0,1],[1,2],[0,3],[1,3],[1,4],[2,4],[3,5],[4,5],[2,5]]

# ── Calibration overlay ────────────────────────────────────────────────────────
var _calibrating : bool  = false
var _calib_timer : float = 0.0
const CALIB_DUR  := 1.5

# ── Scrolling ticker ───────────────────────────────────────────────────────────
const TICKER_SPEED := 55.0   # px / sec
const TICKER_FULL  := \
	"NORAD CHEYENNE MOUNTAIN  ◆  BMEWS-N TRACK NOMINAL  ◆  " \
	+ "SAGE-07 CONTACT CONFIRMED  ◆  RELAY GRID STABLE  ◆  " \
	+ "IFF NEGATIVE TRACK-791  ◆  PHASE LOCK ACHIEVED  ◆  " \
	+ "SAT PASS T-04:22  ◆  CONTINGENCY ALPHA IN EFFECT  ◆  "

# ── Word banks ─────────────────────────────────────────────────────────────────
const ADJECTIVES := ["WATCHFUL", "SILENT", "DARK", "IRON", "POLAR",
					 "ARCTIC", "SHADOW", "CRIMSON", "DISTANT", "STEEL"]
const NOUNS      := ["ECHO", "MERIDIAN", "VECTOR", "COMPASS", "SENTRY",
					 "VIGIL", "BASTION", "CIPHER", "LANCE", "PRISM"]
const STATIONS   := ["BMEWS-N", "BMEWS-S", "SAGE-07", "NORAD-1",
					 "BMEWS-E", "EWS-021", "THULE-A"]
const ORBITS     := ["ORBIT-01", "ORBIT-04", "ORBIT-07", "ORBIT-12", "ORBIT-17"]
const RELAYS     := ["RELAY-1", "RELAY-4", "RELAY-7", "RELAY-9", "RELAY-12"]
const NAMED_IDS  := ["ARC", "POL", "SIB", "ATL", "PAC", "EUR"]

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
	_alpha_scale      = 1.0
	_time_ref         = App.station_time

	_total_size = _panel_layout.get_total_real_size()
	_w = float(_total_size.x)
	_h = float(_total_size.y)

	_op_name       = ADJECTIVES[module_rng.randi() % ADJECTIVES.size()] \
				   + " " + NOUNS[module_rng.randi() % NOUNS.size()]
	_condition     = module_rng.randi_range(2, 4)
	_net_integrity = module_rng.randf_range(88.0, 99.0)
	_last_station  = STATIONS[module_rng.randi() % STATIONS.size()]

	# Radar blips (seeded, stable per run)
	_radar_blips.clear()
	var blip_labels := ["ARC", "POL", "T741", "ATL", "SIB", "T762"]
	for bi in module_rng.randi_range(3, 5):
		_radar_blips.append({
			"angle":       module_rng.randf() * TAU,
			"dist":        module_rng.randf_range(0.28, 0.88),
			"label":       blip_labels[bi % blip_labels.size()],
			"flash_phase": module_rng.randf(),
		})

	# Regions
	_regions.clear()
	var init_statuses := ["CLEAR", "CLEAR", "TRACKING", "CLEAR", "ACTIVE", "TRACKING", "ALERT"]
	for i in REGION_NAMES.size():
		var st : String = init_statuses[i]
		_regions.append({
			"name":               REGION_NAMES[i],
			"status":             st,
			"track_ct":           module_rng.randi_range(1, 4) if st != "CLEAR" else 0,
			"last_event_elapsed": module_rng.randf_range(10.0, 900.0),
			"flash_phase":        module_rng.randf(),
			"threat":             module_rng.randf_range(0.1, 0.95) if st != "CLEAR" else module_rng.randf_range(0.0, 0.25),
		})
	_region_shift_timer = module_rng.randf_range(8.0, 25.0)

	# Tracks
	_tracks.clear()
	for _i in module_rng.randi_range(5, 9):
		_tracks.append(_make_track())

	# Event log
	_events.clear()
	for _i in 6:
		_events.append(_make_event())
	_event_timer = module_rng.randf_range(5.0, 18.0)

	# Telemetry ring buffers
	_telem_signal.clear()
	_telem_radar.clear()
	_telem_uplink.clear()
	for _i in TELEM_BUF:
		_telem_signal.append(module_rng.randf_range(0.78, 0.98))
		_telem_radar.append(module_rng.randf_range(0.60, 0.92))
		_telem_uplink.append(module_rng.randf_range(0.88, 0.99))
	_telem_head  = 0
	_telem_timer = 0.0

	# Relay network nodes (seeded positions)
	_relay_nodes.clear()
	var r_labels := ["THULE-A", "BMEWS-N", "SAGE-07", "NORAD-1", "BMEWS-S", "EWS-021"]
	# Positions in [0..1] relative to the relay rect
	var r_pos := [
		[0.10, 0.45], [0.35, 0.08], [0.65, 0.08],
		[0.50, 0.55], [0.88, 0.45], [0.50, 0.92],
	]
	for ni in r_labels.size():
		_relay_nodes.append({
			"label":       r_labels[ni],
			"nx":          float(r_pos[ni][0]),
			"ny":          float(r_pos[ni][1]),
			"active":      module_rng.randf() < 0.85,
			"flash_phase": module_rng.randf(),
		})

	EventBus.rare_event.connect(_on_rare_event)

func module_status() -> Dictionary:
	var live_ct := 0
	for t in _tracks:
		if t["state"] == "LIVE":
			live_ct += 1
	return {
		"ok":        true,
		"notes":     "COND %d | %d live tracks | op: %s" % [_condition, live_ct, _op_name],
		"intensity": 0.5
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down   = true
	_wd_timer       = 0.0
	Log.debug("NoradSituationBoard: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	if EventBus.rare_event.is_connected(_on_rare_event):
		EventBus.rare_event.disconnect(_on_rare_event)

# ─────────────────────────────────────────────────────────────────────────────
#  Process
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wd_timer    += delta
		_alpha_scale  = clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)
		if _wd_timer >= WD_DUR:
			_finished = true
		queue_redraw()
		return

	var elapsed := App.station_time - _time_ref

	if _calibrating:
		_calib_timer += delta
		if _calib_timer >= CALIB_DUR:
			_calibrating = false

	for r in _regions:
		r["last_event_elapsed"] = float(r["last_event_elapsed"]) + delta

	_region_shift_timer -= delta
	if _region_shift_timer <= 0.0:
		_region_shift_timer = module_rng.randf_range(8.0, 25.0)
		_shift_region_status()

	_event_timer -= delta
	if _event_timer <= 0.0:
		_event_timer = module_rng.randf_range(5.0, 18.0)
		_push_event(_make_event())

	_telem_timer += delta
	if _telem_timer >= TELEM_INT:
		_telem_timer -= TELEM_INT
		var prev_s := float(_telem_signal[(_telem_head - 1 + TELEM_BUF) % TELEM_BUF])
		var prev_r := float(_telem_radar[(_telem_head - 1 + TELEM_BUF) % TELEM_BUF])
		var prev_u := float(_telem_uplink[(_telem_head - 1 + TELEM_BUF) % TELEM_BUF])
		_telem_signal[_telem_head] = clampf(prev_s + module_rng.randf_range(-0.05, 0.05), 0.60, 1.0)
		_telem_radar[_telem_head]  = clampf(prev_r + module_rng.randf_range(-0.09, 0.09), 0.35, 1.0)
		_telem_uplink[_telem_head] = clampf(prev_u + module_rng.randf_range(-0.02, 0.04), 0.50, 1.0)
		_telem_head = (_telem_head + 1) % TELEM_BUF

	for i in _tracks.size():
		var t = _tracks[i]
		t["age"] = float(t["age"]) + delta
		if t["state"] == "ACQUIRING" and float(t["age"]) > float(t["acq_dur"]):
			t["state"] = "LIVE"
		elif t["state"] == "LIVE":
			t["impact_t"] = float(t["impact_t"]) - delta
			if module_rng.randf() < 0.008:
				t["conf"] = clampi(int(t["conf"]) + module_rng.randi_range(-4, 4), 30, 99)
			if module_rng.randf() < 0.0008 and _tracks.size() > 3:
				t["state"] = "FADING"
				t["fade_timer"] = 0.0
		elif t["state"] == "FADING":
			t["fade_timer"] = float(t["fade_timer"]) + delta
			if float(t["fade_timer"]) > 2.0:
				_tracks[i] = _make_track()
				_push_event(_make_event())

	_selected_track_idx = -1
	var best_conf := -1
	for i in _tracks.size():
		var t = _tracks[i]
		if t["state"] == "LIVE" and int(t["conf"]) > best_conf:
			best_conf = int(t["conf"])
			_selected_track_idx = i

	_condition = 3 + int(sin(elapsed * 0.025) * 1.5)
	_condition = clampi(_condition, 2, 4)

	queue_redraw()

# ─────────────────────────────────────────────────────────────────────────────
#  Data helpers
# ─────────────────────────────────────────────────────────────────────────────

func _make_track() -> Dictionary:
	var named := module_rng.randf() < 0.25
	var id_str: String = NAMED_IDS[module_rng.randi() % NAMED_IDS.size()] \
				  if named else "%d" % module_rng.randi_range(700, 799)
	var srcs := ["SAT", "RAD", "OVH"]
	return {
		"id":         id_str,
		"src":        srcs[module_rng.randi() % srcs.size()],
		"spd":        module_rng.randi_range(8000, 24000),
		"alt":        module_rng.randi_range(4, 180),
		"hdg":        module_rng.randi_range(0, 359),
		"conf":       module_rng.randi_range(40, 92),
		"state":      "ACQUIRING" if module_rng.randf() < 0.3 else "LIVE",
		"age":        0.0,
		"acq_dur":    module_rng.randf_range(3.0, 6.0),
		"impact_t":   module_rng.randf_range(180.0, 1200.0),
		"fade_timer": 0.0,
		"region":     REGION_NAMES[module_rng.randi() % REGION_NAMES.size()],
	}

func _make_event() -> String:
	var t  := App.station_time
	var ts := "%02d:%02d:%02dZ" % [int(t / 3600) % 24, int(t / 60) % 60, int(t) % 60]
	var pick := module_rng.randi() % 8
	match pick:
		0: return "%s  TRACK INIT    %d    %s" % [
			ts, module_rng.randi_range(700, 799),
			REGION_NAMES[module_rng.randi() % REGION_NAMES.size()]]
		1: return "%s  RADAR HANDOFF %s  SPD %d" % [
			ts, STATIONS[module_rng.randi() % STATIONS.size()],
			module_rng.randi_range(1000, 9999)]
		2: return "%s  SAT PASS      %s  VIS %d:%02d" % [
			ts, ORBITS[module_rng.randi() % ORBITS.size()],
			module_rng.randi_range(0, 9), module_rng.randi_range(0, 59)]
		3: return "%s  IFF NEGATIVE  TRACK-%d  UNRESOLVED" % [
			ts, module_rng.randi_range(700, 799)]
		4: return "%s  SIGNAL ACQ    %s  STR %d%%" % [
			ts, RELAYS[module_rng.randi() % RELAYS.size()],
			module_rng.randi_range(70, 99)]
		5: return "%s  RELAY OK      %s  NOMINAL" % [
			ts, RELAYS[module_rng.randi() % RELAYS.size()]]
		6: return "%s  DATA RECV     %s  %d B" % [
			ts, STATIONS[module_rng.randi() % STATIONS.size()],
			module_rng.randi_range(1024, 65535)]
		_: return "%s  ANOMALY       %s  UNDER REVIEW" % [
			ts, REGION_NAMES[module_rng.randi() % REGION_NAMES.size()]]

func _push_event(e: String) -> void:
	_events.insert(0, e)
	if _events.size() > 12:
		_events.resize(12)

func _shift_region_status() -> void:
	var idx := module_rng.randi() % _regions.size()
	var r    = _regions[idx]
	var cur  : String = r["status"]
	var roll := module_rng.randf()
	var next : String
	if cur == "CLEAR":
		next = "TRACKING" if roll < 0.25 else "CLEAR"
	elif cur == "TRACKING":
		if   roll < 0.10: next = "ALERT"
		elif roll < 0.40: next = "CLEAR"
		else:             next = "TRACKING"
	elif cur == "ALERT":
		next = "TRACKING" if roll < 0.55 else "ALERT"
	elif cur == "UNKNOWN":
		next = "TRACKING" if roll < 0.65 else "UNKNOWN"
	else:
		next = cur
	r["status"]   = next
	r["track_ct"] = module_rng.randi_range(1, 4) if next != "CLEAR" else 0
	r["threat"]   = module_rng.randf_range(0.3, 0.95) if next != "CLEAR" else module_rng.randf_range(0.0, 0.2)
	r["last_event_elapsed"] = 0.0
	if next != cur:
		_push_event(_make_event())

func _ts() -> String:
	var t := App.station_time
	return "%02d:%02d:%02dZ" % [int(t / 3600) % 24, int(t / 60) % 60, int(t) % 60]

# ─────────────────────────────────────────────────────────────────────────────
#  EventBus
# ─────────────────────────────────────────────────────────────────────────────

func _on_rare_event(name: String, _payload: Dictionary) -> void:
	match name:
		"UPLINK_LOST":
			for i in 10:
				_telem_uplink[(_telem_head - 1 - i + TELEM_BUF * 2) % TELEM_BUF] = \
					maxf(0.0, float(i) * 0.06)
			_push_event(_ts() + "  UPLINK DEGRADED  REACQUISITION IN PROGRESS")
		"TRANSMISSION_ANOMALY":
			_push_event(_ts() + "  ANOMALY DETECTED  SECTOR UNKNOWN  INVESTIGATING")
		"DISPLAY_BUS_CALIBRATION":
			_calibrating = true
			_calib_timer = 0.0
		"PHASE_OFFSET_CORRECTED":
			_push_event(_ts() + "  PHASE OFFSET CORRECTED  RELAY NOMINAL")

# ─────────────────────────────────────────────────────────────────────────────
#  Draw dispatch
# ─────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var a       := _alpha_scale
	var elapsed := App.station_time - _time_ref

	_draw_scanlines(a)
	_draw_panel0(a, elapsed)
	_draw_panel1(a, elapsed)
	_draw_panel2(a, elapsed)
	_draw_panel3(a, elapsed)
	_draw_panel_separators(a)
	_draw_corner_brackets(a)
	_draw_alert_border(a, elapsed)

	if _calibrating:
		var ca := clampf(1.0 - _calib_timer / CALIB_DUR, 0.0, 1.0) * a
		draw_rect(Rect2(0, 0, _w, _h), Color(0.0, 0.0, 0.0, ca * 0.85))
		draw_string(ThemeDB.fallback_font,
			Vector2(_w * 0.5 - 120, _h * 0.5 + 18),
			"CALIBRATING...", HORIZONTAL_ALIGNMENT_LEFT, -1, 36,
			_tint(C_HUD, ca))

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 0 — Strategic Header + Condition + Radar
# ─────────────────────────────────────────────────────────────────────────────

func _draw_panel0(a: float, elapsed: float) -> void:
	var font    := ThemeDB.fallback_font
	var col     := _tint(C_PRIME, a)
	var col_dim := _tint(C_DIM,   a)
	var col_hud := _tint(C_HUD,   a)
	var col_def := _tint(C_DEFCON, a)

	var oy := P0Y

	# ── Title ────────────────────────────────────────────────────────────────
	draw_string(font, Vector2(24, oy + 44),
		"CONTINENTAL DEFENSE COMMAND",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 28, col)

	var t_now := App.station_time
	var utc := "%02d:%02d:%02dZ" % [int(t_now/3600)%24, int(t_now/60)%60, int(t_now)%60]
	draw_string(font, Vector2(24, oy + 72),
		"STRATEGIC STATUS PANEL", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col_dim)
	draw_string(font, Vector2(_w - 170, oy + 72),
		"UTC  " + utc, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col_hud)
	_draw_hline(20, _w - 20, oy + 84, col_dim, 0.7)

	# ── Condition box ─────────────────────────────────────────────────────────
	var bx := 20.0;  var by := oy + 98.0
	var bw := 215.0; var bh  := 220.0
	_draw_box(bx, by, bw, bh, col_dim, 0.8)
	draw_string(font, Vector2(bx + 12, by + 26), "CONDITION",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col_dim)

	var roman := ["I", "II", "III", "IV", "V"]
	draw_string(font, Vector2(bx + 14, by + 86),
		roman[_condition - 1], HORIZONTAL_ALIGNMENT_LEFT, -1, 52, col_def)

	var dot_y := by + 132.0
	for lv in 5:
		var active := ((lv + 1) == _condition)
		var dc  := _tint(C_DEFCON, a) if active else col_dim
		var sym := "■" if active else "○"
		draw_string(font, Vector2(bx + 16 + lv * 37, dot_y),
			sym, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, dc)
	for lv in 5:
		draw_string(font, Vector2(bx + 21 + lv * 37, dot_y + 20),
			"%d" % (lv + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, a * 0.5))

	# ── System status box ─────────────────────────────────────────────────────
	var sx := 250.0;  var sy := oy + 98.0
	var sw := _w - sx - 20.0; var sh := 220.0
	_draw_box(sx, sy, sw, sh, col_dim, 0.8)
	draw_string(font, Vector2(sx + 12, sy + 26), "SYSTEM STATUS",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col_dim)

	var sys_lines := [
		["RADAR NET ........ ", "ACTIVE"],
		["RELAY GRID ....... ", "STABLE"],
		["SAT UPLINK ....... ", "ONLINE"],
		["COMMS ............ ", "SECURE"],
	]
	for si in sys_lines.size():
		var row : Array = sys_lines[si]
		draw_string(font, Vector2(sx + 12, sy + 54 + si * 40),
			row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
		draw_string(font, Vector2(sx + 190, sy + 54 + si * 40),
			row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_hud)

	# ── Footer strip ──────────────────────────────────────────────────────────
	var fy := oy + 336.0
	_draw_hline(20, _w - 20, fy, col_dim, 0.7)
	draw_string(font, Vector2(24, fy + 30),
		"OPERATION: " + _op_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col_hud)
	draw_string(font, Vector2(24, fy + 56),
		"LAST HANDOFF: " + _last_station + "       SECTOR: ARCTIC",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
	var net_vis := fmod(elapsed, 1.4) < 1.05
	if net_vis:
		draw_string(font, Vector2(24, fy + 82),
			"■ NETWORK INTEGRITY ......................... %.0f%%" % _net_integrity,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)

	# ── Mini radar display ────────────────────────────────────────────────────
	var radar_cx := _w * 0.5
	var radar_cy := oy + 570.0
	var radar_r  := 135.0
	_draw_radar(radar_cx, radar_cy, radar_r, elapsed, a)

	# Radar box label
	draw_string(font, Vector2(radar_cx - 58, oy + 430),
		"POLAR THREAT DISPLAY", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)
	_draw_hline(radar_cx - 80, radar_cx + 80, oy + 435, col_dim, 0.4)

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 1 — Regional Threat Table + Event Log
# ─────────────────────────────────────────────────────────────────────────────

func _draw_panel1(a: float, elapsed: float) -> void:
	var font    := ThemeDB.fallback_font
	var col     := _tint(C_PRIME, a)
	var col_dim := _tint(C_DIM,   a)
	var col_hud := _tint(C_HUD,   a)

	var oy := P1Y

	_draw_section_header(oy + 34, "REGIONAL STATUS", a)
	_draw_hline(20, _w - 20, oy + 46, col_dim, 0.7)

	var cx := [36.0, 252.0, 380.0, 462.0, 640.0]
	var hdrs := ["SECTOR", "STATUS", "TRACKS", "LAST EVENT", "THREAT"]
	for ci in hdrs.size():
		draw_string(font, Vector2(cx[ci], oy + 70),
			hdrs[ci], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)
	_draw_hline(20, _w - 20, oy + 76, col_dim, 0.4)

	for ri in _regions.size():
		var r     = _regions[ri]
		var row_y := oy + 102.0 + ri * 50.0

		var status : String = r["status"]
		var sc : Color
		if status == "ALERT":
			var flash_v := 1.0 if fmod(elapsed + float(r["flash_phase"]), 0.66) < 0.43 else 0.25
			sc = _tint(C_DEFCON, a * flash_v)
		elif status == "TRACKING":
			sc = _tint(C_AMBER, a)
		elif status == "UNKNOWN":
			sc = _tint(C_CYAN, a)
		else:
			sc = col_dim

		# Left-edge status stripe
		draw_line(Vector2(20, row_y - 32), Vector2(20, row_y + 12), sc, 3.0)

		draw_string(font, Vector2(cx[0], row_y), r["name"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)
		draw_string(font, Vector2(cx[1], row_y), status,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, sc)
		draw_string(font, Vector2(cx[2], row_y), "%d" % r["track_ct"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col_hud)

		var le := float(r["last_event_elapsed"])
		var le_str := "%.1f MIN" % (le / 60.0) if le < 60.0 else "%.0f MIN" % (le / 60.0)
		draw_string(font, Vector2(cx[3], row_y), le_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)

		# Threat mini-bar
		var threat := float(r["threat"])
		var bar_col: Color
		if   threat > 0.7: bar_col = _tint(C_DEFCON, a * 0.9)
		elif threat > 0.4: bar_col = _tint(C_AMBER, a * 0.8)
		else:              bar_col = _tint(C_DIM, a * 0.7)
		var bar_w := 130.0
		draw_rect(Rect2(cx[4], row_y - 13, bar_w, 10),
			_tint(C_DIM, a * 0.2), true)
		draw_rect(Rect2(cx[4], row_y - 13, bar_w * threat, 10),
			bar_col, true)
		draw_rect(Rect2(cx[4], row_y - 13, bar_w, 10),
			_tint(C_DIM, a * 0.4), false, 0.6)

		_draw_hline(20, _w - 20, row_y + 14, col_dim, 0.25)

	# ── Event log ─────────────────────────────────────────────────────────────
	var elog_y := oy + 458.0
	_draw_hline(20, _w - 20, elog_y, col_dim, 0.7)
	_draw_section_header(elog_y + 28, "EVENT LOG", a)

	var vis := mini(_events.size(), 6)
	for ei in vis:
		var fade_a := a * maxf(0.15, 1.0 - ei * 0.14)
		# Newest event gets a leading chevron
		var prefix := "> " if ei == 0 else "  "
		draw_string(font, Vector2(24, elog_y + 52 + ei * 40),
			prefix + _events[ei], HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			_tint(C_HUD, fade_a))

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 2 — Active Track Table + Selected Track Detail
# ─────────────────────────────────────────────────────────────────────────────

func _draw_panel2(a: float, elapsed: float) -> void:
	var font     := ThemeDB.fallback_font
	var col      := _tint(C_PRIME, a)
	var col_dim  := _tint(C_DIM,   a)
	var col_hud  := _tint(C_HUD,   a)
	var col_amb  := _tint(C_AMBER, a)
	var col_def  := _tint(C_DEFCON, a)

	var oy := P2Y

	var live_ct := 0; var acq_ct := 0
	for t in _tracks:
		if   t["state"] == "LIVE":      live_ct += 1
		elif t["state"] == "ACQUIRING": acq_ct  += 1

	_draw_section_header(oy + 34,
		"ACTIVE TRACKS  [%02d LIVE  /  %02d ACQUIRING]" % [live_ct, acq_ct], a)
	_draw_hline(20, _w - 20, oy + 46, col_dim, 0.7)

	var cx := [28.0, 96.0, 176.0, 286.0, 386.0, 474.0, 600.0, 690.0]
	var hdrs := ["TRACK", "SRC", "SPD", "ALT", "HDG", "CONF", "STATE", ""]
	for ci in hdrs.size():
		draw_string(font, Vector2(cx[ci], oy + 70),
			hdrs[ci], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)
	_draw_hline(20, _w - 20, oy + 76, col_dim, 0.4)

	var acq_anim: String = ["ACQR..", "ACQR...", "ACQR...."][int(fmod(elapsed, 0.9) / 0.3)]

	var max_rows := mini(_tracks.size(), 9)
	for ti in max_rows:
		var t     = _tracks[ti]
		var row_y := oy + 102.0 + ti * 43.0

		if ti == _selected_track_idx:
			draw_rect(Rect2(20, row_y - 17, _w - 40, 27),
				_tint(Color(0.0, 0.5, 0.2, 0.10), a))

		var state : String = t["state"]
		var sc : Color
		if   state == "LIVE":      sc = col_hud
		elif state == "ACQUIRING": sc = col_amb
		else:                      sc = col_dim

		var state_str := acq_anim if state == "ACQUIRING" else \
						 ("FADING" if state == "FADING" else "LIVE")

		draw_string(font, Vector2(cx[0], row_y), t["id"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		draw_string(font, Vector2(cx[1], row_y), t["src"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
		draw_string(font, Vector2(cx[2], row_y), "%d" % t["spd"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_hud)
		draw_string(font, Vector2(cx[3], row_y), "%d KM" % t["alt"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_hud)

		# Heading with compass glyph
		var hdg := int(t["hdg"])
		var hdg_glyph := _hdg_glyph(hdg)
		draw_string(font, Vector2(cx[4], row_y), "%d°%s" % [hdg, hdg_glyph],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)

		draw_string(font, Vector2(cx[5], row_y), "%d%%" % t["conf"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
		draw_string(font, Vector2(cx[6], row_y), state_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, sc)

		# Confidence mini-bar
		var conf_f := float(int(t["conf"])) / 100.0
		var conf_col: Color
		if   conf_f > 0.75: conf_col = _tint(C_HUD, a * 0.85)
		elif conf_f > 0.50: conf_col = _tint(C_AMBER, a * 0.8)
		else:               conf_col = _tint(C_DEFCON, a * 0.75)
		var bar_x: float = cx[7]
		draw_rect(Rect2(bar_x, row_y - 12, 90, 7), _tint(C_DIM, a * 0.2), true)
		draw_rect(Rect2(bar_x, row_y - 12, 90 * conf_f, 7), conf_col, true)
		draw_rect(Rect2(bar_x, row_y - 12, 90, 7), _tint(C_DIM, a * 0.35), false, 0.5)

	# ── Selected track detail ─────────────────────────────────────────────────
	var det_y := oy + 494.0
	_draw_hline(20, _w - 20, det_y, col_dim, 0.7)

	if _selected_track_idx >= 0:
		var st = _tracks[_selected_track_idx]
		draw_string(font, Vector2(24, det_y + 28),
			"SELECTED: TRACK %s  ──  HIGHEST CONFIDENCE" % st["id"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
		draw_string(font, Vector2(24, det_y + 56),
			"CLASS: UNKNOWN VECTOR        ORIGIN: %s" % st["region"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
		draw_string(font, Vector2(24, det_y + 84),
			"SPD: %d KM/H   ALT: %d KM   HDG: %d°" % [st["spd"], st["alt"], st["hdg"]],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_hud)
		var imp := maxf(0.0, float(st["impact_t"]))
		var imm := int(imp / 60.0)
		var ims := int(imp) % 60
		draw_string(font, Vector2(24, det_y + 112),
			"IMPACT WINDOW: T-%02d:%02d       CONF: %d%%" % [imm, ims, st["conf"]],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_def)

		# Impact countdown bar
		var max_imp := 1200.0
		var imp_f := clampf(imp / max_imp, 0.0, 1.0)
		var imp_bar_col := C_DEFCON if imp_f < 0.3 else (C_AMBER if imp_f < 0.6 else C_HUD)
		_draw_bar(Rect2(24, det_y + 132, _w - 48, 12), imp_f, imp_bar_col, a * 0.8)

		# Track detail: heading dial
		_draw_hdg_dial(Vector2(_w - 80, det_y + 84), 50.0, int(st["hdg"]), a)
	else:
		draw_string(font, Vector2(24, det_y + 28),
			"NO LIVE TRACK SELECTED", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col_dim)

# ─────────────────────────────────────────────────────────────────────────────
#  Panel 3 — Telemetry + System Health + Relay Network + Ticker
# ─────────────────────────────────────────────────────────────────────────────

func _draw_panel3(a: float, elapsed: float) -> void:
	var font    := ThemeDB.fallback_font
	var col     := _tint(C_PRIME, a)
	var col_dim := _tint(C_DIM,   a)
	var col_hud := _tint(C_HUD,   a)
	var col_cyn := _tint(C_CYAN,  a)

	var oy := P3Y

	_draw_section_header(oy + 34, "SENSOR TELEMETRY", a)
	_draw_hline(20, _w - 20, oy + 46, col_dim, 0.7)

	var charts := [
		{"data": _telem_signal, "label": "SIGNAL STRENGTH",  "col": C_CYAN},
		{"data": _telem_radar,  "label": "RADAR RETURN",     "col": C_HUD},
		{"data": _telem_uplink, "label": "UPLINK INTEGRITY", "col": C_PRIME},
	]
	var chart_colors := [col_cyn, col_hud, col]
	for ci in charts.size():
		var cc  = charts[ci]
		var ccol: Color = chart_colors[ci]
		var cx  := 20.0
		var cy  := oy + 64.0 + ci * 108.0
		var cw  := 218.0
		var ch  := 86.0
		_draw_box(cx, cy, cw, ch, col_dim, 0.6)
		_draw_chart_area(Rect2(cx + 2, cy + 2, cw - 4, ch - 4), cc["data"], ccol, _telem_head)
		_draw_mini_chart(Rect2(cx + 2, cy + 2, cw - 4, ch - 4), cc["data"], ccol, _telem_head)

		draw_string(font, Vector2(cx + cw + 14, cy + 20), cc["label"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)
		var arr : Array = cc["data"]
		var cur := float(arr[(_telem_head - 1 + TELEM_BUF) % TELEM_BUF]) * 100.0
		var avg := 0.0
		for v in arr:
			avg += float(v)
		avg = avg / arr.size() * 100.0
		draw_string(font, Vector2(cx + cw + 14, cy + 44),
			"CUR: %.0f%%   AVG: %.0f%%" % [cur, avg],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_hud)

		# Sparkline label: live/degraded
		var status_lbl := "NOMINAL" if cur > 60.0 else "DEGRADED"
		var slbl_col   := col_hud if cur > 60.0 else _tint(C_AMBER, a)
		draw_string(font, Vector2(cx + cw + 14, cy + 68),
			status_lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, slbl_col)

	# ── System health bars ────────────────────────────────────────────────────
	var hy0 := oy + 394.0
	_draw_hline(20, _w - 20, hy0, col_dim, 0.7)
	_draw_section_header(hy0 + 28, "SYSTEM HEALTH", a)

	var health := [
		{"label": "PROCESSOR", "val": 0.82, "note": "TEMP: 43.1°C"},
		{"label": "MEMORY",    "val": 0.61, "note": "DISK: OK"},
		{"label": "NET BUS",   "val": 0.94, "note": "QUEUE: NOMINAL"},
	]
	for hi in health.size():
		var hr = health[hi]
		var hy := hy0 + 52.0 + hi * 52.0
		draw_string(font, Vector2(24, hy), hr["label"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_dim)
		_draw_bar(Rect2(148, hy - 16, 290, 18), hr["val"], C_PRIME, a)
		draw_string(font, Vector2(450, hy), "%.0f%%" % (float(hr["val"]) * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col_hud)
		draw_string(font, Vector2(520, hy), hr["note"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col_dim)

	# ── Relay network diagram ─────────────────────────────────────────────────
	var rn_y := oy + 563.0
	_draw_hline(20, _w - 20, rn_y, col_dim, 0.7)
	_draw_section_header(rn_y + 22, "NETWORK RELAY MAP", a)
	_draw_relay_network(Rect2(30, rn_y + 32, _w - 60, 108), elapsed, a)

	# ── Footer ────────────────────────────────────────────────────────────────
	var fy := oy + PH - 50.0
	_draw_hline(20, _w - 20, fy, col_dim, 0.5)
	draw_string(font, Vector2(24, fy + 20),
		"SCR-NSBD │ PHOSPHOR SIM ENABLED │ BUILD: 0.9.1",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col_dim)

	# ── Scrolling ticker ──────────────────────────────────────────────────────
	var ticker_y := oy + PH - 16.0
	_draw_hline(0, _w, ticker_y - 14, _tint(C_DIM, a * 0.4), 0.5)
	var font_sz  := 12
	var str_w    := ThemeDB.fallback_font.get_string_size(
		TICKER_FULL, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz).x
	var tick_x   := fmod(elapsed * TICKER_SPEED, str_w + _w)
	var tx       := _w - tick_x
	draw_string(font, Vector2(tx, ticker_y),
		TICKER_FULL, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, _tint(C_DIM, a * 0.7))
	draw_string(font, Vector2(tx + str_w, ticker_y),
		TICKER_FULL, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, _tint(C_DIM, a * 0.7))

# ─────────────────────────────────────────────────────────────────────────────
#  Animated radar sweep
# ─────────────────────────────────────────────────────────────────────────────

func _draw_radar(cx: float, cy: float, radius: float, elapsed: float, a: float) -> void:
	var sweep_angle := fmod(elapsed * 0.65, 1.0) * TAU   # ~1 rev / 9.7 sec

	# Concentric range rings
	for ri in 4:
		var r := radius * float(ri + 1) / 4.0
		draw_arc(Vector2(cx, cy), r, 0.0, TAU, 72,
			_tint(C_DIM, a * 0.35), 0.7, true)

	# Cardinal cross hairs
	draw_line(Vector2(cx - radius, cy), Vector2(cx + radius, cy), _tint(C_DIM, a * 0.4), 0.7)
	draw_line(Vector2(cx, cy - radius), Vector2(cx, cy + radius), _tint(C_DIM, a * 0.4), 0.7)
	# Diagonal cross (lighter)
	var d := radius * 0.707
	draw_line(Vector2(cx - d, cy - d), Vector2(cx + d, cy + d), _tint(C_DIM, a * 0.18), 0.5)
	draw_line(Vector2(cx + d, cy - d), Vector2(cx - d, cy + d), _tint(C_DIM, a * 0.18), 0.5)

	# Outer ring
	draw_arc(Vector2(cx, cy), radius, 0.0, TAU, 96,
		_tint(C_DIM, a * 0.65), 1.0, true)

	# Sweep sector (filled fan fading from arm backward)
	var sector_span := 0.42   # radians of fade trail
	var fan_steps   := 28
	var fan_pts     := PackedVector2Array()
	var fan_cols    := PackedColorArray()
	fan_pts.push_back(Vector2(cx, cy))
	fan_cols.push_back(_tint(C_HUD, a * 0.0))
	for si in fan_steps + 1:
		var frac := float(si) / float(fan_steps)
		var ang  := sweep_angle - frac * sector_span
		fan_pts.push_back(Vector2(cx + cos(ang) * radius, cy + sin(ang) * radius))
		fan_cols.push_back(_tint(C_HUD, a * (1.0 - frac) * 0.22))
	draw_polygon(fan_pts, fan_cols)

	# Sweep arm
	draw_line(Vector2(cx, cy),
		Vector2(cx + cos(sweep_angle) * radius, cy + sin(sweep_angle) * radius),
		_tint(C_HUD, a * 0.90), 1.8)

	# Blips — fade based on angular proximity to sweep arm
	for b in _radar_blips:
		var ang  := float(b["angle"])
		var dist := float(b["dist"]) * radius
		var bx   := cx + cos(ang) * dist
		var by_  := cy + sin(ang) * dist

		var diff := fmod(sweep_angle - ang + TAU * 2.0, TAU)
		# diff=0 means arm just passed; fade away as diff grows
		var raw_fade := 1.0 - diff / (TAU * 0.5)
		var fade := clampf(raw_fade, 0.0, 1.0)
		if fade < 0.02:
			continue
		var ba := a * (0.25 + fade * 0.75)
		# Outer echo ring
		draw_arc(Vector2(bx, by_), 6.0, 0.0, TAU, 16,
			_tint(C_PRIME, ba * 0.4), 0.7, true)
		draw_circle(Vector2(bx, by_), 3.0, _tint(C_PRIME, ba))
		draw_string(ThemeDB.fallback_font, Vector2(bx + 7, by_ + 5),
			b["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, ba * 0.85))

	# Compass cardinal labels
	var compass_dirs := [["N", 0.0, -1.0], ["E", 1.0, 0.0], ["S", 0.0, 1.0], ["W", -1.0, 0.0]]
	for cd in compass_dirs:
		draw_string(ThemeDB.fallback_font,
			Vector2(cx + float(cd[1]) * (radius + 12) - 4,
					cy + float(cd[2]) * (radius + 18) + 5),
			cd[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, a * 0.55))

	# Range labels
	draw_string(ThemeDB.fallback_font,
		Vector2(cx + 4, cy - radius * 0.75 + 5),
		"2500", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, _tint(C_DIM, a * 0.4))
	draw_string(ThemeDB.fallback_font,
		Vector2(cx + 4, cy - radius * 0.5 + 5),
		"5000", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, _tint(C_DIM, a * 0.4))

# ─────────────────────────────────────────────────────────────────────────────
#  Relay network diagram
# ─────────────────────────────────────────────────────────────────────────────

func _draw_relay_network(rect: Rect2, elapsed: float, a: float) -> void:
	var font := ThemeDB.fallback_font

	# Compute node screen positions
	var positions : Array = []
	for nd in _relay_nodes:
		positions.append(rect.position + Vector2(
			float(nd["nx"]) * rect.size.x,
			float(nd["ny"]) * rect.size.y))

	# Draw edges
	for ei in RELAY_EDGES.size():
		var e   = RELAY_EDGES[ei]
		if e[0] >= positions.size() or e[1] >= positions.size():
			continue
		var pa  : Vector2 = positions[e[0]]
		var pb  : Vector2 = positions[e[1]]
		var n0  = _relay_nodes[e[0]]
		var n1  = _relay_nodes[e[1]]
		var both := bool(n0["active"]) and bool(n1["active"])
		var lc  := _tint(C_HUD, a * 0.28) if both else _tint(C_DIM, a * 0.15)
		draw_line(pa, pb, lc, 0.8)

		# Animated data-packet dot traversing the edge
		if both:
			var phase := float(n0["flash_phase"]) + float(ei) * 0.37
			var t_fwd := fmod(elapsed * 0.35 + phase, 1.0)
			var dp    := pa.lerp(pb, t_fwd)
			draw_circle(dp, 2.2, _tint(C_PRIME, a * 0.75))

	# Draw nodes
	for ni in _relay_nodes.size():
		if ni >= positions.size():
			continue
		var nd  = _relay_nodes[ni]
		var pos : Vector2 = positions[ni]
		var active := bool(nd["active"])
		var fp     := float(nd["flash_phase"])
		var pulse  := sin(elapsed * 2.1 + fp * TAU) * 0.5 + 0.5
		var nc : Color
		if active:
			nc = _tint(C_HUD, a * (0.55 + pulse * 0.45))
		else:
			nc = _tint(C_DIM, a * 0.25)
		draw_circle(pos, 5.5, nc)
		draw_arc(pos, 9.0, 0.0, TAU, 24, _tint(C_DIM, a * 0.38), 0.7, true)
		if active:
			draw_arc(pos, 13.0, 0.0, TAU, 24, _tint(C_HUD, a * pulse * 0.18), 0.5, true)
		draw_string(font, pos + Vector2(-22, 20),
			nd["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, a * 0.65))

# ─────────────────────────────────────────────────────────────────────────────
#  Drawing helpers
# ─────────────────────────────────────────────────────────────────────────────

func _draw_scanlines(a: float) -> void:
	var col := _tint(C_SCAN, a)
	var y := 0.0
	while y < _h:
		draw_line(Vector2(0.0, y), Vector2(_w, y), col, 1.0)
		y += 5.0

func _draw_panel_separators(a: float) -> void:
	var col     := _tint(C_DIM, a * 0.6)
	var col_dim := _tint(C_DIM, a * 0.3)
	for panel_y in [P1Y, P2Y, P3Y]:
		_draw_hline(0, _w, panel_y, col, 1.2)
		# Tick marks
		var tick_x := 0.0
		while tick_x <= _w:
			var tick_h := 6.0 if fmod(tick_x, 64.0) < 1.0 else 3.0
			draw_line(Vector2(tick_x, panel_y - tick_h),
					  Vector2(tick_x, panel_y),
					  col_dim, 0.8)
			tick_x += 32.0
		# Panel index label
		var pidx := int((panel_y - P0Y) / PH)
		draw_string(ThemeDB.fallback_font,
			Vector2(_w - 56, panel_y + 16),
			"P-%d" % pidx,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, a * 0.4))

func _draw_alert_border(a: float, elapsed: float) -> void:
	if _condition > 2:
		return
	var flash := 1.0 if fmod(elapsed, 0.6) < 0.38 else 0.0
	if flash < 0.5:
		return
	var col := _tint(C_DEFCON, a * 0.55)
	var m   := 4.0
	draw_rect(Rect2(m, m, _w - m * 2, _h - m * 2), col, false, 1.5)

func _draw_box(x: float, y: float, w: float, h: float, col: Color, lw: float) -> void:
	draw_rect(Rect2(x, y, w, h), col, false, lw)

func _draw_hline(x1: float, x2: float, y: float, col: Color, lw: float) -> void:
	draw_line(Vector2(x1, y), Vector2(x2, y), col, lw)

func _draw_section_header(y: float, title: String, a: float) -> void:
	draw_string(ThemeDB.fallback_font, Vector2(24, y),
		title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, _tint(C_PRIME, a))

func _draw_mini_chart(rect: Rect2, data: Array, col: Color, head: int) -> void:
	if data.size() < 2:
		return
	var n   := data.size()
	var pts := PackedVector2Array()
	for i in n:
		var idx := (head + i) % n
		var vv  := float(data[idx])
		var px  := rect.position.x + (float(i) / float(n - 1)) * rect.size.x
		var py  := rect.position.y + rect.size.y * (1.0 - vv)
		pts.push_back(Vector2(px, py))
	draw_polyline(pts, col, 1.2, true)

func _draw_chart_area(rect: Rect2, data: Array, col: Color, head: int) -> void:
	if data.size() < 2:
		return
	var n      := data.size()
	var bottom := rect.position.y + rect.size.y
	var pts    := PackedVector2Array()
	var cols   := PackedColorArray()

	for i in n:
		var idx := (head + i) % n
		var vv  := float(data[idx])
		var px  := rect.position.x + (float(i) / float(n - 1)) * rect.size.x
		var py  := rect.position.y + rect.size.y * (1.0 - vv)
		pts.push_back(Vector2(px, py))
		cols.push_back(Color(col.r, col.g, col.b, col.a * 0.28 * (float(i) / float(n))))

	# Bottom-right then bottom-left to close the polygon
	pts.push_back(Vector2(rect.position.x + rect.size.x, bottom))
	cols.push_back(Color(col.r, col.g, col.b, 0.0))
	pts.push_back(Vector2(rect.position.x, bottom))
	cols.push_back(Color(col.r, col.g, col.b, 0.0))

	draw_polygon(pts, cols)

func _draw_bar(rect: Rect2, fill: float, base_col: Color, a: float) -> void:
	draw_rect(rect, _tint(Color(base_col.r, base_col.g, base_col.b, 0.12), a), true)
	var fw := rect.size.x * clampf(fill, 0.0, 1.0)
	draw_rect(Rect2(rect.position, Vector2(fw, rect.size.y)),
		_tint(base_col, a * 0.65), true)
	draw_rect(rect, _tint(base_col, a * 0.35), false, 0.7)

func _draw_corner_brackets(a: float) -> void:
	var col := _tint(C_DIM, a * 0.7)
	var m := 18.0; var bl := 38.0; var bw := 1.6
	var w := _w;   var h  := _h
	draw_line(Vector2(m, m),         Vector2(m + bl, m),         col, bw)
	draw_line(Vector2(m, m),         Vector2(m, m + bl),         col, bw)
	draw_line(Vector2(w - m, m),     Vector2(w - m - bl, m),     col, bw)
	draw_line(Vector2(w - m, m),     Vector2(w - m, m + bl),     col, bw)
	draw_line(Vector2(m, h - m),     Vector2(m + bl, h - m),     col, bw)
	draw_line(Vector2(m, h - m),     Vector2(m, h - m - bl),     col, bw)
	draw_line(Vector2(w - m, h - m), Vector2(w - m - bl, h - m), col, bw)
	draw_line(Vector2(w - m, h - m), Vector2(w - m, h - m - bl), col, bw)

	# Per-panel corner brackets (inner, smaller)
	var sm := 10.0; var sbl := 22.0
	for py in [P1Y, P2Y, P3Y]:
		draw_line(Vector2(sm, py + sm),      Vector2(sm + sbl, py + sm),      col, 0.8)
		draw_line(Vector2(sm, py + sm),      Vector2(sm, py + sm + sbl),      col, 0.8)
		draw_line(Vector2(w - sm, py + sm),  Vector2(w - sm - sbl, py + sm),  col, 0.8)
		draw_line(Vector2(w - sm, py + sm),  Vector2(w - sm, py + sm + sbl),  col, 0.8)

func _draw_hdg_dial(center: Vector2, radius: float, hdg: int, a: float) -> void:
	draw_arc(center, radius, 0.0, TAU, 48, _tint(C_DIM, a * 0.45), 0.8, true)
	var ang := deg_to_rad(float(hdg) - 90.0)
	draw_line(center, center + Vector2(cos(ang), sin(ang)) * radius * 0.85,
		_tint(C_HUD, a * 0.85), 1.5)
	draw_circle(center, 2.5, _tint(C_DIM, a * 0.6))
	draw_string(ThemeDB.fallback_font, center + Vector2(-8, radius + 14),
		"%d°" % hdg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _tint(C_DIM, a * 0.55))

func _hdg_glyph(hdg: int) -> String:
	var sector := int((hdg + 22) / 45) % 8
	match sector:
		0: return "N"
		1: return "NE"
		2: return "E"
		3: return "SE"
		4: return "S"
		5: return "SW"
		6: return "W"
		_: return "NW"

func _tint(c: Color, alpha_scale: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha_scale)
