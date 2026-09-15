# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevColorRamp — the Color Ramp mapped through Gradient.sample per cell, the oracle
# GraphColorRampGate measures Pasture3DUtil.color_ramp_cells against (spec §7.2).
@tool
class_name Pasture3DGraphNodeDevColorRamp
extends Pasture3DGraphNodeColorRamp


func op() -> StringName:
	return &"dev_color_ramp"


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Color Ramp"


func graph_color_cells(_p_upstream: Dictionary, p_field: PackedFloat32Array, p_n: int) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(p_n)
	for i in p_n:
		out[i] = _strength(color_at_value(p_field[i] if i < p_field.size() else NAN))
	return out
