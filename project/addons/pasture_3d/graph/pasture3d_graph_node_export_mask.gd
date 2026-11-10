# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportMask — writes a single-channel mask. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# A MASK is normalised to [0,1] by construction (`pasture3d_graph_node.gd`'s PortType comment), so
# EXPLICIT 0..1 is the honest default here where AUTO is the honest default elsewhere: measuring a mask's
# own extremes would stretch a mask that happens to peak at 0.6 up to full white, and the file would then
# disagree with every other export of the same mask. §5.2's "MASK is absolute" rule (§12.4), applied to a
# file instead of to a thumbnail.
@tool
class_name Pasture3DGraphNodeExportMask
extends Pasture3DGraphNodeExportSink


func _init() -> void:
	super()
	range_mode = RangeMode.EXPLICIT
	range_min = 0.0
	range_max = 1.0


func op() -> StringName:
	return &"export_mask"


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"mask", PortType.MASK).require(),
	]


func formats() -> PackedStringArray:
	return PackedStringArray(["png8", "png16", "exr"])
