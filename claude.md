## 0) Project goals

**Core requirements**

* Godot 4.5 project that runs fullscreen on a tall framebuffer (e.g. 1024×3072 rendered area).
* Visual model: 4 physical monitors stacked vertically (4×1 column), with *virtual* bezel gaps (e.g. 512px) used for timing/continuity math.
* A **Launcher** loads a pool of “animation scenes” (modules).
* Each module declares:

  * its own timeline rules (duration, min/max, or “run until it decides”)
  * whether it can be interrupted
  * how it transitions in/out
  * its own procedural seed policy
* Launcher runs one module at a time, lets it play for its intended lifetime, transitions to the next module.
* Modules can be deterministic-per-run (seeded) but visually non-repeating.
* Robust to missing displays / weird DPI / etc. (launcher doesn’t care; it just renders to the framebuffer it gets).

**Non-goals**

* Multi-window / per-monitor OS-level window management.
* Rendering actual bezel pixels.
* Audio (optional later).

---

## 1) Directory layout (Godot project)

```
res://
  project.godot
  addons/                       (optional; keep empty for now)
  autoload/
    App.gd                      (global orchestration singleton)
    Config.gd                   (loads config JSON, exposes constants)
    RNG.gd                      (seed service)
    EventBus.gd                 (signals for cross-scene events)
    Telemetry.gd                (optional: fake telemetry generator)
    Logger.gd                   (structured log to file/stdout)
  core/
    Launcher.tscn
    Launcher.gd
    SceneRegistry.gd            (discovers animation scenes)
    SceneManifest.gd            (resource format / validation)
    Transitions.gd              (fade/glitch/scanline wipes)
    VirtualSpace.gd             (virtual_y <-> real_y mapping)
    PanelLayout.gd              (defines panel rects)
    Scheduler.gd                (rare events + timebase)
    RenderProfile.gd            (30fps lock, quality knobs)
  modules/
    orbital_overview/
      OrbitalOverview.tscn
      OrbitalOverview.gd
      manifest.json
    pac_containment/
      PacContainment.tscn
      PacContainment.gd
      manifest.json
    core_diagnostics/
      CoreDiagnostics.tscn
      CoreDiagnostics.gd
      manifest.json
    data_cascade/
      DataCascade.tscn
      DataCascade.gd
      manifest.json
    ...
  ui/
    DebugOverlay.tscn           (optional; toggle with key)
    DebugOverlay.gd
  assets/
    fonts/
    shaders/
    textures/
  config/
    app_config.json
    scene_pool.json
```

Everything important is in `core/`, scenes live in `modules/`.

---

## 2) Global runtime model

### 2.1 Timebase

* One global monotonic clock: `station_time` (seconds since boot).
* A fixed timestep option is *not* required, but we do want consistent motion:

  * lock FPS to 30 (see RenderProfile)
  * all motion derived from `delta` + `station_time`
* Support optional “beat” system: `beat = floor(station_time / beat_len)` for periodic but not identical events.

### 2.2 Virtual space model (bezel-aware, no dead pixels)

* Real framebuffer is **1024×(768×4)=1024×3072**.
* Virtual height includes gaps: `virtual_h = 768*4 + bezel_gap*3 = 4608`.
* Any animation that “travels vertically through the monolith” moves in virtual coordinates and is mapped into real panel coordinates, becoming invisible in bezel regions.

This is handled by `VirtualSpace.gd` + helper nodes.

### 2.3 Panels

Panels are logical rects in *real* coordinates:

* Panel0 rect: (0, 0, 1024, 768)
* Panel1 rect: (0, 768, 1024, 768)
* Panel2 rect: (0, 1536, 1024, 768)
* Panel3 rect: (0, 2304, 1024, 768)

No bezel spacing in real rendering.

---

## 3) Autoload singletons (Godot > Project Settings > Autoload)

### 3.1 `Config.gd`

Loads `res://config/app_config.json` at startup.

**Fields (example)**

* `target_fps`: 30
* `panel_count`: 4
* `panel_width`: 1024
* `panel_height`: 768
* `bezel_gap`: 512
* `fullscreen`: true
* `debug_overlay`: false
* `scene_pool_path`: `"res://config/scene_pool.json"`
* `transition_default`: `"fade_black"`
* `min_scene_runtime_sec`: 30
* `max_scene_runtime_sec`: 180
* `seed_policy`: `"boot"` | `"daily"` | `"fixed"` | `"scene+boot"`

**API**

```gdscript
extends Node
class_name Config

func load_config() -> void
func get_i(key: String, default := 0) -> int
func get_f(key: String, default := 0.0) -> float
func get_s(key: String, default := "") -> String
func get_b(key: String, default := false) -> bool
func get_dict(key: String, default := {}) -> Dictionary
```

### 3.2 `RNG.gd`

Central RNG service for:

* boot seed
* scene seed derivation
* reproducibility controls

**API**

```gdscript
extends Node
class_name RNG

var boot_seed: int
func init_seed() -> void
func derive_scene_seed(scene_id: String, variant := "") -> int
func make_rng(seed: int) -> RandomNumberGenerator
```

Seed derivation rule (recommended):

* `scene_seed = hash(scene_id + ":" + str(boot_seed) + ":" + variant)`

### 3.3 `EventBus.gd`

Signal hub to avoid tight coupling.

**Signals**

```gdscript
signal scene_started(scene_id: String, seed: int)
signal scene_finished(scene_id: String, reason: String)
signal rare_event(name: String, payload: Dictionary)
signal transition_started(name: String)
signal transition_finished(name: String)
```

### 3.4 `App.gd`

Top-level orchestrator. Starts Launcher. Applies render settings. Optional debug.

**API**

```gdscript
extends Node
class_name App

var station_time: float
func _ready() -> void
func _process(delta: float) -> void
```

---

## 4) Core systems

### 4.1 `RenderProfile.gd`

Applies:

* FPS cap
* fullscreen
* disables mouse cursor
* optional: disables vsync
* optional: toggle debug overlay

**API**

```gdscript
class_name RenderProfile
static func apply() -> void
```

Implementation notes:

* `Engine.max_fps = Config.get_i("target_fps", 30)`
* `DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)` if configured
* `Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)`

### 4.2 `PanelLayout.gd`

Returns panel rects and convenience mapping.

**API**

```gdscript
extends RefCounted
class_name PanelLayout

var panel_count: int
var panel_w: int
var panel_h: int

func get_panel_rect(i: int) -> Rect2
func clamp_panel_index(i: int) -> int
func get_total_real_size() -> Vector2i
```

### 4.3 `VirtualSpace.gd`

Defines virtual coordinate system with bezel gaps.

**Constants/fields**

* `PANEL_H`
* `BEZEL_GAP`
* `BLOCK = PANEL_H + BEZEL_GAP`
* `virtual_h = PANEL_H*count + BEZEL_GAP*(count-1)`

**API**

```gdscript
extends RefCounted
class_name VirtualSpace

func virtual_height() -> float
func virtual_to_real(vy: float) -> Dictionary
# returns:
# { visible: bool, panel: int, local_y: float, real_y: float }

func real_to_virtual(panel: int, local_y: float) -> float
```

**Mapping rules**

* `panel = floor(vy / BLOCK)`
* `local_y = vy - panel * BLOCK`
* visible if `0 <= local_y < PANEL_H`
* `real_y = panel*PANEL_H + local_y`

### 4.4 `Transitions.gd`

Reusable transitions between modules:

* fade to black
* CRT glitch wipe
* scanline pass
* hard cut (for “broken station” effect)

Transitions are implemented as an overlay `CanvasLayer` with shader or tweens.

**API**

```gdscript
extends Node
class_name Transitions

func play(name: String, duration: float, direction: String) -> void
# direction: "in" or "out"
# emits EventBus.transition_started/finished
```

---

## 5) Scene registry + manifest system

### 5.1 Manifest format (`modules/*/manifest.json`)

Each module ships a JSON manifest:

```json
{
  "id": "orbital_overview",
  "title": "Orbital Overview",
  "scene": "res://modules/orbital_overview/OrbitalOverview.tscn",
  "tags": ["vector", "wireframe", "slow"],
  "timeline": {
    "mode": "fixed|range|self",
    "duration_sec": 90,
    "min_sec": 60,
    "max_sec": 180
  },
  "transition": {
    "in": "fade_black",
    "out": "scanline_wipe",
    "in_duration": 1.0,
    "out_duration": 1.0
  },
  "seed": {
    "policy": "scene+boot",
    "variant": ""
  },
  "interruptible": true,
  "weight": 1.0
}
```

### 5.2 `SceneRegistry.gd`

Discovers modules by scanning `res://modules/` for `manifest.json`.

**API**

```gdscript
extends Node
class_name SceneRegistry

var manifests: Dictionary # id -> manifest dict

func scan() -> void
func get_manifest(id: String) -> Dictionary
func list_ids() -> Array[String]
```

### 5.3 `scene_pool.json`

Defines which scenes are eligible and with what weight constraints.

Example:

```json
{
  "pool": [
    {"id": "orbital_overview", "weight": 1.0},
    {"id": "pac_containment", "weight": 0.8},
    {"id": "core_diagnostics", "weight": 1.2},
    {"id": "data_cascade", "weight": 1.0}
  ],
  "no_repeat_window": 2
}
```

---

## 6) Module interface (the contract)

Every animation module scene root must implement `IModule` behavior.

### 6.1 Node requirements

* Root node script extends `Node2D` (or `Control` if UI-based).
* Must expose:

  * `module_id: String`
  * `module_rng: RandomNumberGenerator`
  * `module_started_at: float`

### 6.2 Required functions (exact signatures)

```gdscript
# Called immediately after instancing but before added to tree
func module_configure(ctx: Dictionary) -> void
# ctx includes:
# {
#   "seed": int,
#   "manifest": Dictionary,
#   "panel_layout": PanelLayout,
#   "virtual_space": VirtualSpace,
#   "station_time": float
# }

# Called when scene becomes active (after transition in begins or completes; pick one and be consistent)
func module_start() -> void

# Called every frame by Godot normally; modules do their own _process
# Optional but recommended: modules implement this to provide status.
func module_status() -> Dictionary
# returns:
# { "ok": bool, "notes": String, "intensity": float }

# Called when launcher requests a graceful stop (for self-timed scenes)
func module_request_stop(reason: String) -> void

# Must return true when the module is finished and safe to transition out
func module_is_finished() -> bool

# Called right before unloading (free resources, stop timers)
func module_shutdown() -> void
```

### 6.3 Timeline modes

* `fixed`: launcher runs for exactly `duration_sec` then requests stop and transitions out.
* `range`: launcher picks a random duration between min/max (using scene seed RNG), runs that long.
* `self`: module decides; launcher starts it and waits until `module_is_finished()` returns true. Launcher may still enforce global max as a safety.

---

## 7) Launcher (the heart)

### 7.1 `Launcher.tscn`

Scene structure:

```
Launcher (Node)
  SceneRoot (Node)               # holds the active module
  TransitionLayer (CanvasLayer)  # transitions overlay
  DebugOverlay (optional)
```

### 7.2 `Launcher.gd` responsibilities

* Scan registry
* Load pool config
* Select next module using weighted random with no-repeat window
* Instantiate module scene
* Create module context (seed, virtual space, layout)
* Run transitions and timing
* Request stop and unload cleanly
* Catch errors (module missing methods, etc.) and skip to next

### 7.3 Selection algorithm (weighted, no-repeat)

Maintain:

* `recent_ids: Array[String]` of length `no_repeat_window`
* Choose from pool excluding `recent_ids` if possible.
* Weighted random selection.

### 7.4 Launcher state machine

States:

* `IDLE`
* `TRANSITION_OUT`
* `LOADING`
* `TRANSITION_IN`
* `RUNNING`
* `STOPPING`
* `UNLOADING`

### 7.5 Timing rules

Per module:

* Determine `planned_runtime_sec`:

  * fixed -> duration
  * range -> rng in [min,max]
  * self -> planned = INF but guard with global max
* Keep:

  * `module_start_time = station_time`
  * `module_deadline = module_start_time + planned_runtime_sec` (or +global max)

Stop condition:

* if time >= deadline -> `module_request_stop("deadline")`
* if module_is_finished -> stop now
* if module not interruptible -> allow it to finish unless hard cap triggers

### 7.6 Transitions

Standard flow:

1. Transition out old module (if any)
2. Unload it
3. Load new module
4. Transition in

---

## 8) Procedural systems

### 8.1 Rare event scheduler (optional but recommended)

A `Scheduler.gd` that triggers occasional global events:

* “DISPLAY BUS CALIBRATION”
* “PHASE OFFSET CORRECTED”
* “UPLINK LOST”

Modules may subscribe via EventBus and respond stylistically.

**API**

```gdscript
extends Node
class_name Scheduler

func _process(delta: float) -> void
func set_rng(rng: RandomNumberGenerator) -> void
```

Event scheduling:

* Poisson-ish: each frame `if rng.randf() < p: emit_event()`
* Use long average intervals (10–30 minutes) for big events; 30–120 seconds for small ones.

---

## 9) Cross-panel vertical movers (utility node)

Create a reusable node `VirtualMover2D` to handle the “travel through bezel void” logic.

**Node**

* extends `Node2D`
* has child visuals (Line2D / Sprite2D / custom draw)

**Fields**

* `virtual_y: float`
* `speed_px_per_sec: float`
* `virtual_space: VirtualSpace`

**Behavior**

* update `virtual_y += speed * delta`
* map to real:

  * if visible: set `position.y = real_y` and `show()`
  * else: `hide()`

This way modules can drop in movers without rewriting math.

---

## 10) Debug + resilience (because installations are mean)

### 10.1 Debug overlay (toggle key)

Shows:

* active scene id
* uptime / station_time
* FPS
* planned runtime remaining
* seed
* last 5 rare events

### 10.2 Error handling rules

If a module:

* fails to load
* lacks required methods
* errors during start

Launcher should:

* log error
* show a brief “SUBSYSTEM OFFLINE” transition
* move to next module

### 10.3 Global hard cap

Even “self” scenes shouldn’t run forever unless they explicitly want to.
Have:

* `global_scene_hard_cap_sec` default 600
  If exceeded:
* force transition out (cut) and log “HARD_CAP”.

---

## 11) Example module template (what the CLI coder should copy)

**`modules/template/TemplateScene.gd`**

```gdscript
extends Node2D

var module_id := "template"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

var _manifest: Dictionary
var _panel_layout
var _virtual_space
var _stop_requested := false
var _finished := false

func module_configure(ctx: Dictionary) -> void:
    _manifest = ctx.manifest
    module_rng = RNG.make_rng(ctx.seed)
    _panel_layout = ctx.panel_layout
    _virtual_space = ctx.virtual_space

func module_start() -> void:
    module_started_at = App.station_time
    _stop_requested = false
    _finished = false
    # init procedural systems, timers, etc.

func module_status() -> Dictionary:
    return {"ok": true, "notes": "", "intensity": 0.5}

func module_request_stop(reason: String) -> void:
    _stop_requested = true
    # optionally start a graceful wind-down timer
    # set _finished true when done

func module_is_finished() -> bool:
    return _finished

func module_shutdown() -> void:
    # stop timers, disconnect signals, free heavy resources
    pass
```

---

## 12) Build/run expectations for the CLI coder

Deliverables:

* A working `Launcher.tscn` set as Main Scene.
* Autoloads configured.
* Registry scanning + pool selection.
* At least 2 demo modules:

  1. `OrbitalOverview` (vector wireframe + slow radar sweep)
  2. `DataCascade` (virtual vertical mover crossing panels)

Controls:

* `Esc` quits (or disable for kiosk).
* `F1` toggles debug overlay.
* `N` skips to next module (debug only).

---

## 13) Installation/kiosk notes (operational)

* The app should tolerate being killed and restarted.
* It should never require keyboard/mouse.
* It should start in fullscreen and stay there.
* If Godot crashes, systemd restarts it (you already planned this).

---

## 14) What “excruciating detail” means in practice (testing checklist)

**Launcher**

* [ ] No-repeat window works
* [ ] Weighted selection works
* [ ] Transitions always occur even if module fails
* [ ] Module seeds stable per boot
* [ ] Hard cap enforced
* [ ] Logs written

**Virtual space**

* [ ] Virtual mover disappears in bezel gap
* [ ] Reappears at next panel top with correct timing
* [ ] No off-by-one panel index at boundaries
* [ ] Clamped for vy < 0 or vy > virtual_h (wrap or reset)

**Modules**

* [ ] Each module respects `module_request_stop`
* [ ] Each module can self-finish for “self” mode
* [ ] No memory leak from lingering signals/timers

---

## 15) Suggested next step: define your first 8 modules

To make the launcher feel rich, you want variety:

* 3 slow “hero” scenes (orbital, subway schematic, wireframe object)
* 3 medium “activity” scenes (telemetry, containment sim, node network)
* 2 “rare event” scenes (calibration, alarm storm)

But the framework above makes that trivial to plug in.
