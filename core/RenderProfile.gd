## Static utility — call RenderProfile.apply() at startup.
## Depends on: Config (autoload)

class_name RenderProfile

static func apply() -> void:
	Engine.max_fps = Config.get_i("target_fps", 30)

	var fullscreen := Config.get_b("fullscreen", true)
	# Only touch window mode when running as a real OS window (not embedded in
	# the Godot editor).  Calling window_set_mode() on an embedded window prints
	# "Embedded window only supports Windowed mode." repeatedly and does nothing.
	# Window sizing / fullscreen toggling is handled by App._toggle_fullscreen().
	if fullscreen and not _is_embedded():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	Log.info("RenderProfile: applied", {"fps": Engine.max_fps, "fullscreen": fullscreen,
		"embedded": _is_embedded()})

static func _is_embedded() -> bool:
	# The root Window has a non-null parent only when embedded in the editor.
	return Engine.get_main_loop() != null \
		and Engine.get_main_loop().root != null \
		and Engine.get_main_loop().root.get_parent() != null
