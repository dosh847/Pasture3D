# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicBenchmark — how long the grid hydraulic solver takes on each of its three routes.
#
# This is a BENCHMARK, not a gate: it asserts nothing and it always "passes". It is split out of
# GraphHydraulicAccelerationGate so that checking the solver's correctness does not cost the machine
# several seconds of full-size GDScript oracle. Run it when you want the numbers.

extends Node


func _ready() -> void:
	print("=== GraphHydraulicBenchmark: grid hydraulic solver throughput ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_hydraulic_solve_grid"):
		print("!! Pasture3DUtil.erosion_hydraulic_solve_grid is missing — extension binary needs rebuild.")
		get_tree().quit(1)
		return
	_run_benchmarks()
	print("
=== GraphHydraulicBenchmark done ===
")
	get_tree().quit(0)


# --- Section D: Performance Benchmarking -----------------------------------------------------------
func _run_benchmarks() -> void:
	print("\n[D] Performance Benchmarks across Grid Scales (25 Iterations)")
	print("%-12s | %-12s | %-12s | %-12s | %-12s" % ["Grid Size", "GDScript", "C++ Native", "GPU Compute", "C++ Speedup"])
	print("-----------------------------------------------------------------------------")

	var grid_sizes := [128, 512, 1024]
	var params := {
		"iterations": 25,
		"rain_rate": 0.05,
		"evaporation_rate": 0.02,
		"sediment_capacity": 8.0,
		"erosion_speed": 0.5,
		"deposition_speed": 0.4,
		"min_slope": 0.01,
	}

	for size: int in grid_sizes:
		var gw: int = size
		var gh: int = size
		var rect := Rect2(-100.0, -100.0, 200.0, 200.0)
		var surf := _make_test_surface(gw, gh)

		# GDScript timing (skip 1024 for headless gate responsiveness unless requested)
		var gd_ms := 0.0
		if size <= 512:
			var t0 := Time.get_ticks_usec()
			Pasture3DGraphNodeDevErosionHydraulic.solve_oracle(surf, gw, gh, rect, params)
			gd_ms = (Time.get_ticks_usec() - t0) / 1000.0
		else:
			# Extrapolated estimate based on O(N) scaling
			gd_ms = -1.0

		# C++ Native timing
		var t1 := Time.get_ticks_usec()
		Pasture3DUtil.erosion_hydraulic_solve_grid(surf, gw, gh, rect, params)
		var cpp_ms := (Time.get_ticks_usec() - t1) / 1000.0

		# GPU Compute timing
		var t2 := Time.get_ticks_usec()
		var gpu_res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(surf, gw, gh, rect, params)
		var gpu_ms := (Time.get_ticks_usec() - t2) / 1000.0
		var gpu_str := "%.2f ms" % gpu_ms if bool(gpu_res.get("ok", false)) else "N/A (headless)"

		var speedup_str := "%.1fx" % (gd_ms / cpp_ms) if gd_ms > 0.0 else "n/a"
		var gd_str := "%.2f ms" % gd_ms if gd_ms > 0.0 else "not run"

		print("%-12s | %-12s | %-12.2f ms | %-12s | %-12s" % [
			"%dx%d" % [size, size],
			gd_str,
			cpp_ms,
			gpu_str,
			speedup_str
		])


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
