# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicParticleGate — Native C++ vs Tier 1 GDScript Oracle for Particle Hydraulic Erosion.
# Verifies bit-level parity (<= 2e-6 m), seed determinism, channel isolation, and NaN boundary handling.

extends Node

const DevHydraulicParticle = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_particle.gd")

const EPS_SINGLE_DROPLET := 2.0e-6
const EPS_MULTI_DROPLET := 0.05

var _fail := 0
var _completed := 0


func _ready() -> void:
	print("=== GraphHydraulicParticleGate: Particle Hydraulic Erosion Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_particle_solve_grid"):
		print("!! Pasture3DUtil.hydraulic_particle_solve_grid is missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_native_parity()
	_test_a3_default_lifetime_parity()
	_test_a4_mask_spawn_parity()
	_test_r_route_parity()
	_test_s_seed_lowering()
	_test_a5_metric_and_radius_parity()
	_test_f_cells_fingerprint()
	_test_l_radius_smooths()
	_test_u_resolution_invariance()
	_test_n_metric_route()
	_test_b_seed_determinism()
	_test_c_nan_boundary_handling()
	_test_d_channel_generation()
	_test_e1_net_channels()
	_test_e2_mass_balance()
	_test_e3_flow_invariance()
	_test_e4_channel_route()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDRAULIC PARTICLE PASS" if _fail == 0 else "GRAPH HYDRAULIC PARTICLE FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_a_native_parity() -> void:
	print("[A1] Bit-level Parity (Single droplet / 10 droplets): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := {
		"droplet_count": 1,
		"max_lifetime": 1,
		"seed": 42,
	}
	var gd_res1: Array = DevHydraulicParticle.solve_oracle(surf, gw, gh, rect, p1)
	var cpp_res1: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p1)
	var diff_h1 := _max_abs_diff(gd_res1[0], cpp_res1["height"])
	print("    [1 droplet, 1 step]    Height max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h1, EPS_SINGLE_DROPLET])
	if diff_h1 > EPS_SINGLE_DROPLET:
		_fail += 1
		print("    !! Single droplet diverged beyond bit-level tolerance")

	var p10 := {
		"droplet_count": 10,
		"max_lifetime": 5,
		"seed": 42,
	}
	var gd_res10: Array = DevHydraulicParticle.solve_oracle(surf, gw, gh, rect, p10)
	var cpp_res10: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p10)
	var diff_h10 := _max_abs_diff(gd_res10[0], cpp_res10["height"])
	print("    [10 droplets, 5 steps] Height max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h10, EPS_SINGLE_DROPLET])
	if diff_h10 > EPS_SINGLE_DROPLET:
		_fail += 1
		print("    !! 10 droplets diverged beyond bit-level tolerance")

	print("\n[A2] Multi-droplet Iterative Parity (500 droplets, 10 steps): C++ Native vs GDScript Tier 1 Oracle")
	var p := {
		"droplet_count": 500,
		"max_lifetime": 10,
		"inertia": 0.05,
		"sediment_capacity": 4.0,
		"erosion_speed": 0.3,
		"deposition_speed": 0.3,
		"evaporation_rate": 0.01,
		"min_slope": 0.01,
		"gravity": 4.0,
		"seed": 42,
	}

	var gd_res: Array = DevHydraulicParticle.solve_oracle(surf, gw, gh, rect, p)
	var cpp_res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p)

	var diff_h := _max_abs_diff(gd_res[0], cpp_res["height"])
	var diff_s := _max_abs_diff(gd_res[1], cpp_res["eroded"])
	var diff_f := _max_abs_diff(gd_res[2], cpp_res["deposited"])
	var diff_w := _max_abs_diff(gd_res[3], cpp_res["flow"])

	print("    Height      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS_MULTI_DROPLET])
	print("    Eroded      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_s, EPS_MULTI_DROPLET])
	print("    Deposited   max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f, EPS_MULTI_DROPLET])
	print("    Flow        max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_w, EPS_MULTI_DROPLET])

	if diff_h > EPS_MULTI_DROPLET or diff_s > EPS_MULTI_DROPLET or diff_f > EPS_MULTI_DROPLET or diff_w > EPS_MULTI_DROPLET:
		_fail += 1
		print("    !! Multi-droplet solver diverged beyond iterative tolerance")


## [A2] stops at 10 steps and 500 droplets, which is short enough that the C++ float32 quad differences
## never amplified. At the default lifetime they did: 1.99 m max on this size of run. Every channel
## must now match the oracle to the bit-level tolerance.
func _test_a3_default_lifetime_parity() -> void:
	print("
[A3] Default-lifetime Parity (2000 droplets, 30 steps): every channel")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var p := {"droplet_count": 2000, "max_lifetime": 30, "seed": 7}
	var gd: Array = DevHydraulicParticle.solve_oracle(surf, gw, gw, rect, p)
	var cpp: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, p)
	var worst := 0.0
	var names := ["height", "eroded", "deposited", "flow"]
	for c in names.size():
		var d := _max_abs_diff(gd[c], cpp[names[c]])
		print("    %-11s max |cpp - gdscript| = %.9f" % [names[c], d])
		worst = maxf(worst, d)
	# Measured-something control: the run must actually have eroded.
	var cut := _max_abs_diff(surf, cpp["height"])
	print("    max |height - input| = %.4f m (want > 0.1, or the run measured nothing)" % cut)
	if worst > EPS_SINGLE_DROPLET or cut <= 0.1:
		_fail += 1
		print("    !! default-lifetime parity failed")
	_completed += 1


## A droplet born where the mask is off (or on no data) never runs, on both routes. The native solver used
## to run it anyway, so it walked out of the masked-off half and cut the unmasked half.
func _test_a4_mask_spawn_parity() -> void:
	print("
[A4] Mask-spawn Parity: half-zero mask, and a no-data band")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	for z in range(40, 44):
		for x in gw:
			surf[z * gw + x] = NAN
	var mask := PackedFloat32Array()
	mask.resize(gw * gw)
	for i in mask.size():
		mask[i] = 1.0 if (i % gw) >= gw / 2 else 0.0
	var p := {"droplet_count": 2000, "max_lifetime": 30, "seed": 7, "mask": mask}
	var gd: Array = DevHydraulicParticle.solve_oracle(surf, gw, gw, rect, p)
	var cpp: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, p)
	var d := _max_abs_diff(gd[0], cpp["height"])
	print("    height max |cpp - gdscript| = %.9f (want <= %.7f)" % [d, EPS_SINGLE_DROPLET])
	# Control: the mask must have changed the result, or this criterion never exercised the skip.
	p.erase("mask")
	var unmasked: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, p)
	var effect := _max_abs_diff(unmasked["height"], cpp["height"])
	print("    masked vs unmasked max |d| = %.4f m (want > 0.1)" % effect)
	if d > EPS_SINGLE_DROPLET or effect <= 0.1:
		_fail += 1
		print("    !! mask-spawn parity failed")
	_completed += 1


## The shipping node on both evaluators, LIVE, mask unwired. The solver keeps its params in double, so the
## node's own route must round them through float32 as the graph program does; without that the two routes
## solve ~1e-9-apart params and the droplets make it 2 m. (The unwired mask -- ones on one route, none on the
## other -- was checked too: the bilinear weights of a uniform quad sum to exactly 1.0 here.)
func _test_r_route_parity() -> void:
	print("
[R] Route parity: the node's GDScript route == its native route, mask unwired")
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
	node.set("droplet_count", 2000)
	var g := _graph_with(node)
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var native := g.native_supported()
	var rn := g.evaluate(gw, gw, rect, null, surf)
	g.force_gdscript_evaluation = true
	var rg := g.evaluate(gw, gw, rect, null, surf)
	var d := _max_abs_diff(rn, rg)
	var cut := _max_abs_diff(rn, surf)
	print("    native=%s  max |native - gdscript| = %.9f  cut = %.4f m (want > 0.1)" % [native, d, cut])
	if not native or d > EPS_SINGLE_DROPLET or cut <= 0.1:
		_fail += 1
		print("    !! the two routes of the shipping node disagree")
	_completed += 1


## The seed is lowered as two 16-bit halves. One float32 slot rounded 16777217 to 16777216, so the graph
## solved a different seed from the node's own route. Seed 0 is 1337 on both solvers.
func _test_s_seed_lowering() -> void:
	print("
[S] Seed lowering: 2^24+1 survives the program; seed 0 agrees with the oracle")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var out := {}
	for sd in [16777217, 16777216]:
		var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
		node.set("droplet_count", 500)
		node.set("seed", sd)
		var g := _graph_with(node)
		out[sd] = g.evaluate(gw, gw, rect, null, surf)
		g.force_gdscript_evaluation = true
		out[-sd] = g.evaluate(gw, gw, rect, null, surf)
	var route := _max_abs_diff(out[16777217], out[-16777217])
	var distinct := _max_abs_diff(out[16777217], out[16777216])
	var p0 := {"droplet_count": 500, "seed": 0}
	var zero := _max_abs_diff(DevHydraulicParticle.solve_oracle(surf, gw, gw, rect, p0)[0],
			Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, p0)["height"])
	print("    2^24+1 native vs gdscript = %.9f | 2^24+1 vs 2^24 = %.4f (want > 0) | seed 0 oracle vs native = %.9f"
		% [route, distinct, zero])
	if route > EPS_SINGLE_DROPLET or distinct <= 1.0e-4 or zero > EPS_SINGLE_DROPLET:
		_fail += 1
		print("    !! seed lowering failed")
	_completed += 1


## METRIC and the erosion radius both run the same on the oracle and in C++: the disc footprint, the step
## in metres, the per-area droplet count and the exact bedrock floor.
func _test_a5_metric_and_radius_parity() -> void:
	print("\n[A5] METRIC and radius parity: C++ Native vs GDScript oracle, every channel")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var cases := {
		"metric": {"units": 1, "droplet_density": 3.0, "step_length_m": 2.0, "max_lifetime": 30, "seed": 7},
		"cells r6": {"droplet_count": 2000, "radius_m": 6.0, "seed": 7},
		"metric r9": {"units": 1, "droplet_density": 3.0, "step_length_m": 2.0, "radius_m": 9.0, "seed": 7},
	}
	var names := ["height", "eroded", "deposited", "flow"]
	var ok := true
	for label in cases:
		var p: Dictionary = cases[label]
		var gd: Array = DevHydraulicParticle.solve_oracle(surf, gw, gw, rect, p)
		var cpp: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, p)
		var worst := 0.0
		for c in names.size():
			worst = maxf(worst, _max_abs_diff(gd[c], cpp[names[c]]))
		var cut := _max_abs_diff(surf, cpp["height"])
		print("    %-9s max |cpp - gdscript| = %.9f   cut = %.4f m (want > 0.1)" % [label, worst, cut])
		ok = ok and worst <= EPS_SINGLE_DROPLET and cut > 0.1
	if not ok:
		_fail += 1
		print("    !! METRIC / radius parity failed")
	_completed += 1


## CELLS with radius 0 is the solver as it was before METRIC and the radius existed, bit for bit. The hash
## was taken from the build before either change, on this fixture.
const CELLS_R0_HEIGHT_HASH := 2608144882

func _test_f_cells_fingerprint() -> void:
	print("\n[F] CELLS, radius 0: unchanged since before METRIC/radius (height hash)")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var h0: int = hash(Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, {"droplet_count": 2000, "seed": 7})["height"])
	# Control: the same run with a radius must NOT hash the same, or the hash is not looking at the cut.
	var h1: int = hash(Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect, {"droplet_count": 2000, "seed": 7, "radius_m": 6.0})["height"])
	print("    radius 0 hash = %d (want %d) | radius 6 hash = %d (control, want different)" % [h0, CELLS_R0_HEIGHT_HASH, h1])
	if h0 != CELLS_R0_HEIGHT_HASH or h1 == CELLS_R0_HEIGHT_HASH:
		_fail += 1
		print("    !! CELLS radius-0 output moved, or the control could not tell")
	_completed += 1


## The radius spreads each cut: the change field's roughness must drop well below the four-corner cut's.
## Roughness is scale-free -- Laplacian energy over (total |change|)^2 -- because the radius also moves about
## twice as much (fewer pits, so droplets live longer), and raw energy would count that against it.
func _test_l_radius_smooths() -> void:
	print("\n[L] Erosion radius smooths the cut (Laplacian energy of the change)")
	var gw := 128
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var e := []
	var amount := []
	for r in [0.0, 6.0]:
		var h: PackedFloat32Array = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect,
				{"droplet_count": 8000, "seed": 7, "radius_m": r})["height"]
		var lap := 0.0
		var tot := 0.0
		for z in range(1, gw - 1):
			for x in range(1, gw - 1):
				var i := z * gw + x
				var d := func(j: int) -> float: return h[j] - surf[j]
				var l: float = d.call(i - 1) + d.call(i + 1) + d.call(i - gw) + d.call(i + gw) - 4.0 * d.call(i)
				lap += l * l
				tot += absf(d.call(i))
		e.append(lap)
		amount.append(tot)
	var rough0: float = e[0] / maxf(amount[0] * amount[0], 1e-12)
	var rough1: float = e[1] / maxf(amount[1] * amount[1], 1e-12)
	var ratio: float = rough1 / maxf(rough0, 1e-30)
	print("    roughness r0 = %s  r6 = %s  ratio = %.3f (want < 0.4) | change r0 = %.1f r6 = %.1f (want both > 1)"
		% [String.num_scientific(rough0), String.num_scientific(rough1), ratio, amount[0], amount[1]])
	if ratio >= 0.4 or amount[0] <= 1.0 or amount[1] <= 1.0:
		_fail += 1
		print("    !! the radius did not smooth the cut, or nothing was cut")
	_completed += 1


## METRIC holds across resolutions: the change field, box-averaged to a common 64^2, must agree between 128^2
## and 256^2 of the same world. CELLS at the same droplet density per area is the control and must not.
func _test_u_resolution_invariance() -> void:
	print("\n[U] Resolution invariance: 128^2 vs 256^2 of one 256 m world")
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var modes := {
		"metric": {"units": 1, "droplet_density": 30.0, "step_length_m": 4.0, "max_lifetime": 30, "seed": 7},
		"cells": {"droplet_count": 80000, "seed": 7},
	}
	var rel := {}
	for label in modes:
		var change := []
		for g in [128, 256]:
			var p: Dictionary = modes[label].duplicate()
			if label == "cells":
				p["droplet_count"] = int(p["droplet_count"]) * (g / 128) * (g / 128)
			var s := _world_mound(g, rect)
			var h: PackedFloat32Array = Pasture3DUtil.hydraulic_particle_solve_grid(s, g, g, rect, p)["height"]
			change.append(_boxed_mean_abs_change(s, h, g, 64))
		rel[label] = absf(change[0] - change[1]) / maxf(change[0], 1e-9)
		print("    %-6s mean |change| at 64^2: 128 -> %.4f m, 256 -> %.4f m, relative %.3f" % [label, change[0], change[1], rel[label]])
	if rel["metric"] >= 0.07 or rel["cells"] < 0.07:
		_fail += 1
		print("    !! METRIC is not resolution-invariant, or the CELLS control could not tell")
	_completed += 1


## METRIC rides the program (units, radius and step in slots 13..15, density in the LUT): the node's native
## route must equal its GDScript route. A density lost on the way would solve 40 per 100 m² instead of 12.
func _test_n_metric_route() -> void:
	print("\n[N] METRIC route parity: the node's native route == its GDScript route")
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
	node.set("units", 1)
	node.set("droplet_density", 12.0)
	node.set("step_length_m", 2.0)
	node.set("radius_m", 5.0)
	var g := _graph_with(node)
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var native := g.native_supported()
	var rn := g.evaluate(gw, gw, rect, null, surf)
	g.force_gdscript_evaluation = true
	var rg := g.evaluate(gw, gw, rect, null, surf)
	var d := _max_abs_diff(rn, rg)
	print("    native=%s  max |native - gdscript| = %.9f  cut = %.4f m (want > 0.1)" % [native, d, _max_abs_diff(rn, surf)])
	if not native or d > EPS_SINGLE_DROPLET or _max_abs_diff(rn, surf) <= 0.1:
		_fail += 1
		print("    !! METRIC did not survive the lowering")
	_completed += 1


## `eroded` and `deposited` are net metres against the FINAL surface, so together they are exactly the
## height change, and neither counts a deposit that was later cut away. Checked against the input and the
## output, not against the numbers they were derived from.
func _test_e1_net_channels() -> void:
	print("\n[E1] eroded and deposited are net metres against the final surface")
	var gw := 96
	var rect := Rect2(0.0, 0.0, 384.0, 384.0)
	var surf := _make_test_surface(gw, gw)
	var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect,
			{"droplet_count": 12000, "seed": 7})
	var h: PackedFloat32Array = res["height"]
	var e: PackedFloat32Array = res["eroded"]
	var d: PackedFloat32Array = res["deposited"]
	var worst := 0.0
	var both := 0
	var max_e := 0.0
	var max_d := 0.0
	for i in surf.size():
		worst = maxf(worst, absf((d[i] - e[i]) - (h[i] - surf[i])))
		if e[i] > 0.0 and d[i] > 0.0:
			both += 1
		max_e = maxf(max_e, e[i])
		max_d = maxf(max_d, d[i])
	# In metres, not 0..1: a normalised channel would peak at exactly 1.
	print("    max |(dep - ero) - (h - in)| = %.9f (want <= %.7f) | cells in both = %d (want 0) | peaks %.4f / %.4f m"
		% [worst, EPS_SINGLE_DROPLET, both, max_e, max_d])
	if worst > EPS_SINGLE_DROPLET or both != 0 or max_e <= 0.01 or max_d <= 0.01 or is_equal_approx(max_e, 1.0) or is_equal_approx(max_d, 1.0):
		_fail += 1
		print("    !! the channels do not describe the final surface, or they are still normalised")
	_completed += 1


## deposit_at_death conserves mass: every grain a droplet carries is laid down somewhere, so the solve
## moves no material off the terrain. The default (off) is the control and must lose mass.
func _test_e2_mass_balance() -> void:
	print("\n[E2] deposit_at_death conserves mass; the default loses it")
	var gw := 96
	var rect := Rect2(0.0, 0.0, 384.0, 384.0)
	var surf := _make_test_surface(gw, gw)
	var cut := {}
	for on in [true, false]:
		var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gw, rect,
				{"droplet_count": 12000, "seed": 7, "deposit_at_death": on})
		var h: PackedFloat32Array = res["height"]
		var net := 0.0
		var gross := 0.0
		for i in surf.size():
			net += h[i] - surf[i]
			gross += absf(h[i] - surf[i])
		cut[on] = [net, gross]
	var rel_on: float = absf(cut[true][0]) / maxf(cut[true][1], 1e-9)
	var rel_off: float = absf(cut[false][0]) / maxf(cut[false][1], 1e-9)
	print("    net/gross change: on = %.5f (want < 0.002) | off = %.5f (control, want > 0.02)" % [rel_on, rel_off])
	if rel_on >= 0.002 or rel_off <= 0.02 or cut[false][0] >= 0.0:
		_fail += 1
		print("    !! deposit_at_death did not conserve mass, or the default already did")
	_completed += 1


## `flow` is path length per unit area at unit droplet density, in metres, so the same world reports the
## same drainage at any resolution under METRIC. Measured with erosion and deposition OFF: with them on,
## the two resolutions carve different pits and droplets die in different places, which is the solver's
## own resolution sensitivity ([U] measures that) and not the channel's. CELLS is the control.
func _test_e3_flow_invariance() -> void:
	print("
[E3] flow holds across resolutions under METRIC (frozen terrain)")
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var modes := {
		"metric": {"units": 1, "droplet_density": 30.0, "step_length_m": 4.0},
		"cells": {"droplet_count": 80000},
	}
	var rel := {}
	for label in modes:
		var mean_flow := []
		for g in [128, 256]:
			var p: Dictionary = modes[label].duplicate()
			p["max_lifetime"] = 30
			p["seed"] = 7
			p["erosion_speed"] = 0.0
			p["deposition_speed"] = 0.0
			if label == "cells":
				p["droplet_count"] = int(p["droplet_count"]) * (g / 128) * (g / 128)
			var s := _world_mound(g, rect)
			var f: PackedFloat32Array = Pasture3DUtil.hydraulic_particle_solve_grid(s, g, g, rect, p)["flow"]
			var t := 0.0
			for v in f:
				t += v
			mean_flow.append(t / float(f.size()))
		rel[label] = absf(mean_flow[0] - mean_flow[1]) / maxf(mean_flow[0], 1e-9)
		print("    %-6s mean flow: 128 -> %.4f m, 256 -> %.4f m, relative %.3f" % [label, mean_flow[0], mean_flow[1], rel[label]])
	if rel["metric"] >= 0.02 or rel["cells"] < 0.1:
		_fail += 1
		print("    !! flow is not resolution-invariant under METRIC, or the CELLS control could not tell")
	_completed += 1


## The aux channels survive the lowering in the right ORDER: reading port k off the native route must
## equal reading port k off the GDScript route, for every k. A swapped copy_aux shows up here and nowhere
## else -- the kernel parity checks compare the solver with the oracle, not the op's wiring.
func _test_e4_channel_route() -> void:
	print("\n[E4] every channel survives the lowering, in order")
	var gw := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var surf := _make_test_surface(gw, gw)
	var worst := 0.0
	var spread := INF
	var seen := []
	for port in 4:
		var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
		node.set("droplet_count", 4000)
		node.set("seed", 7)
		# deposit_at_death rides the LUT beside droplet_density, so this run proves that slot too.
		node.set("deposit_at_death", true)
		var g := Pasture3DTerrainGraph.new()
		var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
		var i_n := g.add_node(node)
		var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
		g.connect_ports(i_in, 0, i_n, 0)
		g.connect_ports(i_n, port, i_out, 0)
		var rn := g.evaluate(gw, gw, rect, null, surf)
		g.force_gdscript_evaluation = true
		var rg := g.evaluate(gw, gw, rect, null, surf)
		worst = maxf(worst, _max_abs_diff(rn, rg))
		seen.append(rn)
	# Control: the death deposit must have reached the native op -- without it the height differs.
	var off: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
	off.set("droplet_count", 4000)
	off.set("seed", 7)
	var g_off := _graph_with(off)
	var flag_effect := _max_abs_diff(seen[0], g_off.evaluate(gw, gw, rect, null, surf))
	# Control: the four channels must not be the same grid, or a swap would be invisible here.
	for a in 4:
		for b in range(a + 1, 4):
			spread = minf(spread, _max_abs_diff(seen[a], seen[b]))
	print("    max |native - gdscript| over 4 ports = %.9f (want <= %.7f) | closest two channels differ by %.4f (want > 1e-3) | death flag moves height %.4f (want > 1e-3)"
		% [worst, EPS_MULTI_DROPLET, spread, flag_effect])
	if worst > EPS_MULTI_DROPLET or spread <= 1.0e-3 or flag_effect <= 1.0e-3:
		_fail += 1
		print("    !! a channel or the death flag did not survive the lowering, or two channels are alike")
	_completed += 1


func _world_mound(p_g: int, p_rect: Rect2) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_g * p_g)
	for z in p_g:
		for x in p_g:
			var wx: float = p_rect.size.x * (float(x) + 0.5) / float(p_g)
			var wz: float = p_rect.size.y * (float(z) + 0.5) / float(p_g)
			var r: float = Vector2(wx - 128.0, wz - 128.0).length() / 128.0
			s[z * p_g + x] = maxf(0.0, 40.0 * (1.0 - r)) + 3.0 * sin(wx * 0.09) * cos(wz * 0.09)
	return s


func _boxed_mean_abs_change(p_before: PackedFloat32Array, p_after: PackedFloat32Array, p_g: int, p_to: int) -> float:
	var k := p_g / p_to
	var tot := 0.0
	for bz in p_to:
		for bx in p_to:
			var acc := 0.0
			for z in k:
				for x in k:
					var i := (bz * k + z) * p_g + bx * k + x
					acc += p_after[i] - p_before[i]
			tot += absf(acc / float(k * k))
	return tot / float(p_to * p_to)


func _graph_with(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var i_n := g.add_node(p_node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_n, 0)
	g.connect_ports(i_n, 0, i_out, 0)
	return g


func _test_b_seed_determinism() -> void:
	print("\n[B] Determinism across identical seeds and differentiation across distinct seeds")
	var gw := 32
	var gh := 32
	var rect := Rect2(0.0, 0.0, 50.0, 50.0)
	var surf := _make_test_surface(gw, gh)

	var p_seed1 := { "droplet_count": 2000, "seed": 999 }
	var p_seed2 := { "droplet_count": 2000, "seed": 999 }
	var p_seed3 := { "droplet_count": 2000, "seed": 1000 }

	var res1: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p_seed1)
	var res2: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p_seed2)
	var res3: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p_seed3)

	var diff_same := _max_abs_diff(res1["height"], res2["height"])
	var diff_diff := _max_abs_diff(res1["height"], res3["height"])

	print("    Same seed diff = %.9f (want == 0)" % diff_same)
	print("    Different seed diff = %.9f (want > 0)" % diff_diff)

	if diff_same > 0.0:
		_fail += 1
		print("    !! Solver is not deterministic on identical seeds")
	if diff_diff <= 1.0e-5:
		_fail += 1
		print("    !! Solver produced identical output across different seeds")


func _test_c_nan_boundary_handling() -> void:
	print("\n[C] NaN Boundary Invariance")
	var gw := 32
	var gh := 32
	var rect := Rect2(0.0, 0.0, 50.0, 50.0)
	var surf := _make_test_surface(gw, gh)

	# Set outer border to NaN
	for ix in range(gw):
		surf[ix] = NAN
		surf[(gh - 1) * gw + ix] = NAN
	for iz in range(gh):
		surf[iz * gw] = NAN
		surf[iz * gw + (gw - 1)] = NAN

	var p := { "droplet_count": 2000, "seed": 123 }
	var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p)
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


func _test_d_channel_generation() -> void:
	print("\n[D] Channel & Deposition Feature Generation")
	var gw := 64
	var gh := 64
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p := {
		"droplet_count": 10000,
		"max_lifetime": 40,
		"inertia": 0.1,
		"sediment_capacity": 5.0,
		"erosion_speed": 0.4,
		"deposition_speed": 0.4,
		"seed": 777,
	}

	var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(surf, gw, gh, rect, p)
	var h: PackedFloat32Array = res["height"]
	var s: PackedFloat32Array = res["deposited"]
	var f: PackedFloat32Array = res["flow"]

	var eroded_depth := _max_abs_diff(surf, h)
	var max_sed := _max_val(s)
	var max_flow := _max_val(f)

	print("    Max erosion delta = %.4f m" % eroded_depth)
	print("    Max deposited = %.4f m" % max_sed)
	print("    Max flow = %.4f" % max_flow)

	if eroded_depth < 0.01 or max_sed < 0.001 or max_flow < 0.1:
		_fail += 1
		print("    !! Solver failed to carve meaningful channels or deposit sediment")


func _make_test_surface(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(p_gw * p_gh)
	for iz in range(p_gh):
		var nz := float(iz) / float(p_gh - 1)
		for ix in range(p_gw):
			var nx := float(ix) / float(p_gw - 1)
			# Central cone with minor ridges
			var dx := nx - 0.5
			var dz := nz - 0.5
			var r := sqrt(dx * dx + dz * dz)
			var h := maxf(0.0, 30.0 * (1.0 - r * 2.0)) + 3.0 * sin(nx * 12.0) * cos(nz * 12.0)
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
