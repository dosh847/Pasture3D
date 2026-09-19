# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevColorBlend — the Color Blend folded per cell in GDScript, the oracle
# GraphColorBlendGate measures Pasture3DUtil.color_blend_cells against.
@tool
class_name Pasture3DGraphNodeDevColorBlend
extends Pasture3DGraphNodeColorBlend


func op() -> StringName:
	return &"dev_color_blend"


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Color Blend"


func graph_color_cells(p_upstream: Dictionary, p_mask: PackedFloat32Array, p_n: int) -> PackedColorArray:
	return _color_cells_gd(p_upstream, p_mask, p_n)
