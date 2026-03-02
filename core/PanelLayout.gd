## Defines the real-coordinate rects for each physical panel.
## No gaps are rendered — panels are adjacent in real pixel space.
## Depends on: Config

class_name PanelLayout
extends RefCounted

var panel_count: int
var panel_w: int
var panel_h: int

func _init() -> void:
	panel_count = Config.get_i("panel_count", 4)
	panel_w = Config.get_i("panel_width", 1024)
	panel_h = Config.get_i("panel_height", 768)

func get_panel_rect(i: int) -> Rect2:
	i = clamp_panel_index(i)
	return Rect2(0, i * panel_h, panel_w, panel_h)

func clamp_panel_index(i: int) -> int:
	return clampi(i, 0, panel_count - 1)

func get_total_real_size() -> Vector2i:
	return Vector2i(panel_w, panel_h * panel_count)
