extends Node

## Loads app_config.json and exposes typed accessors.
## Depends on: Logger

var _data: Dictionary = {}

func _ready() -> void:
	load_config()

func load_config() -> void:
	var path := "res://config/app_config.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		Log.error("Config: failed to open config file", {"path": path})
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		Log.error("Config: failed to parse JSON", {"path": path})
		return
	_data = parsed
	Log.info("Config: loaded", {"keys": _data.keys()})

func get_i(key: String, default := 0) -> int:
	if _data.has(key):
		return int(_data[key])
	return default

func get_f(key: String, default := 0.0) -> float:
	if _data.has(key):
		return float(_data[key])
	return default

func get_s(key: String, default := "") -> String:
	if _data.has(key):
		return str(_data[key])
	return default

func get_b(key: String, default := false) -> bool:
	if _data.has(key):
		return bool(_data[key])
	return default

func get_dict(key: String, default := {}) -> Dictionary:
	if _data.has(key) and _data[key] is Dictionary:
		return _data[key]
	return default
