# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Layers dock for Pasture3D — the editor UI for the non-destructive height-map layer stack.
# See PASTURE3D_LAYERS_GUIDE.md §6. The list mirrors Pasture3DData's bound stack API; structural
# and visual changes recomposite the affected regions so the viewport stays live.
@tool
extends PanelContainer

const BLEND_NAMES: Array[String] = [ "Replace", "Add", "Max", "Min" ]
# Option index -> Pasture3DLayer.BlendMode. BLEND_MAX (placeholder) is intentionally omitted.
const BLEND_MODES: Array[int] = [
	Pasture3DLayer.REPLACE, Pasture3DLayer.ADD, Pasture3DLayer.MAX, Pasture3DLayer.MIN ]
# Owner_id namespace of brush tool layers (Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX). Used to tell a
# tool layer apart from hand layers / road-connector layers when flagging orphaned tool layers.
const BRUSH_OWNER_PREFIX: String = "pasture3d_brush:"

var plugin: EditorPlugin
var terrain: Pasture3D

var _list: VBoxContainer
var _add_btn: Button
var _dup_btn: Button
var _del_btn: Button
var _up_btn: Button
var _down_btn: Button
var _warning: Label
var _warning_timer: Timer
var _rows: Array = []
var _assigned_owners: Dictionary = {} # owner_id -> true, the tool layers some brush node targets


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Pasture3D Layers"
	# Dock first so the control is in the tree and theme icons resolve while building the toolbar.
	plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, self)

	var root := VBoxContainer.new()
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# Toolbar
	var bar := HBoxContainer.new()
	root.add_child(bar)
	var title := Label.new()
	title.text = "Layers"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	_add_btn = _make_tool_button(bar, "Add", "Add", "Add a new layer above the active one")
	_dup_btn = _make_tool_button(bar, "Duplicate", "Duplicate", "Duplicate the active layer")
	_del_btn = _make_tool_button(bar, "Remove", "Remove", "Remove the active layer")
	_up_btn = _make_tool_button(bar, "MoveUp", "ArrowUp", "Move the active layer up (composites later)")
	_down_btn = _make_tool_button(bar, "MoveDown", "ArrowDown", "Move the active layer down")
	_add_btn.pressed.connect(_on_add)
	_dup_btn.pressed.connect(_on_duplicate)
	_del_btn.pressed.connect(_on_remove)
	_up_btn.pressed.connect(_on_move_up)
	_down_btn.pressed.connect(_on_move_down)

	# Warning line (flashes when a stroke hits a locked/reserved layer)
	_warning = Label.new()
	_warning.add_theme_color_override("font_color", Color("FC7F7F"))
	_warning.visible = false
	root.add_child(_warning)
	_warning_timer = Timer.new()
	_warning_timer.one_shot = true
	_warning_timer.wait_time = 2.5
	_warning_timer.timeout.connect(func(): _warning.visible = false)
	add_child(_warning_timer)

	# Scrollable layer list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	refresh()


func _make_tool_button(p_parent: Node, p_name: String, p_icon: String, p_tip: String) -> Button:
	var b := Button.new()
	b.name = p_name
	b.tooltip_text = p_tip
	b.flat = true
	if EditorInterface.get_edited_scene_root() != self:
		b.icon = get_theme_icon(p_icon, "EditorIcons")
	p_parent.add_child(b)
	return b


func remove_dock() -> void:
	if plugin:
		plugin.remove_control_from_docks(self)


func set_terrain(p_terrain: Pasture3D) -> void:
	terrain = p_terrain
	refresh()


func _data() -> Pasture3DData:
	if is_instance_valid(terrain) and terrain.data:
		return terrain.data
	return null


func _stack() -> Pasture3DLayerStack:
	var d := _data()
	if d and d.has_layer_stack():
		return d.get_layer_stack()
	return null


## Flash a UE-style warning. Called by the editor plugin when a stroke is blocked.
func flash_warning(p_layer_name: String, p_hidden: bool = false) -> void:
	if p_hidden:
		_warning.text = "Layer '%s' is hidden — stroke blocked. Make it visible to paint." % p_layer_name
	else:
		_warning.text = "Layer '%s' is locked or reserved — stroke blocked" % p_layer_name
	_warning.visible = true
	_warning_timer.start()


## Rebuild the whole list from the current stack.
func refresh() -> void:
	if not is_instance_valid(_list):
		return
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()

	var d := _data()
	# A freshly added node has no stack yet (the Base is only synthesized on load). Create one so the
	# panel can show and grow it. Add stays enabled whenever a terrain is selected.
	if d:
		d.ensure_layer_stack()
	_add_btn.disabled = d == null

	var stack := _stack()
	_dup_btn.disabled = stack == null
	if stack == null:
		return

	# Which tool layers a Pasture3DTerrainBrush currently targets — recomputed each refresh so the
	# orphaned-tool-layer badges stay current as tools are added/removed/reassigned.
	_assigned_owners = _assigned_brush_owners()

	var active: int = stack.get_active_layer()
	var count: int = stack.get_layer_count()
	# List top layer first so the visual order matches compositing (top = drawn last/over).
	for i in range(count - 1, -1, -1):
		var layer: Pasture3DLayer = stack.get_layer(i)
		if layer == null:
			continue
		_list.add_child(_build_row(i, layer, i == active))

	_del_btn.disabled = active == 0
	_up_btn.disabled = active == 0 or active >= count - 1
	_down_btn.disabled = active <= 1


func _build_row(p_idx: int, p_layer: Pasture3DLayer, p_active: bool) -> Control:
	var row := PanelContainer.new()
	row.set_meta("layer_idx", p_idx)
	if p_active:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.26, 0.45, 0.78, 0.5)
		sb.set_content_margin_all(3)
		row.add_theme_stylebox_override("panel", sb)

	var hb := HBoxContainer.new()
	row.add_child(hb)

	# Visibility toggle
	var vis := CheckButton.new()
	vis.button_pressed = p_layer.is_visible()
	vis.tooltip_text = "Visible"
	vis.toggled.connect(func(v): _on_visible(p_idx, v))
	hb.add_child(vis)

	# Warning badge: orphaned tool layer (no tool targets it) or, as a fallback, an empty layer.
	var status := _layer_status(p_layer)
	if status != "":
		var warn := TextureRect.new()
		warn.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		warn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if EditorInterface.get_edited_scene_root() != self:
			warn.texture = get_theme_icon("NodeWarning", "EditorIcons")
		if status == "orphan":
			warn.tooltip_text = "Tool layer '%s' has no tools assigned — safe to delete, or assign a tool to it." % p_layer.get_layer_name()
		else:
			warn.tooltip_text = "Layer '%s' is empty (nothing painted into it yet)." % p_layer.get_layer_name()
		hb.add_child(warn)

	# Name (click to make active; submit to rename)
	var name_edit := LineEdit.new()
	name_edit.text = p_layer.get_layer_name()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.tooltip_text = "Layer name (Base is index 0)"
	name_edit.text_submitted.connect(func(t): _on_rename(p_idx, t))
	name_edit.gui_input.connect(func(e): _on_row_input(p_idx, e))
	hb.add_child(name_edit)

	# Blend mode
	var blend := OptionButton.new()
	for n in BLEND_NAMES:
		blend.add_item(n)
	blend.select(BLEND_MODES.find(p_layer.get_blend_mode()))
	blend.tooltip_text = "Blend mode"
	blend.item_selected.connect(func(sel): _on_blend(p_idx, sel))
	hb.add_child(blend)

	# Opacity
	var op := HSlider.new()
	op.min_value = 0.0
	op.max_value = 1.0
	op.step = 0.01
	op.value = p_layer.get_opacity()
	op.custom_minimum_size = Vector2(70, 0)
	op.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	op.tooltip_text = "Opacity"
	op.value_changed.connect(func(v): _on_opacity(p_idx, v))
	hb.add_child(op)

	# Lock toggle
	var lock := CheckButton.new()
	lock.button_pressed = p_layer.is_locked()
	lock.tooltip_text = "Locked (blocks sculpting)"
	lock.toggled.connect(func(v): _on_lock(p_idx, v))
	hb.add_child(lock)

	# Drag-reorder support lives on the row.
	row.set_drag_forwarding(
		_get_row_drag.bind(p_idx), _can_drop_row.bind(p_idx), _drop_row.bind(p_idx))
	return row


## ---- Tool-layer health (orphaned / empty) ----

## owner_ids of the tool layers that some Pasture3DTerrainBrush in the edited scene currently targets.
func _assigned_brush_owners() -> Dictionary:
	var owners := {}
	var root := EditorInterface.get_edited_scene_root()
	if root:
		_collect_brush_owners(root, owners)
	return owners


func _collect_brush_owners(node: Node, owners: Dictionary) -> void:
	var brush := node as Pasture3DTerrainBrush
	if brush and brush.terrain == terrain and brush._layer_owner != "":
		owners[brush._layer_owner] = true
	for c in node.get_children():
		_collect_brush_owners(c, owners)


## "" = healthy, "orphan" = brush tool layer no tool targets, "empty" = non-base layer with no tiles.
## Orphan is the primary signal (requirement 4); empty is the fallback (requirement 5).
func _layer_status(p_layer: Pasture3DLayer) -> String:
	var owner := p_layer.get_owner_id()
	if p_layer.is_reserved() and owner.begins_with(BRUSH_OWNER_PREFIX) and not _assigned_owners.has(owner):
		return "orphan"
	if not p_layer.is_base() and p_layer.get_region_locations().is_empty():
		return "empty"
	return ""


## Row interactions


func _set_active(p_idx: int) -> void:
	var stack := _stack()
	if stack:
		stack.set_active_layer(p_idx)
		refresh()


func _on_row_input(p_idx: int, p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton and p_event.pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		_set_active(p_idx)


func _on_visible(p_idx: int, p_visible: bool) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		layer.set_visible(p_visible)
		_data().recomposite_layer(p_idx)
		_mark_unsaved()


func _on_lock(p_idx: int, p_locked: bool) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		layer.set_locked(p_locked)
		_mark_unsaved()


func _on_opacity(p_idx: int, p_value: float) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		layer.set_opacity(p_value)
		_data().recomposite_layer(p_idx)
		_mark_unsaved()


func _on_blend(p_idx: int, p_selected: int) -> void:
	var stack := _stack()
	if not stack or p_selected < 0 or p_selected >= BLEND_MODES.size():
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		layer.set_blend_mode(BLEND_MODES[p_selected])
		_data().recomposite_layer(p_idx)
		_mark_unsaved()


func _on_rename(p_idx: int, p_text: String) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		layer.set_layer_name(p_text)
		_mark_unsaved()


## Toolbar actions


func _on_add() -> void:
	var d := _data()
	if not d:
		return
	var stack := _stack()
	var n: int = stack.get_layer_count() if stack else 0
	# Hand-sculpt layers author absolute heights, so REPLACE is the sane default (§11).
	var idx: int = d.layer_add("Layer %d" % n, Pasture3DLayer.REPLACE)
	if idx >= 0:
		d.get_layer_stack().set_active_layer(idx)
	refresh()
	_mark_unsaved()


func _on_duplicate() -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var idx: int = d.layer_duplicate(stack.get_active_layer())
	if idx >= 0:
		d.get_layer_stack().set_active_layer(idx)
	refresh()
	_mark_unsaved()


func _on_remove() -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	d.layer_remove(stack.get_active_layer())
	refresh()
	_mark_unsaved()


func _on_move_up() -> void:
	_move_active(1)


func _on_move_down() -> void:
	_move_active(-1)


func _move_active(p_dir: int) -> void:
	var stack := _stack()
	if not stack:
		return
	var from: int = stack.get_active_layer()
	var to: int = from + p_dir
	if from <= 0 or to <= 0 or to >= stack.get_layer_count():
		return
	_move_layer_undoable(from, to)


## Drag-and-drop reordering (forwarded from each row)


func _get_row_drag(_pos: Vector2, p_idx: int) -> Variant:
	if p_idx == 0:
		return null # Base never moves.
	var preview := Label.new()
	var stack := _stack()
	var layer: Pasture3DLayer = stack.get_layer(p_idx) if stack else null
	preview.text = layer.get_layer_name() if layer else "Layer"
	set_drag_preview(preview)
	return { "p3d_layer": p_idx }


func _can_drop_row(_pos: Vector2, p_data: Variant, p_idx: int) -> bool:
	return typeof(p_data) == TYPE_DICTIONARY and p_data.has("p3d_layer") and p_idx != 0


func _drop_row(_pos: Vector2, p_data: Variant, p_idx: int) -> void:
	var stack := _stack()
	if not stack:
		return
	var from: int = int(p_data["p3d_layer"])
	var to: int = p_idx
	if from == to or from == 0 or to == 0:
		return
	_move_layer_undoable(from, to)


## Reorder a layer as one undoable action so Ctrl+Z restores the previous order. move_layer is its own
## inverse: undoing move(from→to) is move(to→from), so a single _apply_move serves both directions.
## Routed to the terrain's scene-local history via the custom context.
func _move_layer_undoable(p_from: int, p_to: int) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null:
		_apply_move(p_from, p_to)
		return
	ur.create_action("Reorder Pasture3D Layer", UndoRedo.MERGE_DISABLE, terrain)
	ur.add_do_method(self, "_apply_move", p_from, p_to)
	ur.add_undo_method(self, "_apply_move", p_to, p_from)
	ur.commit_action()


## Apply a reorder and rebuild the list. One entry point for both do and undo, so call order is trivial.
func _apply_move(p_from: int, p_to: int) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	d.layer_move(p_from, p_to)
	stack.set_active_layer(p_to)
	refresh()
	_mark_unsaved()


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()
