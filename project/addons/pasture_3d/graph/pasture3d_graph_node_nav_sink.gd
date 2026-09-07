# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeNavSink — marks terrain navigable (or not) wherever its mask is on. §9.1: "the nav bit
# is already there and we do not write it. A slope-and-water mask from the graph is precisely what wants
# to write it."
#
# Read Pasture3DGraphNodeChannelSink's header first. Structurally identical to the Hole Sink with bit 1
# instead of bit 2 — which is why §9.1 says it is four lines once Control Sink exists.
@tool
class_name Pasture3DGraphNodeNavSink
extends Pasture3DGraphNodeChannelSink

## Whether the masked cells become navigable (true) or explicitly non-navigable (false). As with the Hole
## Sink, false is not an eraser: it authors "not navigable" over the covered cells and nothing outside.
@export var navigable: bool = true:
	set(v):
		navigable = v
		emit_changed()


func op() -> StringName:
	return &"nav_sink"


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
	return "#graph_nav"


func sink_layer_label() -> String:
	return "Graph Navigation"


func control_word(p_below: int, _p_values: Dictionary, _p_cell: int) -> int:
	return (p_below & ~(0x1 << 1)) | Pasture3DUtil.enc_nav(navigable)
