# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportNormalMap — writes tangent-space normals derived from a height field. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# ---- BOTH PORTS ARE DECLARED; ONLY THE DERIVED ONE WORKS ----
#
# Decided 2026-09-06 (§9.2): derive from `height` by default, and declare the optional `normal` VECTOR
# port NOW so the node's shape is final and no graph has to be rewired when authored normals land. The
# SSA program cannot carry a vector grid — giving it one is a compiler and buffer-layout change, not a
# node — so until that lands:
#
#   A WIRED `normal` PORT IS REFUSED BY NAME. It is never silently ignored.
#
# An optional input that quietly falls back to deriving is the zeros-impostor pattern (§4.4) wearing a
# different hat: the author wires a vector field, gets a plausible normal map derived from something else
# entirely, and has no way to tell it apart from the one they asked for. Refusing costs one warning.
#
# Deriving stays the recommended path regardless. A normal map derived from the exact height field you
# exported is consistent with that file by construction, which is the property that actually matters at
# the other end.
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


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "normal"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.VECTOR])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, -1])


func formats() -> PackedStringArray:
	return PackedStringArray(["png8"])


func channels() -> int:
	return 4


## Only the height port is tapped. The `normal` port is checked for a wire by the writer and refused
## there — a port this method omitted would be indistinguishable from one that is not declared.
func source_ports() -> PackedInt32Array:
	return PackedInt32Array([0])
