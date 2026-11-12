# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNode — abstract base for one node of a Pasture3DTerrainGraph. A node reads zero or more
# input height grids and produces one output height grid; the graph wires them into a DAG and evaluates
# in topological order (Pasture3DTerrainGraph.evaluate).
#
# ---- CELL vs GRID, the same split the brush node stack rests on ----
#
# The distinction is `needs_grid()`, lifted from Pasture3DNode (see PASTURE3D_NODE_VOCABULARY.md):
#
#   A CELL node is point-evaluable: `eval_cell(wx, wz, inputs)` sees one cell — its world XZ and its
#   inputs' values THERE — and returns that cell's output. Noise, Const and Blend are cell nodes. A run
#   of them can (later) fold into one loop, exactly as the stack folds a run of cell modifiers.
#
#   A GRID node needs the whole grid: `eval_grid(inputs, gw, gh, mask)` reads neighbours or routes across
#   the field — a blur, an erosion solve. It cannot be expressed per-cell, which is the structural reason
#   the two entry points exist.
#
# In increment 1 the evaluator materialises one grid per node either way (it loops cells calling
# eval_cell for a cell node, or calls eval_grid once for a grid node). The FOLD — fusing a run of cell
# nodes into a single pass, then a C++/GPU backend — is a later optimisation, not a correctness concern.
#
# ---- op() is the dispatch tag, a SUPERSET of the stack's ----
#
# `op()` names the operation the way Pasture3DNode.op() does (&"noise", &"smooth", …). The graph's op
# vocabulary is deliberately a superset of the stack's so the two collapse into one system rather than
# diverging; a node that shares a stack op's name must compute the same thing.
@tool
class_name Pasture3DGraphNode
extends Resource

## What a node does to the field, so the editor palette and the (later) fold can group nodes without
## parsing their op. GENERATOR takes no input and makes a field; FILTER transforms one input; COMBINER
## merges several; SOLVER takes an input field and iterates/routes a simulation over it (Scree, DLA,
## Erosion). A SOLVER is always a grid node, and it is the category that may expose MULTIPLE outputs — a
## primary height plus derived channels (a deposition/flow/wetness mask) that downstream Mask/Blend nodes
## read. See PASTURE3D_TERRAIN_GRAPH_SPEC.md (Solvers).
enum Role { GENERATOR, FILTER, COMBINER, SOLVER }

## Asks whoever is editing this graph to act on this node: `&"auto_fit"`, `&"capture"`. A node is a Resource
## and cannot see its graph or evaluate its own upstream, so an inspector button that needs a measurement
## emits this and the graph editor answers. With no graph editor open nobody is listening and it does nothing.
signal editor_action_requested(p_action: StringName)

## A view onto `resource_name`, so a graph of three Blend nodes does not read as three identical rows in
## the editor. EDITOR-only, not stored twice: `resource_name` already serialises. Mirrors
## Pasture3DNode.label.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		resource_name = v
	get:
		return resource_name

## Where this node sits on the graph editor canvas, in GraphEdit offset units. Persisted so a layout
## survives a reload. Deliberately does NOT emit `changed`: moving a node is not a reason to re-bake the
## terrain, only a reason to re-save the layout.
@export var graph_position: Vector2 = Vector2.ZERO

## When muted, this node is bypassed during graph evaluation (passes its first input through, or 0.0).
@export var muted: bool = false:
	set(v):
		muted = v
		emit_changed()

## When collapsed, the editor hides internal inline controls, displaying a compact header with port slots.
@export var collapsed: bool = false

## When true, the graph editor shows this node's inline 2D thumbnail. Pure toggle state — the editor owns
## all preview rendering; the node stores nothing about the preview beyond these flags.
@export var preview_on: bool = false

# ---- Preview VIEW STATE (visualization spec §5.6, §12.6) ----------------------------------------------
#
# These live on the resource, beside `preview_on`, rather than in an editor-side side table: one
# serialization site, and no lifetime question about what happens to an entry when a node is deleted.
#
# EVERY ONE OF THEM IS A PLAIN `@export` WITH NO SETTER, AND THAT IS THE POINT (§12.6). A setter that
# called `emit_changed()` would put the choice of how to LOOK at a field into the graph revision, which
# would invalidate the cache and re-evaluate the graph — so changing a ramp would cost a bake, and
# `preview_on` would stop being the instant show/hide it is documented to be. View state must never
# participate in invalidation or caching.

## Which representation the thumbnail draws (a `Pasture3DUtil.PreviewRepr`). -1 means "choose from the
## port type", which is the default and what §12.3 wants: representation comes from the declared TYPE,
## never from the port's name. A value >= 0 is an explicit per-node override from the right-click menu.
@export var preview_repr: int = -1

## When true the thumbnail renders against `preview_range_min/max` instead of the field's own extremes.
## This is §5.2 rule 3, and it is the direct fix for "the slider does nothing": with the range pinned, a
## gain change visibly moves the picture instead of being normalised straight back out of view.
@export var preview_range_locked: bool = false

## The pinned range, meaningful only while `preview_range_locked`. Values outside it render in the
## reserved out-of-range colour rather than as the endpoint (§5.2 rule 4) — otherwise the lock would
## trade one silent lie for another.
@export var preview_range_min: float = 0.0
@export var preview_range_max: float = 1.0

# ---- Per-Node Output Buffer Caching (Milestone 1) ----------------------------------------------------
var _cached_grid: PackedFloat32Array = PackedFloat32Array()
var _cached_aux: Dictionary = {}
var _dirty_revision: int = 1
var _last_baked_revision: int = -1
var _inputs_hash: int = 0
var _last_access_tick: int = 0


func _init() -> void:
	changed.connect(_on_node_changed_bump_revision)


func _on_node_changed_bump_revision() -> void:
	_dirty_revision += 1


## Call from every property setter. `@export` assignment emits NO `Resource.changed` in GDScript, so a
## node whose parameters are plain `@export` vars with no setter is INVISIBLE to invalidation: its
## `_dirty_revision` never moves, `_compute_node_inputs_hash` does not read parameters either, and the
## node serves its first grid forever while the host graph never even schedules a re-bake.
##
## Solver nodes override this to mark their private solve stale as well; the base is just the signal.
func _param_changed() -> void:
	emit_changed()


# ---- One cache slot per HOST ------------------------------------------------------------------------
#
# A graph is shared by every brush that hosts it, and each brush evaluates it on its own ground, so a single
# cache slot per node meant the brushes evicting each other on every bake: host A filled it, host B's inputs
# missed and overwrote it, A missed again. Worse, a FROZEN solver's slot was SERVED to the next host (the
# native route serves a frozen solve by grid shape alone), so brush B baked brush A's erosion.
#
# The graph therefore selects a host before every evaluation (`Pasture3DTerrainGraph.set_host_params`), and
# every node swaps its cache fields for that host's. Everything that reads `_cached_grid`, `_inputs_hash` or a
# solver's `_cache` keeps reading one slot, which is now the current host's. 0 is "no host" (a graph edited
# or tested on its own).

## The host whose cache is in the live fields.
var _host_slot: int = 0
## Every other host's state, `{host id: Dictionary}` as `_slot_state` builds it.
var _host_slots: Dictionary = {}
## How many other hosts may keep a GRID here. Grids are the GDScript route's per-node buffers and cost a
## full grid each; past this the oldest host's grid is dropped (it re-evaluates, nothing is wrong). A
## solver's frozen solve is never dropped this way: it is work the author asked to keep.
const MAX_HOST_GRIDS := 8


## Make `p_host`'s cache the live one. Emits nothing.
func select_host(p_host: int) -> void:
	if p_host == _host_slot:
		return
	var st := _slot_state()
	if not st.is_empty():
		_host_slots[_host_slot] = st
	var incoming: Dictionary = _host_slots.get(p_host, {})
	_host_slots.erase(p_host)
	_apply_slot_state(incoming)
	_host_slot = p_host
	_trim_host_grids()


func host_slot() -> int:
	return _host_slot


## The live per-host state, or {} when there is nothing worth keeping. Solvers extend it.
func _slot_state() -> Dictionary:
	if _cached_grid.is_empty():
		return {}
	return {"grid": _cached_grid, "aux": _cached_aux, "baked": _last_baked_revision, "hash": _inputs_hash,
			"tick": _last_access_tick}


## Load a state `_slot_state` built ({} for a host never seen). Solvers extend it.
func _apply_slot_state(p_st: Dictionary) -> void:
	_cached_grid = p_st.get("grid", PackedFloat32Array())
	_cached_aux = p_st.get("aux", {})
	_last_baked_revision = int(p_st.get("baked", -1))
	_inputs_hash = int(p_st.get("hash", 0))
	_last_access_tick = int(p_st.get("tick", 0))


func _trim_host_grids() -> void:
	var with_grid: Array = []
	for h in _host_slots:
		if (_host_slots[h] as Dictionary).has("grid"):
			with_grid.append(h)
	if with_grid.size() <= MAX_HOST_GRIDS:
		return
	with_grid.sort_custom(func(a, b): return int(_host_slots[a].get("tick", 0)) < int(_host_slots[b].get("tick", 0)))
	for i in range(with_grid.size() - MAX_HOST_GRIDS):
		var st: Dictionary = _host_slots[with_grid[i]]
		for k in ["grid", "aux", "baked", "hash", "tick"]:
			st.erase(k)
		if st.is_empty():
			_host_slots.erase(with_grid[i])


## Returns true if the node needs re-evaluation (its properties changed, inputs signature changed, or cache empty).
func is_dirty(p_inputs_hash: int) -> bool:
	if _cached_grid.is_empty():
		return true
	if _dirty_revision != _last_baked_revision:
		return true
	if _inputs_hash != p_inputs_hash:
		return true
	return false


## Stores primary output grid and auxiliary channel grids in the node's local cache.
func store_cache(p_grid: PackedFloat32Array, p_aux: Dictionary, p_inputs_hash: int, p_access_tick: int = 0) -> void:
	_cached_grid = p_grid
	_cached_aux = p_aux
	_last_baked_revision = _dirty_revision
	_inputs_hash = p_inputs_hash
	_last_access_tick = p_access_tick


## Clears this node's cached buffers and resets cache revisions. NOT for overriding — a solver with its
## own private cache overrides `_clear_solver_cache()` below, which this calls.
##
## It used to be the override point, and all twenty solver nodes took it: each cleared its own `_cache`
## and none called `super`, so the base `_cached_grid` — which is precisely what `get_cache_size_bytes()`
## measures, and which line 681 stores for EVERY node in the eval order — survived. Eviction therefore
## freed zero measured bytes, `get_total_cache_bytes() <= max_cache_bytes` never became true, and the
## loop walked the entire list clearing every node in the graph. Each override's `emit_changed()` then
## destroyed a FROZEN solve, which is the expensive work the freeze exists to skip. Splitting the base
## work from the hook makes skipping it unrepresentable rather than merely discouraged.
func clear_cache() -> void:
	_cached_grid = PackedFloat32Array()
	_cached_aux = {}
	_last_baked_revision = -1
	_inputs_hash = 0
	# Every host's grid, not just the live one: the grids of all hosts are what the budget measures.
	for h in _host_slots.keys():
		var st: Dictionary = _host_slots[h]
		for k in ["grid", "aux", "baked", "hash", "tick"]:
			st.erase(k)
		if st.is_empty():
			_host_slots.erase(h)
	_clear_solver_cache()


## The cache key for a solver node's private solve: the grid DIMENSIONS, then every input grid the
## solve actually depends on, in a fixed order.
##
## The twenty solver nodes used to spell this four different ways. Ten wrote
## `hash(gw) ^ (hash(gh) << 1) ^ hash(surface)`; Mudslide folded its mask in and Thermal its hardness
## array (both correct — those really are extra dependencies); and Lake Flooding and Stream Extraction
## used `hash(arr.size()) ^ hash(arr)`, which omits `gw`/`gh` ENTIRELY. A frozen Lake Flooding could not
## tell 512x128 from 128x512: same cell count, same values, same key, and the cached lake surface was
## served against a grid of a different shape. The dependency SET is still each node's own business; the
## rule for turning it into a key is not.
static func solver_cache_key(p_gw: int, p_gh: int, p_grids: Array) -> int:
	var h: int = hash(p_gw) ^ (hash(p_gh) << 1)
	var shift: int = 2
	for g in p_grids:
		shift += 2
		h = h ^ (hash(g) << shift)
	return h


## Override point for a solver node holding a private solve cache. The base does nothing; whatever a
## subclass does here happens IN ADDITION to the buffer reset above, never instead of it.
func _clear_solver_cache() -> void:
	pass


## Returns the primary cached output grid (port 0).
func get_cached_grid() -> PackedFloat32Array:
	return _cached_grid


## Returns the dictionary of cached auxiliary channel grids (ports >= 1).
func get_cached_aux() -> Dictionary:
	return _cached_aux


## Approximate memory footprint in bytes consumed by this node's cached grids.
func get_cache_size_bytes() -> int:
	var total := _grid_bytes(_cached_grid, _cached_aux)
	for h in _host_slots:
		var st: Dictionary = _host_slots[h]
		if st.has("grid"):
			total += _grid_bytes(st["grid"], st.get("aux", {}))
	return total


static func _grid_bytes(p_grid: PackedFloat32Array, p_aux: Dictionary) -> int:
	var total := p_grid.size() * 4
	for k in p_aux:
		var arr = p_aux[k]
		if arr is PackedFloat32Array:
			total += (arr as PackedFloat32Array).size() * 4
	return total



## The dispatch tag. MUST match the string any equivalent stack op / native backend tests.
func op() -> StringName:
	return &""


## Which palette group this node belongs to. Drives nothing in the evaluator; it is authoring metadata.
func role() -> Role:
	return Role.FILTER


## True when this node needs the whole grid (reads neighbours or routes across it). False = a cell node,
## evaluated per cell through `eval_cell`. See the header.
func needs_grid() -> bool:
	return false


## True when this node holds state the native whole-graph evaluator cannot see — in practice, a per-solver
## FROZEN cache. The native program is a pure function of the graph's parameters and its input surface; it
## has no way to serve a cached solve or to notice it has gone stale. A node that answers true takes the
## WHOLE graph off the native path (the bail is graph-wide), which is the price of the cache actually
## working. Solvers that are LIVE must keep answering false, or freezing would cost native everywhere.
func blocks_native() -> bool:
	return false


## True when this node exposes an output port that other nodes can wire from. The Output sink returns
## false — its value is the graph's result, read by the host, not consumed downstream. EDITOR-only (drives
## whether a right-side slot is drawn); the evaluator reads the output through `output_index`.
func has_output() -> bool:
	return true


## Port data types for visual wiring and validation.
##
## ---- FIELD TYPES vs VALUE TYPES ----
##
## The type says whether a port carries a GRID or a NUMBER, and that is not a convention — it is the
## declaration every other consumer reads. FIELD types (HEIGHT, MASK, FIELD, SIGNED, PATH)
## carry one value per cell; VALUE types (FLOAT, INT, BOOL, VECTOR, CURVE, COLOR) carry one value for the
## whole port. `native_param_ports()` must agree: a value-typed input declares a params slot >= 0, a
## field-typed input declares -1. GraphPortTypeGate [C] asserts exactly that correspondence.
##
## Getting it wrong is silent and looks like a feature: an `amount` port typed MASK is coloured amber, so
## the editor tells the author they may wire a mask FIELD in for per-cell blending. The native evaluator
## reads cell 0 of that buffer and blends uniformly. Seven ports shipped that way.
##
## ---- WHY FOUR SCALAR-FIELD TYPES AND NOT ONE ----
##
## A grid of floats is not self-describing, and the difference decides how it is RENDERED and whether a
## range may be rescaled (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §5.2):
##
##   HEIGHT  terrain, in metres above sea level. Lighting it means something, so it is hillshaded.
##   MASK    bounded [0,1] BY CONSTRUCTION. Rescaling one asserts something false.
##   FIELD   an unsigned quantity in its own units, unbounded — distance, depth, flow, metres eroded.
##   SIGNED  the same, but signed, so zero is meaningful and must land mid-ramp.
##
## The operative test for MASK vs FIELD, arrived at by auditing every channel in the registry: a channel
## is a MASK only if something DIVIDED it into [0,1], and then the divisor is part of its meaning and has
## to be reachable (`Pasture3DGraphNodeMudslide.deposition_divisor()` and `smooth_fill`'s
## `last_deposition_divisor` are the two that do this correctly). A channel that was never divided is a
## FIELD no matter how small its numbers happen to be on the fixture in front of you.
##
## ---- ADDING A TYPE ----
##
## Four steps, and PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md is the long form. Port colour is
## `PORT_COLORS[type % size]`, so a type without a colour silently reuses another's rather than failing.
enum PortType {
	HEIGHT = 0,       # Scalar elevation field (meters) - Sky Blue
	MASK = 1,         # Normalized scalar FIELD [0.0, 1.0], by construction - Amber
	VECTOR = 2,       # RETIRED 2026-11-09 with Const Vector: the bus is scalar floats and cannot carry one.
	CURVE = 3,        # RETIRED 2026-11-09 with Const Curve: a node that takes a curve holds it as a property.
	FLOAT = 4,        # General scalar float VALUE / factor (never a grid) - Cyan
	INT = 5,          # Discrete count / integer value - Navy
	COLOR = 6,        # RGBA color / tint / gradient band - Magenta/Pink
	BOOL = 7,         # Boolean toggle / gate switch - Lime Yellow
	TERRAIN_BUS = 8,  # RETIRED 2026-11-09: no node declares it. Kept so 9..11 and PORT_COLORS keep their indices.
	PATH = 9,         # World-space polyline with per-vertex width (Pasture3DGraphPath) - Dark Slate
	FIELD = 10,       # Unsigned scalar field in its OWN units, unbounded - Yellow-Green
	SIGNED = 11,      # Signed scalar field in its own units; zero is meaningful - Crimson
}


## The PATH this node produces, or null. The ONE thing in the graph that does not travel as a grid.
##
## ---- WHY THERE IS A SIDEBAND AT ALL ----
##
## Every other port carries a PackedFloat32Array because every other port is a FIELD. A road is not: it
## is a centreline and a width, and rasterising it into a grid to send it down a wire would fix its
## resolution at the wire instead of at the consumer and throw away the arc length that makes it a road
## rather than a shape. So a PATH port produces no grid; the evaluator carries the resource beside the
## grids, exactly as it already carries a multi-output solver's `aux` channels beside them.
##
## A node whose output is PATH still occupies a grid slot, filled with zeros. That is deliberate: the
## alternative is a special case in every loop that indexes `grids` by node, in exchange for saving one
## array on one node.
func path_output() -> Pasture3DGraphPath:
	return null


## The PATH this node produces GIVEN its resolved PATH inputs, in input-port order (null for a port that
## is unwired or fed by something producing no path). Spec §8.2.
##
## ---- WHY THIS EXISTS ALONGSIDE `path_output` ----
##
## `path_output` answers "what path do you HOLD" — the right question for a source, which holds one, and
## the only question the graph asked before S4. It is the wrong question for a FILTER: a Path Width holds
## nothing at all, it makes a path out of the one upstream, so a graph that only ever calls `path_output`
## sees null at the filter and hands the carve the raw spline. That is not an error anywhere; it is a
## width setting that silently does nothing.
##
## Defaulting to `path_output()` is what makes every existing source correct without being touched: a
## source ignores its (empty) inputs and returns what it holds, which is exactly what it did before.
##
## ---- RETURN A STABLE INSTANCE ----
##
## A filter that allocates a fresh Pasture3DGraphPath on every call breaks the geometry table's fanout
## dedup, which keys on INSTANCE ID (`_compile_geometry`): two consumers of one filter would name two
## entries and the path would be indexed twice per bake. The graph memoises this call per node so the
## same instance comes back while nothing upstream changed — implementations should mutate their own
## kept instance rather than returning a new one, and must never mutate an INPUT path, which belongs to
## the node upstream and is shared with everyone else reading it.
func eval_path(_p_inputs: Array) -> Pasture3DGraphPath:
	return path_output()


## The path this node last HANDED THE GRAPH, or null if it has never been asked.
##
## LIFTED HERE FROM THE DERIVE FAMILY (visualization spec §6.3, V3). It was written for the gates, and its
## own doc-comment said why: "a test that calls `eval_path` itself measures a fresh call rather than the
## graph's". That reasoning is one layer up from where it was written — it applies to the FEATURE, and the
## thing that would measure nothing is now the author's own eyes.
##
## THE TRAP, concretely. `Pasture3DGraphNodePathDerive.derive_without_grid` returns the input path
## UNCHANGED, which is the right answer for an evaluation that has no grid yet. So a viewport overlay that
## asked a Path Drape for its path outside an evaluation would get the UNDRAPED line and draw it,
## confidently, as the answer. An undraped line on terrain does not look broken. It looks like a path. The
## overlay would pass a naive test and be wrong exactly when the author most needs it — when the drape is
## not working.
##
## So: never resolved means NULL, and a consumer draws nothing. Not the input, not a guess. Absence is the
## honest render.
##
## Written by `Pasture3DTerrainGraph._resolved_path_of` at its every return, which is the only place that
## knows. Not by `eval_path`: a PATH SOURCE is answered by the short-circuit and never reaches `eval_path`
## at all, so recording there would leave every Spline Source and Road Source permanently unresolved, and a
## memo HIT returns without calling it either — which would make the record go stale precisely when the
## memo is doing its job.
var _returned: Pasture3DGraphPath = null


## See `_returned`. Read by the gates and by the V3 viewport overlay; never by an evaluator.
func derived_path() -> Pasture3DGraphPath:
	return _returned


## True when this node produces a PATH out of a GRID it reads (spec 8.4). Only the S7a derive family
## answers true.
##
## It exists because `Pasture3DTerrainGraph._resolved_path_of` short-circuits: a node with no PATH input
## is answered with `path_output()`, which is right for a source -- it holds one -- and silently wrong
## for `Path from Flow`, which holds nothing and makes one out of the water.
func derives_path_from_grid() -> bool:
	return false


## Extra material folded into `_resolved_path_of`'s memo key. Zero for every node whose path is a pure
## function of its path inputs, which is all of them except the derive family.
##
## Nothing else in that key moves when an upstream SOLVER re-solves: the key is the input paths' content
## digests plus this node's own revision, and a river traced out of an erosion field has neither. So
## without a salt the memo would serve the first river it ever traced, forever, and the terrain would be
## right the first time and stale every time after -- the shape of bug `memoised-programs-hide-invalidation`
## already names once.
func path_eval_salt() -> int:
	return 0


## True when this node reads PATH inputs, so the evaluator collects them before calling `eval_grid`.
## Answering true costs one dictionary walk per evaluation and nothing else.
func reads_paths() -> bool:
	return false


## Hand this node its PATH inputs, in INPUT PORT ORDER, with null for a port that is unwired or wired to
## something that produces no path. Called immediately before `eval_grid` and only when `reads_paths()`.
##
## Passed in rather than fetched, because a Resource has no way back to the graph that owns it, and
## giving it one would make every node able to reach every other — which is the property that keeps
## the evaluator's ordering meaningful.
func set_path_inputs(_p_paths: Array) -> void:
	pass


## The PATH a node reads on input port `p_port` when NOTHING is wired there, or null. Both evaluator routes
## ask it — `_path_inputs` for the GDScript hand-off and `_path_operand_of` for the native geometry table —
## so a fallback cannot exist on one route and not the other. A port wired to something that resolves to
## no path still reads null: a wire is a choice, and this only answers for an empty socket.
func unwired_path(_p_port: int) -> Pasture3DGraphPath:
	return null


## Metres past the HOST brush's outline this node writes, at full strength, when it runs inside a brush
## graph (the Leveler's outward wall). The brush widens its footprint by the largest of these and holds the
## graph's composite mask at 1 across that band, so a node that builds its own falloff is neither cropped
## at the rim nor tapered a second time by the brush's. 0 for every node that stays inside the outline.
func outward_reach() -> float:
	return 0.0


## How far, in metres, a change to this node's inputs — or, for a node that reads it, to the HOST brush's
## outline — can move this node's output. The host's dirty-rect bake after a point drag pads the moved span
## by the sum of these along the graph (Pasture3DTerrainGraph.edit_reach); INF sends it whole-footprint.
##
## A cell node not touching paths is pointwise — `eval_cell` sees one cell — so 0. Everything else is INF
## until it says otherwise: a grid node reads neighbours or the whole grid, a path is resampled and measured
## along its length, and a node reading the host outline unwired sees a distance to its nearest edge,
## which a moved span changes arbitrarily far away. Overriding this with a finite value is a claim the
## host's rect bake relies on to stay correct, so it needs a criterion in RectEditReachGate.
func edit_reach() -> float:
	if needs_grid() or reads_paths() or output_port_types().has(PortType.PATH):
		return INF
	return 0.0


## Called once when the palette makes a new node, never when a saved graph loads one. For a default that new
## nodes should get but saved nodes, which omit default values when saved, must not.
func on_created() -> void:
	pass


# ---- PORTS ---------------------------------------------------------------------------------------------
#
# A node declares its ports ONCE, by overriding `_inputs()` and `_outputs()`, and nothing else about
# ports. Every accessor below — `input_count`, `input_names`, `input_port_types`, `input_unwired_default`,
# `native_param_ports`, `aux_grid_port` and the three `output_*` — is FINAL and derived from those two
# lists. They used to be nine separate overrides matched by index, plus the editor's `SLOT_SPINS` table.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6.

## This node's input ports, in port order. Override this; do not override the accessors derived from it.
##
## Called again whenever the node changes, so a node whose ports depend on a property (Measure's output
## name follows its mode) may read its own properties here — provided that property's setter calls
## `_param_changed()`, which is what tells the cache below to ask again.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require()]


## This node's output ports, in port order. See `_inputs()`.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [Pasture3DGraphPort.field(&"out", PortType.HEIGHT)]


# The derived tables. Rebuilt when `_dirty_revision` moves, which is every `changed`. The evaluators call
# the accessors inside per-node loops, so they must cost a comparison, not a list build.
var _ports_revision: int = -1
var _in_ports: Array[Pasture3DGraphPort] = []
var _out_ports: Array[Pasture3DGraphPort] = []
var _in_names := PackedStringArray()
var _in_types := PackedInt32Array()
var _in_slots := PackedInt32Array()
var _in_aux: int = -1
var _out_names := PackedStringArray()
var _out_types := PackedInt32Array()
var _mask_port: int = -1


# ---- THE STANDARD MASK (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §9) -----------------------------
#
# A FILTER or SOLVER whose port 0 input and port 0 output are both HEIGHT modifies a surface, and every
# such node gets one `mask` input from here: id `mask`, type MASK, reads 1 unwired, always the LAST input.
# A node never declares it. What the mask does is one rule,
#
#     out0 = lerp(in0, node_out0, clamp(mask, 0, 1))        a non-finite mask cell reads 1
#
# and `mask_mode()` says who applies it.

## Who applies the standard mask.
##   FRAMEWORK  the graph does: one Blend MIX after the node. The node never sees the mask, on any route.
##   OWN        the node receives it as its last input and applies it itself, because its solve or its
##              secondary outputs depend on it. Same port, same meaning.
##   NONE       no standard mask.
enum MaskMode { FRAMEWORK, OWN, NONE }

## Override to answer OWN or NONE. Ignored by a node the rule above does not select.
func mask_mode() -> MaskMode:
	return MaskMode.FRAMEWORK


const MASK_PORT_ID := &"mask"


## True when `p_in` / `p_out` are the ports of a node the standard-mask rule selects.
func _takes_standard_mask(p_in: Array[Pasture3DGraphPort], p_out: Array[Pasture3DGraphPort]) -> bool:
	if mask_mode() == MaskMode.NONE or not has_output():
		return false
	if role() != Role.FILTER and role() != Role.SOLVER:
		return false
	return not p_in.is_empty() and p_in[0].type == PortType.HEIGHT \
			and not p_out.is_empty() and p_out[0].type == PortType.HEIGHT


## FINAL. The index of the standard mask input, or -1 when this node has none.
func standard_mask_port() -> int:
	_ports_refresh()
	return _mask_port


## FINAL. The index of the standard mask input when the GRAPH applies it, else -1. Every evaluator asks
## this one question: a port it names is never handed to the node.
func framework_mask_port() -> int:
	_ports_refresh()
	return _mask_port if mask_mode() == MaskMode.FRAMEWORK else -1


func _ports_refresh() -> void:
	if _ports_revision == _dirty_revision:
		return
	_in_ports = _inputs()
	_out_ports = _outputs()
	_mask_port = -1
	if _takes_standard_mask(_in_ports, _out_ports):
		var declared := false
		var has_aux := false
		for p in _in_ports:
			declared = declared or p.id == MASK_PORT_ID
			has_aux = has_aux or p.aux
		# A node that declares its own `mask` keeps it and gets no second one: two ports with one id would
		# make every stored wire into either ambiguous. GraphStandardMaskGate [F] is what fails on it.
		if not declared:
			var mp := Pasture3DGraphPort.field(MASK_PORT_ID, PortType.MASK).unwired(1.0)
			# An OWN mask is the node's secondary grid, so it reaches a native kernel wherever it lands.
			if mask_mode() == MaskMode.OWN and not has_aux:
				mp.as_aux()
			_in_ports.append(mp)
			_mask_port = _in_ports.size() - 1
	_in_names = PackedStringArray()
	_in_types = PackedInt32Array()
	_in_slots = PackedInt32Array()
	_in_aux = -1
	var any_slot := false
	for i in range(_in_ports.size()):
		var p := _in_ports[i]
		_in_names.append(p.label)
		_in_types.append(p.type)
		_in_slots.append(p.native_slot)
		any_slot = any_slot or p.native_slot >= 0
		if p.aux and _in_aux < 0:
			_in_aux = i
	# "Empty means no port is a scalar" is what `native_param_ports()` has always documented, and the
	# lowering passes this array into the program as-is.
	if not any_slot:
		_in_slots = PackedInt32Array()
	_out_names = PackedStringArray()
	_out_types = PackedInt32Array()
	for p in _out_ports:
		_out_names.append(p.label)
		_out_types.append(p.type)
	_ports_revision = _dirty_revision


## FINAL. The input port descriptors, in port order.
func input_ports() -> Array[Pasture3DGraphPort]:
	_ports_refresh()
	return _in_ports


## FINAL. The output port descriptors, in port order.
func output_ports() -> Array[Pasture3DGraphPort]:
	_ports_refresh()
	return _out_ports


## FINAL. The index of the input port with this id, or -1.
func input_index_of(p_id: StringName) -> int:
	_ports_refresh()
	for i in range(_in_ports.size()):
		if _in_ports[i].id == p_id:
			return i
	return -1


## FINAL. The index of the output port with this id, or -1.
func output_index_of(p_id: StringName) -> int:
	_ports_refresh()
	for i in range(_out_ports.size()):
		if _out_ports[i].id == p_id:
			return i
	return -1


## Whether a wire from an output of `p_from_type` into an input of `p_to_type` is legal. The ONE
## connection matrix: `Pasture3DTerrainGraph.connect_ports` refuses what this refuses, `graph_warnings`
## reports stored wires that fail it, and the graph editor registers its valid connection types from it.
##
## The scalar types are all a float underneath, and three of the four directions connect:
##   field -> field   the per-cell case.
##   value -> value   one number to one number.
##   value -> field   a uniform fill, which is what a Const Float into a HEIGHT port has always been.
##   field -> value   REFUSED (spec §8). A value port reads cell 0 of its source, so a field wired into one
##                    hands it one arbitrary cell. Measure is the node that reduces a field to a number on
##                    purpose, and the editor offers to insert it. A wire of this kind that is already
##                    stored keeps evaluating and is reported by `graph_warnings` (`reads_cell_zero`).
## COLOR and PATH connect only to themselves: each carries something one float cannot be.
## A RETIRED type (VECTOR, CURVE, TERRAIN_BUS) connects to nothing, itself included: no node declares one,
## and a script that does gets a port nothing can be wired to rather than a wire nothing can carry.
static func can_connect(p_from_type: int, p_to_type: int) -> bool:
	if is_retired_type(p_from_type) or is_retired_type(p_to_type):
		return false
	if p_from_type == p_to_type:
		return true
	if reads_cell_zero(p_from_type, p_to_type):
		return false
	return is_scalar_type(p_from_type) and is_scalar_type(p_to_type)


## True for a wire from a scalar FIELD type into a VALUE type: the one scalar direction `can_connect`
## refuses. The evaluator reads cell 0 of the field, so such a wire still means something when it is
## already stored, which is why this is asked separately from "is the wire legal".
static func reads_cell_zero(p_from_type: int, p_to_type: int) -> bool:
	return is_field_type(p_from_type) and is_scalar_type(p_from_type) and is_value_type(p_to_type)


## True for the types that carry one number for the whole port and travel as a float.
static func is_value_type(p_type: int) -> bool:
	return p_type == PortType.FLOAT or p_type == PortType.INT or p_type == PortType.BOOL


## True for the enum members kept only so the others keep their numbers and colours.
static func is_retired_type(p_type: int) -> bool:
	return p_type == PortType.VECTOR or p_type == PortType.CURVE or p_type == PortType.TERRAIN_BUS


## True for the types that travel as a float per cell or one float for the port, and so interconnect.
static func is_scalar_type(p_type: int) -> bool:
	return p_type == PortType.HEIGHT or p_type == PortType.MASK or p_type == PortType.FIELD \
			or p_type == PortType.SIGNED or p_type == PortType.FLOAT or p_type == PortType.INT \
			or p_type == PortType.BOOL


## The enum key for a port type, for a message. "?" for a number that is not a type.
static func port_type_name(p_type: int) -> String:
	var k = PortType.find_key(p_type)
	return String(k) if k != null else "?"


## FINAL — declare `_inputs()`. Types for each input port.
func input_port_types() -> PackedInt32Array:
	_ports_refresh()
	return _in_types


## Output port type of the PRIMARY (port 0) output. Defaults to HEIGHT. Kept as the single-output
## shorthand; `output_port_types()[0]` is the same value.
## FINAL — do not override. The type of output port 0, derived from `output_port_types()`.
##
## This used to be overridable and 14 nodes did, which made it a SECOND declaration of a fact that
## already had one. They drifted, exactly as `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §9 says two numbers kept
## in two places always do: `Pasture3DGraphNodeMask` overrode this to MASK and inherited `[HEIGHT]` from
## the plural, so the editor coloured its output socket HEIGHT-blue (it reads the plural) while the
## preview treated it as a mask (it reads this). One node's face disagreed with its own render.
##
## Declare `output_port_types()` and only that.
func output_port_type() -> int:
	var t := output_port_types()
	return int(t[0]) if t.size() > 0 else PortType.HEIGHT


## True when `p_type` carries one value per CELL rather than one value for the port. See the PortType
## header: this is the split `native_param_ports()` must agree with, and the gate asserts it.
static func is_field_type(p_type: int) -> bool:
	return p_type == PortType.HEIGHT or p_type == PortType.MASK or p_type == PortType.FIELD \
			or p_type == PortType.SIGNED or p_type == PortType.PATH


## How many output ports this node exposes. 1 for every node except a multi-output SOLVER, which returns
## its primary height plus one grid per derived channel (e.g. Scree = [height, deposition-mask]). The
## connection tuple already carries `from_port`, so a consumer wires to a specific channel; the evaluator
## materialises port 0 into its `grids` slot and ports >= 1 into a parallel `aux` map.
## FINAL — declare `_outputs()`.
func output_count() -> int:
	_ports_refresh()
	return _out_ports.size()


## FINAL — declare `_outputs()`. Labels for each output port, for the editor's right-side slots.
func output_names() -> PackedStringArray:
	_ports_refresh()
	return _out_names


## FINAL — declare `_outputs()`. Types for each output port, in port order; the editor colours each
## channel slot from this (a Scree's channel-1 slot is MASK-amber).
func output_port_types() -> PackedInt32Array:
	_ports_refresh()
	return _out_types


## MULTI-OUTPUT grid entry point. Returns one grid per output port, in port order (`output_count()`
## entries). The default wraps the single-output `eval_grid` as `[eval_grid(...)]`, so only a node that
## actually produces channels overrides this. Only called for a node whose `output_count() > 1`; every
## single-output grid node continues to go through `eval_grid` unchanged.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> Array:
	return [eval_grid(p_inputs, p_gw, p_gh, p_mask, p_rect)]


## FINAL — declare `_inputs()`. How many input ports this node reads. GENERATOR = 0; a FILTER = 1.
func input_count() -> int:
	_ports_refresh()
	return _in_ports.size()


## Which native params SLOT each input port overrides when a wire drives it, in port order; -1 for a port
## that carries a grid rather than a scalar. Empty means "no port is a scalar".
##
## This used to be `PARAM_PORT_MAP` in `pasture3d_terrain_graph.gd`, keyed by op string, alongside four
## other tables that also described ops from the outside. A node whose entry was missing was not an
## error: the port simply stopped looking like a scalar, so a driven value reached the script path and
## not the native one, and anything deriving "is this a grid port" from the table got the wrong answer
## (see the Expand/Shrink `amount` note that entry carried). Declared here, the fact travels with the
## node that owns it.
##
## FINAL — it is each port's `native_slot`, declared in `_inputs()`.
func native_param_ports() -> PackedInt32Array:
	_ports_refresh()
	return _in_slots


## The scalar input a per-cell colour node (one answering `graph_color_cells`) needs tapped, or -1. The colour
## resolver asks this, never a position. Defaults to `color_mask_port()`, Color Blend's older name for it, so
## Color Blend needs no change; a converter whose field is not a mask (Color Ramp) overrides this instead.
func color_field_port() -> int:
	return color_mask_port()


## Color Blend's name for `color_field_port()`. -1 on every node that taps no field.
func color_mask_port() -> int:
	return -1


## Marshal this node's parameters into the flat 16-slot scalar block the native op table reads, plus its
## FastNoiseLite and its 256-entry curve LUT when it has them:
##
##     { "params": PackedFloat32Array (16), "noise": FastNoiseLite|null, "lut": PackedFloat32Array }
##
## `{}` means "no scalar parameters", which is right for the structural ops. The op ID is NOT returned
## here — that comes from `Pasture3DUtil.graph_op_ids()`, the one C++ list.
##
## WHY THIS LIVES ON THE NODE. It used to be 60 `match` arms in `_lower_node_op`, naming this node's
## properties from the outside with `node.get("name")`. `get()` on a name the node does not have returns
## null and the arm fell through to a hardcoded default, so a typo produced a plausible surface rather
## than an error, and four shipped bugs of exactly that shape are on the record: Crater baked a fixed
## amplitude of 25.0 into every crater, Warp put `strength` in the slot the kernel reads as the noise
## TYPE, Curve named five properties that do not exist (and threw on `bool(null)`), and Mask read `mode`
## for `property` so every mask lowered as SLOPE. Written here, `amplitude` is a member reference and a
## typo is a PARSE error. That is the whole point of the move; the tidiness is incidental.
func native_lower() -> Dictionary:
	return {}


## How many CHANNELS this node's native kernel writes, which is not always `output_count()` — an op may
## offer five ports in the editor and implement one in C++. Reporting the kernel's number is what makes
## `native_supported()` refuse to lower a graph that reads a channel the kernel does not produce; saying
## `output_count()` here would serve a field of zeros that looks exactly like a real answer.
##
## Was `NATIVE_OUT_COUNT` in `pasture3d_terrain_graph.gd`; a missing entry silently truncated a
## multi-output node to channel 0.
func native_out_count() -> int:
	return 1


## FINAL — declare `_inputs()`. Port labels, for the editor and for configuration warnings.
func input_names() -> PackedStringArray:
	_ports_refresh()
	return _in_names


## Which INPUT PORT carries this node's secondary GRID operand -- the mask, the noise field, the per-cell
## weight -- or -1 when it has none.
##
## A node with a grid on a port other than 0 has to say so HERE, next to input_names(), because the native
## and GPU evaluators cannot see the port list. They used to hardcode `in1` for all of them, which was right
## only for Mudslide: Contrast read its "amount" scalar as a per-cell mask, Falloff read "strength", and
## SmoothFill and RecastCliff read "radius" and "talus". Both halves failed at once -- the real mask was
## ignored AND a driving constant acted as one -- and nothing refused the graph.
##
## Port 0 is the primary input and is never the answer; -1 means the op has no secondary grid.
##
## FINAL — it is the input declared `.as_aux()` in `_inputs()`.
func aux_grid_port() -> int:
	_ports_refresh()
	return _in_aux


## The value an UNWIRED input port reads. A HEIGHT port reads 0 (a missing height adds nothing); a MASK
## port reads 1.0 (a missing gate is fully open, so an unwired mask input is a no-op rather than a hard 0
## that would zero the node out).
##
## FINAL. A port backed by a node property reads that property, live — which is what makes the inline
## widget and the unwired value one number rather than two that agree. Any other port reads the
## `.unwired()` value its descriptor declares.
func input_unwired_default(p_port: int) -> float:
	_ports_refresh()
	if p_port < 0 or p_port >= _in_ports.size():
		return 0.0
	var p := _in_ports[p_port]
	if p.property != &"":
		return float(get(p.property))
	return p.default_value


## CELL node entry point. `p_wx` / `p_wz` are this cell's WORLD XZ (so noise stays continuous where two
## graphs or brushes meet). `p_inputs` holds each input port's value AT THIS CELL, in port order. Returns
## the cell's output height. Default = pass the first input through (a no-op filter).
func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return p_inputs[0] if p_inputs.size() > 0 else 0.0


## GRID node entry point. `p_inputs` is one grid (PackedFloat32Array, row-major `p_gw * p_gh`) per input
## port, in port order; `p_mask` is an optional [0,1] grid of the same shape, or null; `p_rect` is the
## world-XZ extent the grid covers, so a frame-dependent generator (Crater, DLA) can normalise a cell's
## world position to the loop. Returns the output grid. Default = pass the first input through. Only called
## when `needs_grid()` is true.
func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	return (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 else Pasture3DGraphOps.zeros(p_gw * p_gh)


## Problems that only exist when this graph runs inside a BRUSH, where the footprint is one masked
## region among several and neighbouring regions have to agree where they meet. Kept apart from
## `node_warnings` because the same graph resource is meant to be reusable: what is a defect in a brush
## can be the whole point on a full terrain, and a warning that fires in both places is one users learn
## to ignore. Empty = nothing to say.
func node_warnings_in_brush() -> PackedStringArray:
	return PackedStringArray()


## Problems worth surfacing in the graph's configuration warnings (an unassigned noise, a zero pass
## count). Empty = nothing to say.
func node_warnings() -> PackedStringArray:
	return PackedStringArray()


## Human-readable name for warnings: the user's label, else the class name with the Pasture3DGraphNode
## prefix stripped.
func display_name() -> String:
	if not resource_name.is_empty():
		return resource_name
	return String(get_script().get_global_name()).trim_prefix("Pasture3DGraphNode")
