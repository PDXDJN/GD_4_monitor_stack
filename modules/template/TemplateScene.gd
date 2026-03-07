## Template module — copy and rename to create new animation modules.
## See CLAUDE.md section 11 for the full contract.
extends Node2D

var module_id := "template"
var module_rng: RandomNumberGenerator
var module_started_at := 0.0

var _manifest: Dictionary
var _panel_layout: PanelLayout
var _virtual_space: VirtualSpace
var _stop_requested := false
var _finished := false

func module_configure(ctx: Dictionary) -> void:
	_manifest = ctx["manifest"]
	module_rng = RNG.make_rng(ctx["seed"])
	_panel_layout = ctx["panel_layout"]
	_virtual_space = ctx["virtual_space"]

func module_start() -> void:
	module_started_at = App.station_time
	_stop_requested = false
	_finished = false
	# TODO: init procedural systems, timers, etc.

func module_status() -> Dictionary:
	return {"ok": true, "notes": "template running", "intensity": 0.5}

func module_request_stop(reason: String) -> void:
	_stop_requested = true
	Log.debug("Template: stop requested", {"reason": reason})
	# TODO: start graceful wind-down, then set _finished = true
	_finished = true  # Immediate for template

func module_is_finished() -> bool:
	return _finished

func module_shutdown() -> void:
	# TODO: stop timers, disconnect signals, free heavy resources
	pass
