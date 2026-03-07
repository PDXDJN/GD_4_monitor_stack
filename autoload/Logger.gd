extends Node

## Structured logger — outputs to stdout (Godot console).
## No dependencies on other autoloads.

enum Level { DEBUG, INFO, WARN, ERROR }

var _level: Level = Level.INFO
var _log_file: FileAccess = null
var _log_path: String = "user://station.log"

func _ready() -> void:
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log_file == null:
		push_warning("Logger: could not open log file at %s" % _log_path)

func set_level(l: Level) -> void:
	_level = l

func debug(msg: String, ctx: Dictionary = {}) -> void:
	_emit(Level.DEBUG, msg, ctx)

func info(msg: String, ctx: Dictionary = {}) -> void:
	_emit(Level.INFO, msg, ctx)

func warn(msg: String, ctx: Dictionary = {}) -> void:
	_emit(Level.WARN, msg, ctx)

func error(msg: String, ctx: Dictionary = {}) -> void:
	_emit(Level.ERROR, msg, ctx)

func _emit(level: Level, msg: String, ctx: Dictionary) -> void:
	if level < _level:
		return
	var level_str: String = ["DEBUG", "INFO", "WARN", "ERROR"][level]
	var ts := Time.get_datetime_string_from_system()
	var ctx_str := ""
	if not ctx.is_empty():
		ctx_str = " " + JSON.stringify(ctx)
	var line := "[%s][%s] %s%s" % [ts, level_str, msg, ctx_str]
	print(line)
	if _log_file != null:
		_log_file.store_line(line)
		_log_file.flush()

func _exit_tree() -> void:
	if _log_file != null:
		_log_file.close()
