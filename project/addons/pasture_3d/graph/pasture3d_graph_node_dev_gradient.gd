# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevGradient — the Gradient with native blocked: the GDScript oracle GraphGradientGate
# measures gradient_grid and GKM_GRADIENT against (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §4.7).
@tool
class_name Pasture3DGraphNodeDevGradient
extends Pasture3DGraphNodeGradient


func op() -> StringName:
	return &"dev_gradient"


func blocks_native() -> bool:
	return true


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Gradient"
