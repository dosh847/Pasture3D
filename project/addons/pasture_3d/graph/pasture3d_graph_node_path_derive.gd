# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathDerive — the base every GRID → PATH node extends.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5 and §8.4. Three nodes share it: Path Drape, Path Width from
# Field, and Path from Flow. They are the family §8.2's compile-time pre-pass cannot serve, because the
# grid they read is produced by the program being compiled.
#
# ---- WHY THIS FAMILY IS DIFFERENT FROM Pasture3DGraphNodePathShape ----
#
# A reshape is a pure function of the path above it, so the S4 pre-pass can resolve it host-side before
# the program is compiled and hand the result to the geometry table. These read a FIELD. There is no
# moment before compilation at which that field exists, so §8.4's rule applies: `blocks_native()` is
# true, the whole graph drops to the GDScript evaluator, and there — where grids and paths are
# materialised in one topological order — the field is simply already there when the path is asked for.
# S7b cuts the program at these nodes and removes the bail; until then this is honest and expensive
# (`graph-gpu-bail-is-graph-wide`: the erosion and the noise beside it go down too).
#
# ---- HOW THE GRID REACHES eval_path, WHICH IS THE WHOLE TRICK ----
#
# `eval_path` is handed PATH inputs and nothing else — it is called out of `_resolved_path_of`, a
# recursion over the PATH sub-DAG that knows nothing about grids. So the grid arrives by the other door.
# The evaluator materialises every node in topological order and calls `eval_grid` on anything answering
# `needs_grid()`; this family answers true, CAPTURES its inputs and its domain there, and returns the
# zero grid a PATH producer's slot is supposed to hold. The consumer's `_path_inputs` call comes later in
# the same order — a carve wired to this node is downstream of it by construction — so by then the
# capture is the current one.
#
# Two consequences worth stating, because both are silent if missed:
#
#   * `derives_path_from_grid()` is what stops `_resolved_path_of` short-circuiting. That function
#     answers with `path_output()` for any node with no PATH input, which is right for a source and
#     wrong for Path from Flow — it has no PATH input at all and still produces one.
#   * `path_eval_salt()` is what stops the memo serving a stale line. `_resolved_path_of` keys on the
#     input paths' digests and this node's revision, and NEITHER moves when the erosion upstream
#     re-solves. The salt folds the captured grid into the key, so a river re-traces when the flow it
#     was traced from changes and not otherwise.
#
# ---- ASKED FOR A PATH WITH NO CAPTURE ----
#
# Reachable: a preview tap or an oracle can resolve a path without having run this node's `eval_grid`
# first. The answer is `derive_without_grid`, which by default passes the INPUT through unchanged. Not
# null — null is "there is no path here", and a Path Drape that briefly answered null would take the
# carve below it off the line rather than merely leaving it undraped.
@tool
class_name Pasture3DGraphNodePathDerive
extends Pasture3DGraphNode


## Counts completed `eval_path` calls, like the reshape family's. Read only by the gates: a memo that
## quietly stopped memoising produces identical terrain, and only a count can see it.
var eval_path_count: int = 0

## Counts `eval_grid` captures. The pair is what distinguishes "the grid never arrived" from "the grid
## arrived and the derive did nothing", which are different bugs with the same symptom.
var capture_count: int = 0

# The instance handed out, kept rather than reallocated — the geometry table dedups by instance id.
var _out: Pasture3DGraphPath = null

# The captured field(s) and the domain they were sampled over. See the header.
var _grids: Array = []
var _gw: int = 0
var _gh: int = 0
var _rect: Rect2 = Rect2()
var _grid_key: int = 0


func role() -> Role:
	return Role.FILTER


## True: this family reads whole grids. It is also what routes it through the evaluator's `eval_grid`
## branch, which is the only place the capture can happen.
func needs_grid() -> bool:
	return true


## §8.4's rule, and the definition of phase S7a. S7b replaces it with a staged compile rather than by
## weakening it here.
func blocks_native() -> bool:
	return true


## The declaration that separates this family from every other node with no PATH input. See the header.
func derives_path_from_grid() -> bool:
	return true


func output_count() -> int:
	return 1


func output_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func output_port_type() -> int:
	return PortType.PATH


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


## A PATH producer still fills a grid slot, with zeros.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


## Never reached — `blocks_native()` is true — but declared for the same reason the reshape family
## declares it: the op tag has to exist in `k_ops` or the graph drops to GDScript for a second,
## unrelated reason, and a bail with two causes is a bail nobody can measure.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = 0.0
	return {"params": p}


## Which input port carries the PATH this node rewrites, or -1 for a node that produces one from nothing
## (Path from Flow). Drives the pass-through, the min-vertex floor and `derive_without_grid`.
func path_input_port() -> int:
	return 0


## The minimum vertices the input needs before this node will touch it.
func min_vertices() -> int:
	return 2


# ---- the capture ---------------------------------------------------------------------------------

## Capture the field and the domain, and return the zero grid this node's slot holds. Subclasses do not
## override this; they read `_grids` / `_gw` / `_gh` / `_rect` from `derive`.
func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	_grids = p_inputs
	_gw = p_gw
	_gh = p_gh
	_rect = p_rect
	# One hash over the captured fields and the domain. `hash()` on a PackedFloat32Array is content-based,
	# which is exactly the property wanted: an erosion re-solved to the same numbers must NOT re-trace the
	# river, and one re-solved differently must.
	var parts: Array = [p_gw, p_gh, p_rect]
	for g in p_inputs:
		parts.append(hash(g))
	_grid_key = hash(parts)
	capture_count += 1
	return Pasture3DGraphOps.zeros(p_gw * p_gh)


## Folded into `_resolved_path_of`'s memo key. See the header: without it a river never re-traces.
func path_eval_salt() -> int:
	return _grid_key


# ---- the path ------------------------------------------------------------------------------------

## Rewrite `p_out` from `p_src` using the captured field. The base has copied every field across, so a
## subclass writes only what it changes. `p_src` is null for a node whose `path_input_port()` is -1.
func derive(_p_src: Pasture3DGraphPath, _p_out: Pasture3DGraphPath) -> void:
	pass


## What to answer when this node is asked for a path before its `eval_grid` has ever run. The input,
## unchanged — see the header for why it is not null. A producer with no path input has nothing to hand
## back and answers null, which for it IS the honest answer.
func derive_without_grid(p_src: Pasture3DGraphPath) -> Pasture3DGraphPath:
	return p_src


## The path this node last HANDED THE GRAPH, or null if it has never been asked.
##
## Exists for the gates, and it is not a convenience. A test that calls `eval_path` itself measures a
## fresh call rather than the graph's — so it passes whether or not `_resolved_path_of` ever reached this
## node, and whether or not the memo served a stale answer. Both of those are real failure modes with no
## other symptom (PathDeriveGate [E] and [F]), so the only honest thing to read is what the graph got.
func derived_path() -> Pasture3DGraphPath:
	return _returned


# The above. Written on every return, which is why `eval_path` is final here and subclasses override
# `_derive_path` instead.
var _returned: Pasture3DGraphPath = null


## FINAL. Subclasses override `_derive_path` (or, normally, just `derive`).
func eval_path(p_inputs: Array) -> Pasture3DGraphPath:
	_returned = _derive_path(p_inputs)
	return _returned


func _derive_path(p_inputs: Array) -> Pasture3DGraphPath:
	eval_path_count += 1
	var port := path_input_port()
	var src: Pasture3DGraphPath = null
	if port >= 0:
		src = p_inputs[port] if p_inputs.size() > port else null
		if src == null or src.points.size() < min_vertices():
			return src
	if _gw <= 0 or _gh <= 0 or _grids.is_empty():
		return derive_without_grid(src)
	if _out == null:
		_out = Pasture3DGraphPath.new()
	if src != null:
		# Field by field rather than `duplicate()`, for the reason Pasture3DGraphNodePathShape gives.
		_out.points = src.points
		_out.half_widths = src.half_widths
		_out.heights = src.heights
		_out.closed = src.closed
		_out.crown = src.crown
		_out.cut_batter = src.cut_batter
		_out.fill_batter = src.fill_batter
		# A derive never moves the centreline (Drape writes heights, Width writes widths, From Flow makes
		# its own line), so a solved road's profile still describes THIS line and is kept. That is the
		# opposite of the reshape family's default and is the whole of `moves_the_line()`'s argument.
		_out.alignment = src.alignment
		_out.sample_half_widths = src.sample_half_widths
		_out.sample_shoulders = src.sample_shoulders
		_out.sample_verges = src.sample_verges
		_out.sample_suppress = src.sample_suppress
		_out.sample_skip = src.sample_skip
	derive(src, _out)
	return _out


# ---- helpers the family shares -------------------------------------------------------------------

## Bilinear sample of a captured grid at a world XZ, or NAN outside the domain.
##
## Bilinear rather than nearest, and it matters here more than it looks: a draped path's heights become a
## carve's crest, and nearest sampling would give a crest that steps by one cell's relief every time the
## line crossed a cell boundary — a staircase along a river, on ground that is smooth.
func sample_grid(p_grid: PackedFloat32Array, p_wx: float, p_wz: float) -> float:
	if _gw <= 0 or _gh <= 0 or p_grid.size() < _gw * _gh:
		return NAN
	var dx: float = _rect.size.x / float(_gw)
	var dz: float = _rect.size.y / float(_gh)
	if dx <= 0.0 or dz <= 0.0:
		return NAN
	# Cell CENTRES, matching the evaluator's own `min_x = rect.position.x + 0.5 * dx`. Sampling as though
	# the values sat on vertices shifts every drape half a cell, which on a slope is a real offset and on
	# a flat fixture is invisible.
	var fx: float = (p_wx - (_rect.position.x + 0.5 * dx)) / dx
	var fz: float = (p_wz - (_rect.position.y + 0.5 * dz)) / dz
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)
	var x1 := x0 + 1
	var z1 := z0 + 1
	x0 = clampi(x0, 0, _gw - 1)
	x1 = clampi(x1, 0, _gw - 1)
	z0 = clampi(z0, 0, _gh - 1)
	z1 = clampi(z1, 0, _gh - 1)
	var v00: float = p_grid[z0 * _gw + x0]
	var v10: float = p_grid[z0 * _gw + x1]
	var v01: float = p_grid[z1 * _gw + x0]
	var v11: float = p_grid[z1 * _gw + x1]
	if not (is_finite(v00) and is_finite(v10) and is_finite(v01) and is_finite(v11)):
		# NAN is "no data" and does not average. One unknown corner makes the sample unknown rather than
		# three quarters of a height (PASTURE3D_NODE_VOCABULARY.md §1).
		return NAN
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), tz)


## World XZ of a cell centre in the captured domain.
func cell_centre(p_ix: int, p_iz: int) -> Vector2:
	var dx: float = _rect.size.x / float(maxi(_gw, 1))
	var dz: float = _rect.size.y / float(maxi(_gh, 1))
	return Vector2(_rect.position.x + (float(p_ix) + 0.5) * dx,
			_rect.position.y + (float(p_iz) + 0.5) * dz)


## True when a captured port is UNWIRED, which is a question the grid alone cannot answer: the evaluator
## fills an unwired port with a constant, so "all zeros" is both "nothing wired" and "a field that is
## genuinely zero". Nodes here declare NAN as the unwired default for their optional ports and read the
## answer back through this.
func port_unwired(p_port: int) -> bool:
	if p_port < 0 or p_port >= _grids.size():
		return true
	var g: PackedFloat32Array = _grids[p_port]
	return g.is_empty() or is_nan(g[0])
