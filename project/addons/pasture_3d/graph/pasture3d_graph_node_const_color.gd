# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstColor — a GENERATOR constant node that outputs a Color / tint value.
@tool
class_name Pasture3DGraphNodeConstColor
extends Pasture3DGraphNode

## The Color value.
@export var value: Color = Color.WHITE:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const_color"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var cc: Color = value if value is Color else Color.WHITE
	p[0] = cc.get_luminance()
	return {"params": p}


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR])


## The COLOUR sideband's answer. Declared rather than left to be duck-typed off `value`, because that
## is exactly what used to go wrong: the Color Sink asked `"color" in node`, this node's export is named
## `value`, and so the one legal source of a COLOR port was refused as carrying no colour.
func graph_color(_p_upstream: Dictionary = {}) -> Color:
	return value if value is Color else Color.WHITE


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return value.get_luminance()
