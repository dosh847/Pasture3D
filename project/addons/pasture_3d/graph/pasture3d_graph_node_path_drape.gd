# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathDrape — give a path the heights of the ground it crosses.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5, §8.4. The first of the three GRID → PATH nodes, and the one
# that explains why the family needs a phase of its own: it reads the surface the graph is building.
#
# ---- WHAT IT IS FOR ----
#
# A `Pasture3DSpline` publishes the Y the author drew, and for a crest that is exactly right: the line IS
# the ridge. For a river it is exactly wrong — nobody wants to hand-place a hundred control points at the
# elevation of ground that erosion has not finished moving yet. Drape says "sit on whatever is there",
# and `force_downhill` then says "and flow".
#
# Downstream, `Path Carve.follow_path_height` is what reads the result. A drape with no carve below it
# changes no terrain at all, which is the node's most likely first impression and what `node_warnings`
# exists to head off.
#
# ---- FORCE DOWNHILL IS A CLAMP, NOT A SMOOTHING ----
#
# HighMap's `force_downhill`, and the same one line: walking from the start, each vertex is clamped to no
# higher than the one before it, minus `min_drop` per metre. It never RAISES a vertex. That asymmetry is
# the whole of it — a river bed that is allowed to rise to meet a hill is not a river, but one lowered
# into the hill is a gorge, which is a shape people want and `Path Carve` will happily cut.
#
# The direction is the path's own: vertex 0 is upstream. A line drawn the other way produces a river that
# runs uphill and looks broken, which is why the warning says so rather than the node guessing from the
# terrain — guessing would be right most of the time and unexplainable the rest.
@tool
class_name Pasture3DGraphNodePathDrape
extends Pasture3DGraphNodePathDerive

## Metres added to every sampled height, after the drape and before the downhill clamp.
##
## Positive lifts the line off the ground — a levee crest, or a road bench standing proud of the fill.
## Negative sinks it, which with a `Path Carve` BED below is the ordinary way to cut a channel to a fixed
## depth below whatever the terrain does.
@export_range(-200.0, 200.0, 0.1, "or_greater", "or_less", "suffix:m") var offset: float = 0.0:
	set(v):
		offset = v
		emit_changed()

## Clamp the height sequence so it never rises along the line. See the header.
@export var force_downhill: bool = false:
	set(v):
		force_downhill = v
		emit_changed()

## With `force_downhill`, the minimum fall per metre of line — a gradient, not a step, so redistributing
## a line's vertices does not change its profile.
##
## Zero is allowed and means "never rises", which is flat where the ground is flat. The default 0.001 is
## 1 m per kilometre: enough that a `Pasture3DStream` reading the result finds a direction, and small
## enough to be invisible against any real relief.
@export_range(0.0, 0.5, 0.0001, "or_greater", "suffix:m/m") var min_drop: float = 0.001:
	set(v):
		min_drop = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"path_drape"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["path", "surface"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH, PortType.HEIGHT])


## NAN, so an unwired surface is TELLABLE from a surface that is genuinely at sea level. The evaluator
## fills an unwired port with a constant and there is no other way back to the question — see
## Pasture3DGraphNodePathDerive.port_unwired.
func input_unwired_default(p_port: int) -> float:
	return NAN if p_port == 1 else 0.0


func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if port_unwired(1):
		# Nothing to drape ONTO. The path passes through carrying whatever heights it already had, which
		# for a spline with `carry_heights` is the authored line — the pre-drape answer, not a flat one.
		return
	var surf: PackedFloat32Array = _grids[1]
	var pts := p_out.points
	var n := pts.size()
	var hs := PackedFloat32Array()
	hs.resize(n)
	for i in n:
		var h: float = sample_grid(surf, pts[i].x, pts[i].y)
		# Outside the domain the surface says nothing. Carrying the vertex's existing height is better
		# than NAN: a path that leaves the brush's extent at one end would otherwise poison the carve's
		# whole interpolated crest, and a height that is merely stale is a visible, local wrongness.
		if not is_finite(h):
			h = p_out.heights[i] if i < p_out.heights.size() else 0.0
		hs[i] = h + offset
	if force_downhill and n > 1:
		for i in range(1, n):
			var run: float = pts[i].distance_to(pts[i - 1])
			hs[i] = minf(hs[i], hs[i - 1] - min_drop * run)
	p_out.heights = hs


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _gw > 0 and port_unwired(1):
		out.append("Path Drape has no surface wired, so it passes the path through unchanged. Wire the "
				+ "terrain you want it to sit on into `surface`.")
	return out
