extends Node

## Top-level orchestrator singleton.
## Owns station_time (monotonic clock), applies render profile, and starts Launcher.
## Depends on: Logger, Config, RNG, EventBus, RenderProfile (loaded from core)

var station_time: float = 0.0

func _ready() -> void:
	Logger.info("App: starting up")
	# Apply render settings before anything else
	var rp_script := load("res://core/RenderProfile.gd")
	if rp_script:
		rp_script.apply()
	else:
		Logger.warn("App: RenderProfile script not found")

	# Handle quit and debug inputs
	set_process_input(true)
	Logger.info("App: station online", {"boot_seed": RNG.boot_seed})

func _process(delta: float) -> void:
	station_time += delta

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("quit"):
		Logger.info("App: quit requested")
		get_tree().quit()
	elif event.is_action_pressed("toggle_debug"):
		# DebugOverlay toggles itself via EventBus-less approach: we just flip visibility
		var overlay := get_tree().get_root().find_child("DebugOverlay", true, false)
		if overlay:
			overlay.visible = not overlay.visible
	elif event.is_action_pressed("debug_next"):
		EventBus.debug_skip_requested.emit()
