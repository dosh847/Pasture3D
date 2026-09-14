# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# JunctionOutlineGate — `plan_footprint` must keep every outline vertex at the junction, whatever the arm angles.
#
# 2026-09-13: a three-arm junction whose north and south arms were 0.2 degrees short of antiparallel got a
# vertex 1.36 km out. `_append_fillet` pushed the crossing of two nearly parallel edge lines, the ring was
# densified to 2773 vertices, and the Coons patch over its box blocked the main thread for minutes.
#
#   [A] CONTROL  the fixture reaches the bug: the raw edge-line crossing for the skewed pair is far outside the
#                bound. Without this, [B] could pass on arms that never enter the antiparallel branch.
#   [B]          at that skew, every outline vertex is inside the bound
#   [C]          the skewed outline matches the exactly antiparallel one (same count, vertices within 0.1 m)
#   [D]          a sweep of skews through the whole FILLET_MIN_ANGLE window stays bounded and meshes small
#   [E] CONTROL  an ordinary T still gets its kerb returns — the fix must not straighten every corner
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/JunctionOutlineGate.tscn
extends Node

const TRIM := 10.0
const HALF := 4.5
const SOUTH_HALF := 4.0
const RADIUS := 3.0
const SKEW_DEG := 0.2

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== JunctionOutlineGate ===")
	var bound := 2.0 * (TRIM + HALF + RADIUS)
	_a_control_crossing_is_far(bound)
	_b_skewed_outline_bounded(bound)
	_c_matches_exact_antiparallel()
	_d_skew_sweep(bound)
	_e_control_t_keeps_fillets()
	var expected := 5
	if _ran != expected:
		_check("completed", false, "%d of %d criteria ran" % [_ran, expected])
	print("=== JUNCTION OUTLINE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


## North and east arms, and a south arm rotated `p_skew_deg` so the north/south pair is nearly antiparallel.
##
## The south arm is NARROWER. With equal halves the two west edges are nearly collinear and cross a few metres
## out, which is a legitimate corner — the first version of this gate measured exactly that and [A] caught it.
## The edges must be OFFSET: the crossing then sits about offset / skew away, ~140 m here.
func _arms(p_skew_deg: float) -> Array:
	return [
		{"dir": Vector2(0, 1), "trim": TRIM, "half": HALF},
		{"dir": Vector2(1, 0), "trim": 6.0, "half": HALF},
		{"dir": Vector2(0, -1).rotated(deg_to_rad(p_skew_deg)), "trim": TRIM, "half": SOUTH_HALF},
	]


func _max_radius(p_ring: PackedVector2Array) -> float:
	var m := 0.0
	for v in p_ring:
		m = maxf(m, v.length())
	return m


func _a_control_crossing_is_far(p_bound: float) -> void:
	# The corner that failed: north arm's counter-clockwise corner to the south arm's clockwise corner.
	var n_dir := Vector2(0, 1)
	var s_dir := Vector2(0, -1).rotated(deg_to_rad(SKEW_DEG))
	var n_ccw := n_dir * TRIM + Vector2(-n_dir.y, n_dir.x) * HALF
	var s_cw := s_dir * TRIM - Vector2(-s_dir.y, s_dir.x) * SOUTH_HALF
	var hit := Pasture3DRoadMesher._ray_intersect(n_ccw, n_dir, s_cw, s_dir)
	var phi := acos(clampf(n_dir.dot(s_dir), -1.0, 1.0))
	var in_branch := phi > PI - Pasture3DRoadMesher.FILLET_MIN_ANGLE
	var far := not hit.is_empty() and (hit[0] as Vector2).length() > p_bound
	_ran += 1
	_check("[A] control: raw crossing is far", in_branch and far, "phi %.4f (branch %s), crossing %s, bound %.1f m" % [
			phi, in_branch, "none" if hit.is_empty() else "%.1f m out" % (hit[0] as Vector2).length(), p_bound])


func _b_skewed_outline_bounded(p_bound: float) -> void:
	var ring := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _arms(SKEW_DEG), RADIUS)
	var r := _max_radius(ring)
	_ran += 1
	_check("[B] skewed outline bounded", ring.size() >= 3 and r <= p_bound,
			"%d vert(s), furthest %.2f m, bound %.1f m" % [ring.size(), r, p_bound])


func _c_matches_exact_antiparallel() -> void:
	var exact := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _arms(0.0), RADIUS)
	var skew := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _arms(SKEW_DEG), RADIUS)
	var worst := INF
	if exact.size() == skew.size() and not exact.is_empty():
		worst = 0.0
		for i in exact.size():
			worst = maxf(worst, exact[i].distance_to(skew[i]))
	_ran += 1
	_check("[C] matches exact antiparallel", exact.size() == skew.size() and worst <= 0.1,
			"%d vs %d vert(s), worst displacement %s" % [exact.size(), skew.size(),
			"n/a" if worst == INF else "%.3f m" % worst])


func _d_skew_sweep(p_bound: float) -> void:
	var window := rad_to_deg(Pasture3DRoadMesher.FILLET_MIN_ANGLE)
	var bad := PackedStringArray()
	var worst_r := 0.0
	var worst_mesh := 0
	var steps := 40
	for k in range(-steps, steps + 1):
		var deg := window * float(k) / float(steps)
		var ring := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _arms(deg), RADIUS)
		var r := _max_radius(ring)
		var dense := Pasture3DRoadMesher.densify_polygon(ring, 1.0).size()
		worst_r = maxf(worst_r, r)
		worst_mesh = maxi(worst_mesh, dense)
		if ring.size() < 3 or r > p_bound or dense > 400:
			bad.append("%.3f deg (%.1f m, %d)" % [deg, r, dense])
	_ran += 1
	_check("[D] skew sweep +-%.2f deg bounded" % window, bad.is_empty(),
			"%d skew(s); furthest %.2f m, largest densified ring %d%s" % [2 * steps + 1, worst_r, worst_mesh,
			"" if bad.is_empty() else "; bad: " + ", ".join(bad)])


func _e_control_t_keeps_fillets() -> void:
	var arms := [
		{"dir": Vector2(0, 1), "trim": TRIM, "half": HALF},
		{"dir": Vector2(1, 0), "trim": TRIM, "half": HALF},
		{"dir": Vector2(0, -1), "trim": TRIM, "half": HALF},
	]
	var ring := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, RADIUS)
	var squared := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, 0.0)
	_ran += 1
	# Two right-angle corners each gain FILLET_SEGMENTS - 1 arc points plus two tangent points over the bare vertex.
	_check("[E] control: T keeps kerb returns", ring.size() > squared.size() + 2,
			"radius %.1f: %d vert(s); radius 0: %d vert(s)" % [RADIUS, ring.size(), squared.size()])
