# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevValueRamp — the Value Ramp with native blocked: eval_cell through Gradient.sample, the
# oracle GraphValueRampGate measures value_ramp_grid and GKM_VALUE_RAMP against (spec §6.4).
@tool
class_name Pasture3DGraphNodeDevValueRamp
extends Pasture3DGraphNodeValueRamp


func op() -> StringName:
	return &"dev_value_ramp"


func blocks_native() -> bool:
	return true


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Value Ramp"
