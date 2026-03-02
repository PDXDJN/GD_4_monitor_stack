Oh no. You offered *deliverables*. I’m legally obligated to say “yes” and then immediately overdeliver.

Below are:

1. **`scene_pool.json`** (the global pool index)
2. **Two real scene manifests** (each scene defines its own timeline + quirks)
3. **`Launcher.gd`** state machine skeleton (loads, runs, transitions, error handling)
4. **`VirtualSpace.gd`** (wraparound + boundary conditions + “don’t render the dead pixels” via segment mapping)

Everything is written for **Godot 4.x / 4.5** style GDScript.

---

## 1) `res://scene_pool.json`

This is the *only* file the Launcher needs to discover content. It points to per-scene manifests.

```json
{
  "format": 1,
  "pool_id": "cbase_arcade_pool",
  "version": "2026.03.01",
  "defaults": {
    "transition_out": "res://transitions/WipeToWhite.tscn",
    "transition_in": "res://transitions/FadeFromWhite.tscn",
    "fallback_scene": "res://scenes/FallbackDiagnostics.tscn",
    "min_run_seconds": 8.0,
    "max_run_seconds": 45.0
  },
  "entries": [
    {
      "id": "berlin_icons_scroll",
      "manifest": "res://manifests/berlin_icons_scroll.manifest.json",
      "weight": 3.0,
      "enabled": true,
      "tags": ["attract", "vector", "berlin"]
    },
    {
      "id": "monitor_calibration_grid",
      "manifest": "res://manifests/monitor_calibration_grid.manifest.json",
      "weight": 1.0,
      "enabled": true,
      "tags": ["utility", "calibration"]
    }
  ]
}
```

---

## 2) Two real manifests

### A) `res://manifests/berlin_icons_scroll.manifest.json`

A “vertical icon ticker” that can move between displays. Note the **virtual space constraints** and **timeline**.

```json
{
  "format": 1,
  "id": "berlin_icons_scroll",
  "title": "Berlin Icons: Vertical Scroll",
  "scene_path": "res://scenes/Attract/BerlinIconsScroll.tscn",

  "requirements": {
    "virtual_space": true,
    "safe_rendering": "segments_only"
  },

  "timing": {
    "preferred_run_seconds": 28.0,
    "min_run_seconds": 12.0,
    "max_run_seconds": 60.0,
    "allow_early_exit": true
  },

  "timeline": [
    { "t": 0.0,  "op": "call", "method": "set_seed", "args": ["$RANDOM"] },
    { "t": 0.0,  "op": "call", "method": "start_scroll", "args": [] },
    { "t": 6.0,  "op": "call", "method": "set_scroll_speed", "args": [90.0] },
    { "t": 18.0, "op": "call", "method": "inject_glitch", "args": [0.6] },
    { "t": 26.0, "op": "emit", "signal": "request_transition_out", "args": ["collapse_flash"] }
  ],

  "transitions": {
    "out": "res://transitions/CollapseFlashVertical.tscn",
    "in": "res://transitions/FadeFromWhite.tscn"
  },

  "exposed_params": {
    "scroll_direction": "down",
    "wrap_mode": "y",
    "use_vector_icons": true
  }
}
```

### B) `res://manifests/monitor_calibration_grid.manifest.json`

Useful for your “multiple physical monitors stitched with gaps/dead pixels” reality.

```json
{
  "format": 1,
  "id": "monitor_calibration_grid",
  "title": "Monitor Calibration Grid",
  "scene_path": "res://scenes/Utility/CalibrationGrid.tscn",

  "requirements": {
    "virtual_space": true,
    "safe_rendering": "segments_only"
  },

  "timing": {
    "preferred_run_seconds": 20.0,
    "min_run_seconds": 10.0,
    "max_run_seconds": 90.0,
    "allow_early_exit": true
  },

  "timeline": [
    { "t": 0.0, "op": "call", "method": "set_mode", "args": ["grid"] },
    { "t": 3.0, "op": "call", "method": "set_mode", "args": ["labels"] },
    { "t": 8.0, "op": "call", "method": "set_mode", "args": ["edge_walk"] },
    { "t": 18.0, "op": "emit", "signal": "request_transition_out", "args": ["fade"] }
  ],

  "transitions": {
    "out": "res://transitions/WipeToWhite.tscn",
    "in": "res://transitions/FadeFromWhite.tscn"
  },

  "exposed_params": {
    "show_segment_bounds": true,
    "show_dead_zones": true
  }
}
```

---

## 3) `res://scripts/Launcher.gd` (state machine skeleton)

This is a *clean* runner: load pool → pick next → instantiate → drive timeline → transition → cleanup → repeat. It assumes each scene **may** expose `apply_manifest(manifest: Dictionary)` and **may** emit `request_end` / `request_transition_out`.

```gdscript
extends Node
class_name Launcher

signal launcher_state_changed(state: String)
signal scene_started(scene_id: String)
signal scene_finished(scene_id: String, reason: String)

enum State { BOOT, LOAD_POOL, PICK_NEXT, LOAD_SCENE, RUN_SCENE, TRANSITION_OUT, CLEANUP, ERROR }

@export var pool_path: String = "res://scene_pool.json"
@export var virtual_space_path: NodePath # optional: points to a VirtualSpace node

var _state: State = State.BOOT
var _pool: Dictionary = {}
var _entries: Array = []
var _current_entry: Dictionary = {}
var _current_manifest: Dictionary = {}
var _current_node: Node = null
var _timeline: Array = []
var _timeline_index: int = 0
var _run_started_msec: int = 0

var _transition_out_scene: PackedScene
var _transition_in_scene: PackedScene
var _fallback_scene: PackedScene

var _timer := Timer.new()

func _ready() -> void:
	add_child(_timer)
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer_timeout)

	_set_state(State.LOAD_POOL)

func _set_state(s: State) -> void:
	_state = s
	launcher_state_changed.emit(_state_name(s))

	match s:
		State.LOAD_POOL:
			_load_pool()
		State.PICK_NEXT:
			_pick_next()
		State.LOAD_SCENE:
			_load_scene()
		State.RUN_SCENE:
			_start_run()
		State.TRANSITION_OUT:
			_start_transition_out()
		State.CLEANUP:
			_cleanup_and_next()
		State.ERROR:
			_enter_fallback()

func _state_name(s: State) -> String:
	return ["BOOT","LOAD_POOL","PICK_NEXT","LOAD_SCENE","RUN_SCENE","TRANSITION_OUT","CLEANUP","ERROR"][int(s)]

# -------------------------
# Pool / manifests
# -------------------------

func _load_pool() -> void:
	var text := FileAccess.get_file_as_string(pool_path)
	if text.is_empty():
		push_error("Pool file missing/empty: %s" % pool_path)
		_set_state(State.ERROR)
		return

	_pool = JSON.parse_string(text)
	if typeof(_pool) != TYPE_DICTIONARY:
		push_error("Pool JSON invalid: %s" % pool_path)
		_set_state(State.ERROR)
		return

	_entries = _pool.get("entries", [])
	_transition_out_scene = load(_pool.get("defaults", {}).get("transition_out", ""))
	_transition_in_scene = load(_pool.get("defaults", {}).get("transition_in", ""))
	_fallback_scene = load(_pool.get("defaults", {}).get("fallback_scene", ""))

	_set_state(State.PICK_NEXT)

func _pick_next() -> void:
	var enabled := []
	for e in _entries:
		if e.get("enabled", true):
			enabled.append(e)

	if enabled.is_empty():
		push_error("No enabled entries in pool.")
		_set_state(State.ERROR)
		return

	_current_entry = _weighted_pick(enabled)
	_set_state(State.LOAD_SCENE)

func _weighted_pick(items: Array) -> Dictionary:
	var total := 0.0
	for it in items:
		total += float(it.get("weight", 1.0))

	var r := randf() * max(total, 0.0001)
	for it in items:
		r -= float(it.get("weight", 1.0))
		if r <= 0.0:
			return it
	return items.back()

func _load_manifest(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var d := JSON.parse_string(txt)
	return d if typeof(d) == TYPE_DICTIONARY else {}

func _load_scene() -> void:
	var manifest_path := _current_entry.get("manifest", "")
	_current_manifest = _load_manifest(manifest_path)
	if _current_manifest.is_empty():
		push_error("Manifest invalid: %s" % manifest_path)
		_set_state(State.ERROR)
		return

	var scene_path := _current_manifest.get("scene_path", "")
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("Scene missing: %s" % scene_path)
		_set_state(State.ERROR)
		return

	_current_node = packed.instantiate()
	add_child(_current_node)

	# Optional: give it the virtual-space reference
	var vs := _get_virtual_space()
	if vs != null and _current_node.has_method("set_virtual_space"):
		_current_node.call("set_virtual_space", vs)

	# Optional: apply manifest
	if _current_node.has_method("apply_manifest"):
		_current_node.call("apply_manifest", _current_manifest)

	# Listen for polite requests
	if _current_node.has_signal("request_end"):
		_current_node.connect("request_end", Callable(self, "_on_scene_request_end"))
	if _current_node.has_signal("request_transition_out"):
		_current_node.connect("request_transition_out", Callable(self, "_on_scene_request_transition_out"))

	_set_state(State.RUN_SCENE)

func _get_virtual_space() -> Node:
	if virtual_space_path == NodePath():
		return null
	return get_node_or_null(virtual_space_path)

# -------------------------
# Run / timeline
# -------------------------

func _start_run() -> void:
	_run_started_msec = Time.get_ticks_msec()
	_timeline = _current_manifest.get("timeline", [])
	_timeline.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_timeline_index = 0

	scene_started.emit(_current_manifest.get("id", "unknown"))

	# Kick timeline
	_schedule_next_timeline_step()

	# Hard stop at max_run_seconds
	var max_s := float(_current_manifest.get("timing", {}).get("max_run_seconds",
		_pool.get("defaults", {}).get("max_run_seconds", 45.0)))
	# Set a guard timer separate from timeline by using the same timer only if timeline idle could be risky.
	# We'll just rely on end requests + timeline; but you can add a second Timer if you want a strict watchdog.

func _schedule_next_timeline_step() -> void:
	if _timeline_index >= _timeline.size():
		# If timeline ends, we still obey min_run_seconds then transition.
		_maybe_end_due_to_timeline()
		return

	var step := _timeline[_timeline_index]
	var t := float(step.get("t", 0.0))
	var elapsed := float(Time.get_ticks_msec() - _run_started_msec) / 1000.0
	var wait := max(0.0, t - elapsed)

	_timer.start(wait)

func _on_timer_timeout() -> void:
	if _state != State.RUN_SCENE:
		return

	if _timeline_index < _timeline.size():
		_execute_timeline_step(_timeline[_timeline_index])
		_timeline_index += 1

	_schedule_next_timeline_step()

func _execute_timeline_step(step: Dictionary) -> void:
	var op := step.get("op", "")
	match op:
		"call":
			var method := step.get("method", "")
			var args := step.get("args", [])
			_call_scene(method, args)
		"emit":
			# For manifests, emit is interpreted as "ask scene to do something" OR launcher action.
			var sig := step.get("signal", "")
			var args2 := step.get("args", [])
			if sig == "request_transition_out":
				_on_scene_request_transition_out(args2.size() > 0 ? str(args2[0]) : "default")
			else:
				# Forward to scene if it has this signal (rare), else ignore.
				if _current_node != null and _current_node.has_signal(sig):
					_current_node.emit_signal(sig, args2)
		_:
			# Unknown op: ignore.
			pass

func _call_scene(method: String, args: Array) -> void:
	if _current_node == null:
		return
	if not _current_node.has_method(method):
		return

	# Replace "$RANDOM" convenience token
	for i in args.size():
		if typeof(args[i]) == TYPE_STRING and str(args[i]) == "$RANDOM":
			args[i] = randi()

	_current_node.callv(method, args)

func _maybe_end_due_to_timeline() -> void:
	var min_s := float(_current_manifest.get("timing", {}).get("min_run_seconds",
		_pool.get("defaults", {}).get("min_run_seconds", 8.0)))
	var elapsed := float(Time.get_ticks_msec() - _run_started_msec) / 1000.0
	if elapsed >= min_s:
		_set_state(State.TRANSITION_OUT)
	else:
		_timer.start(min_s - elapsed)

# -------------------------
# Scene requests
# -------------------------

func _on_scene_request_end(reason: String = "scene_request") -> void:
	var allow := bool(_current_manifest.get("timing", {}).get("allow_early_exit", true))
	if not allow:
		return
	_set_state(State.TRANSITION_OUT)

func _on_scene_request_transition_out(kind: String = "default") -> void:
	# kind can select different transitions if you want; here we just go.
	_set_state(State.TRANSITION_OUT)

# -------------------------
# Transition / cleanup
# -------------------------

func _start_transition_out() -> void:
	# Optional: instantiate a transition overlay scene that animates, then calls back.
	# Minimal skeleton: just cleanup immediately.
	_set_state(State.CLEANUP)

func _cleanup_and_next() -> void:
	if _current_node != null:
		scene_finished.emit(_current_manifest.get("id", "unknown"), "completed")
		_current_node.queue_free()
		_current_node = null

	_current_entry = {}
	_current_manifest = {}
	_timeline.clear()

	_set_state(State.PICK_NEXT)

func _enter_fallback() -> void:
	if _current_node != null:
		_current_node.queue_free()
		_current_node = null

	if _fallback_scene != null:
		_current_node = _fallback_scene.instantiate()
		add_child(_current_node)
	# After showing fallback briefly, return to pool.
	_timer.start(2.0)
	_timer.timeout.disconnect(_on_timer_timeout)
	_timer.timeout.connect(func():
		_timer.timeout.disconnect_all()
		_timer.timeout.connect(_on_timer_timeout)
		_set_state(State.PICK_NEXT)
	)
```

---

## 4) `res://scripts/VirtualSpace.gd` (wraparound + boundary conditions + dead-pixel-safe rendering)

This is the important bit: you treat your whole “tower of monitors” as a **virtual coordinate space** that includes *dead zones/gaps*, but when it’s time to actually draw, you **only render into live segments**.

### Concept

* Virtual space is broken into **segments** (live rectangles), separated by **gaps** (dead pixels, bezels, missing rows, etc.).
* You position content in **virtual coordinates** (continuous space).
* `VirtualSpace` gives you:

  * wrap functions (`wrap_point`, `wrap_rect`)
  * clipping & mapping to “real” segment-local rects (`map_virtual_rect_to_segments`)
  * helper to compute on-screen transforms for Nodes/CanvasItems

```gdscript
extends Node
class_name VirtualSpace

# A "segment" is a live renderable rectangle in virtual space.
# Example: two stacked monitors with a dead strip between them.
# segments = [
#   {"id":"top", "rect": Rect2(0, 0, 320, 180)},
#   {"id":"bottom", "rect": Rect2(0, 200, 320, 180)} # gap from y=180..200 is dead
# ]
@export var segments: Array[Dictionary] = []

# Total virtual bounds (usually covers everything including gaps).
@export var virtual_bounds: Rect2 = Rect2(0, 0, 320, 380)

# Wrap behavior
@export var wrap_x: bool = false
@export var wrap_y: bool = true

func _ready() -> void:
	# Basic sanity: ensure segment rects exist
	for s in segments:
		if not s.has("rect"):
			push_error("VirtualSpace segment missing rect: %s" % str(s))

func wrap_point(p: Vector2) -> Vector2:
	var out := p
	if wrap_x:
		out.x = _wrap_scalar(out.x, virtual_bounds.position.x, virtual_bounds.position.x + virtual_bounds.size.x)
	if wrap_y:
		out.y = _wrap_scalar(out.y, virtual_bounds.position.y, virtual_bounds.position.y + virtual_bounds.size.y)
	return out

func wrap_rect(r: Rect2) -> Array[Rect2]:
	# Returns 1..4 rects if wrapping splits it. (Most cases: 1 or 2.)
	# This is for content rectangles you want to render safely.
	var rects: Array[Rect2] = [r]
	if wrap_x:
		rects = _split_wrap(rects, axis := "x")
	if wrap_y:
		rects = _split_wrap(rects, axis := "y")
	return rects

func _wrap_scalar(v: float, min_v: float, max_v: float) -> float:
	var span := max_v - min_v
	if span <= 0.0:
		return min_v
	var x := fposmod(v - min_v, span) + min_v
	return x

func _split_wrap(in_rects: Array[Rect2], axis: String) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in in_rects:
		if axis == "x" and wrap_x:
			out.append_array(_split_rect_wrap_x(r))
		elif axis == "y" and wrap_y:
			out.append_array(_split_rect_wrap_y(r))
		else:
			out.append(r)
	return out

func _split_rect_wrap_x(r: Rect2) -> Array[Rect2]:
	var min_x := virtual_bounds.position.x
	var max_x := virtual_bounds.position.x + virtual_bounds.size.x
	var left := r.position.x
	var right := r.position.x + r.size.x

	# normalize into range for stable splitting
	var base := r
	base.position.x = _wrap_scalar(base.position.x, min_x, max_x)
	left = base.position.x
	right = left + base.size.x

	if right <= max_x:
		return [base]

	# Split into two: [left..max_x] and [min_x..(right-max_x)]
	var a := Rect2(Vector2(left, base.position.y), Vector2(max_x - left, base.size.y))
	var b := Rect2(Vector2(min_x, base.position.y), Vector2(right - max_x, base.size.y))
	return [a, b]

func _split_rect_wrap_y(r: Rect2) -> Array[Rect2]:
	var min_y := virtual_bounds.position.y
	var max_y := virtual_bounds.position.y + virtual_bounds.size.y
	var top := r.position.y
	var bottom := r.position.y + r.size.y

	var base := r
	base.position.y = _wrap_scalar(base.position.y, min_y, max_y)
	top = base.position.y
	bottom = top + base.size.y

	if bottom <= max_y:
		return [base]

	var a := Rect2(Vector2(base.position.x, top), Vector2(base.size.x, max_y - top))
	var b := Rect2(Vector2(base.position.x, min_y), Vector2(base.size.x, bottom - max_y))
	return [a, b]

# -------------------------
# Dead-pixel-safe mapping
# -------------------------

func map_virtual_rect_to_segments(virtual_rect: Rect2) -> Array[Dictionary]:
	# Returns list of draw jobs:
	# [
	#   {"segment_id":"top", "segment_rect":Rect2(...), "source_rect":Rect2(...)},
	#   ...
	# ]
	#
	# segment_rect: where on that segment to draw (in virtual coords)
	# source_rect: portion of the original virtual_rect that corresponds to this draw
	#
	# Note: if you render via SubViewport/CanvasItem, you can use these to set
	# region/clip and offset.

	var jobs: Array[Dictionary] = []

	# Apply wrapping first (so you get 1..2 rects typically for vertical wrap)
	var wrapped := wrap_rect(virtual_rect)

	for piece in wrapped:
		for s in segments:
			var sid := str(s.get("id", "segment"))
			var srect: Rect2 = s.get("rect", Rect2())

			var inter := piece.intersection(srect)
			if inter.size.x <= 0.0 or inter.size.y <= 0.0:
				continue

			# source_rect is the part of piece that lands in this segment.
			# In this coordinate system, source_rect == inter, but relative offsets matter to the renderer.
			var job := {
				"segment_id": sid,
				"segment_rect": inter,
				"source_rect": Rect2(inter.position - piece.position, inter.size),
				"piece_origin": piece.position,
				"piece_size": piece.size
			}
			jobs.append(job)

	return jobs

func is_point_live(p: Vector2) -> bool:
	for s in segments:
		var r: Rect2 = s.get("rect", Rect2())
		if r.has_point(p):
			return true
	return false

func clamp_point_to_live(p: Vector2) -> Vector2:
	# If point falls in a dead zone, snap it to the nearest point inside the nearest segment.
	# This avoids "content disappears into the bezel void".
	var best := p
	var best_dist := INF
	for s in segments:
		var r: Rect2 = s.get("rect", Rect2())
		var c := Vector2(
			clamp(p.x, r.position.x, r.position.x + r.size.x),
			clamp(p.y, r.position.y, r.position.y + r.size.y)
		)
		var d := p.distance_squared_to(c)
		if d < best_dist:
			best_dist = d
			best = c
	return best

# Convenience: wrap + keep live (optional policy)
func normalize_point(p: Vector2, keep_live: bool = true) -> Vector2:
	var w := wrap_point(p)
	return clamp_point_to_live(w) if keep_live else w
```

### How a scene uses this (pattern)

Your “vertical animation” scene keeps its content in virtual coordinates, then asks `VirtualSpace` how to draw it:

* If you use one big SubViewport texture for the scene: you can draw it multiple times per segment using region offsets.
* Or simpler: keep separate per-segment CanvasLayers/SubViewports and position content into each via the mapping jobs.

Minimal pseudo-usage:

```gdscript
var vs: VirtualSpace

func set_virtual_space(v: VirtualSpace) -> void:
	vs = v

func _process(delta: float) -> void:
	# content_rect describes where your scrolling sprite/text block is in virtual coords
	var content_rect := Rect2(content_pos, content_size)
	var jobs := vs.map_virtual_rect_to_segments(content_rect)

	# For each segment, draw only the intersecting slice.
	# (Implementation depends on whether you're using TextureRect.region_rect, shaders, or custom draw.)
```
