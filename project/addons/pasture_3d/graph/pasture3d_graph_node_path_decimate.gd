# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathDecimate — fewer vertices, same line.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. The inverse of Resample, and the reason it exists is cost: a
# Meanderize with six iterations over an already-resampled river produces tens of thousands of vertices,
# every one of which is a segment the per-cell path query has to consider. Most of them are on a straight.
#
# ---- VISVALINGAM-WHYATT, NOT DOUGLAS-PEUCKER ----
#
# Both simplify a polyline; they disagree about what "important" means. Douglas-Peucker keeps whatever is
# furthest from a chord, which on a meandering river keeps the extremes of every bend and throws away the
# shape between them — the line stays inside its tolerance and stops looking like a river. Visvalingam-
# Whyatt ranks by the AREA a vertex contributes, so it removes the flattest points first and degrades a
# curve by smoothing it rather than by faceting it. That is the failure mode we can live with here.
#
# ---- THE AREAS ARE NOT RECOMPUTED LAZILY ----
#
# Removing a vertex changes its neighbours' triangles, so the classic implementation keeps a heap and
# repairs it. This walks the remaining points each round instead: O(n) per removal against a few hundred
# vertices, once per edit, and one definition instead of a heap plus its invalidation rule. If a path ever
# arrives with a hundred thousand vertices this is the line to revisit, and `MAX_ROUNDS` is what stops it
# being a hang in the meantime.
@tool
class_name Pasture3DGraphNodePathDecimate
extends Pasture3DGraphNodePathShape

## How many vertices to keep. The path passes through unchanged when it already has this many or fewer —
## this node only removes, so asking for more than the input has is not an error, it is a no-op.
@export_range(3, 4096, 1, "or_greater") var target_points: int = 64:
	set(v):
		target_points = maxi(v, 3)
		emit_changed()

## Stop early once every remaining vertex contributes at least this much area, in SQUARE METRES.
##
## Metric, per §7.4, and it is the knob that makes this node safe to leave in a graph: a target count
## alone will happily strip a genuinely wiggly river down to 64 points. 0 disables it, and the count
## decides alone.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m²") var min_area: float = 0.0:
	set(v):
		min_area = maxf(v, 0.0)
		emit_changed()

## Never move the first or last vertex. Same reasoning as Path Smooth's `pin_ends`, and not optional here:
## an endpoint has no triangle, so it has no area, so it would be removed FIRST.
const KEEPS_ENDS: bool = true

## A ceiling on removals, so a pathological input cannot spin. One per input vertex is already more than
## can ever be needed.
const MAX_ROUNDS: int = 1000000


func min_vertices() -> int:
	return 3


func op() -> StringName:
	return &"path_decimate"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	var pts := p_src.points
	var n := pts.size()
	if n <= maxi(target_points, 3):
		return
	# `keep` indexes into the INPUT, so a removed vertex leaves no gap to compact and the neighbours a
	# triangle is measured from are always the ones that will actually be adjacent afterwards.
	var keep := PackedInt32Array()
	keep.resize(n)
	for i in n:
		keep[i] = i

	var rounds := 0
	while keep.size() > maxi(target_points, 3) and rounds < MAX_ROUNDS:
		rounds += 1
		var worst := INF
		var worst_at := -1
		# A closed ring has no ends to pin: every vertex has two neighbours, wrapping.
		var lo := 0 if p_src.closed else 1
		var hi := keep.size() if p_src.closed else keep.size() - 1
		for k in range(lo, hi):
			var a := pts[keep[posmod(k - 1, keep.size())]]
			var b := pts[keep[k]]
			var c := pts[keep[posmod(k + 1, keep.size())]]
			var area: float = absf((b - a).cross(c - a)) * 0.5
			if area < worst:
				worst = area
				worst_at = k
		if worst_at < 0:
			break
		if min_area > 0.0 and worst >= min_area:
			# Everything left matters. Stopping here rather than at the count is the whole point of the
			# area floor; hitting it is a success, not a failure to reach the target.
			break
		keep.remove_at(worst_at)

	var out := PackedVector2Array()
	out.resize(keep.size())
	for k in keep.size():
		out[k] = pts[keep[k]]
	p_out.points = out
	carry_values(p_src, p_out)


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if target_points <= 4 and min_area <= 0.0:
		out.append("Path Decimate is set to keep %d vertices with no area floor, which will straighten "
				% target_points + "any curve it is given. Set Min Area, or raise the target.")
	return out
