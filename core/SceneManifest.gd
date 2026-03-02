## Wraps and validates a module manifest dictionary.
## Returns defaults for missing fields so modules don't need to be exhaustive.

class_name SceneManifest

static func validate(raw: Dictionary) -> Dictionary:
	var m := {}

	m["id"]            = raw.get("id", "unknown")
	m["title"]         = raw.get("title", m["id"])
	m["scene"]         = raw.get("scene", "")
	m["tags"]          = raw.get("tags", [])
	m["weight"]        = float(raw.get("weight", 1.0))
	m["interruptible"] = bool(raw.get("interruptible", true))

	# Timeline (timing config: mode + duration bounds)
	var tl: Dictionary = raw.get("timeline", {})
	m["timeline"] = {
		"mode":           tl.get("mode", "range"),
		"duration_sec":   float(tl.get("duration_sec", 90.0)),
		"min_sec":        float(tl.get("min_sec", 60.0)),
		"max_sec":        float(tl.get("max_sec", 180.0)),
		"allow_early_exit": bool(tl.get("allow_early_exit", true)),
	}

	# Sequence: optional array of timed ops.
	# Each entry: { "t": float, "op": "call"|"emit", "method"|"signal": str, "args": [] }
	var seq = raw.get("sequence", [])
	m["sequence"] = seq if seq is Array else []

	# Transition
	var tr: Dictionary = raw.get("transition", {})
	m["transition"] = {
		"in":           tr.get("in", "fade_black"),
		"out":          tr.get("out", "fade_black"),
		"in_duration":  float(tr.get("in_duration", 1.0)),
		"out_duration": float(tr.get("out_duration", 1.0)),
	}

	# Seed
	var sd: Dictionary = raw.get("seed", {})
	m["seed"] = {
		"policy":  sd.get("policy", "scene+boot"),
		"variant": sd.get("variant", ""),
	}

	return m

static func is_valid(m: Dictionary) -> bool:
	return m.has("id") and m.has("scene") and m["scene"] != ""
