## ControlBoard — toggle animations on/off at runtime.
## Toggle visibility with F2. Mouse is shown while open.
## Launcher reads is_enabled() before each module pick.
extends CanvasLayer

# id → true means disabled
var _disabled: Dictionary = {}
# id → CheckBox node for runtime updates
var _checkboxes: Dictionary = {}

var _now_playing_label: Label = null
var _mouse_was_hidden := false

# ─── Setup ────────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer   = 201
	visible = false
	_build_ui()

func _build_ui() -> void:
	# Root container — auto-sizes to content
	var root := PanelContainer.new()
	root.position = Vector2(30, 30)
	_style_panel(root)
	add_child(root)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top",    12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.add_theme_constant_override("margin_left",   14)
	margin.add_theme_constant_override("margin_right",  14)
	root.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.custom_minimum_size = Vector2(460, 0)
	margin.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	_add_label(vbox, "▶  ANIMATION CONTROL BOARD", 15, Color(0.10, 0.95, 0.75, 1.0))
	_add_label(vbox, "F2 to close  ·  click rows to toggle", 10, Color(0.35, 0.55, 0.55, 0.80))
	vbox.add_child(_sep())

	# ── Now playing ───────────────────────────────────────────────────────────
	_now_playing_label = _add_label(vbox, "NOW PLAYING:  —", 12, Color(0.90, 0.62, 0.08, 1.0))
	vbox.add_child(_sep())

	# ── Bulk buttons ──────────────────────────────────────────────────────────
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(hbox)
	_add_button(hbox, "ALL ON",  _on_all_on)
	_add_button(hbox, "ALL OFF", _on_all_off)
	vbox.add_child(_sep())

	# ── Column headings ───────────────────────────────────────────────────────
	_add_label(vbox, "      %-30s  WT" % "MODULE", 10, Color(0.30, 0.50, 0.52, 0.80))

	# ── Per-module rows ───────────────────────────────────────────────────────
	for entry in _load_pool_entries():
		_add_row(vbox, entry["id"], entry["title"], entry["weight"])

	vbox.add_child(_sep())

	# ── Close button ──────────────────────────────────────────────────────────
	_add_button(vbox, "CLOSE  [F2]", func(): toggle())

# ─── Row / widget helpers ──────────────────────────────────────────────────────

func _add_row(parent: Control, id: String, title: String, weight: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var cb := CheckBox.new()
	cb.button_pressed = true   # enabled by default
	cb.add_theme_font_size_override("font_size", 12)
	cb.toggled.connect(_on_toggle.bind(id))
	row.add_child(cb)
	_checkboxes[id] = cb

	var lbl := Label.new()
	lbl.text = title.left(30)
	lbl.custom_minimum_size = Vector2(300, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.82, 0.92, 0.88, 0.95))
	row.add_child(lbl)

	var wlbl := Label.new()
	wlbl.text = "%.1f" % weight
	wlbl.add_theme_font_size_override("font_size", 11)
	wlbl.add_theme_color_override("font_color", Color(0.38, 0.58, 0.58, 0.70))
	row.add_child(wlbl)

func _add_label(parent: Control, text: String, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl

func _add_button(parent: Control, text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 12)
	btn.pressed.connect(cb)
	parent.add_child(btn)
	return btn

func _sep() -> HSeparator:
	var s   := HSeparator.new()
	var st  := StyleBoxFlat.new()
	st.bg_color              = Color(0.0, 0.45, 0.55, 0.40)
	st.content_margin_top    = 1
	st.content_margin_bottom = 1
	s.add_theme_stylebox_override("separator", st)
	return s

func _style_panel(p: PanelContainer) -> void:
	var st := StyleBoxFlat.new()
	st.bg_color               = Color(0.04, 0.07, 0.09, 0.95)
	st.border_width_left      = 1
	st.border_width_right     = 1
	st.border_width_top       = 1
	st.border_width_bottom    = 1
	st.border_color           = Color(0.00, 0.65, 0.75, 0.75)
	st.corner_radius_top_left     = 3
	st.corner_radius_top_right    = 3
	st.corner_radius_bottom_left  = 3
	st.corner_radius_bottom_right = 3
	p.add_theme_stylebox_override("panel", st)

# ─── Public API ───────────────────────────────────────────────────────────────

func is_enabled(id: String) -> bool:
	return not _disabled.has(id)

func toggle() -> void:
	if not visible:
		_mouse_was_hidden = Input.get_mouse_mode() == Input.MOUSE_MODE_HIDDEN
		visible = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		visible = false
		if _mouse_was_hidden:
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

# ─── Handlers ─────────────────────────────────────────────────────────────────

func _on_toggle(pressed: bool, id: String) -> void:
	if pressed:
		_disabled.erase(id)
	else:
		_disabled[id] = true

func _on_all_on() -> void:
	_disabled.clear()
	for id in _checkboxes:
		(_checkboxes[id] as CheckBox).button_pressed = true

func _on_all_off() -> void:
	for id in _checkboxes:
		_disabled[id] = true
		(_checkboxes[id] as CheckBox).button_pressed = false

# ─── Process: keep "now playing" current ─────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_control_board"):
		toggle()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if not visible or _now_playing_label == null:
		return
	var launcher := get_tree().get_root().find_child("Launcher", true, false)
	if launcher != null and launcher.has_method("get_active_manifest"):
		var m: Dictionary = launcher.get_active_manifest()
		var id: String    = m.get("id", "—")
		_now_playing_label.text = "NOW PLAYING:  " + id
		# Dim the row for the active module so user knows it won't be skipped mid-run
		if _checkboxes.has(id):
			(_checkboxes[id] as CheckBox).modulate = Color(1, 1, 0.4, 1.0)
		# Restore all other rows to normal
		for other_id in _checkboxes:
			if other_id != id:
				(_checkboxes[other_id] as CheckBox).modulate = Color(1, 1, 1, 1)

# ─── Pool data ────────────────────────────────────────────────────────────────

func _load_pool_entries() -> Array:
	var result := []
	var pool_path := Config.get_s("scene_pool_path", "res://config/scene_pool.json")
	var f := FileAccess.open(pool_path, FileAccess.READ)
	if f == null:
		return result
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return result
	for entry in parsed.get("pool", []):
		if not (entry is Dictionary) or not entry.has("id"):
			continue
		var id      := str(entry["id"])
		var weight  := float(entry.get("weight", 1.0))
		var title   := id
		var mf := FileAccess.open("res://modules/%s/manifest.json" % id, FileAccess.READ)
		if mf != null:
			var mp = JSON.parse_string(mf.get_as_text())
			mf.close()
			if mp is Dictionary:
				title = str(mp.get("title", id))
		result.append({"id": id, "title": title, "weight": weight})
	return result
