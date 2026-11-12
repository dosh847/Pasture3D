# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMaskFeatherGate — the Mask Feather node: Path Mask's distance feather, for any MASK.
#
# MA  mask_feather_grid equals the [Dev/GD] oracle for every side x falloff, inverted, with a NaN cell and a
#     soft input. Control: the oracle at 10% more feather differs by more than the tolerance.
# MB  Input -> Mask Feather -> Output: compile_graph_program + graph_eval_grid equals force_gdscript_evaluation
#     (explicit root), with the feather both typed and driven through its value port by a Const; the graph is
#     native_supported and the op is in graph_op_ids. Controls: the driven feather changes the result; a bogus
#     op is not in graph_op_ids.
# MC  OUTWARD on a hard disc is Path Mask's rule: clamp(1 - (r - R) / F) with r the analytic radius, within
#     the half-cell staircase of a rasterised disc. Control: INWARD is not that ramp.
# MD  resolution invariance on a FIELD metric: the 256² result block-averaged to 64² against the 64² result,
#     RMS over the ramp band, within the half-cell contour floor. Control: a feather of a fixed number of
#     CELLS exceeds twice that floor.
# ME  sides: OUTWARD never drops below the thresholded input, INWARD never reaches outside it, CENTRED reads
#     ~0.5 on the contour. Control: OUTWARD does reach outside.
# MF  no edge: an empty mask reads 0 (inverted 1), a full mask 1, NaN stays NaN with finite neighbours, and
#     feather 0 is the thresholded input. Control: feather 0 is not the feathered result.
# MG  GPU: a graph containing Mask Feather is accepted by graph_eval_grid_gpu (the bail is graph-wide) and
#     matches the CPU route for every side x falloff, inverted, and for an empty and a full mask with a huge
#     feather (the no-edge case the shader reads off the resolved field per cell); a NaN cell stays NaN.
#     Control: the CPU at 10% more feather is outside the GPU tolerance. NO-SIGNAL without a RenderingDevice:
#     run WINDOWED to exercise it.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphMaskFeatherGate.tscn
extends Node

const RECT := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const N := 128
const EPS := 1e-5

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphMaskFeatherGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "mask_feather_grid"):
		_check(false, "mask_feather_grid is not bound — rebuild the GDExtension")
	else:
		_ma()
		_mb()
		_mc()
		_md()
		_me()
		_mf()
		_mg()
	_check(_ran == 7, "all 7 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["MASK FEATHER PASS" if _fail == 0 else "MASK FEATHER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


static func _cell(p_i: int, p_n: int) -> Vector2:
	var d := RECT.size.x / p_n
	return Vector2(RECT.position.x + (p_i % p_n + 0.5) * d, RECT.position.y + (p_i / p_n + 0.5) * d)


## A hard disc of radius p_r metres about p_c.
static func _disc(p_n: int, p_r: float, p_c: Vector2 = Vector2.ZERO) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_n * p_n)
	for i in p_n * p_n:
		m[i] = 1.0 if _cell(i, p_n).distance_to(p_c) < p_r else 0.0
	return m


## A soft, lumpy mask: two overlapping cones with a ripple, so the 0.5 contour is not a circle.
static func _soft(p_n: int) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_n * p_n)
	for i in p_n * p_n:
		var c := _cell(i, p_n)
		var a := 1.0 - c.distance_to(Vector2(-120.0, 40.0)) / 260.0
		var b := 1.0 - c.distance_to(Vector2(170.0, -90.0)) / 180.0
		m[i] = clampf(maxf(a, b) + 0.08 * sin(c.x * 0.05) * cos(c.y * 0.04), 0.0, 1.0)
	return m


static func _params(p_f: float, p_side: int, p_falloff: int, p_thr: float, p_inv: bool) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = p_f
	p[1] = p_side
	p[2] = p_falloff
	p[3] = p_thr
	p[4] = 1.0 if p_inv else 0.0
	return p


static func _oracle(p_m: PackedFloat32Array, p_n: int, p_f: float, p_side: int, p_falloff: int, p_thr: float,
		p_inv: bool) -> PackedFloat32Array:
	var o := Pasture3DGraphNodeDevMaskFeather.new()
	o.side = p_side
	o.falloff = p_falloff
	o.threshold = p_thr
	o.invert = p_inv
	return o.solve(p_m, p_n, p_n, RECT, p_f)


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) or is_nan(y):
			if is_nan(x) != is_nan(y):
				return INF
			continue
		w = maxf(w, absf(x - y))
	return w


func _ma() -> void:
	print("[MA] the native kernel equals the [Dev/GD] oracle")
	var m := _soft(N)
	m[N * 50 + 70] = NAN
	var worst := 0.0
	for side in 3:
		for falloff in 2:
			for inv in [false, true]:
				var nat := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(37.0, side, falloff, 0.45, inv))
				var ora := _oracle(m, N, 37.0, side, falloff, 0.45, inv)
				var w := _worst(nat, ora)
				worst = maxf(worst, w)
				if w > EPS:
					print("    side %d falloff %d invert %s: %.7f" % [side, falloff, inv, w])
	_check(worst <= EPS, "12 combinations: worst %.8f" % worst)
	var nat0 := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(37.0, 0, 0, 0.45, false))
	var off := _worst(nat0, _oracle(m, N, 37.0 * 1.1, 0, 0, 0.45, false))
	_check(off > EPS * 100.0, "control: the oracle at 10%% more feather is %.5f off" % off)
	_ran += 1


func _graph(p_node: Pasture3DGraphNode, p_drive: float = NAN) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), p_node,
			Pasture3DGraphNodeRegistry.create(&"output")]
	var c: Pasture3DGraphNode = null
	if not is_nan(p_drive):
		c = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_drive)
		nodes.append(c)
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, 0, 2, 0)
	if c != null:
		g.connect_ports(3, 0, 1, 1)
	return g


func _feather_node() -> Pasture3DGraphNode:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"mask_feather")
	n.set("feather", 25.0)
	n.set("side", 2)
	n.set("falloff", 1)
	n.set("threshold", 0.4)
	return n


func _mb() -> void:
	print("[MB] the compiled graph route equals the GDScript evaluator")
	var m := _soft(N)
	var results := []
	var native := true
	for drive in [NAN, 60.0]:
		var g := _graph(_feather_node(), drive)
		native = native and g.native_supported()
		var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, m)
		var g2 := _graph(_feather_node(), drive)
		g2.force_gdscript_evaluation = true
		var gd: PackedFloat32Array = g2.evaluate(N, N, RECT, null, m, 2)
		_check(_worst(nat, gd) <= EPS, "%s feather: worst %.8f" % ["driven" if not is_nan(drive) else "typed",
				_worst(nat, gd)])
		results.append(nat)
	_check(native, "both graphs are native_supported")
	var drv := _worst(results[0], results[1])
	_check(drv > 0.05, "control: the driven feather changes the result by %.4f" % drv)
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("mask_feather") or ids.has(&"mask_feather"), "mask_feather is a native op")
	_check(not (ids.has("mask_feather_bogus") or ids.has(&"mask_feather_bogus")), "control: a bogus op is not")
	var has_mask_port := false
	for p in _feather_node().input_ports():
		has_mask_port = has_mask_port or p.id == &"mask"
	_check(not has_mask_port, "no framework mask port")
	_ran += 1


## Mean and max |result - Path Mask's ramp| over the ramp band.
static func _vs_ramp(p_out: PackedFloat32Array, p_n: int, p_r: float, p_f: float) -> Vector2:
	var sum := 0.0
	var cnt := 0
	var worst := 0.0
	for i in p_n * p_n:
		var r := _cell(i, p_n).length()
		if r < p_r - 1.0 or r > p_r + p_f + 1.0:
			continue
		var want := clampf(1.0 - (r - p_r) / p_f, 0.0, 1.0)
		var d := absf(p_out[i] - want)
		sum += d
		cnt += 1
		worst = maxf(worst, d)
	return Vector2(sum / maxf(cnt, 1), worst)


func _mc() -> void:
	print("[MC] OUTWARD on a hard disc is Path Mask's ramp")
	var r := 150.0
	var f := 40.0
	var dx := RECT.size.x / N
	var m := _disc(N, r)
	var out := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(f, 0, 0, 0.5, false))
	var e := _vs_ramp(out, N, r, f)
	# A rasterised disc's contour is off the true circle by up to half a cell (+ JFA's diagonal rounding).
	var tol := (0.5 * dx * sqrt(2.0)) / f
	_check(e.x <= tol * 0.5 and e.y <= tol, "mean %.4f, worst %.4f (tol %.4f)" % [e.x, e.y, tol])
	var inward := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(f, 1, 0, 0.5, false))
	var ei := _vs_ramp(inward, N, r, f)
	_check(ei.x > tol, "control: INWARD is %.4f off the ramp on average" % ei.x)
	_ran += 1


## The fine field averaged down to the coarse grid's cells.
static func _block_mean(p_fine: PackedFloat32Array, p_nf: int, p_nc: int) -> PackedFloat32Array:
	var k := p_nf / p_nc
	var out := PackedFloat32Array()
	out.resize(p_nc * p_nc)
	for cz in p_nc:
		for cx in p_nc:
			var s := 0.0
			for z in k:
				for x in k:
					s += p_fine[(cz * k + z) * p_nf + cx * k + x]
			out[cz * p_nc + cx] = s / float(k * k)
	return out


## RMS of the difference over cells where either field is inside the ramp.
static func _band_rms(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var s := 0.0
	var c := 0
	for i in p_a.size():
		var in_band := (p_a[i] > 0.001 and p_a[i] < 0.999) or (p_b[i] > 0.001 and p_b[i] < 0.999)
		if in_band:
			s += (p_a[i] - p_b[i]) * (p_a[i] - p_b[i])
			c += 1
	return sqrt(s / maxf(c, 1))


func _md() -> void:
	print("[MD] resolution invariance on a field metric")
	var nc := 64
	var nf := 256
	# A soft input's 0.5 contour sits at the same world place at every resolution.
	var mc := _soft(nc)
	var mf := _soft(nf)
	var f := 60.0
	var coarse := Pasture3DUtil.mask_feather_grid(mc, nc, nc, RECT, _params(f, 2, 0, 0.5, false))
	var fine := Pasture3DUtil.mask_feather_grid(mf, nf, nf, RECT, _params(f, 2, 0, 0.5, false))
	var rms := _band_rms(_block_mean(fine, nf, nc), coarse)
	# The floor: the coarse grid places the contour anywhere within half a cell of the fine one, a uniform
	# error of +-dx/2 metres, which the ramp turns into an RMS of (dx/2) / (F sqrt 3).
	var tol := (0.5 * RECT.size.x / nc) / (f * sqrt(3.0))
	_check(rms <= tol, "metre feather: band RMS %.4f (tol %.4f)" % [rms, tol])
	# The wrong unit: four CELLS of feather, 64 m coarse and 16 m fine.
	var cells_c := Pasture3DUtil.mask_feather_grid(mc, nc, nc, RECT, _params(4.0 * RECT.size.x / nc, 2, 0, 0.5, false))
	var cells_f := Pasture3DUtil.mask_feather_grid(mf, nf, nf, RECT, _params(4.0 * RECT.size.x / nf, 2, 0, 0.5, false))
	var rms_c := _band_rms(_block_mean(cells_f, nf, nc), cells_c)
	_check(rms_c > tol * 2.0, "control: a 4-cell feather has band RMS %.4f" % rms_c)
	_ran += 1


func _me() -> void:
	print("[ME] the three sides")
	var m := _soft(N)
	var thr := 0.5
	var o := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(30.0, 0, 0, thr, false))
	var inn := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(30.0, 1, 0, thr, false))
	var cen := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(30.0, 2, 0, thr, false))
	var out_below := 0.0
	var in_leak := 0.0
	var out_leak := 0.0
	var edge_dev := 0.0
	for iz in N:
		for ix in N:
			var i := iz * N + ix
			var inside := m[i] > thr
			if inside:
				out_below = maxf(out_below, 1.0 - o[i])
			else:
				in_leak = maxf(in_leak, inn[i])
				out_leak = maxf(out_leak, o[i])
			# A contour cell pair: this cell and its right neighbour straddle the threshold.
			if ix + 1 < N and inside != (m[i + 1] > thr):
				edge_dev = maxf(edge_dev, absf(0.5 * (cen[i] + cen[i + 1]) - 0.5))
	_check(out_below <= 1e-6, "OUTWARD keeps the shape at 1: worst %.7f" % out_below)
	_check(in_leak <= 1e-6, "INWARD stays inside: worst %.7f" % in_leak)
	_check(edge_dev <= 1e-4, "CENTRED straddles the contour at 0.5: worst %.6f" % edge_dev)
	_check(out_leak > 0.5, "control: OUTWARD reaches %.3f outside the shape" % out_leak)
	_ran += 1


func _mf() -> void:
	print("[MF] no edge, NaN, and feather 0")
	var empty := PackedFloat32Array()
	empty.resize(N * N)
	var full := empty.duplicate()
	full.fill(1.0)
	var e0 := Pasture3DUtil.mask_feather_grid(empty, N, N, RECT, _params(1e6, 2, 0, 0.5, false))
	var e1 := Pasture3DUtil.mask_feather_grid(empty, N, N, RECT, _params(1e6, 2, 0, 0.5, true))
	var f1 := Pasture3DUtil.mask_feather_grid(full, N, N, RECT, _params(1e6, 2, 0, 0.5, false))
	_check(_mx(e0) == 0.0, "empty mask reads 0 even with a huge feather (max %.4f)" % _mx(e0))
	_check(_mn(e1) == 1.0, "empty mask inverted reads 1 (min %.4f)" % _mn(e1))
	_check(_mn(f1) == 1.0, "full mask reads 1 (min %.4f)" % _mn(f1))

	var m := _disc(N, 100.0)
	var hole := N * (N / 2) + N / 2 + 40
	m[hole] = NAN
	var r := Pasture3DUtil.mask_feather_grid(m, N, N, RECT, _params(20.0, 0, 0, 0.5, false))
	_check(is_nan(r[hole]) and is_finite(r[hole + 1]) and is_finite(r[hole - 1]),
			"NaN stays NaN (%s), neighbours finite (%s, %s)" % [r[hole], r[hole - 1], r[hole + 1]])

	var soft := _soft(N)
	var hard := Pasture3DUtil.mask_feather_grid(soft, N, N, RECT, _params(0.0, 0, 0, 0.5, false))
	var thresholded := PackedFloat32Array()
	thresholded.resize(N * N)
	for i in N * N:
		thresholded[i] = 1.0 if soft[i] > 0.5 else 0.0
	_check(_worst(hard, thresholded) == 0.0, "feather 0 is the thresholded input")
	var feathered := Pasture3DUtil.mask_feather_grid(soft, N, N, RECT, _params(20.0, 0, 0, 0.5, false))
	_check(_worst(feathered, thresholded) > 0.5, "control: feather 20 m is not")
	_ran += 1


static func _mx(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return m


static func _mn(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m


## A program with the feather typed in, for both routes.
func _program(p_f: float, p_side: int, p_falloff: int, p_inv: bool) -> Dictionary:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"mask_feather")
	n.set("feather", p_f)
	n.set("side", p_side)
	n.set("falloff", p_falloff)
	n.set("threshold", 0.45)
	n.set("invert", p_inv)
	return _graph(n).compile_graph_program()


func _mg() -> void:
	print("[MG] the GPU route equals the CPU route")
	const GPU_TOL := 1.0e-3
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_check(false, "graph_eval_grid_gpu is not bound")
		_ran += 1
		return
	var m := _soft(N)
	var probe := Pasture3DUtil.graph_eval_grid_gpu(_program(30.0, 0, 0, false), N, N, RECT, m)
	if probe.is_empty():
		var io := Pasture3DTerrainGraph.create_empty()
		io.nodes = [Pasture3DGraphNodeRegistry.create(&"input"), Pasture3DGraphNodeRegistry.create(&"output")] 				as Array[Pasture3DGraphNode]
		io.connect_ports(0, 0, 1, 0)
		if Pasture3DUtil.graph_eval_grid_gpu(io.compile_graph_program(), N, N, RECT, m).is_empty():
			print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
		else:
			_check(false, "the GPU declined Mask Feather but not a bare in->out graph (graph-wide bail)")
		_ran += 1
		return
	var worst := 0.0
	for side in 3:
		for falloff in 2:
			for inv in [false, true]:
				var prog := _program(30.0, side, falloff, inv)
				var gpu := Pasture3DUtil.graph_eval_grid_gpu(prog, N, N, RECT, m)
				var cpu := Pasture3DUtil.graph_eval_grid(prog, N, N, RECT, m)
				worst = maxf(worst, _worst(gpu, cpu))
	_check(worst <= GPU_TOL, "12 combinations: worst |gpu - cpu| %.7f" % worst)

	var empty := PackedFloat32Array()
	empty.resize(N * N)
	var full := empty.duplicate()
	full.fill(1.0)
	var edge_worst := 0.0
	for fld in [empty, full]:
		for side in 3:
			var prog := _program(1e5, side, 0, false)
			edge_worst = maxf(edge_worst, _worst(Pasture3DUtil.graph_eval_grid_gpu(prog, N, N, RECT, fld),
					Pasture3DUtil.graph_eval_grid(prog, N, N, RECT, fld)))
	_check(edge_worst == 0.0, "empty and full masks, 100 km feather: worst %.7f" % edge_worst)

	var holed := _disc(N, 150.0)
	var hole := N * (N / 2) + N / 2 + 10
	holed[hole] = NAN
	var hg := Pasture3DUtil.graph_eval_grid_gpu(_program(20.0, 0, 0, false), N, N, RECT, holed)
	_check(hg.size() == N * N and is_nan(hg[hole]) and is_finite(hg[hole + 1]), "a NaN cell stays NaN on the GPU")

	var gpu0 := Pasture3DUtil.graph_eval_grid_gpu(_program(30.0, 0, 0, false), N, N, RECT, m)
	var off := _worst(gpu0, Pasture3DUtil.graph_eval_grid(_program(33.0, 0, 0, false), N, N, RECT, m))
	_check(off > GPU_TOL, "control: the CPU at 10%% more feather is %.4f off" % off)
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
