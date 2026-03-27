extends Node

## Top-level orchestrator singleton.
## Owns station_time (monotonic clock), applies render profile, and starts Launcher.
## Depends on: Logger, Config, RNG, EventBus, RenderProfile (loaded from core)

var station_time: float = 0.0
var _pre_fit_size := Vector2i(0, 0)   # non-zero when window is currently fit-to-screen
var _pre_span_size := Vector2i(0, 0)  # non-zero when spanning all physical monitors
var _pre_span_pos  := Vector2i(0, 0)

func _ready() -> void:
	Log.info("App: starting up")

	# Preserve aspect ratio regardless of project.godot state.
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	var rp_script := load("res://core/RenderProfile.gd")
	if rp_script:
		rp_script.apply()
	else:
		Log.warn("App: RenderProfile script not found")

	# If starting windowed and not embedded in the editor, auto-size the window.
	var embedded := _is_embedded()
	Log.info("App: embedded detection", {"embedded": embedded})
	if not Config.get_b("fullscreen", true) and not embedded:
		_fit_window_to_screen()

	set_process_input(true)
	Log.info("App: station online", {"boot_seed": RNG.boot_seed})

func _process(delta: float) -> void:
	station_time += delta

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("quit"):
		Log.info("App: quit requested")
		get_tree().quit()
		return

	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var kc := key_event.keycode
	match kc:
		KEY_F:
			_toggle_fullscreen()
		KEY_M:
			_toggle_monitor_span()
		KEY_R:
			_toggle_resolution()
		KEY_F1:
			var overlay := get_tree().get_root().find_child("DebugOverlay", true, false)
			if overlay:
				overlay.visible = not overlay.visible
		KEY_F2:
			var board := get_tree().get_root().find_child("ControlBoard", true, false)
			if board and board.has_method("toggle"):
				board.toggle()
		KEY_N, KEY_RIGHT, KEY_PAGEDOWN:
			EventBus.debug_skip_requested.emit()
		KEY_LEFT, KEY_PAGEUP:
			EventBus.debug_skip_prev_requested.emit()


func _is_embedded() -> bool:
	# Root Window has a non-null parent only when embedded inside the editor viewport.
	var root := get_tree().root
	return root != null and root.get_parent() != null


func _fit_window_to_screen() -> void:
	# Size the window so the full 1024×3072 stack fits on the physical screen,
	# constrained by whichever screen dimension is the limiting factor.
	var screen := DisplayServer.screen_get_size()
	var win_h  := screen.y
	var win_w  := int(win_h * 1024.0 / 3072.0)
	if win_w > screen.x:
		win_w = screen.x
		win_h = int(win_w * 3072.0 / 1024.0)
	get_window().size = Vector2i(win_w, win_h)
	if not _is_embedded():
		get_window().position = (screen - Vector2i(win_w, win_h)) / 2


func _toggle_resolution() -> void:
	# Cycle through available resolution profiles and update the viewport + layout.
	var profiles_dict := Config.get_dict("resolution_profiles", {})
	var profile_names := profiles_dict.keys()
	if profile_names.size() < 2:
		Log.warn("App: only one resolution profile defined, nothing to toggle")
		return
	var current := Config.get_active_profile()
	var idx := profile_names.find(current)
	var next_name: String = profile_names[(idx + 1) % profile_names.size()]
	if Config.apply_profile(next_name):
		var pw := Config.get_i("panel_width")
		var ph := Config.get_i("panel_height")
		var pc := Config.get_i("panel_count", 4)
		get_tree().root.content_scale_size = Vector2i(pw, ph * pc)
		EventBus.resolution_changed.emit(next_name, pw, ph)
		Log.info("App: resolution toggled", {"profile": next_name, "viewport": Vector2i(pw, ph * pc)})


func _toggle_monitor_span() -> void:
	# Span the window across all physical monitors so each panel fills one screen.
	# Requires the OS window to be in windowed (not fullscreen) mode.
	if _is_embedded():
		Log.warn("App: monitor span not supported in editor preview")
		return
	var win := get_window()
	if _pre_span_size != Vector2i(0, 0):
		# Restore pre-span state.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		win.size     = _pre_span_size
		win.position = _pre_span_pos
		_pre_span_size = Vector2i(0, 0)
		get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		Log.info("App: monitor span off")
	else:
		# Save current state and span across all screens.
		_pre_span_size = win.size
		_pre_span_pos  = win.position
		# Must be windowed to move/resize across multiple screens.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var span := _get_all_screens_rect()
		win.size     = span.size
		win.position = span.position
		# IGNORE letterboxing so 1024×3072 content maps 1:1 onto the combined rect.
		get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		Log.info("App: spanning monitors", {"screens": DisplayServer.get_screen_count(), "rect": span})


func _get_all_screens_rect() -> Rect2i:
	var count := DisplayServer.get_screen_count()
	if count == 0:
		return Rect2i(Vector2i.ZERO, DisplayServer.screen_get_size())
	var min_x := 999999;  var min_y := 999999
	var max_x := -999999; var max_y := -999999
	for i in count:
		var pos := DisplayServer.screen_get_position(i)
		var sz  := DisplayServer.screen_get_size(i)
		min_x = mini(min_x, pos.x);        min_y = mini(min_y, pos.y)
		max_x = maxi(max_x, pos.x + sz.x); max_y = maxi(max_y, pos.y + sz.y)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x, max_y - min_y))


func _toggle_fullscreen() -> void:
	# win.mode changes are unsupported in editor preview windows, so we
	# toggle by resizing: save current size, fit to screen, then restore.
	var win := get_window()
	if _pre_fit_size != Vector2i(0, 0):
		# Restore the saved windowed size.
		win.size = _pre_fit_size
		if not _is_embedded():
			win.position = (DisplayServer.screen_get_size() - _pre_fit_size) / 2
		_pre_fit_size = Vector2i(0, 0)
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		Log.info("App: windowed")
	else:
		# Expand to fill the screen (fit all 4 panels).
		_pre_fit_size = win.size
		_fit_window_to_screen()
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		Log.info("App: fullscreen")
