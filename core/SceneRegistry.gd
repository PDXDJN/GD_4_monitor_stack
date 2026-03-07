## Scans res://modules/ for manifest.json files and builds a registry.
## Depends on: Logger, SceneManifest

class_name SceneRegistry
extends Node

var manifests: Dictionary = {}  # id -> validated manifest dict

func scan() -> void:
	manifests.clear()
	var base_dir := "res://modules"
	var dir := DirAccess.open(base_dir)
	if dir == null:
		Log.error("SceneRegistry: cannot open modules directory", {"path": base_dir})
		return

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			_try_load_manifest(base_dir + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()

	Log.info("SceneRegistry: scan complete", {"count": manifests.size(), "ids": manifests.keys()})

func _try_load_manifest(module_path: String) -> void:
	var manifest_path := module_path + "/manifest.json"
	if not FileAccess.file_exists(manifest_path):
		return

	var f := FileAccess.open(manifest_path, FileAccess.READ)
	if f == null:
		Log.warn("SceneRegistry: could not open manifest", {"path": manifest_path})
		return

	var text := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		Log.warn("SceneRegistry: invalid JSON in manifest", {"path": manifest_path})
		return

	var validated := SceneManifest.validate(parsed)
	if not SceneManifest.is_valid(validated):
		Log.warn("SceneRegistry: manifest failed validation", {"path": manifest_path})
		return

	manifests[validated["id"]] = validated
	Log.debug("SceneRegistry: registered module", {"id": validated["id"]})

func get_manifest(id: String) -> Dictionary:
	return manifests.get(id, {})

func list_ids() -> Array[String]:
	var ids: Array[String] = []
	for k in manifests.keys():
		ids.append(str(k))
	return ids
