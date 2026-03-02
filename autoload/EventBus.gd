extends Node

## Central signal hub. Modules and systems communicate through here.

signal scene_started(scene_id: String, seed: int)
signal scene_finished(scene_id: String, reason: String)
signal rare_event(name: String, payload: Dictionary)
signal transition_started(name: String)
signal transition_finished(name: String)
signal debug_skip_requested()
