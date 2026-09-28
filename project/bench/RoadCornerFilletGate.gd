# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadCornerFilletGate — split-tangent and sharp spline points are rounded in the road's PLAN, without
# editing the spline, so the grade, the ribbon and the paint all flow through the corner (2026-09-27).
#
# Every consumer reads one plan (`_plan_points`), so the gate reads the plan and the arc lengths the
# segments are measured in. Each criterion is paired with `sharp_point_radius = 0`, which must leave the
# kink exactly where it was -- the control that says the rounding, and not the fixture, made the difference.
#
#   [K] kink: a zero-handle 90 degree corner turns by at most a few degrees per plan vertex. Control: 90 at 0
#   [R] radius: the arc through it turns 90 degrees over about R * pi/2 metres, R the auto radius
#   [C] control points: the kink's point sits at its arc's midpoint (the nearest plan point to it), the ends
#       at 0 and the total. Control: unrounded, the kink's point is exactly 50 m along
#   [L] closed loop: a closed square turns smoothly everywhere INCLUDING the seam, still closes, and point 0
#       still sits at s = 0. Control: unrounded, the seam turns 90 degrees
#   [S] smooth points are left alone: mirrored handles are not a kink, so the plan is the raw tessellation
#   [J] spline join: two splines meeting at an angle are rounded where they meet. Control: unrounded
#   [D] detector: `detect_sharp_corners` finds nothing on the auto-rounded kink and one on the unrounded
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadCornerFilletGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["K", "R", "C", "L", "S", "J", "D"]
const SMOOTH_DEG := 6.0

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadCornerFilletGate ===")
	await get_tree().process_frame
	_k_r_c()
	_l()
	_s()
	_j()
	_d()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD CORNER FILLET %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _brush(p_points: Array, p_radius: float, p_closed: bool = false, p_splines: int = 1) -> Pasture3DRoadBrush:
	var t := Pasture3DRoadType.new()
	t.lane_width = 3.5
	t.shoulder_width = 1.0
	t.sharp_point_radius = p_radius
	var b := Pasture3DRoadBrush.new()
	b.road_road_type = t
	b.snap_to_surface = false
	add_child(b)
	# Split the point list across `p_splines` splines, the join point repeated as the next one's first.
	var per := ceili(float(p_points.size() - 1) / float(p_splines))
	var start := 0
	for k in p_splines:
		var path := Path3D.new()
		var c := Curve3D.new()
		var stop := mini(start + per, p_points.size() - 1)
		for i in range(start, stop + 1):
			var p = p_points[i]
			if p is Array:
				c.add_point(p[0], p[1], p[2])
			else:
				c.add_point(p)
		path.curve = c
		b.add_child(path)
		start = stop
	b.closed = p_closed
	return b


func _turns(p_raw: PackedVector2Array, p_closed: bool) -> PackedFloat32Array:
	# Duplicate vertices dropped first: two splines meet at a repeated point, and a zero-length segment
	# either side of the join would hide the very turn [J] is looking for.
	var p_plan := PackedVector2Array()
	for p in p_raw:
		if p_plan.is_empty() or p_plan[p_plan.size() - 1].distance_to(p) > 1e-5:
			p_plan.append(p)
	var out := PackedFloat32Array()
	var n := p_plan.size()
	for i in n:
		var ip := i - 1
		var inn := i + 1
		if p_closed:
			# The last vertex repeats the first; the turn at the seam is between the last real segment and
			# the first.
			if i == n - 1:
				continue
			if ip < 0:
				ip = n - 2
		elif ip < 0 or inn >= n:
			continue
		var a := (p_plan[i] - p_plan[ip])
		var b := (p_plan[inn] - p_plan[i])
		if a.length() < 1e-6 or b.length() < 1e-6:
			continue
		out.append(rad_to_deg(acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0))))
	return out


func _max(p_v: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_v:
		m = maxf(m, v)
	return m


func _k_r_c() -> void:
	print("[K][R][C] a zero-handle 90 degree corner")
	var pts := [Vector3(0, 0, 0), Vector3(50, 0, 0), Vector3(50, 0, 50)]
	var rounded := _brush(pts, -1.0)
	var sharp := _brush(pts, 0.0)
	var plan := rounded._plan_points()
	var t_r := _max(_turns(plan, false))
	var t_s := _max(_turns(sharp._plan_points(), false))
	_check("K", t_r <= SMOOTH_DEG and absf(t_s - 90.0) < 0.5,
			"max turn per vertex %.2f deg (want <= %.0f); control: unrounded %.2f deg" % [t_r, SMOOTH_DEG, t_s])

	# [R] the arc: where the plan turns at all, it turns 90 degrees in total over about R pi/2.
	var r := rounded.resolved_road_type().resolved_sharp_point_radius(rounded.resolved_lane_count())
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var first := -1
	var last := -1
	for i in range(1, plan.size() - 1):
		var a := (plan[i] - plan[i - 1]).normalized()
		var b := (plan[i + 1] - plan[i]).normalized()
		if acos(clampf(a.dot(b), -1.0, 1.0)) > 1e-4:
			if first < 0:
				first = i
			last = i
	var arc_len := cum[last] - cum[first] if first >= 0 else 0.0
	var want := r * PI * 0.5
	_check("R", first >= 0 and absf(arc_len - want) < 0.06 * want,
			"arc %.2f m for R %.2f m (want %.2f +- 6%%)" % [arc_len, r, want])

	# [C] where the control points sit.
	var s1 := rounded.point_arc_length(1)
	var hit := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(50, 0))
	var total: float = cum[cum.size() - 1]
	var s1_sharp := sharp.point_arc_length(1)
	_check("C", absf(s1 - float(hit[1])) < 0.05 and rounded.point_arc_length(0) == 0.0
			and absf(rounded.point_arc_length(2) - total) < 1e-3 and absf(s1_sharp - 50.0) < 1e-3
			and is_nan(rounded.point_arc_length(3)),
			"point 1 at %.2f m, nearest plan point to it at %.2f m; ends %.2f / %.2f of %.2f; control: unrounded point 1 at %.3f m"
			% [s1, hit[1], rounded.point_arc_length(0), rounded.point_arc_length(2), total, s1_sharp])
	rounded.queue_free()
	sharp.queue_free()


func _l() -> void:
	print("[L] a closed square, including its seam")
	var pts := [Vector3(0, 0, 0), Vector3(60, 0, 0), Vector3(60, 0, 60), Vector3(0, 0, 60)]
	var rounded := _brush(pts, -1.0, true)
	var sharp := _brush(pts, 0.0, true)
	var plan := rounded._plan_points()
	var t_r := _max(_turns(plan, true))
	var t_s := _max(_turns(sharp._plan_points(), true))
	var closes := plan[0].distance_to(plan[plan.size() - 1]) < 1e-4
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var nearest0 := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(0, 0))
	var s0 := rounded.point_arc_length(0)
	# The corner nearest point 0 is the arc's midpoint, at s = 0 (or the total, which is the same place).
	var at_seam := s0 == 0.0 and (float(nearest0[1]) < 0.05 or absf(float(nearest0[1]) - cum[cum.size() - 1]) < 0.05)
	var s_pts := PackedFloat32Array()
	for i in 4:
		s_pts.append(rounded.point_arc_length(i))
	var ascending := s_pts[0] < s_pts[1] and s_pts[1] < s_pts[2] and s_pts[2] < s_pts[3]
	_check("L", t_r <= SMOOTH_DEG and closes and at_seam and ascending and t_s > 89.5,
			"max turn %.2f deg (want <= %.0f), closes %s, point 0 at s %.3f with its arc midpoint there: %s, points in order %s; control: unrounded %.2f deg"
			% [t_r, SMOOTH_DEG, closes, s0, at_seam, s_pts, t_s])
	rounded.queue_free()
	sharp.queue_free()


func _s() -> void:
	print("[S] a smooth point is not a kink")
	var pts := [Vector3(0, 0, 0), [Vector3(50, 0, 0), Vector3(-15, 0, -8), Vector3(15, 0, 8)], Vector3(90, 0, 50)]
	var rounded := _brush(pts, -1.0)
	var raw := _brush(pts, 0.0)
	var a := rounded._plan_points()
	var b := raw._plan_points()
	_check("S", a == b and a.size() > 3, "the plan is the raw tessellation (%d vs %d vertices)" % [a.size(), b.size()])
	rounded.queue_free()
	raw.queue_free()


func _j() -> void:
	print("[J] two splines meeting at an angle")
	var pts := [Vector3(0, 0, 0), Vector3(40, 0, 0), Vector3(80, 0, 0), Vector3(80, 0, 40), Vector3(80, 0, 80)]
	var rounded := _brush(pts, -1.0, false, 2)
	var sharp := _brush(pts, 0.0, false, 2)
	var t_r := _max(_turns(rounded._plan_points(), false))
	var t_s := _max(_turns(sharp._plan_points(), false))
	var n_paths := 0
	for c in rounded.get_children():
		if c is Path3D:
			n_paths += 1
	_check("J", n_paths == 2 and t_r <= SMOOTH_DEG and absf(t_s - 90.0) < 0.5,
			"%d splines, max turn %.2f deg (want <= %.0f); control: unrounded %.2f deg" % [n_paths, t_r, SMOOTH_DEG, t_s])
	rounded.queue_free()
	sharp.queue_free()


func _d() -> void:
	print("[D] the sharp-corner detector reads the rounded plan")
	var pts := [Vector3(0, 0, 0), Vector3(50, 0, 0), Vector3(50, 0, 50)]
	var rounded := _brush(pts, -1.0)
	var sharp := _brush(pts, 0.0)
	var r_crit := 4.8
	var n_r := rounded.detect_sharp_corners(r_crit).size()
	var n_s := sharp.detect_sharp_corners(r_crit).size()
	_check("D", n_r == 0 and n_s == 1, "%d sharp corner(s) on the rounded plan (want 0); control: %d unrounded (want 1)" % [n_r, n_s])
	rounded.queue_free()
	sharp.queue_free()
