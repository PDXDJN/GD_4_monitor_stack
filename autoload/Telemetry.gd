extends Node

## Fake telemetry generator — emits periodic station status data.
## Subscribes to EventBus.rare_event to log telemetry bursts.
## Depends on: Logger, EventBus

var _timer: float = 0.0
var _interval: float = 5.0

# Latest telemetry values (readable by DebugOverlay etc.)
var uplink_strength: float = 1.0
var core_temp: float = 37.2
var subsystem_ok: bool = true

func _ready() -> void:
	EventBus.rare_event.connect(_on_rare_event)

func _process(delta: float) -> void:
	_timer += delta
	if _timer >= _interval:
		_timer = 0.0
		_tick()

func _tick() -> void:
	# Drift values slightly
	uplink_strength = clampf(uplink_strength + randf_range(-0.05, 0.05), 0.0, 1.0)
	core_temp = clampf(core_temp + randf_range(-0.3, 0.3), 35.0, 45.0)

func _on_rare_event(name: String, _payload: Dictionary) -> void:
	if name == "UPLINK_LOST":
		uplink_strength = 0.0
		subsystem_ok = false
		Log.warn("Telemetry: uplink lost")
