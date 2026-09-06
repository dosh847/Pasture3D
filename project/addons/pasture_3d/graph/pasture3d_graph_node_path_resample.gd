# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathResample — put a vertex every `step` metres along a path.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. The first node of the reshape family and the one the rest
# depend on: a hand-drawn river is six points, and six points have nothing for Smooth to average, nothing
# for Fractalize to displace and nothing for Meanderize to bend. Resample is what turns it into geometry.
#
# ---- METRES, NOT A COUNT ----
#
# `step` is a distance, so a 2 km river and a 200 m creek get vertices at the same density and the same
# downstream settings mean the same thing on both. A target COUNT would make every other parameter in the
# family scale with the length of the line — `saleve-measured-in-grid-fractions` is the same mistake in
# the other units.
#
# ---- THE CURVE METHODS INTERPOLATE POSITION, NOT ARC LENGTH ----
#
# CUBIC and CATMULL_ROM place the new vertex by interpolating the four surrounding control points at the
# fractional index the arc-length walk landed on. That is not the same as being exactly `step` metres
# apart along the CURVE — a curved section stretches slightly. The alternative is an iterative
# re-parameterisation for a spacing nothing downstream measures, and `Path Resample` at LINEAR (the
# default) is exact, which is the case PathShapeGate [C] pins.
@tool
class_name Pasture3DGraphNodePathResample
extends Pasture3DGraphNodePathShape

## How to place a vertex between two of the input's.
##
## LINEAR walks the polyline itself, so the output line is a subset of the input line — no new shape, only
## new vertices. The other three round the corners, which is usually what a drawn line wants and is
## occasionally not: a road centreline that was solved to survey points should stay on them.
##
## BEZIER treats each input segment as a cubic whose control points sit a third of the way along the
## neighbouring segments — a Catmull-Rom in Bezier clothing, kept as a separate entry because it is the
## name people reach for and because its tangents are clamped at the ends where CATMULL_ROM's are
## reflected.
enum Method { LINEAR, CUBIC, CATMULL_ROM, BEZIER }

@export var method: Method = Method.LINEAR:
	set(v):
		method = v
		emit_changed()

## Vertex spacing in metres. The floor is not cosmetic: a step approaching zero on a kilometre of river is
## a million-vertex path, which is not slow, it is a hang.
@export_range(0.25, 200.0, 0.05, "or_greater", "suffix:m") var step: float = 4.0:
	set(v):
		step = maxf(v, 0.05)
		emit_changed()

## Close the path — join the last vertex back to the first — before resampling.
##
## Here rather than only on the spline because a closed line is a *graph-level* decision for the reshape
## family: Meanderize on a closed ring is a lake outline and on an open one is a river, from the same
## drawn points. Never UN-closes: a path that arrives closed stays closed, because opening a ring silently
## deletes the closing edge and the terrain loses a chunk of shoreline with no warning.
@export var close: bool = false:
	set(v):
		close = v
		emit_changed()

## Above this many output vertices the resample refuses and passes the input through, with a warning.
##
## A guard rather than a clamp: silently coarsening the step would give a path that looks resampled and is
## not, at a spacing the user never chose. 200 000 vertices is far past anything a bake needs and well
## short of what stalls the editor.
const MAX_POINTS: int = 200000


func op() -> StringName:
	return &"path_resample"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if close:
		p_out.closed = true
	# The ring is built from the OUTPUT's `closed`, so ticking `close` on an open input adds the closing
	# edge before the walk rather than after it — otherwise the last `step` metres of the ring would be
	# whatever fell out of the join instead of a resampled segment like every other.
	var ring := ring_of(p_out)
	if ring.size() < 2:
		return
	var cum := arc_lengths(ring)
	var total: float = cum[cum.size() - 1]
	if total <= 0.0:
		return
	var count := int(floor(total / step)) + 1
	if count < 2 or count > MAX_POINTS:
		return

	var pts := PackedVector2Array()
	pts.resize(count)
	for i in count:
		pts[i] = _at(ring, cum, minf(float(i) * step, total))
	# The tail. A line whose length is not a whole number of steps would otherwise stop short of its own
	# end, and the last fraction of a river is exactly where a mouth is.
	if pts[count - 1].distance_to(ring[ring.size() - 1]) > step * 0.5:
		pts.append(ring[ring.size() - 1])

	p_out.points = unring(pts, p_out.closed)
	carry_values(p_src, p_out)


## The point at arc length `p_s`, by whichever method is set.
func _at(p_ring: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float) -> Vector2:
	var n := p_ring.size()
	var i := 1
	while i < n - 1 and p_cum[i] < p_s:
		i += 1
	var s0: float = p_cum[i - 1]
	var s1: float = p_cum[i]
	var t: float = 0.0 if s1 <= s0 else clampf((p_s - s0) / (s1 - s0), 0.0, 1.0)
	if method == Method.LINEAR:
		return p_ring[i - 1].lerp(p_ring[i], t)
	# The four control points around segment [i-1, i]. Ends are handled by CLAMPING on a closed ring's
	# behalf too — a ring's neighbours wrap, but `ring_of` has already repeated the first vertex at the
	# end, so index 0 and index n-1 are the same place and clamping there is the wrap.
	var p0 := p_ring[maxi(i - 2, 0)]
	var p1 := p_ring[i - 1]
	var p2 := p_ring[i]
	var p3 := p_ring[mini(i + 1, n - 1)]
	if method == Method.BEZIER:
		# Control points a third of the way along the neighbouring chords: the standard Catmull-Rom to
		# Bezier conversion, written out because the two enum entries differ only at the ends.
		var c1 := p1 + (p2 - p0) / 6.0
		var c2 := p2 - (p3 - p1) / 6.0
		var u := 1.0 - t
		return (p1 * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t)
				+ p2 * (t * t * t))
	if method == Method.CUBIC:
		return p1.cubic_interpolate(p2, p0, p3, t)
	return _catmull_rom(p0, p1, p2, p3, t)


## Uniform (not centripetal) Catmull-Rom. Centripetal would avoid the cusp a near-duplicate control point
## produces, and a resample step small enough to see that cusp is already finer than any terrain cell —
## so the extra square roots would buy nothing measurable and one more thing to keep identical if this
## ever has to agree with a C++ twin.
static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if step < 0.5:
		out.append("Path Resample's step is %.2f m — below about half a terrain cell the extra vertices "
				% step + "cost bake time and change nothing you can see.")
	return out
