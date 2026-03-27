## SignalIntercept — Deep Space Signal Intercept
## Four-monitor vertical display: acquisition → raw signal → decryption → interpretation
## Pure draw_* rendering, no external assets.
extends Node2D

var module_id := "signal_intercept"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished       := false
var _wind_down_timer := 0.0
const _WIND_DOWN_DUR := 2.5
var _winding_down    := false

# ─── Layout ─────────────────────────────────────────────────────────────────
const PW  := 1024
const PH  := 768
const P0Y := 0
const P1Y := 768
const P2Y := 1536
const P3Y := 2304

# ─── Colors ─────────────────────────────────────────────────────────────────
const C_BG      := Color(0.000, 0.030, 0.010, 1.00)
const C_GREEN   := Color(0.150, 0.850, 0.350, 0.85)
const C_GREEN_B := Color(0.200, 1.000, 0.500, 1.00)
const C_GREEN_D := Color(0.050, 0.400, 0.180, 0.55)
const C_AMBER   := Color(0.850, 0.550, 0.100, 0.80)
const C_AMBER_D := Color(0.550, 0.350, 0.050, 0.45)
const C_RED     := Color(0.900, 0.120, 0.080, 0.85)
const C_WHITE   := Color(1.000, 1.000, 0.900, 0.95)
const C_FRAME   := Color(0.080, 0.550, 0.250, 0.65)

# ─── State machine ──────────────────────────────────────────────────────────
enum SigState { IDLE_SCAN, WEAK_SIGNAL, PATTERN_LOCK, SIGNAL_COLLAPSE, RARE_EVENT }
var _state: SigState = SigState.IDLE_SCAN
var _state_timer    := 0.0
var _state_dur      := 30.0
var _rare_cooldown  := 0.0
var _rare_interval  := 120.0
var _post_rare      := false   # set after a RARE_EVENT; changes post-collapse verdict

# ─── Monitor 1: Acquisition ─────────────────────────────────────────────────
const SCOPE_CX := 512
const SCOPE_CY := P0Y + 355
const SCOPE_R  := 265
var _sweep_angle        := 0.0
var _sweep_base_speed   := 0.65   # nominal rad/s
var _sweep_actual_speed := 0.65   # current (reduced during lock snap)
var _sweep_snap         := false
var _sweep_snap_timer   := 0.0
var _lock_active  := false
var _lock_angle   := 0.0
var _lock_alpha   := 0.0
var _lock_pulse   := 0.0          # 0..TAU, drives blink
var _signal_strength := 0.10
var _sig_target   := 0.10
var _strength_hist: Array = []
const HIST_LEN    := 90
var _stars: Array = []            # [{x,y,b,f}]
var _echo_rings: Array = []       # [{x,y,r,alpha}] expanding rings on lock

# ─── Monitor 2: Raw signal ───────────────────────────────────────────────────
const WAVE_SAMPLES := 256
var _wave_primary:   Array = []
var _wave_secondary: Array = []
var _wave_noise:     Array = []   # independent Ch-C buffer
var _carrier_alpha  := 0.0
var _carrier_target := 0.0
var _glitch_active  := false      # true during SIGNAL_COLLAPSE
var _glitch_offsets: Array = []   # per-segment random x offsets
var _stream_texts: Array = []     # [{text, slot, alpha, fade}] — fixed bottom slots
var _stream_timer := 0.0

# ─── Monitor 3: Decryption ───────────────────────────────────────────────────
const DECRYPT_ROWS_MAX := 17
var _decrypt_rows: Array = []
var _decrypt_timer    := 0.0
var _decrypt_burst    := 0.0      # when > 0, forces fast decrypt (cross-panel causality)
var _frag_text  := ""
var _frag_alpha := 0.0
var _err_text   := ""
var _err_alpha  := 0.0
var _err_timer  := 0.0
var _highlight_rects: Array = []  # [{rect, alpha}]
var _rare_cascade_timer := 0.0    # during RARE_EVENT: drives rapid row replacement

# ─── Monitor 4: Interpretation ───────────────────────────────────────────────
var _confidence  := 0.10
var _conf_target := 0.10
var _threat      := 0             # 0=low 1=medium 2=high
var _log_lines: Array = []        # strings (already timestamped)
var _log_timer   := 0.0
var _log_interval := 4.0
var _verdict        := "UNKNOWN"
var _recommendation := "CONTINUE MONITORING"
var _verdict_timer  := 0.0
var _frame_alert_alpha := 0.0     # red/amber frame overlay alpha

# ─── Rare event overlay ──────────────────────────────────────────────────────
var _rare_flash := 0.0
var _rare_text  := ""

var _font: Font
var _station_time := 0.0

# ─── Content pools ───────────────────────────────────────────────────────────
const _BINARY_POOL := [
	"01001000 01000101 01001100 01001100",
	"11001010 10110011 00101011 11100001",
	"00000000 11111111 01010101 10101010",
	"10000001 01111110 00100100 11011011",
	"01110011 01001001 01000111 01001110",
	"11111010 00000101 10110110 01001001",
	"00110011 11001100 01010101 10101010",
	"10010110 01101001 11100011 00011100",
]
const _HEX_POOL := [
	"HEX> A4 F2 9B 11 CC 03 7E 55 D8 01",
	"HEX> FF 00 7F 80 3C C3 AA 55 0F F0",
	"HEX> 4E 6F 20 53 69 67 6E 61 6C 20",
	"HEX> DE AD BE EF 00 01 02 03 04 05",
	"HEX> C0 FF EE 00 11 22 33 44 55 66",
	"HEX> 48 45 4C 4C 4F 20 57 4F 52 4C",
]
const _FRAG_POOL := [
	"ERR: BUFFER OVERFLOW",
	"SEQ: A4-F2-9B-11",
	"[COORD] 47.3N 122.5W",
	"...REPEAT...REPEAT...",
	"MATCH: 0 / 4096",
	"CARRIER: 1420.405 MHZ",
	"CRC FAIL: RETRY",
	"SEGMENT [7] CORRUPT",
	"XMIT INTERVAL: ???",
	"[PARTIAL] ...RRY...T...",
	"SYNC WORD DETECTED",
	"DECODING: 0.002%",
	"PATTERN NULL",
	"TRANSLATION ERROR",
	"NOISE FLOOR RISING",
	"PHASE: UNDEFINED",
	"ENCODING: UNKNOWN",
	"MATCH PROBABILITY: 0.03%",
]
const _LOG_POOL := [
	"SCAN FREQ 1420.405 MHZ",
	"NO MATCH IN DATABASE",
	"SAMPLE RATE 2048 KSPS",
	"FILTER WIDTH 100 KHZ",
	"SNR: -2.3 DB",
	"BUFFER OVERFLOW x3",
	"SECTOR FLAGGED",
	"CORRELATION < 0.001",
	"SYSTEM NOMINAL",
	"PROCESSING QUEUE: 847",
	"ENTROPY HIGH",
	"FFT COMPLETE",
	"UPLINK STABLE",
	"ANOMALY LOGGED",
	"RESAMPLING...",
	"HANDSHAKE FAIL",
	"WATCHDOG OK",
	"TIMESTAMP DRIFT +0.3S",
	"INTERFERENCE DETECTED",
	"GAIN +12 DB",
	"PATTERN SEARCH CYCLE 441",
	"DB QUERY: 0 RESULTS",
]
const _VERDICTS := [
	"UNKNOWN", "NOISE", "POSSIBLE SIGNAL",
	"STRUCTURED PATTERN", "ANOMALOUS", "UNCLASSIFIED",
]
const _RECOMMENDATIONS := [
	"CONTINUE MONITORING",
	"INCREASE GAIN",
	"ALERT SUPERVISORY",
	"CROSS-REFERENCE DB",
	"HOLD FREQUENCY",
	"RECALIBRATE ANTENNA",
	"LOG AND CONTINUE",
	"AWAIT CONFIRMATION",
]

# ─────────────────────────────────────────────────────────────────────────────
func module_configure(ctx: Dictionary) -> void:
	_manifest      = ctx.manifest
	module_rng     = RNG.make_rng(ctx.seed)
	_panel_layout  = ctx.panel_layout
	_virtual_space = ctx.virtual_space

func module_start() -> void:
	module_started_at = App.station_time
	_stop_requested = false
	_finished       = false
	_winding_down   = false
	_font = ThemeDB.fallback_font

	_init_stars()
	_init_waveforms()
	_init_decrypt_rows()
	_init_logs()

	_state              = SigState.IDLE_SCAN
	_state_timer        = 0.0
	_state_dur          = _rand_range(25.0, 55.0)
	_rare_cooldown      = _rand_range(40.0, 70.0)
	_rare_interval      = _rand_range(90.0, 160.0)
	_post_rare          = false
	_sweep_angle        = module_rng.randf() * TAU
	_sweep_base_speed   = _rand_range(0.55, 0.80)
	_sweep_actual_speed = _sweep_base_speed
	_sweep_snap         = false
	_sweep_snap_timer   = 0.0
	_signal_strength    = 0.10
	_sig_target         = 0.10
	_confidence         = 0.10
	_conf_target        = 0.10
	_verdict            = "UNKNOWN"
	_recommendation     = "CONTINUE MONITORING"
	_threat             = 0
	_frame_alert_alpha  = 0.0

func module_status() -> Dictionary:
	return {
		"ok": true,
		"notes": "state:%s sig:%.2f" % [SigState.keys()[_state], _signal_strength],
		"intensity": _signal_strength,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested  = true
	_winding_down    = true
	_wind_down_timer = 0.0

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_stars.clear()
	_wave_primary.clear()
	_wave_secondary.clear()
	_wave_noise.clear()
	_decrypt_rows.clear()
	_log_lines.clear()
	_stream_texts.clear()
	_highlight_rects.clear()
	_strength_hist.clear()
	_echo_rings.clear()
	_glitch_offsets.clear()

# ─── Init helpers ─────────────────────────────────────────────────────────────
func _init_stars() -> void:
	_stars.clear()
	for _i in 42:
		var ang := module_rng.randf() * TAU
		var r   := module_rng.randf_range(12.0, float(SCOPE_R) - 6.0)
		_stars.append({
			"x": SCOPE_CX + cos(ang) * r,
			"y": SCOPE_CY + sin(ang) * r,
			"b": module_rng.randf_range(0.20, 0.80),
			"f": module_rng.randf() * TAU,
		})

func _init_waveforms() -> void:
	_wave_primary.clear()
	_wave_secondary.clear()
	_wave_noise.clear()
	_glitch_offsets.clear()
	for _i in WAVE_SAMPLES:
		_wave_primary.append(module_rng.randf_range(-0.12, 0.12))
		_wave_secondary.append(module_rng.randf_range(-0.06, 0.06))
		_wave_noise.append(module_rng.randf_range(-1.0, 1.0))
		_glitch_offsets.append(0.0)

func _init_decrypt_rows() -> void:
	_decrypt_rows.clear()
	for _i in 8:
		_decrypt_rows.append(_random_decrypt_line())

func _init_logs() -> void:
	_log_lines.clear()
	for _i in 5:
		_log_lines.append(_timestamped(_LOG_POOL[module_rng.randi() % _LOG_POOL.size()]))

# ─── Process ──────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_station_time = App.station_time

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _WIND_DOWN_DUR:
			_finished = true
			return

	_update_state(delta)
	_update_monitor1(delta)
	_update_monitor2(delta)
	_update_monitor3(delta)
	_update_monitor4(delta)

	if _rare_flash > 0.0:
		_rare_flash = move_toward(_rare_flash, 0.0, delta * 0.50)
	_frame_alert_alpha = move_toward(_frame_alert_alpha, 0.0, delta * 0.40)

	queue_redraw()

# ─── State machine ─────────────────────────────────────────────────────────────
func _update_state(delta: float) -> void:
	_state_timer   += delta
	_rare_cooldown -= delta

	if _state == SigState.RARE_EVENT:
		if _state_timer >= _state_dur:
			_post_rare = true
			_transition_state(SigState.SIGNAL_COLLAPSE)
		return

	if _rare_cooldown <= 0.0 and _state == SigState.IDLE_SCAN:
		_rare_cooldown = _rand_range(_rare_interval * 0.8, _rare_interval * 1.6)
		_transition_state(SigState.RARE_EVENT)
		return

	if _state_timer >= _state_dur:
		match _state:
			SigState.IDLE_SCAN:
				if module_rng.randf() < 0.65:
					_transition_state(SigState.WEAK_SIGNAL)
				else:
					_state_timer = 0.0
					_state_dur   = _rand_range(20.0, 60.0)
			SigState.WEAK_SIGNAL:
				if module_rng.randf() < 0.50:
					_transition_state(SigState.PATTERN_LOCK)
				else:
					_transition_state(SigState.SIGNAL_COLLAPSE)
			SigState.PATTERN_LOCK:
				_transition_state(SigState.SIGNAL_COLLAPSE)
			SigState.SIGNAL_COLLAPSE:
				_transition_state(SigState.IDLE_SCAN)

func _transition_state(s: SigState) -> void:
	_state       = s
	_state_timer = 0.0
	match s:
		SigState.IDLE_SCAN:
			_state_dur      = _rand_range(25.0, 70.0)
			_sig_target     = _rand_range(0.04, 0.20)
			_conf_target    = _rand_range(0.04, 0.15)
			_lock_active    = false
			_carrier_target = 0.0
			_threat         = 0
			_glitch_active  = false
			if _post_rare:
				_post_rare      = false
				_verdict        = "RECORD ARCHIVED"
				_recommendation = "AWAIT CONFIRMATION"
				_log_lines.append(_timestamped("ANOMALOUS EVENT ARCHIVED"))
				_log_lines.append(_timestamped("CLASSIFICATION PENDING"))
			else:
				_verdict        = _VERDICTS[module_rng.randi() % 2]
				_recommendation = _RECOMMENDATIONS[0]

		SigState.WEAK_SIGNAL:
			_state_dur      = _rand_range(10.0, 28.0)
			_sig_target     = _rand_range(0.35, 0.65)
			_conf_target    = _rand_range(0.20, 0.45)
			_carrier_target = _rand_range(0.4, 0.8)
			_threat         = 1
			_verdict        = "POSSIBLE SIGNAL"
			_recommendation = _RECOMMENDATIONS[module_rng.randi_range(1, 4)]

		SigState.PATTERN_LOCK:
			_state_dur      = _rand_range(5.0, 14.0)
			_sig_target     = _rand_range(0.70, 0.95)
			_conf_target    = _rand_range(0.55, 0.85)
			_lock_active    = true
			_lock_angle     = module_rng.randf() * TAU
			_carrier_target = 1.0
			_threat         = module_rng.randi_range(1, 2)
			_verdict        = _VERDICTS[3 + module_rng.randi() % 2]
			_recommendation = _RECOMMENDATIONS[module_rng.randi_range(2, 5)]
			# Cross-panel causality: burst the decrypt stream
			_decrypt_burst  = 3.0
			# Sweep snap: slow down, home toward lock angle
			_sweep_snap       = true
			_sweep_snap_timer = 0.0
			# Echo rings at lock position
			var lx := float(SCOPE_CX) + cos(_lock_angle) * float(SCOPE_R) * 0.62
			var ly := float(SCOPE_CY) + sin(_lock_angle) * float(SCOPE_R) * 0.62
			for ri in 3:
				_echo_rings.append({"x": lx, "y": ly, "r": 8.0 + float(ri) * 6.0, "alpha": 0.9 - float(ri) * 0.2})
			_log_lines.append(_timestamped("LOCK ACQUIRED — TRACKING"))

		SigState.SIGNAL_COLLAPSE:
			_state_dur      = _rand_range(2.0, 6.0)
			_sig_target     = 0.0
			_conf_target    = _rand_range(0.02, 0.10)
			_lock_active    = false
			_carrier_target = 0.0
			_threat         = 0
			_verdict        = "SIGNAL LOST"
			_recommendation = "LOG AND CONTINUE"
			_glitch_active  = true
			_log_lines.append(_timestamped("SIGNAL LOST — RECALIBRATING"))

		SigState.RARE_EVENT:
			_state_dur          = _rand_range(5.0, 10.0)
			_sig_target         = 1.0
			_conf_target        = 0.98
			_lock_active        = true
			_lock_angle         = module_rng.randf() * TAU
			_carrier_target     = 1.0
			_threat             = 2
			_rare_flash         = 1.0
			_frame_alert_alpha  = 1.0
			_rare_text          = "STRUCTURED SIGNAL DETECTED"
			_verdict            = "ANOMALOUS"
			_recommendation     = "ALERT SUPERVISORY"
			_rare_cascade_timer = 0.0
			# Clear decrypt rows for dramatic cascade
			_decrypt_rows.clear()
			# Sweep snap
			_sweep_snap       = true
			_sweep_snap_timer = 0.0
			var lx2 := float(SCOPE_CX) + cos(_lock_angle) * float(SCOPE_R) * 0.62
			var ly2 := float(SCOPE_CY) + sin(_lock_angle) * float(SCOPE_R) * 0.62
			for ri in 4:
				_echo_rings.append({"x": lx2, "y": ly2, "r": 6.0 + float(ri) * 8.0, "alpha": 1.0 - float(ri) * 0.18})
			_log_lines.append(_timestamped("!! ANOMALOUS SIGNAL — ALERT !!"))
			_log_lines.append(_timestamped("CONFIDENCE THRESHOLD EXCEEDED"))

# ─── Monitor 1 update ─────────────────────────────────────────────────────────
func _update_monitor1(delta: float) -> void:
	# Sweep snap: on lock entry, decelerate for ~2s then recover
	if _sweep_snap:
		_sweep_snap_timer += delta
		if _sweep_snap_timer < 2.0:
			_sweep_actual_speed = move_toward(_sweep_actual_speed, _sweep_base_speed * 0.07,
				delta * 0.8)
		elif _sweep_snap_timer < 4.5:
			_sweep_actual_speed = move_toward(_sweep_actual_speed, _sweep_base_speed,
				delta * 0.4)
		else:
			_sweep_snap = false
			_sweep_actual_speed = _sweep_base_speed
	else:
		_sweep_actual_speed = _sweep_base_speed

	_sweep_angle     = fmod(_sweep_angle + _sweep_actual_speed * delta, TAU)
	_signal_strength = move_toward(_signal_strength, _sig_target, delta * 0.14)
	_lock_alpha      = move_toward(_lock_alpha, 1.0 if _lock_active else 0.0,
		delta * (1.5 if _lock_active else 0.8))
	_lock_pulse      = fmod(_lock_pulse + delta * 4.0, TAU)

	_strength_hist.append(_signal_strength)
	if _strength_hist.size() > HIST_LEN:
		_strength_hist.pop_front()

	# Echo rings: expand and fade
	for er in _echo_rings:
		er["r"]     = float(er.r) + delta * 55.0
		er["alpha"] = move_toward(float(er.alpha), 0.0, delta * 0.55)
	_echo_rings = _echo_rings.filter(func(er): return float(er.alpha) > 0.01)

# ─── Monitor 2 update ─────────────────────────────────────────────────────────
func _update_monitor2(delta: float) -> void:
	var coherence: float = _signal_strength
	var noise_amp: float = lerp(0.28, 0.04, coherence)
	var sig_amp: float   = lerp(0.00, 0.85, coherence)

	# Primary wave
	var new_p: float = sin(_station_time * 3.1 + module_rng.randf_range(-0.1, 0.1)) * sig_amp
	new_p += module_rng.randf_range(-noise_amp, noise_amp)
	_wave_primary.push_back(clamp(new_p, -1.0, 1.0))
	if _wave_primary.size() > WAVE_SAMPLES:
		_wave_primary.pop_front()

	# Secondary wave
	var new_s: float = sin(_station_time * 1.7 + 1.2) * sig_amp * 0.5
	new_s += module_rng.randf_range(-noise_amp * 0.6, noise_amp * 0.6)
	_wave_secondary.push_back(clamp(new_s, -1.0, 1.0))
	if _wave_secondary.size() > WAVE_SAMPLES:
		_wave_secondary.pop_front()

	# Ch-C: independent pure noise (no signal content)
	var new_n: float = module_rng.randf_range(-1.0, 1.0) * lerp(1.0, 0.25, coherence * 0.5)
	_wave_noise.push_back(new_n)
	if _wave_noise.size() > WAVE_SAMPLES:
		_wave_noise.pop_front()

	# Glitch offsets: randomise during SIGNAL_COLLAPSE
	if _glitch_active:
		for i in _glitch_offsets.size():
			if module_rng.randf() < 0.08:
				_glitch_offsets[i] = module_rng.randf_range(-22.0, 22.0)
			else:
				_glitch_offsets[i] = move_toward(float(_glitch_offsets[i]), 0.0, delta * 30.0)
	else:
		for i in _glitch_offsets.size():
			_glitch_offsets[i] = 0.0

	_carrier_alpha = move_toward(_carrier_alpha, _carrier_target, delta * 0.40)

	# Stream texts: fixed bottom-of-panel slots (avoid waveform overlap)
	_stream_timer -= delta
	if _stream_timer <= 0.0:
		_stream_timer = _rand_range(3.5, 9.0)
		var slot := _stream_texts.size() % 6
		_stream_texts.append({
			"text":  _LOG_POOL[module_rng.randi() % _LOG_POOL.size()],
			"slot":  slot,
			"alpha": 1.0,
			"fade":  _rand_range(4.0, 8.0),
		})
		if _stream_texts.size() > 6:
			_stream_texts.pop_front()

	for st in _stream_texts:
		st["fade"]  -= delta
		st["alpha"]  = clamp(float(st.fade) / 3.0, 0.0, 1.0)

# ─── Monitor 3 update ─────────────────────────────────────────────────────────
func _update_monitor3(delta: float) -> void:
	# Decrypt burst (cross-panel causality on PATTERN_LOCK)
	if _decrypt_burst > 0.0:
		_decrypt_burst -= delta
		_decrypt_timer -= delta * 5.0   # force 5× faster during burst

	# Rare event cascade: replace rows very fast with a single repeated fragment
	if _state == SigState.RARE_EVENT:
		_rare_cascade_timer += delta
		if _rare_cascade_timer > 0.12:
			_rare_cascade_timer = 0.0
			_decrypt_rows.append("...REPEAT...REPEAT...")
			if _decrypt_rows.size() > DECRYPT_ROWS_MAX:
				_decrypt_rows.pop_front()
		return   # skip normal decrypt during RARE_EVENT

	_decrypt_timer -= delta
	if _decrypt_timer <= 0.0:
		var interval: float = lerp(0.85, 0.14, _signal_strength)
		_decrypt_timer = _rand_range(interval * 0.7, interval * 1.4)
		_decrypt_rows.append(_random_decrypt_line())
		if _decrypt_rows.size() > DECRYPT_ROWS_MAX:
			_decrypt_rows.pop_front()

	_frag_alpha = move_toward(_frag_alpha,
		1.0 if _signal_strength > 0.45 else 0.0, delta * 0.7)
	if _signal_strength > 0.45 and module_rng.randf() < delta * 0.35:
		_frag_text = _FRAG_POOL[module_rng.randi() % _FRAG_POOL.size()]

	_err_timer -= delta
	if _err_timer <= 0.0:
		_err_timer = _rand_range(5.0, 16.0)
		_err_text  = _FRAG_POOL[module_rng.randi() % _FRAG_POOL.size()]
		_err_alpha = 1.0
	else:
		_err_alpha = move_toward(_err_alpha, 0.0, delta * 0.18)

	if (_state == SigState.PATTERN_LOCK) \
			and module_rng.randf() < delta * 0.5 and _highlight_rects.size() < 4:
		_highlight_rects.append({
			"rect":  Rect2(
				float(module_rng.randi_range(10, 680)),
				float(P2Y + module_rng.randi_range(10, PH - 60)),
				float(module_rng.randi_range(90, 300)),
				float(module_rng.randi_range(20, 50))),
			"alpha": 1.0,
		})

	for hr in _highlight_rects:
		hr["alpha"] = move_toward(float(hr.alpha), 0.0, delta * 0.38)
	_highlight_rects = _highlight_rects.filter(func(hr): return float(hr.alpha) > 0.01)

# ─── Monitor 4 update ─────────────────────────────────────────────────────────
func _update_monitor4(delta: float) -> void:
	_confidence = move_toward(_confidence, _conf_target, delta * 0.11)

	# Faster logging during active events
	var log_rate := _log_interval
	if _state == SigState.PATTERN_LOCK or _state == SigState.RARE_EVENT:
		log_rate = _log_interval * 0.35

	_log_timer -= delta
	if _log_timer <= 0.0:
		_log_timer = _rand_range(log_rate * 0.6, log_rate * 1.4)
		_log_lines.append(_timestamped(_LOG_POOL[module_rng.randi() % _LOG_POOL.size()]))
		if _log_lines.size() > 14:
			_log_lines.pop_front()

	_verdict_timer -= delta
	if _verdict_timer <= 0.0:
		_verdict_timer = _rand_range(8.0, 22.0)
		if _state == SigState.IDLE_SCAN:
			_verdict = _VERDICTS[module_rng.randi() % 2]

# ─── Draw ─────────────────────────────────────────────────────────────────────
func _draw() -> void:
	draw_rect(Rect2(0.0, 0.0, float(PW), float(PH * 4)), C_BG)

	_draw_monitor1()
	_draw_monitor2()
	_draw_monitor3()
	_draw_monitor4()

	# CRT scanlines — horizontal lines every 4px across all four panels
	var scan_col := Color(0.0, 0.0, 0.0, 0.18)
	var y := 0.0
	while y < float(PH * 4):
		draw_line(Vector2(0.0, y), Vector2(float(PW), y), scan_col, 1.0)
		y += 4.0

	# Rare event frame alert: tint panel frames red/amber
	if _frame_alert_alpha > 0.01:
		var ac := Color(C_RED.r, C_RED.g, C_RED.b, _frame_alert_alpha * 0.55)
		for pi in 4:
			var py := float(pi * PH)
			draw_line(Vector2(6.0, py + 6.0),   Vector2(float(PW) - 6.0, py + 6.0),   ac, 2.0)
			draw_line(Vector2(6.0, py + PH - 6.0), Vector2(float(PW) - 6.0, py + PH - 6.0), ac, 2.0)
			draw_line(Vector2(6.0, py + 6.0),   Vector2(6.0, py + PH - 6.0),           ac, 2.0)
			draw_line(Vector2(float(PW) - 6.0, py + 6.0), Vector2(float(PW) - 6.0, py + PH - 6.0), ac, 2.0)

	# Rare event full-screen flash + text on every panel
	if _rare_flash > 0.01:
		draw_rect(Rect2(0.0, 0.0, float(PW), float(PH * 4)),
			Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, _rare_flash * 0.08))
		if _rare_text != "":
			for pi in 4:
				_draw_text_centered(_rare_text,
					Vector2(PW / 2.0, float(pi * PH + PH / 2 - 10)),
					Color(C_WHITE.r, C_WHITE.g, C_WHITE.b, _rare_flash), 15)

	# Wind-down fade to black
	if _winding_down:
		var alpha: float = clamp(_wind_down_timer / _WIND_DOWN_DUR, 0.0, 1.0)
		draw_rect(Rect2(0.0, 0.0, float(PW), float(PH * 4)), Color(0.0, 0.0, 0.0, alpha))

# ─── Monitor 1: Acquisition ──────────────────────────────────────────────────
func _draw_monitor1() -> void:
	_draw_panel_frame(P0Y, "SIGNAL ACQUISITION — SECTOR 7-G")

	var cx := float(SCOPE_CX)
	var cy := float(SCOPE_CY)
	var r  := float(SCOPE_R)

	# Stars
	for star in _stars:
		var flicker := 0.5 + 0.5 * sin(_station_time * 1.3 + float(star.f))
		draw_circle(Vector2(float(star.x), float(star.y)), 1.2,
			Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b, float(star.b) * flicker * 0.7))

	# Scope concentric rings
	for i in 4:
		draw_arc(Vector2(cx, cy), r * float(i + 1) / 4.0, 0.0, TAU, 64,
			Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b, 0.32), 1.0)

	# Crosshairs
	var ch := Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b, 0.28)
	draw_line(Vector2(cx - r, cy), Vector2(cx + r, cy), ch, 1.0)
	draw_line(Vector2(cx, cy - r), Vector2(cx, cy + r), ch, 1.0)

	# Outer ring
	draw_arc(Vector2(cx, cy), r, 0.0, TAU, 96,
		Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.70), 1.5)

	# Sweep fan (phosphor trail)
	var fan := PI / 5.0
	for i in 20:
		var frac := float(i) / 19.0
		var ang  := _sweep_angle - fan * (1.0 - frac)
		var end  := Vector2(cx + cos(ang) * r, cy + sin(ang) * r)
		draw_line(Vector2(cx, cy), end,
			Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, frac * 0.50), 1.0)

	# Sweep leading edge — phosphor glow (3 passes: wide dim → medium → narrow bright)
	var lead_end := Vector2(cx + cos(_sweep_angle) * r, cy + sin(_sweep_angle) * r)
	draw_line(Vector2(cx, cy), lead_end, Color(C_GREEN_B.r, C_GREEN_B.g, C_GREEN_B.b, 0.12), 6.0)
	draw_line(Vector2(cx, cy), lead_end, Color(C_GREEN_B.r, C_GREEN_B.g, C_GREEN_B.b, 0.30), 3.0)
	draw_line(Vector2(cx, cy), lead_end, Color(C_GREEN_B.r, C_GREEN_B.g, C_GREEN_B.b, 0.90), 1.5)

	# Lock marker with pulse blink
	if _lock_alpha > 0.01:
		var lx   := cx + cos(_lock_angle) * r * 0.62
		var ly   := cy + sin(_lock_angle) * r * 0.62
		var pulse := 0.6 + 0.4 * sin(_lock_pulse)
		var lc   := Color(C_RED.r, C_RED.g, C_RED.b, _lock_alpha * pulse)
		var ls   := 13.0
		# Glow halo behind marker
		draw_arc(Vector2(lx, ly), ls * 1.8, 0.0, TAU, 20,
			Color(C_RED.r, C_RED.g, C_RED.b, _lock_alpha * pulse * 0.15), 6.0)
		draw_arc(Vector2(lx, ly), ls * 0.9, 0.0, TAU, 20, lc, 2.0)
		draw_line(Vector2(lx - ls * 1.4, ly), Vector2(lx - ls * 0.5, ly), lc, 1.5)
		draw_line(Vector2(lx + ls * 0.5, ly), Vector2(lx + ls * 1.4, ly), lc, 1.5)
		draw_line(Vector2(lx, ly - ls * 1.4), Vector2(lx, ly - ls * 0.5), lc, 1.5)
		draw_line(Vector2(lx, ly + ls * 0.5), Vector2(lx, ly + ls * 1.4), lc, 1.5)

	# Echo rings expanding from lock position
	for er in _echo_rings:
		var ea := float(er.alpha)
		if ea > 0.01:
			draw_arc(Vector2(float(er.x), float(er.y)), float(er.r), 0.0, TAU, 32,
				Color(C_RED.r, C_RED.g, C_RED.b, ea * 0.70), 1.5)

	# Signal strength history graph
	var gw := 460.0
	var gh := 72.0
	var gx := (float(PW) - gw) / 2.0
	var gy := float(P0Y + PH) - gh - 22.0
	draw_rect(Rect2(gx, gy, gw, gh), Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b, 0.10))
	_draw_rect_outline(Rect2(gx, gy, gw, gh), Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.35))
	_draw_text(">SIG STR", Vector2(gx, gy - 15.0), C_AMBER_D, 11)

	if _strength_hist.size() > 1:
		var pts := PackedVector2Array()
		for i in _strength_hist.size():
			var px := gx + float(i) / float(HIST_LEN - 1) * gw
			var py := gy + gh - float(_strength_hist[i]) * (gh - 4.0)
			pts.append(Vector2(px, py))
		draw_polyline(pts, C_GREEN, 1.5)

	# Side readouts
	var sx := 18.0
	var sy := float(P0Y) + 65.0
	_draw_text("RA  : %05.1f" % fmod(_sweep_angle * (180.0 / PI), 360.0),
		Vector2(sx, sy), C_GREEN_D, 11)
	_draw_text("FREQ: 1420.4 MHZ",  Vector2(sx, sy + 20.0), C_GREEN_D, 11)
	_draw_text("GAIN: +%02d DB" % int(_signal_strength * 40.0 + 8.0),
		Vector2(sx, sy + 40.0), C_GREEN_D, 11)
	_draw_text("MODE: SWEEP",        Vector2(sx, sy + 60.0), C_GREEN_D, 11)

	# Status label
	var st_text := ""
	var st_col  := C_GREEN
	match _state:
		SigState.IDLE_SCAN:       st_text = "SCANNING..."
		SigState.WEAK_SIGNAL:     st_text = "SIGNAL DETECTED";     st_col = C_GREEN_B
		SigState.PATTERN_LOCK:    st_text = "LOCK ACQUIRED";        st_col = C_WHITE
		SigState.SIGNAL_COLLAPSE: st_text = "SIGNAL LOST";          st_col = C_AMBER
		SigState.RARE_EVENT:      st_text = "** ANOMALY DETECTED **"; st_col = C_RED

	_draw_text_centered(st_text, Vector2(cx, float(P0Y + PH) - 8.0), st_col, 13)

# ─── Monitor 2: Raw signal ───────────────────────────────────────────────────
func _draw_monitor2() -> void:
	_draw_panel_frame(P1Y, "RAW SIGNAL STREAM — CH A / B / C")

	var channels := [
		{"pts": _wave_primary,   "cy_off": 180, "h": 95.0,  "col": C_GREEN,   "label": "CH-A PRIMARY"},
		{"pts": _wave_secondary, "cy_off": 370, "h": 55.0,  "col": C_AMBER,   "label": "CH-B SECONDARY"},
		{"pts": _wave_noise,     "cy_off": 530, "h": 36.0,  "col": C_GREEN_D, "label": "CH-C NOISE REF"},
	]

	for chi in channels.size():
		var ch: Dictionary = channels[chi]
		var label: String  = ch.label
		var col: Color     = ch.col
		var cy: float      = float(P1Y) + float(ch.cy_off)
		var h: float       = ch.h
		var pts: Array     = ch.pts

		_draw_text(label, Vector2(10.0, cy - h - 7.0), col * Color(1, 1, 1, 0.65), 11)
		draw_line(Vector2(0.0, cy), Vector2(float(PW), cy),
			Color(col.r, col.g, col.b, 0.14), 1.0)
		draw_line(Vector2(0.0, cy - h), Vector2(float(PW), cy - h),
			Color(col.r, col.g, col.b, 0.07), 1.0)
		draw_line(Vector2(0.0, cy + h), Vector2(float(PW), cy + h),
			Color(col.r, col.g, col.b, 0.07), 1.0)

		if pts.size() > 1:
			var n := pts.size()
			var wave_pts := PackedVector2Array()
			for i in n:
				var wx := float(i) / float(n - 1) * float(PW)
				# Apply glitch x-offset (only on primary/secondary channels)
				var gx_off := 0.0
				if _glitch_active and chi < 2 and i < _glitch_offsets.size():
					gx_off = float(_glitch_offsets[i])
				var wy := cy + float(pts[i]) * h
				wave_pts.append(Vector2(wx + gx_off, wy))
			draw_polyline(wave_pts, col, 1.5)

	# Carrier line
	if _carrier_alpha > 0.02:
		var ccy := float(P1Y + 295)
		var cc  := Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, _carrier_alpha * 0.70)
		draw_line(Vector2(0.0, ccy), Vector2(float(PW), ccy), cc, 1.0)
		_draw_text("CARRIER 1420.405 MHZ", Vector2(10.0, ccy - 14.0), cc, 11)

	# Stream texts: stacked at bottom of panel (below all waveforms)
	var slot_y0 := float(P1Y + PH) - 108.0
	for st in _stream_texts:
		var alpha: float = float(st.alpha)
		if alpha > 0.01:
			var slot_y := slot_y0 + float(int(st.slot)) * 18.0
			_draw_text(st.text, Vector2(14.0, slot_y),
				Color(C_AMBER_D.r, C_AMBER_D.g, C_AMBER_D.b, alpha * 0.80), 10)

# ─── Monitor 3: Decryption ───────────────────────────────────────────────────
func _draw_monitor3() -> void:
	_draw_panel_frame(P2Y, "DECRYPTION — PATTERN EXTRACTION")

	var row_h := 30.0
	var x0    := 20.0
	var y0    := float(P2Y + 52)

	for i in _decrypt_rows.size():
		var row_y := y0 + float(i) * row_h
		if row_y > float(P2Y + PH) - 90.0:
			break
		var col := C_GREEN_D
		if _decrypt_rows[i].begins_with("HEX"):
			col = C_AMBER_D
		elif _decrypt_rows[i].begins_with("ERR") or _decrypt_rows[i].begins_with("CRC"):
			col = Color(C_RED.r, C_RED.g, C_RED.b, 0.45)
		elif _decrypt_rows[i] == "...REPEAT...REPEAT...":
			col = Color(C_WHITE.r, C_WHITE.g, C_WHITE.b, 0.85)
		_draw_text(_decrypt_rows[i], Vector2(x0, row_y), col, 11)

	# Active fragment block
	if _frag_alpha > 0.02 and _frag_text != "":
		var fy := float(P2Y + 530)
		draw_rect(Rect2(16.0, fy - 4.0, 620.0, 28.0),
			Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, _frag_alpha * 0.07))
		_draw_rect_outline(Rect2(16.0, fy - 4.0, 620.0, 28.0),
			Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, _frag_alpha * 0.40))
		_draw_text("> " + _frag_text, Vector2(24.0, fy),
			Color(C_WHITE.r, C_WHITE.g, C_WHITE.b, _frag_alpha), 13)

	# Error text
	if _err_alpha > 0.02:
		_draw_text(_err_text, Vector2(x0, float(P2Y + PH) - 42.0),
			Color(C_RED.r, C_RED.g, C_RED.b, _err_alpha), 12)

	# Highlight boxes
	for hr in _highlight_rects:
		var hc := Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, float(hr.alpha) * 0.55)
		draw_rect(hr.rect, Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, float(hr.alpha) * 0.06))
		_draw_rect_outline(hr.rect, hc)

# ─── Monitor 4: Interpretation ───────────────────────────────────────────────
func _draw_monitor4() -> void:
	_draw_panel_frame(P3Y, "INTERPRETATION — THREAT ASSESSMENT")

	var bx    := 20.0
	var bar_y := float(P3Y) + 58.0
	var bw    := 480.0
	var bh    := 26.0

	# Confidence meter
	_draw_text("CONFIDENCE", Vector2(bx, bar_y - 15.0), C_GREEN_D, 11)
	draw_rect(Rect2(bx, bar_y, bw, bh), Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b, 0.15))
	# Fill color shifts to red at high threat
	var fill_col := C_GREEN if _threat < 2 else C_AMBER
	if _state == SigState.RARE_EVENT: fill_col = C_RED
	draw_rect(Rect2(bx, bar_y, _confidence * bw, bh),
		Color(fill_col.r, fill_col.g, fill_col.b, 0.65))
	_draw_rect_outline(Rect2(bx, bar_y, bw, bh), Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.50))
	_draw_text("%d%%" % int(_confidence * 100.0),
		Vector2(bx + _confidence * bw + 6.0, bar_y + 5.0), C_GREEN, 13)
	# Tick marks on confidence bar
	for ti in 9:
		var tx := bx + float(ti + 1) * bw / 10.0
		draw_line(Vector2(tx, bar_y + bh - 6.0), Vector2(tx, bar_y + bh),
			Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.50), 1.0)

	# Threat indicator
	var threat_y := bar_y + bh + 22.0
	_draw_text("THREAT LEVEL", Vector2(bx, threat_y), C_GREEN_D, 11)
	var threat_labels := ["LOW", "MEDIUM", "HIGH"]
	var threat_colors := [C_GREEN, C_AMBER, C_RED]
	for tii in 3:
		var tx   := bx + float(tii) * 172.0
		var ty   := threat_y + 18.0
		var col: Color = threat_colors[tii]
		var active := (tii == _threat)
		draw_rect(Rect2(tx, ty, 155.0, 26.0), Color(col.r, col.g, col.b,
			0.14 if active else 0.04))
		_draw_rect_outline(Rect2(tx, ty, 155.0, 26.0), Color(col.r, col.g, col.b,
			0.55 if active else 0.18))
		_draw_text_centered(threat_labels[tii], Vector2(tx + 77.5, ty + 7.0),
			Color(col.r, col.g, col.b, 0.90 if active else 0.35), 12)

	# Verdict / recommendation
	var vy := threat_y + 64.0
	_draw_text("VERDICT  : " + _verdict,        Vector2(bx, vy),        C_WHITE * Color(1,1,1,0.88), 13)
	_draw_text("ACTION   : " + _recommendation, Vector2(bx, vy + 24.0), C_AMBER * Color(1,1,1,0.82), 12)

	# Separator
	var sep_y := vy + 58.0
	draw_line(Vector2(10.0, sep_y), Vector2(float(PW) - 10.0, sep_y),
		Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.38), 1.0)

	# Timestamped log lines
	var ly0     := sep_y + 14.0
	var line_h  := 32.0
	var max_vis := int((float(P3Y + PH) - ly0 - 24.0) / line_h)
	var start_i: int = max(0, _log_lines.size() - max_vis)
	for i in range(start_i, _log_lines.size()):
		var row_y := ly0 + float(i - start_i) * line_h
		if row_y > float(P3Y + PH) - 16.0:
			break
		var age_frac: float = float(i - start_i) / float(max(max_vis - 1, 1))
		var log_col := Color(C_GREEN_D.r, C_GREEN_D.g, C_GREEN_D.b,
			lerp(0.72, 0.22, age_frac))
		_draw_text(_log_lines[i], Vector2(bx, row_y), log_col, 10)

	# Station clock
	_draw_text("T+%07d" % int(_station_time),
		Vector2(float(PW) - 115.0, float(P3Y + PH) - 18.0), C_GREEN_D, 11)

# ─── Shared draw helpers ──────────────────────────────────────────────────────
func _draw_panel_frame(py: int, title: String) -> void:
	var m  := 6.0
	var x0 := m
	var y0 := float(py) + m
	var x1 := float(PW) - m
	var y1 := float(py + PH) - m
	var fc := Color(C_FRAME.r, C_FRAME.g, C_FRAME.b, 0.55)
	draw_line(Vector2(x0, y0), Vector2(x1, y0), fc, 1.5)
	draw_line(Vector2(x0, y1), Vector2(x1, y1), fc, 1.5)
	draw_line(Vector2(x0, y0), Vector2(x0, y1), fc, 1.5)
	draw_line(Vector2(x1, y0), Vector2(x1, y1), fc, 1.5)
	_draw_corner(Vector2(x0, y0),  1.0,  1.0, fc)
	_draw_corner(Vector2(x1, y0), -1.0,  1.0, fc)
	_draw_corner(Vector2(x0, y1),  1.0, -1.0, fc)
	_draw_corner(Vector2(x1, y1), -1.0, -1.0, fc)
	_draw_text(" " + title + " ", Vector2(26.0, float(py) + 20.0),
		Color(C_GREEN.r, C_GREEN.g, C_GREEN.b, 0.82), 12)

func _draw_corner(pos: Vector2, dx: float, dy: float, col: Color) -> void:
	var s := 10.0
	draw_line(pos, pos + Vector2(dx * s, 0.0), col, 1.5)
	draw_line(pos, pos + Vector2(0.0, dy * s), col, 1.5)

func _draw_rect_outline(rect: Rect2, col: Color) -> void:
	draw_line(rect.position, Vector2(rect.end.x, rect.position.y), col, 1.0)
	draw_line(Vector2(rect.end.x, rect.position.y), rect.end, col, 1.0)
	draw_line(rect.end, Vector2(rect.position.x, rect.end.y), col, 1.0)
	draw_line(Vector2(rect.position.x, rect.end.y), rect.position, col, 1.0)

func _draw_text(txt: String, pos: Vector2, col: Color, size: int) -> void:
	if _font:
		draw_string(_font, pos + Vector2(0.0, float(size)),
			txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_text_centered(txt: String, pos: Vector2, col: Color, size: int) -> void:
	if _font:
		draw_string(_font, pos + Vector2(0.0, float(size) * 0.5),
			txt, HORIZONTAL_ALIGNMENT_CENTER, PW, size, col)

# ─── Content helpers ──────────────────────────────────────────────────────────
func _random_decrypt_line() -> String:
	var roll := module_rng.randf()
	if roll < 0.38:
		return _BINARY_POOL[module_rng.randi() % _BINARY_POOL.size()]
	elif roll < 0.68:
		return _HEX_POOL[module_rng.randi() % _HEX_POOL.size()]
	else:
		return _FRAG_POOL[module_rng.randi() % _FRAG_POOL.size()]

func _timestamped(txt: String) -> String:
	return "[T+%06d] " % int(_station_time) + txt

func _rand_range(a: float, b: float) -> float:
	return module_rng.randf_range(a, b)
