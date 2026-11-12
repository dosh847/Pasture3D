# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainGraph — a saveable DAG of Pasture3DGraphNodes that evaluates to one height field. This
# is the reusable unit the whole feature turns on: a graph is a `.tres`, so "a different graph per kind
# of landscape" is just a different resource, and the same graph can drive a whole terrain OR be masked
# to a brush's footprint (the later stack-mount increment).
#
# It generalises the brush node stack from a chain to a DAG. Increment 1 is the EVALUATOR ONLY — headless
# and gated, the way the Sim was built (PASTURE3D_SIM_NODE_SPEC.md) before it grew a UI and a threaded
# backend. No editor UI, no C++/GPU, no stack mount yet; those are later increments
# (PASTURE3D_TERRAIN_GRAPH_SPEC.md, build order).
#
# ---- Evaluation model (increment 1): simplest-correct ----
#
# Topologically order the nodes feeding the output and MATERIALISE ONE GRID PER NODE. A cell node's grid
# is a per-cell loop over `eval_cell`; a grid node's is one `eval_grid` call. No fold yet — a run of cell
# nodes is not fused into a single loop. That fold (and then a C++/GPU backend that keeps grids resident)
# is a pure optimisation layered on later; the per-node grid is the oracle it must match.
@tool
class_name Pasture3DTerrainGraph
extends Resource

const FrameDataScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_frame_data.gd")

## Emitted when graph topology (nodes added/removed, frames, positions) changes for UI canvas synchronization.
signal structure_changed()

## One node's parameters changed, whatever that node is wired to. `changed` is the BAKE signal and stays
## gated on "does this reach the output"; this one is the EDITOR signal, and the editor's node previews
## need it precisely for the nodes `changed` filters out — the branch you are still building, and every
## node in a graph that has no output selected yet. Carries the node's index in `nodes`, or -1 if the
## emitter is not in the array.
signal node_changed(index: int)

## The declared parameter LIST changed: one added, removed, renamed, retyped, or given a new default or
## range. A host listens to this to rebuild the inspector properties it exposes for them (ports spec §10.2).
signal parameters_changed()

## The saved layout this plugin writes, and the oldest it still reads. A graph outside that span is REFUSED:
## it evaluates nothing, its host brush skips it, and `graph_warnings` names both versions. Nothing is
## migrated on load (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §4). Raise both when a change makes an
## older file mean something else, such as a port removed while wires are stored by index.
##
## Format 2 (2026-11-09) stores wires by PORT ID (`wires`); formats 0 and 1 stored them by port index
## (`connections`), which meant inserting or removing a port silently re-aimed every later wire.
##
## Format 3 (2026-11-10) is the standard mask (spec §9): a `mask` wire into a FILTER or SOLVER now means
## "blend the result over the input", Leveler's and Mudslide's old `mask` are `area` and `source`, and
## Terrace's `amount` is a number. A format-2 file is converted by text, not on load.
const FORMAT_CURRENT := 3
const FORMAT_MIN_COMPATIBLE := 3

## The layout this graph was saved in. The script default is 0 and must stay 0: a property equal to its
## default is left out of the file, so a file with no `format_version` line loads as 0, which is what a
## graph saved before versioning is. For that reason it is NOT set in `_init`, which also runs on load;
## `create_default` and the first `add_node` stamp a new graph instead.
@export var format_version: int = 0:
	set(v):
		if format_version == v:
			return
		format_version = v
		structure_changed.emit()
		emit_changed()

## The nodes. Order here is authoring order only — evaluation order is derived from `connections`.
@export var nodes: Array[Pasture3DGraphNode] = []:
	set(v):
		_bind_nodes(nodes, false)
		nodes = v
		_bind_nodes(nodes, true)
		# A Parameter node added here has no binding yet, and its port type comes from the binding.
		_apply_params()
		# Stored wires that arrived before their nodes did (see `wires`).
		if _wires_pending:
			_resolve_wires()
		structure_changed.emit()
		if output_index() >= 0:
			emit_changed()

## THE DECLARED PARAMETERS, in the order a host lists them (ports spec §10). A Parameter node outputs one,
## chosen by id; the value comes from the host (`set_host_params`), and an id no host supplies reads the
## declaration's default. Editing this list is a graph edit like any other: it emits `changed`, so every
## host re-bakes, and `parameters_changed`, so every host rebuilds its property list.
@export var parameters: Array[Pasture3DGraphParam] = []:
	set(v):
		_bind_params(parameters, false)
		parameters = v
		_bind_params(parameters, true)
		_on_params_changed()

## THE STORED WIRES, by port id. Each row is `[from_node: int, from_id: StringName, to_node: int,
## to_id: StringName]`: node indices into `nodes`, and the `id` of a `Pasture3DGraphPort` on each end.
## This is what a file holds (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §7); it is not a working form,
## and nothing but the loader, the saver and a converter should touch it.
##
## SET (by the loader): the rows are resolved to `connections`, once, as soon as `nodes` is there. Property
## load order is not something a setter may assume, so a `wires` that arrives first waits for `nodes`. A row
## whose id its node no longer declares is DROPPED and reported by `graph_warnings`; it is never rebound to
## whichever port now sits at that position, which is the whole reason ids are stored.
##
## GET (by the saver): computed from `connections` and the ports the nodes declare NOW. Not cached, because
## a node may change its port list between the edit and the save, and the file has to name the ports the
## author was looking at. A row naming a node or port that does not exist has no id and is left out.
##
## `@export_storage`: saved, and not shown in the inspector.
@export_storage var wires: Array = []:
	get:
		if _wires_pending:
			return _wires_loaded
		return _wires_from_connections()
	set(v):
		_wires_loaded = v
		_wires_pending = true
		_resolve_wires()

## THE WORKING WIRES, each a PackedInt32Array `[from_node, from_port, to_node, to_port]` (indices into
## `nodes` and into each node's port list). Every reader, the compiler and the editor use this. It is NOT
## stored: `wires` is, and this is rebuilt from it on load. Assigning it is how wiring is edited.
var connections: Array = []:
	set(v):
		connections = v
		structure_changed.emit()
		emit_changed()

var _wires_loaded: Array = []
var _wires_pending: bool = false
## What `_resolve_wires` could not place, as warning text. Kept until `wires` is assigned again: it is a
## report of what the last load dropped.
var _wires_dropped := PackedStringArray()

## Index into `nodes` of the node whose grid is the graph's output. -1 (or out of range) = no output, and
## `evaluate` returns a flat 0 field rather than guessing.
@export var output_node: int = -1:
	set(v):
		output_node = v
		structure_changed.emit()
		emit_changed()

## Temporary editor solo preview override (-1 = normal graph output). When set >= 0, evaluate() routes
## this node's output to the 3D viewport without mutating the permanent saved output.
@export var output_override: int = -1:
	set(v):
		output_override = v
		structure_changed.emit()
		emit_changed()

## Comment and grouping boxes organizing subsets of nodes on the visual canvas.
@export var frames: Array = []:
	set(v):
		_bind_frames(frames, false)
		frames = v
		_bind_frames(frames, true)
		structure_changed.emit()

# ---- Cache Memory Management (Milestone 1) -----------------------------------------------------------
## Maximum total memory in bytes allowed for per-node cached output grids (default 256 MB).
@export var max_cache_bytes: int = 268435456


## Preview evaluation scale (spec §5.4). 1 = 1:1 (default), 2 = 1:2, 4 = 1:4.
##
## ON THE GRAPH, NOT THE NODE, because it is a property of how expensive THIS GRAPH is to preview, not of
## how one thumbnail should look. A per-node scale would let two thumbnails in one refresh disagree about
## their resolution, and the tap pass is a single dispatch precisely so they cannot.
##
## IT TOUCHES THE PREVIEW ONLY. `evaluate()` never reads it and must never read it: the bake is
## bit-identical with this at 1 and at 4, and criterion [F] asserts exactly that rather than trusting the
## sentence. Painting stays at full resolution — isolating an area and working at full res is the point of
## the brush system, and this option does not change it.
##
## A PLAIN `@export` WITH NO SETTER, for §12.6's reason: view state must not participate in invalidation
## or caching. GDScript export assignment fires no `Resource.changed`, so this cannot reach
## `_bump_revision` and cannot cost a bake.
##
## Anything but 1 PUTS A BADGE ON SCREEN, and that is not decoration. A downscaled preview of an erosion
## network is a LIE ABOUT THE NETWORK'S FINENESS: channels merge, ridges round off, and the author tunes
## the wrong parameter to fix a problem only the preview has. Same discipline as the range chip — a
## normalised picture without its divisor is not a measurement.
@export_enum("1:1:1", "1:2:2", "1:4:4") var preview_scale: int = 1

var _global_access_tick: int = 0

# ---- Topology memoization ----------------------------------------------------------------------------
# `_eval_order` and `_fold_plan` depend ONLY on graph topology (nodes, connections, and which node is the
# output) — never on parameter values or mute state — so their results are safe to cache until the topology
# changes. A single bake chains native_supported -> compile_graph_program -> _fold_plan, each recomputing
# the same O(V*E) order/fold from scratch; the editor's async pipeline recompiles a program per expanded
# preview. Caching keyed on the resolved root, cleared on `structure_changed`, removes that redundant walk.
# The cached objects are shared and MUST be treated as read-only by callers.
var _order_cache: Dictionary = {}   # root:int -> Array (topological order)
var _fold_cache: Dictionary = {}    # root:int -> Dictionary (fold plan)


func _invalidate_topology_cache() -> void:
	_order_cache.clear()
	_fold_cache.clear()
	_native_ok_cache.clear()
	_flat_dirty = true


## Clears all cached output grid buffers across every node in the graph.
func clear_cache() -> void:
	for n in nodes:
		if n != null:
			n.clear_cache()


## Total memory footprint in bytes across all node cached grid buffers in this graph.
func get_total_cache_bytes() -> int:
	var total := 0
	for n in nodes:
		if n != null:
			total += n.get_cache_size_bytes()
	return total


## Evicts least-recently-accessed node caches until total memory footprint is <= max_cache_bytes.
func _evict_cache_if_needed() -> void:
	if max_cache_bytes <= 0:
		return
	if get_total_cache_bytes() <= max_cache_bytes:
		return
	
	var cached_nodes: Array[Pasture3DGraphNode] = []
	for n in nodes:
		if n != null and not n.get_cached_grid().is_empty():
			cached_nodes.append(n)
			
	cached_nodes.sort_custom(func(a: Pasture3DGraphNode, b: Pasture3DGraphNode) -> bool:
		return a._last_access_tick < b._last_access_tick
	)
	
	for n in cached_nodes:
		n.clear_cache()
		if get_total_cache_bytes() <= max_cache_bytes:
			break



# ---- Change forwarding -------------------------------------------------------------------------------
#
# A node's own property setters emit `changed` on the node; the graph checks if that node feeds the active
# output. If it does, the graph re-emits `changed` so the host brush re-bakes. A node disconnected from the
# output changes nothing the bake would see, so no re-bake is triggered.

func _bind_nodes(p_list: Array, p_connect: bool) -> void:
	for n in p_list:
		if n == null:
			continue
		# The bound Callable, once, for all three operations — `is_connected`, `connect`, `disconnect`.
		#
		# This is clarity, not a bug fix: `Signal.is_connected` matches on object+method and IGNORES the
		# binds, so probing the unbound `_on_node_changed` did find the bound entry and the disconnect
		# below did work. (`b == h` is still false; the two use different rules. Measured on 4.7.) That
		# same loose matching is what DOES break `_connect_spline` in the brush, where two Path3Ds share
		# one Curve3D and differ only in their bind — see the relay there.
		var cb := _on_node_changed.bind(n)
		if p_connect:
			if not n.changed.is_connected(cb):
				n.changed.connect(cb)
		elif n.changed.is_connected(cb):
			n.changed.disconnect(cb)


func _on_node_changed(p_node: Pasture3DGraphNode = null) -> void:
	var n_idx := -1
	if p_node != null:
		n_idx = nodes.find(p_node)
	# A Parameter node that was just pointed at another id has the OLD parameter's value until it is bound
	# again, and everything below this line reads it.
	# If the new id is declared with a different type, the PORT changed. That is structure, and it has to be
	# said even when nothing below fires: a freshly added Parameter is unwired, so it feeds no output and
	# emits no `changed`, and the editor kept drawing the slot of the type it had before. A Float slot
	# refuses a Path wire, so a PATH parameter could never be connected.
	if p_node != null and p_node.op() == &"param":
		var ports_before := p_node.output_port_types()
		_apply_params()
		if p_node.output_port_types() != ports_before:
			structure_changed.emit()

	# A node the graph does not contain cannot feed the output — that is provable, not a guess, so it
	# defaults to false. It used to default to true, which meant a node left wired by the dead disconnect
	# branch above unconditionally re-baked the terrain after being removed.
	# The editor hears about every edit; only the bake is filtered. GraphEditModelGate [E].
	node_changed.emit(n_idx)

	var affects_output := p_node == null
	if n_idx >= 0:
		var out_idx := output_index()
		# No output at all is the graph being authored, not a node proven irrelevant: there is nothing for
		# the edit to be downstream OF, and nothing baked for a spurious re-bake to cost. Treating that as
		# "does not affect the output" left `_revision` — and so every cache keyed on `content_key()` —
		# frozen for the whole time a graph had no output node.
		affects_output = get_downstream_nodes(n_idx).has(out_idx) if out_idx >= 0 else true

	if affects_output:
		emit_changed()


## Returns all downstream node indices that depend on `p_start_node` (including `p_start_node` itself).
func get_downstream_nodes(p_start_node: int) -> Array[int]:
	var result: Array[int] = [p_start_node]
	var frontier: Array[int] = [p_start_node]
	var visited := {p_start_node: true}
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[0]) == cur:
				var to := int(c[2])
				if to >= 0 and to < nodes.size() and not visited.has(to):
					visited[to] = true
					result.append(to)
					frontier.push_back(to)
	return result


func _bind_frames(p_list: Array, p_connect: bool) -> void:
	for f in p_list:
		if f == null:
			continue
		if p_connect:
			if not f.changed.is_connected(_on_frame_changed):
				f.changed.connect(_on_frame_changed)
		elif f.changed.is_connected(_on_frame_changed):
			f.changed.disconnect(_on_frame_changed)


func _on_frame_changed() -> void:
	structure_changed.emit()


## Monotonic content revision, bumped on every `changed` (any node param, wiring, or output). A host's
## frozen cache stores the revision it baked at; a served entry whose revision differs is stale. Absolute
## value does not matter — only that it changes on an edit — so resetting to 0 on reload is fine, because
## the in-memory cache is empty then too.
var _revision: int = 0


func _bump_revision() -> void:
	_revision += 1


func _init() -> void:
	# A named method, not a lambda: a lambda touching a member becomes a `GDScriptLambdaSelfCallable`
	# holding a strong reference to its host, and storing that in the host's own signal list is a
	# reference cycle a `RefCounted` graph never escapes — taking every node's `_cached_grid` with it.
	changed.connect(_bump_revision)
	structure_changed.connect(_invalidate_topology_cache)


## The current content revision — a host reads this as the staleness key for a frozen bake.
##
## The GRAPH's content, and nothing a host supplies: two hosts with different parameter values read the same
## number here. A host that supplies parameters keys on `hash([content_key(), params_sig()])` after stamping
## its own (`Pasture3DNodeGraph.graph_key`), which is why this stays a pure revision.
func content_key() -> int:
	return _revision


# ---- Parameters (ports spec §10) --------------------------------------------------------------------
#
# The graph declares them; a host supplies the values. `host_params` is the same kind of thing as
# `host_footprint` above it: runtime only, never saved, stamped by the host before it compiles or evaluates,
# and read by everything that compiles after. Because a program's RESULT is never memoised
# (`_native_ok_cache` explains why), stamping is all "substituted at compile" needs: the Parameter node
# lowers the number it was bound to, on every compile.

## `{id: value}` as the host supplied them. Ids the graph does not declare are kept here untouched and
## simply never read; the host is the one that reports them.
var host_params: Dictionary = {}

## `{id: Pasture3DGraphPath}` for the PATH parameters, as the host RESOLVED them (Pasture3DGraphParam's header:
## the host owns the spline lookup, a Resource cannot reach the scene). An id with no entry reads no path.
var host_paths: Dictionary = {}

## The instance id of the host stamped last, 0 for none (a graph edited or tested on its own). Every node keeps
## one cache slot per host (Pasture3DGraphNode.select_host), and this is the slot in use: a graph shared by many
## brushes must solve and cache for each on its own, or they evict, and worse SERVE, each other's results.
var host_id: int = 0


func _bind_params(p_list: Array, p_connect: bool) -> void:
	for p in p_list:
		if p == null:
			continue
		if p_connect:
			if not p.changed.is_connected(_on_params_changed):
				p.changed.connect(_on_params_changed)
		elif p.changed.is_connected(_on_params_changed):
			p.changed.disconnect(_on_params_changed)


func _on_params_changed() -> void:
	_apply_params()
	parameters_changed.emit()
	# A retyped parameter changes a Parameter node's port, which is structure; a new default changes what an
	# unsupplied host bakes, which is content.
	structure_changed.emit()
	emit_changed()


## The declaration for `p_id`, or null. The FIRST one wins when two share an id; `graph_warnings` reports
## the second.
func find_param(p_id: StringName) -> Pasture3DGraphParam:
	if p_id == &"":
		return null
	for p in parameters:
		if p != null and p.id == p_id:
			return p
	return null


## The declared ids, in order, without duplicates or blanks: what a host lists.
func param_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for p in parameters:
		if p != null and p.id != &"" and not out.has(p.id):
			out.append(p.id)
	return out


## The number `p_id` evaluates to for the host stamped last: its value if it supplied one, else the declared
## default. 0 for an id the graph does not declare.
func param_value(p_id: StringName) -> float:
	var decl := find_param(p_id)
	if decl == null:
		return 0.0
	if host_params.has(p_id):
		return decl.coerce(host_params[p_id])
	return decl.default_number()


## Stamp one host's values. Called by the host before every compile and every evaluate, exactly as
## `set_host_footprint` is. EMITS NOTHING: `changed` is the bake signal and the graph is shared, so a stamp
## that emitted would have each host's bake re-bake the others. Everything that must notice the values
## reads them instead (`params_sig`, `_compute_node_inputs_hash`).
func set_host_params(p_values: Dictionary, p_paths: Dictionary = {}, p_host_id: int = 0) -> void:
	host_params = p_values
	host_paths = p_paths
	select_host(p_host_id)
	_apply_params()


## Make `p_host_id`'s cache slot the live one on every node. Emits nothing (see `set_host_params`).
func select_host(p_host_id: int) -> void:
	host_id = p_host_id
	for node in nodes:
		if node != null:
			node.select_host(p_host_id)


## Push every Parameter node its declared type and resolved number. See Pasture3DGraphNodeParam.bind.
func _apply_params() -> void:
	for node in nodes:
		if node != null and node.op() == &"param" and not node.is_pinned():
			var decl := find_param(node.param_id)
			if decl == null:
				node.bind(Pasture3DGraphNode.PortType.FLOAT, 0.0, false)
			else:
				node.bind(decl.port_type(), param_value(decl.id), true, host_paths.get(decl.id) as Pasture3DGraphPath)


## A signature of what the Parameter nodes evaluate to RIGHT NOW, i.e. for the host stamped last. 0 for a
## graph with no Parameter node, so a graph that uses none keys exactly as it did before parameters existed.
## Built from the nodes rather than from `host_params`, so a value nothing reads does not move it.
func params_sig() -> int:
	var sig: Array = []
	for ni in range(nodes.size()):
		var node: Pasture3DGraphNode = nodes[ni]
		if node != null and node.op() == &"param":
			sig.append(ni)
			sig.append(node.value_signature())
	return hash(sig) if not sig.is_empty() else 0


# ---- Subgraphs (ports spec §11) ---------------------------------------------------------------------
#
# SUBGRAPHS DO NOT EXIST BELOW THE COMPILER. A graph holding a Subgraph node is evaluated through its FLAT
# VIEW: a generated graph of ordinary nodes, built here, that every evaluator entry point hands the work to
# (`evaluate`, both compilers, the cell compiler, `native_supported`, the block report, the path pre-pass,
# both reaches, `reads_input`, `reads_footprint`). Nothing below those entry points knows a subgraph exists.
#
# The flat view keeps every top-level node at ITS OWN INDEX (the same objects, not copies), so a wire, a
# preview root, a sink's source and a freeze report mean the same node in both. After them it appends each
# Subgraph node's instance copies (`Pasture3DGraphNodeSubgraph.instance_nodes`) and rewires the boundary:
#   * a consumer of a Subgraph Input copy reads what the parent wired into that port; unwired, the copy is a
#     constant holding the input's default;
#   * a consumer of a child Parameter copy reads what the parent wired into that parameter's port; unwired,
#     the copy is pinned to the instance's value;
#   * a consumer of the Subgraph node's output port k reads whatever feeds the child's k-th Subgraph Output;
#   * with the standard mask wired, one Blend MIX of (input 0, output 0, mask) sits after it — the same op
#     the compiler emits for every other masked node.
# The Subgraph node itself stays at its index with no wires, so it never runs. The Subgraph Output copies
# stay too, wired, as the ROOTS a preview or a sink tapping a Subgraph node's port uses (`_flat_roots`).

## `_flat_root`'s answer for a Subgraph node with no output ports: there is nothing to evaluate.
const FLAT_NO_ROOT := -2

## True on a generated flat view. It never delegates again, and it is never saved.
var _is_flat := false
var _flat: Pasture3DTerrainGraph = null
var _flat_dirty := true
var _flat_sig: int = 0
## Subgraph node index -> the flat node each of its output ports is read from, in port order.
var _flat_roots: Dictionary = {}
## Flat node index -> the top-level node it belongs to (itself, or the Subgraph node that expanded to it).
var _flat_owner := PackedInt32Array()
## What the last flattening refused, as warning text: cycles, mostly. Per-instance notes live on the node.
var _flat_notes := PackedStringArray()
## How many times this graph's flat view was rebuilt. For the gates.
var flat_build_count: int = 0


## True when this graph holds a Subgraph node.
func has_subgraphs() -> bool:
	if _is_flat:
		return false
	for n in nodes:
		if n != null and n.op() == &"subgraph":
			return true
	return false


## True when this graph is evaluated through `flat_view()`: it holds a Subgraph node (§11) or a node with a
## multi-input port that the flat view lowers to a chain of Blends (a Combine, §12).
func needs_flat() -> bool:
	if _is_flat:
		return false
	for n in nodes:
		if n != null and (n.op() == &"subgraph" or n.op() == &"combine"):
			return true
	return false


## The graph every evaluator actually runs: this graph itself when it holds no Subgraph node, else its flat
## view, rebuilt when the wiring or any Subgraph node or child has moved since the last one. Main thread
## only, like `evaluate`: it builds resources.
func flat_view() -> Pasture3DTerrainGraph:
	if not needs_flat():
		return self
	_ensure_flat([self])
	_sync_flat()
	return _flat


## The node list an INSTANCE of this graph copies: this graph, or its flat view when it holds subgraphs.
## `p_stack` is the chain of graphs being expanded, for the cycle refusal.
func _flat_for(p_stack: Array) -> Pasture3DTerrainGraph:
	if not needs_flat():
		return self
	_ensure_flat(p_stack)
	return _flat


func _flat_signature() -> int:
	var sig: Array = []
	for i in range(nodes.size()):
		var n: Pasture3DGraphNode = nodes[i]
		if n != null and n.op() == &"subgraph":
			sig.append(i)
			sig.append(n._dirty_revision)
			sig.append(n._child_serial)
		elif n != null and n.op() == &"combine":
			# The fold's Blends carry the mode, and muting cuts the fold to its first wire (§12).
			sig.append(i)
			sig.append(int(n.mode))
			sig.append(n.muted)
	return hash(sig)


func _ensure_flat(p_stack: Array) -> void:
	var sig := _flat_signature()
	if _flat != null and not _flat_dirty and sig == _flat_sig:
		return
	_rebuild_flat(p_stack)
	_flat_sig = sig
	_flat_dirty = false


## The host-supplied state a flat view must see as its own. Copied on every use, because a host stamps its
## values onto THIS graph and the flat view is shared by every host of it.
func _sync_flat() -> void:
	_flat.host_params = host_params
	_flat.host_paths = host_paths
	_flat.select_host(host_id)
	_flat._apply_params()
	_flat.host_footprint = host_footprint
	_flat.force_gdscript_evaluation = force_gdscript_evaluation
	_flat.force_no_path_prepass = force_no_path_prepass
	_flat.force_no_staged_compile = force_no_staged_compile
	_flat.max_cache_bytes = max_cache_bytes


## A root as the flat view numbers it: the same index for every node but a Subgraph node, which is read from
## its port 0 root; -1 stays -1 (the output). FLAT_NO_ROOT for a Subgraph node with nothing to read.
func _flat_root(p_root: int) -> int:
	if p_root < 0 or p_root >= nodes.size():
		return -1
	if not _flat_roots.has(p_root):
		return p_root
	var r: Array = _flat_roots[p_root]
	return int(r[0]) if not r.is_empty() and int(r[0]) >= 0 else FLAT_NO_ROOT


## Every flat root a list of roots expands to: each port of a Subgraph node, everything else as-is.
func _flat_roots_of(p_roots: Array) -> Array:
	var out: Array = []
	for r in p_roots:
		var ri := int(r)
		if _flat_roots.has(ri):
			for x in _flat_roots[ri]:
				if int(x) >= 0 and not out.has(int(x)):
					out.append(int(x))
		elif not out.has(ri):
			out.append(ri)
	return out


## A block report from the flat view, its `node` put back into this graph's numbering: a copy inside a
## subgraph instance is reported as the Subgraph node that holds it.
func _flat_report(p_rep: Dictionary) -> Dictionary:
	var ni := int(p_rep.get("node", -1))
	if ni >= 0 and ni < _flat_owner.size() and _flat_owner[ni] != ni:
		p_rep["node"] = _flat_owner[ni]
		var own: Pasture3DGraphNode = nodes[_flat_owner[ni]] if _flat_owner[ni] < nodes.size() else null
		var where := "inside the Combine fold" if own != null and own.op() == &"combine" else "inside the subgraph"
		p_rep["detail"] = "%s (%s)" % [String(p_rep.get("detail", "")), where]
	return p_rep


## `compile_graph_program_multi` on the flat view, with each Subgraph root expanded to its ports and the
## result told how to find them again: `slot_of` / `raw_slot_of` map the Subgraph node to its port 0 root,
## and `sub_taps` lists one slot per port, which `tap_slot` and `tap_channel` read.
func _flat_compile_multi(p_roots: Array) -> Dictionary:
	var fv := flat_view()
	var froots := _flat_roots_of(p_roots)
	if froots.is_empty():
		return {}
	var compiled := fv.compile_graph_program_multi(froots)
	if compiled.is_empty():
		return compiled
	var so: Dictionary = compiled["slot_of"]
	var rs: Dictionary = compiled["raw_slot_of"]
	var taps := {}
	for r in p_roots:
		var ri := int(r)
		if not _flat_roots.has(ri):
			continue
		var per: Array = []
		for x in _flat_roots[ri]:
			per.append(int(so[int(x)]) if int(x) >= 0 and so.has(int(x)) else -1)
		taps[ri] = per
		if not per.is_empty() and int(per[0]) >= 0:
			so[ri] = int(per[0])
			rs[ri] = int(per[0])
	compiled["sub_taps"] = taps
	return compiled


func _release_flat() -> void:
	if _flat == null:
		return
	# The old view shares this graph's node objects and parameter declarations, and is bound to their
	# signals. Unbinding is what lets it go.
	var none_n: Array[Pasture3DGraphNode] = []
	var none_p: Array[Pasture3DGraphParam] = []
	_flat.nodes = none_n
	_flat.parameters = none_p
	_flat = null


func _rebuild_flat(p_stack: Array) -> void:
	flat_build_count += 1
	var ctx := {
		"stack": p_stack,
		"fn": [],          # flat nodes
		"fc": [],          # flat wires
		"owner": [],       # flat index -> top-level owner
		"alias": {},       # Vector2i(subgraph node, port) -> Vector2i(flat source, port), x < 0 = unwired
		"roots": {},       # subgraph node -> [flat root per output port]
		"in_src": {},      # Vector2i(node, input port) -> Vector2i(source, port), this graph's wires
		"in_multi": {},    # Vector2i(node, input port) -> [Vector2i(source, port)] in row order (§12)
		"state": {},       # subgraph nodes already expanded (or being expanded)
		"notes": [],
	}
	for i in range(nodes.size()):
		ctx["fn"].append(nodes[i])
		ctx["owner"].append(i)
	for c in connections:
		if c.size() >= 4:
			var key := Vector2i(int(c[2]), int(c[3]))
			var src := Vector2i(int(c[0]), int(c[1]))
			ctx["in_src"][key] = src
			if not ctx["in_multi"].has(key):
				ctx["in_multi"][key] = []
			ctx["in_multi"][key].append(src)
	for i in range(nodes.size()):
		if nodes[i] != null and nodes[i].op() == &"subgraph":
			_fl_expand(ctx, i)
		elif nodes[i] != null and nodes[i].op() == &"combine":
			_fl_combine(ctx, i)
	for c in connections:
		if c.size() < 4:
			continue
		var t := int(c[2])
		if t < 0 or t >= nodes.size() or nodes[t] == null or _fl_lowered(nodes[t]):
			continue # a Subgraph or Combine node's inputs were consumed by its expansion
		var src := _fl_res(ctx, Vector2i(int(c[0]), int(c[1])))
		if src.x >= 0:
			ctx["fc"].append(PackedInt32Array([src.x, src.y, t, int(c[3])]))

	var f := Pasture3DTerrainGraph.new()
	f._is_flat = true
	f.format_version = FORMAT_CURRENT
	f.host_params = host_params
	f.parameters = parameters
	var typed: Array[Pasture3DGraphNode] = []
	typed.assign(ctx["fn"])
	_release_flat()
	f.nodes = typed
	f.connections = ctx["fc"]
	f.output_node = _flat_map_index(ctx, output_node)
	f.output_override = _flat_map_index(ctx, output_override)
	_flat = f
	_flat_roots = ctx["roots"]
	_flat_owner = PackedInt32Array(ctx["owner"])
	_flat_notes = PackedStringArray(ctx["notes"])


func _flat_map_index(p_ctx: Dictionary, p_i: int) -> int:
	if p_i < 0 or p_i >= nodes.size():
		return p_i
	if not p_ctx["roots"].has(p_i):
		return p_i
	var r: Array = p_ctx["roots"][p_i]
	return int(r[0]) if not r.is_empty() else -1


## A wire source in this graph's numbering, as the flat view reads it: a Subgraph node's port becomes the
## flat node behind it (expanding it first if need be).
func _fl_res(p_ctx: Dictionary, p_src: Vector2i) -> Vector2i:
	if p_src.x < 0 or p_src.x >= nodes.size() or nodes[p_src.x] == null:
		return Vector2i(-1, 0)
	if nodes[p_src.x].op() == &"subgraph":
		_fl_expand(p_ctx, p_src.x)
		return p_ctx["alias"].get(p_src, Vector2i(-1, 0))
	if nodes[p_src.x].op() == &"combine":
		_fl_combine(p_ctx, p_src.x)
		return p_ctx["alias"].get(p_src, Vector2i(-1, 0))
	return p_src


## A node the flat view replaces: it stays at its index, unwired, and never runs.
static func _fl_lowered(p_n: Pasture3DGraphNode) -> bool:
	return p_n != null and (p_n.op() == &"subgraph" or p_n.op() == &"combine")


## §12. A Combine node becomes a left fold of two-input Blends over its wires in row order,
## ((w0 op w1) op w2) …: exactly the chain an author would wire by hand, so the two compile alike. One wire
## (or a muted node) is a Reroute of the first wire; none is a Const 0. The last node is the root its
## consumers, a preview and the output read.
func _fl_combine(p_ctx: Dictionary, p_i: int) -> void:
	if p_ctx["state"].has(p_i):
		return
	p_ctx["state"][p_i] = true
	var cn: Pasture3DGraphNodeCombine = nodes[p_i]
	var srcs: Array = []
	for w in p_ctx["in_multi"].get(Vector2i(p_i, 0), []):
		var r := _fl_res(p_ctx, w)
		if r.x >= 0:
			srcs.append(r)
	if cn.muted and srcs.size() > 1:
		srcs = [srcs[0]]
	var fn: Array = p_ctx["fn"]
	var fc: Array = p_ctx["fc"]
	var root: int
	if srcs.is_empty():
		root = fn.size()
		fn.append(Pasture3DGraphNodeConst.new())
		p_ctx["owner"].append(p_i)
	elif srcs.size() == 1:
		root = fn.size()
		fn.append(Pasture3DGraphNodeReroute.new())
		p_ctx["owner"].append(p_i)
		fc.append(PackedInt32Array([srcs[0].x, srcs[0].y, root, 0]))
	else:
		var acc: Vector2i = srcs[0]
		for j in range(1, srcs.size()):
			var b := Pasture3DGraphNodeBlend.new()
			b.mode = cn.blend_mode()
			var bi := fn.size()
			fn.append(b)
			p_ctx["owner"].append(p_i)
			fc.append(PackedInt32Array([acc.x, acc.y, bi, 0]))
			fc.append(PackedInt32Array([srcs[j].x, srcs[j].y, bi, 1]))
			acc = Vector2i(bi, 0)
		root = acc.x
	p_ctx["alias"][Vector2i(p_i, 0)] = Vector2i(root, 0)
	p_ctx["roots"][p_i] = [root]


## What feeds input `p_port` of node `p_to`, in flat numbering; x < 0 when unwired.
func _fl_src_of(p_ctx: Dictionary, p_to: int, p_port: int) -> Vector2i:
	if p_port < 0:
		return Vector2i(-1, 0)
	return _fl_res(p_ctx, p_ctx["in_src"].get(Vector2i(p_to, p_port), Vector2i(-1, 0)))


func _graph_name(p_g: Pasture3DTerrainGraph) -> String:
	if p_g == null:
		return "<none>"
	if p_g.resource_name != "":
		return p_g.resource_name
	if p_g.resource_path != "":
		return p_g.resource_path.get_file()
	return "an unsaved graph"


func _fl_expand(p_ctx: Dictionary, p_s: int) -> void:
	if p_ctx["state"].has(p_s):
		return
	p_ctx["state"][p_s] = true
	var sub: Pasture3DGraphNodeSubgraph = nodes[p_s]
	var child: Pasture3DTerrainGraph = sub.graph
	var n_out := sub.output_count()
	var refused := child == null or not child.is_compatible()
	var stack: Array = p_ctx["stack"]
	if child != null and stack.has(child):
		# §11.3. Named, so the author can find the loop; the Subgraph node passes its first input through.
		var chain := PackedStringArray()
		for g in stack.slice(stack.find(child)):
			chain.append(_graph_name(g))
		chain.append(_graph_name(child))
		p_ctx["notes"].append("%s: the graph contains itself (%s), so the subgraph is refused and passes its first input through." \
				% [sub.display_name(), " -> ".join(chain)])
		refused = true
	if sub.muted or refused:
		# A muted node passes port 0 through; so does one whose child cannot run (§11.3). The other ports
		# read nothing.
		var r: Array = []
		if n_out > 0:
			var a0 := _fl_src_of(p_ctx, p_s, 0)
			p_ctx["alias"][Vector2i(p_s, 0)] = a0
			r.append(a0.x if a0.y == 0 else -1)
		p_ctx["roots"][p_s] = r
		return

	var cf: Pasture3DTerrainGraph = child._flat_for(stack + [child])
	var dups: Array = sub.instance_nodes(cf)
	var fn: Array = p_ctx["fn"]
	var off := fn.size()
	for d in dups:
		fn.append(d)
		p_ctx["owner"].append(p_s)
	# The child's OWN nodes are cf's first child.nodes.size() entries (cf keeps top-level indices, see the
	# header). Only those carry this instance's boundary: a deeper copy was already rewired by the child.
	var redirect := {} # cf index -> flat source
	for ci in range(mini(child.nodes.size(), dups.size())):
		var cn: Pasture3DGraphNode = cf.nodes[ci]
		if cn == null or dups[ci] == null:
			continue
		if cn.op() == &"subgraph_input":
			var port := sub.input_index_of(cn.input_id)
			var src := _fl_src_of(p_ctx, p_s, port)
			if src.x >= 0:
				redirect[ci] = src
		elif cn.op() == &"param":
			var pid: StringName = cn.param_id
			var port := sub.input_index_of(pid) if sub.child_param_ids().has(pid) else -1
			var src := _fl_src_of(p_ctx, p_s, port)
			if src.x >= 0:
				redirect[ci] = src
			var decl := child.find_param(pid)
			# An unwired PATH parameter inside an instance is pinned to NO path: the instance has no host of
			# its own to resolve a spline against. Wire a path into the Subgraph node's port to feed it.
			dups[ci].pin(decl.port_type() if decl != null else Pasture3DGraphNode.PortType.FLOAT,
					sub.param_number(pid) if decl != null else 0.0)
	var fc: Array = p_ctx["fc"]
	var into := {} # flat target index -> source feeding its port 0, for the outputs below
	for c in cf.connections:
		if c.size() < 4:
			continue
		var cfrom := int(c[0])
		var cto := int(c[2])
		if cto < 0 or cto >= dups.size() or dups[cto] == null:
			continue
		var src: Vector2i
		if redirect.has(cfrom):
			src = redirect[cfrom]
		elif cfrom >= 0 and cfrom < dups.size() and dups[cfrom] != null:
			src = Vector2i(off + cfrom, int(c[1]))
		else:
			continue
		fc.append(PackedInt32Array([src.x, src.y, off + cto, int(c[3])]))
		if int(c[3]) == 0:
			into[off + cto] = src
	var r: Array = []
	var outs := sub.child_outputs()
	for k in range(n_out):
		var co := child.nodes.find(outs[k]) if k < outs.size() else -1
		if co < 0 or co >= dups.size() or dups[co] == null:
			p_ctx["alias"][Vector2i(p_s, k)] = Vector2i(-1, 0)
			r.append(-1)
			continue
		p_ctx["alias"][Vector2i(p_s, k)] = into.get(off + co, Vector2i(-1, 0))
		r.append(off + co)
	# The standard mask (P5, §11.2): Blend MIX of (input 0, output 0, mask), exactly the slot the compiler
	# emits after any other masked node, so a masked Subgraph node and its inlined equivalent agree.
	var mp := sub.framework_mask_port()
	var m_src := _fl_src_of(p_ctx, p_s, mp) if mp >= 0 else Vector2i(-1, 0)
	if m_src.x >= 0 and n_out > 0:
		var b := Pasture3DGraphNodeBlend.new()
		b.mode = Pasture3DGraphNodeBlend.Mode.MIX
		var bi := fn.size()
		fn.append(b)
		p_ctx["owner"].append(p_s)
		var a_src := _fl_src_of(p_ctx, p_s, 0)
		var o_src: Vector2i = p_ctx["alias"][Vector2i(p_s, 0)]
		if a_src.x >= 0:
			fc.append(PackedInt32Array([a_src.x, a_src.y, bi, 0]))
		if o_src.x >= 0:
			fc.append(PackedInt32Array([o_src.x, o_src.y, bi, 1]))
		fc.append(PackedInt32Array([m_src.x, m_src.y, bi, 2]))
		p_ctx["alias"][Vector2i(p_s, 0)] = Vector2i(bi, 0)
		r[0] = bi
	p_ctx["roots"][p_s] = r


## False when this graph was saved in a layout this plugin does not read. An empty graph is always
## compatible: it has no wires or ports to mean something else, and it is what the inspector's New
## Pasture3DTerrainGraph makes, at version 0.
func is_compatible() -> bool:
	if nodes.is_empty() and connections.is_empty():
		return true
	return format_version >= FORMAT_MIN_COMPATIBLE and format_version <= FORMAT_CURRENT


## `wires` -> `connections`. Waits (stays pending) while there are rows and no nodes yet.
func _resolve_wires() -> void:
	if nodes.is_empty() and not _wires_loaded.is_empty():
		return
	_wires_pending = false
	_wires_dropped = PackedStringArray()
	var rows: Array = []
	for w in _wires_loaded:
		if not (w is Array) or w.size() < 4:
			_wires_dropped.append("a stored wire is not a [node, id, node, id] row")
			continue
		var fn := int(w[0])
		var tn := int(w[2])
		var from: Pasture3DGraphNode = nodes[fn] if fn >= 0 and fn < nodes.size() else null
		var to: Pasture3DGraphNode = nodes[tn] if tn >= 0 and tn < nodes.size() else null
		if from == null or to == null:
			_wires_dropped.append("a stored wire names node %d, which does not exist" % (fn if from == null else tn))
			continue
		var fp := from.output_index_of(StringName(w[1]))
		var tp := to.input_index_of(StringName(w[3]))
		if fp < 0:
			_wires_dropped.append("%s (node %d) has no output '%s'" % [from.display_name(), fn, w[1]])
			continue
		if tp < 0:
			_wires_dropped.append("%s (node %d) has no input '%s'" % [to.display_name(), tn, w[3]])
			continue
		rows.append(PackedInt32Array([fn, fp, tn, tp]))
	_wires_loaded = []
	connections = rows


## `connections` -> the rows `wires` stores.
func _wires_from_connections() -> Array:
	var out: Array = []
	for c in connections:
		if c.size() < 4:
			continue
		var fn := int(c[0])
		var tn := int(c[2])
		if fn < 0 or fn >= nodes.size() or tn < 0 or tn >= nodes.size() or nodes[fn] == null or nodes[tn] == null:
			continue
		var outs: Array = nodes[fn].output_ports()
		var ins: Array = nodes[tn].input_ports()
		var fp := int(c[1])
		var tp := int(c[3])
		if fp < 0 or fp >= outs.size() or tp < 0 or tp >= ins.size():
			continue
		out.append([fn, outs[fp].id, tn, ins[tp].id])
	return out


## A new, empty graph in the current format. What a script or a gate that fills `nodes` and `connections`
## by hand starts from: `.new()` is format 0, because that is also what the loader starts from, and a
## format-0 graph with nodes in it is refused.
static func create_empty() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	g.format_version = FORMAT_CURRENT
	return g


## Why this graph is refused, for a warning or a banner; empty when it is compatible.
func format_refusal() -> String:
	if is_compatible():
		return ""
	if format_version > FORMAT_CURRENT:
		return ("Terrain graph is format %d and this plugin reads up to format %d, so it is not run. "
				+ "Update the plugin, or rebuild the graph.") % [format_version, FORMAT_CURRENT]
	return ("Terrain graph is format %d and this plugin reads format %d and newer, so it is not run. "
			+ "Rebuild the graph and replace this one.") % [format_version, FORMAT_MIN_COMPATIBLE]


# ---- Editing API -------------------------------------------------------------------------------------
#
# The seam the graph editor drives and the gate tests. Every mutation keeps `connections` and
# `output_node` consistent with `nodes` and emits `changed`. Reassigning `nodes`/`connections` goes
# through their setters, so binding and the emit happen there.

## Append a node at `p_pos` and return its index.
func add_node(p_node: Pasture3DGraphNode, p_pos: Vector2 = Vector2.ZERO) -> int:
	if p_node == null:
		return -1
	# The first node of an empty graph is where it acquires a layout, so that is where it is stamped.
	if nodes.is_empty() and connections.is_empty():
		format_version = FORMAT_CURRENT
	p_node.graph_position = p_pos
	var arr := nodes.duplicate()
	arr.append(p_node)
	nodes = arr
	return nodes.size() - 1


## Remove the node at `p_index`: drop every connection touching it, shift indices above it down by one,
## follow `output_node`, and update frame attachments.
func remove_node(p_index: int) -> void:
	if p_index < 0 or p_index >= nodes.size():
		return
	var remapped: Array = []
	for c in connections:
		var f := int(c[0])
		var t := int(c[2])
		if f == p_index or t == p_index:
			continue
		remapped.append(PackedInt32Array([
			f - 1 if f > p_index else f, int(c[1]),
			t - 1 if t > p_index else t, int(c[3])]))
	if output_node == p_index:
		output_node = -1
	elif output_node > p_index:
		output_node = output_node - 1
		
	if output_override == p_index:
		output_override = -1
	elif output_override > p_index:
		output_override = output_override - 1
	connections = remapped
	
	# Remap frame attached indices
	for f in frames:
		if f != null:
			var new_attached := PackedInt32Array()
			for idx in f.attached_node_indices:
				if idx == p_index:
					continue
				new_attached.append(idx - 1 if idx > p_index else idx)
			f.attached_node_indices = new_attached
			
	var arr := nodes.duplicate()
	arr.remove_at(p_index)
	nodes = arr


## Append a frame and return its index.
func add_frame(p_frame: Resource) -> int:
	if p_frame == null:
		return -1
	var arr := frames.duplicate()
	arr.append(p_frame)
	frames = arr
	return frames.size() - 1


## Remove the frame at `p_index`.
func remove_frame(p_index: int) -> void:
	if p_index < 0 or p_index >= frames.size():
		return
	var arr := frames.duplicate()
	arr.remove_at(p_index)
	frames = arr


## Groups the specified node indices into a new GraphFrame bounding them. Returns frame index.
func group_nodes_in_frame(p_indices: Array, p_title: String = "Group", p_tint: Color = Color(0.2, 0.25, 0.35, 0.75)) -> int:
	var valid_indices: Array[int] = []
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	
	for idx in p_indices:
		var i := int(idx)
		if i >= 0 and i < nodes.size() and nodes[i] != null:
			valid_indices.append(i)
			var pos: Vector2 = nodes[i].graph_position
			min_pos = min_pos.min(pos)
			max_pos = max_pos.max(pos + Vector2(200, 100))
			
	var frame_pos: Vector2 = min_pos - Vector2(30, 40) if not is_inf(min_pos.x) else Vector2(100, 100)
	var frame_size: Vector2 = (max_pos - min_pos) + Vector2(60, 80) if not is_inf(min_pos.x) else Vector2(320, 240)
	frame_size = frame_size.max(Vector2(200, 140))
	
	var fd = FrameDataScript.new()
	fd.title = p_title
	fd.tint_color = p_tint
	fd.position_offset = frame_pos
	fd.size = frame_size
	fd.attached_node_indices = PackedInt32Array(valid_indices)
	return add_frame(fd)


## Splits an existing connection `(from:from_port -> to:to_port)` by inserting `p_node` at `p_pos`.
## Returns the newly inserted node's index. Performs insertion and rewiring atomically.
func split_connection_with_node(p_from: int, p_from_port: int, p_to: int, p_to_port: int, p_node: Pasture3DGraphNode, p_pos: Vector2) -> int:
	p_node.graph_position = p_pos
	var arr := nodes.duplicate()
	arr.append(p_node)
	var new_idx := arr.size() - 1
	
	var new_conns: Array = []
	for c in connections:
		if int(c[0]) == p_from and int(c[1]) == p_from_port \
				and int(c[2]) == p_to and int(c[3]) == p_to_port:
			continue
		new_conns.append(c)
	new_conns.append(PackedInt32Array([p_from, p_from_port, new_idx, 0]))
	new_conns.append(PackedInt32Array([new_idx, 0, p_to, p_to_port]))
	
	_bind_nodes([p_node], true)
	nodes = arr
	connections = new_conns
	return new_idx


## Wire `from`:`from_port` -> `to`:`to_port`. An input port takes ONE wire, so any existing wire into
## `(to, to_port)` is replaced.
##
## Returns false and changes NOTHING when the wire is not one this graph can hold: a node index or a port
## index that does not exist, or a pair of port types `Pasture3DGraphNode.can_connect` refuses. The editor
## already refused those by never offering them; this is the same rule for every other caller (a preset
## builder, a paste, a script), which used to be able to store a wire the editor would not draw.
func connect_ports(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> bool:
	if wire_problem(p_from, p_from_port, p_to, p_to_port) != "":
		return false
	# A multi port (§12) keeps every wire, appended last in its order; the same wire twice is one wire.
	var multi: bool = nodes[p_to].input_ports()[p_to_port].multi
	var arr: Array = []
	for c in connections:
		if int(c[2]) == p_to and int(c[3]) == p_to_port:
			if not multi:
				continue
			if int(c[0]) == p_from and int(c[1]) == p_from_port:
				return true
		arr.append(c)
	arr.append(PackedInt32Array([p_from, p_from_port, p_to, p_to_port]))
	connections = arr
	return true


## Why the wire `from`:`from_port` -> `to`:`to_port` cannot exist, or "" when it can. The ONE check:
## `connect_ports` refuses on it and `graph_warnings` reports every stored wire that fails it.
func wire_problem(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> String:
	if p_from < 0 or p_from >= nodes.size() or nodes[p_from] == null:
		return "its source node %d does not exist" % p_from
	if p_to < 0 or p_to >= nodes.size() or nodes[p_to] == null:
		return "its target node %d does not exist" % p_to
	var from_node: Pasture3DGraphNode = nodes[p_from]
	var to_node: Pasture3DGraphNode = nodes[p_to]
	var outs := from_node.output_ports()
	var ins := to_node.input_ports()
	if p_from_port < 0 or p_from_port >= outs.size():
		return "%s has no output %d" % [from_node.display_name(), p_from_port]
	if p_to_port < 0 or p_to_port >= ins.size():
		return "%s has no input %d" % [to_node.display_name(), p_to_port]
	if not Pasture3DGraphNode.can_connect(outs[p_from_port].type, ins[p_to_port].type):
		return "%s '%s' is %s and %s '%s' takes %s" % [
				from_node.display_name(), outs[p_from_port].label, Pasture3DGraphNode.port_type_name(outs[p_from_port].type),
				to_node.display_name(), ins[p_to_port].label, Pasture3DGraphNode.port_type_name(ins[p_to_port].type)]
	return ""


## True when the wire runs from a field output into a value input: the kind `connect_ports` refuses since
## spec §8 and that a graph may still hold from before. It evaluates as it always did, reading cell 0.
func wire_reads_cell_zero(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> bool:
	if p_from < 0 or p_from >= nodes.size() or nodes[p_from] == null:
		return false
	if p_to < 0 or p_to >= nodes.size() or nodes[p_to] == null:
		return false
	var outs := nodes[p_from].output_ports()
	var ins := nodes[p_to].input_ports()
	if p_from_port < 0 or p_from_port >= outs.size() or p_to_port < 0 or p_to_port >= ins.size():
		return false
	return Pasture3DGraphNode.reads_cell_zero(outs[p_from_port].type, ins[p_to_port].type)


## Remove exactly the wire `from`:`from_port` -> `to`:`to_port`, if present.
func disconnect_ports(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	var arr: Array = []
	for c in connections:
		if int(c[0]) == p_from and int(c[1]) == p_from_port \
				and int(c[2]) == p_to and int(c[3]) == p_to_port:
			continue
		arr.append(c)
	connections = arr


## Designate the graph's output node (-1 = none). Also toggles solo preview override.
func set_output(p_index: int) -> void:
	if p_index >= -1 and p_index < nodes.size():
		if output_override == p_index:
			output_override = -1
		else:
			output_override = p_index
		output_node = p_index


## Serializes a subset of nodes and their internal connecting wires into a clipboard dictionary.
func serialize_subgraph(p_indices: Array) -> Dictionary:
	var valid_indices: Array[int] = []
	for idx in p_indices:
		var i := int(idx)
		if i >= 0 and i < nodes.size() and nodes[i] != null and not valid_indices.has(i):
			valid_indices.append(i)
	if valid_indices.is_empty():
		return {"nodes": [], "wires": [], "center": Vector2.ZERO}
	
	var cloned_nodes: Array[Pasture3DGraphNode] = []
	var center_accum := Vector2.ZERO
	for i in valid_indices:
		var cloned: Pasture3DGraphNode = nodes[i].duplicate(true)
		cloned.graph_position = nodes[i].graph_position
		center_accum += nodes[i].graph_position
		cloned_nodes.append(cloned)
	var center := center_accum / float(valid_indices.size())
	
	var internal_wires: Array = []
	for c in connections:
		var f := int(c[0])
		var t := int(c[2])
		var local_f := valid_indices.find(f)
		var local_t := valid_indices.find(t)
		if local_f != -1 and local_t != -1:
			# By port id, like the file: a clipboard outlives the port list it was copied from.
			var outs: Array = nodes[f].output_ports()
			var ins: Array = nodes[t].input_ports()
			var fp := int(c[1])
			var tp := int(c[3])
			if fp >= 0 and fp < outs.size() and tp >= 0 and tp < ins.size():
				internal_wires.append([local_f, outs[fp].id, local_t, ins[tp].id])
			
	return {
		"nodes": cloned_nodes,
		"wires": internal_wires,
		"center": center,
	}


## Deserializes subgraph data into the graph. If `p_at_position` is provided, positions are offset relative
## to the data's center. Returns the newly created global node indices.
func deserialize_subgraph(p_data: Dictionary, p_at_position: Vector2 = Vector2.INF) -> Array[int]:
	var input_nodes: Array = p_data.get("nodes", [])
	var input_wires: Array = p_data.get("wires", [])
	var original_center: Vector2 = p_data.get("center", Vector2.ZERO)
	if input_nodes.is_empty():
		return []
	
	var offset := Vector2.ZERO
	if not is_inf(p_at_position.x) and not is_inf(p_at_position.y):
		offset = p_at_position - original_center
		
	var new_indices: Array[int] = []
	for n in input_nodes:
		if n is Pasture3DGraphNode:
			var cloned: Pasture3DGraphNode = n.duplicate(true)
			var new_pos: Vector2 = n.graph_position + offset
			var idx := add_node(cloned, new_pos)
			new_indices.append(idx)
			
	for w in input_wires:
		if w.size() >= 4:
			var local_f := int(w[0])
			var local_t := int(w[2])
			if local_f >= 0 and local_f < new_indices.size() and local_t >= 0 and local_t < new_indices.size():
				var nf := new_indices[local_f]
				var nt := new_indices[local_t]
				# An id the pasted node no longer declares resolves to -1, which `connect_ports` refuses.
				var fp := nodes[nf].output_index_of(StringName(w[1]))
				var tp := nodes[nt].input_index_of(StringName(w[3]))
				if wire_reads_cell_zero(nf, fp, nt, tp):
					# A copy of a wire the original already holds. Dropping it here would make Duplicate
					# quietly change what the copy evaluates to; it keeps its warning instead.
					var arr: Array = connections.duplicate()
					arr.append(PackedInt32Array([nf, fp, nt, tp]))
					connections = arr
				else:
					connect_ports(nf, fp, nt, tp)
				
	return new_indices


## Duplicates selected nodes and internal connecting wires by `p_offset`. Returns new global indices.
func duplicate_subgraph(p_indices: Array, p_offset: Vector2 = Vector2(40, 40)) -> Array[int]:
	var serialized := serialize_subgraph(p_indices)
	if serialized["nodes"].is_empty():
		return []
	for n in serialized["nodes"]:
		n.graph_position += p_offset
	return deserialize_subgraph(serialized, Vector2.INF)


# ---- Group / Ungroup (ports spec §11.5) -------------------------------------------------------------
#
# Both rebuild `nodes` and `connections` whole and assign each once, so the editor can take its undo as one
# snapshot of the two. Group COPIES the selection into a new child (the originals leave this graph); Ungroup
# copies the child's nodes back in. Neither shares a node object between two graphs.

static func _is_sink_node(p_n: Pasture3DGraphNode) -> bool:
	return p_n is Pasture3DGraphNodeChannelSink or p_n is Pasture3DGraphNodeExportSink \
			or p_n is Pasture3DGraphNodeRuntimeSink


static func _unique_id(p_base: String, p_taken: Dictionary) -> StringName:
	var id := p_base
	var k := 2
	while p_taken.has(StringName(id)):
		id = "%s_%d" % [p_base, k]
		k += 1
	p_taken[StringName(id)] = true
	return StringName(id)


## Move the nodes at `p_indices` into a new child graph and put one Subgraph node in their place. Every wire
## that crossed the selection's edge becomes a Subgraph Input (one per distinct outside source) or a Subgraph
## Output (one per distinct inside source), and is re-made through the Subgraph node's matching port, so the
## graph evaluates exactly as before. A Parameter node in the selection keeps reading the host: the child
## declares the same parameter, and a new Parameter node here feeds its port.
##
## Returns `{"index": the Subgraph node, "child": the graph, "notes": [...]}`, or `{"error": text}` and
## changes nothing. Refused: an Output, a sink or publish node, a subgraph boundary node, the designated
## output, and a crossing wire carrying a PATH or COLOR (§11.1 carries scalars only in this phase).
func group_into_subgraph(p_indices: Array) -> Dictionary:
	var sel: Array[int] = []
	for v in p_indices:
		var i := int(v)
		if i >= 0 and i < nodes.size() and nodes[i] != null and not sel.has(i):
			sel.append(i)
	sel.sort()
	if sel.is_empty():
		return {"error": "nothing selected to group"}
	for i in sel:
		var n: Pasture3DGraphNode = nodes[i]
		if n.op() == &"output":
			return {"error": "%s cannot go into a subgraph: the graph's output stays in the graph." % n.display_name()}
		if n.op() == &"subgraph_input" or n.op() == &"subgraph_output":
			return {"error": "%s is this graph's own boundary and cannot move into a child." % n.display_name()}
		if _is_sink_node(n):
			return {"error": "%s cannot go into a subgraph: sinks and publish nodes are refused there." % n.display_name()}
	if sel.has(output_node) or sel.has(output_override):
		return {"error": "the designated output is in the selection; set another output first."}

	var in_sel := {}
	for i in sel:
		in_sel[i] = true
	# The crossing sources, in wire order.
	var ins: Array = []   # Vector2i(outside node, port)
	var outs: Array = []  # Vector2i(inside node, port)
	for c in connections:
		if c.size() < 4:
			continue
		var f := int(c[0])
		var t := int(c[2])
		if in_sel.has(t) and not in_sel.has(f):
			var k := Vector2i(f, int(c[1]))
			if not ins.has(k):
				ins.append(k)
		elif in_sel.has(f) and not in_sel.has(t):
			var k := Vector2i(f, int(c[1]))
			if not outs.has(k):
				outs.append(k)
	for k: Vector2i in ins + outs:
		var t := _out_port_type(k.x, k.y)
		if not Pasture3DGraphNode.is_scalar_type(t):
			return {"error": "a wire from %s carries a %s, and a subgraph boundary carries scalars only." \
					% [nodes[k.x].display_name(), Pasture3DGraphNode.PortType.find_key(t)]}

	var notes := PackedStringArray()
	var child := Pasture3DTerrainGraph.new()
	child.format_version = FORMAT_CURRENT
	# Parameters the selection reads, declared the same way in the child.
	var pids: Array[StringName] = []
	var decls: Array[Pasture3DGraphParam] = []
	for i in sel:
		if nodes[i].op() == &"param":
			var pid: StringName = nodes[i].param_id
			var d := find_param(pid)
			if d != null and not pids.has(pid):
				pids.append(pid)
				decls.append(d.duplicate(true))
	var taken := {}
	for pid in pids:
		taken[pid] = true
	taken[Pasture3DGraphNode.MASK_PORT_ID] = true

	var center := Vector2.ZERO
	for i in sel:
		center += nodes[i].graph_position
	center /= float(sel.size())

	var cn: Array[Pasture3DGraphNode] = []
	var local := {}
	for i in sel:
		var d: Pasture3DGraphNode = nodes[i].duplicate(true)
		if d is Pasture3DGraphSolverNode and d.evaluation == Pasture3DGraphSolverNode.Evaluation.FROZEN:
			d.evaluation = Pasture3DGraphSolverNode.Evaluation.LIVE
			notes.append("%s was Frozen and is Live inside the subgraph: a solver inside a subgraph cannot be Frozen." \
					% nodes[i].display_name())
		local[i] = cn.size()
		cn.append(d)
	var min_x := INF
	var max_x := -INF
	for i in sel:
		min_x = minf(min_x, nodes[i].graph_position.x)
		max_x = maxf(max_x, nodes[i].graph_position.x)
	var in_local: Array = []
	for j in range(ins.size()):
		var k: Vector2i = ins[j]
		var sin := Pasture3DGraphNodeSubgraphInput.new()
		sin.input_id = _unique_id("in", taken)
		sin.port_type = _boundary_type(_out_port_type(k.x, k.y))
		sin.graph_position = Vector2(min_x - 260.0, center.y + 120.0 * j)
		in_local.append(cn.size())
		cn.append(sin)
	var out_local: Array = []
	for j in range(outs.size()):
		var k: Vector2i = outs[j]
		var sout := Pasture3DGraphNodeSubgraphOutput.new()
		sout.output_id = _unique_id("out", taken)
		sout.port_type = _boundary_type(_out_port_type(k.x, k.y))
		sout.graph_position = Vector2(max_x + 260.0, center.y + 120.0 * j)
		out_local.append(cn.size())
		cn.append(sout)
	var cc: Array = []
	for c in connections:
		if c.size() < 4:
			continue
		var f := int(c[0])
		var t := int(c[2])
		if in_sel.has(f) and in_sel.has(t):
			cc.append(PackedInt32Array([local[f], int(c[1]), local[t], int(c[3])]))
		elif in_sel.has(t):
			cc.append(PackedInt32Array([in_local[ins.find(Vector2i(f, int(c[1])))], 0, local[t], int(c[3])]))
	for j in range(outs.size()):
		var k: Vector2i = outs[j]
		cc.append(PackedInt32Array([local[k.x], k.y, out_local[j], 0]))
	child.parameters = decls
	child.nodes = cn
	child.connections = cc
	if not out_local.is_empty():
		child.output_node = out_local[0]

	var sub := Pasture3DGraphNodeSubgraph.new()
	sub.graph = child
	sub.graph_position = center
	# This graph's new node list: everything outside the selection, in order, then the Subgraph node, then
	# one Parameter node per parameter the child reads.
	var nn: Array[Pasture3DGraphNode] = []
	var remap := {}
	for i in range(nodes.size()):
		if not in_sel.has(i):
			remap[i] = nn.size()
			nn.append(nodes[i])
	var si := nn.size()
	nn.append(sub)
	var nc: Array = []
	for c in connections:
		if c.size() < 4:
			continue
		var f := int(c[0])
		var t := int(c[2])
		if not in_sel.has(f) and not in_sel.has(t):
			nc.append(PackedInt32Array([remap[f], int(c[1]), remap[t], int(c[3])]))
		elif in_sel.has(f) and not in_sel.has(t):
			nc.append(PackedInt32Array([si, outs.find(Vector2i(f, int(c[1]))), remap[t], int(c[3])]))
	for j in range(ins.size()):
		var k: Vector2i = ins[j]
		nc.append(PackedInt32Array([remap[k.x], k.y, si, j]))
	for j in range(pids.size()):
		var pn := Pasture3DGraphNodeParam.new()
		pn.param_id = pids[j]
		pn.graph_position = center + Vector2(-260.0, 120.0 * (ins.size() + j))
		nc.append(PackedInt32Array([nn.size(), 0, si, sub.input_index_of(pids[j])]))
		nn.append(pn)
	var keep_out := output_node
	var keep_ov := output_override
	for f in frames:
		if f != null:
			var att := PackedInt32Array()
			for idx in f.attached_node_indices:
				if remap.has(idx):
					att.append(remap[idx])
			f.attached_node_indices = att
	nodes = nn
	connections = nc
	output_node = remap.get(keep_out, -1) if keep_out >= 0 else keep_out
	output_override = remap.get(keep_ov, -1) if keep_ov >= 0 else keep_ov
	return {"index": si, "child": child, "notes": notes}


func _out_port_type(p_node: int, p_port: int) -> int:
	var ports: Array = nodes[p_node].output_ports()
	return ports[p_port].type if p_port >= 0 and p_port < ports.size() else Pasture3DGraphNode.PortType.HEIGHT


## The boundary node's type for a wire of type `p_type`: its own, all scalar types being available.
static func _boundary_type(p_type: int) -> int:
	return p_type


## Replace the Subgraph node at `p_index` with copies of its child's nodes, wired as the flattened view
## wires them (§11.2): a consumer of a Subgraph Input reads what fed the port (a Const of the input's
## default when nothing did), a child Parameter becomes what fed its port (a Const of this instance's value
## when nothing did), and a consumer of an output port reads what fed the matching Subgraph Output, through
## one Blend MIX when the standard mask is wired. Nested Subgraph nodes stay Subgraph nodes: one level per
## Ungroup. Returns the new nodes' indices, or [] and changes nothing.
func ungroup_subgraph(p_index: int) -> Array[int]:
	var none: Array[int] = []
	if p_index < 0 or p_index >= nodes.size() or nodes[p_index] == null or nodes[p_index].op() != &"subgraph":
		return none
	var sub: Pasture3DGraphNodeSubgraph = nodes[p_index]
	var child: Pasture3DTerrainGraph = sub.graph
	if child == null or not child.is_compatible():
		return none
	# What fed each of the Subgraph node's input ports, in THIS graph's numbering.
	var fed := {}
	for c in connections:
		if c.size() >= 4 and int(c[2]) == p_index:
			fed[int(c[3])] = Vector2i(int(c[0]), int(c[1]))

	var nn: Array[Pasture3DGraphNode] = []
	var remap := {}
	for i in range(nodes.size()):
		if i != p_index:
			remap[i] = nn.size()
			nn.append(nodes[i])
	# Child node -> what replaces it: a new index (copy or Const), or a redirect to a source here.
	var cidx := {}      # child index -> new node index
	var redirect := {}  # child index -> Vector2i(source here, port)
	var ccenter := Vector2.ZERO
	var counted := 0
	for n in child.nodes:
		if n != null:
			ccenter += n.graph_position
			counted += 1
	if counted > 0:
		ccenter /= float(counted)
	var shift := sub.graph_position - ccenter
	var param_ports := sub.child_param_ids()
	for ci in range(child.nodes.size()):
		var n: Pasture3DGraphNode = child.nodes[ci]
		if n == null or n.op() == &"output" or n.op() == &"subgraph_output" or _is_sink_node(n):
			continue
		var made: Pasture3DGraphNode = null
		if n.op() == &"subgraph_input":
			var port := sub.input_index_of(n.input_id)
			if fed.has(port):
				redirect[ci] = Vector2i(remap[fed[port].x], fed[port].y)
				continue
			made = _const_for(n.port_type, n.default_value)
		elif n.op() == &"param":
			var pid: StringName = n.param_id
			var decl := child.find_param(pid)
			var port := sub.input_index_of(pid) if param_ports.has(pid) else -1
			if fed.has(port):
				redirect[ci] = Vector2i(remap[fed[port].x], fed[port].y)
				continue
			if decl != null and decl.is_path():
				# An unwired PATH parameter has no number to bake into a constant. The closest standing node
				# is a Spline Source with the empty key: it reads this host's own spline child, which is what
				# the parameter read for a host that supplied nothing.
				var ss := Pasture3DGraphNodeSplineSource.new()
				ss.spline_index = decl.spline_index
				ss.sample_points = decl.sample_points
				ss.sample_interval = decl.sample_interval
				made = ss
			else:
				made = _const_for(decl.port_type() if decl != null else Pasture3DGraphNode.PortType.FLOAT,
						sub.param_number(pid) if decl != null else 0.0)
		elif n.op() == &"subgraph":
			made = n.duplicate(false)
			made.param_values = n.param_values.duplicate()
		else:
			made = n.duplicate(true)
		made.graph_position = n.graph_position + shift
		cidx[ci] = nn.size()
		nn.append(made)
	var src_of := func(ci: int, port: int) -> Vector2i:
		if redirect.has(ci):
			return redirect[ci]
		if cidx.has(ci):
			return Vector2i(cidx[ci], port)
		return Vector2i(-1, 0)
	var nc: Array = []
	var into_out := {} # child Subgraph Output index -> source here
	for c in connections:
		if c.size() >= 4 and int(c[0]) != p_index and int(c[2]) != p_index:
			nc.append(PackedInt32Array([remap[int(c[0])], int(c[1]), remap[int(c[2])], int(c[3])]))
	for c in child.connections:
		if c.size() < 4:
			continue
		var s: Vector2i = src_of.call(int(c[0]), int(c[1]))
		if s.x < 0:
			continue
		var t := int(c[2])
		if child.nodes[t] != null and child.nodes[t].op() == &"subgraph_output":
			into_out[t] = s
		elif cidx.has(t):
			nc.append(PackedInt32Array([s.x, s.y, cidx[t], int(c[3])]))
	# Output port k -> source here.
	var alias: Array = []
	for o in sub.child_outputs():
		alias.append(into_out.get(child.nodes.find(o), Vector2i(-1, 0)))
	var mp := sub.framework_mask_port()
	if mp >= 0 and fed.has(mp) and not alias.is_empty():
		var b := Pasture3DGraphNodeBlend.new()
		b.mode = Pasture3DGraphNodeBlend.Mode.MIX
		b.graph_position = sub.graph_position + Vector2(260.0, 0.0)
		var bi := nn.size()
		nn.append(b)
		if fed.has(0):
			nc.append(PackedInt32Array([remap[fed[0].x], fed[0].y, bi, 0]))
		if alias[0].x >= 0:
			nc.append(PackedInt32Array([alias[0].x, alias[0].y, bi, 1]))
		nc.append(PackedInt32Array([remap[fed[mp].x], fed[mp].y, bi, 2]))
		alias[0] = Vector2i(bi, 0)
	for c in connections:
		if c.size() >= 4 and int(c[0]) == p_index:
			var k := int(c[1])
			var s: Vector2i = alias[k] if k < alias.size() else Vector2i(-1, 0)
			if s.x >= 0:
				nc.append(PackedInt32Array([s.x, s.y, remap[int(c[2])], int(c[3])]))
	var made_idx: Array[int] = []
	for i in range(nodes.size() - 1, nn.size()):
		made_idx.append(i)
	var keep_out := output_node
	var keep_ov := output_override
	var a0: Vector2i = alias[0] if not alias.is_empty() else Vector2i(-1, 0)
	for f in frames:
		if f != null:
			var att := PackedInt32Array()
			for idx in f.attached_node_indices:
				if remap.has(idx):
					att.append(remap[idx])
			f.attached_node_indices = att
	nodes = nn
	connections = nc
	output_node = (a0.x if a0.y == 0 else -1) if keep_out == p_index else int(remap.get(keep_out, keep_out))
	output_override = (a0.x if a0.y == 0 else -1) if keep_ov == p_index else int(remap.get(keep_ov, keep_ov))
	return made_idx


## A Const node of the right flavour for a value of type `p_type`.
static func _const_for(p_type: int, p_value: float) -> Pasture3DGraphNode:
	if p_type == Pasture3DGraphNode.PortType.INT:
		var ci := Pasture3DGraphNodeConstInt.new()
		ci.value = int(round(p_value))
		return ci
	if p_type == Pasture3DGraphNode.PortType.BOOL:
		var cb := Pasture3DGraphNodeConstBool.new()
		cb.value = p_value != 0.0
		return cb
	var c := Pasture3DGraphNodeConst.new()
	c.value = p_value
	return c



## The EFFECTIVE output node the evaluator returns: an explicit solo override (if set), else an explicit
## Output node (op &"output"), else the designated `output_node`.
func output_index() -> int:
	# A refused graph has no output. Every "is there anything to run" test in the plugin asks this, the
	# host's `is_active` included, so answering -1 here is what takes the graph out of a brush's stack.
	if not is_compatible():
		return -1
	if output_override >= 0 and output_override < nodes.size() and nodes[output_override] != null:
		return output_override
	for i in range(nodes.size()):
		if nodes[i] != null and nodes[i].op() == &"output":
			return i
	return output_node


## True when the graph returns its input unchanged: nothing but Input and Output nodes, the Output fed by an
## Input. Composited, that is `z + (z - z) * mask = z` whatever the strength, feather or blend, so a host
## drops it from the stack instead of deferring, solving and repainting a no-op (demo island, 2026-10-26:
## an accidental Input -> Output graph made every member edit a two-pass deferred run).
func is_identity() -> bool:
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null or nodes[out].muted:
		return false
	for nd in nodes:
		if nd != null and nd.op() != &"input" and nd.op() != &"output":
			return false
	for c in connections:
		if c.size() >= 4 and int(c[2]) == out and int(c[3]) == 0:
			var src := int(c[0])
			return (src >= 0 and src < nodes.size() and nodes[src] != null
					and nodes[src].op() == &"input" and int(c[1]) == 0)
	return false


## True when an Input node feeds the output — the graph is a FILTER whose result depends on the surface it
## is handed, not a pure generator. A host reads this to decide whether its frozen cache must key on that
## surface: an Input-reading graph re-evaluates when the surface changes, a generator does not.
## The host brush's footprint, stamped by the host on every bake: the 0..1 mask its graph step composites
## through (feather and Modifier Margin included), `{grid, gw, gh, rect}`. Runtime only, never saved. Every
## compile carries it, so the native evaluator, the deferred worker, the sink pass and the editor preview all
## read the Input node's footprint pin from the same mask. Empty = no host, which reads 1.0 everywhere.
var host_footprint: Dictionary = {}


func set_host_footprint(p_grid: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> void:
	if p_gw <= 0 or p_gh <= 0 or p_grid.size() != p_gw * p_gh:
		host_footprint = {}
		return
	host_footprint = {"grid": p_grid, "gw": p_gw, "gh": p_gh, "rect": p_rect}


## True when some node reads an Input node's footprint pin (channel 1).
func reads_footprint() -> bool:
	if not is_compatible():
		return false
	if needs_flat():
		return flat_view().reads_footprint()
	for c in connections:
		if c.size() >= 4 and int(c[1]) == 1:
			var from := int(c[0])
			if from >= 0 and from < nodes.size() and nodes[from] != null and nodes[from].op() == &"input":
				return true
	return false


## The largest `outward_reach()` of any unmuted node: how far past the host brush's outline this graph
## writes at full strength. See Pasture3DGraphNode.outward_reach.
func outward_reach() -> float:
	if not is_compatible():
		return 0.0
	if needs_flat():
		return flat_view().outward_reach()
	var r := 0.0
	for node in nodes:
		if node != null and not node.muted:
			r = maxf(r, node.outward_reach())
	return r


## How far, in metres, an edit to the host brush can spread through this graph to its output: the longest
## chain of `edit_reach()` from any node to the output, summed (a node's own reach adds to the furthest of
## its inputs'). A muted node passes its input through and adds nothing. INF as soon as any node on the
## chain is INF, and 0 for a graph with no usable output (a flat field cannot move).
func edit_reach() -> float:
	if needs_flat() and is_compatible():
		return flat_view().edit_reach()
	var order := _eval_order()
	if order.is_empty():
		return 0.0
	var acc := {}
	for ni: int in order:
		var upstream := 0.0
		for c in connections:
			if c.size() >= 4 and int(c[2]) == ni and acc.has(int(c[0])):
				upstream = maxf(upstream, float(acc[int(c[0])]))
		var node: Pasture3DGraphNode = nodes[ni]
		acc[ni] = upstream + (0.0 if node.muted else node.edit_reach())
	return float(acc.get(output_index(), 0.0))


## The footprint pin over `p_rect` at `p_gw` x `p_gh`: nearest footprint cell to each cell centre, 0 outside
## the footprint's rect, 1.0 everywhere when there is none. The oracle for graph_footprint_fill.
static func footprint_grid(p_fp: Dictionary, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var fg: PackedFloat32Array = p_fp.get("grid", PackedFloat32Array())
	var fgw: int = int(p_fp.get("gw", 0))
	var fgh: int = int(p_fp.get("gh", 0))
	if fgw <= 0 or fgh <= 0 or fg.size() != fgw * fgh:
		return Pasture3DGraphOps.filled(n, 1.0)
	var fr: Rect2 = p_fp["rect"]
	var fdx: float = fr.size.x / float(fgw)
	var fdz: float = fr.size.y / float(fgh)
	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var out := PackedFloat32Array()
	out.resize(n)
	for iz in range(p_gh):
		var wz: float = p_rect.position.y + (float(iz) + 0.5) * dz
		var v: float = floorf((wz - fr.position.y) / fdz)
		for ix in range(p_gw):
			var wx: float = p_rect.position.x + (float(ix) + 0.5) * dx
			var u: float = floorf((wx - fr.position.x) / fdx)
			var val := 0.0
			if u >= 0.0 and v >= 0.0 and u < float(fgw) and v < float(fgh):
				val = fg[int(v) * fgw + int(u)]
				if not is_finite(val):
					val = 0.0
			out[iz * p_gw + ix] = val
	return out


func _footprint_sig() -> int:
	if host_footprint.is_empty() or not reads_footprint():
		return 0
	return hash([_content_sig(host_footprint["grid"]), host_footprint["gw"], host_footprint["gh"], host_footprint["rect"]])


## Stamp the footprint onto a compiled program. Both compilers call it, so no program leaves without it.
func _with_footprint(p_prog: Dictionary) -> Dictionary:
	if not host_footprint.is_empty():
		p_prog["footprint"] = host_footprint["grid"]
		p_prog["footprint_gw"] = host_footprint["gw"]
		p_prog["footprint_gh"] = host_footprint["gh"]
		p_prog["footprint_rect"] = host_footprint["rect"]
	return p_prog


func reads_input() -> bool:
	if needs_flat() and is_compatible():
		return flat_view().reads_input()
	for ni in _eval_order():
		if nodes[ni] != null and nodes[ni].op() == &"input":
			return true
	return false


## A fresh graph pre-populated with an Input → Output pair, wired together — the standard starting point a
## host hands the user instead of a blank canvas. As built it is the IDENTITY (Output passes the surface
## straight through), so it changes nothing until nodes are inserted between the two. Laid out left-to-right
## so the Add-node flow drops new nodes into the gap.
static func create_default() -> Pasture3DTerrainGraph:
	var g := create_empty()
	var input := Pasture3DGraphNodeInput.new()
	input.graph_position = Vector2(40.0, 80.0)
	var output := Pasture3DGraphNodeOutput.new()
	output.graph_position = Vector2(420.0, 80.0)
	var nodes: Array[Pasture3DGraphNode] = [input, output]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])] # Input.out -> Output.result
	return g


## Map a cell to its WORLD XZ. Cell-CENTRE sampling over `p_rect` (position = min XZ, size = extent).
## Static so the graph and any oracle sample the identical point — a mapping disagreement would look like
## a solver bug. `dx = size / count`, `w = min + (i + 0.5) * dx`.
static func cell_to_world(p_ix: int, p_iz: int, p_gw: int, p_gh: int, p_rect: Rect2) -> Vector2:
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	return Vector2(p_rect.position.x + (float(p_ix) + 0.5) * dx,
			p_rect.position.y + (float(p_iz) + 0.5) * dz)


## Evaluate the graph to a `p_gw * p_gh` row-major height field over `p_rect` (world XZ). `p_mask` is an
## optional [0,1] grid handed to grid nodes; it is NOT applied globally — where a graph's result lands is
## the host's concern. A missing output or a cycle yields a flat 0 field.
##
## Uses the CELL-NODE FOLD: a run of cell nodes is evaluated INLINE in one loop rather than materialising
## a grid per node — the same optimisation the brush node stack makes. Only a grid node, the OUTPUT, a
## node that fans out to more than one consumer, and a node feeding a grid node get a materialised grid; a
## cell node consumed once by another cell node folds into that consumer's loop, saving an allocation and
## a pass. `_eval_unfolded` is the reference this matches (to float32 rounding — the fold keeps
## intermediates in double, so it is in fact slightly more accurate); GraphFoldGate holds the two together.
func evaluate(p_gw: int, p_gh: int, p_rect: Rect2, p_mask = null, p_input = null, p_root_node: int = -1) -> PackedFloat32Array:
	evaluate_count += 1
	# NO Pasture3DTerrainGraph METHOD MAY BE CALLED OFF THE MAIN THREAD, and this is where that is
	# enforced rather than documented. evaluate() mutates the shared resource on BOTH of its routes --
	# store_cache below, _global_access_tick, each node's _last_access_tick, _evict_cache_if_needed -- so
	# a worker calling it races any main-thread edit of graph.nodes or graph.connections: concurrent
	# refcount traffic on the same Array and Dictionary, which surfaces as an out-of-range index, a
	# corrupted cache grid, or an editor crash. The contract is compile here, solve there: hand a worker
	# compile_graph_program()'s output and let it call the stateless Pasture3DUtil.graph_eval_grid.
	#
	# Returns zeros rather than half-evaluating, so a caller that ignores the error still gets a defined
	# grid instead of a race.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		push_error("Pasture3DTerrainGraph.evaluate() called off the main thread. Compile on the main "
				+ "thread with compile_graph_program() and solve with Pasture3DUtil.graph_eval_grid.")
		return Pasture3DGraphOps.zeros(p_gw * p_gh)
	# An explicit root would otherwise walk past `output_index`'s refusal.
	if not is_compatible():
		return Pasture3DGraphOps.zeros(p_gw * p_gh)
	if needs_flat():
		# §11.2: the flat view runs it. Its counters are the flat view's; the ones a caller reads are here.
		var fv := flat_view()
		var froot := _flat_root(p_root_node)
		if froot == FLAT_NO_ROOT:
			return Pasture3DGraphOps.zeros(p_gw * p_gh)
		var staged0 := fv.staged_compile_count
		var res := fv.evaluate(p_gw, p_gh, p_rect, p_mask, p_input, froot)
		staged_compile_count += fv.staged_compile_count - staged0
		return res
	var n := p_gw * p_gh
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return Pasture3DGraphOps.zeros(n)

	# 0. The staged compile (spec 8.4, S7b). A graph whose ONLY native blocker is the derive family is
	# cut at those nodes: each one's grid inputs are evaluated first -- natively, if they lower -- and
	# handed to it, which produces its path; then the whole program is compiled with those paths in the
	# geometry table and the derive nodes lowered to CONST like every other PATH producer.
	#
	# This runs BEFORE the native check rather than inside it because it is the thing that makes the
	# native check true. `native_supported(out)` is still false here and still should be: it answers
	# "can this be compiled once and handed to a worker", and the capture is a main-thread, evaluate-time
	# event. `_stage_derives` is what changes the answer, and only for this call.
	if _native_supported_if_staged(out) and ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		if _stage_derives(out, p_gw, p_gh, p_rect, p_mask, p_input):
			var sprog: Dictionary = compile_graph_program(out)
			if not sprog.is_empty():
				var s_in := _surface_grid(p_input, n)
				var sfield: PackedFloat32Array = _native_eval(sprog, p_gw, p_gh, p_rect, s_in)
				if not sfield.is_empty() and sfield.size() == n:
					staged_compile_count += 1
					# No `store_cache` here, unlike the single-program path below. A derive node's answer
					# depends on a grid, and `_compute_node_inputs_hash` folds in the graph's parameters
					# and the input surface -- not the FIELD a stage produced. Keying a cache on
					# something that does not describe what is in it is how a stale paint ships
					# (`cache-key-the-output-not-the-input`), so the staged route recomputes, which is
					# slower than it could be and never wrong. S7b's cost win is the kernel, not a skip.
					return sfield

	# 1. Native C++ Whole-Graph Acceleration Path
	if native_supported(out) and ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		var prog: Dictionary = compile_graph_program(out)
		if not prog.is_empty():
			var in_surf := _surface_grid(p_input, n)
			var field: PackedFloat32Array = _native_eval(prog, p_gw, p_gh, p_rect, in_surf)
			if not field.is_empty() and field.size() == n:
				# The bake does not touch 2D node previews. The graph editor owns previews end to end,
				# rendering them off the main thread from its own single low-res tap pass (see graph_editor.gd).
				# The native call returns port 0 and nothing else, so it has no auxiliary channels to
				# store. It used to store `{}` for them anyway, which does not mean "unknown" to
				# `get_cached_aux()` — it means "there are none": a later cache hit then handed every
				# downstream `_read_channel` on port >= 1 a zero grid. A multi-output node as the graph
				# output therefore does not get a native-path cache entry at all; the next evaluate
				# recomputes it, which is slower and true, and the GDScript path at line 695 below still
				# fills both halves properly.
				#
				# The key gets the real dependency maps for the same reason it does there. With `{}` for
				# both, the per-port loop inside `_compute_node_inputs_hash` never ran and the key
				# encoded nothing about the graph that produced the grid — only its dimensions, rect,
				# muted flag and op. `_fold_plan` is topology-only and served from `_fold_cache`, so
				# asking for it here costs nothing after the first call.
				var single_output: bool = nodes[out].output_count() <= 1
				if (p_root_node < 0 or p_root_node == output_index()) and single_output:
					var plan_n: Dictionary = _fold_plan(out)
					nodes[out].store_cache(field, {}, _compute_node_inputs_hash(out, p_gw, p_gh, p_rect, p_mask, p_input, plan_n["inputs_of"], plan_n["input_ports_of"], _content_sig(p_input), _content_sig(p_mask)), _global_access_tick)
				return field

	# 2. GDScript Folded / Multi-Channel Evaluation Reference Path
	var plan := _fold_plan(out)
	var order: Array = plan["order"]
	if order.is_empty(): # unreachable output or a cycle
		return Pasture3DGraphOps.zeros(n)
	var inputs_of: Dictionary = plan["inputs_of"]
	var input_ports_of: Dictionary = plan["input_ports_of"]
	# `plan["materialize"]` is deliberately NOT read here. The documented cell-node fold — evaluate a
	# non-grid node per cell instead of allocating a grid for it — is not wired up: this loop materialises
	# every node, and `{}` was already being passed everywhere the plan would have been consumed, so the
	# local below it was dead. Leaving the plan built and unused is cheap (it is topology-only and
	# `_fold_cache`d) and it is what a future fold would consume; reading it into a variable nobody uses
	# only made the fold look implemented. See PASTURE3D_TERRAIN_GRAPH_SPEC.md, "cell-node fold", and
	# §4.1 — every node materialising a grid is what makes that ceiling arrive sooner.

	_global_access_tick += 1
	# Once per evaluate, not once per node: every node's signature folds in the same two arrays.
	var surf_sig := hash([_content_sig(p_input), _footprint_sig()])
	var mask_sig := _content_sig(p_mask)

	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz

	var grids := {} # node index -> materialised grid (port 0)
	var aux := {}   # node index -> { output_port >= 1 : grid } for multi-output solver channels
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var inputs_hash: int = _compute_node_inputs_hash(ni, p_gw, p_gh, p_rect, p_mask, p_input, inputs_of, input_ports_of, surf_sig, mask_sig)

		# Cache hit check: if clean and matching size, serve cached grid in 0.0 ms
		if not node.is_dirty(inputs_hash) and node.get_cached_grid().size() == n:
			grids[ni] = node.get_cached_grid()
			var c_aux := node.get_cached_aux()
			if not c_aux.is_empty():
				aux[ni] = c_aux
			node._last_access_tick = _global_access_tick
			continue

		if node.muted:
			var s0: int = inputs_of[ni][0] if not inputs_of[ni].is_empty() else -1
			var sp0: int = input_ports_of[ni][0] if not input_ports_of[ni].is_empty() else 0
			if s0 < 0:
				grids[ni] = Pasture3DGraphOps.zeros(n)
			elif sp0 > 0 or grids.has(s0):
				grids[ni] = _read_channel(s0, sp0, grids, aux, n).duplicate()
			else:
				var g := PackedFloat32Array()
				g.resize(n)
				var cell_in := PackedFloat32Array()
				cell_in.resize(8)
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var wx: float = min_x + float(ix) * dx
						g[row + ix] = _cell_value_fast(s0, row + ix, wx, wz, grids, aux, inputs_of, input_ports_of, cell_in)
				grids[ni] = g
		elif node.op() == &"input":
			grids[ni] = _surface_grid(p_input, n) # the surface handed in, or a flat 0 when none
			if reads_footprint():
				aux[ni] = {1: footprint_grid(host_footprint, p_gw, p_gh, p_rect)}
		elif node.op() == &"output":
			var s0: int = inputs_of[ni][0] if not inputs_of[ni].is_empty() else -1
			var sp0: int = input_ports_of[ni][0] if not input_ports_of[ni].is_empty() else 0
			grids[ni] = _read_channel(s0, sp0, grids, aux, n).duplicate()
		elif node.op() == &"noise_jordan" or node.op() == &"noise_swiss" or node.op() == &"furrows" or node.op() == &"dunes" or node.op() == &"fractal":
			var in_grids := _input_grids(ni, grids, aux, n, p_input)
			grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
		elif node.needs_grid():
			var in_grids := _input_grids(ni, grids, aux, n, p_input)
			if node.reads_paths():
				node.set_path_inputs(_path_inputs(ni, inputs_of))
			if node.output_count() > 1:
				var chans: Array = node.eval_grid_channels(in_grids, p_gw, p_gh, p_mask, p_rect)
				grids[ni] = chans[0]
				var ax := {}
				for pi in range(1, chans.size()):
					ax[pi] = chans[pi]
				aux[ni] = ax
			else:
				grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
		else:
			var g := PackedFloat32Array()
			g.resize(n)
			var in_grids := _input_grids(ni, grids, aux, n, p_input)
			var in_count: int = in_grids.size()
			var cell_in := PackedFloat32Array()
			cell_in.resize(in_count)
			if in_count == 1:
				var in0: PackedFloat32Array = in_grids[0]
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var idx := row + ix
						var wx: float = min_x + float(ix) * dx
						cell_in[0] = in0[idx]
						g[idx] = node.eval_cell(wx, wz, cell_in)
			elif in_count == 0:
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var idx := row + ix
						var wx: float = min_x + float(ix) * dx
						g[idx] = node.eval_cell(wx, wz, cell_in)
			else:
				# Only ports WIRED to an upstream node vary per cell. An unwired port is a constant fill
				# (see _input_grids), so re-reading one per cell fetched the same number n times through a
				# Variant cast. Terrace is the common shape and the reason this matters: one wired surface
				# and three unwired parameter sockets, i.e. three quarters of the per-cell work was
				# re-reading constants. Hoist them, and loop only over what actually varies.
				#
				# A port BEYOND the connection list is treated as varying, not constant: with no source
				# recorded for it there is no proof its grid is a fill, and calling it constant would
				# silently flatten a real one.
				var srcs_c: Array = inputs_of[ni]
				var vary_ports := PackedInt32Array()
				var vary_grids: Array = []
				for p in range(in_count):
					var gp: PackedFloat32Array = in_grids[p]
					if p < srcs_c.size() and int(srcs_c[p]) < 0:
						cell_in[p] = gp[0] if not gp.is_empty() else 0.0
					else:
						vary_ports.append(p)
						vary_grids.append(gp)
				var vary_count := vary_ports.size()
				if vary_count == 1:
					var vp: int = vary_ports[0]
					var vg: PackedFloat32Array = vary_grids[0]
					for iz in range(p_gh):
						var row := iz * p_gw
						var wz: float = min_z + float(iz) * dz
						for ix in range(p_gw):
							var idx := row + ix
							var wx: float = min_x + float(ix) * dx
							cell_in[vp] = vg[idx]
							g[idx] = node.eval_cell(wx, wz, cell_in)
				else:
					for iz in range(p_gh):
						var row := iz * p_gw
						var wz: float = min_z + float(iz) * dz
						for ix in range(p_gw):
							var idx := row + ix
							var wx: float = min_x + float(ix) * dx
							for p in range(vary_count):
								cell_in[vary_ports[p]] = (vary_grids[p] as PackedFloat32Array)[idx]
							g[idx] = node.eval_cell(wx, wz, cell_in)
			grids[ni] = g

		grids[ni] = _with_standard_mask(ni, grids[ni], grids, aux, n)

		# The bake does not touch 2D node previews — the graph editor owns them (see the note above).
		if p_root_node < 0 or p_root_node == output_index():
			node.store_cache(grids[ni], aux.get(ni, {}), inputs_hash, _global_access_tick)
			_evict_cache_if_needed()

	return grids[out]


## The PATH resources wired into `p_ni`, in input port order, with null for a port that is unwired or
## wired to a node that produces no path.
##
## The PATH SIDEBAND. Every other port carries a grid, because every other port is a field; a road is a
## centreline and a width, and rasterising it into a grid to send it down a wire would fix its resolution
## at the wire rather than at the consumer and throw away the arc length. So the resource travels beside
## the grids, the same way a multi-output solver's channels already travel beside them in `aux`.
##
## Read from the SOURCE NODE rather than from a value the source produced, which is the one thing worth
## being careful about: it means a path is identified by the node that made it, and a stale path can only
## come from a stale node. Cache invalidation then needs nothing new — `_append_input_signature`
## already folds a source's `_dirty_revision` into its consumer's hash, and a Road Source re-emits
## `changed` when its path resource does.
##
## Since S4 the source is asked through `_resolved_path_of` rather than for `path_output()` directly, so a
## FILTER between the source and here contributes its work. Both routes into the geometry go through that
## one resolver deliberately: this is the GDScript evaluator's hand-off and `_path_operand_of` is the
## native compile's, and when they disagreed about which path a node sees, the two evaluators would carve
## different terrain from one graph — the class of bug `[Dev/GD]` twins exist to catch and would then be
## measuring the wrong thing.
func _path_inputs(p_ni: int, p_inputs_of: Dictionary) -> Array:
	var out: Array = []
	var k := 0
	for s_i in p_inputs_of.get(p_ni, []):
		var src: int = s_i
		k += 1
		if src < 0:
			out.append(nodes[p_ni].unwired_path(k - 1))
		elif src >= nodes.size() or nodes[src] == null:
			out.append(null)
		else:
			out.append(_resolved_path_of(src, p_inputs_of))
	return out


## A content signature for one of the arrays handed to `evaluate`: its hash, or 0 when it is not a
## grid at all. Separated out so both the native and the folded path identify a surface the same way.
func _content_sig(p_arr) -> int:
	if p_arr is PackedFloat32Array and not (p_arr as PackedFloat32Array).is_empty():
		return hash(p_arr)
	return 0


## Computes a signature hash representing node inputs, wiring, and spatial evaluation context.
func _compute_node_inputs_hash(p_ni: int, p_gw: int, p_gh: int, p_rect: Rect2, p_mask, p_input, p_inputs_of: Dictionary, p_input_ports_of: Dictionary, p_surf_sig: int = 0, p_mask_sig: int = 0) -> int:
	var node: Pasture3DGraphNode = nodes[p_ni]
	var sig: Array = [
		p_gw,
		p_gh,
		p_rect.position.x,
		p_rect.position.y,
		p_rect.size.x,
		p_rect.size.y,
		node.muted,
		node.op(),
	]
	# The surface and the mask are identified by CONTENT. This used to sample size, cell 0 and cell n-1,
	# which is not an identity: two genuinely different surfaces agreeing on their first and last cell
	# read as the same input, and the cache served one node's result for the other. A brush edit in the
	# middle of a region is exactly that shape — the corners do not move. Hashing the whole array is
	# cheap here because the caller computes it ONCE per evaluate and passes it in, rather than once per
	# node; see p_surf_sig / p_mask_sig.
	if node.op() == &"input":
		sig.append(p_surf_sig)
	# A Parameter node's value moves without its `_dirty_revision` moving (a host's stamp emits nothing, see
	# Pasture3DGraphNodeParam), so the VALUE is in the key. Every consumer folds this node's hash into its
	# own, which is how the change reaches a cached grid three nodes downstream.
	if node.op() == &"param":
		sig.append(node.value_signature())
	if node.needs_grid() and p_mask != null:
		sig.append(p_mask_sig)

	var srcs: Array = p_inputs_of.get(p_ni, [])
	var ports: Array = p_input_ports_of.get(p_ni, [])
	for p in range(srcs.size()):
		var s: int = srcs[p]
		var sp: int = ports[p]
		if s < 0 or s >= nodes.size() or nodes[s] == null:
			sig.append(-1)
			sig.append(node.input_unwired_default(p))
		else:
			_append_input_signature(s, sp, sig)
	return hash(sig)


func _append_input_signature(p_s: int, p_sp: int, p_sig: Array) -> void:
	if p_s < 0 or p_s >= nodes.size() or nodes[p_s] == null:
		p_sig.append(-1)
		return
	var src_node: Pasture3DGraphNode = nodes[p_s]
	p_sig.append(p_s)
	p_sig.append(p_sp)
	p_sig.append(src_node.muted)
	p_sig.append(src_node._dirty_revision)
	# Every node materialises (see `evaluate`), so the source's own `_inputs_hash` is always the right
	# signature. This used to branch on a `p_materialize` dictionary that every caller passed as `{}`,
	# whose `else` recursed into the folded node's inputs — unreachable code for the fold that was never
	# wired. It comes back with the fold, not before it.
	p_sig.append(src_node._inputs_hash)


func _cell_value_fast(p_ni: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary, p_aux: Dictionary,
		p_inputs_of: Dictionary, p_ports_of: Dictionary, p_cell_in: PackedFloat32Array) -> float:
	if p_grids.has(p_ni):
		return (p_grids[p_ni] as PackedFloat32Array)[p_cell]
	var node: Pasture3DGraphNode = nodes[p_ni]
	var srcs: Array = p_inputs_of[p_ni]
	var ports: Array = p_ports_of[p_ni]
	if node.muted:
		if srcs.is_empty() or srcs[0] < 0:
			return 0.0
		return _cell_input(srcs[0], ports[0], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	for k in range(srcs.size()):
		if srcs[k] < 0:
			p_cell_in[k] = node.input_unwired_default(k)
		else:
			p_cell_in[k] = _cell_input(srcs[k], ports[k], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	return node.eval_cell(p_wx, p_wz, p_cell_in)




## The grid an Input node yields: a COPY of the surface handed to `evaluate`, or a flat 0 when none was
## (or its size does not match the grid). Copied so a downstream grid node mutating it in place cannot
## corrupt the host's working surface.
func _surface_grid(p_input, p_n: int) -> PackedFloat32Array:
	if p_input is PackedFloat32Array and (p_input as PackedFloat32Array).size() == p_n:
		return (p_input as PackedFloat32Array).duplicate()
	return Pasture3DGraphOps.zeros(p_n)


## A cell node's value at one cell, folding unmaterialised cell inputs inline. A materialised node (a grid
## node, or a materialised cell node) is read from its grid; a folded input recurses. `p_cell` is the
## row-major index; `p_wx`/`p_wz` the world XZ.
func _cell_value(p_ni: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary, p_aux: Dictionary,
		p_inputs_of: Dictionary, p_ports_of: Dictionary) -> float:
	if p_grids.has(p_ni):
		return (p_grids[p_ni] as PackedFloat32Array)[p_cell]
	var node: Pasture3DGraphNode = nodes[p_ni]
	var srcs: Array = p_inputs_of[p_ni]
	var ports: Array = p_ports_of[p_ni]
	if node.muted:
		if srcs.is_empty() or srcs[0] < 0:
			return 0.0
		return _cell_input(srcs[0], ports[0], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	var cell_in := PackedFloat32Array()
	cell_in.resize(srcs.size())
	for k in range(srcs.size()):
		if srcs[k] < 0:
			cell_in[k] = node.input_unwired_default(k)
		else:
			cell_in[k] = _cell_input(srcs[k], ports[k], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	return node.eval_cell(p_wx, p_wz, cell_in)


## One input value at a cell: an unwired source reads 0; a port >= 1 reads a materialised multi-output
## channel directly out of `p_aux`; a port-0 source recurses (folding an unmaterialised cell run inline, or
## reading a materialised source's primary grid).
func _cell_input(p_src: int, p_port: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary,
		p_aux: Dictionary, p_inputs_of: Dictionary, p_ports_of: Dictionary) -> float:
	if p_src < 0:
		return 0.0
	if p_port > 0:
		if p_aux.has(p_src) and (p_aux[p_src] as Dictionary).has(p_port):
			return (p_aux[p_src][p_port] as PackedFloat32Array)[p_cell]
		return 0.0
	return _cell_value(p_src, p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)


## The fold plan for the output's ancestry: the topo `order`, each node's input source per port
## (`inputs_of`, -1 = unwired), and which nodes MATERIALISE (`materialize`). A node materialises if it is a
## grid node, the output, fans out to more than one consumer, or feeds a grid node; every other cell node
## folds. Exposed for GraphFoldGate.
func _fold_plan(p_root: int = -1) -> Dictionary:
	var out := p_root if (p_root >= 0 and p_root < nodes.size()) else output_index()
	# Topology-only result — served from cache until `structure_changed` clears it. Read-only for callers.
	if _fold_cache.has(out):
		return _fold_cache[out]
	var order := _eval_order(out)
	var needed := {}
	for ni in order:
		needed[ni] = true
	var inputs_of := {}
	var input_ports_of := {}
	for ni in order:
		var arr: Array = []
		arr.resize(nodes[ni].input_count())
		arr.fill(-1)
		inputs_of[ni] = arr
		var parr: Array = []
		parr.resize(nodes[ni].input_count())
		parr.fill(0)
		input_ports_of[ni] = parr
	for c in connections:
		if c.size() >= 4:
			var to := int(c[2])
			var from := int(c[0])
			if needed.has(to) and needed.has(from):
				var tp := int(c[3])
				if tp >= 0 and tp < (inputs_of[to] as Array).size():
					inputs_of[to][tp] = from
					input_ports_of[to][tp] = int(c[1])
	var fanout := {}
	var grid_consumer := {}
	for ni in order:
		fanout[ni] = 0
		grid_consumer[ni] = false
	for ni in order:
		for s in inputs_of[ni]:
			if s >= 0 and needed.has(s):
				fanout[s] += 1
				if nodes[ni].needs_grid():
					grid_consumer[s] = true
	var materialize := {}
	for ni in order:
		materialize[ni] = nodes[ni].needs_grid() or ni == out \
				or fanout[ni] > 1 or grid_consumer[ni]
	var plan := {"order": order, "inputs_of": inputs_of, "input_ports_of": input_ports_of,
			"materialize": materialize}
	_fold_cache[out] = plan
	return plan


## Lower a CELL-ONLY graph into the flat SSA program the native evaluator reads
## (Pasture3DUtil.graph_cell_eval_grid; C++ side pasture_3d_graph_ops). One instruction per node in
## topological order, so an instruction's inputs are always lower-numbered slots. Returns {} — meaning
## "not lowerable, stay on the GDScript path" — when the output is missing, its ancestry has a cycle, or it
## contains ANY grid node (a neighbour-reading pass like Smooth cannot fold into a per-cell loop). That is
## exactly the fold's cell-run scope (§6): the native path optimises the cell runs, and `evaluate` remains
## the oracle it must match. A node whose op the native evaluator does not know also returns {} rather than
## a program the two sides would read differently.
##
## Program keys, all parallel and one entry per slot except `output`:
##   ops     [int]   GraphCellOpType — 1 noise, 2 const, 3 blend (a WIRE FORMAT shared with C++)
##   params  [float] one scalar per slot: amplitude (noise) / value (const) / mode (blend)
##   in_a    [int]   input-A source slot, or -1 for an unwired port (reads 0)
##   in_b    [int]   input-B source slot (blend only), or -1
##   noise   [Variant] the slot's FastNoiseLite (noise ops) or null — passed as-is, never rebuilt, so the
##                   two evaluators cannot disagree on the noise
##   output  int     the slot whose value is the graph output
func compile_cell_program() -> Dictionary:
	if needs_flat() and is_compatible():
		return flat_view().compile_cell_program()
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {}
	var order := _eval_order()
	if order.is_empty():
		return {}
	var slot_of := {}
	for k in range(order.size()):
		slot_of[order[k]] = k
	var inputs_of: Dictionary = _fold_plan()["inputs_of"] # node -> [source node per port, -1 unwired]
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var in_a := PackedInt32Array()
	var in_b := PackedInt32Array()
	var noise_tab: Array = []
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		if node.needs_grid():
			return {} # a grid node cannot fold into a per-cell run — stay on the GDScript path
		if _framework_mask_wired(ni, inputs_of) >= 0:
			return {} # the cell kernel has no mask slot; the grid program does (`_emit_program`)
		var srcs: Array = inputs_of[ni]
		var sa: int = int(srcs[0]) if srcs.size() > 0 else -1
		var sb: int = int(srcs[1]) if srcs.size() > 1 else -1
		# The id comes from the same C++ list the grid path reads, so the two compilers can no longer
		# disagree about what an op tag means. The `match` below stays, because it is answering a DIFFERENT
		# question: the cell evaluator implements only NOISE / CONST / BLEND / TERRACE, so having an id is
		# necessary and not sufficient here.
		#
		# Mute lowers to BLEND-add-nothing rather than to the grid path's OUTPUT because the cell kernel
		# has no passthrough op at all. Same concept, two vocabularies; naming both from `op_ids()` is as
		# unified as they can honestly be.
		var op_id := int(op_ids().get(node.op(), 0))
		var param := 0.0
		var pb := 0.0
		var pc := 0.0
		var pd := 0.0
		var nz = null
		if node.muted:
			op_id = int(op_ids().get(&"blend", 0))
			param = 0.0 # BLEND_ADD
			sb = -1 # unwired second input (adds 0.0 -> pure passthrough of sa)
		else:
			match node.op():
				&"noise":
					param = float(node.get("amplitude")); nz = node.get("noise")
				&"const":
					param = float(node.get("value"))
				&"const_int":
					param = float(int(node.get("value")))
				&"param":
					param = node.resolved_value()
				&"const_color":
					var cc: Color = node.get("value") if node.get("value") is Color else Color.WHITE
					param = cc.get_luminance()
				&"const_bool":
					param = 1.0 if bool(node.get("value")) else 0.0
				&"blend":
					if srcs.size() > 2 and int(srcs[2]) >= 0:
						return {} # a masked blend is 3-input; the native cell evaluator only reads a & b
					param = float(int(node.get("mode")))
				&"terrace":
					param = float(node.get("band_height"))
					pb = float(node.get("hardness"))
					pc = float(node.get("amount"))
					pd = float(node.get("jitter"))
					if pd > 0.0 and node.has_method("_jitter_field"):
						nz = node.call("_jitter_field")
				_:
					return {} # an op the native cell evaluator does not implement
		ops.append(op_id)
		params.append(param)
		params_b.append(pb)
		params_c.append(pc)
		params_d.append(pd)
		noise_tab.append(nz)
		# Generators have no inputs; -1 there is harmless (the native evaluator only reads a blend's ports).
		in_a.append(int(slot_of[sa]) if sa >= 0 else -1)
		in_b.append(int(slot_of[sb]) if sb >= 0 else -1)
	return {
		"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
		"in_a": in_a, "in_b": in_b,
		"noise": noise_tab, "output": int(slot_of[out]),
	}


## The standard-mask port of `p_ni` when the GRAPH applies it and something is wired to it, else -1
## (spec §9.2). The one question every route asks: -1 means the node is evaluated exactly as before this
## existed, so an unwired mask costs nothing anywhere.
func _framework_mask_wired(p_ni: int, p_inputs_of: Dictionary) -> int:
	var node: Pasture3DGraphNode = nodes[p_ni]
	if node == null or node.muted:
		return -1
	var mp := node.framework_mask_port()
	if mp < 0:
		return -1
	var srcs: Array = p_inputs_of.get(p_ni, [])
	return mp if (mp < srcs.size() and int(srcs[mp]) >= 0) else -1


## The standard rule, applied by the GDScript evaluators: `in + (out - in) * clamp(mask, 0, 1)`, and a
## non-finite mask cell leaves `out`. In double, as the native Blend MIX does it.
static func apply_standard_mask(p_in: PackedFloat32Array, p_out: PackedFloat32Array, p_mask: PackedFloat32Array) -> PackedFloat32Array:
	var n := p_out.size()
	if p_mask.size() != n:
		return p_out
	var res := p_out.duplicate()
	var has_in := p_in.size() == n
	for i in range(n):
		var m: float = p_mask[i]
		if is_finite(m):
			var a: float = p_in[i] if has_in else 0.0
			res[i] = a + (float(p_out[i]) - a) * clampf(m, 0.0, 1.0)
	return res


## The compiled slot to TAP for `p_node`'s output `p_port`, or -1. Port 0 of a masked node is its mask
## slot, so a thumbnail shows the masked result; its other channels live on the node's own slot.
static func tap_slot(p_compiled: Dictionary, p_node: int, p_port: int = 0) -> int:
	# A Subgraph node's ports are separate roots in the flat view (§11.2), each read at its own channel 0.
	var st: Dictionary = p_compiled.get("sub_taps", {})
	if st.has(p_node):
		var per: Array = st[p_node]
		return int(per[p_port]) if p_port >= 0 and p_port < per.size() else -1
	var key := "slot_of" if p_port <= 0 else "raw_slot_of"
	var m: Dictionary = p_compiled.get(key, p_compiled.get("slot_of", {}))
	return int(m[p_node]) if m.has(p_node) else -1


## The channel of `tap_slot(p_compiled, p_node, p_port)`'s slot a tap reads: the port itself, except on a
## Subgraph node, whose every port is channel 0 of its own slot.
static func tap_channel(p_compiled: Dictionary, p_node: int, p_port: int = 0) -> int:
	var st: Dictionary = p_compiled.get("sub_taps", {})
	return 0 if st.has(p_node) else p_port


## THE SHARED LOWERING. One slot per node of `p_order`, plus one Blend MIX slot after every node whose
## standard mask is wired and applied by the graph. `compile_graph_program` and
## `compile_graph_program_multi` are both this and nothing else, so the bake, the previews, the sinks and
## the GPU route (which reads the same program) cannot disagree about a mask.
##
## Returns `{}` for an op the native evaluator does not implement, else
## `{"program", "slot_of", "raw_slot_of"}`. `slot_of[node]` is the slot a consumer of the node's PORT 0
## reads, which is the mask slot when there is one. `raw_slot_of[node]` is the node's own op, where its
## secondary channels are. The two are the same number for every unmasked node.
func _emit_program(p_order: Array, p_inputs_of: Dictionary, p_input_ports_of: Dictionary) -> Dictionary:
	var raw_slot := {}
	var out_slot := {}
	var next := 0
	for ni in p_order:
		raw_slot[ni] = next
		next += 1
		if _framework_mask_wired(ni, p_inputs_of) >= 0:
			out_slot[ni] = next
			next += 1
		else:
			out_slot[ni] = raw_slot[ni]
	var blend_op := int(op_ids().get(&"blend", -1))
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var params_e := PackedFloat32Array()
	var params_f := PackedFloat32Array()
	var params_g := PackedFloat32Array()
	var params_h := PackedFloat32Array()
	var params_i := PackedFloat32Array()
	var params_j := PackedFloat32Array()
	var params_k := PackedFloat32Array()
	var params_l := PackedFloat32Array()
	var params_m := PackedFloat32Array()
	var params_n := PackedFloat32Array()
	var params_o := PackedFloat32Array()
	var params_p := PackedFloat32Array()
	var in0 := PackedInt32Array()
	var in1 := PackedInt32Array()
	var in2 := PackedInt32Array()
	var in3 := PackedInt32Array()
	# Parallel to in0..in3: the params slot each of those ports overrides when wired, or -1.
	var pmap0 := PackedInt32Array()
	var pmap1 := PackedInt32Array()
	var pmap2 := PackedInt32Array()
	var pmap3 := PackedInt32Array()
	# The overflow table for driven scalars on ports >= 4, which have no in-slot to ride in. Three parallel
	# arrays, one entry per such wire: which compiled slot is being driven, which of the sixteen params it
	# overrides, and which compiled slot supplies the value. Flat rather than in4/in5/... because the next
	# node with a seventh port should not be another schema change.
	var pdrv_node := PackedInt32Array()
	var pdrv_param := PackedInt32Array()
	var pdrv_src := PackedInt32Array()
	# Which output CHANNEL of the source each pdrv entry reads (a Measure's max is channel 1).
	var pdrv_chan := PackedInt32Array()
	# Multi-output channels (P2b): how many grids each slot produces, and which grid of its source each of
	# in0..in3 reads. Emitted for every program, not only ones that use them, so the native side never has
	# to guess whether a missing array means "one channel" or "an older compiler".
	var out_count := PackedInt32Array()
	# Which INPUT PORT carries each slot's secondary GRID operand (mask / noise / per-cell weight), or -1.
	# The native and GPU evaluators cannot see a node's port list, so they used to hardcode `in1` for every
	# op that has one -- correct for Mudslide and wrong for the other five. The node answers this itself
	# (Pasture3DGraphNode.aux_grid_port), so a new node declares it beside its own input_names().
	var aux_port := PackedInt32Array()
	var in0_port := PackedInt32Array()
	var in1_port := PackedInt32Array()
	var in2_port := PackedInt32Array()
	var in3_port := PackedInt32Array()
	# The source of a secondary grid on a port past in3, and the channel it reads. See GraphProgram::in_aux.
	var in_aux := PackedInt32Array()
	var in_aux_port := PackedInt32Array()
	var noise_tab: Array = []
	var luts_tab: Array = []
	var frozen_tab: Array = []
	var geo := _compile_geometry(p_order, p_inputs_of)
	var geo_in: PackedInt32Array = geo["in_g"]
	var in_g := PackedInt32Array()

	for oi in range(p_order.size()):
		var ni: int = p_order[oi]
		var node: Pasture3DGraphNode = nodes[ni]
		var iports: Array = p_input_ports_of.get(ni, [])
		# The node's operands. A mask the graph applies is taken OUT of them here: the node's own op must
		# not see it as a grid operand, a driven scalar or part of a frozen solve's key.
		var srcs: Array = (p_inputs_of[ni] as Array).duplicate()
		var mp := _framework_mask_wired(ni, p_inputs_of)
		var mask_src := -1
		var mask_chan := 0
		if mp >= 0:
			if blend_op < 0:
				return {}
			mask_src = int(srcs[mp])
			mask_chan = int(iports[mp]) if iports.size() > mp else 0
			srcs[mp] = -1
		# Slot and channel of each of the first four operands. Port 0 of a source is its `out_slot`.
		var s_slot := PackedInt32Array([-1, -1, -1, -1])
		var s_chan := PackedInt32Array([0, 0, 0, 0])
		for k in range(mini(4, srcs.size())):
			var sk := int(srcs[k])
			if sk >= 0:
				s_chan[k] = int(iports[k]) if iports.size() > k else 0
				s_slot[k] = int(out_slot[sk]) if s_chan[k] <= 0 else int(raw_slot[sk])
		var lowered := _lower_node_op(node)
		if lowered.is_empty():
			return {} # an op the native evaluator does not implement
		var _pr: PackedFloat32Array = lowered["params"]
		ops.append(int(lowered["op"]))
		params.append(_pr[0]); params_b.append(_pr[1]); params_c.append(_pr[2]); params_d.append(_pr[3])
		params_e.append(_pr[4]); params_f.append(_pr[5]); params_g.append(_pr[6]); params_h.append(_pr[7])
		params_i.append(_pr[8]); params_j.append(_pr[9]); params_k.append(_pr[10]); params_l.append(_pr[11])
		params_m.append(_pr[12]); params_n.append(_pr[13]); params_o.append(_pr[14]); params_p.append(_pr[15])
		noise_tab.append(lowered["noise"])
		luts_tab.append(lowered["lut"])
		in0.append(s_slot[0]); in1.append(s_slot[1]); in2.append(s_slot[2]); in3.append(s_slot[3])
		in0_port.append(s_chan[0]); in1_port.append(s_chan[1]); in2_port.append(s_chan[2]); in3_port.append(s_chan[3])
		out_count.append(native_out_count(ni))
		var high_aux: int = node.aux_grid_port()
		aux_port.append(high_aux)
		var s_aux: int = int(srcs[high_aux]) if high_aux >= 4 and srcs.size() > high_aux else -1
		var c_aux: int = int(iports[high_aux]) if s_aux >= 0 and iports.size() > high_aux else 0
		in_aux.append(-1 if s_aux < 0 else (int(out_slot[s_aux]) if c_aux <= 0 else int(raw_slot[s_aux])))
		in_aux_port.append(c_aux)
		var _pm: PackedInt32Array = lowered.get("pmap", PackedInt32Array())
		pmap0.append(_pm[0] if _pm.size() > 0 else -1)
		pmap1.append(_pm[1] if _pm.size() > 1 else -1)
		pmap2.append(_pm[2] if _pm.size() > 2 else -1)
		pmap3.append(_pm[3] if _pm.size() > 3 else -1)
		for k in range(4, _pm.size()):
			var pslot: int = int(_pm[k])
			var psrc: int = int(srcs[k]) if srcs.size() > k else -1
			if pslot >= 0 and psrc >= 0:
				var pch: int = int(iports[k]) if iports.size() > k else 0
				pdrv_node.append(ops.size() - 1)
				pdrv_param.append(pslot)
				pdrv_src.append(int(out_slot[psrc]) if pch <= 0 else int(raw_slot[psrc]))
				pdrv_chan.append(pch)
		frozen_tab.append(node.native_freeze_entry() if (not node.muted and node is Pasture3DGraphSolverNode) else null)
		in_g.append(geo_in[oi] if oi < geo_in.size() else -1)

		if mp < 0:
			continue
		# THE MASK SLOT: Blend MIX of (the node's input, the node's output, the mask). MIX with a mask is
		# `a + (b - a) * clamp(mask, 0, 1)`, and a non-finite mask cell leaves `b`, which is the standard
		# rule word for word. It is the Blend node's own op, so there is no new kernel on any route.
		ops.append(blend_op)
		params.append(float(Pasture3DGraphNodeBlend.Mode.MIX)); params_b.append(0.0); params_c.append(0.0); params_d.append(0.0)
		params_e.append(0.0); params_f.append(0.0); params_g.append(0.0); params_h.append(0.0)
		params_i.append(0.0); params_j.append(0.0); params_k.append(0.0); params_l.append(0.0)
		params_m.append(0.0); params_n.append(0.0); params_o.append(0.0); params_p.append(0.0)
		noise_tab.append(null)
		luts_tab.append(PackedFloat32Array())
		in0.append(s_slot[0]); in0_port.append(s_chan[0])
		in1.append(int(raw_slot[ni])); in1_port.append(0)
		in2.append(int(out_slot[mask_src]) if mask_chan <= 0 else int(raw_slot[mask_src])); in2_port.append(mask_chan)
		in3.append(-1); in3_port.append(0)
		out_count.append(1)
		aux_port.append(-1)
		in_aux.append(-1)
		in_aux_port.append(0)
		pmap0.append(-1); pmap1.append(-1); pmap2.append(-1); pmap3.append(-1)
		frozen_tab.append(null)
		in_g.append(-1)

	return {
		"program": _with_footprint({
			"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
			"params_e": params_e, "params_f": params_f, "params_g": params_g, "params_h": params_h,
			"params_i": params_i, "params_j": params_j, "params_k": params_k, "params_l": params_l,
			"params_m": params_m, "params_n": params_n, "params_o": params_o, "params_p": params_p,
			"in0": in0, "in1": in1, "in2": in2, "in3": in3,
			"out_count": out_count, "aux_port": aux_port,
			"in0_port": in0_port, "in1_port": in1_port, "in2_port": in2_port, "in3_port": in3_port,
			"in_aux": in_aux, "in_aux_port": in_aux_port,
			"in_g": in_g, "geom": geo["geom"],
			"pmap0": pmap0, "pmap1": pmap1, "pmap2": pmap2, "pmap3": pmap3,
			"pdrv_node": pdrv_node, "pdrv_param": pdrv_param, "pdrv_src": pdrv_src, "pdrv_chan": pdrv_chan,
			"noise": noise_tab, "luts": luts_tab, "output": 0,
			# The freeze table, parallel to the slots: each FROZEN solver's cache and key recipe, null
			# elsewhere. A mask slot is never frozen, so a solve is cached UNMASKED and changing the mask
			# re-runs one blend. Without the table a sink or preview tap pass re-solved every FROZEN solver
			# from scratch -- a Saleve solve on the main thread, per bake pass.
			"frozen": frozen_tab,
		}),
		"slot_of": out_slot,
		"raw_slot_of": raw_slot,
	}


## Lower the WHOLE graph — any node types — into the flat program the native evaluator materialises node by
## node (`Pasture3DUtil.graph_eval_grid`; C++ `pasture_3d_graph_ops`). One slot per node in topological
## order, so a slot's inputs are always earlier slots. This is the materialise-every-node analogue of
## `_eval_unfolded` (which `evaluate`, the folded path, matches to float32 rounding); the native side does
## not fold, so it mirrors the unfolded reference. Returns {} — "stay on the GDScript path" — for a missing
## or cyclic output, or a node whose op the native evaluator does not implement.
##
## Program keys, all parallel and one entry per slot except `output`:
##   ops      [int]     GraphCellOpType — 1 noise, 2 const, 3 blend, 4 terrace, 10 input, 11 smooth, 12 output
##   params   [float]   amplitude | value | blend-mode | smooth-passes | band_height
##   params_b [float]   hardness
##   params_c [float]   amount
##   params_d [float]   jitter
##   in0      [int]     first input's source slot, or -1 unwired
##   in1      [int]     second input's source slot (blend only), or -1
##   noise    [Variant] the slot's FastNoiseLite (noise/jitter ops) or null — passed as-is, never rebuilt
##   output   int       the slot whose grid is the graph output
func compile_graph_program(p_root_node: int = -1) -> Dictionary:
	if needs_flat() and is_compatible():
		var froot := _flat_root(p_root_node)
		return {} if froot == FLAT_NO_ROOT else flat_view().compile_graph_program(froot)
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {}
	var order := _eval_order(out)
	if order.is_empty():
		return {}
	# The same narrowing as native_supported: a channel the native op does not write cannot be compiled
	# into a program, and the two must agree or a graph would report as lowerable and then fail to lower.
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if order.has(to_node) and order.has(from_node) and int(c[1]) >= native_out_count(from_node):
				return {}
	var plan: Dictionary = _fold_plan(out)
	var emitted := _emit_program(order, plan["inputs_of"], plan["input_ports_of"])
	if emitted.is_empty():
		return {} # an op the native evaluator does not implement
	var prog: Dictionary = emitted["program"]
	prog["output"] = int(emitted["slot_of"][out])
	return prog


## True when a compiled program carries a FROZEN solver. Static and resource-free, so a worker may ask.
static func program_has_freeze(p_prog: Dictionary) -> bool:
	for e in p_prog.get("frozen", []):
		if e != null:
			return true
	return false


## File what the native evaluator served or solved back into the solver nodes. MAIN THREAD ONLY — this is
## the half of the freeze a worker may not do. Reports name the node by instance id rather than slot, so a
## node deleted or renumbered while a worker solved is skipped instead of handed another node's solve.
##
## `p_host_id` is the host the program was compiled for. A worker's solve can land after another host was
## stamped, so the solve is filed into ITS host's slot, not whichever is live; -1 means the live one.
func adopt_native_freeze(p_reports: Array, p_host_id: int = -1) -> void:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		push_error("Pasture3DTerrainGraph.adopt_native_freeze() called off the main thread.")
		return
	var live := host_id
	if p_host_id >= 0 and p_host_id != live:
		select_host(p_host_id)
	_adopt_reports(p_reports)
	if host_id != live:
		select_host(live)


func _adopt_reports(p_reports: Array) -> void:
	for r in p_reports:
		var obj := instance_from_id(int((r as Dictionary).get("node_id", 0)))
		if obj is Pasture3DGraphSolverNode and nodes.has(obj):
			obj.adopt_native_freeze(r)


## One native evaluation of a compiled program, freeze-aware: a program with a FROZEN solver goes through
## the reporting entry point and its reports are adopted before the field is returned.
func _native_eval(p_prog: Dictionary, p_gw: int, p_gh: int, p_rect: Rect2, p_input: PackedFloat32Array) -> PackedFloat32Array:
	if program_has_freeze(p_prog):
		var res: Dictionary = Pasture3DUtil.graph_eval_grid_frozen(p_prog, p_gw, p_gh, p_rect, p_input)
		adopt_native_freeze(res.get("frozen", []))
		return res.get("field", PackedFloat32Array())
	return Pasture3DUtil.graph_eval_grid(p_prog, p_gw, p_gh, p_rect, p_input)


## Which compiled parameter slot each of a node's first four INPUT PORTS drives, per op.
##
## The native evaluator used to read every op's parameters out of the compiled program and ignore the wires
## entirely, so a Const driving an amplitude, a talus angle or an iteration count did nothing at all — on 52
## of the 105 parameter ports in the graph. This table is what makes a driven port reach the kernel: entry
## `k` is the index into the 16 params slots (0 = params, 1 = params_b, ... 15 = params_p) that port `k`
## overrides when it is wired, or -1 when the port is not a scalar parameter (a HEIGHT or MASK grid input,
## or an unmapped port).
##
## Entries may run PAST four ports. A compiled program carries only four grid slots (in0..in3), but a
## driven scalar does not need a grid slot: the native evaluator reads cell 0 of the source buffer, and the
## source is already a compiled slot. Ports >= 4 that this table maps therefore travel in a flat overflow
## table (`pdrv_node` / `pdrv_param` / `pdrv_src`) instead, so wiring Swiss `frequency` or Dunes `sharpness`
## no longer costs the whole graph its acceleration. A port >= 4 that this table does NOT map is a grid port
## with nowhere to go, and `native_supported()` still declines it rather than dropping it silently. The one
## exception is the node's own `aux_grid_port`, which rides `in_aux`.
##
## The values were derived by matching each node's `input_names()` against the property names its lowering
## reads, then checked against the node's own `eval_grid`. GraphAllNodeSocketsGate section F sweeps every
## port and fails on any that the native path ignores, so an op missing from this table is caught rather
## than silently reverting to the old behaviour.
##
## hydraulic_saleve's dx/dy are deliberately absent: they are per-cell FIELDS, not scalars, and the native
## case already consumes them as grids.


## The op vocabulary, read once from C++ and memoised.
##
## `Pasture3DUtil.graph_op_ids()` maps every op tag the native evaluator implements to its
## `GraphCellOpType` id. It replaces 70 hand-typed integers in `_lower_node_op` AND the `SUPPORTED`
## allow-list that restated the same set — two tables that had to agree with no way to say so. An id typed
## wrong lowered the wrong kernel; an op missing from the allow-list did not fail loudly, it silently
## dropped the ENTIRE graph onto the script evaluator, which is how DLA escaped native lowering.
##
## Empty when the extension is unavailable — which is exactly the state `native_supported()` must report
## as "no", so that degradation needs no branch of its own.
static var _op_ids_cache: Dictionary = {}


static func op_ids() -> Dictionary:
	if _op_ids_cache.is_empty() and ClassDB.class_has_method("Pasture3DUtil", "graph_op_ids"):
		# No colour node belongs in this table. COLOR wires are a compile-time sideband resolved by walking
		# upstream (Pasture3DGraphChannelSinks._color_of); the editor preview keeps colour roots out of the
		# compile and compiles only their field sources. Color Mix/Blend once had GRAPH_OP_CONST aliases here
		# and in C++ to paper over a preview that bailed on them.
		_op_ids_cache = Pasture3DUtil.graph_op_ids().duplicate()
	return _op_ids_cache


## Lower ONE node into the native op table: its GraphCellOpType id, the 16 parallel scalar params
## (p0..pp, index-aligned with compile_graph_program's params/params_b/.../params_p), its FastNoiseLite (or
## null), and its CURVE LUT (or an empty array). The single source of truth for the op vocabulary, shared by
## the single-root bake compile (`compile_graph_program`) and the multi-root preview compile
## (`compile_graph_program_multi`) so a new node's lowering is written once. Returns {} for an op the native
## evaluator does not implement — the caller then abandons the native path. A muted node lowers to op 12
## (passthrough of its first input), matching the folded evaluator's mute semantics.
func _lower_node_op(node: Pasture3DGraphNode) -> Dictionary:
	# Two lookups and no vocabulary of its own. The id comes from the C++ list; the parameters come from
	# the node that owns them. What used to be here was 60 match arms reading this node's properties by
	# string from the outside — see `Pasture3DGraphNode.native_lower()` for the four shipped bugs that
	# arrangement produced and why a typo there was silent.
	var op_id := int(op_ids().get(&"output" if node.muted else node.op(), -1))
	if op_id < 0:
		return {} # an op the native evaluator does not implement
	# A muted node passes its first input through and has no parameters of its own, so it marshals none
	# and maps no port.
	var low: Dictionary = {} if node.muted else node.native_lower()
	var pr: PackedFloat32Array = low.get("params", PackedFloat32Array())
	pr.resize(16)
	return {
		"op": op_id,
		"params": pr,
		"pmap": PackedInt32Array() if node.muted else node.native_param_ports(),
		"noise": low.get("noise"),
		"lut": low.get("lut", PackedFloat32Array()),
	}


## Topological order of the UNION of every root's ancestry — one program that can cover several preview
## roots at once. Same ancestor walk + Kahn sort as `_eval_order`, over the combined `needed` set; empty on a
## cycle. NOT memoized: the root SET varies with which previews are toggled on, so caching it would thrash;
## the single-root `_eval_order` stays the cached hot path the bake rides.
## A wire into a COLOR port. Colours travel the sideband (graph_channel_sinks `_color_of`), never the
## program, so the ancestry walks skip these: a Const Color or Color Blend upstream of a Color Sink used to
## enter the sink's eval order and, having no native op, drop the whole graph to GDScript.
func _is_color_wire(p_c) -> bool:
	var to := int(p_c[2])
	if to < 0 or to >= nodes.size() or nodes[to] == null:
		return false
	var types: PackedInt32Array = nodes[to].input_port_types()
	var port := int(p_c[3])
	return port >= 0 and port < types.size() and int(types[port]) == Pasture3DGraphNode.PortType.COLOR


func _eval_order_multi(p_roots: Array) -> Array:
	if not is_compatible():
		return []
	var needed := {}
	var frontier: Array = []
	for r in p_roots:
		var ri := int(r)
		if ri >= 0 and ri < nodes.size() and nodes[ri] != null and not needed.has(ri):
			needed[ri] = true
			frontier.push_back(ri)
	if needed.is_empty():
		return []
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[2]) == cur and not _is_color_wire(c):
				var from := int(c[0])
				# Null-skip for the same reason as `_eval_order` below.
				if from >= 0 and from < nodes.size() and nodes[from] != null and not needed.has(from):
					needed[from] = true
					frontier.push_back(from)
	var indeg := {}
	for ni in needed:
		indeg[ni] = 0
	for c in connections:
		if c.size() >= 4:
			var from := int(c[0])
			var to := int(c[2])
			if needed.has(from) and needed.has(to):
				indeg[to] += 1
	var ready: Array = []
	for ni in indeg:
		if indeg[ni] == 0:
			ready.push_back(ni)
	var order: Array = []
	while not ready.is_empty():
		var ni: int = ready.pop_back()
		order.push_back(ni)
		for c in connections:
			if c.size() >= 4 and int(c[0]) == ni and needed.has(int(c[2])):
				var to := int(c[2])
				indeg[to] -= 1
				if indeg[to] == 0:
					ready.push_back(to)
	if order.size() != needed.size():
		return [] # a cycle in the combined ancestry
	return order


## Compile ONE native program covering every root in `p_roots` and their ancestors, plus a `slot_of` map
## (node index -> SSA slot) so the caller can find each preview node's tap slot. Backs the editor's inline
## previews: one program feeds one `Pasture3DUtil.graph_eval_grid_taps` pass, so N open previews cost a
## single evaluation. Returns {} — "no native preview this tick" — when the root set is empty, its combined
## ancestry has a cycle or a secondary-port (port >= 1) wire, or any node's op is not native. The program's
## `output` is set to one root's slot purely to satisfy graph_build's range check; the caller reads the
## tapped buffers, never the output.
func compile_graph_program_multi(p_roots: Array) -> Dictionary:
	if needs_flat() and is_compatible():
		return _flat_compile_multi(p_roots)
	var order := _eval_order_multi(p_roots)
	if order.is_empty():
		return {}
	var needed := {}
	for ni in order:
		needed[ni] = true
	# Bail exactly as native_supported / compile_graph_program do — same rule, three places, and they have
	# to move together or a graph reports lowerable and then fails to lower. Since P2b that rule is
	# "reading a channel the native op does not write", not "reading any secondary port".
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if needed.has(to_node) and needed.has(from_node) and int(c[1]) >= native_out_count(from_node):
				return {}
	# inputs_of over the union ancestor set — same construction as _fold_plan, restricted to `needed`.
	var inputs_of := {}
	var input_ports_of := {}
	for ni in order:
		var arr: Array = []
		arr.resize(nodes[ni].input_count())
		arr.fill(-1)
		inputs_of[ni] = arr
		var parr: Array = []
		parr.resize(nodes[ni].input_count())
		parr.fill(0)
		input_ports_of[ni] = parr
	for c in connections:
		if c.size() >= 4:
			var to := int(c[2])
			var from := int(c[0])
			if needed.has(to) and needed.has(from):
				var tp := int(c[3])
				if tp >= 0 and tp < (inputs_of[to] as Array).size():
					inputs_of[to][tp] = from
					input_ports_of[to][tp] = int(c[1])
	var emitted := _emit_program(order, inputs_of, input_ports_of)
	if emitted.is_empty():
		return {} # an op the native evaluator does not implement
	var slot_of: Dictionary = emitted["slot_of"]
	for r in p_roots:
		var ri := int(r)
		if slot_of.has(ri):
			emitted["program"]["output"] = int(slot_of[ri])
			break
	return emitted


## How many output channels the NATIVE evaluator writes for an op (P2b,
## PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.3). Absent means one.
##
## ---- THIS IS ABOUT THE KERNEL, NOT ABOUT THE NODE ----
##
## It would be easier to read `node.output_count()`, and it would be wrong. That number is what the
## GDScript node OFFERS; this one is what `graph_eval_grid` actually fills in. An op whose secondary
## channels have no case in pasture_3d_graph_ops.cpp declares 1 here, and a graph reading them is then
## refused a native lowering — rather than lowered and served a field of zeros, which is the failure this
## whole allow-list style exists to prevent.
##
## Add an entry the same commit you write the channels, never in advance.


## How many channels the native evaluator produces for the op at `p_node`, 1 when it is single-output or
## unknown.
func native_out_count(p_node: int) -> int:
	if p_node < 0 or p_node >= nodes.size() or nodes[p_node] == null:
		return 1
	if nodes[p_node].muted:
		return 1 # a muted node lowers to passthrough, which has one channel whatever it wrapped
	return nodes[p_node].native_out_count()


## ---- The geometry table (P2c, PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §4.1) ----
##
## Which PATH feeds `p_ni`, or null. Found by PORT TYPE, never by port index: the path is port 0 on Path
## Distance and Path Mask and port 1 on Road Grade, and an index hardcoded here would grade a road against
## nothing the day one of those nodes grows another input — silently, because "no path" is a legal state
## that passes the surface through.
func _path_operand_of(p_ni: int, p_inputs_of: Dictionary) -> Pasture3DGraphPath:
	if p_ni < 0 or p_ni >= nodes.size() or nodes[p_ni] == null:
		return null
	var types := nodes[p_ni].input_port_types()
	var srcs: Array = p_inputs_of.get(p_ni, [])
	var first_unwired := -1
	for k in range(types.size()):
		if int(types[k]) != Pasture3DGraphNode.PortType.PATH:
			continue
		var src := int(srcs[k]) if k < srcs.size() else -1
		if src >= 0 and src < nodes.size() and nodes[src] != null:
			return _resolved_path_of(src, p_inputs_of)
		if src < 0 and first_unwired < 0:
			first_unwired = k
	# Nothing wired: the node's own fallback for the empty socket, the same one `_path_inputs` hands the
	# GDScript route.
	return nodes[p_ni].unwired_path(first_unwired) if first_unwired >= 0 else null


## The PATH a node actually produces, resolved through the whole upstream filter chain — or null.
##
## The editor's door to the pre-pass. `_resolved_path_of` needs an `inputs_of` map and every existing
## caller already has one built for another purpose; this builds the same map for the one-node question a
## thumbnail asks, so the preview reads the path the BAKE would resolve rather than the raw
## `path_output()` a node happens to be holding. Those differ by exactly the filter chain, which is the
## whole of §7.5 — previewing the unfiltered path would draw the input to a Path Resample and call it the
## output (`PathDeriveGate`'s trap, in a new place).
##
## Costs one memoised pre-pass walk. Called from the preview refresh, which is debounced, and only for
## nodes whose declared output type is PATH.
func resolved_path_of(p_ni: int) -> Pasture3DGraphPath:
	if not is_compatible():
		return null
	if needs_flat():
		var fr := _flat_root(p_ni)
		return null if fr < 0 else flat_view().resolved_path_of(fr)
	if p_ni < 0 or p_ni >= nodes.size() or nodes[p_ni] == null:
		return null
	# Same construction as `compile_graph_program_multi`'s, over every node rather than an ancestor set:
	# a single query does not know which ancestors it needs until the recursion asks for them.
	var inputs_of := {}
	for ni in range(nodes.size()):
		if nodes[ni] == null:
			continue
		var arr: Array = []
		arr.resize(nodes[ni].input_count())
		arr.fill(-1)
		inputs_of[ni] = arr
	for c in connections:
		if c.size() >= 4:
			var to := int(c[2])
			var tp := int(c[3])
			if inputs_of.has(to) and tp >= 0 and tp < (inputs_of[to] as Array).size():
				inputs_of[to][tp] = int(c[0])
	return _resolved_path_of(p_ni, inputs_of)


## ---- THE PATH PRE-PASS (spec §8.2-8.3) ----------------------------------------------------------
##
## Set to make `_resolved_path_of` degenerate to the pre-S4 single hop: every node answers with the path
## it HOLDS, so a filter contributes nothing. Not a user setting and not exported — it is the control a
## gate needs, because "the width came out right" is also what you see when the width node happens to be
## a no-op, and only turning the pre-pass off distinguishes them.
var force_no_path_prepass := false

# host id -> node index -> [key, path], per host like every node's grid cache (`host_id`). The key folds the node's own `_dirty_revision` and the CONTENT DIGEST of
# every resolved input path, so an edit anywhere upstream misses and everything else hits.
var _path_eval_cache: Dictionary = {}


## The path a node PRODUCES, resolved through however many PATH filters sit above it.
##
## ---- WHY A MEMOISED RECURSION AND NOT A TOPOLOGICAL SWEEP ----
##
## A sweep would have to be run somewhere, and there are five call sites that want a path (two compilers,
## the folded evaluator, the unfolded oracle, the preview taps) reached by four different orderings.
## Recursion resolves in dependency order by construction, from whichever of them asks first, and the
## memo makes the repeat asks free — the sweep's only real advantage.
##
## ---- WHY THE KEY IS A DIGEST AND NOT A REVISION CHAIN ----
##
## A filter's output depends on its inputs' CONTENTS, and a Road Source re-baked to byte-identical
## geometry bumps its revision every bake. Keying on revisions alone would re-run every filter in the
## graph on every bake and hand back a new instance each time, which costs the geometry table's fanout
## dedup as well as the work. `content_digest` is one native hash per path (§ its own comment) and it is
## the same measure `Pasture3DGraphPath` already uses to decide whether it changed at all.
## Records what this node HANDED THE GRAPH, then answers with it (visualization spec §6.3, V3).
##
## A wrapper rather than four assignments inside the body, because the record has to hold at EVERY return
## — the source short-circuit, the cycle break, the memo hit and the fresh `eval_path` alike — and a rule
## that has to be remembered at four returns is a rule that will be forgotten at the fifth.
##
## This is the only place that knows. `eval_path` cannot record for a SOURCE, which the short-circuit
## answers without ever calling it, and cannot record a memo HIT, which returns without calling it either.
## An overlay reading a record written by `eval_path` would therefore show every Spline Source as "not yet
## resolved" and would go stale exactly while the memo was working.
func _resolved_path_of(p_ni: int, p_inputs_of: Dictionary, p_stack: Dictionary = {}) -> Pasture3DGraphPath:
	var made := _resolved_path_of_uncached(p_ni, p_inputs_of, p_stack)
	if p_ni >= 0 and p_ni < nodes.size() and nodes[p_ni] != null:
		nodes[p_ni]._returned = made
	return made


func _resolved_path_of_uncached(p_ni: int, p_inputs_of: Dictionary, p_stack: Dictionary = {}) -> Pasture3DGraphPath:
	if p_ni < 0 or p_ni >= nodes.size() or nodes[p_ni] == null:
		return null
	var node: Pasture3DGraphNode = nodes[p_ni]
	if force_no_path_prepass:
		return node.path_output()
	# A cycle cannot be built in the editor, but a graph resource can be hand-edited and a `.tscn` can be
	# merged badly. Answering with what the node holds breaks the loop without pretending it was legal.
	if p_stack.has(p_ni):
		return node.path_output()
	# A source has no PATH inputs to resolve and its `eval_path` is `path_output` by definition, so the
	# common case never allocates the input array or touches the cache at all.
	var types := node.input_port_types()
	var srcs: Array = p_inputs_of.get(p_ni, [])
	var n_in := mini(types.size(), srcs.size())
	var any_path := false
	for k in range(n_in):
		if int(types[k]) == Pasture3DGraphNode.PortType.PATH:
			any_path = true
			break
	# A derive node (8.4) has a grid input and may have no PATH input at all, and still produces a path.
	# Short-circuiting on "no PATH input" would answer Path from Flow with the null it holds.
	if not any_path and not node.derives_path_from_grid():
		return node.path_output()

	p_stack[p_ni] = true
	var ins: Array = []
	# The salt is the derive family's captured grid. Nothing else in this key moves when the erosion above
	# re-solves -- see Pasture3DGraphNode.path_eval_salt.
	var key_parts: Array = [node._dirty_revision, node.path_eval_salt()]
	for k in range(types.size()):
		var up: Pasture3DGraphPath = null
		if k < n_in and int(types[k]) == Pasture3DGraphNode.PortType.PATH:
			up = _resolved_path_of(int(srcs[k]), p_inputs_of, p_stack)
		ins.append(up)
		# The digest AND the instance id: two different paths can hash alike in principle, and more to the
		# point a consumer that keeps its own instance needs to know when the thing above it was replaced
		# rather than edited, which a content digest cannot say.
		key_parts.append(up.content_digest() if up != null else 0)
		key_parts.append(up.get_instance_id() if up != null else 0)
	p_stack.erase(p_ni)

	var key := hash(key_parts)
	if not _path_eval_cache.has(host_id):
		_path_eval_cache[host_id] = {}
	var memo: Dictionary = _path_eval_cache[host_id]
	var hit = memo.get(p_ni)
	# `hit[1] == null` is a HIT, not a miss: producing no path is a legal answer (an unresolved source
	# above a filter), and treating it as a miss would re-run that filter every single evaluation.
	if hit != null and int(hit[0]) == key and (hit[1] == null or is_instance_valid(hit[1])):
		return hit[1]
	var made := node.eval_path(ins)
	memo[p_ni] = [key, made]
	return made


## Run the first half of the staged compile: give every derive node its grid, in topological order.
##
## Spec 8.4's cut, one node at a time:
##
##     compile( everything feeding the node's grid port ) -> evaluate -> eval_path( that result )
##
## The "evaluate" is a recursive `evaluate` call rooted at the upstream node, so a stage that lowers takes
## the kernel and one that does not takes GDScript -- and a derive feeding another derive is handled by
## the recursion rather than by a second mechanism, because the outer loop walks in topological order and
## the inner call stages whatever it finds above it.
##
## Returns false when a stage could not be produced, which sends `evaluate` down the ordinary routes
## rather than compiling a program whose geometry table names a path nobody made.
## Public door to the staging pass, for a caller that wants a PATH resolved against a surface it holds
## rather than against whatever the last `evaluate` happened to capture.
##
## The B3 publish sinks (§9.3) need exactly this. A Path Drape captures its surface during `eval_grid`,
## so `resolved_path_of` on its own re-derives from the PREVIOUS bake's grid — which would publish a
## river draped over the terrain as it was before the edit that triggered the publish, and, worse, would
## make the staleness check agree with it. Staging first is what makes "the digest moves when the ground
## under the path moves" true at the bake that moved it.
##
## Returns false when nothing could be staged, which leaves the caller resolving against the capture —
## the honest fallback, since a graph with no derive nodes has nothing to stage and every other one has
## already reported why.
func stage_paths_for(p_root: int, p_gw: int, p_gh: int, p_rect: Rect2,
		p_input: PackedFloat32Array) -> bool:
	if p_gw <= 0 or p_gh <= 0 or p_root < 0 or p_root >= nodes.size():
		return false
	if needs_flat() and is_compatible():
		var fr := _flat_root(p_root)
		return false if fr < 0 else flat_view().stage_paths_for(fr, p_gw, p_gh, p_rect, p_input)
	return _stage_derives(p_root, p_gw, p_gh, p_rect, null, p_input)


func _stage_derives(p_out: int, p_gw: int, p_gh: int, p_rect: Rect2, p_mask, p_input) -> bool:
	var order := _eval_order(p_out)
	if order.is_empty():
		return false
	var plan := _fold_plan(p_out)
	var inputs_of: Dictionary = plan["inputs_of"]
	var n := p_gw * p_gh
	var staged := 0
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		# Muted or not. A muted derive still has to be handed its grid: `_resolved_path_of` does not read
		# mute state, so skipping one would leave it serving whatever it captured last -- a path from a
		# different bake, which is the one answer worse than no path at all.
		if node == null or not node.derives_path_from_grid():
			continue
		var count: int = node.input_count()
		var types: PackedInt32Array = node.input_port_types()
		var srcs: Array = inputs_of.get(ni, [])
		var ins: Array = []
		ins.resize(count)
		for port in range(count):
			# An unwired port is its declared default, filled -- the same convention `_input_grids` uses,
			# and the reason the derive family declares NAN for its optional grids: it is the only way
			# back to "nothing is wired" from a grid of identical numbers.
			var dv: float = node.input_unwired_default(port)
			var src: int = int(srcs[port]) if port < srcs.size() else -1
			if src < 0 or port >= types.size() or int(types[port]) == Pasture3DGraphNode.PortType.PATH:
				if src < 0 and port < types.size() and int(types[port]) == Pasture3DGraphNode.PortType.HEIGHT and p_input != null and (p_input is PackedFloat32Array) and not (p_input as PackedFloat32Array).is_empty():
					ins[port] = _surface_grid(p_input, n)
				else:
					ins[port] = Pasture3DGraphOps.zeros(n) if is_zero_approx(dv) else Pasture3DGraphOps.filled(n, dv)
				continue
			var g: PackedFloat32Array = evaluate(p_gw, p_gh, p_rect, p_mask, p_input, src)
			if g.size() != n:
				return false
			ins[port] = g
		node.eval_grid(ins, p_gw, p_gh, p_mask, p_rect)
		staged += 1
	# Nothing staged means no derive node was reachable, so there was nothing for this route to do and
	# the ordinary native path is the honest one. Reporting success would make `staged_compile_count`
	# count graphs this phase never touched.
	return staged > 0


## One geometry-table entry: the polyline, its per-vertex widths, and — only when the road has a solved
## alignment — the grading profile in the alignment's OWN sampling.
##
## The two samplings are not redundancy. `values` is per vertex and answers the `t` query; `profile` is
## per alignment sample and is handed to the grader verbatim. Resampling either into the other would put
## an interpolation between the brush's road and the graph's, and RoadGraphGate [K] — 0.0000 m between
## them — is what would fail.
func _geom_entry(p_path: Pasture3DGraphPath) -> Dictionary:
	var d := {
		"kind": 0, # PATH. 1 = CLOUD is reserved (§5.4) and no op reads it yet.
		"closed": p_path.closed,
		"points": p_path.points,
		"values": p_path.half_widths,
		# Per-vertex elevation, and EMPTY when the path carries none — which the native build copies
		# verbatim rather than padding, so `height_at` can answer NaN instead of sea level (spec §6.1).
		"heights": p_path.heights,
	}
	# Only when there ARE parts, so a one-part path compiles to exactly the program it did before parts
	# existed (GraphPortIdGate's recorded programs are the check). The native table reads a missing key as none.
	if not p_path.part_starts.is_empty():
		d["part_starts"] = p_path.part_starts
	if p_path.can_grade() and p_path.alignment != null:
		d["profile"] = {
			"ds": p_path.alignment.ds,
			"s0": p_path.alignment.s0,
			"height": p_path.alignment.z,
			"bank": p_path.alignment.bank,
			"half": p_path.sample_half_widths,
			"shoulder": p_path.sample_shoulders,
			"verge": p_path.sample_verges,
			"suppress": p_path.sample_suppress,
			"skip": p_path.sample_skip,
			"crown": p_path.crown,
			"cut_batter": p_path.cut_batter,
			"fill_batter": p_path.fill_batter,
			"toe_rounding": p_path.toe_rounding,
			"hinge_rounding": p_path.hinge_rounding,
			"wall_plan": p_path.alignment.wall_plan,
			"section": p_path.sample_section,
		}
	return d


## The table and the per-slot `in_g`, for a compiled slot order.
##
## Entries are DEDUPLICATED by path instance, which is where fanout becomes free: four nodes reading one
## road name one entry, and the native side indexes that road once for the whole bake instead of four
## times. Keyed by instance id rather than by contents, because two roads may legitimately have identical
## geometry and must still be two entries — they can be re-baked apart.
func _compile_geometry(p_order: Array, p_inputs_of: Dictionary) -> Dictionary:
	var geom: Array = []
	var in_g := PackedInt32Array()
	var by_id := {}
	for ni in p_order:
		# A PATH PRODUCER names no entry, even though it has a PATH input and `_path_operand_of` would
		# happily answer with it. Its grid slot is a zero placeholder (see `Pasture3DGraphNode.path_output`)
		# and its op lowers to CONST, so it cannot read geometry — but the entry would still be built,
		# deduplicated apart from the path it PRODUCES, and uploaded to the GPU as a second polyline that
		# nothing dispatches against. PathPrePassGate [B] is what found this: two carves behind one filter
		# shared one entry correctly, and the table still held two.
		var node: Pasture3DGraphNode = nodes[int(ni)] if int(ni) < nodes.size() else null
		if node != null and node.output_port_type() == Pasture3DGraphNode.PortType.PATH:
			in_g.append(-1)
			continue
		var path := _path_operand_of(int(ni), p_inputs_of)
		if path == null:
			in_g.append(-1)
			continue
		var key := path.get_instance_id()
		if not by_id.has(key):
			by_id[key] = geom.size()
			geom.append(_geom_entry(path))
		in_g.append(int(by_id[key]))
	return {"in_g": in_g, "geom": geom}


## True when every node feeding the output has an op the native whole-graph evaluator implements.
## Set to hold a graph on the GDScript evaluator no matter what it contains. Not exported and not a user
## setting — it exists so that the things which live ONLY on the script path (per-node caching, a solver's
## frozen cache) can be tested for what they are, instead of a gate having to smuggle in whichever native
## limitation happens to survive. GraphNodeCachingGate used to force the path with a wire into port 4;
## when that stopped declining, the gate went red rather than vacuous, but the lesson is that a premise
## should be stated, not borrowed.
var force_gdscript_evaluation := false


## ---- THE STAGED COMPILE (spec 8.4, phase S7b) ---------------------------------------------------
##
## Set to hold a graph containing derive nodes on the S7a route: the whole-graph bail, GDScript, correct
## and slow. Not a user setting -- it is the control PathStagedCompileGate needs, because the staged and
## unstaged routes are supposed to produce the SAME terrain, and a staged route that quietly did nothing
## would agree with the reference for the most boring possible reason.
var force_no_staged_compile := false

## Counts staged compiles that actually ran. Read by the gates for the same reason `eval_path_count` is:
## "the terrain is right" is equally true of a staged run and of one that fell through to GDScript, and
## the whole point of S7b is WHICH of those happened.
var staged_compile_count: int = 0


## Counts `evaluate()` calls that actually ran. Read by criterion [G] of the visualization spec, which
## exists to hold the line standing constraint 2 draws: PREVIEWS ARE NEVER PAID FOR BY `evaluate()`. The
## thumbnail path taps a compiled program directly (`graph_eval_grid_taps`) and the `preview_on` toggle is
## an instant show/hide, so a preview refresh — and every toggle — must leave this number where it was.
##
## Counted rather than reasoned about, because "the preview looked instant on my machine" is not a
## measurement, and a regression here would present as an editor that merely got slower.
var evaluate_count: int = 0


## Memoised per [root, revision]. The answer is a function of TOPOLOGY, the op set, and mute state, all of
## which bump `_revision` when they change on a node that feeds the output — and a node that does not feed
## the output is not in `order`, so it cannot change the answer either.
##
## Deliberately NOT extended to memoise `compile_graph_program`'s RESULT. A compiled program copies the
## nodes' values into flat arrays; memoising those bytes means a source that mutates without announcing
## it leaves the program silently stale, which is a failure mode this project has already paid for once.
## This cache holds a bool derived from structure, which has no such copy to go stale.
var _native_ok_cache: Dictionary = {}   # [root, revision] -> bool


func native_supported(p_root_node: int = -1) -> bool:
	if force_gdscript_evaluation:
		return false
	if needs_flat() and is_compatible():
		var froot := _flat_root(p_root_node)
		return false if froot == FLAT_NO_ROOT else flat_view().native_supported(froot)
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return false
	# A 5-spline brush with a graph modifier asked this question five times per bake, each answer an
	# O(E*V) walk with an `Array.has()` scan inside it, for five identical answers.
	var ck := [out, _revision]
	if _native_ok_cache.has(ck):
		return _native_ok_cache[ck]
	var ok := _native_supported_uncached(out)
	# One entry per revision, and a revision is only reachable while it is current — so the dictionary
	# would grow one entry per edit for the resource's lifetime. It answers exactly one revision at a
	# time, so clearing it is free.
	_native_ok_cache.clear()
	_native_ok_cache[ck] = ok
	return ok


## True when the only thing keeping this graph off the native tier is the S7a derive family.
##
## Asked by `evaluate` before it stages. Deliberately NOT folded into `native_supported`, which stays the
## honest answer to "can this graph be compiled and handed to a worker": a derive node's capture happens
## during evaluation on the main thread, so a program compiled without staging carries a path that is
## stale or absent, and the off-thread contract at the top of `evaluate` would be quietly broken.
func _native_supported_if_staged(p_out: int) -> bool:
	if force_gdscript_evaluation or force_no_staged_compile:
		return false
	if needs_flat() and is_compatible():
		var fr := _flat_root(p_out)
		return false if fr == FLAT_NO_ROOT else flat_view()._native_supported_if_staged(fr)
	# The cheap question first. `_native_supported_uncached` is an O(E*V) walk and it is NOT memoised on
	# this route -- the memo is keyed on [root, revision] and would collide with `native_supported`'s own
	# answer for the same pair, which is a different question with a different answer. A graph with no
	# derive node in it can never be staged, and that is one O(V) scan rather than the walk, paid by every
	# bake of every ordinary graph in the project.
	var any := false
	for nd in nodes:
		if nd != null and nd.derives_path_from_grid():
			any = true
			break
	if not any:
		return false
	return _native_supported_uncached(p_out, true)


## True when this graph lowers to the native evaluator, and NOTHING ELSE. The reason it does not is
## `native_block_report`'s business, and both read the same scan below — one rule, one place. A second
## implementation of "why did this not lower" would drift from the one that decides, and it would drift
## silently, because the report is only read when the answer is already "no".
func _native_supported_uncached(p_out: int, p_ignore_derives: bool = false) -> bool:
	return _native_block_scan(p_out, p_ignore_derives).is_empty()


## WHY a graph does not lower, as `{"reason", "node", "op", "detail"}`, or `{}` when it does.
##
## Spec §5.5, the second half: "a frozen thumbnail must never be indistinguishable from a live one". A
## graph that does not lower leaves the preview showing whatever it last managed to render, forever, with
## nothing on screen saying so — and per `op-ids-omission-drops-graph-to-gdscript` the usual cause is a
## single node, which this can name.
##
## `node` is -1 when no single node is responsible (an empty evaluation order, a wiring-level refusal).
## Callers must not treat -1 as "no block": the presence of `reason` is the answer.
##
## This walks; it does not consult `_native_ok_cache`. It is called when something has already gone wrong
## and a thumbnail is about to be marked stale, which is not a path worth memoising.
func native_block_report(p_root_node: Variant = -1) -> Dictionary:
	if force_gdscript_evaluation:
		return {"reason": "force_gdscript_evaluation is on", "node": -1, "op": &"", "detail": ""}
	if p_root_node is Array:
		return native_block_report_multi(p_root_node)
	if needs_flat() and is_compatible():
		var froot := _flat_root(int(p_root_node))
		if froot == FLAT_NO_ROOT:
			return {"reason": "the subgraph has no output port", "node": int(p_root_node), "op": &"subgraph", "detail": ""}
		return _flat_report(flat_view().native_block_report(froot))
	var out: int = int(p_root_node) if (int(p_root_node) >= 0 and int(p_root_node) < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {"reason": "the graph has no output node", "node": -1, "op": &"", "detail": ""}
	return _native_block_scan(out, false)


## Multi-root diagnostic scan explaining why compile_graph_program_multi(p_roots) failed.
func native_block_report_multi(p_roots: Array, p_ignore_derives: bool = false) -> Dictionary:
	if force_gdscript_evaluation:
		return {"reason": "force_gdscript_evaluation is on", "node": -1, "op": &"", "detail": ""}
	if p_roots.is_empty():
		return {"reason": "the root list is empty", "node": -1, "op": &"", "detail": ""}
	if needs_flat() and is_compatible():
		var fv := flat_view()
		return _flat_report(fv.native_block_report_multi(_flat_roots_of(p_roots), p_ignore_derives))
	var order := _eval_order_multi(p_roots)
	if order.is_empty():
		return {"reason": "the graph has no evaluation order (empty, or a cycle)",
				"node": -1, "op": &"", "detail": ""}
	return _native_block_scan_order(order, p_ignore_derives)


## The single scan both of the above read. Returns `{}` when the graph lowers, or the FIRST block found,
## in the order the original guards ran — the order matters, because a graph can be blocked in more than
## one way and the first is the one worth naming.
func _native_block_scan(p_out: int, p_ignore_derives: bool = false) -> Dictionary:
	var out := p_out
	var order := _eval_order(out)
	if order.is_empty():
		return {"reason": "the graph has no evaluation order (empty, or a cycle)",
				"node": -1, "op": &"", "detail": ""}
	return _native_block_scan_order(order, p_ignore_derives)


func _native_block_scan_order(order: Array, p_ignore_derives: bool = false) -> Dictionary:
	# The allow-list used to be restated here as 63 op tags. It is `op_ids()` now — the same C++ list the
	# lowering reads its id from, so "the native evaluator implements this op" is one fact rather than two
	# that had to be kept in step. Forgetting an entry used to be silent: it did not fail, it dropped the
	# WHOLE graph onto the script evaluator, which is how DLA ran unlowered for as long as it did.
	var supported := op_ids()
	for ni in order:
		if nodes[ni] == null:
			return {"reason": "a node in the evaluation order is null", "node": ni, "op": &"", "detail": ""}
		if not nodes[ni].muted and not supported.has(nodes[ni].op()):
			# THE common case, and the one worth naming loudest: an op the native evaluator does not
			# implement, or one simply missing from `graph_op_ids()`. Either way the WHOLE graph drops to
			# the GDScript evaluator — erosion included — and until now it did so without a word.
			return {"reason": "the native evaluator has no op for this node",
					"node": ni, "op": nodes[ni].op(),
					"detail": "add it to graph_op_ids() in src/pasture_3d_util.cpp, or mute the node"}
		# A FROZEN solver owns a cache the native program knows nothing about. Lowering it silently re-solved
		# on every evaluation and never reported itself stale, so the freeze looked like it worked while doing
		# nothing at all — which is worse than being slow. Only DLA escaped it, and only because its op was
		# never added to the allow-list above.
		if nodes[ni] != null and not nodes[ni].muted and nodes[ni].blocks_native():
			# S7b: a derive node blocks a SINGLE-program compile and does not block a staged one. Its
			# path is produced before the remainder is compiled and travels in the geometry table, so
			# what reaches the kernel is one flat polyline -- the same thing an S4 filter hands it.
			if not (p_ignore_derives and nodes[ni].derives_path_from_grid()):
				return {"reason": "this node owns a cache the native program cannot see (frozen solver "
						+ "or grid-to-path derive)", "node": ni, "op": nodes[ni].op(),
						"detail": "unfreeze it, or accept the GDScript evaluator for this graph"}
	# A wire out of a secondary port (port >= 1, e.g. a solver's flow field) used to drop the whole graph
	# to the GDScript evaluator unconditionally. Since P2b the program can carry channels, so the bail
	# narrows to the case that is still unlowerable: reading a channel the NATIVE op does not write.
	#
	# Narrowed, not deleted. `native_out_count` reports the kernel's channels, not the node's, so an op
	# that offers five outputs in the editor and implements one in C++ still refuses — which is the whole
	# point, because lowering it would serve a field of zeros that looks exactly like a real answer.
	#
	# A secondary channel driving a port >= 4 used to refuse too, because the pdrv_* overflow table carried
	# no channel. It carries one now (`pdrv_chan`) — Measure's max into Curve's out_max is that wire — so
	# only the unwritten-channel case is left.
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if order.has(to_node) and order.has(from_node) and int(c[1]) >= native_out_count(from_node):
				return {"reason": "a wire reads a secondary channel the native op does not write",
						"node": from_node, "op": nodes[from_node].op() if nodes[from_node] != null else &"",
						"detail": "channel %d of %d native channels, into port %d"
								% [int(c[1]), native_out_count(from_node), int(c[3])]}
	# A compiled program carries four GRID slots, in0..in3, so a wire into port 4 or beyond has no in-slot.
	# A driven SCALAR does not need one — the native evaluator reads cell 0 of the source buffer, and those
	# ports now travel in the flat pdrv_* overflow table (see `native_param_ports`). A port >= 4 the node
	# does not map is a real grid input with nowhere to go, and the kernel would fall back to the baked
	# local value without saying so, which is exactly the silent-drop this guard exists to stop.
	for c in connections:
		if c.size() >= 4 and int(c[3]) >= 4:
			var to_node := int(c[2])
			if not order.has(to_node) or nodes[to_node] == null:
				continue
			if int(c[3]) == nodes[to_node].aux_grid_port():
				continue # a declared grid operand rides in_aux, muted or not
			if int(c[3]) == nodes[to_node].framework_mask_port():
				continue # the graph's own Blend slot reads it, not the node's op (`_emit_program`)
			if nodes[to_node].muted:
				# muted lowers to passthrough, which carries no params at all
				return {"reason": "a wire drives a high port on a MUTED node, which lowers to passthrough",
						"node": to_node, "op": nodes[to_node].op(), "detail": "port %d" % int(c[3])}
			var pm := nodes[to_node].native_param_ports()
			var port := int(c[3])
			if port >= pm.size() or int(pm[port]) < 0:
				return {"reason": "a wire drives a port the native op has no parameter slot for",
						"node": to_node, "op": nodes[to_node].op(),
						"detail": "port %d is not in native_param_ports()" % port}
	return {}



## The pre-fold reference: materialise EVERY node's grid (increment 1's evaluator). Kept as the oracle the
## folded `evaluate` is checked against — GraphFoldGate asserts they agree to float32 rounding.
func _eval_unfolded(p_gw: int, p_gh: int, p_rect: Rect2, p_mask = null, p_input = null) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return Pasture3DGraphOps.zeros(n)
	var order := _eval_order()
	if order.is_empty():
		return Pasture3DGraphOps.zeros(n)
	var grids := {}
	var aux := {}
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		if node.op() == &"input":
			grids[ni] = _surface_grid(p_input, n)
			if reads_footprint():
				aux[ni] = {1: footprint_grid(host_footprint, p_gw, p_gh, p_rect)}
			continue
		var in_grids := _input_grids(ni, grids, aux, n, p_input)
		if node.muted:
			grids[ni] = (in_grids[0] as PackedFloat32Array) if not in_grids.is_empty() else Pasture3DGraphOps.zeros(n)
		elif node.op() == &"noise_jordan" or node.op() == &"noise_swiss" or node.op() == &"furrows" or node.op() == &"dunes" or node.op() == &"fractal":
			# These are cell nodes, so the generic branch below would evaluate them one cell at a time in
			# script; each has a whole-grid kernel, and this shortcut takes it. It must still go through
			# `eval_grid(in_grids, ...)` — the previous version called the Pasture3DUtil kernel directly with
			# `node.<property>`, which threw away every wire into a parameter port. A Const driving an
			# amplitude did nothing, silently. Matches the same branch in `evaluate()`.
			grids[ni] = node.eval_grid(_input_grids(ni, grids, aux, n, p_input), p_gw, p_gh, p_mask, p_rect)
		elif node.needs_grid() and node.output_count() > 1:
			var chans: Array = node.eval_grid_channels(in_grids, p_gw, p_gh, p_mask, p_rect)
			grids[ni] = chans[0]
			var ax := {}
			for pi in range(1, chans.size()):
				ax[pi] = chans[pi]
			aux[ni] = ax
		elif node.needs_grid():
			grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
		else:
			var g := PackedFloat32Array()
			g.resize(n)
			var cell_in := PackedFloat32Array()
			cell_in.resize(in_grids.size())
			for iz in range(p_gh):
				var row := iz * p_gw
				for ix in range(p_gw):
					var w := cell_to_world(ix, iz, p_gw, p_gh, p_rect)
					for k in range(in_grids.size()):
						cell_in[k] = (in_grids[k] as PackedFloat32Array)[row + ix]
					g[row + ix] = node.eval_cell(w.x, w.y, cell_in)
			grids[ni] = g
		grids[ni] = _with_standard_mask(ni, grids[ni], grids, aux, n)
	return grids[out]


## The input grids for node `p_ni`, one per input port in port order; an unwired port reads zeros so a
## missing connection is a clean 0, not an error. Channel-aware: a connection from a multi-output source's
## port >= 1 reads that channel out of `p_aux[from]`, so a grid node can consume a solver's mask channel.
func _input_grids(p_ni: int, p_grids: Dictionary, p_aux: Dictionary, p_n: int, p_input = null) -> Array:
	var node: Pasture3DGraphNode = nodes[p_ni]
	var count: int = node.input_count()
	var types: PackedInt32Array = node.input_port_types()
	var out: Array = []
	out.resize(count)
	for p in range(count):
		var dv: float = node.input_unwired_default(p)
		if node.derives_path_from_grid() and p < types.size() and int(types[p]) == Pasture3DGraphNode.PortType.HEIGHT and p_input != null and (p_input is PackedFloat32Array) and not (p_input as PackedFloat32Array).is_empty():
			out[p] = _surface_grid(p_input, p_n)
		else:
			out[p] = Pasture3DGraphOps.zeros(p_n) if is_zero_approx(dv) else Pasture3DGraphOps.filled(p_n, dv)
	for c in connections:
		if c.size() >= 4 and int(c[2]) == p_ni:
			var to_port := int(c[3])
			var from := int(c[0])
			var from_port := int(c[1])
			if to_port >= 0 and to_port < count:
				out[to_port] = _read_channel(from, from_port, p_grids, p_aux, p_n)
	# A mask the graph applies is never handed to the node (spec §9.1). It is always the last port, so
	# dropping it moves no other index.
	if node.framework_mask_port() >= 0:
		out.resize(count - 1)
	return out


## `p_grid`, node `p_ni`'s port 0 as the node produced it, with the standard mask applied when the graph
## applies it and it is wired. The GDScript half of `_emit_program`'s mask slot.
func _with_standard_mask(p_ni: int, p_grid: PackedFloat32Array, p_grids: Dictionary, p_aux: Dictionary, p_n: int) -> PackedFloat32Array:
	var node: Pasture3DGraphNode = nodes[p_ni]
	var mp := node.framework_mask_port()
	if mp < 0 or node.muted:
		return p_grid
	var mask_grid := PackedFloat32Array()
	var in_grid := PackedFloat32Array()
	for c in connections:
		if c.size() >= 4 and int(c[2]) == p_ni:
			if int(c[3]) == mp:
				mask_grid = _read_channel(int(c[0]), int(c[1]), p_grids, p_aux, p_n)
			elif int(c[3]) == 0:
				in_grid = _read_channel(int(c[0]), int(c[1]), p_grids, p_aux, p_n)
	if mask_grid.is_empty():
		return p_grid
	if in_grid.is_empty():
		in_grid = Pasture3DGraphOps.filled(p_n, node.input_unwired_default(0))
	return apply_standard_mask(in_grid, p_grid, mask_grid)


## One source node's output grid at `p_from_port`: port 0 comes from the materialised `p_grids` slot;
## a port >= 1 comes from `p_aux[p_from]` (a multi-output solver's derived channel). Reads zeros when the
## source has not materialised or lacks that channel, so a stale wire is a clean 0.
func _read_channel(p_from: int, p_from_port: int, p_grids: Dictionary, p_aux: Dictionary, p_n: int) -> PackedFloat32Array:
	if p_from_port <= 0:
		return p_grids[p_from] if p_grids.has(p_from) else Pasture3DGraphOps.zeros(p_n)
	if p_aux.has(p_from) and (p_aux[p_from] as Dictionary).has(p_from_port):
		return p_aux[p_from][p_from_port]
	return Pasture3DGraphOps.zeros(p_n)


## Topological order of exactly the nodes that feed the output (`output_index`). Empty if the output is
## unreachable or its ancestry contains a cycle (Kahn leaves nodes unresolved). Restricting to ancestors
## means a stray disconnected node neither runs nor breaks the sort.
func _eval_order(p_root: int = -1) -> Array:
	# A refused graph has no order, whatever root is named. Every compiler and the native check start here,
	# so none of them reads a node or a wire of a layout this plugin does not understand.
	if not is_compatible():
		return []
	# 1. Ancestor set: walk connections backwards from the root.
	var root := p_root if (p_root >= 0 and p_root < nodes.size()) else output_index()
	if root < 0 or root >= nodes.size() or nodes[root] == null:
		return []
	# Topology-only result — served from cache until `structure_changed` clears it. Read-only for callers.
	if _order_cache.has(root):
		return _order_cache[root]
	var needed := {root: true}
	var frontier: Array = [root]
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[2]) == cur and not _is_color_wire(c):
				var from := int(c[0])
				# `nodes[from] != null` is not belt-and-braces: a .tres whose node script failed to load
				# (renamed script, or a dev-flag script absent from a build) leaves a null in `nodes`, and
				# `_fold_plan` calls `nodes[ni].input_count()` unguarded. Dropping it from the ancestor set
				# leaves the downstream port unwired, which binds the zero buffer — the flat zero field
				# `evaluate` already promises for an unusable graph, instead of a crash.
				if from >= 0 and from < nodes.size() and nodes[from] != null and not needed.has(from):
					needed[from] = true
					frontier.push_back(from)
	# 2. Kahn's algorithm over edges internal to the ancestor set.
	var indeg := {}
	for ni in needed:
		indeg[ni] = 0
	for c in connections:
		if c.size() >= 4:
			var from := int(c[0])
			var to := int(c[2])
			if needed.has(from) and needed.has(to):
				indeg[to] += 1
	var ready: Array = []
	for ni in indeg:
		if indeg[ni] == 0:
			ready.push_back(ni)
	var order: Array = []
	while not ready.is_empty():
		var ni: int = ready.pop_back()
		order.push_back(ni)
		for c in connections:
			if c.size() >= 4 and int(c[0]) == ni and needed.has(int(c[2])):
				var to := int(c[2])
				indeg[to] -= 1
				if indeg[to] == 0:
					ready.push_back(to)
	if order.size() != needed.size():
		order = [] # a cycle in the output's ancestry
	_order_cache[root] = order
	return order


## True when the output's ancestry contains a cycle — surfaced as a warning and the reason `evaluate`
## returns a flat field.
func has_cycle() -> bool:
	var out := output_index()
	return out >= 0 and out < nodes.size() and nodes[out] != null \
			and _eval_order().is_empty()


## Problems worth telling the user about, for a host's configuration warnings: a missing output, a cycle,
## a null node, an unwired required input, plus each node's own complaints.
## `p_in_brush` is passed by the host, not stored on the graph: the same .tres is meant to drive a whole
## landscape AND sit in a brush, so "am I in a brush" is a fact about the caller and cannot be cached here.
func graph_warnings(p_in_brush: bool = false) -> PackedStringArray:
	var w := PackedStringArray()
	# The one line, and nothing else: every other check below reads nodes and wires by a layout this
	# plugin does not understand, and "no output node" would be the wrong thing to tell the author.
	if not is_compatible():
		w.append(format_refusal())
		return w
	if output_index() < 0 or output_index() >= nodes.size():
		w.append("Terrain graph has no output node set. Add an Output node (or Set as Output on a node), "
			+ "or it evaluates to a flat 0.")
		return w
	if has_cycle():
		w.append("Terrain graph has a cycle feeding its output, so it evaluates to a flat 0. Remove a "
			+ "connection to break the loop.")
	if needs_flat():
		# Building the view is what finds a graph that contains itself (§11.3).
		flat_view()
		w.append_array(_flat_notes)
	# Unwired required inputs (a filter/combiner with a port nothing connects to).
	for ni in range(nodes.size()):
		var node: Pasture3DGraphNode = nodes[ni]
		if node == null:
			w.append("Terrain graph node %d is empty (null)." % ni)
			continue
		var wired := {}
		for c in connections:
			if c.size() >= 4 and int(c[2]) == ni:
				wired[int(c[3])] = true
		# Only a port its node declares REQUIRED. A mask that reads 1 unwired, or an `amount` the node's
		# own property supplies, is a port working as designed; warning on those buried the real ones.
		var ports := node.input_ports()
		for p in range(ports.size()):
			if ports[p].required and not wired.has(p):
				w.append("%s: input '%s' is unconnected and reads %s." % [node.display_name(), ports[p].label,
						String.num(node.input_unwired_default(p), 3)])
		w.append_array(node.node_warnings())
		if p_in_brush:
			w.append_array(node.node_warnings_in_brush())
	# Declarations a Parameter node or a host cannot name.
	var seen_ids := {}
	for pi in range(parameters.size()):
		var decl: Pasture3DGraphParam = parameters[pi]
		if decl == null:
			continue
		if decl.id == &"":
			w.append("Graph parameter %d has no id, so nothing can read it." % pi)
		elif seen_ids.has(decl.id):
			w.append("Graph parameter '%s' is declared twice; the second declaration is ignored." % decl.id)
		seen_ids[decl.id] = true
	# What the load could not place. These wires are GONE from the graph, and from the file at its next save.
	for d in _wires_dropped:
		w.append("A saved wire was dropped: %s." % d)
	# Wires `connect_ports` would refuse today, assigned through `connections` directly. They still
	# evaluate (a wire is a pair of indices), so say so rather than drop them.
	for c in connections:
		if c.size() < 4:
			continue
		var why := wire_problem(int(c[0]), int(c[1]), int(c[2]), int(c[3]))
		if why == "":
			continue
		if wire_reads_cell_zero(int(c[0]), int(c[1]), int(c[2]), int(c[3])):
			var src: Pasture3DGraphNode = nodes[int(c[0])]
			var dst: Pasture3DGraphNode = nodes[int(c[2])]
			w.append(("%s: input '%s' is wired to %s '%s', which is a field, and reads cell 0 of it: one "
					+ "arbitrary cell. Put a Measure between them to choose the number.") % [
					dst.display_name(), dst.input_ports()[int(c[3])].label,
					src.display_name(), src.output_ports()[int(c[1])].label])
		else:
			w.append("A wire is not valid: %s." % why)
	return w
