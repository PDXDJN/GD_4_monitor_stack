extends Node

## Top-level orchestrator singleton.
## Owns station_time (monotonic clock), applies render profile, and starts Launcher.
## Depends on: Logger, Config, RNG, EventBus, RenderProfile (loaded from core)

var station_time: float = 0.0

func _ready() -> void:
	Log.info("App: starting up")
	# Apply render settings before anything else
	var rp_script := load("res://core/RenderProfile.gd")
	if rp_script:
		rp_script.apply()
	else:
		Log.warn("App: RenderProfile script not found")

	# Handle quit and debug inputs
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
		KEY_F1:
			var overlay := get_tree().get_root().find_child("DebugOverlay", true, false)
			if overlay:
				overlay.visible = not overlay.visible
		KEY_N, KEY_RIGHT, KEY_PAGEDOWN:
			EventBus.debug_skip_requested.emit()
		KEY_LEFT, KEY_PAGEUP:
			EventBus.debug_skip_prev_requested.emit()
