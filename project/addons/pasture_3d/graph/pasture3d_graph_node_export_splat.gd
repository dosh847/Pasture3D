# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportSplat — packs four masks into one RGBA weight map. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# Four ports rather than one four-channel port because there is no four-channel port: every wire in this
# graph carries a scalar field. Packing is the sink's job and is the reason the node exists — otherwise
# it would be four Export Mask nodes and a reassembly step at the far end.
#
# An UNWIRED channel writes ZERO, and that is the one place in the B2 set where zeros are the right answer
# rather than the §4.4 impostor: a splat channel means "how much of layer N is here", and no wire means
# none of it. The distinction is that this zero is DECLARED — `sink_warnings` names every unwired channel
# so the author sees which ones are empty before the file exists, rather than discovering it downstream.
@tool
class_name Pasture3DGraphNodeExportSplat
extends Pasture3DGraphNodeExportSink


func _init() -> void:
	super()
	format = "png8"
	filename = "splat.png"
	range_mode = RangeMode.EXPLICIT
	range_min = 0.0
	range_max = 1.0


func op() -> StringName:
	return &"export_splat"


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["r", "g", "b", "a"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.MASK, PortType.MASK, PortType.MASK])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, -1, -1, -1])


func formats() -> PackedStringArray:
	return PackedStringArray(["png8", "png16"])


func channels() -> int:
	return 4


func source_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2, 3])
