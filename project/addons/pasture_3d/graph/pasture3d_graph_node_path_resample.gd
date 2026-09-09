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
	if not ClassDB.class_has_method("Pasture3DUtil", "path_resample_solve"):
		push_error("Pasture3DGraphNodePathResample: Pasture3DUtil.path_resample_solve is missing from GDExtension!")
		return

	if close:
		p_out.closed = true

	var res: Dictionary = Pasture3DUtil.path_resample_solve(
		p_src.points,
		p_src.half_widths,
		p_src.heights,
		p_src.closed,
		method,
		step,
		close
	)

	if res.is_empty():
		return

	p_out.closed = res.get("closed", p_out.closed)
	p_out.points = res.get("points", PackedVector2Array())
	p_out.half_widths = res.get("half_widths", PackedFloat32Array())
	p_out.heights = res.get("heights", PackedFloat32Array())


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if step < 0.5:
		out.append("Path Resample's step is %.2f m — below about half a terrain cell the extra vertices "
				% step + "cost bake time and change nothing you can see.")
	return out
