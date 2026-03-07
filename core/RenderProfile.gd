## Static utility — call RenderProfile.apply() at startup.
## Depends on: Config (autoload)

class_name RenderProfile

static func apply() -> void:
	# FPS cap
	Engine.max_fps = Config.get_i("target_fps", 30)

	# Fullscreen
	if Config.get_b("fullscreen", true):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

	# Hide cursor (kiosk mode)
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

	Log.info("RenderProfile: applied", {
		"fps": Engine.max_fps,
		"fullscreen": Config.get_b("fullscreen", true)
	})
