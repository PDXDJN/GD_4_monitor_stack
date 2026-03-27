extends Node

## Central signal hub. Modules and systems communicate through here.

@warning_ignore("UNUSED_SIGNAL") signal scene_started(scene_id: String, seed: int)
@warning_ignore("UNUSED_SIGNAL") signal scene_finished(scene_id: String, reason: String)
@warning_ignore("UNUSED_SIGNAL") signal rare_event(name: String, payload: Dictionary)
@warning_ignore("UNUSED_SIGNAL") signal transition_started(name: String)
@warning_ignore("UNUSED_SIGNAL") signal transition_finished(name: String)
@warning_ignore("UNUSED_SIGNAL") signal debug_skip_requested()
@warning_ignore("UNUSED_SIGNAL") signal debug_skip_prev_requested()
@warning_ignore("UNUSED_SIGNAL") signal resolution_changed(profile_name: String, panel_w: int, panel_h: int)
