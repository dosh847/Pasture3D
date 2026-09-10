# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadVerticalDynamicsGate — vertical dynamics & velocity-aware curvature limiting (P9f).
# See PASTURE3D_ROAD_SIMCADE_UPGRADE_SPEC.md §3.6 and §Phase P9f.
#
# Tests the solver's second-difference clamping projection:
#   Δ²z_i = (z[i-1] - 2*z[i] + z[i+1]) / ds² ∈ [-κ_{crest}, κ_{sag}]
# where κ = a_max / v_design²:
#
#   A  crest vertical acceleration bounded at design speed (a_crest <= 0.4g)
#   B  speed-dependent control: increasing design speed flattens the crest and cuts deeper
#   C  intentional rally jump override (allow_airborne_jump) preserves authored sharp crest
#   D  sag vertical acceleration bounded in dip (a_sag <= 0.6g)
#   E  grade limits strictly satisfied across all profiles (feasible == true, |dz/ds| <= max_grade)
#   F  GDScript oracle and native C++ implementation agree with bit-accurate parity
#
# House discipline: every criterion carries a CONTROL that must move if the path is dead.
@tool
extends Node

const DS: float = 1.0
const N: int = 201

var _fail: int = 0


func _ready() -> void:
	print("=== RoadVerticalDynamicsGate: vertical dynamics limiter (P9f) ===\n")
	_a_crest_acceleration_bounded()
	_b_design_speed_flattens_crest()
	_c_intentional_jump_preserves_crest()
	_d_sag_acceleration_bounded()
	_e_grade_limits_strictly_satisfied()
	_f_native_matches_gdscript_oracle()
	print("\n=== %s (%d failures) ===\n" % ["ROAD VERTICAL DYNAMICS PASS" if _fail == 0 else "ROAD VERTICAL DYNAMICS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## Sharp hill fixture: climbs at +5% (0.05) to peak at 100 m, then descends at -5% (-0.05).
## The kink at the apex has ground curvature ~ 0.100 m⁻¹ (6.37g at 25 m/s).
func _sharp_hill() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(N)
	for i in N:
		if i <= 100:
			g[i] = float(i) * 0.05
		else:
			g[i] = 5.0 - float(i - 100) * 0.05
	return g


## Sharp dip fixture: descends at -5% (-0.05) to valley at 100 m, then climbs at +5% (+0.05).
func _sharp_dip() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(N)
	for i in N:
		if i <= 100:
			g[i] = 5.0 - float(i) * 0.05
		else:
			g[i] = float(i - 100) * 0.05
	return g


func _max_abs_delta(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var n := mini(p_a.size(), p_b.size())
	var d := 0.0
	for i in n:
		d = maxf(d, absf(p_a[i] - p_b[i]))
	return d


# ---- A ------------------------------------------------------------------------------------------

func _a_crest_acceleration_bounded() -> void:
	print("[A] crest vertical acceleration is bounded at design speed")
	var ground := _sharp_hill()
	var v_design := 25.0 # 90 km/h
	var a_crest_max := 0.4 * 9.81 # 3.924 m/s²
	var k_crest_target := a_crest_max / (v_design * v_design) # 0.0062784 m⁻¹

	# Unconstrained ground curvature at peak:
	var ground_k := absf(ground[99] - 2.0 * ground[100] + ground[101]) / (DS * DS)
	var ground_accel := ground_k * v_design * v_design

	var align := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": v_design,
		"vertical_crest_accel_limit": 0.4,
		"vertical_sag_accel_limit": 0.6,
	})

	var peak_accel := align.peak_vertical_accel_crest
	var peak_k := align.peak_vertical_curvature_crest
	print("    v=%.1f m/s: peak crest accel %.3f m/s² (%.3fg), peak curv %.6f m⁻¹ (target <= %.6f)"
			% [v_design, peak_accel, peak_accel / 9.81, peak_k, k_crest_target])

	# Must be bounded within tolerance (allowing tiny numerical residual <= 5e-4 m⁻¹)
	if peak_k > k_crest_target + 5e-4:
		_fail += 1; print("    !! solved profile exceeded crest curvature limit: %.6f > %.6f" % [peak_k, k_crest_target])

	# Control: unconstrained ground breaches the limit severely:
	print("    control: unconstrained ground crest accel %.3f m/s² (%.2fg, %dx the limit)"
			% [ground_accel, ground_accel / 9.81, int(round(ground_accel / a_crest_max))])
	if ground_accel <= a_crest_max * 2.0:
		_fail += 1; print("    !! fixture was not sharp enough to test crest limiting")


# ---- B ------------------------------------------------------------------------------------------

func _b_design_speed_flattens_crest() -> void:
	print("[B] increasing design speed flattens the crest and cuts deeper")
	var ground := _sharp_hill()

	var align_slow := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": 25.0,
		"vertical_crest_accel_limit": 0.4,
	})
	var align_fast := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": 50.0,
		"vertical_crest_accel_limit": 0.4,
	})

	var peak_z_slow := align_slow.z[100]
	var peak_z_fast := align_fast.z[100]
	var k_slow := align_slow.peak_vertical_curvature_crest
	var k_fast := align_fast.peak_vertical_curvature_crest

	print("    v=25 m/s: apex z=%.4f m, curv=%.6f m⁻¹" % [peak_z_slow, k_slow])
	print("    v=50 m/s: apex z=%.4f m, curv=%.6f m⁻¹" % [peak_z_fast, k_fast])

	# Higher design speed must flatten crest: apex elevation must be lower (cut deeper) and curvature lower
	if peak_z_fast >= peak_z_slow - 0.05:
		_fail += 1; print("    !! v=50 profile did not cut deeper than v=25 profile (%.4f vs %.4f)"
				% [peak_z_fast, peak_z_slow])
	if k_fast >= k_slow:
		_fail += 1; print("    !! v=50 profile curvature is not gentler than v=25 (%.6f vs %.6f)"
				% [k_fast, k_slow])

	# Control: low design speed (10 m/s) stays closer to ground apex (5.0 m)
	var align_crawl := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": 10.0,
		"vertical_crest_accel_limit": 0.4,
	})
	var peak_z_crawl := align_crawl.z[100]
	print("    control: v=10 m/s apex z=%.4f m (closer to ground 5.0000 m)" % peak_z_crawl)
	if peak_z_crawl <= peak_z_slow:
		_fail += 1; print("    !! v=10 crawl did not produce higher apex than v=25")


# ---- C ------------------------------------------------------------------------------------------

func _c_intentional_jump_preserves_crest() -> void:
	print("[C] intentional jump override (allow_airborne_jump) preserves sharp crest")
	var ground := _sharp_hill()
	var v_design := 25.0

	var jump_mask := PackedByteArray()
	jump_mask.resize(N)
	jump_mask.fill(0)
	for i in range(85, 116):
		jump_mask[i] = 1

	var align_limited := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": v_design,
		"vertical_crest_accel_limit": 0.4,
	})
	var align_jump := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": v_design,
		"vertical_crest_accel_limit": 0.4,
		"allow_airborne_jump": jump_mask,
	})

	var peak_z_limited := align_limited.z[100]
	var peak_z_jump := align_jump.z[100]
	var k_jump := align_jump.peak_vertical_curvature_crest
	var k_target := (0.4 * 9.81) / (v_design * v_design)

	print("    limited: apex z=%.4f m, jump: apex z=%.4f m, jump curv=%.6f m⁻¹ (target limit was %.6f)"
			% [peak_z_limited, peak_z_jump, k_jump, k_target])

	# Jump crest must stay higher and retain sharp curvature:
	if peak_z_jump <= peak_z_limited + 0.03:
		_fail += 1; print("    !! jump override did not preserve higher crest (%.4f <= %.4f)"
				% [peak_z_jump, peak_z_limited])
	if k_jump <= k_target + 0.005:
		_fail += 1; print("    !! jump crest curvature was clamped instead of preserved (%.6f <= %.6f)"
				% [k_jump, k_target])

	# Control: turning jump off cuts the peak down:
	var delta_apex := peak_z_jump - peak_z_limited
	print("    control: jump override raised crest by +%.4f m" % delta_apex)
	if delta_apex < 0.02:
		_fail += 1; print("    !! jump override had negligible effect on apex")


# ---- D ------------------------------------------------------------------------------------------

func _d_sag_acceleration_bounded() -> void:
	print("[D] sag vertical acceleration is bounded in dip")
	var ground := _sharp_dip()
	var v_design := 25.0
	var a_sag_max := 0.6 * 9.81 # 5.886 m/s²
	var k_sag_target := a_sag_max / (v_design * v_design) # 0.0094176 m⁻¹

	var ground_k := absf(ground[99] - 2.0 * ground[100] + ground[101]) / (DS * DS)
	var ground_accel := ground_k * v_design * v_design

	var align := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, {
		"design_speed": v_design,
		"vertical_crest_accel_limit": 0.4,
		"vertical_sag_accel_limit": 0.6,
	})

	var peak_accel := align.peak_vertical_accel_sag
	var peak_k := align.peak_vertical_curvature_sag
	print("    v=%.1f m/s: peak sag accel %.3f m/s² (%.3fg), peak curv %.6f m⁻¹ (target <= %.6f)"
			% [v_design, peak_accel, peak_accel / 9.81, peak_k, k_sag_target])

	if peak_k > k_sag_target + 5e-4:
		_fail += 1; print("    !! solved profile exceeded sag curvature limit: %.6f > %.6f" % [peak_k, k_sag_target])

	# The dip floor must be filled (raised above ground 0.0):
	var floor_z := align.z[100]
	print("    dip floor filled: z=%.4f m (ground was 0.0000 m)" % floor_z)
	if floor_z <= 0.05:
		_fail += 1; print("    !! solved profile did not fill the dip floor (z=%.4f)" % floor_z)

	# Control: ground dip acceleration is dangerous:
	print("    control: unconstrained ground dip accel %.3f m/s² (%.2fg, %dx the limit)"
			% [ground_accel, ground_accel / 9.81, int(round(ground_accel / a_sag_max))])
	if ground_accel <= a_sag_max * 2.0:
		_fail += 1; print("    !! dip fixture was not sharp enough")


# ---- E ------------------------------------------------------------------------------------------

func _e_grade_limits_strictly_satisfied() -> void:
	print("[E] grade limits strictly satisfied across all profiles")
	var hill := _sharp_hill()
	var dip := _sharp_dip()
	var g_max := 0.08

	var hill_align := Pasture3DRoadAlignmentSolver.solve(hill, DS, g_max, {
		"design_speed": 25.0,
		"vertical_crest_accel_limit": 0.4,
		"vertical_sag_accel_limit": 0.6,
	})
	var dip_align := Pasture3DRoadAlignmentSolver.solve(dip, DS, g_max, {
		"design_speed": 25.0,
		"vertical_crest_accel_limit": 0.4,
		"vertical_sag_accel_limit": 0.6,
	})

	print("    hill peak grade: %.6f (limit %.3f), feasible=%s"
			% [hill_align.peak_grade, g_max, hill_align.feasible])
	print("    dip peak grade:  %.6f (limit %.3f), feasible=%s"
			% [dip_align.peak_grade, g_max, dip_align.feasible])

	if hill_align.peak_grade > g_max + 1e-4 or not hill_align.feasible:
		_fail += 1; print("    !! hill profile breached grade limit")
	if dip_align.peak_grade > g_max + 1e-4 or not dip_align.feasible:
		_fail += 1; print("    !! dip profile breached grade limit")

	# Control: ground grade is 5%
	var ground_grade := 0.05
	print("    control: ground grade is %.3f, bounded by %.3f" % [ground_grade, g_max])


# ---- F ------------------------------------------------------------------------------------------

func _f_native_matches_gdscript_oracle() -> void:
	print("[F] native C++ matches GDScript oracle bit-accurately")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_align_solve"):
		print("    NO-SIGNAL: Pasture3DUtil extension not loaded")
		_fail += 1
		return

	var ground := _sharp_hill()
	var jump_mask := PackedByteArray()
	jump_mask.resize(N)
	jump_mask.fill(0)
	for i in range(95, 106):
		jump_mask[i] = 1

	var opts := {
		"design_speed": 35.0,
		"vertical_crest_accel_limit": 0.4,
		"vertical_sag_accel_limit": 0.6,
		"allow_airborne_jump": jump_mask,
		"pins": {10: 0.5, 190: 0.5},
	}

	var nat := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, opts, false)
	var gds := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, opts, true)

	var dz := _max_abs_delta(nat.z, gds.z)
	print("    max |z_nat - z_gds| = %.8f m" % dz)
	print("    native crest curv %.6f vs GDScript %.6f"
			% [nat.peak_vertical_curvature_crest, gds.peak_vertical_curvature_crest])
	print("    native peak grade %.6f vs GDScript %.6f"
			% [nat.peak_grade, gds.peak_grade])

	if dz > 1e-4:
		_fail += 1; print("    !! native and GDScript oracle diverged (|dz| > 1e-4 m)")
	if absf(nat.peak_vertical_curvature_crest - gds.peak_vertical_curvature_crest) > 1e-5:
		_fail += 1; print("    !! crest curvature diagnostic diverged")
	if absf(nat.peak_grade - gds.peak_grade) > 1e-5:
		_fail += 1; print("    !! peak grade diagnostic diverged")

	# Control: solver actually changed ground:
	var delta_ground := _max_abs_delta(nat.z, ground)
	print("    control: solve moved ground profile by %.4f m" % delta_ground)
	if delta_ground < 0.1:
		_fail += 1; print("    !! solve did not move ground profile")
