# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportIndexMap — writes material or region indices. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# ---- AN INDEX IS NOT A QUANTITY, SO IT IS NEVER SCALED ----
#
# Every other sink maps a float field onto [0,1] through a divisor. This one must not: index 7 has to come
# back as index 7, and a divisor that mapped a 0..31 field onto a byte would return 57 for it. So
# `is_index_map()` is true and the writer stores `round(value)` verbatim, one index per sample, with the
# sidecar recording a range of 0..255 (png8) purely so a consumer reading the sidecar mechanically is not
# told a divisor that does not apply.
#
# For the same reason the file must never be filtered, resampled or mipmapped at the far end — nearest
# only. An interpolated index map produces materials that exist nowhere in the graph, at every boundary
# between two that do. The sidecar says so in words, because a JSON field nobody reads would not.
#
# `png8` covers the 32 texture indices the control word actually has room for (5 bits — see
# `Pasture3DGraphNodeControlSink`), with 224 spare. `exr` is offered for region ids and anything else that
# outgrows a byte.
@tool
class_name Pasture3DGraphNodeExportIndexMap
extends Pasture3DGraphNodeExportSink


func _init() -> void:
	super()
	format = "png8"
	filename = "index.png"


func op() -> StringName:
	return &"export_index_map"


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["index"])


func input_port_types() -> PackedInt32Array:
	# INT, as §9.2's table declares. The port is read as a per-cell FIELD here, unlike the Control Sink's
	# `base`/`overlay` INT ports which are read from cell 0: a texture index is one value for a whole
	# sink, an index MAP is one per cell. The tap returns the source slot's entire grid either way, so
	# the difference is in what the consumer does with it, not in what the wire carries.
	return PackedInt32Array([PortType.INT])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1])


func formats() -> PackedStringArray:
	return PackedStringArray(["png8", "exr"])


func is_index_map() -> bool:
	return true
