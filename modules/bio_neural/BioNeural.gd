## BioNeural — "Bio-Neural Activity Column"
## The station appears to think, hesitate, overload, and occasionally question your decisions.
##
## Pure draw_*() — no external assets.  Directed neural graph with signal pulses
## travelling top-to-bottom through four distinct cognitive zones.
extends Node2D

var module_id          := "bio_neural"
var module_rng:        RandomNumberGenerator
var module_started_at  := 0.0

# ─── Module state ────────────────────────────────────────────────────────────
var _manifest:        Dictionary
var _panel_layout:    PanelLayout
var _virtual_space:   VirtualSpace
var _stop_requested   := false
var _finished         := false
var _winding_down     := false
var _wind_down_timer  := 0.0
const _WIND_DOWN_DUR  := 2.5

var _total_size: Vector2i
var _font:       Font

# ─── Graph ───────────────────────────────────────────────────────────────────
# node: {pos: Vector2, panel: int, blink: float, activity: float}
var _nodes:          Array = []
# edge: {a: int, b: int, weight: float}
var _edges:          Array = []
# per node: Array[int] — indices into _edges for outgoing edges
var _node_out_edges: Array = []

# ─── Pulses ──────────────────────────────────────────────────────────────────
# pulse: {path, seg, t, speed, color, width, trail, mode, alive}
var _pulses:          Array = []
# Per-panel spawn timers and intervals.
# Panel 0 flows downward; panels 1-3 spawn local-only pulses.
var _spawn_timers:    Array = [0.0, 0.0, 0.0, 0.0]
var _spawn_intervals: Array = [0.38, 0.50, 0.55, 0.65]
const MAX_PULSES      := 65
const TRAIL_LEN       := 14

# ─── Rare events ─────────────────────────────────────────────────────────────
var _event_timer    := 0.0
var _event_next     := 0.0        # set in module_start

# Labels: {text, pos, timer, duration, color}
var _labels: Array  = []

# Purge wave
var _purge_active   := false
var _purge_y        := 0.0
const _PURGE_SPEED  := 520.0

# Emergent spike
var _spike_idx      := -1         # index into _pulses
var _spike_timer    := 0.0
var _spike_phase    := "grow"     # grow / hold / collapse

# ─── Palette ─────────────────────────────────────────────────────────────────
const C_CYAN   := Color(0.00, 0.90, 1.00, 0.88)
const C_VIOLET := Color(0.62, 0.22, 1.00, 0.90)
const C_AMBER  := Color(1.00, 0.68, 0.08, 0.90)
const C_RED    := Color(1.00, 0.15, 0.12, 0.92)
const C_EDGE   := Color(0.00, 0.40, 0.55, 0.18)
const C_HUD    := Color(0.20, 1.00, 0.60, 0.75)
const C_PURGE  := Color(0.90, 0.05, 0.25, 0.70)
const C_ZONE   := Color(0.10, 0.65, 0.80, 0.30)

const _ZONE_NAMES := [
	"SIGNAL INTAKE CORTEX",
	"PROCESSING LATTICE",
	"COGNITIVE OVERLOAD ZONE",
	"OUTPUT / SUPPRESSION LAYER",
]

const _ZONE_COLORS := [C_CYAN, C_VIOLET, C_AMBER, C_CYAN]

# ═════════════════════════════════════════════════════════════════════════════
# Module contract
# ═════════════════════════════════════════════════════════════════════════════

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
	_font       = ThemeDB.fallback_font

	_build_graph()
	_pulses.clear()
	_labels.clear()
	_spawn_timers = [0.0, 0.0, 0.0, 0.0]
	_event_timer  = 0.0
	_event_next   = module_rng.randf_range(12.0, 22.0)
	_purge_active = false
	_spike_idx    = -1

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "pulses:%d nodes:%d" % [_pulses.size(), _nodes.size()],
		"intensity": clampf(float(_pulses.size()) / 30.0, 0.0, 1.0),
	}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("BioNeural: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_pulses.clear()
	_labels.clear()

# ═════════════════════════════════════════════════════════════════════════════
# Graph construction
# ═════════════════════════════════════════════════════════════════════════════

func _build_graph() -> void:
	_nodes.clear()
	_edges.clear()
	_node_out_edges.clear()

	var w        := _total_size.x
	var panel_h  := 768
	# Panel 0: sparse intake; Panel 1: dense processing; Panel 2: chaotic; Panel 3: sparse output
	var counts   := [10, 24, 19, 11]
	var radii    := [290.0, 250.0, 230.0, 290.0]  # connection radius per panel
	var max_out  := [3, 4, 3, 2]

	for panel_i in 4:
		var y_base: int = panel_i * panel_h
		for _i in counts[panel_i]:
			_nodes.append({
				pos      = Vector2(
					module_rng.randf_range(65.0, float(w) - 65.0),
					module_rng.randf_range(float(y_base) + 65.0, float(y_base + panel_h) - 65.0)
				),
				panel    = panel_i,
				blink    = module_rng.randf_range(0.0, TAU),
				activity = 0.0,
			})

	for _n in _nodes.size():
		_node_out_edges.append([])

	for i in _nodes.size():
		var ni: Dictionary = _nodes[i]
		var r := float(radii[ni.panel])
		var candidates := []
		for j in _nodes.size():
			if j == i:
				continue
			var nj: Dictionary = _nodes[j]
			var pdiff := int(nj.panel) - int(ni.panel)
			if pdiff < 0 or pdiff > 1:
				continue
			var dist := (ni.pos as Vector2).distance_to(nj.pos as Vector2)
			if dist <= r:
				candidates.append([j, dist])
		candidates.sort_custom(func(a, b): return a[1] < b[1])
		var added := 0
		for ci in candidates:
			if added >= max_out[ni.panel]:
				break
			var j: int = ci[0]
			var eidx := _edges.size()
			_edges.append({a = i, b = j, weight = 0.2})
			_node_out_edges[i].append(eidx)
			added += 1

# ═════════════════════════════════════════════════════════════════════════════
# Update
# ═════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	_update_node_activity(delta)
	_update_pulses(delta)
	_update_spawn(delta)
	_update_rare_events(delta)
	_update_labels(delta)

	if _purge_active:
		_purge_y += _PURGE_SPEED * delta
		if _purge_y > float(_total_size.y) + 50.0:
			_purge_active = false

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true

	queue_redraw()

func _update_node_activity(delta: float) -> void:
	for n in _nodes:
		n.activity = maxf(0.0, n.activity - delta * 0.75)
		n.blink    = fmod(n.blink + delta * (1.0 + n.activity * 3.0), TAU)
	for e in _edges:
		e.weight = maxf(0.15, e.weight - delta * 0.04)

func _update_pulses(delta: float) -> void:
	# Validate spike index
	if _spike_idx >= _pulses.size():
		_spike_idx = -1

	var i := _pulses.size() - 1
	while i >= 0:
		var p: Dictionary = _pulses[i]

		if not p.alive:
			_pulses.remove_at(i)
			if _spike_idx == i:
				_spike_idx = -1
			elif _spike_idx > i:
				_spike_idx -= 1
			i -= 1
			continue

		# Emergent spike override
		if _spike_idx == i:
			_update_spike(p, delta)

		var path: Array = p.path

		# Advance along path
		p.t += p.speed * delta
		while p.t >= 1.0 and p.seg < path.size() - 2:
			p.t   -= 1.0
			p.seg += 1
			var nidx: int = path[p.seg]
			_nodes[nidx].activity = 1.0
			# Strengthen the edge we just traversed
			if p.seg + 1 < path.size():
				for ei in _node_out_edges[nidx]:
					var e: Dictionary = _edges[ei]
					if e.b == path[p.seg + 1]:
						e.weight = minf(e.weight + 0.28, 1.0)
						break

		# Reached end of path
		if p.t >= 1.0 and p.seg >= path.size() - 2:
			if p.mode == "loop":
				p.seg = 0
				p.t   = 0.0
				p.trail = PackedVector2Array()
			else:
				p.alive = false
				_pulses.remove_at(i)
				if _spike_idx == i:
					_spike_idx = -1
				elif _spike_idx > i:
					_spike_idx -= 1
				i -= 1
				continue

		# Update trail
		if p.seg + 1 < path.size():
			var pa: Vector2 = _nodes[path[p.seg]].pos
			var pb: Vector2 = _nodes[path[p.seg + 1]].pos
			var cur := pa.lerp(pb, clampf(p.t, 0.0, 1.0))
			var trail: PackedVector2Array = p.trail
			trail.append(cur)
			if trail.size() > TRAIL_LEN:
				trail = trail.slice(trail.size() - TRAIL_LEN)
			p.trail = trail

			# Purge wave clears pulses it has passed
			if _purge_active and cur.y < _purge_y - 15.0:
				p.alive = false
				_pulses.remove_at(i)
				if _spike_idx == i:
					_spike_idx = -1
				elif _spike_idx > i:
					_spike_idx -= 1
				i -= 1
				continue

		i -= 1

func _update_spawn(delta: float) -> void:
	if _pulses.size() >= MAX_PULSES:
		return
	for panel_i in 4:
		_spawn_timers[panel_i] = float(_spawn_timers[panel_i]) + delta
		var interval: float = float(_spawn_intervals[panel_i])
		if _purge_active:
			interval = 3.0
		if float(_spawn_timers[panel_i]) >= interval:
			_spawn_timers[panel_i] = 0.0
			# Panel 0 pulses travel the full graph downward.
			# Panels 1-3 spawn local pulses that stay within their panel.
			_spawn_pulse(panel_i, "normal", panel_i > 0)

func _update_rare_events(delta: float) -> void:
	_event_timer += delta
	if _event_timer >= _event_next:
		_event_timer = 0.0
		_event_next  = module_rng.randf_range(18.0, 50.0)
		_fire_rare_event()

func _update_labels(delta: float) -> void:
	var i := _labels.size() - 1
	while i >= 0:
		_labels[i].timer += delta
		if _labels[i].timer >= _labels[i].duration:
			_labels.remove_at(i)
		i -= 1

func _update_spike(pulse: Dictionary, delta: float) -> void:
	_spike_timer += delta
	match _spike_phase:
		"grow":
			pulse.width = lerpf(pulse.width, 14.0, delta * 3.5)
			if _spike_timer > 1.3:
				_spike_phase = "hold"
				_spike_timer = 0.0
		"hold":
			if _spike_timer > 0.9:
				_spike_phase = "collapse"
				_spike_timer = 0.0
				var path: Array = pulse.path
				var lbl_pos: Vector2 = _nodes[path[min(pulse.seg, path.size() - 1)]].pos
				_add_label("EMERGENT SIGNAL COLLAPSED", lbl_pos + Vector2(0.0, -28.0), 3.2, C_RED)
		"collapse":
			pulse.width = lerpf(pulse.width, 1.5, delta * 7.0)
			if _spike_timer > 1.1:
				_spike_idx  = -1
				pulse.width = 2.0

# ═════════════════════════════════════════════════════════════════════════════
# Pulse helpers
# ═════════════════════════════════════════════════════════════════════════════

func _spawn_pulse(start_panel: int, mode: String = "normal", local_only: bool = false) -> int:
	if _pulses.size() >= MAX_PULSES:
		return -1
	var starts := []
	for i in _nodes.size():
		if _nodes[i].panel == start_panel:
			starts.append(i)
	if starts.is_empty():
		return -1
	var start: int = starts[module_rng.randi() % starts.size()]
	var path  := _build_path(start, local_only)
	if path.size() < 2:
		return -1
	var idx := _pulses.size()
	_pulses.append({
		path   = path,
		seg    = 0,
		t      = 0.0,
		speed  = module_rng.randf_range(0.75, 2.1),
		color  = _color_for_panel(start_panel, mode),
		width  = 2.0,
		trail  = PackedVector2Array(),
		mode   = mode,
		alive  = true,
	})
	_nodes[start].activity = 1.0
	return idx

func _build_path(start: int, local_only: bool = false) -> Array:
	var path         := [start]
	var current      := start
	var visited      := {start: true}
	var source_panel: int = _nodes[start].panel
	for _step in 22:
		var out: Array = _node_out_edges[current]
		if out.is_empty():
			break
		var forward := []
		for ei in out:
			var e: Dictionary = _edges[ei]
			if not visited.has(e.b):
				# When local_only, skip edges that leave the source panel
				if local_only and int(_nodes[e.b].panel) != source_panel:
					continue
				forward.append([e.b, e.weight])
		if forward.is_empty():
			break
		# Weighted random selection
		var total_w := 0.0
		for fe in forward:
			total_w += float(fe[1])
		var r := module_rng.randf() * total_w
		var chosen := int(forward[0][0])
		for fe in forward:
			r -= float(fe[1])
			if r <= 0.0:
				chosen = int(fe[0])
				break
		path.append(chosen)
		visited[chosen] = true
		current = chosen
		if not local_only and _nodes[current].panel == 3:
			break
	return path

func _color_for_panel(panel: int, mode: String) -> Color:
	if mode == "phantom":
		return Color(C_VIOLET.r, C_VIOLET.g, C_VIOLET.b, 0.45)
	match panel:
		0: return C_CYAN
		1: return C_VIOLET if module_rng.randf() < 0.40 else C_CYAN
		2: return C_RED    if module_rng.randf() < 0.55 else C_AMBER
		3: return C_CYAN
		_: return C_CYAN

# ═════════════════════════════════════════════════════════════════════════════
# Rare events
# ═════════════════════════════════════════════════════════════════════════════

func _fire_rare_event() -> void:
	var pool := ["thought_loop", "purge", "emergent_spike", "phantom"]
	if _purge_active:
		pool.erase("purge")
	if _pulses.is_empty():
		pool.erase("emergent_spike")
	var ev: String = pool[module_rng.randi() % pool.size()]

	match ev:
		"thought_loop":
			_add_label("RECURSIVE PATTERN DETECTED",
				Vector2(float(_total_size.x) * 0.5, float(_total_size.y) * 0.35),
				4.5, C_VIOLET)
			# Spawn slow loop pulses in the processing lattice
			for _i in 4:
				var idx := _spawn_pulse(1, "loop")
				if idx >= 0:
					_pulses[idx].speed = module_rng.randf_range(0.3, 0.7)

		"purge":
			_purge_active = true
			_purge_y      = 0.0
			_add_label("MEMORY FLUSH",
				Vector2(float(_total_size.x) * 0.5, float(_total_size.y) * 0.5),
				4.0, C_PURGE)

		"emergent_spike":
			if _spike_idx < 0 and _pulses.size() > 0:
				_spike_idx   = module_rng.randi() % _pulses.size()
				_spike_timer = 0.0
				_spike_phase = "grow"

		"phantom":
			_add_label("PHANTOM ACTIVITY DETECTED",
				Vector2(float(_total_size.x) * 0.5, float(_total_size.y) * 0.65),
				3.5, Color(C_VIOLET.r, C_VIOLET.g, C_VIOLET.b, 0.70))
			var ph_panel := module_rng.randi() % 4
			for _i in module_rng.randi_range(3, 7):
				_spawn_pulse(ph_panel, "phantom")

func _add_label(text: String, pos: Vector2, duration: float, color: Color) -> void:
	_labels.append({text = text, pos = pos, timer = 0.0, duration = duration, color = color})

# ═════════════════════════════════════════════════════════════════════════════
# Draw
# ═════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha := 1.0
	if _winding_down:
		alpha = clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)

	_draw_background(alpha)
	_draw_edges(alpha)
	_draw_nodes(alpha)
	_draw_pulses(alpha)
	_draw_purge_wave(alpha)
	_draw_zone_labels(alpha)
	_draw_panel_seams(alpha)
	_draw_event_labels(alpha)

func _draw_background(alpha: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(_total_size)),
			Color(0.0, 0.0, 0.015, alpha))
	# Subtle vignette — darken top and bottom edges
	for i in 10:
		var vig := float(i) / 10.0 * 0.09 * alpha
		draw_rect(Rect2(0.0, float(i) * 5.0, float(_total_size.x), 5.0),
				Color(0.0, 0.0, 0.0, vig))
		draw_rect(Rect2(0.0, float(_total_size.y) - float(i + 1) * 5.0,
				float(_total_size.x), 5.0), Color(0.0, 0.0, 0.0, vig))

func _draw_edges(alpha: float) -> void:
	for e in _edges:
		var na: Dictionary = _nodes[e.a]
		var nb: Dictionary = _nodes[e.b]
		var w: float = e.weight
		var a  := alpha * (0.08 + w * 0.24)
		draw_line(na.pos, nb.pos, Color(C_EDGE.r, C_EDGE.g, C_EDGE.b, a), 0.7, true)

func _draw_nodes(alpha: float) -> void:
	for nd in _nodes:
		var n: Dictionary = nd
		var act:   float = n.activity
		var blink: float = (sin(n.blink) * 0.5 + 0.5)  # 0..1

		# Color by panel + state
		var col: Color
		match n.panel:
			0: col = C_CYAN
			1: col = C_VIOLET if (blink > 0.65 and act > 0.15) else C_CYAN
			2: col = C_RED    if (act > 0.35)                   else C_AMBER if act > 0.1 else C_CYAN
			3: col = C_CYAN
			_: col = C_CYAN

		var base_a := alpha * (0.28 + blink * 0.22 + act * 0.50)
		var nc     := Color(col.r, col.g, col.b, base_a)
		var r      := 2.8 + act * 3.8
		draw_circle(n.pos, r, nc)

		# Activity ring
		if act > 0.25:
			var ring_r := r + 7.0 * (1.0 - act * 0.7)
			draw_arc(n.pos, ring_r, 0.0, TAU, 16,
					Color(col.r, col.g, col.b, base_a * 0.38 * act), 0.8, true)

		# Panel 2 misfire sparks
		if n.panel == 2 and act > 0.55 and blink > 0.65:
			var sc := Color(C_RED.r, C_RED.g, C_RED.b, alpha * act * 0.72)
			for si in 4:
				var ang := TAU * float(si) / 4.0 + float(n.blink)
				var tip := (n.pos as Vector2) + Vector2(cos(ang), sin(ang)) * (r + 3.0 + blink * 9.0)
				draw_line((n.pos as Vector2) + Vector2(cos(ang), sin(ang)) * r, tip, sc, 0.8, true)

func _draw_pulses(alpha: float) -> void:
	for pi in _pulses.size():
		var p: Dictionary = _pulses[pi]
		if not p.alive:
			continue
		var col:   Color               = p.color
		var w:     float               = p.width
		var trail: PackedVector2Array  = p.trail

		var pulse_a := alpha * (0.55 if p.mode == "phantom" else 1.0)
		var dc      := Color(col.r, col.g, col.b, col.a * pulse_a)

		# Fading trail
		var tlen := trail.size()
		if tlen >= 2:
			for ti in tlen - 1:
				var fade := float(ti) / float(tlen)
				var tc   := Color(dc.r, dc.g, dc.b, dc.a * fade * 0.55)
				draw_line(trail[ti], trail[ti + 1], tc, maxf(w * 0.35, 0.4), true)

		# Pulse head
		var path: Array = p.path
		if p.seg + 1 < path.size():
			var pa:   Vector2 = _nodes[path[p.seg]].pos
			var pb:   Vector2 = _nodes[path[p.seg + 1]].pos
			var head := pa.lerp(pb, clampf(p.t, 0.0, 1.0))
			var hr   := maxf(w * 0.7, 1.5)
			draw_circle(head, hr, dc)
			# Glow halo
			draw_circle(head, w * 1.5, Color(dc.r, dc.g, dc.b, dc.a * 0.20))

func _draw_purge_wave(alpha: float) -> void:
	if not _purge_active:
		return
	var col := Color(C_PURGE.r, C_PURGE.g, C_PURGE.b, alpha * 0.70)
	draw_line(Vector2(0.0, _purge_y),
			Vector2(float(_total_size.x), _purge_y), col, 2.5, true)
	for i in 10:
		var fy := _purge_y - float(i) * 5.0
		if fy < 0.0:
			break
		var fa := alpha * 0.55 * (1.0 - float(i) / 10.0)
		draw_line(Vector2(0.0, fy), Vector2(float(_total_size.x), fy),
				Color(col.r, col.g, col.b, fa), 0.9, true)

func _draw_zone_labels(alpha: float) -> void:
	if not _font:
		return
	for pi in 4:
		var y_mid := float(pi * 768) + 384.0
		var label: String = _ZONE_NAMES[pi]
		var zc:    Color  = _ZONE_COLORS[pi]
		var col   := Color(zc.r, zc.g, zc.b, alpha * C_ZONE.a)
		var ts    := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		draw_string(_font,
				Vector2(float(_total_size.x) - ts.x - 12.0, y_mid),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

func _draw_panel_seams(alpha: float) -> void:
	var col := Color(C_HUD.r, C_HUD.g, C_HUD.b, alpha * 0.25)
	for pi in 3:
		var y := float((pi + 1) * 768)
		draw_line(Vector2(0.0, y), Vector2(float(_total_size.x), y), col, 0.5)

func _draw_event_labels(alpha: float) -> void:
	if not _font:
		return
	for lbl in _labels:
		var l:     Dictionary = lbl
		var t_frac: float = float(l.timer) / float(l.duration)
		var blink  := 0.65 + 0.35 * sin(float(l.timer) * 7.5)
		var a      := alpha * (1.0 - t_frac * 0.7) * blink
		var col    := Color(l.color.r, l.color.g, l.color.b, l.color.a * a)
		var fs     := 14
		var ts     := _font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(_font,
				l.pos - Vector2(ts.x * 0.5, 0.0),
				l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
