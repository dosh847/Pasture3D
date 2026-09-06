# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathMeanderize — make a drawn line meander like a river.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. The river node, and the single biggest difference between a
# drawn river and a believable one: real channels do not go anywhere directly, and a straight line reads
# as a canal no matter what cross-section is carved along it.
#
# ---- WHAT IT ACTUALLY DOES, AND WHY NOT JUST NOISE ----
#
# Fractalize already offsets a line by noise, and the result looks like a wobbly line, not a river. The
# difference is that a meander AMPLIFIES ITS OWN CURVATURE: water cuts the outside of a bend and deposits
# on the inside, so wherever the line already turns, it turns harder next year. So each iteration pushes
# every vertex along its own normal by an amount proportional to the local curvature there, subdivides,
# and repeats. Noise is added on top and is a garnish; `ratio` is the node.
#
# ---- THE SIGN IS THE ENTIRE ALGORITHM ----
#
# Curvature is signed by the cross product of the incoming and outgoing segments, and pushing OUTWARD
# means displacing along the normal in the direction the bend already leans. Getting that sign backwards
# does not produce a mirrored river: it produces a line that straightens itself, iteration by iteration,
# converging on the chord between the endpoints. That failure is silent at one iteration and total at six,
# which is why PathShapeGate measures total length rather than eyeballing a shape — a meandering line is
# LONGER than the line it came from, and a straightened one is shorter.
#
# ---- REMOVE LOOPS ----
#
# Amplifying curvature is a positive feedback, so a tight enough bend eventually crosses itself. A path
# that self-intersects is not wrong to the query — nearest-segment still answers — but a river that flows
# through itself carves a bed twice and reads as a mistake. `remove_loops` excises the vertices between
# any two crossing segments, which is the standard cut and is why the two are one node rather than two.
@tool
class_name Pasture3DGraphNodePathMeanderize
extends Pasture3DGraphNodePathShape

## How hard each iteration pushes a bend outward, as a fraction of the local segment length. The useful
## range is small: 0.3 over six iterations is already a floodplain river. 0 is the identity.
@export_range(0.0, 2.0, 0.001) var ratio: float = 0.4:
	set(v):
		ratio = maxf(v, 0.0)
		emit_changed()

## Random displacement added on top, as a fraction of the local segment length. A garnish — see the
## header. It is what stops every bend being the same bend, and it cannot make a straight line meander.
@export_range(0.0, 1.0, 0.001) var noise_ratio: float = 0.1:
	set(v):
		noise_ratio = maxf(v, 0.0)
		emit_changed()

## The seed. Stable, for the reason Path Fractalize's header gives at length: the generator is seeded once
## and consumed in a fixed order, and anything that reorders the walk moves the terrain under a frozen
## graph.
@export var seed: int = 0:
	set(v):
		seed = v
		emit_changed()

## How many times to amplify. Each iteration multiplies the vertex count by `edge_divisions`, so this and
## that knob together are the cost.
@export_range(1, 10, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 1, 10)
		emit_changed()

## How many vertices each edge becomes per iteration. Two is the minimum that can bend at all; more gives
## a smoother bend for the same number of iterations, at a cost that multiplies rather than adds.
@export_range(2, 8, 1) var edge_divisions: int = 2:
	set(v):
		edge_divisions = clampi(v, 2, 8)
		emit_changed()

## Cut out any loop the amplification produces. See the header.
@export var remove_loops: bool = true:
	set(v):
		remove_loops = v
		emit_changed()

## Hold the first and last vertices — a river's mouth and source are placed, not derived. Ignored when
## the path is closed.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		emit_changed()

## Above this the node stops iterating and keeps what it has, rather than passing the input through: a
## meander that got most of the way there is still a meander, unlike a half-resampled path.
const MAX_POINTS: int = 200000


## Three, because curvature needs an interior vertex. A two-point line is straight by definition and this
## node cannot make it anything else — it is not noise, it amplifies what is already there.
func min_vertices() -> int:
	return 3


func op() -> StringName:
	return &"path_meanderize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if ratio <= 0.0 and noise_ratio <= 0.0:
		return
	var pts := ring_of(p_src)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	for _it in iterations:
		# Checked against what the NEXT iteration would produce, not what this one already has: the count
		# is multiplied by `edge_divisions`, so a check on the current size lets the last pass overshoot
		# the cap by that factor.
		if pts.size() * edge_divisions > MAX_POINTS:
			break
		pts = _subdivide(pts, p_src.closed)
		pts = _amplify(pts, p_src.closed, rng)
		if remove_loops:
			pts = _cut_loops(pts, p_src.closed)
		if pts.size() < 3:
			break

	if p_src.closed and pts.size() >= 2:
		pts[pts.size() - 1] = pts[0]
	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


## Split every edge into `edge_divisions` pieces. Straight subdivision: the bending is `_amplify`'s job,
## and doing both in one pass would make the displacement depend on how many pieces an edge became.
func _subdivide(p_pts: PackedVector2Array, _p_closed: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(p_pts.size() - 1):
		var a := p_pts[i]
		var b := p_pts[i + 1]
		for k in edge_divisions:
			out.append(a.lerp(b, float(k) / float(edge_divisions)))
	out.append(p_pts[p_pts.size() - 1])
	return out


## Push every vertex outward along its own normal, proportionally to the curvature there.
func _amplify(p_pts: PackedVector2Array, p_closed: bool, p_rng: RandomNumberGenerator) -> PackedVector2Array:
	var n := p_pts.size()
	var out := p_pts.duplicate()
	for i in range(n):
		var is_end := (i == 0 or i == n - 1)
		# The random draw is taken for EVERY vertex including the pinned ends, before any decision to skip
		# it. Consuming the stream unconditionally is what keeps the seed stable when `pin_ends` changes:
		# otherwise turning it off would reroll every bend in the river, not just its two ends.
		var jitter := p_rng.randfn(0.0, 1.0)
		if is_end and not p_closed:
			if pin_ends:
				continue
		var prev := p_pts[posmod(i - 1, n - 1) if p_closed else maxi(i - 1, 0)]
		var next := p_pts[posmod(i + 1, n - 1) if p_closed else mini(i + 1, n - 1)]
		var v0 := p_pts[i] - prev
		var v1 := next - p_pts[i]
		var l0 := v0.length()
		var l1 := v1.length()
		if l0 <= 0.0 or l1 <= 0.0:
			continue
		var chord := (l0 + l1) * 0.5
		# The LEFT normal of the average direction, and the SIGNED turn. `cross` is positive when the line
		# turns one way and negative the other, so multiplying by it displaces outward on both — see the
		# header for what the wrong sign does.
		var dir := (v0 / l0 + v1 / l1).normalized()
		if dir == Vector2.ZERO:
			continue
		var nrm := Vector2(dir.y, -dir.x)
		var turn: float = (v0 / l0).cross(v1 / l1)
		out[i] = p_pts[i] + nrm * (chord * (ratio * turn + noise_ratio * jitter))
	if p_closed and n >= 2:
		out[n - 1] = out[0]
	return out


## Excise the vertices between any two non-adjacent segments that cross, replacing them with the crossing
## point. One forward pass over a bucket-indexed segment set.
##
## ---- WHY THIS IS INDEXED AND THE REST OF THE FAMILY IS NOT ----
##
## Everything else here is a walk over a few hundred vertices, where an index would cost more than it
## saves. This is the one O(n²) question in the family, asked on the one node whose vertex count is
## MULTIPLIED rather than added to: six iterations at three divisions turns a 70-point line into 51 000,
## and the naive pairwise scan is 2.6 billion segment tests per cut attempt. The first version of this
## function was that scan, and it did not fail the gate — it hung it.
##
## So segments go into a uniform bucket index, the same shape `Pasture3DGraphPath` builds for its own
## queries, and each segment only tests the ones sharing a cell.
##
## ---- ONE PASS, LARGEST LOOP FIRST ----
##
## Where segment `i` crosses several later segments, the LAST of them is taken, so the biggest loop is
## excised in one cut and the small ones inside it go with it. The walk then resumes past the cut, which
## means the partial segment left behind by the cut is not itself re-tested against what follows. That
## can leave a loop the next iteration will usually remove anyway, and it is the price of a single pass;
## the alternative is re-indexing after every cut, which is where the hang came from.
func _cut_loops(p_pts: PackedVector2Array, p_closed: bool) -> PackedVector2Array:
	var n := p_pts.size()
	if n < 4:
		return p_pts
	var segs := n - 1
	# Cell size from the MEAN segment length: the index exists to bound how many segments share a cell,
	# and a cell a few segments wide does that whatever scale the path is drawn at. A fixed metric size
	# would be one bucket for a 20 m creek and a hundred thousand for a continental river.
	var total := 0.0
	for i in segs:
		total += p_pts[i].distance_to(p_pts[i + 1])
	var cell: float = maxf(total / float(segs) * 4.0, 0.001)

	var buckets := {}
	for i in segs:
		for c in _cells_of(p_pts[i], p_pts[i + 1], cell):
			if not buckets.has(c):
				buckets[c] = PackedInt32Array()
			buckets[c].append(i)

	var out := PackedVector2Array()
	var i := 0
	while i < segs:
		out.append(p_pts[i])
		var best_j := -1
		var best_x := Vector2.ZERO
		var seen := {}
		for c in _cells_of(p_pts[i], p_pts[i + 1], cell):
			for j in buckets.get(c, PackedInt32Array()):
				# `i + 2` skips the adjacent segment, which shares an endpoint and so always "crosses".
				if j <= i + 1 or seen.has(j):
					continue
				seen[j] = true
				if p_closed and i == 0 and j == segs - 1:
					continue # the seam pair, adjacent around the ring
				var x = Geometry2D.segment_intersects_segment(p_pts[i], p_pts[i + 1],
						p_pts[j], p_pts[j + 1])
				if x != null and j > best_j:
					best_j = j
					best_x = x
		if best_j >= 0:
			out.append(best_x)
			i = best_j + 1
		else:
			i += 1
	out.append(p_pts[n - 1])
	return out


## The index cells a segment's bounding box covers. The box, not the line: a couple of extra cells on a
## diagonal costs one wasted segment test each, and walking the line exactly is a second rasteriser to
## keep correct.
static func _cells_of(p_a: Vector2, p_b: Vector2, p_cell: float) -> Array:
	var x0 := int(floor(minf(p_a.x, p_b.x) / p_cell))
	var x1 := int(floor(maxf(p_a.x, p_b.x) / p_cell))
	var y0 := int(floor(minf(p_a.y, p_b.y) / p_cell))
	var y1 := int(floor(maxf(p_a.y, p_b.y) / p_cell))
	var out: Array = []
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			out.append(Vector2i(x, y))
	return out


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if ratio <= 0.0 and noise_ratio <= 0.0:
		out.append("Path Meanderize is the identity: both ratio and noise ratio are 0, so the path "
				+ "passes through unchanged.")
	elif ratio <= 0.0:
		out.append("Path Meanderize's ratio is 0, so it is only adding noise — it cannot make a "
				+ "straight line meander, because it amplifies curvature that is already there.")
	return out
