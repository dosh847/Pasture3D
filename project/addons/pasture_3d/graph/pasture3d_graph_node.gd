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
	var total := _cached_grid.size() * 4
	for k in _cached_aux:
		var arr = _cached_aux[k]
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
## declaration every other consumer reads. FIELD types (HEIGHT, MASK, FIELD, SIGNED, TERRAIN_BUS, PATH)
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
	VECTOR = 2,       # Directional 2D/3D vector / angle value - Purple
	CURVE = 3,        # Spline / transfer curve - Emerald
	FLOAT = 4,        # General scalar float VALUE / factor (never a grid) - Cyan
	INT = 5,          # Discrete count / integer value - Cobalt Blue
	COLOR = 6,        # RGBA color / tint / gradient band - Magenta/Pink
	BOOL = 7,         # Boolean toggle / gate switch - Lime Yellow
	TERRAIN_BUS = 8,  # Bundled multi-channel stream - Warm Gold
	PATH = 9,         # World-space polyline with per-vertex width (Pasture3DGraphPath) - Slate
	FIELD = 10,       # Unsigned scalar field in its OWN units, unbounded - Yellow-Green
	SIGNED = 11,      # Signed scalar field in its own units; zero is meaningful - Magenta
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


## Types for each input port. Defaults to HEIGHT for all ports.
func input_port_types() -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(input_count())
	arr.fill(PortType.HEIGHT)
	return arr


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
			or p_type == PortType.SIGNED or p_type == PortType.TERRAIN_BUS or p_type == PortType.PATH


## How many output ports this node exposes. 1 for every node except a multi-output SOLVER, which returns
## its primary height plus one grid per derived channel (e.g. Scree = [height, deposition-mask]). The
## connection tuple already carries `from_port`, so a consumer wires to a specific channel; the evaluator
## materialises port 0 into its `grids` slot and ports >= 1 into a parallel `aux` map.
func output_count() -> int:
	return 1


## Labels for each output port, for the editor's right-side slots. Length should match `output_count()`.
func output_names() -> PackedStringArray:
	return PackedStringArray(["out"])


## Types for each output port, in port order. Defaults to a single HEIGHT. A multi-output node overrides
## this so the editor colours each channel slot (a Scree's channel-1 slot is MASK-amber).
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


## MULTI-OUTPUT grid entry point. Returns one grid per output port, in port order (`output_count()`
## entries). The default wraps the single-output `eval_grid` as `[eval_grid(...)]`, so only a node that
## actually produces channels overrides this. Only called for a node whose `output_count() > 1`; every
## single-output grid node continues to go through `eval_grid` unchanged.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> Array:
	return [eval_grid(p_inputs, p_gw, p_gh, p_mask, p_rect)]


## How many input ports this node reads. GENERATOR = 0; a FILTER = 1; Blend = 2.
func input_count() -> int:
	return 1


## Which native params SLOT each input port overrides when a wire drives it, in port order; -1 for a port
## that carries a grid rather than a scalar. Empty means "no port is a scalar".
##
## This used to be `PARAM_PORT_MAP` in `pasture3d_terrain_graph.gd`, keyed by op string, alongside four
## other tables that also described ops from the outside. A node whose entry was missing was not an
## error: the port simply stopped looking like a scalar, so a driven value reached the script path and
## not the native one, and anything deriving "is this a grid port" from the table got the wrong answer
## (see the Expand/Shrink `amount` note that entry carried). Declared here, the fact travels with the
## node that owns it.
func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array()


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


## Port labels, for the editor and for configuration warnings. Length should match `input_count()`.
func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


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
func aux_grid_port() -> int:
	return -1


## The value an UNWIRED input port reads. A HEIGHT port reads 0 (a missing height adds nothing); a MASK
## port reads 1.0 (a missing gate is fully open, so an unwired mask input is a no-op rather than a hard 0
## that would zero the node out). Nodes with a mask/weight input override this per port.
func input_unwired_default(_p_port: int) -> float:
	return 0.0


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
