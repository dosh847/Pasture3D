# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeParam — a value source that outputs one of its graph's DECLARED parameters, chosen by id
# (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §10). It connects exactly as a Const does: to any value port,
# and to a field port as a flat field.
#
# ---- WHERE THE VALUE COMES FROM ----
#
# Not from this node. The graph declares the parameter (type, default) and the HOST supplies the value, so a
# node cannot answer on its own. The graph BINDS it instead: `Pasture3DTerrainGraph._apply_params` writes the
# declared type and the resolved number here whenever the declarations change, a node's id changes, or a
# host stamps its values (`set_host_params`). The node then lowers and evaluates as a constant holding that
# number, which is the whole of "substituted at compile".
#
# ---- WHY A BIND DOES NOT EMIT `changed` ----
#
# One graph is shared by several hosts with different values, and each stamps its own before it compiles.
# `changed` is the bake signal: emitting it on a stamp would make host A's bake re-bake host B, whose stamp
# would re-bake host A. The value therefore moves silently, and everything keyed on this node reads the
# VALUE rather than a revision: `_compute_node_inputs_hash` folds `resolved_value()` in, and the host's key
# folds in `Pasture3DTerrainGraph.params_sig()`.
#
# ---- A PATH PARAMETER ----
#
# Declared PATH, this node outputs a PATH rather than a number: the Pasture3DGraphPath the host resolved from
# its spline (Pasture3DGraphParam's header has the rule). It is bound exactly as the number is — silently —
# and lowers exactly as Spline Source does: a zero grid slot, with the path itself going into the program's
# geometry table through `path_output`. The path's `content_digest` stands in for the number in every key.
#
# A TYPE change is different. It changes the port this node declares, and the derived port tables are rebuilt
# when `_dirty_revision` moves, so a bind that changes the type moves it (still without a signal: the graph
# that is binding is already emitting its own for the declaration edit that caused it).
@tool
class_name Pasture3DGraphNodeParam
extends Pasture3DGraphNode

## Which declared parameter this outputs. An id the graph does not declare reads 0 and is reported.
@export var param_id: StringName = &"":
	set(v):
		param_id = v
		emit_changed()

# The binding. Runtime only: written by the graph, never saved.
var _type: int = PortType.FLOAT
var _value: float = 0.0
var _declared: bool = false
var _path: Pasture3DGraphPath = null


## Written by the graph. See the header for why this emits nothing. `p_path` is read only when the type is
## PATH, and is null for a host that resolved no spline.
func bind(p_port_type: int, p_value: float, p_declared: bool, p_path: Pasture3DGraphPath = null) -> void:
	if p_port_type != _type:
		_type = p_port_type
		_dirty_revision += 1
	_value = p_value
	_declared = p_declared
	_path = p_path if p_port_type == PortType.PATH else null


## True on a copy made for a SUBGRAPH instance (§11.2): its value is that instance's, fixed when the instance
## was expanded, and the flattened graph's own `_apply_params` must not rebind it from the parent's
## declarations, which may happen to use the same id for something else.
var _pinned := false


## Fix this node to one value for good. Written by flattening; see `_pinned`.
func pin(p_port_type: int, p_value: float, p_path: Pasture3DGraphPath = null) -> void:
	bind(p_port_type, p_value, true, p_path)
	_pinned = true


func is_pinned() -> bool:
	return _pinned


## The number this node outputs for the host whose values were stamped last.
func resolved_value() -> float:
	return _value


func is_declared() -> bool:
	return _declared


## The path this node outputs for the host stamped last, or null (not PATH, or that host has no spline).
func resolved_path() -> Pasture3DGraphPath:
	return _path


## What stands for this node's value in a cache key: the number, or for PATH the path's content. A number
## parameter keys exactly as it did before PATH existed, so no saved key moves.
func value_signature() -> Variant:
	if _type == PortType.PATH:
		return _path.content_digest() if _path != null else 0
	return _value


func path_output() -> Pasture3DGraphPath:
	return _path


func op() -> StringName:
	return &"param"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = _value
	return {"params": p}


func role() -> Role:
	return Role.GENERATOR


func _inputs() -> Array[Pasture3DGraphPort]:
	return []


func _outputs() -> Array[Pasture3DGraphPort]:
	# A PATH is a field port, as Spline Source's is: a path is not a value a scalar socket can hold.
	if _type == PortType.PATH:
		return [Pasture3DGraphPort.field(&"out", PortType.PATH)]
	return [
		Pasture3DGraphPort.value(&"out", _type),
	]


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return _value


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if param_id == &"":
		w.append("%s: no parameter chosen, so it reads 0." % display_name())
	elif not _declared:
		w.append("%s: the graph declares no parameter '%s', so it reads 0." % [display_name(), param_id])
	elif _type == PortType.PATH and (_path == null or _path.segment_count() == 0):
		w.append(("%s: the host brush supplied no spline for '%s', so it produces an empty path. Add a "
				+ "Pasture3DSpline under the brush, or pick one by key in the brush's Node Graph parameters.")
				% [display_name(), param_id])
	return w
