# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathDrape — the ORACLE for Path Drape. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node (pasture3d_graph_node_path_drape.gd) calls Pasture3DUtil.path_drape_solve
# and fails fast without it. This is the pure GDScript definition that kernel is measured against.
@tool
class_name Pasture3DGraphNodeDevPathDrape
extends Pasture3DGraphNodePathDerive

@export_range(-200.0, 200.0, 0.1, "or_greater", "or_less", "suffix:m") var offset: float = 0.0:
	set(v):
		offset = v
		_param_changed()

@export var force_downhill: bool = false:
	set(v):
		force_downhill = v
		_param_changed()

@export_range(0.0, 0.5, 0.0001, "or_greater", "suffix:m/m") var min_drop: float = 0.001:
	set(v):
		min_drop = maxf(v, 0.0)
		_param_changed()


func op() -> StringName:
	return &"dev_path_drape"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["path", "surface"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH, PortType.HEIGHT])


func input_unwired_default(p_port: int) -> float:
	return NAN if p_port == 1 else 0.0


func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	p_out.alignment = null
	p_out.sample_half_widths = PackedFloat32Array()
	p_out.sample_shoulders = PackedFloat32Array()
	p_out.sample_verges = PackedFloat32Array()
	p_out.sample_suppress = PackedByteArray()
	p_out.sample_skip = PackedByteArray()

	if port_unwired(1):
		return
	var surf: PackedFloat32Array = _grids[1]
	var pts := p_out.points
	var n := pts.size()
	var hs := PackedFloat32Array()
	hs.resize(n)
	for i in n:
		var h: float = sample_grid(surf, pts[i].x, pts[i].y)
		if not is_finite(h):
			var prev_h: float = p_out.heights[i] if i < p_out.heights.size() else 0.0
			h = prev_h if is_finite(prev_h) else 0.0
		hs[i] = h + offset
	if force_downhill and n > 1 and not p_out.closed:
		for i in range(1, n):
			var run: float = pts[i].distance_to(pts[i - 1])
			hs[i] = minf(hs[i], hs[i - 1] - min_drop * run)
	p_out.heights = hs


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
