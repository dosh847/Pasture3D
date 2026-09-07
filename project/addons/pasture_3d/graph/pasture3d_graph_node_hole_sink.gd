# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHoleSink — punches terrain holes wherever its mask is on. §9.1.
#
# Read Pasture3DGraphNodeChannelSink's header first. The one thing specific to this node: the hole bit is
# bit 2 of the control word, so this sink authors the word already on the ground with that ONE bit
# flipped — exactly what `Pasture3DData::set_hole_on_layer` does (`pasture_3d_data.cpp:2063`), and for the
# reason its comment gives: authoring a bare `enc_hole(true)` would win the topmost-covered-wins composite
# and take the texture, rotation and nav bits with it.
#
# `pasture3d_road_connector.gd`'s `#holes` layer is the working precedent for this exact shape.
@tool
class_name Pasture3DGraphNodeHoleSink
extends Pasture3DGraphNodeChannelSink

## ADD punches holes inside the mask; SUBTRACT fills them back in. Both write only inside the mask —
## SUBTRACT is not an eraser for the whole layer, it authors "no hole here" over the covered cells.
@export var carve: bool = true:
	set(v):
		carve = v
		emit_changed()


func op() -> StringName:
	return &"hole_sink"


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1])


func sink_map_type() -> int:
	return MAPTYPE_CONTROL


func sink_owner_suffix() -> String:
	return "#graph_holes"


func sink_layer_label() -> String:
	return "Graph Holes"


func control_word(p_below: int, _p_values: Dictionary, _p_cell: int) -> int:
	return (p_below & ~(0x1 << 2)) | Pasture3DUtil.enc_hole(carve)
