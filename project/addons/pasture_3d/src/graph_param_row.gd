# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphParamRow — the top of the Inspector for a Parameter node: pick one of the graph's declared
# parameters, or declare a new one, without leaving the node.
#
# A parameter is DECLARED on the graph (Pasture3DTerrainGraph.parameters: id, type, default) and a Parameter
# node outputs one by id (ports spec §10). Declaring meant expanding the graph resource inside the brush's
# modifier and adding to an array, and until something was declared the modifier had no Parameters section
# at all, so a new Parameter node gave no hint of where to go. This row is that path from the node itself.
#
# The edit is pure (`declared_list`), so a gate can check it without the editor; the row hands the result to
# a callback that applies it, which in the editor is an undoable action (Pasture3DGraphInspectorPlugin).

@tool
extends VBoxContainer

const TYPE_NAMES := ["Float", "Int", "Bool", "Path"]

var _graph: Pasture3DTerrainGraph
var _node: Pasture3DGraphNodeParam
## `func(graph, node, new_parameters: Array[Pasture3DGraphParam], new_id: StringName)`: applies an edit.
var _apply: Callable

var _pick: OptionButton
var _new_id: LineEdit
var _new_type: OptionButton
var _declare: Button
var _note: Label


func setup(p_graph: Pasture3DTerrainGraph, p_node: Pasture3DGraphNodeParam, p_apply: Callable) -> Control:
	_graph = p_graph
	_node = p_node
	_apply = p_apply
	_build()
	_refresh()
	if _graph != null and not _graph.parameters_changed.is_connected(_refresh):
		_graph.parameters_changed.connect(_refresh)
	return self


## The parameter list after declaring `p_id` of type `p_type` on `p_graph`: the same list with one new
## declaration appended, or the same list unchanged when `p_id` is already declared (the node is then just
## pointed at it). Empty `p_id` returns null: nothing to do.
static func declared_list(p_graph: Pasture3DTerrainGraph, p_id: StringName, p_type: int) -> Variant:
	if p_graph == null or String(p_id).strip_edges().is_empty():
		return null
	var out: Array[Pasture3DGraphParam] = p_graph.parameters.duplicate()
	if p_graph.find_param(p_id) != null:
		return out
	var d := Pasture3DGraphParam.new()
	d.id = p_id
	d.type = p_type
	out.append(d)
	return out


## A free id for a new declaration: `param`, `param_2`, ...
static func free_id(p_graph: Pasture3DTerrainGraph, p_base := "param") -> String:
	if p_graph == null or p_graph.find_param(StringName(p_base)) == null:
		return p_base
	var n := 2
	while p_graph.find_param(StringName("%s_%d" % [p_base, n])) != null:
		n += 1
	return "%s_%d" % [p_base, n]


func _build() -> void:
	var title := Label.new()
	title.text = "Graph parameter"
	add_child(title)

	var pick_row := HBoxContainer.new()
	var pl := Label.new()
	pl.text = "Reads"
	pl.custom_minimum_size.x = 60
	pick_row.add_child(pl)
	_pick = OptionButton.new()
	_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick.tooltip_text = "Which of the graph's declared parameters this node outputs. The value is set per brush, in the brush's graph modifier under Parameters."
	_pick.item_selected.connect(_on_picked)
	pick_row.add_child(_pick)
	add_child(pick_row)

	var new_row := HBoxContainer.new()
	var nl := Label.new()
	nl.text = "New"
	nl.custom_minimum_size.x = 60
	new_row.add_child(nl)
	_new_id = LineEdit.new()
	_new_id.placeholder_text = "id"
	_new_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_id.text_submitted.connect(func(_t): _on_declare())
	new_row.add_child(_new_id)
	_new_type = OptionButton.new()
	for i in TYPE_NAMES.size():
		_new_type.add_item(TYPE_NAMES[i], i)
	_new_type.tooltip_text = "Path: each brush reads a spline (its own Pasture3DSpline child by default)."
	new_row.add_child(_new_type)
	_declare = Button.new()
	_declare.text = "Declare"
	_declare.tooltip_text = "Declare this parameter on the graph and point this node at it. Every brush using the graph then shows it in its graph modifier's Parameters section."
	_declare.pressed.connect(_on_declare)
	new_row.add_child(_declare)
	add_child(new_row)

	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	add_child(_note)
	add_child(HSeparator.new())


func _refresh() -> void:
	if _pick == null or not is_instance_valid(_node):
		return
	_pick.clear()
	_pick.add_item("(none)")
	_pick.set_item_metadata(0, &"")
	var sel := 0
	var ids: Array[StringName] = []
	if _graph != null:
		ids = _graph.param_ids()
	for id in ids:
		var d := _graph.find_param(id)
		_pick.add_item("%s  (%s)" % [id, TYPE_NAMES[clampi(d.type, 0, TYPE_NAMES.size() - 1)]])
		_pick.set_item_metadata(_pick.item_count - 1, id)
		if id == _node.param_id:
			sel = _pick.item_count - 1
	if sel == 0 and _node.param_id != &"":
		_pick.add_item("%s  (not declared)" % _node.param_id)
		_pick.set_item_metadata(_pick.item_count - 1, _node.param_id)
		sel = _pick.item_count - 1
	_pick.select(sel)
	if _new_id.text.is_empty() and _graph != null:
		_new_id.text = free_id(_graph, String(_node.param_id) if _node.param_id != &"" and _graph.find_param(_node.param_id) == null else "param")
	_pick.disabled = _graph == null
	_declare.disabled = _graph == null
	if _graph == null:
		_note.text = "Open this node's graph in the Graph Editor to declare or pick parameters."
	elif ids.is_empty():
		_note.text = "The graph declares no parameters yet. Declare one here; it then appears under Parameters in every brush's graph modifier."
	else:
		_note.text = "Set the value per brush in the brush's graph modifier, under Parameters."


func _on_picked(p_i: int) -> void:
	var id: StringName = _pick.get_item_metadata(p_i)
	if id == _node.param_id:
		return
	_apply.call(_graph, _node, _graph.parameters.duplicate(), id)


func _on_declare() -> void:
	var id := StringName(_new_id.text.strip_edges())
	var list = declared_list(_graph, id, _new_type.get_selected_id())
	if list == null:
		return
	_new_id.text = ""
	_apply.call(_graph, _node, list, id)
	_refresh()
