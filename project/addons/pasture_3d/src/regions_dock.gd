# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The Regions dock (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §G): the region selection's inspector rows
# and its actions. Selection itself happens in the viewport, in the Region tool (see editor_plugin.gd); this
# only shows and acts on it. Everything here goes through region_selection.gd, which the gate measures.
@tool
extends PanelContainer

const RegionSelection := preload("res://addons/pasture_3d/src/region_selection.gd")
const BUILTIN_TYPES := [
	"res://addons/pasture_3d/region_types/standard.tres",
	"res://addons/pasture_3d/region_types/background.tres",
]

var plugin: EditorPlugin
var model: RegionSelection

var _summary: Label
var _rows: GridContainer
var _type_pick: OptionButton
var _type_paths: Array[String] = []
var _result: Label
var _confirm: ConfirmationDialog
var _pending_type: Resource = null
var _buttons := {}
var _watched_data = null


func initialize(p_plugin: EditorPlugin, p_model: RegionSelection) -> void:
	plugin = p_plugin
	model = p_model
	name = "Pasture3D Regions"
	plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, self)

	# A wrapping Label measured at zero width (the dock before its tab is first shown) reports one word per
	# line as its minimum height. Without the scroll container that height reaches the dock slot and squeezes
	# the viewport and every other dock until the tab is clicked.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)
	var title := Label.new()
	title.text = "Regions"
	root.add_child(title)
	var hint := Label.new()
	hint.text = "Region tool: click a region to select it, Shift-click to toggle, drag for a box " \
		+ "(Shift adds, Shift+Ctrl removes)."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 120
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root.add_child(hint)
	_summary = Label.new()
	root.add_child(_summary)

	_rows = GridContainer.new()
	_rows.columns = 2
	root.add_child(_rows)

	var row1 := HBoxContainer.new()
	root.add_child(row1)
	_button(row1, "Load", "Load the selected regions that are not loaded.", func(): _show(model.load_selected(), "Loaded"))
	_button(row1, "Unload", "Unload the selected regions. A region with unsaved changes is saved first, "
		+ "and its undo history is dropped.", func(): _show(model.unload_selected(), "Unloaded"))
	_button(row1, "Bake Selected", "Bake every brush that touches the selection, over its whole footprint. "
		+ "Loads the regions the bake needs and releases them after.", _on_bake)
	var row2 := HBoxContainer.new()
	root.add_child(row2)
	_button(row2, "Lock", "Lock the selected loaded regions: strokes, bakes and type changes skip them.",
		func(): _show(model.set_locked(true), "Locked"))
	_button(row2, "Unlock", "Unlock the selected loaded regions.", func(): _show(model.set_locked(false), "Unlocked"))
	_button(row2, "Clear", "Clear the selection.", func(): model.clear())
	var row3 := HBoxContainer.new()
	root.add_child(row3)
	_type_pick = OptionButton.new()
	_type_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(_type_pick)
	_button(row3, "Set Type", "Give the selected loaded, unlocked regions this type. Moving to a coarser type "
		+ "downsamples them and discards detail, and asks first.", _on_set_type)
	var row4 := HBoxContainer.new()
	root.add_child(row4)
	_button(row4, "Delete", "Delete the selected loaded regions (Remove Region, one undo action). The files "
		+ "go on the next save.", func(): _show(model.delete_selected(plugin.editor if plugin else null), "Deleted"))

	_result = Label.new()
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.custom_minimum_size.x = 120
	root.add_child(_result)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_type_confirmed)
	add_child(_confirm)

	model.changed.connect(refresh)
	refresh()


func _button(p_parent: Node, p_text: String, p_tip: String, p_call: Callable) -> Button:
	var b := Button.new()
	b.text = p_text
	b.tooltip_text = p_tip
	b.pressed.connect(p_call)
	p_parent.add_child(b)
	_buttons[p_text] = b
	return b


func remove_dock() -> void:
	if plugin:
		plugin.remove_control_from_docks(self)


func set_terrain(p_terrain) -> void:
	if _watched_data != null and is_instance_valid(_watched_data) \
			and _watched_data.region_map_changed.is_connected(_on_regions_changed):
		_watched_data.region_map_changed.disconnect(_on_regions_changed)
	_watched_data = p_terrain.data if p_terrain != null and is_instance_valid(p_terrain) else null
	if _watched_data != null:
		_watched_data.region_map_changed.connect(_on_regions_changed)
	model.terrain = p_terrain
	_type_paths.clear() # the names come from the terrain's data: without one they were file names
	model.prune()
	refresh()


func _on_regions_changed() -> void:
	model.prune()
	refresh()
	if plugin and plugin.has_method("update_region_gizmo"):
		plugin.update_region_gizmo()


func refresh() -> void:
	if _summary == null:
		return
	for c in _rows.get_children():
		c.queue_free()
	var sel := model.selected
	var loaded := 0
	for loc in sel:
		if model.state(loc) == RegionSelection.STATE_LOADED:
			loaded += 1
	_summary.text = "No terrain" if model.terrain == null else ("%d selected (%d loaded, %d unloaded) of %d"
		% [sel.size(), loaded, sel.size() - loaded, model.known().size()])
	if sel.size() == 1:
		var inf := model.info(sel[0])
		_row("Location", str(inf["location"]))
		_row("State", "loaded" if inf["loaded"] else "unloaded")
		_row("Type", "%s (1:%d)" % [inf.get("type_name", "?"), int(inf.get("texel_ratio", 1))])
		_row("Resolution", "%d x %d" % [inf["resolution"].x, inf["resolution"].y])
		_row("Locked", "yes" if inf.get("locked", false) else "no")
		_row("Unsaved changes", "yes" if inf.get("dirty", false) else "no")
		_row("Memory", "%s%s" % ["~" if inf.get("memory_estimated", false) else "",
			String.humanize_size(int(inf.get("memory_bytes", 0)))])
	elif sel.size() > 1:
		var bytes := 0
		for loc in sel:
			bytes += int(model.info(loc).get("memory_bytes", 0))
		_row("Memory", String.humanize_size(bytes))
	_refresh_types()
	for k in _buttons:
		_buttons[k].disabled = sel.is_empty() and k != "Clear"


func _row(p_key: String, p_value: String) -> void:
	var k := Label.new()
	k.text = p_key
	k.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_rows.add_child(k)
	var v := Label.new()
	v.text = p_value
	_rows.add_child(v)


## The built-ins, and any other type a known region already uses.
func _refresh_types() -> void:
	var paths: Array[String] = []
	paths.assign(BUILTIN_TYPES)
	for loc in model.known():
		var p := str(model.info(loc).get("type_path", ""))
		if not p.is_empty() and not paths.has(p):
			paths.append(p)
	if paths == _type_paths:
		return
	_type_paths = paths
	var keep := _type_pick.selected
	_type_pick.clear()
	for p in paths:
		var t = model.terrain.data.load_region_type(p) if model.terrain != null else null
		_type_pick.add_item(t.get_type_name() if t != null else p.get_file())
	_type_pick.selected = clampi(keep, 0, paths.size() - 1)


func _on_set_type() -> void:
	if _type_pick.selected < 0 or model.terrain == null:
		return
	var t: Resource = model.terrain.data.load_region_type(_type_paths[_type_pick.selected])
	var down := model.downsampled_by(t)
	if down.is_empty():
		_show(model.set_type(t), "Set type on")
		return
	_pending_type = t
	_confirm.title = "Downsample regions?"
	_confirm.dialog_text = ("%d region(s) will be downsampled to %s (1:%d). The detail above that resolution "
		+ "is discarded, and undo does not cover it.") % [down.size(), t.get_type_name(), t.get_texel_ratio()]
	_confirm.popup_centered()


func _on_type_confirmed() -> void:
	if _pending_type != null:
		_show(model.set_type(_pending_type), "Set type on")
	_pending_type = null


func _on_bake() -> void:
	var rep := model.bake_selected()
	if not bool(rep.get("ok", false)):
		_result.text = "Bake: %s" % rep.get("reason", "failed")
		return
	_result.text = "Baked %d owner(s); loaded %d region(s) for it, released %d; %d locked and %d over budget skipped." \
		% [(rep.get("owners", []) as Array).size(), (rep.get("loaded_for_bake", []) as Array).size(),
			(rep.get("released", []) as Array).size(), (rep.get("skipped_locked", []) as Array).size(),
			(rep.get("skipped_budget", []) as Array).size()]


func _show(p_rep: Dictionary, p_verb: String) -> void:
	var skipped: Dictionary = p_rep["skipped"]
	var text := "%s %d region(s)." % [p_verb, (p_rep["done"] as Array).size()]
	if not skipped.is_empty():
		var why := {}
		for loc in skipped:
			why[skipped[loc]] = int(why.get(skipped[loc], 0)) + 1
		var parts := PackedStringArray()
		for w in why:
			parts.append("%d %s" % [why[w], w])
		text += " Skipped: " + ", ".join(parts) + "."
	_result.text = text
	if plugin and plugin.has_method("update_region_gizmo"):
		plugin.update_region_gizmo()
