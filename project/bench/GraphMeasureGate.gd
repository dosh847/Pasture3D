# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMeasureGate — the Measure node, and the Output Range SAME_AS_INPUT mode on Curve and Value Ramp.
#
# MA  measure_field == the GDScript oracle in every mode, with and without a selection. Controls: the
#     selection must move the answer (it excludes a spike), and the fixture must tell interpolated
#     percentiles from nearest-rank ones, or "agree" would hold for either rule.
# MB  Measure -> Curve wired two ways: min/max into in_min/in_max (ports 1-2, the in-slot route) with
#     SAME_AS_INPUT, and min/max into out_min/out_max (ports 3-4, the pdrv overflow route, channel 1 on a
#     port >= 4). Native == the same Curve with the window typed in; native vs script no worse than that
#     typed graph's own LUT-vs-sample_baked floor; the output keeps the input's range; the curve moved the mean.
#     Control: a Const in place of the max wire must change the port-4 result, or channel 1 was never read.
# MC  SAME_AS_INPUT == CUSTOM with the window typed in, on Curve and on Value Ramp HEIGHT, both routes.
# MD  edit reach: a live Measure makes the graph INF, a locked one does not; locked outputs the typed values.
# ME  GPU == CPU for the MB graphs; a Measure channel 1 read as a GRID must refuse the GPU, not serve height.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/GraphMeasureGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const SPIKE := 1000.0
const ROUTE_EPS := 1.0e-4
const GPU_TOL := 1.0e-3

var _fail := 0
var _field := PackedFloat32Array()
var _sel := PackedFloat32Array()
var _spike_i := 0


func _ready() -> void:
	print("=== GraphMeasureGate: Measure and Output Range SAME_AS_INPUT ===\n")
	_build_fixture()
	_ma_kernel_vs_oracle()
	_mb_measure_drives_curve()
	_mc_same_as_input()
	_md_reach_and_lock()
	_me_gpu()
	print("\n=== %s (%d failures) ===\n" % ["MEASURE PASS" if _fail == 0 else "MEASURE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## A 60..240 m noise field with NaN outside a circle (a brush footprint), one +1000 m spike, and a selection
## that is open everywhere except on the spike.
func _build_fixture() -> void:
	var fn := FastNoiseLite.new()
	fn.seed = 7
	fn.frequency = 0.008
	_field.resize(GW * GH)
	_sel.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var i := iz * GW + ix
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			_field[i] = NAN if w.length() > 230.0 else 150.0 + 90.0 * fn.get_noise_2d(w.x, w.y)
			_sel[i] = 1.0 if w.x > -120.0 else 0.0 # a band excluded, so selection moves every statistic
	_spike_i = (GH / 2) * GW + GW / 2
	_field[_spike_i] = SPIKE
	_sel[_spike_i] = 0.0


# --- MA ----------------------------------------------------------------------------------------------
func _ma_kernel_vs_oracle() -> void:
	print("[MA] measure_field == oracle in every mode; selection and rank rule are live")
	var cases := [[0, 0.0, 0.0], [1, 1.0, 99.0], [1, 37.3, 62.9], [2, 0.0, 0.0]]
	for cs in cases:
		for use_sel in [false, true]:
			var sel := _sel if use_sel else PackedFloat32Array()
			var k: PackedFloat64Array = Pasture3DUtil.measure_field(_field, sel, cs[0], cs[1], cs[2])
			var o: PackedFloat64Array = Pasture3DGraphNodeDevMeasure.measure_gd(_field, sel, cs[0], cs[1], cs[2])
			var d := maxf(absf(k[0] - o[0]), absf(k[1] - o[1]))
			print("    mode %d (%5.1f, %5.1f) sel %-5s  a %10.4f  b %10.4f  n %6d  |kernel - oracle| %s"
					% [cs[0], cs[1], cs[2], str(use_sel), k[0], k[1], int(k[2]), str(d)])
			if d > 1.0e-9 or k[2] != o[2]:
				_fail += 1; print("      !! the kernel and the oracle disagree")
			if not (is_finite(k[0]) and is_finite(k[1])):
				_fail += 1; print("      !! a NaN cell reached the statistic")
	# Controls.
	var full: PackedFloat64Array = Pasture3DUtil.measure_field(_field, PackedFloat32Array(), 0, 0.0, 0.0)
	var picked: PackedFloat64Array = Pasture3DUtil.measure_field(_field, _sel, 0, 0.0, 0.0)
	print("    control: max without selection %.1f (want %.0f), with %.1f (want < 300)" % [full[1], SPIKE, picked[1]])
	if full[1] != SPIKE or picked[1] >= 300.0:
		_fail += 1; print("      !! the selection did not exclude the spike")
	var interp: PackedFloat64Array = Pasture3DUtil.measure_field(_field, _sel, 1, 37.3, 62.9)
	var nearest := _nearest_rank(_sel, 37.3)
	print("    control: interpolated p37.3 %.6f vs nearest-rank %.6f (want them to differ)" % [interp[0], nearest])
	if absf(interp[0] - nearest) <= 1.0e-6:
		_fail += 1; print("      !! the fixture cannot tell the rank rules apart")
	var empty: PackedFloat64Array = Pasture3DUtil.measure_field(_field, Pasture3DGraphOps.zeros(GW * GH), 0, 0.0, 0.0)
	print("    empty selection -> a %.1f b %.1f n %d (want 0, 0, 0)" % [empty[0], empty[1], int(empty[2])])
	if empty[0] != 0.0 or empty[1] != 0.0 or empty[2] != 0.0:
		_fail += 1; print("      !! an empty selection did not answer 0, 0")


func _nearest_rank(p_sel: PackedFloat32Array, p_pct: float) -> float:
	var v := PackedFloat64Array()
	for i in _field.size():
		if is_finite(_field[i]) and p_sel[i] >= 0.5:
			v.append(_field[i])
	v.sort()
	return v[clampi(int(round(p_pct / 100.0 * (v.size() - 1))), 0, v.size() - 1)]


# --- MB ----------------------------------------------------------------------------------------------
func _mb_measure_drives_curve() -> void:
	print("[MB] Measure -> Curve, through the in-slot ports and through the port >= 4 overflow")
	var lo := INF
	var hi := -INF
	for v in _field:
		if is_finite(v):
			lo = minf(lo, v); hi = maxf(hi, v)
	# The FLOOR: the same curve over the same window typed in, no Measure. The native route reads a 256-entry
	# LUT and the script route reads sample_baked exactly, so they already differ at the curve's kinks by
	# about slope change * step / 4 * window (0.2 * 1/255 / 4 * 912 m = 0.18 m here). Measure must add
	# nothing beyond that difference.
	var typed := _typed_curve_graph(lo, hi)
	var t_native := typed.evaluate(GW, GH, RECT, null, _field)
	typed.force_gdscript_evaluation = true
	var floor_d := _max_abs_diff(t_native, typed.evaluate(GW, GH, RECT, null, _field))
	print("    floor: typed window, no Measure, |native - script| %.6f (the LUT, not Measure)" % floor_d)
	for label in ["in-window", "out-range"]:
		var g := _measure_curve_graph(label == "out-range", false)
		if not g.native_supported():
			_fail += 1
			print("    %s !! native_supported() = FALSE: %s" % [label, str(g.native_block_report())])
			continue
		var native := g.evaluate(GW, GH, RECT, null, _field)
		g.force_gdscript_evaluation = true
		var script := g.evaluate(GW, GH, RECT, null, _field)
		var d := _max_abs_diff(native, script)
		var r := _range_of(native)
		var shift := _mean_of(native) - _mean_of(_field)
		print("    %-9s |native - script| %.6f  out range %.3f .. %.3f (input %.3f .. %.3f)  mean moved %.2f m"
				% [label, d, r.x, r.y, lo, hi, shift])
		if d > floor_d + ROUTE_EPS:
			_fail += 1; print("      !! the native and script routes disagree beyond the typed-window floor")
		var tn := _max_abs_diff(native, t_native)
		print("      |measured - typed| native %.6f" % tn)
		if tn > ROUTE_EPS:
			_fail += 1; print("      !! the measured window is not the typed one")
		if absf(r.x - lo) > 1.0e-3 or absf(r.y - hi) > 1.0e-3:
			_fail += 1; print("      !! the output did not keep the input's range")
		if absf(shift) < 1.0:
			_fail += 1; print("      !! the curve did not redistribute anything (control dead)")
	# CONTROL for the overflow channel: a Const of 500 into out_max must change the result.
	var ctl := _measure_curve_graph(true, true)
	var with_const := ctl.evaluate(GW, GH, RECT, null, _field)
	var wired := _measure_curve_graph(true, false).evaluate(GW, GH, RECT, null, _field)
	var c := _max_abs_diff(with_const, wired)
	print("    control: Const 500 on out_max moved the output by %.2f m (want > 10)" % c)
	if c <= 10.0:
		_fail += 1; print("      !! port 4 ignores its wire, so the Measure max reaching it proved nothing")


## Input -> Curve(y = x^2) -> Output, a Measure on the Input. `p_out_ports`: min/max drive out_min/out_max
## (3, 4) with the curve's input window typed to the field's range; otherwise they drive in_min/in_max
## (1, 2) with SAME_AS_INPUT. `p_const_max` replaces the max wire with a Const 500.
func _measure_curve_graph(p_out_ports: bool, p_const_max: bool) -> Pasture3DTerrainGraph:
	var curve := Pasture3DGraphNodeCurve.new()
	curve.curve = _square_curve()
	var m := Pasture3DGraphNodeMeasure.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), curve, Pasture3DGraphNodeOutput.new(), m]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0]), PackedInt32Array([0, 0, 3, 0])]
	if p_out_ports:
		var r := Pasture3DUtil.measure_field(_field, PackedFloat32Array(), 0, 0.0, 0.0)
		curve.input_min = r[0]
		curve.input_max = r[1]
		conns.append(PackedInt32Array([3, 0, 1, 3]))
		if p_const_max:
			var k := Pasture3DGraphNodeConst.new()
			k.value = 500.0
			nodes.append(k)
			conns.append(PackedInt32Array([4, 0, 1, 4]))
		else:
			conns.append(PackedInt32Array([3, 1, 1, 4]))
	else:
		curve.output_range = Pasture3DGraphNodeCurve.OutputRange.SAME_AS_INPUT
		curve.output_min = -999.0 # ignored in SAME_AS_INPUT; a leak shows as a wrong range
		curve.output_max = 999.0
		conns.append(PackedInt32Array([3, 0, 1, 1]))
		conns.append(PackedInt32Array([3, 1, 1, 2]))
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


## Input -> Curve(y = x^2, window [p_lo, p_hi] typed in for both input and output) -> Output.
func _typed_curve_graph(p_lo: float, p_hi: float) -> Pasture3DTerrainGraph:
	var curve := Pasture3DGraphNodeCurve.new()
	curve.curve = _square_curve()
	curve.input_min = p_lo
	curve.input_max = p_hi
	curve.output_min = p_lo
	curve.output_max = p_hi
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = [Pasture3DGraphNodeInput.new(), curve, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	return g


func _square_curve() -> Curve:
	var c := Curve.new()
	for k in 11:
		var x := k / 10.0
		c.add_point(Vector2(x, x * x), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return c


# --- MC ----------------------------------------------------------------------------------------------
func _mc_same_as_input() -> void:
	print("[MC] SAME_AS_INPUT == CUSTOM with the window typed in, Curve and Value Ramp, both routes")
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0))
	grad.set_color(1, Color(1, 1, 1))
	grad.add_point(0.5, Color(0.15, 0.15, 0.15))
	for kind in ["curve", "ramp"]:
		for force_gd in [false, true]:
			var same := _single(kind, true, grad)
			var typed := _single(kind, false, grad)
			same.force_gdscript_evaluation = force_gd
			typed.force_gdscript_evaluation = force_gd
			var a := same.evaluate(GW, GH, RECT, null, _field)
			var b := typed.evaluate(GW, GH, RECT, null, _field)
			var d := _max_abs_diff(a, b)
			var ctl := _max_abs_diff(a, _field)
			print("    %-5s %-6s |same - typed| %.6f  control |same - input| %.2f (want > 1)"
					% [kind, "script" if force_gd else "native", d, ctl])
			if d > ROUTE_EPS:
				_fail += 1; print("      !! SAME_AS_INPUT is not the input window")
			if ctl <= 1.0:
				_fail += 1; print("      !! control dead: the node passed the input through")


## One Curve or Value Ramp on Input, window 60..240. `p_same`: SAME_AS_INPUT with a decoy output range;
## otherwise CUSTOM with the output typed to 60..240.
func _single(p_kind: String, p_same: bool, p_grad: Gradient) -> Pasture3DTerrainGraph:
	var node: Pasture3DGraphNode
	if p_kind == "curve":
		var c := Pasture3DGraphNodeCurve.new()
		c.curve = _square_curve()
		c.input_min = 60.0
		c.input_max = 240.0
		c.output_min = -5.0 if p_same else 60.0
		c.output_max = 5.0 if p_same else 240.0
		if p_same:
			c.output_range = Pasture3DGraphNodeCurve.OutputRange.SAME_AS_INPUT
		node = c
	else:
		var r := Pasture3DGraphNodeValueRamp.new()
		r.gradient = p_grad
		r.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.HEIGHT
		r.input_min = 60.0
		r.input_max = 240.0
		r.height_min = -5.0 if p_same else 60.0
		r.height_max = 5.0 if p_same else 240.0
		if p_same:
			r.output_range = Pasture3DGraphNodeValueRamp.OutputRange.SAME_AS_INPUT
		node = r
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), node, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	return g


# --- MD ----------------------------------------------------------------------------------------------
func _md_reach_and_lock() -> void:
	print("[MD] a live Measure is non-local; a locked one is a constant")
	var g := _measure_curve_graph(false, false)
	var live := g.edit_reach()
	var m: Pasture3DGraphNodeMeasure = g.nodes[3]
	m.locked = true
	m.locked_a = 100.0
	m.locked_b = 200.0
	var locked := g.edit_reach()
	print("    graph edit_reach live %s, locked %s (want INF, finite)" % [str(live), str(locked)])
	if not is_inf(live) or is_inf(locked):
		_fail += 1; print("      !! the reach does not follow the lock")
	var out := g.evaluate(GW, GH, RECT, null, _field)
	var r := _range_of(out)
	print("    locked 100..200 -> output range %.3f .. %.3f (want 100 .. 200)" % [r.x, r.y])
	if absf(r.x - 100.0) > 1.0e-3 or absf(r.y - 200.0) > 1.0e-3:
		_fail += 1; print("      !! the locked values did not reach the curve")


# --- ME ----------------------------------------------------------------------------------------------
func _me_gpu() -> void:
	print("[ME] GPU == CPU through both wirings; channel 1 as a grid refuses")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! graph_eval_grid_gpu is not bound")
		return
	var bare := Pasture3DTerrainGraph.create_empty()
	var bn: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	bare.nodes = bn
	bare.connections = [PackedInt32Array([0, 0, 1, 0])]
	if (Pasture3DUtil.graph_eval_grid_gpu(bare.compile_graph_program(), GW, GH, RECT, _field) as PackedFloat32Array).is_empty():
		print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
		return
	for label in ["in-window", "out-range"]:
		var g := _measure_curve_graph(label == "out-range", false)
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH, RECT, _field)
		if gpu.is_empty():
			_fail += 1; print("    %-9s !! the GPU refused a Measure read as a scalar" % label)
			continue
		var d := _max_abs_diff(gpu, g.evaluate(GW, GH, RECT, null, _field))
		print("    %-9s max |gpu - cpu| %.6f" % [label, d])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU disagrees with the CPU")
	# Measure max into a Blend's height input: channel 1 as a GRID, which this plan cannot hold.
	var blend := Pasture3DGraphNodeBlend.new()
	var m := Pasture3DGraphNodeMeasure.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), blend, Pasture3DGraphNodeOutput.new(), m]
	var g2 := Pasture3DTerrainGraph.create_empty()
	g2.nodes = nodes
	g2.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0]), PackedInt32Array([0, 0, 3, 0]),
			PackedInt32Array([3, 1, 1, 1])]
	var refused: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g2.compile_graph_program(), GW, GH, RECT, _field)
	print("    channel 1 into a grid port: GPU returned %d cells (want 0, a refusal)" % refused.size())
	if not refused.is_empty():
		_fail += 1; print("      !! the GPU served a secondary channel it holds no buffer for")


# --- helpers -----------------------------------------------------------------------------------------
func _range_of(p_a: PackedFloat32Array) -> Vector2:
	var lo := INF
	var hi := -INF
	for v in p_a:
		if is_finite(v):
			lo = minf(lo, v); hi = maxf(hi, v)
	return Vector2(lo, hi)


func _mean_of(p_a: PackedFloat32Array) -> float:
	var s := 0.0
	var n := 0
	for v in p_a:
		if is_finite(v):
			s += v; n += 1
	return s / maxf(n, 1)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) and is_nan(y):
			continue
		if is_nan(x) or is_nan(y):
			return INF
		m = maxf(m, absf(x - y))
	return m
