# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConst — a GENERATOR cell node that outputs one fixed value everywhere. Small on
# purpose: it is the offset/bias a Blend needs, and it gives gates a known field to assert against.
#
# ---- WHY THE OUTPUT IS TYPED FLOAT AND NOT HEIGHT ----
#
# It fills every cell, so it is a legal flat field and it drives a HEIGHT port exactly as it always has.
# But it is ALSO the only way to drive a scalar VALUE port by wire, and until this type changed there was
# no such way: measured across the registry, FLOAT was consumed by 107 input ports and produced by ZERO
# nodes, so every one of those ports could only ever be set inline. The palette has called this node
# "Const Float" the whole time; it emitted HEIGHT, because it never overrode `output_port_types()` and the
# base default is HEIGHT.
#
# The cross-type wires that make both readings work are registered in
# `Pasture3DGraphEditor.register_connection_types`. The scalar reading is not an invention of this node:
# a driven scalar port has always been read as CELL 0 of the source buffer, by the native evaluator
# (`native_param_ports`) and by every GDScript `eval_grid` alike (`p_inputs[n][0]`). A uniform grid makes
# those two readings the same number, which is why a constant is the honest source for such a port.
@tool
class_name Pasture3DGraphNodeConst
extends Pasture3DGraphNode

## The value written to every cell, in metres.
@export var value: float = 0.0:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const"


## FLOAT, not HEIGHT. See the header — this is what makes the registry's 107 scalar ports reachable.
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.FLOAT])


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = value
	return {"params": p}


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return value
