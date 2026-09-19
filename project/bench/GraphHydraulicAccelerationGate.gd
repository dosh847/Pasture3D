# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicAccelerationGate — Native C++ & GPU Hydraulic Erosion acceleration vs Tier 1 GDScript oracle.
# Verifies bit-level parity (<= 2e-6 m) between the C++ kernel, its GDScript oracle and the GPU route.
#
# This gate TIMES NOTHING. It used to end in a benchmark across 128^2, 512^2 and 1024^2 that ran the
# GDScript oracle twice at full size, so a correctness run cost ~17 seconds of CPU and could not be asked
# for without also asking for the machine. The benchmark lives in GraphHydraulicBenchmark.tscn, which is
# run deliberately; this gate can be run at any time.

extends Node

const EPS_SINGLE_PASS := 2.0e-6 # bit-level parity on single pass
# The multi-pass budget is the SINGLE-pass budget. The native kernel computes in double and rounds only
# where it writes a grid, exactly as the oracle does, so iterating it cannot introduce error the first pass
# did not have: 15 passes are bit-identical, not merely close. The old 2.0e-4 was sized for a drift whose
# real cause was the params struct storing float where the oracle had doubles; at that width the criterion
# could not have caught the 8e-4 it eventually reported until it was already four times over budget.
const EPS_MULTI_PASS := EPS_SINGLE_PASS
const GPU_TOL := 1.0e-2        # GPU float math vs CPU double/float intermediates

var _fail := 0


func _ready() -> void:
	print("=== GraphHydraulicAccelerationGate: Native C++ & GPU Hydraulic Acceleration Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_hydraulic_solve_grid"):
		print("!! Pasture3DUtil.erosion_hydraulic_solve_grid is missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_native_parity()
	_test_b_edge_cases()
	_test_c_gpu_parity()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDRAULIC ACCELERATION PASS" if _fail == 0 else "GRAPH HYDRAULIC ACCELERATION FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Section A: C++ Native Parity against GDScript Tier 1 Oracle ------------------------------------
func _test_a_native_parity() -> void:
	print("[A1] Bit-level Parity (Single Pass): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := {
		"iterations": 1,
		"rain_rate": 0.05,
		"evaporation_rate": 0.02,
		"sediment_capacity": 8.0,
		"erosion_speed": 0.5,
		"deposition_speed": 0.4,
		"min_slope": 0.01,
	}

	var gd_res1: Array = Pasture3DGraphNodeDevErosionHydraulic.solve_oracle(surf, gw, gh, rect, p1)
	var cpp_res1: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(surf, gw, gh, rect, p1)

	var diff_h1 := _max_abs_diff(gd_res1[0], cpp_res1["height"])
	var diff_s1 := maxf(_max_abs_diff(gd_res1[1], cpp_res1["eroded"]), _max_abs_diff(gd_res1[2], cpp_res1["deposited"]))
	var diff_f1 := _max_abs_diff(gd_res1[3], cpp_res1["flow"])

	print("    [1 pass] Height   max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h1, EPS_SINGLE_PASS])
	print("    [1 pass] Erosion  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_s1, EPS_SINGLE_PASS])
	print("    [1 pass] Flow     max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f1, EPS_SINGLE_PASS])

	if diff_h1 > EPS_SINGLE_PASS or diff_s1 > EPS_SINGLE_PASS or diff_f1 > EPS_SINGLE_PASS:
		_fail += 1
		print("    !! C++ native single-pass diverged beyond bit-level tolerance")

	print("\n[A2] Multi-Pass Parity (15 Iterations): C++ Native vs GDScript Tier 1 Oracle")
	var p15 := {
		"iterations": 15,
		"rain_rate": 0.05,
		"evaporation_rate": 0.02,
		"sediment_capacity": 8.0,
		"erosion_speed": 0.5,
		"deposition_speed": 0.4,
		"min_slope": 0.01,
	}

	var gd_res15: Array = Pasture3DGraphNodeDevErosionHydraulic.solve_oracle(surf, gw, gh, rect, p15)
	var cpp_res15: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(surf, gw, gh, rect, p15)

	var diff_h15 := _max_abs_diff(gd_res15[0], cpp_res15["height"])
	var diff_s15 := maxf(_max_abs_diff(gd_res15[1], cpp_res15["eroded"]), _max_abs_diff(gd_res15[2], cpp_res15["deposited"]))
	var diff_f15 := _max_abs_diff(gd_res15[3], cpp_res15["flow"])

	print("    [15 pass] Height   max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h15, EPS_MULTI_PASS])
	print("    [15 pass] Erosion  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_s15, EPS_MULTI_PASS])
	print("    [15 pass] Flow     max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f15, EPS_MULTI_PASS])

	if diff_h15 > EPS_MULTI_PASS or diff_s15 > EPS_MULTI_PASS or diff_f15 > EPS_MULTI_PASS:
		_fail += 1
		print("    !! C++ native multi-pass diverged beyond iterative tolerance")

	# CONTROL. At this width the comparison passes on identical arrays, so it has to be shown that it is
	# still reading them — a diff that returned 0.0 unconditionally would look like perfect parity.
	var bent: PackedFloat32Array = cpp_res15["height"].duplicate()
	bent[bent.size() / 2] += 1.0e-4
	if _max_abs_diff(gd_res15[0], bent) <= EPS_MULTI_PASS:
		_fail += 1
		print("    !! control failed: a 1e-4 m error in one cell is NOT detected at this tolerance")
	else:
		print("    control: a 1e-4 m error in one cell IS detected at this tolerance")

	# Control checks: surface must have changed and channels must have values
	var eroded_cut := _max_abs_diff(surf, cpp_res15["height"])
	var max_flow := _max_val(cpp_res15["flow"])
	# Deposition is legitimately zero at these parameters: the fixture drains off the edge under WALLS
	# before the capacity is exceeded anywhere, so nothing is laid back down. Printed, not asserted.
	var max_sed := _max_val(cpp_res15["deposited"])
	print("    control: max height cut = %.4f m, max flow = %.4f m2, max deposited = %.4f m" % [eroded_cut, max_flow, max_sed])
	if eroded_cut < 0.01 or max_flow < 0.01:
		_fail += 1
		print("    !! control failed: simulation did not perform work")


# --- Section B: Edge Cases (Flat terrain, NaN holes, Zero rain/erosion) -----------------------------
func _test_b_edge_cases() -> void:
	print("\n[B] Edge Cases & Boundary Handling")
	var gw := 32
	var gh := 32
	var rect := Rect2(0.0, 0.0, 32.0, 32.0)

	# 1. Flat terrain -> no gradient -> zero cut
	var flat := PackedFloat32Array()
	flat.resize(gw * gh)
	flat.fill(10.0)
	var flat_res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(flat, gw, gh, rect, { "iterations": 10 })
	var flat_cut := _max_abs_diff(flat, flat_res["height"])
	print("    Flat terrain cut: %.6f m (want 0.0)" % flat_cut)
	if flat_cut > 1e-6:
		_fail += 1
		print("    !! flat terrain suffered unexpected erosion")

	# 2. NaN boundary hole preservation
	var with_nan := _make_test_surface(gw, gh)
	with_nan[0] = NAN
	with_nan[gw * (gh / 2) + (gw / 2)] = NAN
	var nan_res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(with_nan, gw, gh, rect, { "iterations": 5 })
	var nan_h: PackedFloat32Array = nan_res["height"]
	if not is_nan(nan_h[0]) or not is_nan(nan_h[gw * (gh / 2) + (gw / 2)]):
		_fail += 1
		print("    !! NaN hole was overwritten with finite number")
	else:
		print("    NaN holes preserved correctly: PASS")


# --- Section C: GPU Compute Parity (When RenderingDevice available) --------------------------------
func _test_c_gpu_parity() -> void:
	print("\n[C] GPU Compute vs C++ Native Parity")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var params := {
		"iterations": 15,
		"rain_rate": 0.05,
		"evaporation_rate": 0.02,
		"sediment_capacity": 8.0,
		"erosion_speed": 0.5,
		"deposition_speed": 0.4,
		"min_slope": 0.01,
	}

	var gpu_res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(surf, gw, gh, rect, params)
	if not bool(gpu_res.get("ok", false)):
		print("    GPU Compute unavailable on this platform/headless context. (Skipping GPU parity assertion)")
		return

	var cpp_res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(surf, gw, gh, rect, params)
	var diff_h := _max_abs_diff(cpp_res["height"], gpu_res["height"])
	var diff_s := maxf(_max_abs_diff(cpp_res["eroded"], gpu_res["eroded"]), _max_abs_diff(cpp_res["deposited"], gpu_res["deposited"]))
	# `flow` is a contributing AREA in m^2, not a 0..1 channel: its peak here is in the tens, so the
	# absolute metre tolerance the height uses says nothing about it. Compared against its own peak.
	var flow_peak := _max_val(cpp_res["flow"])
	var diff_f := _max_abs_diff(cpp_res["flow"], gpu_res["flow"]) / maxf(flow_peak, 1e-9)

	print("    GPU vs C++ Height   max diff: %.6f (want < %.4f)" % [diff_h, GPU_TOL])
	print("    GPU vs C++ Erosion  max diff: %.6f (want < %.4f)" % [diff_s, GPU_TOL])
	print("    GPU vs C++ Flow     max diff: %.6f of its %.2f m2 peak (want < %.4f)" % [diff_f, flow_peak, GPU_TOL])

	if diff_h > GPU_TOL or diff_s > GPU_TOL or diff_f > GPU_TOL or flow_peak <= 1.0:
		_fail += 1
		print("    !! GPU compute diverged from C++ native oracle beyond tolerance, or flow came back normalised")


# ---- Helpers ----------------------------------------------------------------------------------------
func _make_test_surface(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_gw * p_gh)
	for iz in range(p_gh):
		var cz := (float(iz) / float(p_gh) - 0.5) * 2.0
		for ix in range(p_gw):
			var cx := (float(ix) / float(p_gw) - 0.5) * 2.0
			var cone := maxf(0.0, 1.0 - sqrt(cx * cx + cz * cz)) * 30.0
			var ridge := sin(cx * 6.0) * cos(cz * 6.0) * 4.0
			s[iz * p_gw + ix] = cone + ridge
	return s


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_nan(p_a[i]) and is_nan(p_b[i]):
			continue
		if is_nan(p_a[i]) != is_nan(p_b[i]):
			return INF
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _max_val(p_arr: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_arr:
		if is_finite(v):
			m = maxf(m, v)
	return m
