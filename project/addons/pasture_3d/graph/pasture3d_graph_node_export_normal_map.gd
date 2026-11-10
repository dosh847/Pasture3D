# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportNormalMap — writes tangent-space normals derived from a height field. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# ---- THE NORMALS ARE DERIVED ----
#
# There is one input, `height`. The node used to declare a second, a `normal` VECTOR port that the writer
# refused by name when wired, so that the node's shape would not change when authored normals landed. Wires
# are stored by port id since format 2, so adding a port later moves nothing, and the placeholder went with
# the VECTOR type (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §7.3). The program cannot carry a vector
# grid; that is a compiler and buffer-layout change, not a node.
#
# A normal map derived from the exact height field you exported is consistent with that file by
# construction, which is the property that actually matters at the other end.
#
# ---- WHY THERE IS NO RANGE ----
#
# A normal is a direction, so its encoding is fixed: x,y,z in [-1,1] map to [0,255] by the universal
# `v * 0.5 + 0.5`. `range_mode` is therefore not read by the writer for this sink, and the sidecar records
# the metres-per-cell the gradient was measured over instead — which IS a calibration constant, and the
# one a consumer needs to know how steep "steep" was.
@tool
class_name Pasture3DGraphNodeExportNormalMap
extends Pasture3DGraphNodeExportSink

## Vertical exaggeration applied to the derived gradient before normalising. 1.0 is true-to-metres.
@export_range(0.05, 20.0, 0.05) var normal_strength: float = 1.0:
	set(v):
		normal_strength = maxf(0.001, v)
		emit_changed()


func _init() -> void:
	super()
	format = "png8"
	filename = "normal.png"


func op() -> StringName:
	return &"export_normal_map"


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT).require(),
	]


func formats() -> PackedStringArray:
	return PackedStringArray(["png8"])


func channels() -> int:
	return 4


func source_ports() -> PackedInt32Array:
	return PackedInt32Array([0])
