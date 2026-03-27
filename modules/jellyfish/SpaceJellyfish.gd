## SpaceJellyfish — large bioluminescent cosmic jellyfish drifting through the monitor wall.
## Pure vector rendering: draw_polygon / draw_polyline / draw_arc / draw_circle.
## Tentacles use virtual-coordinate mapping so they cross bezel gaps seamlessly.
##
## Bell faces upward (dome at top, mouth at bottom). Tentacles trail downward through
## virtual space (increasing virtual_y), spanning multiple panels.
extends Node2D

var module_id          := "jellyfish"
var module_rng:         RandomNumberGenerator
var module_started_at  := 0.0

var _manifest:      Dictionary
var _panel_layout:  PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished       := false
var _winding_down   := false
var _wind_down_timer := 0.0

const _WIND_DOWN_DUR := 3.0

var _total_size: Vector2i

# ── Bell geometry ────────────────────────────────────────────────────────────
var _bell_w:       float   # half-width of bell mouth
var _bell_h:       float   # height from mouth to apex

# ── Body position (pure functions of time, no integration drift) ─────────────
var _body_vy_base:    float   # virtual-y of bell mouth at rest
var _body_x_base:     float   # screen-x of bell center at rest

var _bob_amp:     float
var _bob_freq_a:  float
var _bob_freq_b:  float
var _bob_phase_a: float
var _bob_phase_b: float

var _drift_amp:   float   # virtual-px amplitude of slow panel-crossing drift
var _drift_freq:  float
var _drift_phase: float

var _meander_amp:   float   # screen-x horizontal wander
var _meander_freq:  float
var _meander_phase: float

# ── Bell swim cycle ──────────────────────────────────────────────────────────
var _swim_phase0: float   # phase at module_start
var _swim_freq:   float   # rad/sec  (~TAU/5)

# ── Bell tilt ────────────────────────────────────────────────────────────────
var _tilt_amp:   float
var _tilt_freq:  float
var _tilt_phase: float

# ── Tentacle descriptors ─────────────────────────────────────────────────────
var _tentacles: Array = []

# ── Particle motes ───────────────────────────────────────────────────────────
var _motes: Array = []

# ── Palette ──────────────────────────────────────────────────────────────────
const C_HALO_A     := Color(0.20, 0.35, 0.90, 0.06)
const C_HALO_B     := Color(0.30, 0.50, 1.00, 0.04)
const C_BELL_FILL  := Color(0.18, 0.08, 0.55, 0.28)
const C_BELL_MID   := Color(0.28, 0.14, 0.70, 0.18)
const C_BELL_INNER := Color(0.35, 0.20, 0.80, 0.12)
const C_RIB        := Color(0.38, 0.22, 0.82, 0.30)
const C_RIM        := Color(0.55, 0.72, 1.00, 0.72)
const C_NUCLEUS    := Color(0.78, 0.92, 1.00, 0.95)
const C_NUCLEUS_G  := Color(0.40, 0.65, 1.00, 0.35)
const C_PRIM_A     := Color(0.38, 0.60, 1.00, 0.72)   # blue-violet primary
const C_PRIM_B     := Color(0.78, 0.25, 0.92, 0.62)   # magenta-violet primary
const C_ORAL       := Color(0.50, 0.30, 0.88, 0.65)   # oral arm ribbons
const C_FILAMENT   := Color(0.55, 0.80, 1.00, 0.36)   # fine filaments
const C_FROND      := Color(0.18, 0.88, 0.82, 0.26)   # energy fronds
const C_PULSE_GLO  := Color(0.65, 0.88, 1.00, 0.80)   # bioluminescent pulse
const C_MOTE       := Color(0.62, 0.76, 1.00, 0.55)

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
	_bell_w     = float(_total_size.x) * module_rng.randf_range(0.18, 0.26)
	_bell_h     = _bell_w * module_rng.randf_range(0.80, 1.20)

	var vh := _virtual_space.virtual_height()

	# Bell mouth resting virtual-y (upper portion of virtual space)
	_body_vy_base = module_rng.randf_range(vh * 0.18, vh * 0.48)
	_body_x_base  = float(_total_size.x) * module_rng.randf_range(0.28, 0.72)

	# Two-oscillator bob
	_bob_amp     = module_rng.randf_range(28.0, 65.0)
	_bob_freq_a  = TAU / module_rng.randf_range(11.0, 17.0)
	_bob_freq_b  = TAU / module_rng.randf_range(18.0, 28.0)
	_bob_phase_a = module_rng.randf_range(0.0, TAU)
	_bob_phase_b = module_rng.randf_range(0.0, TAU)

	# Slow panel-crossing drift
	_drift_amp   = vh * module_rng.randf_range(0.10, 0.20)
	_drift_freq  = TAU / module_rng.randf_range(90.0, 160.0)
	_drift_phase = module_rng.randf_range(0.0, TAU)

	# Horizontal meander
	_meander_amp   = module_rng.randf_range(45.0, 130.0)
	_meander_freq  = TAU / module_rng.randf_range(35.0, 75.0)
	_meander_phase = module_rng.randf_range(0.0, TAU)

	# Swim pulse  (4.5–7s full cycle)
	_swim_phase0 = module_rng.randf_range(0.0, TAU)
	_swim_freq   = TAU / module_rng.randf_range(4.5, 7.0)

	# Tilt
	_tilt_amp   = module_rng.randf_range(0.04, 0.10)
	_tilt_freq  = TAU / module_rng.randf_range(14.0, 28.0)
	_tilt_phase = module_rng.randf_range(0.0, TAU)

	_build_tentacles()
	_build_motes()

func module_status() -> Dictionary:
	var bc := _bell_center(App.station_time)
	return {"ok": true, "notes": "vy=%.0f x=%.0f" % [bc.y, bc.x], "intensity": 0.20}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0
	Log.debug("SpaceJellyfish: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_tentacles.clear()
	_motes.clear()

# ═════════════════════════════════════════════════════════════════════════════
# Build helpers
# ═════════════════════════════════════════════════════════════════════════════

func _build_tentacles() -> void:
	var vh      := _virtual_space.virtual_height()
	var max_len := vh * 0.62

	# 4 primary tentacles — long, ribbon-like, alternating colour
	var p_xf := [-0.37, -0.12, 0.13, 0.38]
	for i in 4:
		_tentacles.append({
			"kind":   "primary",
			"x_frac": p_xf[i] + module_rng.randf_range(-0.05, 0.05),
			"length": module_rng.randf_range(max_len * 0.50, max_len * 0.88),
			"phase":  module_rng.randf_range(0.0, TAU),
			"sway_f": TAU / module_rng.randf_range(4.5, 9.0),
			"sway_a": module_rng.randf_range(42.0, 90.0),
			"w_root": module_rng.randf_range(2.5, 4.2),
			"color":  C_PRIM_A if (i % 2 == 0) else C_PRIM_B,
			"lag":    module_rng.randf_range(0.20, 0.65),
		})

	# 2 oral arms — thicker, close to body
	var o_xf := [-0.19, 0.20]
	for i in 2:
		_tentacles.append({
			"kind":   "oral",
			"x_frac": o_xf[i] + module_rng.randf_range(-0.04, 0.04),
			"length": module_rng.randf_range(_bell_h * 1.6, _bell_h * 2.8),
			"phase":  module_rng.randf_range(0.0, TAU),
			"sway_f": TAU / module_rng.randf_range(5.0, 10.0),
			"sway_a": module_rng.randf_range(18.0, 48.0),
			"w_root": module_rng.randf_range(3.8, 6.5),
			"color":  C_ORAL,
			"lag":    module_rng.randf_range(0.08, 0.28),
		})

	# 4 fine filaments — thin, highly independent
	var f_xf := [-0.29, -0.07, 0.09, 0.28]
	for i in 4:
		_tentacles.append({
			"kind":   "filament",
			"x_frac": f_xf[i] + module_rng.randf_range(-0.07, 0.07),
			"length": module_rng.randf_range(max_len * 0.22, max_len * 0.55),
			"phase":  module_rng.randf_range(0.0, TAU),
			"sway_f": TAU / module_rng.randf_range(3.0, 6.5),
			"sway_a": module_rng.randf_range(14.0, 42.0),
			"w_root": module_rng.randf_range(0.7, 1.5),
			"color":  C_FILAMENT,
			"lag":    module_rng.randf_range(0.45, 1.10),
		})

	# 2 energy fronds — outer, faint, cosmic
	var e_xf := [-0.50, 0.50]
	for i in 2:
		_tentacles.append({
			"kind":   "frond",
			"x_frac": e_xf[i] + module_rng.randf_range(-0.06, 0.06),
			"length": module_rng.randf_range(max_len * 0.28, max_len * 0.58),
			"phase":  module_rng.randf_range(0.0, TAU),
			"sway_f": TAU / module_rng.randf_range(7.0, 14.0),
			"sway_a": module_rng.randf_range(30.0, 72.0),
			"w_root": module_rng.randf_range(0.8, 1.8),
			"color":  C_FROND,
			"lag":    module_rng.randf_range(0.5, 1.3),
		})

func _build_motes() -> void:
	for i in 28:
		_motes.append({
			"x_off":   module_rng.randf_range(-380.0, 380.0),
			"vy_off":  module_rng.randf_range(-480.0, 950.0),
			"drift_y": module_rng.randf_range(-14.0, -4.0),
			"drift_x": module_rng.randf_range(-6.0,   6.0),
			"blink_p": module_rng.randf_range(0.0, TAU),
			"blink_f": TAU / module_rng.randf_range(3.0, 9.0),
			"size":    module_rng.randf_range(0.8, 2.4),
			"alpha":   module_rng.randf_range(0.12, 0.50),
		})

# ═════════════════════════════════════════════════════════════════════════════
# Position & animation helpers (pure time functions, no accumulated state)
# ═════════════════════════════════════════════════════════════════════════════

func _bell_center(t: float) -> Vector2:
	var e  := t - module_started_at
	var bob := _bob_amp * (
		sin(e * _bob_freq_a + _bob_phase_a) * 0.6 +
		sin(e * _bob_freq_b + _bob_phase_b) * 0.4)
	var drift := _drift_amp * sin(e * _drift_freq + _drift_phase)
	var mx    := sin(e * _meander_freq + _meander_phase) * _meander_amp
	return Vector2(_body_x_base + mx, _body_vy_base + drift + bob)

# Swim contraction: 0.0 = relaxed, 1.0 = fully contracted
func _swim_t(t: float) -> float:
	var e := t - module_started_at
	return 0.5 + 0.5 * sin(e * _swim_freq + _swim_phase0)

func _bell_tilt(t: float) -> float:
	var e := t - module_started_at
	return _tilt_amp * sin(e * _tilt_freq + _tilt_phase)

# ═════════════════════════════════════════════════════════════════════════════
# Tentacle geometry  — returns Array of PackedVector2Array segments
# (split at bezel gaps via virtual_to_real)
# ═════════════════════════════════════════════════════════════════════════════

func _tentacle_segments(tent: Dictionary, t: float, bell_vc: Vector2) -> Array:
	var e      := t - module_started_at
	var lag    := float(tent.lag)
	var sway_f := float(tent.sway_f)
	var sway_a := float(tent.sway_a)
	var phase  := float(tent.phase)
	var x_frac := float(tent.x_frac)
	var length := float(tent.length)

	var root_x  := bell_vc.x + x_frac * _bell_w
	var root_vy := bell_vc.y   # tentacle roots at the bell mouth (virtual y)

	const STEPS := 44
	var segments: Array = []
	var current  := PackedVector2Array()

	for i in STEPS + 1:
		var frac := float(i) / float(STEPS)
		var vy   := root_vy + frac * length
		# Traveling-wave sway: amplitude grows toward tip; lag shifts phase along length
		var sway := sway_a * frac * sin(
			e * sway_f - frac * (2.5 * PI) + phase - lag * sway_f * frac * 0.6)
		var rx   := root_x + sway

		var map := _virtual_space.virtual_to_real(vy)
		if map.visible:
			current.push_back(Vector2(rx, float(map.real_y)))
		else:
			if current.size() >= 2:
				segments.push_back(current.duplicate())
			current = PackedVector2Array()

	if current.size() >= 2:
		segments.push_back(current)
	return segments

# ═════════════════════════════════════════════════════════════════════════════
# Godot process
# ═════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	# Drift motes upward; respawn when they exit the top
	for m in _motes:
		m["vy_off"] += float(m["drift_y"]) * delta
		m["x_off"]  += float(m["drift_x"]) * delta
		m["blink_p"] = fmod(float(m["blink_p"]) + float(m["blink_f"]) * delta, TAU)
		if float(m["vy_off"]) < -900.0:
			m["vy_off"] = module_rng.randf_range(700.0, 1100.0)
			m["x_off"]  = module_rng.randf_range(-380.0, 380.0)

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true

	queue_redraw()

# ═════════════════════════════════════════════════════════════════════════════
# Draw
# ═════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var t       := App.station_time
	var elapsed := t - module_started_at
	var fade    := clampf(elapsed / 2.5, 0.0, 1.0)     # fade in over 2.5s
	if _winding_down:
		fade = minf(fade, clampf(1.0 - _wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0))

	var bell_vc := _bell_center(t)        # (screen_x, virtual_y) of bell mouth
	var swim    := _swim_t(t)
	var tilt    := _bell_tilt(t)

	# Bell contraction: contract y-extent, expand x-extent subtly
	var ctr     := swim * 0.10
	var bw      := _bell_w * (1.0 + ctr * 0.4)
	var bh      := _bell_h * (1.0 - ctr)

	# Real position of bell mouth
	var mouth_map := _virtual_space.virtual_to_real(bell_vc.y)
	var bell_visible: bool = mouth_map.visible
	var bell_ry      := float(mouth_map.real_y)
	var bell_rx      := bell_vc.x

	# Draw order: back → front
	_draw_halo(bell_rx, bell_ry, bw, bh, bell_visible, fade)
	_draw_motes(bell_vc, fade)
	_draw_all_tentacles(bell_vc, t, "frond",    fade)
	_draw_all_tentacles(bell_vc, t, "filament", fade)
	_draw_all_tentacles(bell_vc, t, "primary",  fade)
	_draw_all_tentacles(bell_vc, t, "oral",     fade)
	if bell_visible:
		_draw_bell(bell_rx, bell_ry, bw, bh, swim, tilt, elapsed, fade)

# ── Atmospheric halo rings around the bell ───────────────────────────────────

func _draw_halo(cx: float, cy: float, bw: float, bh: float,
		bell_vis: bool, fade: float) -> void:
	if not bell_vis:
		return
	# Apex center of bell (dome top)
	var ax := cx
	var ay := cy - bh
	var halo_r := (bw + bh) * 0.6
	var layers := [
		[1.00, 3.6, Color(C_HALO_A.r, C_HALO_A.g, C_HALO_A.b, C_HALO_A.a * fade)],
		[1.30, 2.8, Color(C_HALO_A.r, C_HALO_A.g, C_HALO_A.b, C_HALO_A.a * fade * 0.65)],
		[1.70, 2.0, Color(C_HALO_B.r, C_HALO_B.g, C_HALO_B.b, C_HALO_B.a * fade * 0.5)],
		[2.20, 1.4, Color(C_HALO_B.r, C_HALO_B.g, C_HALO_B.b, C_HALO_B.a * fade * 0.3)],
	]
	for layer in layers:
		var r   := halo_r * float(layer[0])
		var w   := float(layer[1])
		var col := layer[2] as Color
		draw_arc(Vector2(ax, ay), r, 0.0, TAU, 48, col, w, true)

# ── Particle motes — cosmic plankton ─────────────────────────────────────────

func _draw_motes(bell_vc: Vector2, fade: float) -> void:
	for m in _motes:
		var mvy := bell_vc.y + float(m["vy_off"])
		var mx  := bell_vc.x + float(m["x_off"])
		var map := _virtual_space.virtual_to_real(mvy)
		if not map.visible:
			continue
		var blink := 0.5 + 0.5 * sin(float(m["blink_p"]))
		var a     := float(m["alpha"]) * blink * fade
		var sz    := float(m["size"])
		draw_circle(Vector2(mx, float(map.real_y)), sz,
				Color(C_MOTE.r, C_MOTE.g, C_MOTE.b, a))

# ── Tentacle batch draw ───────────────────────────────────────────────────────

func _draw_all_tentacles(bell_vc: Vector2, t: float,
		kind: String, fade: float) -> void:
	for tent in _tentacles:
		if tent.kind != kind:
			continue
		var segs := _tentacle_segments(tent, t, bell_vc)
		var n_segs := segs.size()
		for si in n_segs:
			var seg: PackedVector2Array = segs[si]
			var n_pts := seg.size()
			if n_pts < 2:
				continue
			# Draw segment: taper line-width and alpha root→tip
			# (root = si=0, pt=0; tip = last point of last segment)
			for pi in n_pts - 1:
				var frac_root := float(pi)       / float(n_pts - 1)
				var frac_tip  := float(pi + 1)   / float(n_pts - 1)
				var frac_mid  := (frac_root + frac_tip) * 0.5
				var alpha_mul := (1.0 - frac_mid * 0.88) * fade
				var w_root    := float(tent.w_root)
				var lw        := w_root * (1.0 - frac_mid * 0.92)
				lw            = maxf(lw, 0.3)
				var base := tent.color as Color
				var col  := Color(base.r, base.g, base.b, base.a * alpha_mul)
				var pts  := PackedVector2Array([seg[pi], seg[pi + 1]])
				draw_polyline(pts, col, lw, true)

			# Occasional bioluminescent pulse glow along primary/oral tentacles
			if (kind == "primary" or kind == "oral") and n_pts >= 3:
				_draw_tentacle_pulse(seg, t, tent, fade)

func _draw_tentacle_pulse(seg: PackedVector2Array, t: float,
		tent: Dictionary, fade: float) -> void:
	# A slow bright node travelling down the tentacle
	var e        := t - module_started_at
	var pulse_t  := fmod(e * 0.18 + float(tent.phase), 1.0)
	var n        := seg.size()
	if n < 2:
		return
	var idx := int(pulse_t * float(n - 1))
	idx = clampi(idx, 0, n - 1)
	var pt  := seg[idx]
	var a   := 0.55 * fade * (0.6 + 0.4 * sin(e * 2.8 + float(tent.phase)))
	draw_circle(pt, 3.5, Color(C_PULSE_GLO.r, C_PULSE_GLO.g, C_PULSE_GLO.b, a))
	draw_circle(pt, 6.0, Color(C_PULSE_GLO.r, C_PULSE_GLO.g, C_PULSE_GLO.b, a * 0.3))

# ── Bell ──────────────────────────────────────────────────────────────────────

func _draw_bell(cx: float, cy: float, bw: float, bh: float,
		swim: float, tilt: float, elapsed: float, fade: float) -> void:
	# Build dome polygon: half-circle, rounded top facing up
	# (cx,cy) = mouth center; apex at (cx, cy-bh)
	# x = cx - bw*cos(a) + tilt_shift(a), y = cy - bh*sin(a),  a ∈ [0,PI]
	const N_DOME := 64
	var dome     := PackedVector2Array()
	for i in N_DOME + 1:
		var a := PI * float(i) / float(N_DOME)
		var px := cx - bw * cos(a) + (1.0 - sin(a)) * tilt * bh
		var py := cy - bh * sin(a)
		dome.append(Vector2(px, py))
	# draw_polygon auto-closes (last pt → first pt = flat base across mouth)

	# Layer 1: outer fill (most transparent, widest)
	_draw_dome_fill(dome, Color(C_BELL_FILL.r, C_BELL_FILL.g, C_BELL_FILL.b,
			C_BELL_FILL.a * 0.55 * fade))
	# Layer 2: scaled inward dome
	var dome2 := _scale_dome(dome, cx, cy, 0.78, 0.72)
	_draw_dome_fill(dome2, Color(C_BELL_MID.r, C_BELL_MID.g, C_BELL_MID.b,
			C_BELL_MID.a * 0.65 * fade))
	# Layer 3: innermost dome
	var dome3 := _scale_dome(dome, cx, cy, 0.52, 0.50)
	_draw_dome_fill(dome3, Color(C_BELL_INNER.r, C_BELL_INNER.g, C_BELL_INNER.b,
			C_BELL_INNER.a * 0.80 * fade))

	# Radial rib lines (8 ribs suggesting internal anatomy)
	_draw_ribs(cx, cy, bw, bh, tilt, fade)

	# Rim highlight: thin bright arc along the dome outline
	var rim_a := C_RIM.a * fade
	draw_polyline(dome, Color(C_RIM.r, C_RIM.g, C_RIM.b, rim_a), 1.4, true)
	# Faint glow duplicate
	draw_polyline(dome, Color(C_RIM.r, C_RIM.g, C_RIM.b, rim_a * 0.28), 4.0, true)

	# Core nucleus — pulsing sphere near apex
	_draw_nucleus(cx, cy, bw, bh, swim, elapsed, fade)

func _draw_dome_fill(pts: PackedVector2Array, col: Color) -> void:
	var colors := PackedColorArray()
	colors.resize(pts.size())
	colors.fill(col)
	draw_polygon(pts, colors)

func _scale_dome(dome: PackedVector2Array, cx: float, cy: float,
		sx: float, sy: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in dome:
		out.append(Vector2(cx + (pt.x - cx) * sx, cy + (pt.y - cy) * sy))
	return out

func _draw_ribs(cx: float, cy: float, bw: float, bh: float,
		tilt: float, fade: float) -> void:
	const N_RIBS := 8
	var col := Color(C_RIB.r, C_RIB.g, C_RIB.b, C_RIB.a * fade)
	for i in N_RIBS:
		var a  := PI * (float(i) + 0.5) / float(N_RIBS)
		var tip_x := cx - bw * cos(a) * 0.90 + (1.0 - sin(a)) * tilt * bh
		var tip_y := cy - bh * sin(a) * 0.90
		draw_line(Vector2(cx, cy), Vector2(tip_x, tip_y), col, 0.7, true)

func _draw_nucleus(cx: float, cy: float, bw: float, bh: float,
		swim: float, elapsed: float, fade: float) -> void:
	# Nucleus sits 65% up the dome from mouth
	var nx := cx
	var ny := cy - bh * 0.65
	var base_r := bw * 0.095
	# Pulse with swim cycle
	var pulse := 0.80 + 0.20 * (1.0 - swim)
	var nr    := base_r * pulse

	# Outer glow rings
	for gi in 3:
		var gr := nr * (1.8 + float(gi) * 0.8)
		var ga := C_NUCLEUS_G.a * fade * (0.35 - float(gi) * 0.10)
		draw_circle(Vector2(nx, ny), gr,
				Color(C_NUCLEUS_G.r, C_NUCLEUS_G.g, C_NUCLEUS_G.b, ga))
	# Core
	draw_circle(Vector2(nx, ny), nr,
			Color(C_NUCLEUS.r, C_NUCLEUS.g, C_NUCLEUS.b, C_NUCLEUS.a * fade))
	# Hot centre
	draw_circle(Vector2(nx, ny), nr * 0.45,
			Color(1.0, 1.0, 1.0, 0.88 * fade))
