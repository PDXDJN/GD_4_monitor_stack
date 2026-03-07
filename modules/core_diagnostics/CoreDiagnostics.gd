## CoreDiagnostics — multi-mode display calibration scene.
## Cycles through: grid → labels → edge_walk via manifest sequence.
## Uses VirtualSpace segments to highlight live panel areas.
extends Node2D

var module_id := "core_diagnostics"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false
var _winding_down := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 1.5

# Current display mode — changed via set_mode() from the manifest sequence
var _mode := "grid"
var _edge_pos := 0.0   # 0..1, traces entire perimeter of all panels

const COLOR_PRIMARY  := Color(0.0, 0.9, 1.0, 0.9)   # cyan
const COLOR_DIM      := Color(0.0, 0.5, 0.6, 0.4)
const COLOR_ACCENT   := Color(1.0, 0.9, 0.0, 0.85)  # yellow
const COLOR_LIVE     := Color(0.0, 1.0, 0.4, 0.7)

func module_configure(ctx: Dictionary) -> void:
	_manifest = ctx["manifest"]
	module_rng = RNG.make_rng(ctx["seed"])
	_panel_layout = ctx["panel_layout"]
	_virtual_space = ctx["virtual_space"]

## Called by Launcher sequence at timed intervals.
func set_mode(m: String) -> void:
	_mode = m
	Log.debug("CoreDiagnostics: mode", {"mode": m})
	queue_redraw()

func module_start() -> void:
	module_started_at = App.station_time
	_stop_requested = false
	_finished = false
	_winding_down = false
	_wind_down_timer = 0.0
	_mode = "grid"
	_edge_pos = 0.0

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true
		queue_redraw()
		return

	if _mode == "edge_walk":
		_edge_pos += delta * 0.15  # full cycle ≈ 6.7 s
		_edge_pos = fmod(_edge_pos, 1.0)

	queue_redraw()

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha := 1.0
	if _winding_down:
		alpha = clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)

	var pc := _virtual_space.panel_count
	var pw := float(_virtual_space.panel_width)

	match _mode:
		"grid":      _draw_grid(alpha, pc, pw)
		"labels":    _draw_labels(alpha, pc, pw)
		"edge_walk": _draw_edge_walk(alpha, pc, pw)

func _draw_grid(alpha: float, panel_count: int, pw: float) -> void:
	var ph      := float(_virtual_space.PANEL_H)
	var spacing := 64.0
	var cols    := int(pw / spacing) + 1
	var rows    := int(ph / spacing) + 1

	for p in panel_count:
		var rect := _panel_layout.get_panel_rect(p)
		var ry   := rect.position.y

		# Panel border
		var border_col := Color(COLOR_PRIMARY.r, COLOR_PRIMARY.g, COLOR_PRIMARY.b, 0.6 * alpha)
		draw_rect(rect, border_col, false, 1.5)

		# Grid lines
		var grid_col := Color(COLOR_DIM.r, COLOR_DIM.g, COLOR_DIM.b, 0.5 * alpha)
		for c in cols:
			var x := c * spacing
			if x >= pw:
				break
			draw_line(Vector2(x, ry), Vector2(x, ry + ph), grid_col, 0.5)
		for r in rows:
			var y := ry + r * spacing
			if y >= ry + ph:
				break
			draw_line(Vector2(0.0, y), Vector2(pw, y), grid_col, 0.5)

		# Center crosshair
		var cx := pw * 0.5
		var cy := ry + ph * 0.5
		var cross_col := Color(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 0.5 * alpha)
		draw_line(Vector2(cx - 20.0, cy), Vector2(cx + 20.0, cy), cross_col, 1.0)
		draw_line(Vector2(cx, cy - 20.0), Vector2(cx, cy + 20.0), cross_col, 1.0)
		draw_circle(Vector2(cx, cy), 3.0, cross_col)

func _draw_labels(alpha: float, panel_count: int, pw: float) -> void:
	var ph   := float(_virtual_space.PANEL_H)
	var font := ThemeDB.fallback_font

	for p in panel_count:
		var rect := _panel_layout.get_panel_rect(p)
		var ry   := rect.position.y

		# Panel border
		var border_col := Color(COLOR_PRIMARY.r, COLOR_PRIMARY.g, COLOR_PRIMARY.b, 0.45 * alpha)
		draw_rect(rect, border_col, false, 1.0)

		# Panel label
		var label_col := Color(COLOR_PRIMARY.r, COLOR_PRIMARY.g, COLOR_PRIMARY.b, 0.9 * alpha)
		draw_string(font, Vector2(12.0, ry + 30.0),
				"PANEL %d" % p, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, label_col)

		# Real Y range
		var coord_col := Color(COLOR_DIM.r, COLOR_DIM.g, COLOR_DIM.b, 0.8 * alpha)
		draw_string(font, Vector2(12.0, ry + 58.0),
				"y: %d — %d  |  %dpx" % [int(ry), int(ry + ph), int(ph)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, coord_col)

		# Virtual Y range
		var vy_start := _virtual_space.real_to_virtual(p, 0.0)
		var vy_end   := _virtual_space.real_to_virtual(p, ph)
		var vy_col   := Color(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 0.6 * alpha)
		draw_string(font, Vector2(12.0, ry + 80.0),
				"virtual y: %.0f — %.0f" % [vy_start, vy_end],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, vy_col)

		# LIVE marker (bottom-right)
		var live_col := Color(COLOR_LIVE.r, COLOR_LIVE.g, COLOR_LIVE.b, 0.75 * alpha)
		draw_string(font, Vector2(pw - 86.0, ry + ph - 14.0),
				"▶ LIVE", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, live_col)

		# Bezel gap note between panels
		if p < panel_count - 1:
			var gap_col := Color(0.7, 0.15, 0.0, 0.4 * alpha)
			draw_string(font, Vector2(12.0, ry + ph + 18.0),
					"╴╴╴ BEZEL GAP %dpx ╶╶╶" % _virtual_space.BEZEL_GAP,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, gap_col)

func _draw_edge_walk(alpha: float, panel_count: int, pw: float) -> void:
	var ph   := float(_virtual_space.PANEL_H)
	var font := ThemeDB.fallback_font

	# Draw dim panel borders
	for p in panel_count:
		var r := _panel_layout.get_panel_rect(p)
		draw_rect(r, Color(COLOR_DIM.r, COLOR_DIM.g, COLOR_DIM.b, 0.3 * alpha), false, 1.0)

	# Compute walker position across all panels (each has its own perimeter)
	var per_panel_perim := 2.0 * (pw + ph)
	var total_perim     := per_panel_perim * panel_count
	var dist            := _edge_pos * total_perim

	var panel_idx  := clampi(int(dist / per_panel_perim), 0, panel_count - 1)
	var local_dist := fmod(dist, per_panel_perim)

	var walker_rect := _panel_layout.get_panel_rect(panel_idx)
	var walker_pos  := _perim_pos(walker_rect, local_dist / per_panel_perim)

	# Walker dot + halo
	var walker_col := Color(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, alpha)
	draw_circle(walker_pos, 6.0, walker_col)
	draw_circle(walker_pos, 11.0, Color(walker_col.r, walker_col.g, walker_col.b, 0.2 * alpha))

	# Trailing dots
	for i in 8:
		var trail_t := _edge_pos - float(i + 1) * 0.005
		if trail_t < 0.0:
			trail_t += 1.0
		var td      := trail_t * total_perim
		var tp_idx  := clampi(int(td / per_panel_perim), 0, panel_count - 1)
		var tl_dist := fmod(td, per_panel_perim)
		var t_rect  := _panel_layout.get_panel_rect(tp_idx)
		var t_pos   := _perim_pos(t_rect, tl_dist / per_panel_perim)
		var t_alpha := (1.0 - float(i) / 8.0) * 0.4 * alpha
		draw_circle(t_pos, 3.5, Color(walker_col.r, walker_col.g, walker_col.b, t_alpha))

	# Panel label near walker
	var lry := walker_rect.position.y
	draw_string(font, Vector2(12.0, lry + 24.0),
			"EDGE WALK — PANEL %d" % panel_idx,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color(COLOR_PRIMARY.r, COLOR_PRIMARY.g, COLOR_PRIMARY.b, 0.6 * alpha))

## Walk around the perimeter of a Rect2. t in [0,1] maps to top→right→bottom→left.
func _perim_pos(rect: Rect2, t: float) -> Vector2:
	var w     := rect.size.x
	var h     := rect.size.y
	var perim := 2.0 * (w + h)
	var d     := t * perim
	if d < w:
		return rect.position + Vector2(d, 0.0)
	d -= w
	if d < h:
		return rect.position + Vector2(w, d)
	d -= h
	if d < w:
		return rect.position + Vector2(w - d, h)
	d -= w
	return rect.position + Vector2(0.0, h - d)

func module_status() -> Dictionary:
	return {"ok": true, "notes": "mode=%s" % _mode, "intensity": 0.3}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down = true
	_wind_down_timer = 0.0
	Log.debug("CoreDiagnostics: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	pass
