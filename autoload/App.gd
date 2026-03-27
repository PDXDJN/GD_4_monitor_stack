extends Node

## Top-level orchestrator singleton.
## Owns station_time (monotonic clock), applies render profile, and starts Launcher.
## Depends on: Logger, Config, RNG, EventBus, RenderProfile (loaded from core)

var station_time: float = 0.0
var _pre_fit_size := Vector2i(0, 0)  # non-zero when window is currently fit-to-screen

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
