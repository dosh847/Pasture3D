# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevFloatToMask — Float to Mask in GDScript, the oracle GraphFloatToMaskGate measures
# Pasture3DUtil.float_to_mask_grid (native op 66) against.
@tool
class_name Pasture3DGraphNodeDevFloatToMask
extends Pasture3DGraphNodeFloatToMask


func op() -> StringName:
	return &"dev_float_to_mask"


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Float to Mask"


func native_lower() -> Dictionary:
	return {}


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
	return _eval_gd(h, p_gw, p_gh)
