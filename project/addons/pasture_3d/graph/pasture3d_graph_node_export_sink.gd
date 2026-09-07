# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExportSink — the shared shape of the five B2 file sinks (Heightmap, Mask, Normal Map,
# Splat, Index Map). PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.2.
#
# ---- TERMINAL, AND THAT IS THE WHOLE MECHANISM ----
#
# `has_output()` is false, so nothing can wire FROM a sink, so it is never an ancestor of the graph's
# Output node or of a preview root, so `compile_graph_program_multi` never emits an op for it. The file
# write lives in `Pasture3DGraphExportSinks.export_graph_outputs()`, an entry point the evaluator has no
# path to. Consequences (§9.2): no `auto_export` flag, because there is nothing to suppress; no op id and
# no `graph_op_ids()` entry, so adding a sink cannot cost the graph its native route — which matters
# because that bail is graph-wide and silent (§10); and the compiled program is byte-identical with the
# sink present, which is what criterion [A] asserts.
#
# It is deliberately NOT modelled on mute (§12.7). A muted node is not rewired out — it lowers to op 12,
# `output`, a passthrough. Mute costs an op. Terminality costs nothing, because there is nothing
# downstream to pass through TO.
#
# This is the same shape as the B1 channel sinks (`pasture3d_graph_node_channel_sink.gd`) with a different
# consumer: B1 writes through the bake into a layer, B2 writes a file. They do not share a base class
# because they share no member beyond terminality — the channel sinks carry a map type and a layer owner,
# these carry a filename and a format, and folding both into one base would produce a class where half
# the methods are meaningless for half the subclasses.
#
# ---- WHY THE RANGE IS RECORDED AND NOT PRINTED ----
#
# png8 and png16 are integer formats, so a float field only reaches them through a divisor, and the file
# is meaningless without it (`calibration-constants-must-be-stored-not-printed` — "printing it is not an
# interface"). Every export therefore writes a SIDECAR next to the image naming the range actually used.
# `range_mode` AUTO measures the tapped field and records what it measured; EXPLICIT uses the numbers on
# this node and records those. Either way the recorded numbers are the ones the writer used, not the ones
# the inspector shows — the sidecar is a readout of the export, never a restatement of a property
# (`PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §9's rule, and the reason 37 of 41 range pairs had drifted).
@tool
class_name Pasture3DGraphNodeExportSink
extends Pasture3DGraphNode

## How the [0,1] mapping for a quantised format is chosen. Ignored by exr and r16, which carry the field
## in its own units — but the sidecar is written for those too, so a consumer never has to know which.
enum RangeMode {
	AUTO,     ## Measure the tapped field's min/max and record what was measured.
	EXPLICIT, ## Use `range_min`/`range_max`, so successive exports of a changing field stay comparable.
}

## Relative to the base path `Export All` is given, or to `res://` for a single export. Relative on
## purpose: §9.2's "batch is a parameter of the action, not a mutation of the graph" — the base path
## belongs to the export, the leaf name belongs to the node, and they are joined at export time so a
## batch run rewrites nothing.
@export var filename: String = "export.png":
	set(v):
		filename = v
		emit_changed()

## One of `formats()`. Not an enum: the legal set differs per sink (§9.2's table), and an enum whose
## meaning changed per subclass would be a second source for that table.
@export var format: String = "png16":
	set(v):
		format = v
		emit_changed()

@export var range_mode: RangeMode = RangeMode.AUTO:
	set(v):
		range_mode = v
		emit_changed()

@export var range_min: float = 0.0:
	set(v):
		range_min = v
		emit_changed()

@export var range_max: float = 1.0:
	set(v):
		range_max = v
		emit_changed()

## Grid size of the tap, in cells, square. The export's own resolution — unrelated to the thumbnail's
## and unrelated to the terrain's, because an export is not a preview and not a bake.
@export_range(16, 4096, 1) var resolution: int = 256:
	set(v):
		resolution = maxi(16, v)
		emit_changed()

## The world rect the tap is evaluated over. §9.2: "the world rect + resolution the tap is evaluated at"
## is carried by the node, so a sink is self-contained and `Export All` needs to know nothing about what
## any individual sink covers.
@export var world_rect: Rect2 = Rect2(0.0, 0.0, 256.0, 256.0):
	set(v):
		world_rect = v
		emit_changed()


## Terminal. See the header — this one override is the entire native story.
func has_output() -> bool:
	return false


func role() -> Role:
	return Role.FILTER


## Extensions this sink can write, most-recommended first. Read by `sink_warnings` and by the editor.
func formats() -> PackedStringArray:
	return PackedStringArray(["png16", "png8", "exr"])


## How many channels the image carries. 1 for every sink but Splat (4) and Normal Map (4, RGB used).
func channels() -> int:
	return 1


## Which input port carries the field this sink writes. Splat overrides `source_ports` instead.
func source_ports() -> PackedInt32Array:
	return PackedInt32Array([0])


## True when this sink's samples must be written without interpolation or rescaling — Index Map. A
## quantised index that got a divisor would come back as a different material.
func is_index_map() -> bool:
	return false


## Reasons this sink cannot write, named. Empty means it will. The refusal is the tested behaviour.
func sink_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if filename.strip_edges().is_empty():
		out.append("the filename is empty, so there is nothing to write")
	if not formats().has(format):
		out.append("format '%s' is not one this sink writes (%s)"
				% [format, ", ".join(formats())])
	if range_mode == RangeMode.EXPLICIT and range_max <= range_min:
		out.append(("the explicit range is %s..%s, which is empty — every sample would quantise to the "
				+ "same value") % [range_min, range_max])
	return out
