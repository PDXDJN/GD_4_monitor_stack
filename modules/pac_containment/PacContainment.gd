## PacContainment — retro "particle containment field" visualization.
## Each panel shows a pulsing containment boundary with status readouts.
## Cross-panel containment threads travel via VirtualSpace math.
extends Node2D

var module_id := "pac_containment"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false
var _winding_down := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 2.0

# Palette: orange/amber "warning" theme
const COLOR_FIELD    := Color(1.0,  0.55, 0.0,  0.8)
const COLOR_FIELD_DIM := Color(1.0, 0.35, 0.0,  0.3)
const COLOR_ALERT    := Color(1.0,  0.9,  0.0,  0.9)
const COLOR_STABLE   := Color(0.0,  1.0,  0.6,  0.7)
const COLOR_BG_GRID  := Color(0.6,  0.2,  0.0,  0.12)

# Per-panel state
var _panels: Array[Dictionary] = []

# Cross-panel containment threads
const MAX_THREADS := 3
var _threads: Array[Dictionary] = []

var _station_pulse := 0.0  # drives sin-wave effects

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
	_station_pulse = 0.0
	_init_panels()
	_init_threads()

func _init_panels() -> void:
	_panels.clear()
	var statuses := ["NOMINAL", "NOMINAL", "STABLE", "MONITORING"]
	for p in _virtual_space.panel_count:
		_panels.append({
			"index":          p,
			"status":         statuses[p % statuses.size()],
			"field_strength": module_rng.randf_range(0.72, 1.0),
			"pulse_offset":   module_rng.randf() * TAU,
			"leak_timer":     module_rng.randf_range(4.0, 9.0),
			"leak_active":    false,
			"leak_pos":       Vector2.ZERO,
		})

func _init_threads() -> void:
	_threads.clear()
	for _i in MAX_THREADS:
		_threads.append(_make_thread())

func _make_thread() -> Dictionary:
	var virt_h := _virtual_space.virtual_height()
	return {
		"virtual_y": module_rng.randf_range(-150.0, virt_h),
		"speed":     module_rng.randf_range(90.0, 220.0),
		"x":         module_rng.randf_range(60.0, float(_virtual_space.panel_width) - 60.0),
		"width":     module_rng.randf_range(1.2, 2.8),
		"alpha":     module_rng.randf_range(0.3, 0.65),
	}

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true
		queue_redraw()
		return

	_station_pulse += delta

	# Update per-panel leak state
	for panel_data in _panels:
		panel_data["leak_timer"] -= delta
		if panel_data["leak_timer"] <= 0.0:
			panel_data["leak_active"] = not panel_data["leak_active"]
			if panel_data["leak_active"]:
				panel_data["status"]     = "WARNING"
				panel_data["leak_timer"] = module_rng.randf_range(1.5, 3.5)
				var rect := _panel_layout.get_panel_rect(panel_data["index"])
				panel_data["leak_pos"] = Vector2(
					module_rng.randf_range(rect.position.x + 28.0, rect.end.x - 28.0),
					module_rng.randf_range(rect.position.y + 28.0, rect.end.y - 28.0),
				)
			else:
				panel_data["status"]     = "NOMINAL"
				panel_data["leak_timer"] = module_rng.randf_range(4.0, 10.0)

	# Advance cross-panel threads in virtual space
	var virt_h := _virtual_space.virtual_height()
	for thread in _threads:
		thread["virtual_y"] += thread["speed"] * delta
		if thread["virtual_y"] > virt_h + 120.0:
			thread["virtual_y"] = -120.0
			thread["x"] = module_rng.randf_range(60.0, float(_virtual_space.panel_width) - 60.0)

	queue_redraw()

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha_scale := 1.0
	if _winding_down:
		alpha_scale = clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)

	var pw := float(_virtual_space.panel_width)
	var ph := float(_virtual_space.PANEL_H)

	for panel_data in _panels:
		_draw_panel_field(panel_data, alpha_scale, pw, ph)

	for thread in _threads:
		_draw_thread(thread, alpha_scale)

func _draw_panel_field(panel_data: Dictionary, alpha_scale: float, pw: float, ph: float) -> void:
	var p      := panel_data["index"]
	var rect   := _panel_layout.get_panel_rect(p)
	var ry     := rect.position.y
	var pulse  := sin(_station_pulse * 1.8 + float(panel_data["pulse_offset"])) * 0.5 + 0.5

	# Subtle background dot grid
	var bg_col  := Color(COLOR_BG_GRID.r, COLOR_BG_GRID.g, COLOR_BG_GRID.b, COLOR_BG_GRID.a * alpha_scale)
	var spacing := 40.0
	var cols    := int(pw / spacing) + 1
	var rows    := int(ph / spacing) + 1
	for row in rows:
		for col_i in cols:
			var ox := 0.0 if row % 2 == 0 else spacing * 0.5
			draw_circle(Vector2(col_i * spacing + ox, ry + row * spacing), 1.5, bg_col)

	# Main containment field rect (pulsing border)
	var margin     := 24.0
	var field_rect := Rect2(
		rect.position + Vector2(margin, margin),
		rect.size - Vector2(margin * 2.0, margin * 2.0),
	)
	var field_alpha := (0.38 + pulse * 0.42) * alpha_scale * float(panel_data["field_strength"])
	draw_rect(field_rect, Color(COLOR_FIELD.r, COLOR_FIELD.g, COLOR_FIELD.b, field_alpha), false,
			1.5 + pulse * 0.6)

	# Corner markers
	var mk_col := Color(COLOR_FIELD.r, COLOR_FIELD.g, COLOR_FIELD.b, 0.7 * alpha_scale)
	var clen   := 16.0
	_draw_corner(field_rect.position,                              Vector2( 1.0,  1.0), clen, mk_col)
	_draw_corner(field_rect.position + Vector2(field_rect.size.x, 0.0),  Vector2(-1.0,  1.0), clen, mk_col)
	_draw_corner(field_rect.position + Vector2(0.0, field_rect.size.y),  Vector2( 1.0, -1.0), clen, mk_col)
	_draw_corner(field_rect.end,                                   Vector2(-1.0, -1.0), clen, mk_col)

	# Status label
	var font       := ThemeDB.fallback_font
	var status     : String = panel_data["status"]
	var status_col : Color
	if status == "NOMINAL" or status == "STABLE":
		status_col = Color(COLOR_STABLE.r, COLOR_STABLE.g, COLOR_STABLE.b, 0.8 * alpha_scale)
	else:
		var blink := 1.0 if fmod(_station_pulse * 2.0, 1.0) < 0.6 else 0.0
		status_col = Color(COLOR_ALERT.r, COLOR_ALERT.g, COLOR_ALERT.b, blink * alpha_scale)

	draw_string(font, Vector2(margin + 6.0, ry + margin + 22.0),
			"PANEL %d — %s" % [p, status],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, status_col)

	# Field strength bar
	var bar_y  := ry + ph - margin - 10.0
	var bar_w  := pw - margin * 2.0
	draw_rect(Rect2(Vector2(margin, bar_y), Vector2(bar_w, 6.0)),
			Color(COLOR_FIELD_DIM.r, COLOR_FIELD_DIM.g, COLOR_FIELD_DIM.b, 0.3 * alpha_scale), true)

	var fill_w := bar_w * float(panel_data["field_strength"]) * (0.85 + pulse * 0.15)
	draw_rect(Rect2(Vector2(margin, bar_y), Vector2(fill_w, 6.0)),
			Color(COLOR_FIELD.r, COLOR_FIELD.g, COLOR_FIELD.b, 0.55 * alpha_scale), true)

	draw_string(font, Vector2(margin, bar_y - 14.0),
			"FIELD  %.0f%%" % (float(panel_data["field_strength"]) * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			Color(COLOR_FIELD_DIM.r + 0.3, COLOR_FIELD_DIM.g + 0.1, COLOR_FIELD_DIM.b, 0.7 * alpha_scale))

	# Leak indicator
	if panel_data["leak_active"] and fmod(_station_pulse * 4.0, 1.0) < 0.55:
		var lp       : Vector2 = panel_data["leak_pos"]
		var leak_col := Color(COLOR_ALERT.r, COLOR_ALERT.g, COLOR_ALERT.b, 0.9 * alpha_scale)
		draw_circle(lp, 5.0, leak_col)
		draw_arc(lp, 13.0, 0.0, TAU, 16, leak_col, 1.2, true)
		draw_string(font, lp + Vector2(18.0, 5.0), "LEAK",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(COLOR_ALERT.r, COLOR_ALERT.g, COLOR_ALERT.b, 0.8 * alpha_scale))

func _draw_corner(pos: Vector2, dir: Vector2, length: float, color: Color) -> void:
	draw_line(pos, pos + Vector2(dir.x * length, 0.0), color, 1.5)
	draw_line(pos, pos + Vector2(0.0, dir.y * length), color, 1.5)

func _draw_thread(thread: Dictionary, alpha_scale: float) -> void:
	# Draw a vertical containment thread that travels through virtual space.
	# Segments that pass through bezel gaps are automatically hidden.
	var x          := float(thread["x"])
	var vy         := float(thread["virtual_y"])
	var thread_len := 90.0
	var steps      := 24

	for i in steps:
		var t        := float(i) / float(steps - 1)
		var char_vy  := vy - t * thread_len
		if char_vy < 0.0:
			continue

		var mapping := _virtual_space.virtual_to_real(char_vy)
		if not mapping["visible"]:
			continue

		var real_y    : float = mapping["real_y"]
		var seg_alpha := (1.0 - t) * float(thread["alpha"]) * alpha_scale
		var col       := Color(COLOR_FIELD.r, COLOR_FIELD.g, COLOR_FIELD.b, seg_alpha)
		draw_circle(Vector2(x, real_y), float(thread["width"]) + (1.0 if i == 0 else 0.0), col)

func module_status() -> Dictionary:
	var warnings := 0
	for pd in _panels:
		if (pd["status"] as String) == "WARNING":
			warnings += 1
	return {
		"ok":       warnings == 0,
		"notes":    "%d nominal, %d warning" % [_panels.size() - warnings, warnings],
		"intensity": 0.65,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down = true
	_wind_down_timer = 0.0
	Logger.debug("PacContainment: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_panels.clear()
	_threads.clear()
