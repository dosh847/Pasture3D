# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCombine — any number of fields folded by one associative mode: add, max, min or
# multiply. PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §12 (P8).
#
# Its one input is a MULTI port (`Pasture3DGraphPort.accepts_many`): every wire into it is an operand, in
# the order the wires sit in the graph's `connections` (and so in the saved `wires`). Nothing below the
# compiler knows: the graph's flat view (§11.2, which P7 built for subgraphs) replaces this node with a
# left fold of two-input Blends, ((w0 op w1) op w2) …, so a Combine and the same chain built by hand compile
# to the same program. That is also why only these four modes exist: each is associative and commutative,
# so the order of the wires moves rounding (add, multiply) or nothing at all (max, min). Blend's SUB, DIV,
# POW and MIX depend on which operand is which and stay two-input.
#
# One wire is passed through; none reads 0.
@tool
class_name Pasture3DGraphNodeCombine
extends Pasture3DGraphNode

## The fold. Values are serialised, so the order is fixed: append, never insert.
enum Mode { ADD, MAX, MIN, MUL }

@export var mode: Mode = Mode.ADD:
	set(v):
		if mode == v:
			return
		mode = v
		_param_changed()


func op() -> StringName:
	return &"combine"


func role() -> Role:
	return Role.COMBINER


## Never reaches a compiler: the flat view lowers it to Blends, so it has no native op id on purpose.
## `GraphAllNodeSocketsGate` reads this as the declaration.
func flattens_away() -> bool:
	return true


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).accepts_many().require().labelled("in (any number)"),
	]


## The Blend mode each fold step uses.
func blend_mode() -> Pasture3DGraphNodeBlend.Mode:
	match mode:
		Mode.MAX: return Pasture3DGraphNodeBlend.Mode.MAX
		Mode.MIN: return Pasture3DGraphNodeBlend.Mode.MIN
		Mode.MUL: return Pasture3DGraphNodeBlend.Mode.MUL
	return Pasture3DGraphNodeBlend.Mode.ADD


## Only reached if something evaluates the node outside a graph: the flat view never hands it cells.
func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	if p_inputs.is_empty():
		return 0.0
	var acc: float = p_inputs[0]
	for i in range(1, p_inputs.size()):
		var b: float = p_inputs[i]
		match mode:
			Mode.ADD: acc += b
			Mode.MAX: acc = maxf(acc, b)
			Mode.MIN: acc = minf(acc, b)
			Mode.MUL: acc *= b
	return acc
