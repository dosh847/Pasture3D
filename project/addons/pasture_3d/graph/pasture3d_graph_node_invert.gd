# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeInvert — a FILTER cell node: reflects a field about a pivot, output = 2 * pivot - input.
# The default pivot of 0.5 is the mask inversion, 1 - input. A pivot in metres flips terrain about that
# height, so peaks become pits and the pivot height itself stays put. Nothing is clamped.
#
# There is no kernel of its own. "invert" is an alias of GRAPH_OP_REMAP in graph_op_ids(), lowered as an
# unclamped inverted remap over a unit window centred on the pivot. The window edges are float32 in the
# native program, so the script route reflects about those same rounded edges.
@tool
class_name Pasture3DGraphNodeInvert
extends Pasture3DGraphNode

## The value that maps to itself. 0.5 gives 1 - input for a 0..1 mask; for a height, use the height in
## metres to flip the terrain about.
@export var pivot: float = 0.5:
	set(v):
		pivot = v
		emit_changed()


func op() -> StringName:
	return &"invert"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = pivot - 0.5 # in_min
	p[1] = pivot + 0.5 # in_max
	p[2] = p[0] # out_min
	p[3] = p[1] # out_max
	p[4] = 0.0 # clamp_output
	p[5] = 0.0 # soft_knee
	p[6] = 1.0 # invert
	return {"params": p}


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var p: PackedFloat32Array = native_lower()["params"]
	var x: float = p_inputs[0] if p_inputs.size() > 0 else 0.0
	return p[0] + p[1] - x # NaN (outside a footprint) stays NaN
