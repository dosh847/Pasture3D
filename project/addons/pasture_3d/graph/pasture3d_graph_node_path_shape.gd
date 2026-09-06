# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathShape — the base every PATH -> PATH node extends.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. Six nodes share this: the five of the reshape family, plus
# Path Width, which was written before this base existed and was retrofitted onto it.
#
# ---- WHAT IS SHARED, AND WHY IT IS WORTH A BASE CLASS ----
#
# The port shape, the CONST lowering, the zero-filled grid slot and the kept output instance are the same
# on all six and are all easy to get subtly wrong in a way nothing reports. A node that allocates a fresh
# path per call still produces correct terrain — it just costs the geometry table's instance-keyed fanout
# dedup, which only an entry COUNT can see (PathPrePassGate [B]). Written six times, that is six chances.
#
# ---- A RESHAPE DROPS THE ROAD PROFILE. WIDTH DOES NOT. ----
#
# `Pasture3DGraphPath` carries an `alignment` and a set of `sample_*` arrays indexed by alignment sample:
# a solved road's vertical profile. Those describe a SPECIFIC LINE. Move the line and they describe
# somewhere else, while `can_grade()` still answers true and Road Grade still grades to them — a road
# that silently follows a profile belonging to the path it used to be.
#
# So `moves_the_line()` is the one thing a subclass must answer honestly. True (the default, and the case
# for all five of the reshape family) drops the alignment. False keeps it, which is right for Path Width:
# it rewrites widths and the centreline is untouched.
@tool
class_name Pasture3DGraphNodePathShape
extends Pasture3DGraphNode


## Counts completed `eval_path` calls. Not saved, not shown, and read only by the gates — the memo in
## `Pasture3DTerrainGraph._resolved_path_of` is invisible from outside otherwise, and "the answer is
## right" is equally true of a cache that hits and one that re-runs the work every time.
var eval_path_count: int = 0

# The instance handed out, kept rather than reallocated. See the header.
var _out: Pasture3DGraphPath = null


func role() -> Role:
	return Role.FILTER


## Declared rather than inherited, even though the base already answers false: it is one of the four
## declarations PASTURE3D_NODE_ACCELERATION_GUIDE.md Step 1 asks every node for, and "no grid" is a claim
## about this family worth reading in the family's own file. A PATH filter has no grid domain at all — it
## runs once per compile over a few hundred vertices, host-side, and its grid SLOT is the zero placeholder
## `eval_cell` fills.
func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


## One path out. Same reason as `needs_grid` for spelling out the default.
func output_count() -> int:
	return 1


func output_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func output_port_type() -> int:
	return PortType.PATH


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


## A PATH producer still fills a grid slot, with zeros. See Pasture3DGraphNode.path_output.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


## Lowers to CONST, like every PATH node: it produces no grid, its path is resolved host-side by the
## pre-pass and travels in the geometry table, and the slot is a placeholder. The op tag still has to be
## in `k_ops` — an absent tag drops the WHOLE graph to the GDScript evaluator without a word.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = 0.0
	return {"params": p}


## True when this node MOVES the centreline, and so invalidates a solved road profile. See the header.
## Defaults to true, which is the safe answer: keeping a stale alignment is silent, dropping a valid one
## is visible immediately as a road that will not grade.
func moves_the_line() -> bool:
	return true


## The minimum vertices this node needs to do anything. Below it, `eval_path` passes the input straight
## through rather than emitting a degenerate path — a two-point line has no interior vertex to smooth, no
## corner to fractalise and no curvature to meander.
func min_vertices() -> int:
	return 2


## Rewrite `p_out` from `p_src`. The base has already copied every field across, so a subclass writes only
## what it changes — usually `points`, and `half_widths` / `heights` through `_carry_values`.
##
## Never read `_out` here expecting last call's answer: it is the SAME instance, already overwritten with
## this call's input. A reshape that wanted its previous output would be a filter with state, which the
## memo's content-digest key cannot express.
func reshape(_p_src: Pasture3DGraphPath, _p_out: Pasture3DGraphPath) -> void:
	pass


## The path this node PRODUCES. See Pasture3DGraphNode.eval_path.
func eval_path(p_inputs: Array) -> Pasture3DGraphPath:
	eval_path_count += 1
	var src: Pasture3DGraphPath = p_inputs[0] if p_inputs.size() > 0 else null
	if src == null or src.points.size() < min_vertices():
		# The INPUT, not an empty copy. An unresolved source's warning stays attached to the source, and
		# the geometry table stays at one entry rather than two.
		return src
	if _out == null:
		_out = Pasture3DGraphPath.new()
	# Field by field rather than `duplicate()`, which allocates a new instance every call — exactly what
	# the kept `_out` exists to avoid — and deep-copies the alignment into a second set nobody can reach.
	_out.points = src.points
	_out.half_widths = src.half_widths
	_out.heights = src.heights
	_out.closed = src.closed
	_out.crown = src.crown
	_out.cut_batter = src.cut_batter
	_out.fill_batter = src.fill_batter
	if moves_the_line():
		_out.alignment = null
		_out.sample_half_widths = PackedFloat32Array()
		_out.sample_shoulders = PackedFloat32Array()
		_out.sample_verges = PackedFloat32Array()
		_out.sample_suppress = PackedByteArray()
		_out.sample_skip = PackedByteArray()
	else:
		_out.alignment = src.alignment
		_out.sample_half_widths = src.sample_half_widths
		_out.sample_shoulders = src.sample_shoulders
		_out.sample_verges = src.sample_verges
		_out.sample_suppress = src.sample_suppress
		_out.sample_skip = src.sample_skip
	reshape(src, _out)
	return _out


# ---- helpers the family shares ------------------------------------------------------------------

## Cumulative arc length at each vertex of `p_pts`, in metres. Walked here rather than asked of the path,
## because `Pasture3DGraphPath._cum` is the RING's — one vertex longer on a closed line — while
## `half_widths` and `heights` are indexed by `points`. Mixing the two shifts every value by one on a
## closed path and by nothing on an open one, which is a bug that only appears on closed fixtures.
static func arc_lengths(p_pts: PackedVector2Array) -> PackedFloat32Array:
	var n := p_pts.size()
	var cum := PackedFloat32Array()
	cum.resize(n)
	if n == 0:
		return cum
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + p_pts[i].distance_to(p_pts[i - 1])
	return cum


## Sample a per-vertex array at an arc length, linearly. Returns NAN for an empty array, which is the
## vocabulary's "no data" and is what `heights` means when a spline carries none — returning 0.0 would
## drag a ridge drawn at 400 m down to sea level (PASTURE3D_NODE_VOCABULARY.md §1).
static func sample_along(p_vals: PackedFloat32Array, p_cum: PackedFloat32Array, p_s: float) -> float:
	var n := p_vals.size()
	if n == 0:
		return NAN
	if n == 1 or p_cum.size() < 2:
		return p_vals[0]
	var last: float = p_cum[p_cum.size() - 1]
	if p_s <= 0.0 or last <= 0.0:
		return p_vals[0]
	if p_s >= last:
		return p_vals[mini(p_cum.size() - 1, n - 1)]
	# Linear scan. The alternative is a binary search, and these arrays are a few hundred entries walked
	# in increasing `s` by every caller, so the scan is already the faster one.
	var i := 1
	while i < p_cum.size() - 1 and p_cum[i] < p_s:
		i += 1
	var s0: float = p_cum[i - 1]
	var s1: float = p_cum[i]
	var t: float = 0.0 if s1 <= s0 else (p_s - s0) / (s1 - s0)
	var v0: float = p_vals[mini(i - 1, n - 1)]
	var v1: float = p_vals[mini(i, n - 1)]
	return lerpf(v0, v1, t)


## Carry `p_src`'s widths and heights onto `p_out`'s NEW points, by projecting each new point onto the
## original polyline and sampling at the arc length it lands on.
##
## ---- WHY PROJECTION AND NOT AN INDEX MAP ----
##
## Three of the five reshapes know exactly where each new vertex came from and two do not: Fractalize and
## Meanderize move vertices OFF the original line, by design. Projection answers all five with one
## definition, and answers it the way a reader would expect — a meander bend carries the width of the
## stretch of river it bulged out of. An index map would need a different derivation per node, which is
## three more places for the closed-path off-by-one above to live.
##
## An empty source array stays empty rather than becoming zeros: see `sample_along`.
static func carry_values(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	var have_w := p_src.half_widths.size() > 0
	var have_h := p_src.heights.size() > 0
	if not have_w and not have_h:
		p_out.half_widths = PackedFloat32Array()
		p_out.heights = PackedFloat32Array()
		return
	var cum := arc_lengths(p_src.points)
	var n := p_out.points.size()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	if have_w:
		w.resize(n)
	if have_h:
		h.resize(n)
	for i in n:
		var s := project_s(p_src.points, cum, p_out.points[i])
		if have_w:
			w[i] = sample_along(p_src.half_widths, cum, s)
		if have_h:
			h[i] = sample_along(p_src.heights, cum, s)
	p_out.half_widths = w
	p_out.heights = h


## Arc length of the point on polyline `p_pts` nearest to `p_q`. Brute force over segments: these are a
## few hundred vertices resampled a few hundred times, once per edit, against a per-cell query run
## `gw x gh` times — the cost is not measurable next to a single bake.
static func project_s(p_pts: PackedVector2Array, p_cum: PackedFloat32Array, p_q: Vector2) -> float:
	var best := INF
	var best_s := 0.0
	for i in range(1, p_pts.size()):
		var a := p_pts[i - 1]
		var b := p_pts[i]
		var ab := b - a
		var len2 := ab.length_squared()
		var t: float = 0.0 if len2 <= 0.0 else clampf((p_q - a).dot(ab) / len2, 0.0, 1.0)
		var d: float = p_q.distance_squared_to(a + ab * t)
		if d < best:
			best = d
			best_s = p_cum[i - 1] + (p_cum[i] - p_cum[i - 1]) * t
	return best_s


## The polyline the reshapes actually walk: `points`, plus the first point repeated when `closed`.
##
## The same ring `Pasture3DGraphPath` builds, and for the same reason: the closing edge is otherwise a
## special case inside every one of these algorithms, and it is the case that looks right forever on an
## open fixture.
static func ring_of(p_path: Pasture3DGraphPath) -> PackedVector2Array:
	var r := p_path.points
	if p_path.closed and r.size() >= 2:
		r = r.duplicate()
		r.append(r[0])
	return r


## Drop the ring's repeated last vertex, if this path is closed. The inverse of `ring_of`, applied before
## writing points back — a closed path stores its vertices ONCE and `closed` says the rest.
static func unring(p_pts: PackedVector2Array, p_closed: bool) -> PackedVector2Array:
	if p_closed and p_pts.size() >= 2 and p_pts[0].is_equal_approx(p_pts[p_pts.size() - 1]):
		return p_pts.slice(0, p_pts.size() - 1)
	return p_pts
