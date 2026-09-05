# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstVector — a GENERATOR constant node that outputs a 2D or 3D direction / vector.
@tool
class_name Pasture3DGraphNodeConstVector
extends Pasture3DGraphNode

## The Vector2 value (e.g. angle, offset, directional bias).
@export var value: Vector2 = Vector2.ZERO:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const_vector"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var cv: Vector2 = value if value is Vector2 else Vector2.ZERO
	p[0] = cv.length()
	return {"params": p}


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.VECTOR


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.VECTOR])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return value.length()
