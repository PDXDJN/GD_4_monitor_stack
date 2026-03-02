extends Node

## Central RNG service. Provides a stable boot seed and per-scene derivation.
## Depends on: Logger, Config

var boot_seed: int = 0

func _ready() -> void:
	init_seed()

func init_seed() -> void:
	var policy := Config.get_s("seed_policy", "boot")
	match policy:
		"daily":
			var d := Time.get_date_dict_from_system()
			boot_seed = hash("%d-%02d-%02d" % [d.year, d.month, d.day])
		"fixed":
			boot_seed = 42424242
		"boot", "scene+boot", _:
			# Use time at boot for randomness per-run
			boot_seed = int(Time.get_unix_time_from_system())
	Logger.info("RNG: boot_seed initialised", {"policy": policy, "seed": boot_seed})

func derive_scene_seed(scene_id: String, variant := "") -> int:
	var raw := "%s:%d:%s" % [scene_id, boot_seed, variant]
	return hash(raw)

func make_rng(seed_val: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	return rng
