## DataCascade — matrix-rain-style glyphs falling vertically through all panels.
## Uses VirtualSpace math so columns disappear in bezel gaps and reappear seamlessly.
## Drawn via _draw() each frame.
extends Node2D

var module_id := "data_cascade"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

# ─── Private state ────────────────────────────────────────────────────────────
var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false
var _winding_down := false
var _wind_down_timer := 0.0
var _wind_down_dur := 2.0

# Column data
const CHAR_W := 16
const CHAR_H := 20
const TRAIL_LENGTH := 24      # chars in each trail
const UPDATE_INTERVAL := 0.06 # seconds between character scramble (~15 fps for chars)

var _columns: Array[Dictionary] = []   # per-column state
var _char_timer := 0.0

# Character set — Japanese katakana + Korean hangul syllables
const CHARSET: Array[String] = [
	"ア","イ","ウ","エ","オ","カ","キ","ク","ケ","コ",
	"サ","シ","ス","セ","ソ","タ","チ","ツ","テ","ト",
	"ナ","ニ","ヌ","ネ","ノ","ハ","ヒ","フ","ヘ","ホ",
	"マ","ミ","ム","メ","モ","ヤ","ユ","ヨ","ラ","リ",
	"ル","レ","ロ","ワ","ヲ","ン","ヴ","ガ","ギ","グ",
	"가","나","다","라","마","바","사","아","자","차",
	"카","타","파","하","고","노","도","로","모","보",
	"소","오","조","초","코","토","포","호","구","누",
	"두","루","무","부","수","우","주","추","쿠","투",
]

# Real viewport dimensions
var _vp_w: int = 1024
var _vp_h: int = 3072

# Colors
const COLOR_HEAD := Color(0.8, 1.0, 0.85, 1.0)
const COLOR_BRIGHT := Color(0.2, 1.0, 0.4, 0.9)
const COLOR_MID := Color(0.0, 0.8, 0.3, 0.6)
const COLOR_TAIL := Color(0.0, 0.5, 0.2, 0.15)

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
	_char_timer = 0.0

	var total := _panel_layout.get_total_real_size()
	_vp_w = total.x
	_vp_h = total.y

	_init_columns()

func _init_columns() -> void:
	_columns.clear()
	var num_cols := int(_vp_w / CHAR_W)
	for i in num_cols:
		_columns.append(_make_column(i, true))

func _make_column(col_index: int, randomize_start: bool) -> Dictionary:
	var virt_h := _virtual_space.virtual_height()
	var speed := module_rng.randf_range(150.0, 500.0)
	var start_vy := 0.0
	if randomize_start:
		start_vy = module_rng.randf_range(-virt_h, virt_h)

	# Generate initial character trail
	var chars: Array[String] = []
	for j in TRAIL_LENGTH:
		chars.append(_random_char())

	return {
		"col_index": col_index,
		"x": col_index * CHAR_W,
		"virtual_y": start_vy,
		"speed": speed,
		"chars": chars,
		"active": true,
	}

func _random_char() -> String:
	return CHARSET[module_rng.randi() % CHARSET.size()]

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wind_down_timer += delta
		if _wind_down_timer >= _wind_down_dur:
			_finished = true
			return

	# Advance column virtual positions
	var virt_h := _virtual_space.virtual_height()
	for col in _columns:
		if not col["active"]:
			continue
		col["virtual_y"] = col["virtual_y"] + col["speed"] * delta
		# Wrap
		if col["virtual_y"] > virt_h + float(TRAIL_LENGTH * CHAR_H):
			col["virtual_y"] = -float(TRAIL_LENGTH * CHAR_H)

	# Scramble characters periodically
	_char_timer += delta
	if _char_timer >= UPDATE_INTERVAL:
		_char_timer = 0.0
		for col in _columns:
			# Shift trail down and add new char at top
			var chars: Array = col["chars"]
			chars.pop_back()
			chars.insert(0, _random_char())

	queue_redraw()

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var alpha_scale := 1.0
	if _winding_down:
		alpha_scale = clampf(1.0 - _wind_down_timer / _wind_down_dur, 0.0, 1.0)

	for col in _columns:
		if not col["active"]:
			continue
		_draw_column(col, alpha_scale)

func _draw_column(col: Dictionary, alpha_scale: float) -> void:
	var x: float = float(col["x"])
	var head_vy: float = col["virtual_y"]
	var chars: Array = col["chars"]

	for i in TRAIL_LENGTH:
		# Each char is at vy = head_vy - i * CHAR_H (trail goes upward)
		var char_vy := head_vy - float(i) * float(CHAR_H)

		# Skip if above virtual top
		if char_vy < -float(CHAR_H):
			continue

		var mapping := _virtual_space.virtual_to_real(char_vy)
		if not mapping["visible"]:
			continue

		var real_y: float = mapping["real_y"]
		# Skip if outside real viewport
		if real_y < -float(CHAR_H) or real_y > float(_vp_h):
			continue

		# Determine color based on position in trail
		var t := float(i) / float(TRAIL_LENGTH)  # 0=head, 1=tail
		var col_color: Color
		if i == 0:
			col_color = Color(COLOR_HEAD.r, COLOR_HEAD.g, COLOR_HEAD.b, COLOR_HEAD.a * alpha_scale)
		elif i < 3:
			col_color = Color(COLOR_BRIGHT.r, COLOR_BRIGHT.g, COLOR_BRIGHT.b, COLOR_BRIGHT.a * alpha_scale)
		elif i < TRAIL_LENGTH / 2:
			var blend := float(i - 2) / float(TRAIL_LENGTH / 2 - 2)
			col_color = COLOR_BRIGHT.lerp(COLOR_MID, blend)
			col_color.a *= alpha_scale
		else:
			var blend := float(i - TRAIL_LENGTH / 2) / float(TRAIL_LENGTH / 2)
			col_color = COLOR_MID.lerp(COLOR_TAIL, blend)
			col_color.a *= alpha_scale

		var ch: String = chars[i]
		draw_string(ThemeDB.fallback_font, Vector2(x, real_y + float(CHAR_H) * 0.8),
					ch, HORIZONTAL_ALIGNMENT_LEFT, -1, CHAR_H - 2, col_color)

func module_status() -> Dictionary:
	return {
		"ok": true,
		"notes": "%d columns" % _columns.size(),
		"intensity": 0.7
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down = true
	_wind_down_timer = 0.0
	Log.debug("DataCascade: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_columns.clear()
