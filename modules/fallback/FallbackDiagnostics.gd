## FallbackDiagnostics — shown briefly when a module fails to load.
## Displays "SUBSYSTEM OFFLINE" with a blinking reinitialize indicator.
extends Node2D

var _timer  := 0.0
var _blink  := true

func _process(delta: float) -> void:
	_timer += delta
	_blink  = fmod(_timer, 1.0) < 0.6
	queue_redraw()

func _draw() -> void:
	var vp   := get_viewport().get_visible_rect().size
	var font := ThemeDB.fallback_font

	# Near-black background
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.0, 0.0, 1.0), true)

	var cx := vp.x * 0.5
	var cy := vp.y * 0.5

	# Primary message
	var title_col := Color(1.0, 0.18, 0.08, 0.9)
	draw_string(font, Vector2(cx - 220.0, cy - 22.0),
			"SUBSYSTEM OFFLINE", HORIZONTAL_ALIGNMENT_LEFT, -1, 38, title_col)

	# Blinking status
	if _blink:
		var blink_col := Color(1.0, 0.6, 0.0, 0.85)
		draw_string(font, Vector2(cx - 130.0, cy + 34.0),
				"▶ REINITIALIZING...", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, blink_col)

	# Corner brackets
	var col    := Color(0.8, 0.1, 0.0, 0.5)
	var blen   := 30.0
	var margin := 40.0
	draw_line(Vector2(margin, margin),            Vector2(margin + blen, margin), col, 2.0)
	draw_line(Vector2(margin, margin),            Vector2(margin, margin + blen), col, 2.0)
	draw_line(Vector2(vp.x - margin, vp.y - margin), Vector2(vp.x - margin - blen, vp.y - margin), col, 2.0)
	draw_line(Vector2(vp.x - margin, vp.y - margin), Vector2(vp.x - margin, vp.y - margin - blen), col, 2.0)
