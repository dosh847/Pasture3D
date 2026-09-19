# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicGridGate — the grid ErosionHydraulic solver's edge handling (review item 7) and its PIPE
# model (item 8). Correctness only: nothing here is timed.
#
#   [O1] OUTLETS: C++ == GDScript oracle, with a no-data block, every channel.
#   [O2] OUTLETS changes the rim and nothing else: cells further from the rim (and the no-data block) than
#        the iteration count are bit-identical to WALLS; the rim band is not (control).
#   [O3] OUTLETS: GPU == CPU within the hydraulic tolerance; the GPU must actually have run.
#   [O4] OUTLETS survives the lowering: the node's native route == its GDScript route.
#   [P0] MUSGRAVE at its defaults is bit-identical to the build before items 7 and 8.
#   [P1] PIPE: C++ == GDScript oracle, with a no-data block, under WALLS and OUTLETS.
#   [P2] PIPE is thread-invariant at 160 rows, and the threaded arm is proven to have split.
#   [P3] PIPE converges with resolution; grid-unit PIPE and MUSGRAVE are the controls that do not.
#   [P4] PIPE and its time step survive the lowering.
#   [P5] The GPU declines PIPE, and the best route then equals the CPU solve.
#
# [O3] and [P5] need a RenderingDevice: run this gate WITHOUT --headless.
extends Node

const DevErosionHydraulic = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_erosion_hydraulic.gd")

const EPS := 2.0e-6
const HYD_TOL := 3.0e-3 # GraphGpuParityGate's hydraulic tolerance
const WANT := 10

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphHydraulicGridGate: grid hydraulic outlets and PIPE model ===\n")
	_o1_outlet_parity()
	_o2_rim_only()
	_o3_outlet_gpu()
	_o4_outlet_route()
	_p0_default_unchanged()
	_p1_pipe_parity()
	_p2_pipe_threads()
	_p3_pipe_converges()
	_p4_pipe_route()
	_p5_pipe_declines_gpu()
	if _done != WANT:
		_fail += 1
		print("\n!! only %d of %d criteria reached their assertion" % [_done, WANT])
	print("\n=== %s (%d failures) ===\n" % ["GRAPH HYDRAULIC GRID PASS" if _fail == 0 else "GRAPH HYDRAULIC GRID FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_msg: String) -> void:
	_done += 1
	if not p_ok:
		_fail += 1
		print("    !! " + p_msg)


func _o1_outlet_parity() -> void:
	print("[O1] OUTLETS: C++ == GDScript oracle (with a no-data block)")
	var g := 48
	var rect := Rect2(0.0, 0.0, 192.0, 192.0)
	var s := _terrain(g, rect)
	for z in range(20, 24):
		for x in range(30, 36):
			s[z * g + x] = NAN
	var p := {"iterations": 20, "edge_mode": 1, "outlet_level": 0.5}
	var gd: Array = DevErosionHydraulic.solve_oracle(s, g, g, rect, p)
	var cpp: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)
	var worst := 0.0
	var names := ["height", "sediment", "flow"]
	for c in names.size():
		worst = maxf(worst, _max_abs_diff(gd[c], cpp[names[c]]))
	var walls: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": 20})
	var effect := _max_abs_diff(walls["height"], cpp["height"])
	print("    max |cpp - gdscript| = %.9f (want <= %.7f) | OUTLETS vs WALLS = %.4f m (want > 1e-3)" % [worst, EPS, effect])
	_check(worst <= EPS and effect > 1.0e-3, "OUTLETS oracle parity failed, or OUTLETS changed nothing")


func _o2_rim_only() -> void:
	print("\n[O2] OUTLETS moves the rim, never the interior")
	var g := 128
	var iters := 25
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _terrain(g, rect)
	for z in range(60, 64):
		for x in range(60, 66):
			s[z * g + x] = NAN
	var walls: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": iters})["height"]
	var outl: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect,
			{"iterations": iters, "edge_mode": 1})["height"]
	var interior := 0.0
	var rim := 0.0
	var n_interior := 0
	for z in g:
		for x in g:
			var i := z * g + x
			if is_nan(s[i]):
				continue
			var d_edge: int = mini(mini(x, z), mini(g - 1 - x, g - 1 - z))
			var d_hole: int = maxi(maxi(60 - z, z - 63), maxi(60 - x, x - 65))
			var d: int = mini(d_edge, d_hole)
			var diff := absf(walls[i] - outl[i])
			if d > iters + 1:
				interior = maxf(interior, diff)
				n_interior += 1
			elif d <= 2:
				rim = maxf(rim, diff)
	print("    interior (%d cells > %d from any outlet) max |OUTLETS - WALLS| = %.9f (want 0) | rim band = %.4f m (want > 1e-3)"
		% [n_interior, iters + 1, interior, rim])
	_check(interior == 0.0 and rim > 1.0e-3 and n_interior > 1000, "OUTLETS moved the interior, or did nothing at the rim")


func _o3_outlet_gpu() -> void:
	print("\n[O3] OUTLETS: GPU == CPU")
	var g := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _terrain(g, rect)
	# 5 passes: past that, float32 order differences between the GPU and CPU grow chaotically through the
	# erode/deposit branch in EITHER mode (WALLS, the unchanged default, is 0.016 m apart by 20 passes on
	# this fixture), so a longer run measures that chaos, not the outlet rule. The rim effect exists by 5.
	var p := {"iterations": 5, "edge_mode": 1, "outlet_level": 0.5}
	var gpu: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(s, g, g, rect, p)
	if not bool(gpu.get("ok", false)):
		_check(false, "the GPU hydraulic solver did not run, so this proves nothing")
		return
	var cpu: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)
	var worst := 0.0
	for ch in ["height", "sediment", "flow"]:
		worst = maxf(worst, _max_abs_diff(gpu[ch], cpu[ch]))
	# Control: the GPU must see the mode -- its OUTLETS answer must differ from its own WALLS answer.
	var gpu_walls: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(s, g, g, rect, {"iterations": 5})
	var sees := _max_abs_diff(gpu_walls["height"], gpu["height"])
	print("    max |GPU - CPU| = %.7f (want < %.4f) | GPU OUTLETS vs GPU WALLS = %.4f (want > 1e-3)" % [worst, HYD_TOL, sees])
	_check(worst < HYD_TOL and sees > 1.0e-3, "GPU OUTLETS diverged from CPU, or the GPU ignored the mode")


func _o4_outlet_route() -> void:
	print("\n[O4] OUTLETS survives the lowering")
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
	node.set("edge_mode", 1)
	node.set("outlet_level", 0.5)
	var gr := _graph_with(node)
	var g := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _terrain(g, rect)
	var native := gr.native_supported()
	var rn := gr.evaluate(g, g, rect, null, s)
	gr.force_gdscript_evaluation = true
	var rg := gr.evaluate(g, g, rect, null, s)
	var walls: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": 25})["height"]
	var d := _max_abs_diff(rn, rg)
	var effect := _max_abs_diff(rn, walls)
	print("    native=%s max |native - gdscript| = %.7f (want < %.4f) | native vs WALLS = %.4f (want > 1e-3)" % [native, d, HYD_TOL, effect])
	_check(native and d < HYD_TOL and effect > 1.0e-3, "OUTLETS did not reach the native op")


## MUSGRAVE, WALLS, every default: the solver as it was before outlets or PIPE existed, bit for bit. The
## hash was taken on the build before item 7, on this fixture.
const MUSGRAVE_HEIGHT_HASH := 343181042

func _p0_default_unchanged() -> void:
	print("\n[P0] Defaults unchanged since before outlets and PIPE (height hash)")
	var g := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _fp_surface(g)
	var h0: int = hash(Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": 25})["height"])
	# Control: the same run under PIPE must not hash the same, or the hash is not looking at the model.
	var h1: int = hash(Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": 25, "model": 1})["height"])
	print("    MUSGRAVE hash = %d (want %d) | PIPE hash = %d (control, want different)" % [h0, MUSGRAVE_HEIGHT_HASH, h1])
	_check(h0 == MUSGRAVE_HEIGHT_HASH and h1 != MUSGRAVE_HEIGHT_HASH, "the default output moved, or the control could not tell")


func _p1_pipe_parity() -> void:
	print("\n[P1] PIPE: C++ == GDScript oracle (with a no-data block), WALLS and OUTLETS")
	var g := 48
	var rect := Rect2(0.0, 0.0, 192.0, 192.0)
	var s := _terrain(g, rect)
	for z in range(20, 24):
		for x in range(30, 36):
			s[z * g + x] = NAN
	var names := ["height", "sediment", "flow"]
	var worst := 0.0
	for em in [0, 1]:
		var p := {"model": 1, "iterations": 10, "sediment_capacity": 0.2, "edge_mode": em, "outlet_level": 0.5}
		var gd: Array = DevErosionHydraulic.solve_oracle(s, g, g, rect, p)
		var cpp: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)
		for c in names.size():
			worst = maxf(worst, _max_abs_diff(gd[c], cpp[names[c]]))
	var musgrave: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, {"iterations": 10})["height"]
	var pipe: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect,
			{"model": 1, "iterations": 10, "sediment_capacity": 0.2})["height"]
	var effect := _max_abs_diff(musgrave, pipe)
	print("    max |cpp - gdscript| = %.9f (want <= %.7f) | PIPE vs MUSGRAVE = %.4f m (want > 1e-3)" % [worst, EPS, effect])
	_check(worst <= EPS and effect > 1.0e-3, "PIPE oracle parity failed, or PIPE is the Musgrave model")


## Every PIPE phase gathers into its own cell from start-of-phase buffers, so any row split gives the same
## bits. 160 rows, because the pool runs serial below 128 and a smaller grid would prove nothing -- the
## dispatch counter is the evidence that the threaded arm actually split.
func _p2_pipe_threads() -> void:
	print("\n[P2] PIPE: serial == threaded, bit for bit, at 160 rows")
	var g := 160
	var rect := Rect2(0.0, 0.0, 320.0, 320.0)
	var s := _terrain(g, rect)
	var p := {"model": 1, "iterations": 4, "sediment_capacity": 0.2, "edge_mode": 1}
	var cap_before: int = Pasture3DUtil.get_max_threads()
	Pasture3DUtil.set_max_threads(1)
	var d0: int = Pasture3DUtil.parallel_dispatch_count()
	var serial: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)
	var d_serial: int = Pasture3DUtil.parallel_dispatch_count() - d0
	Pasture3DUtil.set_max_threads(0)
	d0 = Pasture3DUtil.parallel_dispatch_count()
	var threaded: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)
	var d_threaded: int = Pasture3DUtil.parallel_dispatch_count() - d0
	Pasture3DUtil.set_max_threads(cap_before)
	var worst := 0.0
	for ch in ["height", "sediment", "flow"]:
		worst = maxf(worst, _max_abs_diff(serial[ch], threaded[ch]))
	print("    max |serial - threaded| = %.9f (want 0) | dispatches serial = %d (want 0), threaded = %d (want > 0)"
		% [worst, d_serial, d_threaded])
	_check(worst == 0.0 and d_serial == 0 and d_threaded > 0, "PIPE is not thread-invariant, or the threaded arm never split")


## The point of PIPE: one world at 128^2, 256^2 and 512^2 converges. Each run's change field, box-averaged
## to 64^2, is compared with the next resolution's (RMS, relative to the finest run's own change): the gap
## must be small and must shrink. PIPE run in GRID units (every cell 1 m, whatever the world -- what a
## cell-unit solver does) is the control, and so is MUSGRAVE; both must fail it.
func _p3_pipe_converges() -> void:
	print("\n[P3] PIPE converges with resolution (change field at 64^2, 128 -> 256 -> 512)")
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var arms := {
		"pipe": [{"model": 1, "sediment_capacity": 0.1}, false],
		"pipe, grid units": [{"model": 1, "sediment_capacity": 0.1}, true],
		"musgrave": [{"sediment_capacity": 0.1}, false],
	}
	var gap := {}
	var shrinks := {}
	for label in arms:
		var p: Dictionary = arms[label][0]
		var grid_units: bool = arms[label][1]
		var fields := []
		for g in [128, 256, 512]:
			var s := _mound(g, rect)
			var r: Rect2 = Rect2(0.0, 0.0, float(g), float(g)) if grid_units else rect
			var h: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, r, p)["height"]
			fields.append(_box_change(s, h, g, 64))
		var scale: float = maxf(_rms(fields[2], PackedFloat32Array()), 1e-9)
		var coarse: float = _rms(fields[0], fields[1]) / scale
		var fine: float = _rms(fields[1], fields[2]) / scale
		gap[label] = fine
		shrinks[label] = fine < coarse
		print("    %-16s gap 128/256 = %.3f  256/512 = %.3f (of its own change)" % [label, coarse, fine])
	_check(gap["pipe"] < 0.1 and shrinks["pipe"] and gap["pipe, grid units"] > 0.5 and gap["musgrave"] > 0.25,
		"PIPE does not converge, or a control could not tell")


func _p4_pipe_route() -> void:
	print("\n[P4] PIPE survives the lowering")
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
	node.set("model", 1)
	node.set("time_step", 0.3)
	node.set("sediment_capacity", 0.2)
	var gr := _graph_with(node)
	var g := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _terrain(g, rect)
	var native := gr.native_supported()
	var rn := gr.evaluate(g, g, rect, null, s)
	gr.force_gdscript_evaluation = true
	var rg := gr.evaluate(g, g, rect, null, s)
	# Control: the time step must have reached the solver -- the default step gives a different answer.
	var other: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect,
			{"model": 1, "sediment_capacity": 0.2})["height"]
	var d := _max_abs_diff(rn, rg)
	var effect := _max_abs_diff(rn, other)
	print("    native=%s max |native - gdscript| = %.9f (want <= %.7f) | vs default time step = %.4f (want > 1e-3)" % [native, d, EPS, effect])
	_check(native and d <= EPS and effect > 1.0e-3, "PIPE or its time step did not reach the native op")


## The GPU kernel is Musgrave only: it must decline PIPE (so the dispatcher solves it on the CPU) rather
## than run the wrong model. Needs a GPU to mean anything: the same call under MUSGRAVE must succeed.
func _p5_pipe_declines_gpu() -> void:
	print("\n[P5] The GPU declines PIPE; the best route solves it on the CPU")
	var g := 64
	var rect := Rect2(0.0, 0.0, 256.0, 256.0)
	var s := _terrain(g, rect)
	var p := {"model": 1, "iterations": 5, "sediment_capacity": 0.2}
	var musgrave_ok: bool = bool(Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(s, g, g, rect, {"iterations": 5}).get("ok", false))
	var pipe_ok: bool = bool(Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(s, g, g, rect, p).get("ok", false))
	var best: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid_best(s, g, g, rect, p)["height"]
	var cpu: PackedFloat32Array = Pasture3DUtil.erosion_hydraulic_solve_grid(s, g, g, rect, p)["height"]
	var d := _max_abs_diff(best, cpu)
	print("    GPU MUSGRAVE ok = %s (want true) | GPU PIPE ok = %s (want false) | max |best - cpu| = %.9f (want 0)" % [musgrave_ok, pipe_ok, d])
	_check(musgrave_ok and not pipe_ok and d == 0.0, "the GPU ran PIPE, or there was no GPU to decline it")


func _fp_surface(p_g: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_g * p_g)
	for iz in p_g:
		for ix in p_g:
			var nx := float(ix) / float(p_g - 1)
			var nz := float(iz) / float(p_g - 1)
			var r := sqrt((nx - 0.5) * (nx - 0.5) + (nz - 0.5) * (nz - 0.5))
			s[iz * p_g + ix] = maxf(0.0, 30.0 * (1.0 - r * 2.0)) + 3.0 * sin(nx * 12.0) * cos(nz * 12.0)
	return s


func _mound(p_g: int, p_rect: Rect2) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_g * p_g)
	for z in p_g:
		for x in p_g:
			var wx: float = p_rect.size.x * (float(x) + 0.5) / float(p_g)
			var wz: float = p_rect.size.y * (float(z) + 0.5) / float(p_g)
			var r: float = Vector2(wx - 128.0, wz - 128.0).length() / 128.0
			s[z * p_g + x] = maxf(0.0, 40.0 * (1.0 - r)) + 3.0 * sin(wx * 0.09) * cos(wz * 0.09)
	return s


func _box_change(p_before: PackedFloat32Array, p_after: PackedFloat32Array, p_g: int, p_to: int) -> PackedFloat32Array:
	var k := p_g / p_to
	var out := PackedFloat32Array()
	out.resize(p_to * p_to)
	for bz in p_to:
		for bx in p_to:
			var acc := 0.0
			for z in k:
				for x in k:
					var i := (bz * k + z) * p_g + bx * k + x
					acc += p_after[i] - p_before[i]
			out[bz * p_to + bx] = acc / float(k * k)
	return out


## RMS of a - b; an empty b is zero.
func _rms(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var t := 0.0
	for i in a.size():
		var d: float = a[i] - (b[i] if not b.is_empty() else 0.0)
		t += d * d
	return sqrt(t / float(maxi(a.size(), 1)))


# ---- helpers -----------------------------------------------------------------------------------------

func _terrain(p_g: int, p_rect: Rect2) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_g * p_g)
	for z in p_g:
		for x in p_g:
			var wx: float = p_rect.size.x * (float(x) + 0.5) / float(p_g)
			var wz: float = p_rect.size.y * (float(z) + 0.5) / float(p_g)
			var cx: float = p_rect.size.x * 0.5
			var r: float = Vector2(wx - cx, wz - cx).length() / cx
			s[z * p_g + x] = 30.0 * maxf(0.0, 1.0 - r) + 0.04 * wx + 2.0 * sin(wx * 0.11) * cos(wz * 0.07)
	return s


func _graph_with(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var i_n := g.add_node(p_node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_n, 0)
	g.connect_ports(i_n, 0, i_out, 0)
	return g


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size() or a.is_empty():
		return INF
	var m := 0.0
	for i in a.size():
		var va := a[i]
		var vb := b[i]
		if is_nan(va) and is_nan(vb):
			continue
		if is_nan(va) or is_nan(vb):
			return INF
		m = maxf(m, absf(va - vb))
	return m
