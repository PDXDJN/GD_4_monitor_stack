## Poisson-ish rare event emitter. Uses long average intervals.
## Emits events through EventBus.rare_event signal.
## Depends on: Logger, EventBus, RNG

class_name Scheduler
extends Node

## Small events: avg interval in seconds
const SMALL_EVENT_AVG_SEC := 60.0
## Big events: avg interval in seconds
const BIG_EVENT_AVG_SEC := 900.0

var _rng: RandomNumberGenerator

const SMALL_EVENTS := [
	"PHASE_OFFSET_CORRECTED",
	"BUFFER_FLUSH",
	"SIGNAL_REACQUIRED",
	"CLOCK_SYNC",
	"DATA_CHECKSUM_OK",
]

const BIG_EVENTS := [
	"DISPLAY_BUS_CALIBRATION",
	"UPLINK_LOST",
	"CORE_DIAGNOSTIC_SWEEP",
	"TRANSMISSION_ANOMALY",
]

func _ready() -> void:
	_rng = RNG.make_rng(RNG.derive_scene_seed("scheduler"))

func set_rng(rng: RandomNumberGenerator) -> void:
	_rng = rng

func _process(delta: float) -> void:
	# Poisson process: P(event in dt) = dt / avg_interval
	if _rng.randf() < delta / SMALL_EVENT_AVG_SEC:
		_emit_small()
	if _rng.randf() < delta / BIG_EVENT_AVG_SEC:
		_emit_big()

func _emit_small() -> void:
	var name: String = SMALL_EVENTS[_rng.randi() % SMALL_EVENTS.size()]
	var payload := {"time": App.station_time}
	Log.debug("Scheduler: rare small event", {"name": name})
	EventBus.rare_event.emit(name, payload)

func _emit_big() -> void:
	var name: String = BIG_EVENTS[_rng.randi() % BIG_EVENTS.size()]
	var payload := {"time": App.station_time, "severity": "high"}
	Log.info("Scheduler: rare BIG event", {"name": name})
	EventBus.rare_event.emit(name, payload)
