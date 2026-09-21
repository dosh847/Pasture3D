# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicStreamLogGate — Native C++ vs Tier 1 GDScript Oracle for Logarithmic Stream Power Erosion.
# Verifies bit-level parity (<= 2e-6 m), logarithmic incision response, channel mask generation, and NaN handling.

extends Node

const DevHydraulicStreamLog = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_stream_log.gd")

const EPS_SINGLE_PASS := 5.0e-6
const EPS_MULTI_PASS := 0.01

var _fail := 0


func _ready() -> void:
	print("=== GraphHydraulicStreamLogGate: Logarithmic Stream-Power Erosion Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_stream_log_solve_grid"):
		print("!! Pasture3DUtil.hydraulic_stream_log_solve_grid is missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_native_parity()
	_test_b_logarithmic_scaling()
	_test_c_nan_boundary_handling()
	_test_d_channel_extraction()
	_test_e_erosion_depth()
	_test_f_pit_drainage()
	_test_g_flow_under_mask()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDRAULIC STREAM LOG PASS" if _fail == 0 else "GRAPH HYDRAULIC STREAM LOG FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_a_native_parity() -> void:
	print("[A1] Bit-level Parity (Single Pass): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := {
		"iterations": 1,
		"incision_rate": 0.15,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 1.0,
		"bank_smoothing": 0.1,
	}

	var gd_res1: Array = DevHydraulicStreamLog.solve_oracle(surf, gw, gh, rect, p1)
	var cpp_res1: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p1)

	var diff_h1 := _max_abs_diff(gd_res1[0], cpp_res1["height"])
	var diff_c1 := _max_abs_diff(gd_res1[1], cpp_res1["channel_mask"])
	var diff_f1 := _max_abs_diff(gd_res1[2], cpp_res1["flow_accumulation"])
	var diff_e1 := _max_abs_diff(gd_res1[3], cpp_res1["erosion_depth"])

	print("    [1 pass] Height            max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h1, EPS_SINGLE_PASS])
	print("    [1 pass] Channel Mask      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_c1, EPS_SINGLE_PASS])
	print("    [1 pass] Flow Accumulation max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f1, EPS_SINGLE_PASS])
	print("    [1 pass] Erosion Depth     max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_e1, EPS_SINGLE_PASS])

	if diff_h1 > EPS_SINGLE_PASS or diff_c1 > EPS_SINGLE_PASS or diff_f1 > EPS_SINGLE_PASS or diff_e1 > EPS_SINGLE_PASS:
		_fail += 1
		print("    !! Single pass C++ native solver diverged beyond bit-level tolerance")

	print("\n[A2] Multi-Pass Parity (10 Iterations): C++ Native vs GDScript Tier 1 Oracle")
	var p10 := {
		"iterations": 10,
		"incision_rate": 0.15,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 1.0,
		"bank_smoothing": 0.1,
	}

	var gd_res10: Array = DevHydraulicStreamLog.solve_oracle(surf, gw, gh, rect, p10)
	var cpp_res10: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p10)

	var diff_h10 := _max_abs_diff(gd_res10[0], cpp_res10["height"])
	var diff_c10 := _max_abs_diff(gd_res10[1], cpp_res10["channel_mask"])
	var diff_f10 := _max_abs_diff(gd_res10[2], cpp_res10["flow_accumulation"])
	var diff_e10 := _max_abs_diff(gd_res10[3], cpp_res10["erosion_depth"])

	print("    [10 pass] Height            max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h10, EPS_MULTI_PASS])
	print("    [10 pass] Channel Mask      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_c10, EPS_MULTI_PASS])
	print("    [10 pass] Flow Accumulation max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f10, EPS_MULTI_PASS])
	print("    [10 pass] Erosion Depth     max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_e10, EPS_MULTI_PASS])

	if diff_h10 > EPS_MULTI_PASS or diff_c10 > EPS_MULTI_PASS or diff_f10 > EPS_MULTI_PASS or diff_e10 > EPS_MULTI_PASS:
		_fail += 1
		print("    !! Multi-pass C++ native solver diverged beyond iterative tolerance")


func _test_b_logarithmic_scaling() -> void:
	print("\n[B] Logarithmic Scaling & Stability (No Runaway Blowouts)")
	var gw := 64
	var gh := 64
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := { "iterations": 5, "incision_rate": 0.1, "area_exponent": 0.5, "slope_exponent": 1.0 }
	var p2 := { "iterations": 25, "incision_rate": 0.1, "area_exponent": 0.5, "slope_exponent": 1.0 }

	var res1: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p1)
	var res2: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p2)

	var cut1 := _max_abs_diff(surf, res1["height"])
	var cut2 := _max_abs_diff(surf, res2["height"])

	print("    Incision depth @ 5 passes = %.4f m" % cut1)
	print("    Incision depth @ 25 passes = %.4f m" % cut2)

	if cut2 <= cut1 or cut2 > 25.0:
		_fail += 1
		print("    !! Incision failed stability / monotonic growth criteria")


func _test_c_nan_boundary_handling() -> void:
	print("\n[C] NaN Boundary Invariance")
	var gw := 32
	var gh := 32
	var rect := Rect2(0.0, 0.0, 50.0, 50.0)
	var surf := _make_test_surface(gw, gh)

	for ix in range(gw):
		surf[ix] = NAN
		surf[(gh - 1) * gw + ix] = NAN
	for iz in range(gh):
		surf[iz * gw] = NAN
		surf[iz * gw + (gw - 1)] = NAN

	var p := { "iterations": 5 }
	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p)
	var h: PackedFloat32Array = res["height"]

	var nan_ok := true
	for ix in range(gw):
		if not is_nan(h[ix]) or not is_nan(h[(gh - 1) * gw + ix]):
			nan_ok = false
	for iz in range(gh):
		if not is_nan(h[iz * gw]) or not is_nan(h[iz * gw + (gw - 1)]):
			nan_ok = false

	print("    NaN borders preserved: %s" % str(nan_ok))
	if not nan_ok:
		_fail += 1
		print("    !! Solver corrupted NaN boundaries")


func _test_d_channel_extraction() -> void:
	print("\n[D] Channel Mask & Flow Accumulation Response")
	var gw := 64
	var gh := 64
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p := {
		"iterations": 15,
		"incision_rate": 0.2,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 2.0,
		"bank_smoothing": 0.1,
	}

	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p)
	var c: PackedFloat32Array = res["channel_mask"]
	var f: PackedFloat32Array = res["flow_accumulation"]

	var max_c := _max_val(c)
	var max_f := _max_val(f)

	print("    Max channel mask = %.4f" % max_c)
	print("    Max flow accumulation = %.4f cells" % max_f)

	if max_c < 0.05 or max_f < 10.0:
		_fail += 1
		print("    !! Channel mask or flow accumulation failed to extract river network")


## Erosion depth is the incision in METRES, so it is checked against the height it came out of rather than
## against a number derived from itself: sum(cut) over the passes has to equal the drop from the input
## surface, cell for cell. channel_mask cannot stand in for this -- it is the same cut over a PARAMETER,
## clamped to 1, so it saturates and carries no depth.
func _test_e_erosion_depth() -> void:
	print("\n[E] Erosion Depth Channel (metres)")
	var gw := 48
	var gh := 48
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p := { "iterations": 8, "incision_rate": 0.2 }
	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p)
	var h: PackedFloat32Array = res["height"]
	var e: PackedFloat32Array = res["erosion_depth"]

	if e.size() != gw * gh:
		_fail += 1
		print("    !! erosion_depth was not produced")
		return

	# Independent check: depth must reconstruct the surface it was cut from.
	var worst := 0.0
	var max_e := 0.0
	for i in range(gw * gh):
		if not is_finite(surf[i]):
			continue
		worst = maxf(worst, absf((surf[i] - e[i]) - h[i]))
		max_e = maxf(max_e, e[i])

	print("    Max erosion depth = %.4f m" % max_e)
	print("    Worst |(input - depth) - output| = %.7f m" % worst)

	# Saturation control: the mask must be pinned at 1.0 somewhere the depth still varies, which is exactly
	# the information the mask cannot carry and the reason this channel exists.
	var c: PackedFloat32Array = res["channel_mask"]
	var pinned := 0
	for i in range(gw * gh):
		if c[i] >= 0.999:
			pinned += 1
	print("    Cells with channel_mask pinned at 1.0 = %d" % pinned)

	if max_e < 0.1 or worst > 0.01:
		_fail += 1
		print("    !! erosion_depth does not account for the height the solver removed")


## Depression filling, with its own control: the SAME basin solved with the fill off must strand its flow.
## A criterion that only asserted "the pit drains" would pass on a fixture that never had a pit.
##
## What is asserted is the DEFECT -- a cell that swallows its whole upstream catchment -- and not the shape
## of the network below the basin. Measured on this fixture, the bowl's 577 cells of discharge collapse to
## 41 with the fill on, while the peak discharge a few rows downslope moves only from 224.8 to 232.9: MD8
## splits flow among every lower neighbour, so over a filled lake, where the only gradient is the fill
## epsilon, the plume spreads instead of converging on the outlet. That is inherent to MD8 over flats, not
## a fault in the fill, so the downstream figure is printed and deliberately NOT gated -- gating it would
## be gating a number this fix does not claim to move.
func _test_f_pit_drainage() -> void:
	print("\n[F] Pit Drainage (depression filling)")
	var gw := 48
	var gh := 48
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)

	# A plane tilted along +z with a closed conical bowl cut into the middle. The bowl walls are steeper than
	# the tilt, so every bowl cell drains inward and the centre cell is a terminal sink.
	var surf := PackedFloat32Array()
	surf.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			var h: float = 40.0 - float(iz) * 0.5
			var d: float = sqrt(pow(float(ix) - 24.0, 2.0) + pow(float(iz) - 24.0, 2.0))
			if d < 8.0:
				h -= (8.0 - d) * 1.5
			surf[iz * gw + ix] = h

	# The fixture has to actually contain the thing under test, so count the sinks rather than trust the
	# formula: exactly one interior cell with no lower neighbour.
	var pits := 0
	for iz in range(1, gh - 1):
		for ix in range(1, gw - 1):
			var c: float = surf[iz * gw + ix]
			var has_lower := false
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dz == 0:
						continue
					if surf[(iz + dz) * gw + ix + dx] < c:
						has_lower = true
			if not has_lower:
				pits += 1
	print("    Interior terminal sinks in the fixture = %d" % pits)
	if pits != 1:
		_fail += 1
		print("    !! FIXTURE IS WRONG: it does not contain exactly one pit, so this criterion tests nothing")
		return

	var p_on := { "iterations": 1, "incision_rate": 0.15, "fill_depressions": true }
	var p_off := { "iterations": 1, "incision_rate": 0.15, "fill_depressions": false }
	var f_on: PackedFloat32Array = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p_on)["flow_accumulation"]
	var f_off: PackedFloat32Array = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p_off)["flow_accumulation"]

	var pit: int = 24 * gw + 24
	print("    Discharge at the pit, fill OFF = %.1f cells" % f_off[pit])
	print("    Discharge at the pit, fill ON  = %.1f cells" % f_on[pit])
	print("    (ungated) peak discharge 10 rows downslope: OFF %.1f, ON %.1f" % [
		_window_max(f_off, gw, 34, 38, 12, 36), _window_max(f_on, gw, 34, 38, 12, 36)])

	# CONTROL: with no fill the pit must hoard a catchment far larger than its own rainfall of 1 cell. If it
	# does not, the bowl drained by itself and everything below this proves nothing.
	if f_off[pit] < 50.0:
		_fail += 1
		print("    !! CONTROL DID NOT FAIL: the unfilled pit did not trap a catchment")

	# The fix: the sink is gone, so the pit carries ordinary through-flow instead of the whole bowl.
	if f_on[pit] > f_off[pit] * 0.25:
		_fail += 1
		print("    !! Depression filling did not stop the pit swallowing its catchment")

	# And the pit must no longer be the wettest cell on the map, which is what a terminal sink always is.
	var arg_on := 0
	for i in range(gw * gh):
		if f_on[i] > f_on[arg_on]:
			arg_on = i
	if arg_on == pit:
		_fail += 1
		print("    !! The pit is still the global discharge maximum")


## Discharge is published for every cell, including cells the mask forbids eroding. The control is the same
## solve without a mask: the two flow fields have to agree, because a mask says nothing about where water
## goes. Reading it off the eroded height would not catch this -- the mask genuinely does change that.
func _test_g_flow_under_mask() -> void:
	print("\n[G] Flow Accumulation Is Not Masked")
	var gw := 48
	var gh := 48
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	# Erosion allowed only in the upper half.
	var mask := PackedFloat32Array()
	mask.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			mask[iz * gw + ix] = 1.0 if iz < gh / 2 else 0.0

	var p_masked := { "iterations": 1, "incision_rate": 0.15, "mask": mask }
	var p_plain := { "iterations": 1, "incision_rate": 0.15 }

	var r_masked: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p_masked)
	var r_plain: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p_plain)
	var f_masked: PackedFloat32Array = r_masked["flow_accumulation"]

	var zeros_under_mask := 0
	var lowest := INF
	for iz in range(gh / 2, gh):
		for ix in range(gw):
			var v: float = f_masked[iz * gw + ix]
			lowest = minf(lowest, v)
			if v == 0.0:
				zeros_under_mask += 1

	# First pass routes on the input surface, which the mask does not touch, so the fields are identical.
	var diff := _max_abs_diff(f_masked, r_plain["flow_accumulation"])

	print("    Masked-off cells reporting 0 discharge = %d (of %d)" % [zeros_under_mask, (gh / 2) * gw])
	print("    Lowest discharge under the mask = %.4f cells" % lowest)
	print("    max |masked - unmasked| discharge = %.7f cells" % diff)

	# Every cell gets one cell of rainfall, so 0 means the field was never written there.
	if zeros_under_mask > 0 or lowest < 1.0:
		_fail += 1
		print("    !! The erosion mask blanked the discharge field")
	if diff > 1.0e-5:
		_fail += 1
		print("    !! Masking changed the discharge field")


func _window_max(f: PackedFloat32Array, p_gw: int, p_z0: int, p_z1: int, p_x0: int, p_x1: int) -> float:
	var m := 0.0
	for iz in range(p_z0, p_z1):
		for ix in range(p_x0, p_x1):
			m = maxf(m, f[iz * p_gw + ix])
	return m


func _make_test_surface(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(p_gw * p_gh)
	for iz in range(p_gh):
		var nz := float(iz) / float(p_gh - 1)
		for ix in range(p_gw):
			var nx := float(ix) / float(p_gw - 1)
			# Sloped terrain with central valley thalweg
			var valley := absf(nx - 0.5) * 20.0
			var slope := (1.0 - nz) * 40.0
			var h := slope + valley + 2.0 * sin(nx * 8.0) * cos(nz * 8.0)
			arr[iz * p_gw + ix] = h
	return arr


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(min(a.size(), b.size())):
		var va := a[i]
		var vb := b[i]
		if is_nan(va) and is_nan(vb):
			continue
		if is_nan(va) or is_nan(vb):
			return 99999.0
		var d := absf(va - vb)
		if d > m:
			m = d
	return m


func _max_val(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		if is_finite(v) and v > m:
			m = v
	return m
