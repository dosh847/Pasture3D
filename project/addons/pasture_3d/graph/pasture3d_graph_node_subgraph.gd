# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSubgraph — a node that IS another graph (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §11).
#
# ---- THE PORTS COME FROM THE CHILD ----
#
# Inputs: one per Subgraph Input node in the child, in node order, then one VALUE port per parameter the
# child declares (§10), then the standard mask when the first input and first output are both HEIGHT.
# Outputs: one per Subgraph Output node in the child, in node order. The node declares none of it; it reads
# the child every time its port tables are rebuilt, which is every `changed` — and the child's edits reach
# here as `changed`, bound to the child OBJECT (`_bind_child`), not to a key someone has to remember to move.
#
# ---- IT NEVER RUNS ----
#
# Subgraphs do not exist below the compiler (§11.2). `Pasture3DTerrainGraph` flattens a graph holding one of
# these into a generated graph of ordinary nodes and hands every evaluator that; this node only supplies the
# expansion (`instance_nodes`) and the values of its parameter ports. Its own op is deliberately not in the
# native op table, so a route that forgot to flatten fails to lower rather than evaluating a passthrough.
#
# ---- PER-INSTANCE COPIES ----
#
# Each Subgraph node expands to its OWN copies of the child's nodes, so two instances of one child with
# different parameter values are two sets of nodes with two sets of values, and a node's grid cache belongs
# to one instance. The copies are kept here and rebuilt when the child moves (`_child_serial`).
@tool
class_name Pasture3DGraphNodeSubgraph
extends Pasture3DGraphNode

const VALUE_PREFIX := "values/"

## The child graph. An external `.tres` is shared by every Subgraph node naming it; Make Unique gives this
## node its own.
@export var graph: Pasture3DTerrainGraph = null:
	set(v):
		if graph == v:
			return
		_bind_child(graph, false)
		graph = v
		_bind_child(graph, true)
		_child_serial += 1
		notify_property_list_changed()
		emit_changed()

## This instance's value for each child parameter whose port is unwired, by parameter id. An id with no
## entry reads the child's declared default. Ids the child no longer declares are kept and never read.
@export_storage var param_values: Dictionary = {}

## Moves on every edit of the child (any node, any wire, any declaration). The instance copies key on it.
var _child_serial: int = 0
var _relaying := false

# The expansion cache. `_inst_key` identifies the child graph object it was copied from and the child's
# serial at the time.
var _inst_key: int = 0
var _inst_nodes: Array = []
var _inst_notes := PackedStringArray()


func op() -> StringName:
	return &"subgraph"


## Never reaches a compiler: the parent's flat view replaces it with the child's nodes (§11.2), so it has
## no native op id on purpose. `GraphAllNodeSocketsGate` reads this as the declaration.
func flattens_away() -> bool:
	return true


# ---- The child ------------------------------------------------------------------------------------------

func _bind_child(p_child: Pasture3DTerrainGraph, p_connect: bool) -> void:
	if p_child == null:
		return
	# node_changed fires for every node edit, wired to the output or not; structure_changed for every wire,
	# node list, output and declaration edit. Between them, nothing the child does goes unheard.
	for sig: Signal in [p_child.node_changed, p_child.structure_changed]:
		if p_connect:
			if not sig.is_connected(_on_child_edited):
				sig.connect(_on_child_edited)
		elif sig.is_connected(_on_child_edited):
			sig.disconnect(_on_child_edited)


## The child moved. Re-derive the ports and tell the parent. The guard is what keeps a graph that contains
## itself (which flattening refuses, §11.3) from relaying its own edit back into itself forever.
func _on_child_edited(_p_index: int = -1) -> void:
	if _relaying:
		return
	_relaying = true
	_child_serial += 1
	emit_changed()
	_relaying = false


## The child's Subgraph Input nodes with a usable id, first of each id, in node order.
func child_inputs() -> Array:
	return _child_boundary(&"subgraph_input", &"input_id")


## The child's Subgraph Output nodes with a usable id, first of each id, in node order.
func child_outputs() -> Array:
	return _child_boundary(&"subgraph_output", &"output_id")


func _child_boundary(p_op: StringName, p_prop: StringName) -> Array:
	var out: Array = []
	if graph == null:
		return out
	var seen := {}
	for n in graph.nodes:
		if n == null or n.op() != p_op:
			continue
		var id := StringName(n.get(p_prop))
		if id == &"" or id == Pasture3DGraphNode.MASK_PORT_ID or seen.has(id):
			continue
		seen[id] = true
		out.append(n)
	return out


## The parameter ids that become value ports: the child's declarations, minus any id a Subgraph Input
## already uses (the input wins; `node_warnings` reports the clash).
func child_param_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	if graph == null:
		return out
	var taken := {}
	for n in child_inputs():
		taken[n.input_id] = true
	for id in graph.param_ids():
		if not taken.has(id) and id != Pasture3DGraphNode.MASK_PORT_ID:
			out.append(id)
	return out


# ---- Ports -------------------------------------------------------------------------------------------

func role() -> Role:
	var ins := _inputs()
	var outs := _outputs()
	if not ins.is_empty() and not outs.is_empty() and ins[0].type == PortType.HEIGHT \
			and outs[0].type == PortType.HEIGHT:
		return Role.FILTER
	return Role.GENERATOR if ins.is_empty() else Role.COMBINER


## Conservative for anything that asks before flattening (the editor's tier badge): a child may hold
## anything.
func needs_grid() -> bool:
	return true


func _inputs() -> Array[Pasture3DGraphPort]:
	var out: Array[Pasture3DGraphPort] = []
	for n in child_inputs():
		out.append(n.as_port())
	for id in child_param_ids():
		var decl: Pasture3DGraphParam = graph.find_param(id)
		var p := Pasture3DGraphPort.value(id, decl.port_type(), StringName(VALUE_PREFIX + String(id)))
		p.labelled(decl.display_label())
		out.append(p)
	return out


func _outputs() -> Array[Pasture3DGraphPort]:
	var out: Array[Pasture3DGraphPort] = []
	for n in child_outputs():
		out.append(n.as_port())
	return out


## The number this instance gives parameter `p_id` while its port is unwired.
func param_number(p_id: StringName) -> float:
	var decl: Pasture3DGraphParam = graph.find_param(p_id) if graph != null else null
	if decl == null:
		return float(param_values.get(p_id, 0.0))
	if param_values.has(p_id):
		return decl.coerce(param_values[p_id])
	return decl.default_number()


func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if graph == null:
		return out
	for id in child_param_ids():
		var info: Dictionary = graph.find_param(id).property_info(VALUE_PREFIX + String(id))
		info["usage"] = PROPERTY_USAGE_EDITOR
		out.append(info)
	return out


func _get(p_name: StringName) -> Variant:
	var s := String(p_name)
	if not s.begins_with(VALUE_PREFIX) or graph == null:
		return null
	var id := StringName(s.substr(VALUE_PREFIX.length()))
	var decl: Pasture3DGraphParam = graph.find_param(id)
	if decl == null:
		return null
	return decl.typed(param_number(id))


func _set(p_name: StringName, p_value: Variant) -> bool:
	var s := String(p_name)
	if not s.begins_with(VALUE_PREFIX):
		return false
	var id := StringName(s.substr(VALUE_PREFIX.length()))
	var decl: Pasture3DGraphParam = graph.find_param(id) if graph != null else null
	param_values[id] = decl.coerce(p_value) if decl != null else float(p_value)
	emit_changed()
	return true


func _property_can_revert(p_name: StringName) -> bool:
	var s := String(p_name)
	return s.begins_with(VALUE_PREFIX) and param_values.has(StringName(s.substr(VALUE_PREFIX.length())))


func _property_get_revert(p_name: StringName) -> Variant:
	var s := String(p_name)
	var decl: Pasture3DGraphParam = graph.find_param(StringName(s.substr(VALUE_PREFIX.length()))) if graph != null else null
	return decl.typed(decl.default_number()) if decl != null else null


# ---- Reach -------------------------------------------------------------------------------------------
#
# Both are computed over the FLATTENED view by the graph (§11.2); these answers are only what a route that
# never flattened would see, and they are the conservative ones.

func edit_reach() -> float:
	return INF


func outward_reach() -> float:
	return 0.0


# ---- Expansion ---------------------------------------------------------------------------------------

## This instance's copies of `p_flat`'s nodes, parallel to `p_flat.nodes`: a fresh copy per node, or null for
## a node an instance does not carry. `p_flat` is the child itself, or the child's own flattened view when
## the child holds subgraphs. Cached until the child moves. `notes` collects what was refused or thawed.
##
## Not carried: the child's Output node (the instance's result leaves through Subgraph Output nodes, and an
## Output copy would take over the PARENT's output), a dead Subgraph or Combine node of the child's own
## (already expanded in `p_flat`), and every sink and publish node (refused in this phase, §11.3).
func instance_nodes(p_flat: Pasture3DTerrainGraph) -> Array:
	var key := hash([p_flat.get_instance_id(), _child_serial, p_flat.nodes.size()])
	if key == _inst_key and _inst_nodes.size() == p_flat.nodes.size():
		return _inst_nodes
	_inst_key = key
	_inst_nodes = []
	_inst_notes = PackedStringArray()
	for src in p_flat.nodes:
		if src == null or src.op() == &"subgraph" or src.op() == &"combine" or src.op() == &"output":
			_inst_nodes.append(null)
			continue
		if src is Pasture3DGraphNodeChannelSink or src is Pasture3DGraphNodeExportSink \
				or src is Pasture3DGraphNodeRuntimeSink:
			_inst_notes.append("%s: %s inside the subgraph is not run; sinks and publish nodes are refused in a subgraph." \
					% [display_name(), src.display_name()])
			_inst_nodes.append(null)
			continue
		var d: Pasture3DGraphNode = src.duplicate(false)
		if d is Pasture3DGraphSolverNode and d.evaluation == Pasture3DGraphSolverNode.Evaluation.FROZEN:
			# §11.4: one node resource cannot hold a freeze per instance yet.
			d.evaluation = Pasture3DGraphSolverNode.Evaluation.LIVE
			_inst_notes.append("%s: %s is Frozen in the child and runs Live here; a solver inside a subgraph cannot be Frozen." \
					% [display_name(), src.display_name()])
		if src.op() == &"param":
			# A copy of the child's own copy keeps the value it was pinned to; `duplicate` does not carry the
			# runtime binding.
			d.pin(src._type, src.resolved_value(), src.resolved_path())
		_inst_nodes.append(d)
	return _inst_nodes


## What the last expansion refused or changed, for the parent's warnings.
func instance_notes() -> PackedStringArray:
	return _inst_notes


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if graph == null:
		w.append("%s: no graph assigned, so it has no ports and outputs nothing." % display_name())
		return w
	if not graph.is_compatible():
		w.append("%s: %s It passes its first input through." % [display_name(), graph.format_refusal()])
	var ids := {}
	for n in child_inputs():
		ids[n.input_id] = true
	for id in graph.param_ids():
		if ids.has(id):
			w.append("%s: parameter '%s' has the same id as a Subgraph Input, so it gets no port." % [display_name(), id])
	w.append_array(_inst_notes)
	return w
