# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphCurveGpuGate — the Curve GPU mode and its LUT binding (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md Phase 2a).
#
#   R  The route is real. A Curve graph called DIRECTLY through graph_eval_grid_gpu comes back non-empty (through
#      evaluate() a refusal would fall back to the CPU and match perfectly). Control: a GPU-refused program
#      (Leveler channel 1) comes back empty, so a refusal is recognisable.
#   A  Native vs GPU over a sweep of curves x windows (normal, reversed, degenerate) x amounts, on a surface with
#      NaN holes; the NaN pattern must match exactly. The tolerance is EPS plus the curve's steepest gain times
#      ULP_IN: the GPU takes curve X in float32, and a flat 1e-4 failed a steep step on rounding alone (worst
#      2.2e-4 m at ~45 m/m gain). Control: both output bounds +1 m on the GPU must land OUTSIDE that tolerance.
#   B  A driven parameter: a Const wired into out_max moves the GPU result the same as the native one.
#      Control: the undriven GPU result must differ from the driven native one by more than EPS.
#   C  Pass-through: no Curve, and amount 0, both return the input bit-exact on the GPU (the host plans a COPY).
#   E  Every criterion above completed.
#
# WINDOWED. Headless, the GPU criteria report SKIPPED and the gate prints PARTIAL, never PASS.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphCurveGpuGate.tscn
extends Node

const GW := 131
const GH := 97
const RECT := Rect2(-240.0, 75.0, 520.0, 388.0)
const EPS := 1.0e-4
const ULP_IN := 2.0e-5 # a few float32 ulps of the input curve X, in metres of input, at the fixture's <= 150 m
const CRITERIA := ["R", "A", "B", "C"]

var _fail := 0
var _seen := {}
var _skipped := {}


func _ready() -> void:
	print("=== GraphCurveGpuGate: Curve GPU mode (spec Phase 2a) ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	var surf := _terrain()
	if Pasture3DUtil.graph_eval_grid_gpu(_io_graph().compile_graph_program(), GW, GH, RECT, surf).is_empty():
		print("    NO-SIGNAL: the GPU refused a bare in->out graph (no RenderingDevice). Every criterion SKIPPED.")
		for name in CRITERIA:
			_skipped[name] = true
	else:
		_run("R", _r_route.bind(surf))
		_run("A", _a_sweep.bind(surf))
		_run("B", _b_driven.bind(surf))
		_run("C", _c_pass_through.bind(surf))

	for name in CRITERIA:
		if not _seen.has(name) and not _skipped.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	var verdict := "FAIL" if _fail > 0 else ("PARTIAL" if not _skipped.is_empty() else "PASS")
	print("=== CURVE GPU %s (%d failures, %d skipped) ===" % [verdict, _fail, _skipped.size()])
	get_tree().quit(0 if _fail == 0 else 1)


func _run(p_name: String, p_fn: Callable) -> void:
	p_fn.call()
	if not _seen.has(p_name) and not _skipped.has(p_name):
		print("!! [%s] returned without reporting" % p_name)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


# --- fixtures ----------------------------------------------------------------------------------------
## Heights spanning about -20..140 m, so every window below clips on both sides somewhere, with NaN holes.
func _terrain() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var v := 60.0 + 70.0 * sin(ix * 0.071) * cos(iz * 0.053) + 10.0 * sin((ix + iz) * 0.31)
			if (ix * 7 + iz * 13) % 97 == 0:
				v = NAN
			s[iz * GW + ix] = v
	return s


func _curves() -> Array:
	var linear := Curve.new()
	linear.add_point(Vector2(0.0, 0.0))
	linear.add_point(Vector2(1.0, 1.0))
	var s_curve := Curve.new()
	s_curve.add_point(Vector2(0.0, 0.0), 0.0, 0.0)
	s_curve.add_point(Vector2(0.5, 0.15), 0.0, 0.0)
	s_curve.add_point(Vector2(0.8, 0.95), 0.0, 0.0)
	s_curve.add_point(Vector2(1.0, 1.0), 0.0, 0.0)
	var stepped := Curve.new()
	stepped.add_point(Vector2(0.0, 1.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	stepped.add_point(Vector2(0.48, 1.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	stepped.add_point(Vector2(0.52, 0.2), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	stepped.add_point(Vector2(1.0, 0.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return [["linear", linear], ["s", s_curve], ["stepped", stepped]]


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g


func _curve_node(p_curve: Curve, p_cfg: Dictionary) -> Pasture3DGraphNodeCurve:
	var c := Pasture3DGraphNodeCurve.new()
	c.curve = p_curve
	c.input_min = p_cfg["in_min"]
	c.input_max = p_cfg["in_max"]
	c.output_min = p_cfg["out_min"]
	c.output_max = p_cfg["out_max"]
	c.amount = p_cfg["amount"]
	return c


## Input -> Curve -> Output, optionally with a Const driving out_max (Curve input port 4).
func _graph(p_curve: Curve, p_cfg: Dictionary, p_driven_out_max = null) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _curve_node(p_curve, p_cfg),
			Pasture3DGraphNodeOutput.new()]
	var conns := [[0, 0, 1, 0], [1, 0, 2, 0]]
	if p_driven_out_max != null:
		var k := Pasture3DGraphNodeConst.new()
		k.value = float(p_driven_out_max)
		nodes.append(k)
		conns.append([3, 0, 1, 4])
	g.nodes = nodes
	g.connections = conns
	return g


func _refused_graph(p_channel: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeLeveler.new(),
			Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, p_channel, 2, 0]]
	return g


func _cpu(p_graph: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_graph.compile_graph_program(), GW, GH, RECT, p_surf)


func _gpu(p_graph: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_graph.compile_graph_program(), GW, GH, RECT, p_surf)


## Worst |a - b| over finite cells; INF when the NaN patterns differ or a grid is missing.
func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.size() != GW * GH:
		return INF
	var w := 0.0
	for i in p_a.size():
		var an := is_nan(p_a[i])
		if an or is_nan(p_b[i]):
			if an != is_nan(p_b[i]):
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _bit_equal(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> bool:
	return p_a.size() == p_b.size() and p_a.to_byte_array() == p_b.to_byte_array()


# --- R. route ----------------------------------------------------------------------------------------
func _r_route(p_surf: PackedFloat32Array) -> void:
	print("[R] a Curve graph is served by the GPU directly")
	var refused := _gpu(_refused_graph(1), p_surf)
	var served := _gpu(_refused_graph(0), p_surf)
	_control(refused.is_empty() and served.size() == GW * GH,
			"Leveler channel 1 returned %d cells (want 0); channel 0 returned %d (want %d)" % [refused.size(), served.size(), GW * GH])
	var cfg := {"in_min": 0.0, "in_max": 100.0, "out_min": 0.0, "out_max": 100.0, "amount": 1.0}
	var got := _gpu(_graph(_curves()[1][1], cfg), p_surf)
	_check("R", got.size() == GW * GH, "Curve graph returned %d cells from the GPU (want %d)" % [got.size(), GW * GH])


# --- A. sweep ----------------------------------------------------------------------------------------
func _a_sweep(p_surf: PackedFloat32Array) -> void:
	print("[A] native == GPU within %s m + gain x ulp, curves x windows x amounts" % str(EPS))
	var windows := [
		{"in_min": 0.0, "in_max": 100.0, "out_min": 0.0, "out_max": 100.0},
		{"in_min": 120.0, "in_max": -10.0, "out_min": 5.0, "out_max": 80.0}, # reversed input window
		{"in_min": 40.0, "in_max": 40.0, "out_min": -30.0, "out_max": 90.0}, # degenerate: every cell reads X = 0
		{"in_min": 10.0, "in_max": 90.0, "out_min": 150.0, "out_max": -25.0}, # inverted output
	]
	var cases := 0
	var passed := 0
	var worst := 0.0
	var worst_ratio := 0.0
	var worst_control := INF
	for cv in _curves():
		for win in windows:
			for amt in [1.0, 0.37]:
				var cfg: Dictionary = win.duplicate()
				cfg["amount"] = amt
				var g := _graph(cv[1], cfg)
				var cpu := _cpu(g, p_surf)
				var gpu := _gpu(g, p_surf)
				var w := _worst(gpu, cpu)
				var tol := _tolerance(g.nodes[1] as Pasture3DGraphNodeCurve, cfg)
				cases += 1
				worst = maxf(worst, w)
				worst_ratio = maxf(worst_ratio, w / tol)
				if w <= tol:
					passed += 1
				else:
					print("    !! %s %s amount %s: worst |GPU - native| %s (tolerance %s)" % [cv[0], str(win), str(amt), str(w), str(tol)])
				# CONTROL: shift BOTH output bounds. Moving out_max alone is invisible wherever the curve reads
				# Y = 0 -- every cell of the degenerate window on a curve starting at 0 -- and killed the control.
				var bumped: Dictionary = cfg.duplicate()
				bumped["out_min"] = float(cfg["out_min"]) + 1.0
				bumped["out_max"] = float(cfg["out_max"]) + 1.0
				worst_control = minf(worst_control, _worst(_gpu(_graph(cv[1], bumped), p_surf), cpu) / tol)
	_check("A", passed == cases, "%d of %d cases within tolerance; worst %s m, worst error/tolerance %s" % [passed, cases, str(worst), str(worst_ratio)])
	_control(worst_control > 1.0, "outputs +1 m: smallest worst error/tolerance %s (want > 1)" % str(worst_control))


## EPS, widened by the curve's steepest gain times one float32 ulp of the input. The GPU computes the curve X
## in float32 where the kernel uses double, so a steep segment multiplies an input rounding of ~1.5e-5 m (at
## 150 m) into the output: the stepped fixture gains ~45 m per metre. A flat EPS would fail on arithmetic,
## and a flat loose one would hide a real change on a gentle curve.
func _tolerance(p_node: Pasture3DGraphNodeCurve, p_cfg: Dictionary) -> float:
	var lut: PackedFloat32Array = p_node.native_lower()["lut"]
	var span_in := absf(float(p_cfg["in_max"]) - float(p_cfg["in_min"]))
	if lut.size() < 2 or span_in <= 1.0e-9:
		return EPS
	var step := 0.0
	for k in lut.size() - 1:
		step = maxf(step, absf(lut[k + 1] - lut[k]))
	var gain := step * (lut.size() - 1) * absf(float(p_cfg["out_max"]) - float(p_cfg["out_min"])) / span_in
	return EPS + gain * float(p_cfg["amount"]) * ULP_IN


# --- B. driven parameter -----------------------------------------------------------------------------
func _b_driven(p_surf: PackedFloat32Array) -> void:
	print("[B] a Const driving out_max moves the GPU as it moves native")
	var cfg := {"in_min": 0.0, "in_max": 100.0, "out_min": 0.0, "out_max": 100.0, "amount": 1.0}
	var cv: Curve = _curves()[1][1]
	var cpu := _cpu(_graph(cv, cfg, 37.5), p_surf)
	var gpu := _gpu(_graph(cv, cfg, 37.5), p_surf)
	var w := _worst(gpu, cpu)
	_check("B", w <= EPS, "driven out_max 37.5: worst |GPU - native| %s m" % str(w))
	var undriven := _gpu(_graph(cv, cfg), p_surf)
	var wc := _worst(undriven, cpu)
	_control(wc > EPS, "undriven GPU vs driven native: worst %s m (want > %s)" % [str(wc), str(EPS)])


# --- C. pass-through ---------------------------------------------------------------------------------
func _c_pass_through(p_surf: PackedFloat32Array) -> void:
	print("[C] no Curve, and amount 0, return the input bit-exact on the GPU")
	var cfg := {"in_min": 0.0, "in_max": 100.0, "out_min": 0.0, "out_max": 100.0, "amount": 1.0}
	var no_curve := _gpu(_graph(null, cfg), p_surf)
	var zero_cfg: Dictionary = cfg.duplicate()
	zero_cfg["amount"] = 0.0
	var zero_amt := _gpu(_graph(_curves()[1][1], zero_cfg), p_surf)
	_check("C", _bit_equal(no_curve, p_surf) and _bit_equal(zero_amt, p_surf),
			"no Curve bit-exact: %s; amount 0 bit-exact: %s" % [str(_bit_equal(no_curve, p_surf)), str(_bit_equal(zero_amt, p_surf))])
