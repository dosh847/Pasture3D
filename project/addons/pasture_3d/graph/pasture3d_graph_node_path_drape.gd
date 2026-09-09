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
		_param_changed()

## Clamp the height sequence so it never rises along the line. See the header.
@export var force_downhill: bool = false:
	set(v):
		force_downhill = v
		_param_changed()

## With `force_downhill`, the minimum fall per metre of line — a gradient, not a step, so redistributing
## a line's vertices does not change its profile.
##
## Zero is allowed and means "never rises", which is flat where the ground is flat. The default 0.001 is
## 1 m per kilometre: enough that a `Pasture3DStream` reading the result finds a direction, and small
## enough to be invisible against any real relief.
@export_range(0.0, 0.5, 0.0001, "or_greater", "suffix:m/m") var min_drop: float = 0.001:
	set(v):
		min_drop = maxf(v, 0.0)
		_param_changed()


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
	# A drape replaces the vertical profile of the line. Drop any pre-existing road alignment
	# and sample arrays so downstream graders do not grade to a stale vertical solve.
	p_out.alignment = null
	p_out.sample_half_widths = PackedFloat32Array()
	p_out.sample_shoulders = PackedFloat32Array()
	p_out.sample_verges = PackedFloat32Array()
	p_out.sample_suppress = PackedByteArray()
	p_out.sample_skip = PackedByteArray()

	if port_unwired(1):
		# Nothing to drape ONTO. The path passes through carrying whatever heights it already had, which
		# for a spline with `carry_heights` is the authored line — the pre-drape answer, not a flat one.
		return

	if not ClassDB.class_has_method("Pasture3DUtil", "path_drape_solve"):
		push_error("[Pasture3D] Pasture3DUtil.path_drape_solve is not bound. Rebuild GDExtension.")
		return

	var surf: PackedFloat32Array = _grids[1]
	p_out.heights = Pasture3DUtil.path_drape_solve(p_out.points, p_out.heights, p_out.closed,
			surf, _gw, _gh, _rect, offset, force_downhill, min_drop)


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if port_unwired(1):
		out.append("Path Drape has no surface wired, so it passes the path through unchanged. Wire the "
				+ "terrain you want it to sit on into `surface`.")
	if force_downhill:
		if _out != null and _out.closed:
			out.append("Path is closed: Force Downhill is suppressed because a closed loop cannot be "
					+ "monotonically downhill without creating a vertical cliff at the seam.")
		elif _out != null and _out.points.size() >= 2 and _grids.size() > 1 and not _grids[1].is_empty():
			var h0: float = sample_grid(_grids[1], _out.points[0].x, _out.points[0].y)
			var h_end: float = sample_grid(_grids[1], _out.points[-1].x, _out.points[-1].y)
			if is_finite(h0) and is_finite(h_end) and h_end > h0 + 5.0:
				out.append("The terrain rises along this path from vertex 0 to the end. Force Downhill "
						+ "clamps from vertex 0, which will carve deeply into the terrain. Reverse the spline "
						+ "so vertex 0 sits at the upstream head.")
	return out
