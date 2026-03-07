## BerlinIconsScroll — white-on-black Berlin icon silhouettes scrolling vertically
## through all panels. Uses VirtualSpace bezel-gap math so icons disappear cleanly
## in dead zones and reappear on the next panel with correct timing.
## Icons are drawn via _draw() using map_virtual_rect_to_segments().
## Glitch pulses applied via CRT shader overlay (GlitchLayer/GlitchOverlay).
extends Node2D

var module_id := "berlin_icons"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

# ─── Private state ─────────────────────────────────────────────────────────────
var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false
var _winding_down := false
var _wind_down_timer := 0.0
const WIND_DOWN_DUR := 1.5

# ─── Scroll config ─────────────────────────────────────────────────────────────
const BASE_SPEED := 60.0          # px/sec in virtual space
const ICON_SIZE  := 96.0          # display size (virtual px, square)
const MAX_ICONS  := 18

var _scroll_direction := 1        # 1 = down, -1 = up
var _scroll_speed    := BASE_SPEED

# ─── Glitch ────────────────────────────────────────────────────────────────────
var _glitch_intensity := 0.0
var _glitch_timer     := 0.0
var _glitch_next      := 0.0      # seconds until next blip

# ─── Assets ────────────────────────────────────────────────────────────────────
const ICONS_DIR := "res://modules/berlin_icons/icons/"
var _textures: Array[Texture2D] = []
var _icons: Array[Dictionary]   = []

# ─── Cached node ref ───────────────────────────────────────────────────────────
var _glitch_mat: ShaderMaterial = null

# ══════════════════════════════════════════════════════════════════════════════
# Module contract
# ══════════════════════════════════════════════════════════════════════════════

func module_configure(ctx: Dictionary) -> void:
	_manifest      = ctx["manifest"]
	module_rng     = RNG.make_rng(ctx["seed"])
	_panel_layout  = ctx["panel_layout"]
	_virtual_space = ctx["virtual_space"]


func module_start() -> void:
	module_started_at  = App.station_time
	_stop_requested    = false
	_finished          = false
	_winding_down      = false
	_wind_down_timer   = 0.0
	_glitch_intensity  = 0.0
	_glitch_timer      = 0.0
	_glitch_next       = module_rng.randf_range(2.0, 8.0)

	# Randomise direction (mostly down, occasionally up)
	_scroll_direction = 1 if module_rng.randf() > 0.25 else -1
	_scroll_speed     = BASE_SPEED + module_rng.randf_range(-10.0, 20.0)

	_icons.clear()
	_load_textures()

	# Cache shader material
	var overlay := get_node_or_null("GlitchLayer/GlitchOverlay")
	if overlay:
		_glitch_mat = overlay.material as ShaderMaterial

	# Pre-populate icons spread across the full virtual height
	if not _textures.is_empty():
		for _i in MAX_ICONS:
			_spawn_icon_random()


func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "icons:%d spd:%.0f dir:%d" % [_icons.size(), _scroll_speed, _scroll_direction],
		"intensity": clamp(_scroll_speed / 200.0, 0.1, 0.9),
	}


func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down   = true
	Log.debug("BerlinIconsScroll: stop requested: " + reason)


func module_is_finished() -> bool:
	return _finished


func module_shutdown() -> void:
	_icons.clear()
	_textures.clear()
	_glitch_mat = null


# ══════════════════════════════════════════════════════════════════════════════
# Per-frame logic
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if _textures.is_empty():
		return

	# Wind-down: accelerate until icons blur off, then finish
	if _winding_down:
		_wind_down_timer += delta
		_scroll_speed = BASE_SPEED * (1.0 + _wind_down_timer * 4.0)
		if _wind_down_timer >= WIND_DOWN_DUR:
			_finished = true
			return

	# Glitch pulse timing
	_glitch_timer += delta
	if _glitch_timer >= _glitch_next:
		_glitch_intensity = module_rng.randf_range(0.3, 0.9)
		_glitch_timer     = 0.0
		_glitch_next      = module_rng.randf_range(0.3, 2.5)
	else:
		_glitch_intensity = max(0.0, _glitch_intensity - delta * 10.0)

	# Push intensity to shader
	if _glitch_mat:
		_glitch_mat.set_shader_parameter("intensity",  _glitch_intensity)
		_glitch_mat.set_shader_parameter("time_seed",  App.station_time)

	_update_icons(delta)
	queue_redraw()


# ══════════════════════════════════════════════════════════════════════════════
# Icon lifecycle
# ══════════════════════════════════════════════════════════════════════════════

func _load_textures() -> void:
	_textures.clear()
	var dir := DirAccess.open(ICONS_DIR)
	if dir == null:
		Log.warn("BerlinIconsScroll: icons dir not found: " + ICONS_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() == "png":
			var tex: Texture2D = load(ICONS_DIR + fname)
			if tex:
				_textures.append(tex)
		fname = dir.get_next()
	dir.list_dir_end()
	Log.info("BerlinIconsScroll: loaded %d textures" % _textures.size())


func _spawn_icon_random() -> void:
	var tex: Texture2D = _textures[module_rng.randi() % _textures.size()]
	var vb  := _virtual_space.virtual_bounds
	_icons.append({
		"texture":  tex,
		"position": Vector2(
			module_rng.randf_range(0.0, vb.size.x - ICON_SIZE),
			module_rng.randf_range(0.0, vb.size.y)
		),
		"size":     Vector2(ICON_SIZE, ICON_SIZE),
		"speed":    _scroll_speed + module_rng.randf_range(-15.0, 15.0),
		"wobble":   module_rng.randf_range(0.0, TAU),
	})


func _update_icons(delta: float) -> void:
	var vb := _virtual_space.virtual_bounds
	for icon in _icons:
		icon["position"].y += float(_scroll_direction) * icon["speed"] * delta
		icon["wobble"]      += delta * 1.6
		# Subtle horizontal drift
		icon["position"].x  += sin(icon["wobble"]) * 7.0 * delta
		# Clamp X so icons stay on screen
		icon["position"].x   = clamp(icon["position"].x, 0.0, vb.size.x - ICON_SIZE)
		# Wrap Y through virtual space — seamless bezel crossing
		icon["position"]     = _virtual_space.wrap_point(icon["position"])


# ══════════════════════════════════════════════════════════════════════════════
# Drawing — bezel-aware via map_virtual_rect_to_segments
# ══════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	for icon in _icons:
		_draw_icon(icon)


func _draw_icon(icon: Dictionary) -> void:
	var tex: Texture2D = icon["texture"]
	if tex == null:
		return

	var virtual_rect := Rect2(icon["position"], icon["size"])
	var jobs         := _virtual_space.map_virtual_rect_to_segments(virtual_rect)
	var tex_size     := tex.get_size()
	var icon_size    : Vector2 = icon["size"]
	var sx           := tex_size.x / icon_size.x
	var sy           := tex_size.y / icon_size.y

	for job in jobs:
		var real_rect : Rect2 = job["real_rect"]
		var src       : Rect2 = job["source_rect"]
		# Scale source_rect from virtual-icon pixels to texture pixels
		var tex_src := Rect2(src.position.x * sx, src.position.y * sy,
				src.size.x * sx, src.size.y * sy)

		var color := Color.WHITE
		# Rare per-icon glitch: colour inversion or channel shift
		if _glitch_intensity > 0.0 and module_rng.randf() < _glitch_intensity * 0.04:
			var r := module_rng.randf_range(0.5, 1.0)
			var g := module_rng.randf_range(0.5, 1.0)
			var b := module_rng.randf_range(0.5, 1.0)
			color = Color(r, g, b, 1.0)

		draw_texture_rect_region(tex, real_rect, tex_src, color)
