# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadEndConnectionGate — Automatic End-to-End Road Connections & Junction Remediation (P10).
# Gating Criteria A through G from PASTURE3D_ROAD_END_CONNECTION_SPEC.md §4.
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadEndConnectionGate: end-to-end connections and junction remediation (P10) ===\n")
	_a_collinear_roads_connect_end_to_end()
	_b_collinear_matching_trim_is_zero()
	_c_lane_solver_connects_without_stop_lines_or_crossing_markings()
	_d_terminating_road_emits_one_arm()
	_e_indirect_acute_cluster_calculates_tangent_angle()
	_f_lane_count_transition_generates_trapezoid_and_taper()
	_g_route_traversal_is_continuous_across_seam()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["ROAD END CONNECTION PASS" if _fail == 0 else "ROAD END CONNECTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


# ---- fixtures -----------------------------------------------------------------------------------

func _solver_run(p_key: String, p_pts: PackedVector2Array, p_priority: int = 0,
		p_half: float = 4.0, p_height: float = 0.0) -> Dictionary:
	var cum := Pasture3DRoadGrader.cumulative_length(p_pts)
	var total: float = cum[cum.size() - 1]
	var n := maxi(int(ceil(total)) + 1, 2)
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	z.resize(n)
	z.fill(p_height)
	a.z = z
	a.ground = z.duplicate()
	var bridge := PackedByteArray()
	bridge.resize(n)
	bridge.fill(0)
	return {
		"key": p_key,
		"plan": p_pts,
		"cum": cum,
		"alignment": a,
		"bridge": bridge,
		"priority": p_priority,
		"half_width": p_half,
	}


# ---- Criteria -----------------------------------------------------------------------------------

## [A] Two collinear roads with endpoints within 1.0 m form an END_TO_END junction.
func _a_collinear_roads_connect_end_to_end() -> void:
	print("[A] collinear roads with endpoints within 1.0 m form an END_TO_END junction")
	var r_a := _solver_run("road_a", PackedVector2Array([Vector2(-50.0, 0.0), Vector2(0.0, 0.0)]), 10, 4.0)
	var r_b := _solver_run("road_b", PackedVector2Array([Vector2(0.5, 0.0), Vector2(50.0, 0.0)]), 5, 4.0)
	var js := Pasture3DRoadJunctionSolver.resolve([r_a, r_b])

	var count_ok := js.size() == 1
	_check("A", count_ok, "exactly one junction formed for touching endpoints (got %d)" % js.size())
	if not count_ok:
		return
	var j: Pasture3DRoadJunction = js[0]
	var kind_ok := j.kind == Pasture3DRoadJunction.JunctionKind.END_TO_END
	_check("A", kind_ok, "junction classified as END_TO_END (got %d)" % j.kind)
	var arms_ok := j.arm_dirs.size() == 2
	_check("A", arms_ok, "junction has exactly 2 arms (got %d)" % j.arm_dirs.size())

	# Control mutation: Move roads 5.0 m apart -> 0 junctions found.
	var r_b_far := _solver_run("road_b_far", PackedVector2Array([Vector2(5.0, 0.0), Vector2(50.0, 0.0)]), 5, 4.0)
	var js_far := Pasture3DRoadJunctionSolver.resolve([r_a, r_b_far])
	var control_ok := js_far.is_empty()
	_check("A", control_ok, "control: roads separated by 5.0 m do not connect (got %d junctions)" % js_far.size())


## [B] Trim-back on collinear matching roads is <= 1e-3 m (zero gap).
func _b_collinear_matching_trim_is_zero() -> void:
	print("[B] trim-back on collinear matching roads is <= 1e-3 m (zero gap)")
	var r_a := _solver_run("road_a", PackedVector2Array([Vector2(-50.0, 0.0), Vector2(0.0, 0.0)]), 10, 4.0)
	var r_b := _solver_run("road_b", PackedVector2Array([Vector2(0.0, 0.0), Vector2(50.0, 0.0)]), 10, 4.0)
	var js := Pasture3DRoadJunctionSolver.resolve([r_a, r_b])
	if js.is_empty():
		_check("B", false, "no junction formed")
		return
	var j: Pasture3DRoadJunction = js[0]
	var trim_a := j.trim_back_for("road_a")
	var trim_b := j.trim_back_for("road_b")
	var trim_ok := absf(trim_a) <= 1e-3 and absf(trim_b) <= 1e-3
	_check("B", trim_ok, "trims are zero (trim_a=%.4f, trim_b=%.4f)" % [trim_a, trim_b])
	_check("B", j.radius <= 1e-3, "junction radius is <= 1e-3 m (got %.4f)" % j.radius)

	# Footprint polygon for matching flush roads is empty (ribbons touch directly, no gap)
	var poly := Pasture3DRoadMesher.plan_footprint(j.center, j.footprint_arms(), j.effective_corner_radius())
	_check("B", poly.is_empty(), "matching flush collinear footprint polygon is empty (got %d verts)" % poly.size())

	# Control mutation: crossing formula w / sin θ would yield > 30 m trim
	var naive_sin: float = sin(Pasture3DRoadJunctionSolver.MIN_CROSSING_ANGLE)
	var naive_trim: float = 4.0 / naive_sin
	_check("B", naive_trim > 30.0, "control: w / sin θ diverges to %.2f m at shallow angles" % naive_trim)


## [C] Lane solver connects incoming lanes 1-to-1 without stop lines; markings are suppressed.
func _c_lane_solver_connects_without_stop_lines_or_crossing_markings() -> void:
	print("[C] lane solver connects 1-to-1 without stop lines, and markings are suppressed")
	var lanes := Pasture3DRoadLanes.cross_section(2, 3.5, false, false) # 1 forward, 1 backward
	var arms := [
		{
			"key": "road_a",
			"end": Pasture3DRoadLaneConnector.End.BEFORE,
			"point": Vector2(-2.0, 0.0),
			"y": 0.0,
			"distance": 48.0,
			"tangent": Vector2.RIGHT,
			"lanes": lanes,
		},
		{
			"key": "road_b",
			"end": Pasture3DRoadLaneConnector.End.AFTER,
			"point": Vector2(2.0, 0.0),
			"y": 0.0,
			"distance": 2.0,
			"tangent": Vector2.RIGHT,
			"lanes": lanes,
		},
	]
	var res := Pasture3DRoadLaneSolver.solve(arms, [], {"is_end_to_end": true})
	var connectors: Array = res["connectors"]
	var stop_lines: Array = res["stop_lines"]

	_check("C", connectors.size() == 2, "2 legal connectors generated (got %d)" % connectors.size())
	_check("C", stop_lines.is_empty(), "stop lines suppressed for END_TO_END (got %d)" % stop_lines.size())

	var j := Pasture3DRoadJunction.new()
	j.kind = Pasture3DRoadJunction.JunctionKind.END_TO_END
	j.road_keys = PackedStringArray(["road_a", "road_b"])
	j.connectors = []
	for c in connectors:
		if c is Pasture3DRoadLaneConnector:
			j.connectors.append(c)
	j.stop_lines = []

	var marks := Pasture3DRoadJunctionMarkings.plan_junction(j, arms)
	var stop_bar_count := 0
	var crosswalk_count := 0
	var give_way_count := 0
	var ribbon_count := 0
	for m: Dictionary in marks:
		match m["kind"]:
			Pasture3DRoadJunctionMarkings.Kind.STOP_BAR:
				stop_bar_count += 1
			Pasture3DRoadJunctionMarkings.Kind.CROSSWALK:
				crosswalk_count += 1
			Pasture3DRoadJunctionMarkings.Kind.GIVE_WAY:
				give_way_count += 1
			Pasture3DRoadJunctionMarkings.Kind.CONNECTOR_RIBBON:
				ribbon_count += 1
	_check("C", stop_bar_count == 0, "0 stop bars planned on END_TO_END (got %d)" % stop_bar_count)
	_check("C", crosswalk_count == 0, "0 crosswalks planned on END_TO_END (got %d)" % crosswalk_count)
	_check("C", give_way_count == 0, "0 give-way markings on END_TO_END (got %d)" % give_way_count)
	_check("C", ribbon_count > 0, "connector ribbons planned across transition (got %d)" % ribbon_count)

	# Control mutation: standard crossing produces stop lines
	var res_crossing := Pasture3DRoadLaneSolver.solve(arms, [], {"is_end_to_end": false})
	_check("C", res_crossing["stop_lines"].size() == 2, "control: standard crossing emits stop lines (got %d)" % res_crossing["stop_lines"].size())


class MockRoadBrush extends RefCounted:
	var _total: float
	func _init(p_total: float = 100.0) -> void:
		_total = p_total
	func resolved_lanes() -> Array:
		return [{"index": 0, "ordinal": 0, "direction": 1, "width": 3.5, "offset": 1.75}]
	func total_arc_length() -> float:
		return _total
	func height_at_arc(_s: float) -> float:
		return 5.0
	func point_at_arc(s: float) -> Vector2:
		return Vector2(s, 0.0)
	func tangent_at_arc(_s: float) -> Vector2:
		return Vector2.RIGHT


## [D] Terminating road emits exactly 1 arm in _arms_for (remediation of phantom arm bug).
func _d_terminating_road_emits_one_arm() -> void:
	print("[D] terminating road emits exactly 1 arm in _arms_for")
	var net := Pasture3DRoadNetwork.new()
	var j_terminus := Pasture3DRoadJunction.new()
	j_terminus.road_keys = PackedStringArray(["road_term"])
	j_terminus.arc_lengths = PackedFloat32Array([100.0])
	j_terminus.trim_backs = PackedFloat32Array([0.0])

	var brush := MockRoadBrush.new(100.0)
	var by_key := {"road_term": brush}
	var arms := net._arms_for(j_terminus, by_key)

	_check("D", arms.size() == 1, "terminating road contributes exactly 1 arm (got %d)" % arms.size())
	if arms.size() == 1:
		_check("D", int(arms[0]["end"]) == Pasture3DRoadLaneConnector.End.BEFORE,
				"terminating road arm is End.BEFORE (got %d)" % int(arms[0]["end"]))

	# Control mutation: a road continuing through junction (s=50 on 100m total) emits 2 arms
	var j_through := Pasture3DRoadJunction.new()
	j_through.road_keys = PackedStringArray(["road_term"])
	j_through.arc_lengths = PackedFloat32Array([50.0])
	j_through.trim_backs = PackedFloat32Array([0.0])
	var through_arms := net._arms_for(j_through, by_key)
	_check("D", through_arms.size() == 2, "control: through road contributes 2 arms (got %d)" % through_arms.size())


## [E] Clustered indirect acute pair uses tangent angle, not 90° fallback.
func _e_indirect_acute_cluster_calculates_tangent_angle() -> void:
	print("[E] indirect acute cluster calculates tangent angle, not 90° fallback")
	var dir_a := Vector2(1.0, 0.0)
	var dir_c := Vector2(cos(deg_to_rad(15.0)), sin(deg_to_rad(15.0)))
	var run_a := _solver_run("a", PackedVector2Array([Vector2.ZERO, dir_a * 100.0]), 0, 4.0)
	var run_c := _solver_run("c", PackedVector2Array([Vector2.ZERO, dir_c * 100.0]), 0, 4.0)
	var runs := [run_a, {}, run_c]
	var dummy_crossings: Array = [
		{"a": 0, "b": 1, "point": Vector2.ZERO, "s_a": 0.0, "s_b": 0.0, "angle": 0.5},
		{"a": 1, "b": 2, "point": Vector2.ZERO, "s_a": 0.0, "s_b": 0.0, "angle": 0.5},
	]
	var group: Array = [0, 1]

	var ang := Pasture3DRoadJunctionSolver._angle_between(dummy_crossings, group, 0, 2, runs, 0.0, 0.0)
	var ang_deg := rad_to_deg(ang)
	_check("E", absf(ang_deg - 15.0) < 1.0, "angle between indirect acute pair is ~15° (got %.2f°)" % ang_deg)

	var trim_tangent := 4.0 / sin(ang)
	_check("E", trim_tangent > 15.0, "trim calculated from tangent angle is > 15 m (got %.2f m)" % trim_tangent)

	# Control mutation: 90° fallback
	var ang_fallback := Pasture3DRoadJunctionSolver._angle_between(dummy_crossings, group, 0, 2)
	var trim_fallback := 4.0 / sin(ang_fallback)
	_check("E", absf(rad_to_deg(ang_fallback) - 90.0) < 1e-3, "control: fallback without runs yields 90°")
	_check("E", trim_fallback < 5.0, "control: 90° fallback collapses trim to %.2f m" % trim_fallback)


## [F] Lane count transition (4-lane to 2-lane) generates trapezoid and tapering.
func _f_lane_count_transition_generates_trapezoid_and_taper() -> void:
	print("[F] lane count transition (4-lane to 2-lane) generates trapezoid and tapering")
	var r_4 := _solver_run("road_4", PackedVector2Array([Vector2(-50.0, 0.0), Vector2(0.0, 0.0)]), 10, 7.0)
	var r_2 := _solver_run("road_2", PackedVector2Array([Vector2(0.0, 0.0), Vector2(50.0, 0.0)]), 5, 3.5)
	var js := Pasture3DRoadJunctionSolver.resolve([r_4, r_2])
	_check("F", js.size() == 1, "junction resolved for width step")
	if js.is_empty():
		return
	var j: Pasture3DRoadJunction = js[0]
	_check("F", j.kind == Pasture3DRoadJunction.JunctionKind.END_TO_END, "classified as END_TO_END")

	var want_trim := (7.0 - 3.5) * 3.0 * 0.5
	var trim_4 := j.trim_back_for("road_4")
	var trim_2 := j.trim_back_for("road_2")
	_check("F", absf(trim_4 - want_trim) < 0.01 and absf(trim_2 - want_trim) < 0.01,
			"taper trim applied (want %.2f m, got %.2f and %.2f)" % [want_trim, trim_4, trim_2])

	var arms := j.footprint_arms()
	var poly := Pasture3DRoadMesher.plan_footprint(j.center, arms, j.effective_corner_radius())
	_check("F", poly.size() >= 4, "footprint boundary has at least 4 vertices (got %d)" % poly.size())

	var area := 0.0
	for i in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		area += (p0.x * p1.y - p1.x * p0.y)
	area = absf(area) * 0.5
	_check("F", area > 50.0, "trapezoid has non-zero area bridging width step (got %.2f m²)" % area)

	var lanes_4 := Pasture3DRoadLanes.cross_section(4, 3.5, false, false)
	var lanes_2 := Pasture3DRoadLanes.cross_section(2, 3.5, false, false)
	var lane_arms := [
		{
			"key": "road_4", "end": Pasture3DRoadLaneConnector.End.BEFORE,
			"point": Vector2(-want_trim, 0.0), "y": 0.0, "distance": 50.0 - want_trim,
			"tangent": Vector2.RIGHT, "lanes": lanes_4
		},
		{
			"key": "road_2", "end": Pasture3DRoadLaneConnector.End.AFTER,
			"point": Vector2(want_trim, 0.0), "y": 0.0, "distance": want_trim,
			"tangent": Vector2.RIGHT, "lanes": lanes_2
		}
	]
	var lres := Pasture3DRoadLaneSolver.solve(lane_arms, [], {"is_end_to_end": true})
	var conns: Array = lres["connectors"]
	_check("F", conns.size() == 3, "3 connectors formed (2 forward merging to 1, 1 backward fanning to 1) (got %d)" % conns.size())


## [G] Route traversal across end-to-end connection is continuous.
func _g_route_traversal_is_continuous_across_seam() -> void:
	print("[G] route traversal across end-to-end connection is continuous")
	var rt := Pasture3DRoadRuntime.new()
	var r1 := Pasture3DRoadRun.new()
	r1.id = 1
	r1.label = "Run1"
	r1.plan = PackedVector2Array([Vector2(0.0, 0.0), Vector2(100.0, 0.0)])
	r1.cum = Pasture3DRoadGrader.cumulative_length(r1.plan)
	var a1 := Pasture3DRoadAlignment.new()
	a1.ds = 1.0
	var z1 := PackedFloat32Array()
	z1.resize(101)
	for i in 101:
		z1[i] = 10.0 + float(i) * 0.05
	a1.z = z1; a1.ground = z1.duplicate()
	var b1 := PackedFloat32Array(); b1.resize(101); b1.fill(0.0)
	a1.bank = b1; a1.curvature = b1
	r1.alignment = a1

	var r2 := Pasture3DRoadRun.new()
	r2.id = 2
	r2.label = "Run2"
	r2.plan = PackedVector2Array([Vector2(100.0, 0.0), Vector2(200.0, 0.0)])
	r2.cum = Pasture3DRoadGrader.cumulative_length(r2.plan)
	var a2 := Pasture3DRoadAlignment.new()
	a2.ds = 1.0
	var z2 := PackedFloat32Array()
	z2.resize(101)
	for i in 101:
		z2[i] = 15.0 + float(i) * 0.05
	a2.z = z2; a2.ground = z2.duplicate()
	var b2 := PackedFloat32Array(); b2.resize(101); b2.fill(0.0)
	a2.bank = b2; a2.curvature = b2
	r2.alignment = a2

	rt.runs = [r1, r2]
	rt.links = [{
		"at": Vector2(100.0, 0.0),
		"runs": PackedInt32Array([1, 2]),
		"s": PackedFloat32Array([100.0, 0.0]),
	}]

	var route := Pasture3DRoadRoute.new()
	route.entries = [
		{"run_id": 1, "reversed": false},
		{"run_id": 2, "reversed": false}
	]
	_check("G", absf(route.length(rt) - 200.0) < 0.1, "route length spans both runs (200 m, got %.1f)" % route.length(rt))

	var s_before := route.sample(rt, 99.9)
	var s_after := route.sample(rt, 100.1)
	_check("G", not s_before.is_empty() and not s_after.is_empty(), "samples before and after seam exist")
	if not s_before.is_empty() and not s_after.is_empty():
		var pos_diff: float = (s_before["position"] as Vector3).distance_to(s_after["position"] as Vector3)
		_check("G", pos_diff < 0.3, "position is continuous across seam (delta=%.3f m)" % pos_diff)
		var height_diff: float = absf(float(s_before["position"].y) - float(s_after["position"].y))
		_check("G", height_diff < 0.05, "height is continuous across seam (delta=%.3f m)" % height_diff)
		var tang_dot: float = (s_before["tangent"] as Vector3).dot(s_after["tangent"] as Vector3)
		_check("G", tang_dot > 0.99, "tangent is smooth across seam (dot=%.4f)" % tang_dot)

	# Control mutation: Route disconnected (only Run 1) clamps at 100 m
	var single_route := Pasture3DRoadRoute.new()
	single_route.entries = [{"run_id": 1, "reversed": false}]
	var s_past := single_route.entry_at(rt, 105.0)
	_check("G", s_past["local_s"] <= 100.0, "control: disconnected route clamps at 100 m (got %.1f)" % s_past["local_s"])
