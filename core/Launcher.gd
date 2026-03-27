## Heart of the system. Manages module lifecycle, transitions, and scheduling.
## Depends on: App, Config, RNG, EventBus, Logger, SceneRegistry, Transitions

extends Node

# ─── State Machine ───────────────────────────────────────────────────────────
enum State {
	IDLE,
	LOADING,
	TRANSITION_IN,
	RUNNING,
	STOPPING,
	TRANSITION_OUT,
	UNLOADING,
}

var _state: State = State.IDLE

# ─── References ──────────────────────────────────────────────────────────────
var _scene_root: Node = null
var _transitions: Transitions = null
var _debug_overlay: Node = null
var _control_board: Node = null

# ─── Registry & pool ─────────────────────────────────────────────────────────
var _registry: SceneRegistry = null
var _pool: Array[Dictionary] = []      # [{id, weight}]
var _no_repeat_window: int = 2
var _recent_ids: Array[String] = []
var _history: Array[String] = []        # ordered play history for prev navigation
var _next_override_id: String = ""      # force-pick this id on next load

# ─── Active module ────────────────────────────────────────────────────────────
var _active_module: Node = null
var _active_manifest: Dictionary = {}
var _module_start_time: float = 0.0
var _module_deadline: float = 0.0
var _hard_cap_sec: float = 600.0

# ─── Manifest sequence (timed ops) ───────────────────────────────────────────
var _sequence: Array = []         # sorted list of step dicts
var _sequence_index: int = 0      # next step to execute

# ─── Layout & space ──────────────────────────────────────────────────────────
var _panel_layout: PanelLayout = null
var _virtual_space: VirtualSpace = null

# ─── Scheduler ───────────────────────────────────────────────────────────────
var _scheduler: Scheduler = null

func _ready() -> void:
	Log.info("Launcher: starting")
	_panel_layout = PanelLayout.new()
	_virtual_space = VirtualSpace.new()
	_hard_cap_sec = Config.get_f("global_scene_hard_cap_sec", 600.0)

	# Find child nodes set up in .tscn
	_scene_root = $SceneRoot
	_transitions = $TransitionLayer/Transitions
	_scheduler = $Scheduler

	# Debug overlay (optional)
	_debug_overlay = get_node_or_null("DebugOverlay")
	_control_board = get_node_or_null("ControlBoard")

	# Connect debug signals
	EventBus.debug_skip_requested.connect(_on_debug_skip)
	EventBus.debug_skip_prev_requested.connect(_on_debug_skip_prev)

	# Load registry
	_registry = SceneRegistry.new()
	add_child(_registry)
	_registry.scan()

	# Load pool config
	_load_pool()

	# Start the loop
	await get_tree().process_frame
	_transition_to(State.LOADING)

func _process(_delta: float) -> void:
	match _state:
		State.RUNNING:
			_check_running()
		State.STOPPING:
			_check_stopping()

# ─── State transitions ────────────────────────────────────────────────────────
func _transition_to(new_state: State) -> void:
	_state = new_state
	match new_state:
		State.LOADING:
			_do_loading()
		State.UNLOADING:
			_do_unloading()

func _do_loading() -> void:
	var manifest := _pick_next_module()
	if manifest.is_empty():
		Log.error("Launcher: no modules available — retrying in 5s")
		await get_tree().create_timer(5.0).timeout
		_transition_to(State.LOADING)
		return

	_active_manifest = manifest
	var scene_path: String = manifest["scene"]
	Log.info("Launcher: loading module", {"id": manifest["id"], "scene": scene_path})

	# Load the scene
	var packed: PackedScene = load(scene_path)
	if packed == null:
		Log.error("Launcher: failed to load scene", {"path": scene_path})
		_show_subsystem_offline()
		await get_tree().create_timer(2.0).timeout
		_transition_to(State.LOADING)
		return

	_active_module = packed.instantiate()
	if _active_module == null:
		Log.error("Launcher: failed to instantiate scene", {"path": scene_path})
		_show_subsystem_offline()
		await get_tree().create_timer(2.0).timeout
		_transition_to(State.LOADING)
		return

	# Configure the module before adding to tree
	var seed_val := RNG.derive_scene_seed(manifest["id"], manifest["seed"]["variant"])
	var ctx := {
		"seed": seed_val,
		"manifest": manifest,
		"panel_layout": _panel_layout,
		"virtual_space": _virtual_space,
		"station_time": App.station_time
	}

	if not _active_module.has_method("module_configure"):
		Log.error("Launcher: module missing module_configure", {"id": manifest["id"]})
		_active_module.free()
		_active_module = null
		_show_subsystem_offline()
		await get_tree().create_timer(2.0).timeout
		_transition_to(State.LOADING)
		return

	_active_module.module_configure(ctx)
	_scene_root.add_child(_active_module)

	# Optional: apply_manifest for modules that want the full manifest dict
	if _active_module.has_method("apply_manifest"):
		_active_module.call("apply_manifest", manifest)

	# Determine planned runtime
	var planned := _calc_planned_runtime(manifest, seed_val)
	_module_start_time = App.station_time
	_module_deadline = _module_start_time + planned
	Log.info("Launcher: module configured", {
		"id": manifest["id"],
		"planned_sec": planned,
		"seed": seed_val
	})

	# Transition in
	_state = State.TRANSITION_IN
	var tr_in: String = manifest["transition"]["in"]
	var tr_in_dur: float = manifest["transition"]["in_duration"]
	await _transitions.play(tr_in, tr_in_dur, "in")

	# Start module
	if _active_module.has_method("module_start"):
		_active_module.module_start()

	# Connect early-exit signals if the module exposes them
	if _active_module.has_signal("request_end"):
		_active_module.connect("request_end", _on_module_request_end)
	if _active_module.has_signal("request_transition_out"):
		_active_module.connect("request_transition_out", _on_module_request_transition_out)

	# Load and sort the manifest sequence (timed ops)
	_sequence = _active_manifest.get("sequence", []).duplicate()
	_sequence.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_sequence_index = 0

	EventBus.scene_started.emit(manifest["id"], seed_val)
	_add_to_recent(manifest["id"])
	_transition_to(State.RUNNING)

func _do_unloading() -> void:
	# Reset sequence state
	_sequence.clear()
	_sequence_index = 0

	if _active_module != null:
		if _active_module.has_method("module_shutdown"):
			_active_module.module_shutdown()
		_scene_root.remove_child(_active_module)
		_active_module.queue_free()
		_active_module = null
		Log.info("Launcher: module unloaded", {"id": _active_manifest.get("id", "?")})

	await get_tree().process_frame
	_transition_to(State.LOADING)

# ─── Running logic ─────────────────────────────────────────────────────────────
func _check_running() -> void:
	if _active_module == null:
		return

	var now     := App.station_time
	var elapsed := now - _module_start_time

	# Hard cap
	if elapsed >= _hard_cap_sec:
		Log.warn("Launcher: HARD_CAP exceeded", {"id": _active_manifest.get("id", "?")})
		_begin_stop("HARD_CAP")
		return

	# Module self-finished
	if _active_module.has_method("module_is_finished") and _active_module.module_is_finished():
		_begin_stop("self_finished")
		return

	# Deadline reached
	if now >= _module_deadline:
		_begin_stop("deadline")
		return

	# Advance sequence ops
	_advance_sequence(elapsed)

func _begin_stop(reason: String) -> void:
	Log.info("Launcher: stopping module", {"reason": reason, "id": _active_manifest.get("id", "?")})
	_state = State.STOPPING
	if _active_module != null and _active_module.has_method("module_request_stop"):
		_active_module.module_request_stop(reason)

func _check_stopping() -> void:
	if _active_module == null:
		_do_transition_out()
		return

	# If module is interruptible or finished, proceed
	var finished: bool = not _active_module.has_method("module_is_finished") or _active_module.module_is_finished()
	var interruptible: bool = _active_manifest.get("interruptible", true)

	if finished or interruptible:
		_do_transition_out()

func _do_transition_out() -> void:
	_state = State.TRANSITION_OUT
	var tr_out: String = _active_manifest.get("transition", {}).get("out", "fade_black")
	var tr_out_dur: float = _active_manifest.get("transition", {}).get("out_duration", 1.0)
	EventBus.scene_finished.emit(_active_manifest.get("id", "?"), "transition_out")
	await _transitions.play(tr_out, tr_out_dur, "out")
	_transition_to(State.UNLOADING)

# ─── Sequence (timed manifest ops) ───────────────────────────────────────────
func _advance_sequence(elapsed: float) -> void:
	while _sequence_index < _sequence.size():
		var step: Dictionary = _sequence[_sequence_index]
		if elapsed >= float(step.get("t", 0.0)):
			_execute_sequence_step(step)
			_sequence_index += 1
		else:
			break  # steps are sorted; no point checking further

func _execute_sequence_step(step: Dictionary) -> void:
	var op := str(step.get("op", ""))
	match op:
		"call":
			_call_module_method(str(step.get("method", "")), step.get("args", []))
		"emit":
			var sig := str(step.get("signal", ""))
			if sig == "request_transition_out":
				var allow_early: bool = _active_manifest.get("timeline", {}).get("allow_early_exit", true)
				if allow_early:
					_begin_stop("sequence_emit")
		_:
			Log.warn("Launcher: unknown sequence op", {"op": op})

func _call_module_method(method: String, args: Array) -> void:
	if _active_module == null or method.is_empty():
		return
	if not _active_module.has_method(method):
		Log.warn("Launcher: module missing method in sequence", {"method": method, "id": _active_manifest.get("id", "?")})
		return

	# Replace the "$RANDOM" convenience token with a random integer
	var resolved: Array = []
	for a in args:
		if typeof(a) == TYPE_STRING and str(a) == "$RANDOM":
			resolved.append(randi())
		else:
			resolved.append(a)

	_active_module.callv(method, resolved)

# ─── Module signal handlers (early exit) ──────────────────────────────────────
func _on_module_request_end(_reason: String = "scene_request") -> void:
	var allow: bool = _active_manifest.get("timeline", {}).get("allow_early_exit", true)
	if allow and (_state == State.RUNNING):
		_begin_stop("module_request_end")

func _on_module_request_transition_out(_kind: String = "default") -> void:
	var allow: bool = _active_manifest.get("timeline", {}).get("allow_early_exit", true)
	if allow and (_state == State.RUNNING):
		_begin_stop("module_request_transition_out")

# ─── Selection ────────────────────────────────────────────────────────────────
func _load_pool() -> void:
	var pool_path := Config.get_s("scene_pool_path", "res://config/scene_pool.json")
	var f := FileAccess.open(pool_path, FileAccess.READ)
	if f == null:
		Log.error("Launcher: cannot open scene_pool.json", {"path": pool_path})
		return

	var parsed = JSON.parse_string(f.get_as_text())
	f.close()

	if parsed == null or not parsed is Dictionary:
		Log.error("Launcher: invalid scene_pool.json")
		return

	_no_repeat_window = int(parsed.get("no_repeat_window", Config.get_i("no_repeat_window", 2)))

	var raw_pool: Array = parsed.get("pool", [])
	_pool.clear()
	for entry in raw_pool:
		if entry is Dictionary and entry.has("id"):
			_pool.append({"id": str(entry["id"]), "weight": float(entry.get("weight", 1.0))})

	Log.info("Launcher: pool loaded", {"count": _pool.size(), "no_repeat": _no_repeat_window})

func _pick_next_module() -> Dictionary:
	# Override: go to a specific module (e.g. from debug_prev)
	if not _next_override_id.is_empty():
		var override_id := _next_override_id
		_next_override_id = ""
		var m := _registry.get_manifest(override_id)
		if not m.is_empty():
			return m
		Log.warn("Launcher: override id not found in registry, falling through", {"id": override_id})

	if _pool.is_empty():
		Log.error("Launcher: pool is empty")
		return {}

	# Respect control board — build enabled subset
	var enabled_pool: Array[Dictionary] = []
	for entry in _pool:
		if _is_module_enabled(entry["id"]):
			enabled_pool.append(entry)
	if enabled_pool.is_empty():
		Log.warn("Launcher: all modules disabled in control board, using full pool")
		enabled_pool = _pool

	# Filter out recent ids
	var candidates: Array[Dictionary] = []
	for entry in enabled_pool:
		if not (entry["id"] in _recent_ids):
			var manifest := _registry.get_manifest(entry["id"])
			if not manifest.is_empty():
				candidates.append({"weight": entry["weight"], "manifest": manifest})

	# Fallback: ignore repeat window if all enabled modules were recent
	if candidates.is_empty():
		Log.warn("Launcher: all enabled modules in repeat window, ignoring window")
		for entry in enabled_pool:
			var manifest := _registry.get_manifest(entry["id"])
			if not manifest.is_empty():
				candidates.append({"weight": entry["weight"], "manifest": manifest})

	if candidates.is_empty():
		Log.error("Launcher: no valid modules found in registry")
		return {}

	# Weighted random selection
	var total_weight := 0.0
	for c in candidates:
		total_weight += c["weight"]

	var pick := randf() * total_weight
	var cumulative := 0.0
	for c in candidates:
		cumulative += c["weight"]
		if pick <= cumulative:
			return c["manifest"]

	return candidates[-1]["manifest"]

func _is_module_enabled(id: String) -> bool:
	if _control_board != null and _control_board.has_method("is_enabled"):
		return _control_board.is_enabled(id)
	return true

func _add_to_recent(id: String) -> void:
	_recent_ids.append(id)
	while _recent_ids.size() > _no_repeat_window:
		_recent_ids.pop_front()
	_history.append(id)
	if _history.size() > 20:
		_history.pop_front()

func _calc_planned_runtime(manifest: Dictionary, seed_val: int) -> float:
	var tl: Dictionary = manifest.get("timeline", {})
	var mode: String = tl.get("mode", "range")
	match mode:
		"fixed":
			return float(tl.get("duration_sec", 90.0))
		"range":
			var rng := RNG.make_rng(seed_val)
			var min_s: float = tl.get("min_sec", 60.0)
			var max_s: float = tl.get("max_sec", 180.0)
			return rng.randf_range(min_s, max_s)
		"self":
			return _hard_cap_sec
		_:
			return 90.0

# ─── Debug ────────────────────────────────────────────────────────────────────
func _on_debug_skip() -> void:
	if _state == State.RUNNING or _state == State.STOPPING:
		Log.info("Launcher: debug skip requested")
		_begin_stop("debug_skip")

func _on_debug_skip_prev() -> void:
	if _state != State.RUNNING and _state != State.STOPPING:
		return
	# Need at least 2 entries: current + one before it
	if _history.size() < 2:
		Log.info("Launcher: no previous module in history")
		return
	# The last entry is the current module; step back to the one before it
	_history.pop_back()
	_next_override_id = _history.back()
	_history.pop_back()   # will be re-added when it starts again
	Log.info("Launcher: going back to", {"id": _next_override_id})
	_begin_stop("debug_prev")

func _show_subsystem_offline() -> void:
	Log.warn("Launcher: SUBSYSTEM OFFLINE")
	await _transitions.play("hard_cut", 0.0, "out")
	await get_tree().create_timer(1.5).timeout
	await _transitions.play("hard_cut", 0.0, "in")

func get_active_manifest() -> Dictionary:
	return _active_manifest

func get_module_time_remaining() -> float:
	return maxf(0.0, _module_deadline - App.station_time)
