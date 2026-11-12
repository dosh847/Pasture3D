# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeColorInput — "the colour already on the terrain", as a COLOR source.
#
# ---- WHY IT EXISTS ----
#
# A Color Sink writes a colour wherever its mask is on, and its mask defaults to the whole footprint. So a
# graph that layers several colours through several Color Blends -- sand where `beach`, rock where `cliff`
# -- had a base colour on its first Blend's A port, and that base was painted over every cell no mask
# claimed. The only way to leave those cells alone was to union every mask by hand and wire the result to
# the sink's mask as well: the same masks, said twice.
#
# Wire this into the first Blend's A instead. Where no mask claims a cell, the chain carries this colour
# through to the sink, and the sink writes nothing there: the terrain's existing colour shows.
#
# ---- WHAT IT IS: TRANSPARENT, NOT A READ ----
#
# It outputs `Color(0, 0, 0, 0)`, and the sink reads a graph colour's ALPHA as coverage (premultiplied: a
# Blend lerps RGB and A together, so blending a colour in at mask m over this gives `(m * rgb, m)`, which
# is exactly "rgb at coverage m" -- see `Pasture3DGraphChannelSinks` and `set_colors_on_layer_grid`).
#
# It does NOT read the colour beneath back into the graph. That would have to read the layers BELOW the
# sink's own (the composite includes the sink's last paint, so reading it feeds back), and whatever it
# read would be baked into the sink's layer: change a lower layer and the sink keeps the old copy. A
# transparent cell carries nothing, so the layers beneath stay live.
#
# The cost of that choice: an operation that needs the existing RGB has nothing to work on. A Multiply,
# Add, Screen or Overlay Blend keeps A's alpha, so over this it stays transparent and paints nothing.
# Tinting the existing colour needs a real read and is not this node.
@tool
class_name Pasture3DGraphNodeColorInput
extends Pasture3DGraphNode

## The colour this node stands for: none. Coverage 0, so the sink authors nothing where it arrives.
const TRANSPARENT := Color(0.0, 0.0, 0.0, 0.0)


func op() -> StringName:
	return &"color_input"


func role() -> Role:
	return Role.GENERATOR


func _inputs() -> Array[Pasture3DGraphPort]:
	return []


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.value(&"out", PortType.COLOR),
	]


## The COLOUR sideband's answer (Pasture3DGraphChannelSinks._color_of).
func graph_color(_p_upstream: Dictionary = {}) -> Color:
	return TRANSPARENT
