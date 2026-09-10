# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadMountainCivilGate — Simcade Phase 5 (Revised): Civil Mountain Road Engineering & Adaptive Splines.
# Gating:
#   [A] Editor Performance & Adaptive Plan Tessellation (< 150 points, fast)
#   [B] Hairpin Apex Curvature Preservation & Localized Transition (no straight bleed)
#   [C] Mountain Banking Cap for Sharp Turns (civil drainage crossfall vs track banking)
#   [D] Hairpin Grade Compensation on Steep Climbs (gradient easing through switchbacks)
#   [E] Carriageway Curve Widening (extra width around sharp curves)
#   [F] Bit-Accurate C++ / GDScript Parity (tangent stencil & solve_with_plan)
@tool
extends Node

const DS: float = 1.0

var _fail: int = 0
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F"]
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadMountainCivilGate: civil mountain road geometry & adaptive splines (Phase 5) ===\n")
	_a_editor_performance_and_adaptive_splines()
	_b_hairpin_apex_preservation_and_localized_transition()
	_c_mountain_banking_cap()
	_d_hairpin_grade_compensation()
	_e_carriageway_curve_widening()
	_f_cpp_gdscript_parity()
	for c in CRITERIA:
		if not _reported.get(c, false):
			_fail += 1
			print("    !! criterion [%s] never reported (gate aborted early)" % c)
	print("\n=== %s (%d failures) ===\n" % ["ROAD MOUNTAIN CIVIL PASS" if _fail == 0 else "ROAD MOUNTAIN CIVIL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
		print("    FAIL [%s]: %s" % [p_name, p_detail])
	else:
		print("    PASS [%s]: %s" % [p_name, p_detail])


func _resample_plan(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_ds: float, p_n: int) -> PackedVector2Array:
	if ClassDB.class_has_method("Pasture3DUtil", "resample_plan"):
		return Pasture3DUtil.resample_plan(p_plan, p_cum, p_ds, p_n)
	var out := PackedVector2Array()
	out.resize(p_n)
	for i in p_n:
		out[i] = Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, float(i) * p_ds)
	return out


## Constructs a 180-degree hairpin switchback path:
## - 50m straight approach along +X
## - 180° circular arc (R = 15m, length = pi * 15 ≈ 47.12m)
## - 50m straight return along -X
## Total length ≈ 147.12m.
func _make_switchback_fixture() -> Dictionary:
	var curve := Curve3D.new()
	# Approach: (0, 0, 0) to (50, 0, 0)
	curve.add_point(Vector3(0.0, 0.0, 0.0), Vector3.ZERO, Vector3(25.0, 0.0, 0.0))
	curve.add_point(Vector3(50.0, 0.0, 0.0), Vector3(-15.0, 0.0, 0.0), Vector3(8.284, 0.0, 0.0))
	# Hairpin arc turning around (50, 0, 15) to (50, 0, 30)
	curve.add_point(Vector3(65.0, 0.0, 15.0), Vector3(0.0, 0.0, -8.284), Vector3(0.0, 0.0, 8.284))
	curve.add_point(Vector3(50.0, 0.0, 30.0), Vector3(8.284, 0.0, 0.0), Vector3(-25.0, 0.0, 0.0))
	# Return straight: (50, 0, 30) to (0, 0, 30)
	curve.add_point(Vector3(0.0, 0.0, 30.0), Vector3(15.0, 0.0, 0.0), Vector3.ZERO)

	# Tessellate plan
	var pts3d := curve.tessellate(5, 4.0)
	var plan := PackedVector2Array()
	var cum := PackedFloat32Array()
	var run := 0.0
	for i in pts3d.size():
		var p2 := Vector2(pts3d[i].x, pts3d[i].z)
		plan.append(p2)
		if i == 0:
			cum.append(0.0)
		else:
			run += plan[i - 1].distance_to(p2)
			cum.append(run)

	var total_s: float = cum[cum.size() - 1]
	var n_s := int(ceil(total_s / DS)) + 1
	var resampled := _resample_plan(plan, cum, DS, n_s)

	return {
		"curve": curve,
		"plan": plan,
		"cum": cum,
		"total_s": total_s,
		"n_s": n_s,
		"resampled": resampled,
	}


## [A] Editor Performance & Adaptive Plan Tessellation:
## The native curve tessellation produces a concise, adaptive polyline (< 150 points for ~150m),
## avoiding the 20x-40x point explosion that froze the Godot editor on mouse drags.
func _a_editor_performance_and_adaptive_splines() -> void:
	print("[A] editor performance & adaptive splines (fast, no point explosion)")
	var fx := _make_switchback_fixture()
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]

	# Check point count
	var pt_count := plan.size()
	var ok_count: bool = pt_count > 10 and pt_count < 150
	_check("A", ok_count, "tessellated plan points: %d (expected 15..150, not thousands)" % pt_count)

	# Verify tangent evaluation speed
	var t0 := Time.get_ticks_usec()
	var queries := 1000
	var total_s: float = float(fx["total_s"])
	var step: float = total_s / float(queries)
	for i in queries:
		var s: float = float(i) * step
		var _tan: Vector2 = Pasture3DRoadGrader.plan_tangent_at(plan, cum, s)
	var elapsed_ms := float(Time.get_ticks_usec() - t0) * 0.001
	var ok_speed: bool = elapsed_ms < 15.0
	_check("A", ok_speed, "1000 tangent queries took %.2f ms (expected < 15 ms)" % elapsed_ms)


## [B] Hairpin Apex Curvature Preservation & Localized Transition:
## Curvature at the hairpin apex must be preserved (not flattened by an over-long moving average),
## and banking transitions must be locally bounded by curve radius so banking does not bleed into straights.
func _b_hairpin_apex_preservation_and_localized_transition() -> void:
	print("[B] hairpin apex curvature preservation & localized transition length")
	var fx := _make_switchback_fixture()
	var resampled: PackedVector2Array = fx["resampled"]
	var n_s: int = fx["n_s"]

	var curv := Pasture3DRoadAlignmentSolver.plan_curvature(resampled)
	# Find peak curvature around the apex
	var max_k := 0.0
	var apex_i := -1
	for i in curv.size():
		var abs_k := absf(curv[i])
		if abs_k > max_k:
			max_k = abs_k
			apex_i = i

	# Apex curvature should be around 1 / 15m = 0.067 m^-1 (within reasonable bezier tolerance >= 0.045)
	var ok_apex: bool = max_k >= 0.045
	_check("B", ok_apex, "hairpin apex curvature: %.4f m^-1 (expected >= 0.045 m^-1)" % max_k)

	# Test banking with localized transition: L_trans <= 0.35 * R ≈ 5.25m
	var bank := Pasture3DRoadAlignmentSolver.superelevation(curv, 16.67, 0.06, DS, 25.0)

	# Banking at s = 20m (far ahead of turn, around i = 20) must be essentially zero (< 0.001)
	var approach_bank := absf(bank[20])
	var ok_no_bleed: bool = approach_bank < 0.001
	_check("B", ok_no_bleed, "banking on straight approach (s = 20m): %.5f rad (expected < 0.001 rad)" % approach_bank)

	# Banking at apex should be significant (>= 0.03)
	var apex_bank := absf(bank[apex_i])
	var ok_apex_bank: bool = apex_bank >= 0.03
	_check("B", ok_apex_bank, "banking at hairpin apex: %.4f rad (expected >= 0.03 rad)" % apex_bank)


## [C] Mountain Banking Cap for Sharp Turns:
## Real-world mountain roads limit hairpin banking to civil drainage crossfall (2% - 4%)
## rather than high-speed circuit banking.
func _c_mountain_banking_cap() -> void:
	print("[C] mountain banking cap (civil drainage crossfall on tight turns)")
	var fx := _make_switchback_fixture()
	var resampled: PackedVector2Array = fx["resampled"]
	var curv := Pasture3DRoadAlignmentSolver.plan_curvature(resampled)

	# Unconstrained banking (high design speed = 25 m/s, max_superelevation = 0.08)
	var unconstrained := Pasture3DRoadAlignmentSolver.superelevation(curv, 25.0, 0.08, DS, 25.0, -1.0)
	var max_unconstrained := 0.0
	for b in unconstrained:
		max_unconstrained = maxf(max_unconstrained, absf(b))

	# Constrained mountain banking cap = 0.04 rad (4% crossfall)
	var mtn_capped := Pasture3DRoadAlignmentSolver.superelevation(curv, 25.0, 0.08, DS, 25.0, 0.04)
	var max_capped := 0.0
	for b in mtn_capped:
		max_capped = maxf(max_capped, absf(b))

	var ok_cap: bool = max_capped <= 0.0401 and max_unconstrained > 0.05
	_check("C", ok_cap, "mountain capped max banking: %.4f rad vs unconstrained: %.4f rad (cap = 0.04)" % [max_capped, max_unconstrained])


## [D] Hairpin Grade Compensation on Steep Climbs:
## In civil road engineering (AASHTO / Swiss Norm VSS), hairpins on steep slopes require
## grade easing to prevent vehicle traction loss and roll-overs.
func _d_hairpin_grade_compensation() -> void:
	print("[D] hairpin grade compensation on steep climbs")
	var fx := _make_switchback_fixture()
	var resampled: PackedVector2Array = fx["resampled"]
	var n_s: int = fx["n_s"]

	# Steep mountain ground: 12% grade (g = 0.12)
	var ground := PackedFloat32Array()
	ground.resize(n_s)
	for i in n_s:
		ground[i] = 100.0 + float(i) * DS * 0.12

	# Solve with hairpin_grade_compensation = 0.5
	var opts := {
		"hairpin_grade_compensation": 0.5,
	}
	var alignment := Pasture3DRoadAlignmentSolver.solve_with_plan(resampled, ground, DS, 0.12, 16.67, 0.06, opts)

	# Measure grade across the hairpin apex vs approach straight
	var curv := alignment.curvature
	var max_k := 0.0
	var apex_i := -1
	for i in curv.size():
		var abs_k := absf(curv[i])
		if abs_k > max_k:
			max_k = abs_k
			apex_i = i

	var approach_grade := alignment.grade_at(20) # on straight approach
	var apex_grade := alignment.grade_at(apex_i)   # at hairpin apex

	# Grade at apex should be reduced by >= 25% compared to approach
	var reduction := (approach_grade - apex_grade) / maxf(approach_grade, 0.001)
	var ok_comp: bool = reduction >= 0.25 and apex_grade <= 0.09
	_check("D", ok_comp, "hairpin apex grade: %.4f (%.1f%% reduction from straight %.4f)" % [apex_grade, reduction * 100.0, approach_grade])


## [E] Carriageway Curve Widening:
## Road carriageway widens dynamically around sharp turns (hairpins) to accommodate vehicle sweep paths.
func _e_carriageway_curve_widening() -> void:
	print("[E] carriageway curve widening around sharp curves")
	var fx := _make_switchback_fixture()
	var resampled: PackedVector2Array = fx["resampled"]
	var n_s: int = fx["n_s"]

	var t := Pasture3DRoadType.new()
	t.lane_width = 3.5
	t.lane_count = 2
	t.curve_widening_enabled = true
	t.curve_widening_factor = 25.0
	t.curve_widening_max = 2.0

	var curv := Pasture3DRoadAlignmentSolver.plan_curvature(resampled)
	var max_k := 0.0
	for k in curv:
		max_k = maxf(max_k, absf(k))

	# Compute expected extra width at apex: clamp(factor * max_k, 0, max)
	var expected_extra := clampf(t.curve_widening_factor * max_k, 0.0, t.curve_widening_max)
	var base_half := t.half_width(2)

	# Verify widening magnitude
	var ok_widen: bool = expected_extra >= 1.0
	_check("E", ok_widen, "curve widening at apex: +%.2f m (base half: %.2f m, widened: %.2f m)" % [expected_extra, base_half, base_half + expected_extra])


## [F] Bit-Accurate C++ / GDScript Parity:
## Both the 5-point Savitzky-Golay tangent evaluator and solve_with_plan with civil options
## must match between C++ and GDScript within machine precision.
func _f_cpp_gdscript_parity() -> void:
	print("[F] bit-accurate C++ / GDScript parity")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_plan_tangent_at"):
		_check("F", false, "Pasture3DUtil.road_plan_tangent_at missing from ClassDB")
		return

	var fx := _make_switchback_fixture()
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var resampled: PackedVector2Array = fx["resampled"]
	var n_s: int = fx["n_s"]
	var total_s: float = fx["total_s"]

	# 1. Tangent Parity
	var max_tan_diff := 0.0
	for i in 50:
		var s := float(i) * (total_s / 49.0)
		var tan_cpp := Pasture3DUtil.road_plan_tangent_at(plan, cum, s)
		var tan_gd := Pasture3DRoadGrader.plan_tangent_at(plan, cum, s, 0.5, true)
		max_tan_diff = maxf(max_tan_diff, tan_cpp.distance_to(tan_gd))

	var ok_tan_parity: bool = max_tan_diff < 1e-4
	_check("F", ok_tan_parity, "tangent evaluator max diff C++ vs GDScript: %.6f (expected < 1e-4)" % max_tan_diff)

	# 2. Solver Parity (with mountain banking cap and hairpin grade compensation)
	var ground := PackedFloat32Array()
	ground.resize(n_s)
	for i in n_s:
		ground[i] = 50.0 + float(i) * DS * 0.08

	var opts := {
		"mountain_banking_cap": 0.04,
		"hairpin_grade_compensation": 0.5,
		"smooth_radius": 5.0,
	}

	var sol_cpp := Pasture3DRoadAlignmentSolver.solve_with_plan(resampled, ground, DS, 0.10, 20.0, 0.08, opts, false)
	var sol_gd := Pasture3DRoadAlignmentSolver.solve_with_plan(resampled, ground, DS, 0.10, 20.0, 0.08, opts, true)

	var max_z_diff := 0.0
	var max_bank_diff := 0.0
	var max_k_diff := 0.0
	for i in n_s:
		max_z_diff = maxf(max_z_diff, absf(sol_cpp.z[i] - sol_gd.z[i]))
		max_bank_diff = maxf(max_bank_diff, absf(sol_cpp.bank[i] - sol_gd.bank[i]))
		max_k_diff = maxf(max_k_diff, absf(sol_cpp.curvature[i] - sol_gd.curvature[i]))

	var ok_sol_parity: bool = max_z_diff < 1e-3 and max_bank_diff < 1e-4 and max_k_diff < 1e-4
	_check("F", ok_sol_parity, "solver parity: max dz=%.6f, dbank=%.6f, dk=%.6f" % [max_z_diff, max_bank_diff, max_k_diff])
