# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSplineSource — an authored curve as a PATH in the graph.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §5. The scene end of the same wire is Pasture3DSpline.
#
# ---- THE THIRD SOURCE, AND WHAT MAKES IT DIFFERENT FROM THE OTHER TWO ----
#
# Road Source names a road: a solved alignment with a vertical profile, produced by a road brush.
# Shape Source names a shaping brush's OUTLINE: closed, Y dropped, widths dropped, because a Mound's
# outline is a by-product and all a consumer wants from it is where the region is.
# This names a Pasture3DSpline: a curve somebody drew ON PURPOSE for a graph to read, so it arrives with
# everything the author gave it — per-vertex half-widths and, optionally, the drawn elevation.
#
# All three lower identically, because by the time a path is in the geometry table there is no difference
# between them: a polyline is a polyline and `closed` rides on the entry. They differ only in what they
# name and who resolves them.
#
# ---- THE EMPTY KEY IS NOT A CONVENIENCE ----
#
# An empty key resolves to the HOST brush's own first Pasture3DSpline child. Road Source does the same
# thing; Shape Source deliberately does not, because a brush masking itself by its own outline is a step
# that can never change anything.
#
# Here it is load-bearing, and the Ridge/Trough presets (§9) do not work without it. A key is a SCENE
# PATH: a preset whose graph named "Ridge/Crest" would, when duplicated, produce a second Ridge whose
# graph still named the FIRST one's spline. Every copy would carve the original's line and the preset
# would be unusable as a preset, which is the only thing it is for. An empty key is relative to whoever
# is running the graph, so a duplicate resolves to its own child.
#
# A typed key still shares a spline deliberately — one line carved by two brushes, or an input spline
# reparented out of a preset and read from somewhere else. Both work. The default is the one that
# survives duplication.
@tool
class_name Pasture3DGraphNodeSplineSource
extends Pasture3DGraphNode

## The Pasture3DSpline this node stands for, by the key its terrain uses. EMPTY means "the host brush's
## own first Pasture3DSpline child" — see the header for why that default is what makes a preset work.
@export var spline_key: String = "":
	set(v):
		spline_key = v
		emit_changed()

## Which of the named node's child splines to take.
##
## Past the end resolves to an EMPTY path, not to the last one. Clamping would let a graph keep working
## while pointing at a line nobody chose, after a spline was deleted — the same rule Shape Source states
## at length, and for the same reason.
@export_range(0, 32) var spline_index: int = 0:
	set(v):
		spline_index = maxi(v, 0)
		emit_changed()

## The resolved geometry. Written by the host at bake (or at the moment the spline is edited — see
## Pasture3DTerrainBrush._refresh_consumers), or assigned directly. Null until then.
##
## Emits `changed` through this node when the path itself changes, which is what makes an edited spline
## invalidate the caches of everything downstream: the evaluator folds a source node's revision into its
## consumers' input hashes, so a path that changed silently would serve a stale distance field that looks
## exactly like a correct one.
@export var path: Pasture3DGraphPath:
	set(v):
		if path != null and path.changed.is_connected(emit_changed):
			path.changed.disconnect(emit_changed)
		path = v
		if path != null and not path.changed.is_connected(emit_changed):
			path.changed.connect(emit_changed)
		emit_changed()


## The spline keys the HOST last offered, for the inspector dropdown. Never saved and never read by the
## solve. Setting it NOTIFIES, because `_validate_property` only runs while Godot is building a property
## list, and a list stamped after that build is invisible — the bug that left Road Key a plain String box
## for a while, whose symptom is that the keys are collected correctly, the hint is written correctly, and
## the field still is not a dropdown.
var editor_spline_keys: PackedStringArray = PackedStringArray():
	set(v):
		if editor_spline_keys == v:
			return
		editor_spline_keys = v
		notify_property_list_changed()


## ENUM_SUGGESTION, not ENUM, for the reason Road Source spells out: a hard enum can only hold values that
## exist RIGHT NOW, so a graph opened with its scene absent would render the key it already holds as
## invalid and rewrite it to a different spline on the first click. It also has to stay typeable here for
## a second reason — the empty key is a meaningful value, and an enum cannot express "none of these".
func _validate_property(property: Dictionary) -> void:
	if property["name"] != &"spline_key" or editor_spline_keys.is_empty():
		return
	property["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
	property["hint_string"] = ",".join(editor_spline_keys)


func op() -> StringName:
	return &"spline_source"


## The geometry does not ride in these params: it goes in the program's geometry table and `in_g` names
## an entry, because a polyline is neither a float nor an index into the scratch arena (§4.1). A PATH
## producer still fills a grid slot, with zeros — the same 0.0 its `eval_cell` returns — so that nothing
## which indexes by node has to special-case it.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = 0.0
	return {"params": p}


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func output_port_type() -> int:
	return PortType.PATH


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


func path_output() -> Pasture3DGraphPath:
	return path


## A PATH producer still fills a grid slot, with zeros. See Pasture3DGraphNode.path_output.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if path == null or path.segment_count() == 0:
		if spline_key.is_empty():
			out.append("Spline Source has no key and no host spline: it produces nothing. Add a "
				+ "Pasture3DSpline under this brush, or pick one by key.")
		else:
			out.append("Spline Source \"%s\" has not been resolved yet; it produces an empty path."
					% spline_key)
		return out
	if path.closed:
		# Worth saying rather than leaving to be discovered: a CLOSED path through Path Mask fills its
		# interior instead of giving a corridor, and a carve reads it as a ring rather than a route. Both
		# are legitimate; neither is what "I drew a river" leads you to expect.
		out.append("Spline Source \"%s\" is CLOSED, so Path Mask fills its interior rather than giving "
				% spline_key + "a corridor along it.")
	if path.heights.is_empty():
		# The one that costs a consumer silently. Path Carve with Follow Path Height on has nothing to
		# follow, and Path Distance's height channel reads NaN everywhere.
		out.append("Spline Source \"%s\" carries no heights (Carry Heights is off on the spline), so "
				% spline_key + "anything grading TO this line has no elevation to grade to.")
	return out
