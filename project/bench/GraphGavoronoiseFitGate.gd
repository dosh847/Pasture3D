# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGavoronoiseFitGate — Gavoronoise fits the brush it sits on, and Variation breaks up the pattern.
#
# FA  scale: a base and the same base x4 (offset too) give gullies x4, so the look fits any brush.
#     Control: with Fit off and one Amplitude, the two do NOT scale together.
# FB  measured == typing the true range into Amplitude, on a base that starts at 0.
# FC  Measure -> Min/Max == fit, stays native, and wired Min/Max sets the generator's range.
#     Control: the values under the wires alone differ.
# FD  a saved node (fit off, variation 0) is bit-identical to the kernel's legacy call; palette nodes fit.
# FE  Variation moves the pattern, and a different seed gives a different variation.
# FF  kernel == oracle, base form at 128 rows (threaded), generator at 32 (slow oracle), fit and variation, with NaN holes.
# FG  GPU == CPU, for measured, uploaded and varied. Windowed only.
#
# Run WINDOWED for FG: Godot_v4.7-stable_win64_console.exe --path project res://bench/GraphGavoronoiseFitGate.tscn
extends Node

const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const TOL := 1.0e-3
const GPU_TOL := 2.0e-2

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphGavoronoiseFitGate ===\n")
	_fa()
	_fb()
	_fc()
	_fd()
	_fe()
	_ff()
	_fg()
	_check(_ran == 7, "all 7 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["GAVORONOISE FIT PASS" if _fail == 0 else "GAVORONOISE FIT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## A cone from p_lo to p_lo + p_h.
func _cone(p_n: int, p_lo: float, p_h: float, p_nan := false) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			var v := p_lo + p_h * clampf(1.0 - w.length() / 240.0, 0.0, 1.0)
			o[iz * p_n + ix] = NAN if (p_nan and w.length() > 230.0) else v
	return o


func _gav(p_fit: bool, p_var := 0.0) -> Pasture3DGraphNodeGavoronoise:
	var n := Pasture3DGraphNodeGavoronoise.new()
	n.fit_to_base = p_fit
	n.variation = p_var
	n.amplitude = 200.0
	n.frequency = 1.0 / 80.0
	n.erosion_strength = 0.2
	n.z_cut_min = 0.1
	n.z_cut_max = 0.8
	n.octaves = 4
	return n


func _wired(p_n: Pasture3DGraphNode, p_extra: Array = [], p_conns: Array = []) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_n, Pasture3DGraphNodeOutput.new()]
	nodes.append_array(p_extra)
	g.nodes = nodes
	var c: Array = [PackedInt32Array([0, 0, 1, 3]), PackedInt32Array([1, 0, 2, 0])]
	c.append_array(p_conns)
	g.connections = c
	return g


func _alone(p_n: Pasture3DGraphNode, p_extra: Array = [], p_conns: Array = []) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [p_n, Pasture3DGraphNodeOutput.new()]
	nodes.append_array(p_extra)
	g.nodes = nodes
	var c: Array = [PackedInt32Array([0, 0, 1, 0])]
	c.append_array(p_conns)
	g.connections = c
	return g


func _f32(p_v: float) -> float:
	return float(PackedFloat32Array([p_v])[0])


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		if is_nan(p_a[i]) != is_nan(p_b[i]):
			return INF
		if not is_nan(p_a[i]):
			w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _delta(p_o: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var d := PackedFloat32Array()
	d.resize(p_o.size())
	for i in p_o.size():
		d[i] = p_o[i] - p_b[i]
	return d


func _scaled(p_a: PackedFloat32Array, p_s: float) -> PackedFloat32Array:
	var d := p_a.duplicate()
	for i in d.size():
		d[i] *= p_s
	return d


func _fa() -> void:
	print("[FA] the gullies scale with the brush")
	var small := _cone(128, 0.0, 100.0)
	var big := _cone(128, 50.0, 400.0)
	var ref := _delta(_wired(_gav(true)).evaluate(128, 128, RECT, null, small), small)
	var fit := _delta(_wired(_gav(true)).evaluate(128, 128, RECT, null, big), big)
	# float32 rounding of the base at 450 m reaches the slope, so this is not ulp-tight.
	var d := _worst(_scaled(fit, 0.25), ref)
	_check(d <= 0.05, "400 m at offset 50 / 4 == 100 m: worst %.5f m" % d)
	var rmax := 0.0
	for v in ref:
		rmax = maxf(rmax, absf(v))
	_check(rmax > 1.0, "control: the gullies are %.2f m deep" % rmax)
	var off := _delta(_wired(_gav(false)).evaluate(128, 128, RECT, null, big), big)
	var off_small := _delta(_wired(_gav(false)).evaluate(128, 128, RECT, null, small), small)
	_check(_worst(_scaled(off, 0.25), off_small) > 1.0, "control: Fit off with one Amplitude does not scale")
	_ran += 1


func _fb() -> void:
	print("[FB] measured == the true range typed in")
	var b := _cone(128, 0.0, 330.0)
	var measured := -INF
	for v in b:
		measured = maxf(v, measured)
	var typed := _gav(false)
	typed.amplitude = measured
	var out := _wired(typed).evaluate(128, 128, RECT, null, b)
	var d := _worst(_wired(_gav(true)).evaluate(128, 128, RECT, null, b), out)
	_check(d <= 1.0e-4, "worst %.6f m" % d)
	_check(_worst(_wired(_gav(false)).evaluate(128, 128, RECT, null, b), out) > 0.5, "control: the 200 m Amplitude differs")
	_ran += 1


func _fc() -> void:
	print("[FC] Measure drives Min and Max")
	var b := _cone(128, 20.0, 300.0)
	var m: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"measure")
	var g := _wired(_gav(false), [m], [PackedInt32Array([0, 0, 3, 0]), PackedInt32Array([3, 0, 1, 4]), PackedInt32Array([3, 1, 1, 5])])
	_check(g.native_supported(), "Measure -> Min/Max stays native")
	var fit := _wired(_gav(true)).evaluate(128, 128, RECT, null, b)
	var d := _worst(g.evaluate(128, 128, RECT, null, b), fit)
	_check(d <= 1.0e-4, "== Fit To Base, worst %.6f m" % d)
	_check(_worst(_wired(_gav(false)).evaluate(128, 128, RECT, null, b), fit) > 0.5, "control: the Amplitude alone differs")
	var c1: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	var c2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c1.set("value", 500.0)
	c2.set("value", 600.0)
	var o := _alone(_gav(false), [c1, c2], [PackedInt32Array([2, 0, 0, 4]), PackedInt32Array([3, 0, 0, 5])]).evaluate(128, 128, RECT, null, null)
	var lo := INF
	var hi := -INF
	for v in o:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check(lo > 450.0 and hi < 650.0 and hi - lo > 20.0, "generator with Min 500, Max 600 spans %.1f..%.1f" % [lo, hi])
	_ran += 1


func _fd() -> void:
	print("[FD] saved nodes keep their look; palette nodes fit")
	var b := _cone(128, 0.0, 300.0)
	var kp := {"amplitude": 200.0, "frequency": _f32(1.0 / 80.0), "octaves": 4, "erosion_strength": _f32(0.2),
			"z_cut_min": _f32(0.1), "z_cut_max": _f32(0.8)}
	var legacy := Pasture3DUtil.gavoronoise_base_grid(128, 128, RECT, kp, b, 0.0)
	_check(_wired(_gav(false)).evaluate(128, 128, RECT, null, b) == legacy, "Fit off == the kernel called without the new keys, to the bit")
	_check(not Pasture3DGraphNodeGavoronoise.new().fit_to_base, "a loaded node (no stored value) stays off")
	_check(Pasture3DGraphNodeRegistry.create(&"gavoronoise").fit_to_base, "a palette node starts on")
	_ran += 1


func _fe() -> void:
	print("[FE] Variation changes the pattern")
	var b := _cone(128, 0.0, 300.0)
	var off := _wired(_gav(true)).evaluate(128, 128, RECT, null, b)
	var on := _wired(_gav(true, 0.8)).evaluate(128, 128, RECT, null, b)
	_check(_worst(on, off) > 1.0, "0.8 moves the result %.2f m" % _worst(on, off))
	var other := _gav(true, 0.8)
	other.seed = 5
	var ctl := _gav(true)
	ctl.seed = 5
	var other_d := _delta(_wired(other).evaluate(128, 128, RECT, null, b), _wired(ctl).evaluate(128, 128, RECT, null, b))
	_check(_worst(other_d, _delta(on, off)) > 0.5, "another seed varies differently")
	var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c.set("value", 0.8)
	var driven := _wired(_gav(true), [c], [PackedInt32Array([3, 0, 1, 6])])
	_check(driven.native_supported() and _worst(driven.evaluate(128, 128, RECT, null, b), on) <= 1.0e-4, "the Variation port reaches the kernel")
	var gen := _worst(_alone(_gav(false, 0.8)).evaluate(128, 128, RECT, null, null), _alone(_gav(false)).evaluate(128, 128, RECT, null, null))
	_check(gen > 1.0, "the generator form varies too (%.2f m)" % gen)
	_ran += 1


func _dev(p_n: Pasture3DGraphNodeGavoronoise) -> Pasture3DGraphNodeDevGavoronoise:
	var kp := p_n.kernel_params(p_n.amplitude, p_n.angle_deg, p_n.frequency)
	var dev := Pasture3DGraphNodeDevGavoronoise.new()
	for k in kp:
		dev.set(k, kp[k])
	return dev


func _ff() -> void:
	print("[FF] kernel == oracle")
	var b := _cone(128, 30.0, 250.0, true)
	for cfg in [[true, 0.0], [true, 0.7], [false, 0.7]]:
		var n := _gav(cfg[0], cfg[1])
		var kp := n.kernel_params(n.amplitude, n.angle_deg, n.frequency)
		var nat := Pasture3DUtil.gavoronoise_base_grid(128, 128, RECT, kp, b, 0.0)
		var d := _worst(nat, _dev(n).solve_base(128, 128, RECT, b))
		_check(d <= TOL, "base fit=%s var=%.1f worst %.6f m" % [cfg[0], cfg[1], d])
		_check(_worst(nat, b) > 0.5, "control: the kernel changed the base")
		var gen := Pasture3DUtil.gavoronoise_grid(32, 32, RECT, kp)
		var dg := _worst(gen, _dev(n).solve(32, 32, RECT))
		_check(dg <= TOL, "generator fit=%s var=%.1f worst %.6f m" % [cfg[0], cfg[1], dg])
	_ran += 1


func _fg() -> void:
	print("[FG] GPU == CPU")
	_ran += 1
	var b := _cone(128, 30.0, 250.0)
	var bare := Pasture3DTerrainGraph.create_empty()
	var bn: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	bare.nodes = bn
	bare.connections = [PackedInt32Array([0, 0, 1, 0])]
	if Pasture3DUtil.graph_eval_grid_gpu(bare.compile_graph_program(), 128, 128, RECT, b).is_empty():
		print("    NO-SIGNAL: no local RenderingDevice, GPU route unverified. Re-run windowed.")
		return
	for g: Pasture3DTerrainGraph in [_wired(_gav(true)), _wired(_gav(false)), _wired(_gav(true, 0.7)), _alone(_gav(false, 0.7))]:
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), 128, 128, RECT, b)
		var d := _worst(gpu, g.evaluate(128, 128, RECT, null, b))
		_check(d <= GPU_TOL, "worst %.5f m" % d)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])
