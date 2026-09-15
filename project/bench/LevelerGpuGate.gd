# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerGpuGate — the GPU Leveler against the lowered CPU one (PASTURE3D_GRAPH_LEVELER_SPEC.md §7 GPU).
#
# Every criterion calls graph_eval_grid_gpu DIRECTLY. Compared through evaluate() a refusal would fall back
# to the CPU and agree perfectly (`graph-gpu-bail-is-graph-wide`); here an empty return IS the refusal and
# is counted as one.
#
#   A  height agrees with the CPU for every statistic, both distance routes, cut/fill, path-width feather,
#      a wired target and a NaN footprint. Tolerance 2e-3 m: the shader is float32 and the mean's block
#      sums are float32 before the host folds them in double.
#   B  channels 1-4 are refused; control: channel 0 of the same graph is served.
#   C  an empty core passes the height through unchanged; control: the same graph with a full mask moves it.
#
# WINDOWED ONLY. With no RenderingDevice it prints NO-SIGNAL and quits 0 as SKIPPED.
#   Godot_v4.7-stable_win64_console.exe --path project bench/LevelerGpuGate.tscn
extends Node

const GW := 128
const GH := 128
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const EPS := 2.0e-3
const CRITERIA := ["A", "B", "C"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== LevelerGpuGate: GPU Leveler vs the lowered CPU one (spec §7 GPU) ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	var probe: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(_io_graph().compile_graph_program(),
			GW, GH, RECT, _terrain())
	if probe.is_empty():
		print("    NO-SIGNAL: the GPU evaluator bailed on a bare in->out graph (no RenderingDevice).")
		print("=== LEVELER GPU SKIPPED (no RenderingDevice) ===")
		get_tree().quit(0)
		return
	print("    precondition: the GPU route is live (%d cells on a bare in->out graph)" % probe.size())

	_a_gpu_matches_cpu()
	_b_mask_channels_refused()
	_c_empty_core_passes_through()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== LEVELER GPU %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


# --- fixtures ---------------------------------------------------------------------------------------

func _terrain(p_nan_strip := false) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(GW * GH)
	var dx := RECT.size.x / GW
	for iz in GH:
		for ix in GW:
			var x := RECT.position.x + (ix + 0.5) * dx
			var z := RECT.position.y + (iz + 0.5) * dx
			h[iz * GW + ix] = 10.0 + 0.2 * x + 0.1 * z + 6.0 * exp(-(pow(x - 8.0, 2.0) + pow(z + 6.0, 2.0)) / 60.0) \
					+ 0.8 * sin(x * 0.37) * cos(z * 0.23)
			if p_nan_strip and ix > 100:
				h[iz * GW + ix] = NAN
	return h


func _loop() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(-30, -28), Vector2(26, -30), Vector2(32, 24), Vector2(-12, 30),
			Vector2(-34, 8)])
	p.half_widths = PackedFloat32Array([2.0, 3.0, 12.0, 10.0, 5.0])
	p.closed = true
	return p


func _road() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(-50, -10), Vector2(-10, 5), Vector2(20, -5), Vector2(50, 12)])
	p.half_widths = PackedFloat32Array([14.0, 14.0, 14.0, 14.0])
	p.closed = false
	return p


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g


## Input -> Leveler.height; loop Road Source -> Leveler.loop (optional); open Road Source -> Path Mask ->
## Leveler.mask (optional), or a Const -> Leveler.mask; Const -> Leveler.target_height (optional).
## Leveler[channel] -> Output.
func _graph(p_cfg: Dictionary, p_opts: Dictionary, p_channel := 0) -> Pasture3DTerrainGraph:
	var lev := Pasture3DGraphNodeLeveler.new()
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE # the original cases; INSIDE ones set it
	for k in p_cfg:
		lev.set(String(k), p_cfg[k])
	var loop_src := Pasture3DGraphNodeRoadSource.new()
	loop_src.path = _loop()
	var road_src := Pasture3DGraphNodeRoadSource.new()
	road_src.path = _road()
	var pm := Pasture3DGraphNodePathMask.new()
	pm.feather = 8.0
	var tgt := Pasture3DGraphNodeConst.new()
	tgt.value = float(p_opts.get("target", 0.0))
	var mconst := Pasture3DGraphNodeConst.new()
	mconst.value = float(p_opts.get("mask_const", 1.0))
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), loop_src, lev,
			Pasture3DGraphNodeOutput.new(), road_src, pm, tgt, mconst]
	g.nodes = nodes
	var conns: Array = [[0, 0, 2, 0], [2, p_channel, 3, 0]]
	if p_opts.get("loop", false):
		conns.append([1, 0, 2, 1])
	if p_opts.get("road_mask", false):
		conns.append([4, 0, 5, 0])
		conns.append([5, 0, 2, 2])
	elif p_opts.has("mask_const"):
		conns.append([7, 0, 2, 2])
	if p_opts.has("target"):
		conns.append([6, 0, 2, 3])
	g.connections = conns
	return g


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		var an := is_nan(p_a[i])
		if an and is_nan(p_b[i]):
			continue
		if an != is_nan(p_b[i]):
			return INF
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


# --- A. GPU == CPU ------------------------------------------------------------------------------------
func _a_gpu_matches_cpu() -> void:
	print("[A] GPU height == lowered CPU height, every statistic and route")
	var surf := _terrain()
	var cases := [
		["loop MEAN", {"statistic": 0, "feather": 6.0}, {"loop": true}, surf],
		["loop MEDIAN", {"statistic": 1, "feather": 6.0}, {"loop": true}, surf],
		["loop MEDIAN 64 bins", {"statistic": 1, "median_bins": 64, "feather": 6.0}, {"loop": true}, surf],
		["loop MIN", {"statistic": 2, "feather": 6.0}, {"loop": true}, surf],
		["loop MAX", {"statistic": 3, "feather": 6.0}, {"loop": true}, surf],
		["loop LEVEL wired", {"mode": 1, "feather": 6.0}, {"loop": true, "target": 3.5}, surf],
		["loop CUT_ONLY", {"mode": 1, "target_height": 14.0, "cut_fill": 1, "feather": 6.0}, {"loop": true}, surf],
		["loop FILL_ONLY", {"statistic": 0, "cut_fill": 2, "feather": 6.0}, {"loop": true}, surf],
		["loop path width", {"mode": 1, "target_height": 20.0, "feather_from_path_width": true,
				"path_width_scale": 1.5}, {"loop": true}, surf],
		["loop hard edge", {"mode": 1, "target_height": 20.0, "feather": 0.0}, {"loop": true}, surf],
		["mask JFA MEDIAN", {"statistic": 1, "feather": 7.0}, {"road_mask": true}, surf],
		["loop+mask JFA MEAN", {"statistic": 0, "feather": 7.0}, {"loop": true, "road_mask": true}, surf],
		["no area MEAN", {"statistic": 0}, {}, surf],
		["NaN footprint MEDIAN", {"statistic": 1, "feather": 6.0}, {"loop": true}, _terrain(true)],
		# INSIDE: the wall within the area — exact loop, raster mask, grid border, footprint, path width.
		["IN loop LEVEL", {"mode": 1, "target_height": 30.0, "feather": 9.0, "feather_side": 0}, {"loop": true}, surf],
		["IN loop MEDIAN SLOPE", {"statistic": 1, "feather": 9.0, "feather_side": 0, "walls_shape": 1},
				{"loop": true}, surf],
		["IN mask JFA", {"mode": 1, "target_height": 30.0, "feather": 12.0, "feather_side": 0}, {"road_mask": true}, surf],
		["IN no area (border)", {"mode": 1, "target_height": 30.0, "feather": 20.0, "feather_side": 0}, {}, surf],
		["IN NaN footprint loop", {"mode": 1, "target_height": 30.0, "feather": 9.0, "feather_side": 0},
				{"loop": true}, _terrain(true)],
		["IN path width CUT", {"mode": 1, "target_height": 14.0, "feather_side": 0, "cut_fill": 1,
				"feather_from_path_width": true, "path_width_scale": 1.5}, {"loop": true}, surf],
	]
	var worst := 0.0
	var bailed := []
	var moved := 0
	for c in cases:
		var prog := _graph(c[1], c[2]).compile_graph_program()
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, GW, GH, RECT, c[3])
		var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, c[3])
		if gpu.is_empty():
			bailed.append(c[0])
			print("    %-22s the GPU REFUSED this program" % c[0])
			continue
		var w := _worst(gpu, cpu)
		var mv := _worst(cpu, c[3])
		if mv > 1.0:
			moved += 1
		worst = maxf(worst, w)
		print("    %-22s worst |GPU - CPU| %.6f m, CPU moved the terrain up to %.2f m" % [c[0], w, mv])
		if w > EPS:
			_fail += 1
			print("    !! %s disagrees" % c[0])
	_check("A", bailed.is_empty() and worst <= EPS,
			"%d cases, %d refused, worst %.6f m (want <= %.4f)" % [cases.size(), bailed.size(), worst, EPS])
	# CONTROL: the fixtures have to level something, or A compared two pass-throughs.
	if moved < cases.size() - 2:
		_fail += 1
		print("    !! control: only %d of %d cases moved the terrain by > 1 m" % [moved, cases.size()])


# --- B. mask channels refused ------------------------------------------------------------------------
func _b_mask_channels_refused() -> void:
	print("[B] channels 1-4 are refused on the GPU; channel 0 is served")
	var cfg := {"statistic": 0, "feather": 6.0}
	var surf := _terrain()
	var served := []
	for ch in range(1, 5):
		var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				_graph(cfg, {"loop": true}, ch).compile_graph_program(), GW, GH, RECT, surf)
		if not got.is_empty():
			served.append(ch)
	_check("B", served.is_empty(), "mask channels served by the GPU: %s (want none)" % str(served))
	var h_got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_graph(cfg, {"loop": true}, 0).compile_graph_program(), GW, GH, RECT, surf)
	print("    control: channel 0 returned %d cells (want %d)" % [h_got.size(), GW * GH])
	if h_got.size() != GW * GH:
		_fail += 1
		print("    !! height was refused too, so [B] measured the op bailing, not the channel guard")


# --- C. empty core passes through ---------------------------------------------------------------------
func _c_empty_core_passes_through() -> void:
	print("[C] an empty core passes the height through on the GPU")
	var surf := _terrain()
	var cfg := {"mode": 1, "target_height": 30.0, "feather": 6.0}
	var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_graph(cfg, {"mask_const": 0.5}).compile_graph_program(), GW, GH, RECT, surf)
	var w := _worst(got, surf) if not got.is_empty() else INF
	_check("C", w == 0.0, "mask 0.5 everywhere: worst |GPU - input| %.6f m (want exactly 0)" % w)
	var full: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_graph(cfg, {"mask_const": 1.0}).compile_graph_program(), GW, GH, RECT, surf)
	var fw := _worst(full, surf) if not full.is_empty() else 0.0
	print("    control: mask 1.0 moves the terrain by up to %.2f m (want > 1)" % fw)
	if fw <= 1.0:
		_fail += 1
		print("    !! control dead: a full mask did not level either")
