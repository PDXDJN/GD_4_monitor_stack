## Virtual coordinate system that includes bezel gaps between panels.
## Use this for animations that travel vertically "through" the monolith.
## Segments define live (renderable) regions; gaps are the dead bezel zones.
## Depends on: Config

class_name VirtualSpace
extends RefCounted

var PANEL_H: int
var BEZEL_GAP: int
var BLOCK: int          ## PANEL_H + BEZEL_GAP
var panel_count: int
var panel_width: int

## Live segments in virtual coordinate space (auto-built from config).
## Each entry: { id, rect: Rect2 (in virtual coords), panel_index }
var segments: Array[Dictionary] = []

## Full virtual bounds: Rect2(0, 0, panel_width, virtual_height)
var virtual_bounds: Rect2 = Rect2()

## Wrap behavior (x disabled, y enabled for vertical travel)
var wrap_x: bool = false
var wrap_y: bool = true

func _init() -> void:
	PANEL_H     = Config.get_i("panel_height", 768)
	BEZEL_GAP   = Config.get_i("bezel_gap", 512)
	BLOCK       = PANEL_H + BEZEL_GAP
	panel_count = Config.get_i("panel_count", 4)
	panel_width = Config.get_i("panel_width", 1024)

	virtual_bounds = Rect2(0.0, 0.0, float(panel_width), virtual_height())

	# Build one segment per panel — each is a live rect in virtual space.
	# Virtual Y for panel i starts at i * BLOCK.
	for i in panel_count:
		var vy_start := float(i * BLOCK)
		segments.append({
			"id":          "panel_%d" % i,
			"rect":        Rect2(0.0, vy_start, float(panel_width), float(PANEL_H)),
			"panel_index": i,
		})

func virtual_height() -> float:
	return float(PANEL_H * panel_count + BEZEL_GAP * (panel_count - 1))

## Map a virtual Y coordinate to real render coordinates.
## Returns: { visible: bool, panel: int, local_y: float, real_y: float }
func virtual_to_real(vy: float) -> Dictionary:
	var panel  := int(floor(vy / BLOCK))
	var local_y := vy - panel * BLOCK

	if panel < 0 or panel >= panel_count:
		return {"visible": false, "panel": panel, "local_y": local_y, "real_y": 0.0}

	var visible := local_y >= 0.0 and local_y < float(PANEL_H)
	var real_y  := float(panel * PANEL_H) + local_y

	return {
		"visible": visible,
		"panel":   panel,
		"local_y": local_y,
		"real_y":  real_y,
	}

## Convert real panel-local Y back to virtual Y.
func real_to_virtual(panel: int, local_y: float) -> float:
	return float(panel * BLOCK) + local_y

# ─── Wrap functions ────────────────────────────────────────────────────────────

## Wrap a virtual-space point back into [virtual_bounds], respecting wrap_x / wrap_y.
func wrap_point(p: Vector2) -> Vector2:
	var out := p
	if wrap_x:
		out.x = _wrap_scalar(out.x,
				virtual_bounds.position.x,
				virtual_bounds.position.x + virtual_bounds.size.x)
	if wrap_y:
		out.y = _wrap_scalar(out.y,
				virtual_bounds.position.y,
				virtual_bounds.position.y + virtual_bounds.size.y)
	return out

## Returns 1–4 Rect2s after splitting a rect at wrap boundaries.
## Use this when content may straddle the virtual-space edge.
func wrap_rect(r: Rect2) -> Array[Rect2]:
	var rects: Array[Rect2] = [r]

	if wrap_y:
		var split: Array[Rect2] = []
		for piece in rects:
			split.append_array(_split_rect_wrap_y(piece))
		rects = split

	if wrap_x:
		var split2: Array[Rect2] = []
		for piece in rects:
			split2.append_array(_split_rect_wrap_x(piece))
		rects = split2

	return rects

func _wrap_scalar(v: float, min_v: float, max_v: float) -> float:
	var span := max_v - min_v
	if span <= 0.0:
		return min_v
	return fposmod(v - min_v, span) + min_v

func _split_rect_wrap_y(r: Rect2) -> Array[Rect2]:
	var min_y := virtual_bounds.position.y
	var max_y := virtual_bounds.position.y + virtual_bounds.size.y

	var base    := r
	base.position.y = _wrap_scalar(base.position.y, min_y, max_y)
	var top    := base.position.y
	var bottom := top + base.size.y

	if bottom <= max_y:
		return [base]

	var a := Rect2(Vector2(base.position.x, top),   Vector2(base.size.x, max_y - top))
	var b := Rect2(Vector2(base.position.x, min_y), Vector2(base.size.x, bottom - max_y))
	return [a, b]

func _split_rect_wrap_x(r: Rect2) -> Array[Rect2]:
	var min_x := virtual_bounds.position.x
	var max_x := virtual_bounds.position.x + virtual_bounds.size.x

	var base  := r
	base.position.x = _wrap_scalar(base.position.x, min_x, max_x)
	var left  := base.position.x
	var right := left + base.size.x

	if right <= max_x:
		return [base]

	var a := Rect2(Vector2(left,  base.position.y), Vector2(max_x - left,  base.size.y))
	var b := Rect2(Vector2(min_x, base.position.y), Vector2(right - max_x, base.size.y))
	return [a, b]

# ─── Dead-pixel-safe segment mapping ──────────────────────────────────────────

## Map a virtual rect to the live panel segments it intersects.
## Applies wrap_rect first, then clips each piece against every segment.
##
## Returns an Array of draw-job Dictionaries:
##   segment_id   : String  — which panel segment
##   panel_index  : int     — panel number (0-based)
##   segment_rect : Rect2   — intersection in virtual coords
##   source_rect  : Rect2   — portion of the original piece (relative offset)
##   piece_origin : Vector2 — origin of the wrapped piece
##   piece_size   : Vector2 — size of the wrapped piece
##   real_y       : float   — screen Y of segment_rect top
##   real_rect    : Rect2   — screen-space Rect2 to draw into
func map_virtual_rect_to_segments(virtual_rect: Rect2) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	var wrapped := wrap_rect(virtual_rect)

	for piece in wrapped:
		for s in segments:
			var srect: Rect2 = s["rect"]
			var inter := piece.intersection(srect)
			if inter.size.x <= 0.0 or inter.size.y <= 0.0:
				continue

			# Map the intersection's top-left to real screen coordinates.
			var mapping  := virtual_to_real(inter.position.y)
			var real_y   : float = mapping["real_y"] if mapping["visible"] else 0.0
			var real_rect := Rect2(Vector2(inter.position.x, real_y), inter.size)

			jobs.append({
				"segment_id":  s["id"],
				"panel_index": s.get("panel_index", 0),
				"segment_rect": inter,
				"source_rect":  Rect2(inter.position - piece.position, inter.size),
				"piece_origin": piece.position,
				"piece_size":   piece.size,
				"real_y":       real_y,
				"real_rect":    real_rect,
			})

	return jobs

## Returns true if a virtual-space point is inside a live panel segment.
func is_point_live(p: Vector2) -> bool:
	for s in segments:
		var r: Rect2 = s["rect"]
		if r.has_point(p):
			return true
	return false

## If a point is in a dead zone (bezel gap), snap it to the nearest live segment edge.
func clamp_point_to_live(p: Vector2) -> Vector2:
	if is_point_live(p):
		return p
	var best      := p
	var best_dist := INF
	for s in segments:
		var r: Rect2 = s["rect"]
		var c := Vector2(
			clamp(p.x, r.position.x, r.position.x + r.size.x),
			clamp(p.y, r.position.y, r.position.y + r.size.y),
		)
		var d := p.distance_squared_to(c)
		if d < best_dist:
			best_dist = d
			best = c
	return best

## Wrap a virtual point then optionally clamp it to the nearest live segment.
func normalize_point(p: Vector2, keep_live: bool = true) -> Vector2:
	var w := wrap_point(p)
	return clamp_point_to_live(w) if keep_live else w
