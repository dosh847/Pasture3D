# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphParamRowGate — declaring a graph parameter from the Parameter node (Pasture3DGraphParamRow).
#
#   RA  `declared_list` appends one declaration of the chosen id and type and leaves the graph untouched.
#       Control: an id already declared appends nothing; an empty id is refused (null).
#   RB  the row: with no declarations it lists only "(none)" and says so; Declare hands the callback the new
#       list and id, and after applying, the node outputs a PATH and the brush modifier gains its Parameters
#       group. Control: the modifier has no Parameters group before.
#   RC  the graph editor's `apply_param_edit` is ONE undoable action: undo removes the declaration and puts
#       the node's old id back, redo restores both.
#       Control: picking an already declared id leaves the declarations alone.
#   RD  a row with no graph (the node's graph is not the one open) is disabled and says why.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphParamRowGate.tscn
extends Node

const Row = preload("res://addons/pasture_3d/src/graph_param_row.gd")
const CRITERIA: Array[String] = ["RA", "RB", "RC", "RD"]

var _fail := 0
var _reported := {}


func _ready() -> void:
	print("=== GraphParamRowGate: declare a parameter from the Parameter node ===\n")
	_ra()
	_rb()
	_rc()
	_rd()
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported, so nothing was measured" % name)
	print("\n=== %s (%d failures) ===\n" % ["PARAM ROW PASS" if _fail == 0 else "PARAM ROW FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _ra() -> void:
	var g := Pasture3DTerrainGraph.create_empty()
	var l1 = Row.declared_list(g, &"spine", Pasture3DGraphParam.Type.PATH)
	var ok1: bool = l1 is Array and l1.size() == 1 and l1[0].id == &"spine" and l1[0].type == Pasture3DGraphParam.Type.PATH \
			and g.parameters.is_empty()
	g.parameters = l1
	var l2 = Row.declared_list(g, &"spine", Pasture3DGraphParam.Type.FLOAT)
	var dup_none: bool = l2 is Array and l2.size() == 1
	var empty_null: bool = Row.declared_list(g, &"  ", 0) == null
	var fid := Row.free_id(g, "spine")
	_check("RA", ok1 and dup_none and empty_null and fid == "spine_2",
			"one PATH declaration appended, graph untouched=%s | existing id adds nothing (control)=%s | empty id refused=%s | free id %s"
			% [ok1, dup_none, empty_null, fid])


func _rb() -> void:
	var g := _graph()
	var pn: Pasture3DGraphNodeParam = g.nodes[0]
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	var group_before := _has_group(mod)
	var calls: Array = []
	var apply := func(p_g, p_n, p_list, p_id):
		calls.append([p_list.size(), p_id])
		p_g.parameters = p_list
		p_n.param_id = p_id
	var row = Row.new().setup(g, pn, apply)
	add_child(row)
	var only_none: bool = row._pick.item_count == 1 and row._note.text.contains("no parameters")
	row._new_id.text = "spine"
	row._new_type.select(Pasture3DGraphParam.Type.PATH)
	row._on_declare()
	g.set_host_params({})
	var port_path := pn.output_port_types().size() == 1 and int(pn.output_port_types()[0]) == Pasture3DGraphNode.PortType.PATH
	var group_after := _has_group(mod)
	var listed: bool = row._pick.item_count == 2 and row._pick.selected == 1
	remove_child(row)
	row.free()
	_check("RB", only_none and calls == [[1, &"spine"]] and port_path and group_after and not group_before and listed,
			"empty list says so=%s | declare called %s | node outputs PATH=%s | modifier Parameters group %s -> %s (control: none before) | listed and selected=%s"
			% [only_none, calls, port_path, group_before, group_after, listed])


func _rc() -> void:
	var ed := Pasture3DGraphEditor.new()
	var g := _graph()
	var pn: Pasture3DGraphNodeParam = g.nodes[0]
	pn.param_id = &"old"
	var list = Row.declared_list(g, &"spine", Pasture3DGraphParam.Type.PATH)
	ed.apply_param_edit(g, pn, list, &"spine")
	var done: bool = g.param_ids() == [&"spine"] and pn.param_id == &"spine"
	var ur: UndoRedo = ed._local_undo_redo
	ur.undo()
	var undone: bool = g.param_ids().is_empty() and pn.param_id == &"old"
	ur.redo()
	var redone: bool = g.param_ids() == [&"spine"] and pn.param_id == &"spine"
	# Control: a pick of a declared id is not a declaration.
	var before_n := g.parameters.size()
	ed.apply_param_edit(g, pn, g.parameters.duplicate(), &"")
	var pick_only: bool = g.parameters.size() == before_n and pn.param_id == &""
	ur.undo()
	var pick_undone: bool = pn.param_id == &"spine" and g.param_ids() == [&"spine"]
	ed.free()
	_check("RC", done and undone and redone and pick_only and pick_undone,
			"applied=%s undo=%s redo=%s | pick keeps declarations (control)=%s, undone=%s" % [done, undone, redone, pick_only, pick_undone])


func _rd() -> void:
	var g := _graph()
	var row = Row.new().setup(null, g.nodes[0], Callable())
	add_child(row)
	var ok: bool = row._declare.disabled and row._pick.disabled and row._note.text.contains("Graph Editor")
	remove_child(row)
	row.free()
	_check("RD", ok, "no graph: disabled and explained=%s" % ok)


func _graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = [Pasture3DGraphNodeParam.new(), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	g.set_host_params({})
	return g


func _has_group(p_mod: Pasture3DNodeGraph) -> bool:
	for p in p_mod._get_property_list():
		if p["name"] == "Parameters" and int(p["usage"]) & PROPERTY_USAGE_GROUP:
			return true
	return false
