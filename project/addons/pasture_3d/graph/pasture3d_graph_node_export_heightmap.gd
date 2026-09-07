# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportHeightmap — writes an elevation raster. §9.2.
#
# Read Pasture3DGraphNodeExportSink's header first.
#
# r16 and exr are the round-trip formats (`Pasture3DData::export_image`'s doc-comment says the same of the
# region-map exporter, for the same reason). png16 is offered because it is what most external terrain
# tools ingest; png8 is deliberately NOT offered here — eight bits across a mountain range is a terraced
# heightmap, and a format list is the cheapest place to refuse that.
@tool
class_name Pasture3DGraphNodeExportHeightmap
extends Pasture3DGraphNodeExportSink


func op() -> StringName:
	return &"export_heightmap"


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["height"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1])


func formats() -> PackedStringArray:
	return PackedStringArray(["r16", "exr", "png16"])
