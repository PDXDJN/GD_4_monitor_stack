## Reusable scene transition effects rendered on a CanvasLayer overlay.
## play(name, duration, direction) blocks until complete (uses await internally).
## Depends on: Logger, EventBus, Config

class_name Transitions
extends Node

## The CanvasLayer this node is attached to (set by Launcher scene)
var _overlay: ColorRect = null
var _tween: Tween = null

func _ready() -> void:
	# Build a full-screen black rect used for fade transitions
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Size will be set in play() to cover full viewport
	add_child(_overlay)

func play(name: String, duration: float, direction: String) -> void:
	EventBus.transition_started.emit(name)
	Log.debug("Transitions: play", {"name": name, "dir": direction, "dur": duration})

	# Ensure overlay covers the full viewport
	var vp_size := get_viewport().get_visible_rect().size
	_overlay.size = vp_size
	_overlay.position = Vector2.ZERO

	match name:
		"fade_black":
			await _fade_black(duration, direction)
		"scanline_wipe":
			await _scanline_wipe(duration, direction)
		"hard_cut":
			await _hard_cut(direction)
		_:
			# Unknown transition — use fade as fallback
			Log.warn("Transitions: unknown transition, using fade_black", {"name": name})
			await _fade_black(duration, direction)

	EventBus.transition_finished.emit(name)

func _fade_black(duration: float, direction: String) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()

	if direction == "out":
		# Fade to black
		_tween.tween_property(_overlay, "color:a", 1.0, duration)
	else:
		# Fade from black
		_overlay.color.a = 1.0
		_tween.tween_property(_overlay, "color:a", 0.0, duration)

	await _tween.finished

func _scanline_wipe(duration: float, direction: String) -> void:
	# Simplified: just do a faster fade as fallback for now
	# A real scanline wipe would use a shader
	await _fade_black(duration * 0.5, direction)

func _hard_cut(direction: String) -> void:
	if direction == "out":
		_overlay.color.a = 1.0
	else:
		_overlay.color.a = 0.0
	# No await needed for hard cut — instant
	await get_tree().process_frame
