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
	_test_b_seed_determinism()
	_test_c_nan_boundary_handling()
	_test_d_channel_generation()

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
	var diff_s := _max_abs_diff(gd_res[1], cpp_res["sediment"])
	var diff_f := _max_abs_diff(gd_res[2], cpp_res["flow"])
	var diff_w := _max_abs_diff(gd_res[3], cpp_res["water_depth"])

	print("    Height      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS_MULTI_DROPLET])
	print("    Sediment    max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_s, EPS_MULTI_DROPLET])
	print("    Flow        max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f, EPS_MULTI_DROPLET])
	print("    Water Depth max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_w, EPS_MULTI_DROPLET])

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
	var names := ["height", "sediment", "flow", "water_depth"]
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
	var s: PackedFloat32Array = res["sediment"]
	var f: PackedFloat32Array = res["flow"]

	var eroded_depth := _max_abs_diff(surf, h)
	var max_sed := _max_val(s)
	var max_flow := _max_val(f)

	print("    Max erosion delta = %.4f m" % eroded_depth)
	print("    Max sediment = %.4f" % max_sed)
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
