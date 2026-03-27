## PacMan — Pac-Man travels vertically through all four panels chased by four ghosts.
## SVG ghosts are recoloured per character (Blinky/Pinky/Inky/Clyde) via inline shader.
## Pac-Man is drawn procedurally as an animated pie slice; pellets and maze corridors
## are drawn with _draw().  Ghost sprites use ghost.svg from modules/pacman/images/.
##
## Power pellets appear only on one randomly chosen panel per run.  When eaten:
##   - Ghosts turn navy blue and flee downward off the bottom of virtual space.
##   - Pac-Man reverses direction (moves upward, chasing the fleeing ghosts).
##   - Once all ghosts have exited the bottom of virtual space, Pac-Man flips
##     back to downward travel and ghosts respawn trailing behind in normal colours.
extends Node2D

var module_id         := "pac_man"
var module_rng        : RandomNumberGenerator
var module_started_at := 0.0

var _manifest      : Dictionary
var _panel_layout  : PanelLayout
var _virtual_space : VirtualSpace
var _stop_requested := false
var _finished       := false

# ── Palette ───────────────────────────────────────────────────────────────────
const C_PACMAN := Color(1.00, 0.90, 0.00, 1.0)   # arcade yellow
const C_DOT    := Color(1.00, 0.95, 0.85, 0.90)   # pellet cream
const C_POWER  := Color(1.00, 0.95, 0.85, 0.95)   # power pellet
const C_MAZE   := Color(0.12, 0.22, 0.82, 0.85)   # blue maze walls
const C_SCORE  := Color(1.00, 1.00, 1.00, 0.90)   # score text
const C_LABEL  := Color(0.80, 0.80, 0.80, 0.70)   # dim ui labels
const C_BG     := Color(0.01, 0.01, 0.06, 1.0)    # near-black background
const C_NAVY   := Color(0.00, 0.08, 0.52, 1.0)    # frightened ghost navy blue

# Ghost body colours — Blinky (red), Pinky (pink), Inky (cyan), Clyde (orange)
const GHOST_COLORS := [
	Color(1.00, 0.18, 0.18, 1.0),
	Color(1.00, 0.72, 0.90, 1.0),
	Color(0.20, 0.90, 1.00, 1.0),
	Color(1.00, 0.72, 0.30, 1.0),
]
const GHOST_NAMES := ["BLINKY", "PINKY", "INKY", "CLYDE"]

# Ghost body-recolour shader.
# ghost.svg body is orange (~#FFA05A).  Eyes are white + blue.
# "Orangeness" = R-B channel gap: high for orange body, ~0 for white, negative for blue.
# We lerp body pixels toward ghost_color (preserving brightness variation),
# while leaving white and blue eye pixels intact.
const GHOST_SHADER_SRC := """
shader_type canvas_item;
uniform vec4 ghost_color : source_color = vec4(1.0, 0.2, 0.2, 1.0);
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float orangeness = clamp((tex.r - tex.b) * 2.0, 0.0, 1.0);
    vec3 tinted = ghost_color.rgb * (tex.r * 0.85 + 0.15);
    COLOR = vec4(mix(tex.rgb, tinted, orangeness), tex.a);
}
"""

# ── Animation constants ────────────────────────────────────────────────────────
const SPEED_VPX_SEC   := 200.0   # virtual pixels/sec  (full loop ≈ 23 s)
const PACMAN_R        := 52.0    # Pac-Man radius in real pixels
const GHOST_R         := 48.0    # ghost half-height in real pixels
const GHOST_SPACING_V := 108.0   # virtual px gap between successive ghosts (20% wider than original)
const DOT_SPACING_V   := 48.0    # virtual px between pellets
const POWER_EVERY     := 8       # every Nth pellet on the power panel is a power pellet
const MOUTH_SPEED     := 7.0     # rad/sec for mouth open-close oscillation

# ── Runtime state ──────────────────────────────────────────────────────────────
var _pw        := 0.0
var _ph        := 0.0
var _virtual_h := 0.0
var _track_x   := 0.0   # real-x of the vertical track (screen centre)
var _block     := 0.0   # PANEL_H + BEZEL_GAP in virtual px (1280)

var _virt_y    := 0.0   # Pac-Man virtual Y
var _mouth_t   := 0.0   # drives mouth angle oscillation
var _score     := 0
var _direction := 1.0   # +1.0 = moving down, -1.0 = moving up

var _dot_vy        : Array[float] = []   # virtual Y position for each pellet
var _eaten         : Dictionary   = {}   # int(vy) → true once eaten
var _power_dot_vys : Dictionary   = {}   # int(vy) → true for power pellets (one panel only)
var _power_panel   := 0                  # which panel (0-3) holds power pellets this run

# ── Power mode ────────────────────────────────────────────────────────────────
var _power_mode      := false
var _ghost_virt_y    : Array[float] = []   # independent ghost positions during power mode
var _ghost_offscreen : Array[bool]  = []   # true once ghost has fled past virtual_h

var _ghost_tex     : Texture2D = null
var _ghost_shader  : Shader    = null
var _ghost_sprites : Array[Sprite2D] = []

# ── Wind-down ──────────────────────────────────────────────────────────────────
var _winding_down := false
var _wd_timer     := 0.0
const WD_DUR       := 1.5

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

	_pw        = float(_panel_layout.panel_w)
	_ph        = float(_panel_layout.panel_h)
	_block     = _ph + 512.0   # PANEL_H + BEZEL_GAP
	_track_x   = _pw * 0.5
	_virtual_h = _virtual_space.virtual_height()

	_virt_y    = module_rng.randf_range(0.0, _virtual_h * 0.5)
	_mouth_t   = 0.0
	_score     = 0
	_direction = 1.0
	_power_mode = false

	_power_panel = module_rng.randi_range(0, _panel_layout.panel_count - 1)

	_ghost_virt_y.clear()
	_ghost_offscreen.clear()
	for i in 4:
		_ghost_virt_y.append(fmod(_virt_y - float(i + 1) * GHOST_SPACING_V + _virtual_h * 2.0, _virtual_h))
		_ghost_offscreen.append(false)

	_build_dots()
	_setup_ghost_sprites()

func _build_dots() -> void:
	_dot_vy.clear()
	_eaten.clear()
	_power_dot_vys.clear()
	var vy := 0.0
	var idx := 0
	while vy < _virtual_h:
		_dot_vy.append(vy)
		# Power pellets only on _power_panel, every POWER_EVERY-th dot
		var panel := int(vy / _block)
		if idx % POWER_EVERY == 0 and panel == _power_panel:
			_power_dot_vys[int(vy)] = true
		vy  += DOT_SPACING_V
		idx += 1

func _setup_ghost_sprites() -> void:
	_free_ghost_sprites()
	_ghost_tex    = null
	_ghost_shader = null

	var svg := "res://modules/pacman/images/ghost.svg"
	if ResourceLoader.exists(svg):
		var res := load(svg)
		if res is Texture2D:
			_ghost_tex = res as Texture2D
		else:
			Log.warn("PacMan: ghost SVG loaded but is not Texture2D")
	else:
		Log.warn("PacMan: ghost.svg not found — ghosts will not render")

	if _ghost_tex:
		_ghost_shader      = Shader.new()
		_ghost_shader.code = GHOST_SHADER_SRC

	var tex_sz := 1.0
	if _ghost_tex:
		tex_sz = float(maxi(_ghost_tex.get_width(), _ghost_tex.get_height()))

	for i in 4:
		if not _ghost_tex:
			continue
		var sp          := Sprite2D.new()
		sp.texture       = _ghost_tex
		sp.scale         = Vector2.ONE * (GHOST_R * 2.0) / tex_sz
		sp.z_index       = 1
		sp.z_as_relative = true
		var mat         := ShaderMaterial.new()
		mat.shader       = _ghost_shader
		mat.set_shader_parameter("ghost_color", GHOST_COLORS[i])
		sp.material      = mat
		add_child(sp)
		_ghost_sprites.append(sp)

func _free_ghost_sprites() -> void:
	for sp in _ghost_sprites:
		if is_instance_valid(sp):
			sp.queue_free()
	_ghost_sprites.clear()

# ─────────────────────────────────────────────────────────────────────────────
#  Power mode transitions
# ─────────────────────────────────────────────────────────────────────────────

func _start_power_mode() -> void:
	_power_mode = true
	_direction  = -1.0   # Pac-Man reverses: now moves upward
	_score      += 50
	# Snapshot current ghost positions as independent starting points
	for i in 4:
		_ghost_virt_y[i]    = fmod(_virt_y - float(i + 1) * GHOST_SPACING_V + _virtual_h * 2.0, _virtual_h)
		_ghost_offscreen[i] = false
	# Paint all ghost sprites navy blue
	for i in _ghost_sprites.size():
		var mat := _ghost_sprites[i].material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("ghost_color", C_NAVY)

func _end_power_mode() -> void:
	_power_mode = false
	_direction  = 1.0   # Pac-Man resumes downward travel
	# Restore ghost colours and reset positions trailing behind Pac-Man
	for i in 4:
		_ghost_virt_y[i]    = fmod(_virt_y - float(i + 1) * GHOST_SPACING_V + _virtual_h * 2.0, _virtual_h)
		_ghost_offscreen[i] = false
		if i < _ghost_sprites.size():
			var mat := _ghost_sprites[i].material as ShaderMaterial
			if mat:
				mat.set_shader_parameter("ghost_color", GHOST_COLORS[i])

# ─────────────────────────────────────────────────────────────────────────────
#  Per-frame update
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not module_started_at > 0.0:
		return

	if _winding_down:
		_wd_timer += delta
		var a := clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)
		for sp in _ghost_sprites:
			if is_instance_valid(sp):
				sp.modulate.a = a
		if _wd_timer >= WD_DUR:
			_finished = true
		queue_redraw()
		return

	# ── Pac-Man movement (direction-aware) ────────────────────────────────────
	_virt_y  += SPEED_VPX_SEC * _direction * delta
	_mouth_t += MOUTH_SPEED * delta

	# Wrap at both ends; rebuild pellets on each full pass
	if _virt_y >= _virtual_h:
		_virt_y = fmod(_virt_y, _virtual_h)
		_build_dots()
	elif _virt_y < 0.0:
		_virt_y += _virtual_h
		_build_dots()

	# ── Ghost logic ───────────────────────────────────────────────────────────
	if _power_mode:
		# Ghosts flee downward independently; no wrap — they exit off the bottom
		var eat_r := PACMAN_R + GHOST_R
		var all_fled := true
		for i in 4:
			if not _ghost_offscreen[i]:
				_ghost_virt_y[i] += SPEED_VPX_SEC * delta
				if _ghost_virt_y[i] >= _virtual_h:
					_ghost_offscreen[i] = true
				elif absf(_virt_y - _ghost_virt_y[i]) < eat_r:
					# Pac-Man collides with navy ghost — eat it
					_ghost_offscreen[i] = true
					_score += 200
			if not _ghost_offscreen[i]:
				all_fled = false
		if all_fled:
			_end_power_mode()
	else:
		# Normal mode: ghosts derived from Pac-Man position, trailing above
		for i in 4:
			_ghost_virt_y[i] = fmod(_virt_y - float(i + 1) * GHOST_SPACING_V + _virtual_h * 2.0, _virtual_h)

	# ── Pellet eating (only outside power mode) ───────────────────────────────
	if not _power_mode:
		var eat_r := PACMAN_R * 1.4
		for idx in _dot_vy.size():
			var vy  := _dot_vy[idx]
			var key := int(vy)
			if _eaten.has(key):
				continue
			if absf(_virt_y - vy) < eat_r:
				_eaten[key] = true
				if _power_dot_vys.has(key):
					_start_power_mode()
					break   # one power pellet per frame is enough
				else:
					_score += 10

	# ── Update ghost sprite positions ─────────────────────────────────────────
	for i in _ghost_sprites.size():
		var sp : Sprite2D = _ghost_sprites[i]
		if _power_mode and _ghost_offscreen[i]:
			sp.visible = false
			continue
		var info := _virtual_space.virtual_to_real(_ghost_virt_y[i])
		if info["visible"]:
			sp.visible  = true
			sp.position = Vector2(_track_x, float(info["real_y"]))
		else:
			sp.visible = false

	queue_redraw()

# ─────────────────────────────────────────────────────────────────────────────
#  Drawing
# ─────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if not module_started_at > 0.0:
		return

	var a := 1.0
	if _winding_down:
		a = clampf(1.0 - _wd_timer / WD_DUR, 0.0, 1.0)

	# Per-panel backgrounds and maze corridors
	for i in _panel_layout.panel_count:
		_draw_panel(i, a)

	# Pellets along the vertical track
	_draw_dots(a)

	# Pac-Man (only when in a visible panel region)
	var pm_info := _virtual_space.virtual_to_real(_virt_y)
	if pm_info["visible"]:
		_draw_pacman(Vector2(_track_x, float(pm_info["real_y"])), a)

	_draw_hud(a)

func _draw_panel(panel_idx: int, a: float) -> void:
	var rect := _panel_layout.get_panel_rect(panel_idx)

	# Solid dark background
	draw_rect(rect, Color(C_BG.r, C_BG.g, C_BG.b, a), true)

	# Outer maze border
	var wall := Color(C_MAZE.r, C_MAZE.g, C_MAZE.b, a * 0.80)
	var m    := 36.0
	var bw   := 4.0
	var tl   := rect.position + Vector2(m, m)
	var br   := rect.end      - Vector2(m, m)
	draw_line(tl,                    Vector2(br.x, tl.y), wall, bw)   # top
	draw_line(Vector2(tl.x, br.y),  br,                  wall, bw)   # bottom
	draw_line(tl,                    Vector2(tl.x, br.y), wall, bw)   # left
	draw_line(Vector2(br.x, tl.y),  br,                  wall, bw)   # right

	# Horizontal corridor dividers above/below the vertical mid-point,
	# with a gap around the track so Pac-Man and pellets are unobstructed.
	var dim_wall := Color(C_MAZE.r, C_MAZE.g, C_MAZE.b, a * 0.48)
	var gap      := PACMAN_R * 2.4
	for cy in [rect.position.y + _ph * 0.33, rect.position.y + _ph * 0.67]:
		draw_line(Vector2(tl.x,         cy), Vector2(_track_x - gap, cy), dim_wall, bw * 0.7)
		draw_line(Vector2(_track_x + gap, cy), Vector2(br.x, cy),         dim_wall, bw * 0.7)

	# Small corner accents
	var bc  := Color(C_MAZE.r, C_MAZE.g, C_MAZE.b, a * 0.38)
	var bl2 := 26.0
	for corner: Array in [
		[tl,                         Vector2( 1.0,  1.0)],
		[Vector2(br.x, tl.y),        Vector2(-1.0,  1.0)],
		[Vector2(tl.x, br.y),        Vector2( 1.0, -1.0)],
		[br,                          Vector2(-1.0, -1.0)],
	]:
		var p : Vector2 = corner[0]
		var d : Vector2 = corner[1]
		draw_line(p, p + Vector2(d.x * bl2, 0.0), bc, 1.5)
		draw_line(p, p + Vector2(0.0, d.y * bl2), bc, 1.5)

	# Panel number label (top-left, inside border)
	var font   := ThemeDB.fallback_font
	var labels := ["PANEL  I", "PANEL  II", "PANEL  III", "PANEL  IV"]
	draw_string(font,
			Vector2(tl.x + 6.0, tl.y + 24.0),
			labels[panel_idx],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			Color(C_MAZE.r, C_MAZE.g, C_MAZE.b, a * 0.52))

func _draw_dots(a: float) -> void:
	var now := App.station_time
	for idx in _dot_vy.size():
		var vy  := _dot_vy[idx]
		var key := int(vy)
		if _eaten.has(key):
			continue
		var info := _virtual_space.virtual_to_real(vy)
		if not info["visible"]:
			continue
		var rp := Vector2(_track_x, float(info["real_y"]))
		if _power_dot_vys.has(key):
			var pulse := 0.72 + 0.28 * sin(now * 4.5)
			draw_circle(rp, 9.0 * pulse,
					Color(C_POWER.r, C_POWER.g, C_POWER.b, a * pulse))
		else:
			draw_circle(rp, 3.8,
					Color(C_DOT.r, C_DOT.g, C_DOT.b, a * 0.82))

func _draw_pacman(pos: Vector2, a: float) -> void:
	# Filled polygon forming a pie-slice facing in the direction of travel.
	# Mouth oscillates open/closed via sin().
	var mouth_open : float = abs(sin(_mouth_t)) * 0.42   # 0=closed, 0.42 rad ≈ 24°
	var facing     : float = PI * 0.5 * _direction       # +PI/2=down, -PI/2=up

	var arc_start : float = facing + mouth_open
	var arc_range : float = TAU - mouth_open * 2.0
	const VERTS           := 28

	var pts := PackedVector2Array()
	pts.push_back(pos)
	for i in VERTS + 1:
		var angle : float = arc_start + arc_range * float(i) / float(VERTS)
		pts.push_back(pos + Vector2(cos(angle), sin(angle)) * PACMAN_R)

	var col    := Color(C_PACMAN.r, C_PACMAN.g, C_PACMAN.b, a)
	var colors := PackedColorArray()
	colors.resize(pts.size())
	colors.fill(col)
	draw_polygon(pts, colors)

	# Eye offset: upper-right relative to direction of travel
	# _direction=+1 (down): eye at (+0.30R, -0.38R) — upper-right
	# _direction=-1 (up):   eye at (+0.30R, +0.38R) — lower-right = upper-right of upward body
	draw_circle(pos + Vector2(PACMAN_R * 0.30, -PACMAN_R * 0.38 * _direction), 3.5,
			Color(0.04, 0.04, 0.10, a))

func _draw_hud(a: float) -> void:
	var font := ThemeDB.fallback_font

	# Score — top of the framebuffer
	draw_string(font,
			Vector2(_pw - 14.0, 34.0),
			"SCORE  %06d" % _score,
			HORIZONTAL_ALIGNMENT_RIGHT, int(_pw * 0.45), 20,
			Color(C_SCORE.r, C_SCORE.g, C_SCORE.b, a * 0.95))
	draw_string(font,
			Vector2(14.0, 34.0), "1UP",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color(C_LABEL.r, C_LABEL.g, C_LABEL.b, a * 0.65))

	# Ghost name labels next to each visible ghost sprite
	# In power mode labels are navy; otherwise per-ghost colour
	for i in _ghost_sprites.size():
		var sp : Sprite2D = _ghost_sprites[i]
		if not sp.visible:
			continue
		var gc : Color = C_NAVY if _power_mode else GHOST_COLORS[i]
		draw_string(font,
				sp.position + Vector2(GHOST_R * 1.2, -GHOST_R * 0.35),
				GHOST_NAMES[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				Color(gc.r, gc.g, gc.b, a * 0.78))

# ─────────────────────────────────────────────────────────────────────────────
#  Module lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func module_status() -> Dictionary:
	return {
		"ok":        true,
		"notes":     "score:%d vy:%.0f power:%s" % [_score, _virt_y, str(_power_mode)],
		"intensity": 0.50,
	}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	_winding_down   = true
	_wd_timer       = 0.0
	Log.debug("PacMan: stop requested", {"reason": reason})

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	_free_ghost_sprites()
	_ghost_tex    = null
	_ghost_shader = null
	_dot_vy.clear()
	_eaten.clear()
	_power_dot_vys.clear()
	_ghost_virt_y.clear()
	_ghost_offscreen.clear()
