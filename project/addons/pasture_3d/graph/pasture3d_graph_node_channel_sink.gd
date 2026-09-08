# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeChannelSink — the shared shape of the four B1 terrain-channel sinks (Control, Color,
# Hole, Nav). PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.1.
#
# ---- WHAT A SINK IS, AND WHAT IT IS NOT ----
#
# It is TERMINAL: `has_output()` is false, so nothing can wire from it, so it is never an ancestor of the
# graph's Output node or of a preview root, so `compile_graph_program_multi` never emits an op for it.
# That is the whole native story — no op id, no `blocks_native()`, no entry in `graph_op_ids()`. A graph
# is not made slower or less native by containing sinks, which matters because the bail is graph-wide and
# silent (standing constraint 1 / §10). The Output node is the same shape with a different consumer
# (`pasture3d_graph_node_output.gd:34`), and §9.2 argues at length why terminality beats a mute flag.
#
# It is NOT an exporter. §12.8: B1 writes through the bake and the layer stack, which already own write-
# area clipping, layer binding, undo and staleness. A parallel path would reimplement all four.
#
# ---- THE MASK IS A WRITE STENCIL, NOT AN OPACITY ----
#
# Control composites topmost-covered-wins — each covered overlay bottom→top FULLY replaces the value,
# because a packed uint32 is not float-blendable (PASTURE3D_LAYERS_GUIDE.md §5.1). So a graph mask can
# only mean "does this sink own this cell", and `MASK_EPSILON` is where that answer flips. Below it the
# sink authors nothing at all and the pre-existing control word is byte-identical — which is the property
# `road-batter-overwrites-other-roads` was the absence of.
#
# ---- WHY THE INDEX REFUSAL IS A REFUSAL ----
#
# Both index fields are 5 bits and all 32 values are legal texture ids, so there is no NONE sentinel and
# no room for one (§9.1). `-1` does not read as "skip"; it reads as texture 31, which is what
# `road-tier-far-paint-built` actually shipped. NONE is expressed as NOT WRITING — a zero in the mask —
# and a negative index is refused outright rather than clamped, because a clamp would paint texture 0 and
# look like a choice.
@tool
class_name Pasture3DGraphNodeChannelSink
extends Pasture3DGraphNode

## Pasture3DData.MapType, mirrored (the enum is not exposed to GDScript). Same values the road connector
## and the brush already mirror — `pasture3d_road_connector.gd:87`, `pasture3d_terrain_brush.gd:25`.
const MAPTYPE_CONTROL: int = 1
const MAPTYPE_COLOR: int = 2
const BLEND_REPLACE: int = 0

## Where "the mask is on" stops. Not a feather: see the header — coverage is binary because the composite
## is. Small rather than zero so a mask that decays smoothly to nothing does not author a fringe of cells
## at 1e-7 coverage, which would show up as a one-cell halo of fully-replaced control word.
const MASK_EPSILON: float = 0.001

## The highest legal texture index. 5 bits, and Terrain3D allows all 32 (§9.1).
const MAX_TEXTURE_INDEX: int = 31

## WHICH LAYER THIS SINK OWNS. Empty means "one of my own", which is the default and the historical
## behaviour: the writer keys the layer on this node's INDEX, so two Control Sinks in a graph get two
## layers and neither clears the other's paint.
##
## A non-empty key replaces the index in that owner id, which makes it a NAME two sinks can agree on. Two
## sinks sharing a key share one layer, and that is the point: control composites topmost-covered-wins,
## so the only way to have one sink lay rock and another lay grass over the top of it IN ONE LAYER is for
## both to author into it. They write in graph order, later over earlier.
##
## ---- WHY SHARING NEEDED THE CLEAR TO MOVE, NOT JUST THE OWNER ID ----
##
## Step 2 of every sink write clears the layer's footprint before authoring (PASTURE3D_LAYERS_GUIDE.md
## §8.1) — that clear is what makes a re-bake idempotent and stops a moved brush leaving stale paint
## behind forever. Two sinks on one layer each doing that would mean the second cleared away the first's
## work every single bake, and the layer would only ever show the last sink. So the clear is now once per
## LAYER per bake rather than once per sink, tracked by the writer. That is the whole mechanism; the
## owner id alone would have shipped a feature that silently discards everything but the last write.
##
## The key does NOT name a hand-made layer in the Layers dock. A sink's layer is `reserved` and is cleared
## and re-authored on every bake; pointing one at a layer somebody paints by hand would erase that paint
## on the next refresh with nothing said about why. Layer up instead — a hand layer above a sink layer
## composites over it, which is the arrangement `brush-layers-are-not-hand-paintable` describes.
@export var layer_key: String = "":
	set(v):
		layer_key = v.strip_edges()
		emit_changed()


## Terminal. See the header — this one override is the entire native story.
func has_output() -> bool:
	return false


func role() -> Role:
	return Role.FILTER


## Which map type this sink's reserved layer is. MAPTYPE_CONTROL or MAPTYPE_COLOR.
func sink_map_type() -> int:
	return MAPTYPE_CONTROL


## The suffix appended to the host brush's `owner_id` to key this sink's reserved layer. Sinks of
## different kinds must not collide on one layer: `create_owned_layer_typed` is idempotent PER OWNER ID,
## so two sinks sharing a suffix would share a layer, and the second's clear-first step would wipe the
## first's paint every bake. The node's own index is appended by the writer so two Control Sinks in one
## graph get two layers.
func sink_owner_suffix() -> String:
	return "#graph_control"


## Human-readable name for the created layer, shown in the Layers dock.
func sink_layer_label() -> String:
	return "Graph Control"


## Which input port carries the write stencil. Every sink has one; it is port 0 in all four.
func mask_port() -> int:
	return 0


## Compose the control word this sink wants at one cell, given what is already composited beneath it
## (`p_below`) and the resolved per-port values. Control sinks only; a colour sink overrides
## `color_at` instead. Returning -1 means "author nothing here", which is distinct from authoring 0.
func control_word(_p_below: int, _p_values: Dictionary, _p_cell: int) -> int:
	return -1


## The RGBA a colour sink authors at one cell. Colour sinks only.
func color_at(_p_values: Dictionary, _p_cell: int) -> Color:
	return Color.WHITE


## Reasons this sink cannot write, named. Empty means it will. Surfaced by the editor and asserted by
## GraphChannelSinkGate [C] — the refusal is the tested behaviour, not a side effect of a clamp.
func sink_warnings() -> PackedStringArray:
	return PackedStringArray()


## Shared index validation, so all four sinks refuse identically. Returns "" when p_index is legal.
static func index_refusal(p_label: String, p_index: int) -> String:
	if p_index < 0:
		return ("%s is %d. There is no NONE index — all 32 values are legal textures, so a negative one "
				+ "would be written as texture %d. Leave the mask at zero where you want no paint.") \
				% [p_label, p_index, p_index & MAX_TEXTURE_INDEX]
	if p_index > MAX_TEXTURE_INDEX:
		return "%s is %d; the field is 5 bits, so the highest legal index is %d." \
				% [p_label, p_index, MAX_TEXTURE_INDEX]
	return ""
