## Debug overlay — shows station_time, FPS, active scene, remaining runtime, seed, rare events.
## Toggle with F1 (handled by App.gd).
## Rendered on CanvasLayer layer=200 so it's always on top.
extends CanvasLayer

var _launcher: Node = null
var _last_events: Array[String] = []

var _label: Label = null

func _ready() -> void:
	layer = 200
	visible = Config.get_b("debug_overlay", false)

	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(0.0, 1.0, 0.5, 0.9))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)

	EventBus.rare_event.connect(_on_rare_event)

func _process(_delta: float) -> void:
	if not visible:
		return
	if _launcher == null:
		_launcher = get_tree().get_root().find_child("Launcher", true, false)

	var fps := Engine.get_frames_per_second()
	var st := App.station_time

	var scene_id := "—"
	var remaining := 0.0
	var seed_val := 0

	if _launcher != null and _launcher.has_method("get_active_manifest"):
		var m: Dictionary = _launcher.get_active_manifest()
		scene_id = m.get("id", "—")
		seed_val = RNG.derive_scene_seed(scene_id)
		if _launcher.has_method("get_module_time_remaining"):
			remaining = _launcher.get_module_time_remaining()

	var events_str := ""
	for ev in _last_events:
		events_str += "  " + ev + "\n"

	_label.text = (
		"═══ DEBUG OVERLAY ═══\n"
		+ "FPS:        %d / %d\n" % [fps, Config.get_i("target_fps", 30)]
		+ "Station T:  %.1f s\n" % st
		+ "Scene:      %s\n" % scene_id
		+ "Remaining:  %.1f s\n" % remaining
		+ "Seed:       %d\n" % seed_val
		+ "Uplink:     %.0f%%\n" % (Telemetry.uplink_strength * 100.0)
		+ "─── Last Events ───\n"
		+ events_str
	)

func _on_rare_event(name: String, _payload: Dictionary) -> void:
	_last_events.append(name)
	while _last_events.size() > 5:
		_last_events.pop_front()
