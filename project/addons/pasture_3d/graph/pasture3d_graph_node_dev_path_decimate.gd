# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathDecimate — the ORACLE for Path Decimate. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_decimate_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathDecimate
extends Pasture3DGraphNodePathShape

@export_range(3, 4096, 1, "or_greater") var target_points: int = 64:
	set(v):
		target_points = maxi(v, 3)
		emit_changed()

@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m²") var min_area: float = 0.0:
	set(v):
		min_area = maxf(v, 0.0)
		emit_changed()

const KEEPS_ENDS: bool = true
const MAX_ROUNDS: int = 1000000


func min_vertices() -> int:
	return 3


func op() -> StringName:
	return &"dev_path_decimate"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	var pts := p_src.points
	var n := pts.size()
	if n <= maxi(target_points, 3):
		return
	var keep := PackedInt32Array()
	keep.resize(n)
	for i in n:
		keep[i] = i

	var rounds := 0
	while keep.size() > maxi(target_points, 3) and rounds < MAX_ROUNDS:
		rounds += 1
		var worst := INF
		var worst_at := -1
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
			break
		keep.remove_at(worst_at)

	var out := PackedVector2Array()
	out.resize(keep.size())
	for k in keep.size():
		out[k] = pts[keep[k]]

	p_out.points = out
	carry_values(p_src, p_out)
