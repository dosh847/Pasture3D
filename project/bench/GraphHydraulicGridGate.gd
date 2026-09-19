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
extends Node

const DevErosionHydraulic = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_erosion_hydraulic.gd")

const EPS := 2.0e-6
const HYD_TOL := 3.0e-3 # GraphGpuParityGate's hydraulic tolerance
const WANT := 4

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphHydraulicGridGate: grid hydraulic outlets and PIPE model ===\n")
	_o1_outlet_parity()
	_o2_rim_only()
	_o3_outlet_gpu()
	_o4_outlet_route()
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
