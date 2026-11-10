# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphInvertGate — the Invert node, on the native route and the script route.
#
# IA  The Add menu can create it, and a graph holding it stays native. An op missing from graph_op_ids()
#     drops the whole graph to script, so this is the wiring the alias exists for.
# IB  Native output == 2 * pivot - input, computed here and not through the node, for the default pivot and
#     a metres pivot, including values outside 0..1 (no clamp) and NaN cells (stay NaN). Control: moving the
#     pivot must move the output.
# IC  The node's eval_cell agrees with the native output for the same pivots.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphInvertGate.tscn
extends Node

const GW := 8
const GH := 8
const RECT := Rect2(-40.0, -40.0, 80.0, 80.0)
const EPS := 1.0e-4

var _fail := 0
var _field := PackedFloat32Array()


func _ready() -> void:
	print("=== GraphInvertGate ===\n")
	_field.resize(GW * GH)
	for i in _field.size():
		_field[i] = -3.0 + float(i) * 0.37 # spans below 0 and above 1
	_field[5] = NAN
	var low := _criteria(0.5, "pivot 0.5")
	var high := _criteria(120.25, "pivot 120.25")
	_check(absf(low[0] - high[0]) > 100.0, "control: moving the pivot moves the output")
	print("\n=== %s (%d failures) ===\n" % ["INVERT PASS" if _fail == 0 else "INVERT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _criteria(p_pivot: float, p_label: String) -> PackedFloat32Array:
	print("[%s]" % p_label)
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"invert")
	_check(node != null, "IA the registry creates the node")
	node.set("pivot", p_pivot)
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = [Pasture3DGraphNodeRegistry.create(&"input"), node, Pasture3DGraphNodeRegistry.create(&"output")]
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	_check(g.native_supported(), "IA the graph stays native: %s" % str(g.native_block_report()))
	var out := g.evaluate(GW, GH, RECT, null, _field)
	_check(out.size() == _field.size(), "IB output has one value per cell")
	var worst_native := 0.0
	var worst_cell := 0.0
	var nan_ok := true
	for i in mini(out.size(), _field.size()):
		if is_nan(_field[i]):
			nan_ok = nan_ok and is_nan(out[i])
			continue
		worst_native = maxf(worst_native, absf(out[i] - (2.0 * p_pivot - _field[i])))
		worst_cell = maxf(worst_cell, absf(out[i] - node.eval_cell(0.0, 0.0, PackedFloat32Array([_field[i]]))))
	_check(worst_native <= EPS, "IB native == 2 * pivot - input (worst %.7f)" % worst_native)
	_check(nan_ok, "IB NaN stays NaN")
	_check(worst_cell <= EPS, "IC eval_cell == native (worst %.7f)" % worst_cell)
	return out


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])
