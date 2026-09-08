# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeColorSink — tints the terrain's COLOR map wherever its mask is on. §9.1.
#
# Read Pasture3DGraphNodeChannelSink's header first.
#
# ---- WHY THE COLOUR PORT IS RESOLVED DIFFERENTLY FROM EVERY OTHER PORT ----
#
# Every other sink port is resolved by TAPPING the slot its source node compiled into — which is how the
# native evaluator reads a driven param, so the sink and the kernel cannot disagree about what a wire
# means. A COLOR port cannot work that way: the SSA program's buffers are scalar, so there is no slot that
# could carry RGBA. The writer therefore reads the wired node's own `color` property, and a source that
# has none is REFUSED by name rather than falling back to this node's colour.
#
# That refusal is the same call §9.2 makes about `Export Normal Map`'s vector port, for the same reason:
# an optional input that quietly falls back is the zeros-impostor pattern of §4.4 wearing a hat. The
# author wires a gradient, gets a flat tint that looks deliberate, and has no way to tell.
#
# ---- ALPHA IS COVERAGE, NOT ROUGHNESS ----
#
# A colour OVERLAY's A channel is its coverage weight; roughness lives in the colour Base and
# `_composite_color_region` leaves it untouched (`pasture_3d_data.cpp:1606`). So this sink authors RGB
# and never roughness — the same boundary the §9.1a stroke routing draws around the ROUGHNESS tool.
@tool
class_name Pasture3DGraphNodeColorSink
extends Pasture3DGraphNodeChannelSink

## The tint written where the mask is on and the `color` port is unwired.
@export var color: Color = Color.WHITE:
	set(v):
		color = v
		emit_changed()


func op() -> StringName:
	return &"color_sink"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["mask", "color"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.COLOR])


func native_param_ports() -> PackedInt32Array:
	# COLOR is a value type, so it names a slot rather than -1 — even though nothing lowers this node and
	# no scalar slot could hold an RGBA. The declaration is read as "this port is not a grid", which is
	# the fact the editor and GraphPortTypeGate care about; see the header for how it is actually read.
	return PackedInt32Array([-1, 0])


func sink_map_type() -> int:
	return MAPTYPE_COLOR


func sink_owner_suffix() -> String:
	return "#graph_color"


func sink_layer_label() -> String:
	return "Graph Color"


## The tint for one cell.
##
## The `color` value is a single Color from a Const Color or a Color Mix, or a PackedColorArray from a
## Color Blend, whose mask chooses between two colours per cell. This method has taken a cell index
## since it was written and ignored it; the per-cell case is what it was for.
func color_at(p_values: Dictionary, p_cell: int) -> Color:
	var c = p_values.get("color", null)
	if c is PackedColorArray:
		# A short array is a resolver that produced fewer cells than the bake grid, which is a bug
		# rather than an author's choice — so fall back to the declared tint instead of wrapping the
		# index round and painting a plausible, wrong pattern.
		return c[p_cell] if p_cell >= 0 and p_cell < c.size() else color
	return c if c is Color else color
