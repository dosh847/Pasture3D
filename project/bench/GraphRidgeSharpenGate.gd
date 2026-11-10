# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphRidgeSharpenGate — the Ridge Sharpen node. Fixture: a tall ridge and a low ridge running along z.
#
# RA  a graph holding it stays native. Control: the oracle twin refuses native.
# RB  native == the GDScript oracle on a 160-row grid (threaded), with NaN cells and a mask.
#     Control: the output differs from the input, so agreeing is not both doing nothing.
# RC  the tall crest rises and its width at half height narrows. Control: amount 0 is the input to the bit.
# RD  cells below their surroundings are unchanged to the bit. Control: such cells exist, and others moved.
# RE  a mask from a Remap leaves the low ridge to the bit and still lifts the tall one.
# RF  the lift along a line agrees across 128/256/512 grids over the same rect. Control: half the radius
#     moves it by more than the tolerance, so the metric can see a radius error.
# RG  Radius and Amount ports driven by Consts reach the kernel, and match typing the values in.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphRidgeSharpenGate.tscn
extends Node

const RECT := Rect2(-256.0, -256.0, 512.0, 512.0)
const RAD := 32.0
const FIELD_TOL := 1.0
const ORACLE_TOL := 1.0e-3

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphRidgeSharpenGate ===\n")
	_ra()
	_rb()
	_rc()
	_rd()
	_re()
	_rf()
	_rg()
	_check(_ran == 7, "all 7 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["RIDGE SHARPEN PASS" if _fail == 0 else "RIDGE SHARPEN FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _field(p_n: int, p_nan := false) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			var a := (w.x + 100.0) / 40.0
			var b := (w.x - 120.0) / 40.0
			var v := 100.0 * exp(-a * a) + 40.0 * exp(-b * b) + 5.0 * sin(w.y * 0.03)
			h[iz * p_n + ix] = NAN if (p_nan and w.length() > 240.0) else v
	return h


func _graph(p_op: StringName, p_radius: float, p_amount: float, p_masked := false) -> Pasture3DTerrainGraph:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	n.set("radius", p_radius)
	n.set("amount", p_amount)
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), n, Pasture3DGraphNodeRegistry.create(&"output")]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	if p_masked:
		var r: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"remap")
		r.set("in_min", 60.0)
		r.set("in_max", 61.0)
		nodes.append(r)
		conns.append(PackedInt32Array([0, 0, 3, 0]))
		conns.append(PackedInt32Array([3, 0, 1, 3]))
	g.nodes = nodes
	g.connections = conns
	return g


func _ra() -> void:
	print("[RA] stays native")
	_check(_graph(&"ridge_sharpen", RAD, 1.0).native_supported(), "the graph is native")
	_check(not _graph(&"dev_ridge_sharpen", RAD, 1.0).native_supported(), "control: the oracle twin is not")
	_ran += 1


func _rb() -> void:
	print("[RB] native == oracle")
	var f := _field(160, true)
	for masked in [false, true]:
		var nat := _graph(&"ridge_sharpen", RAD, 1.5, masked).evaluate(160, 160, RECT, null, f)
		var ora := _graph(&"dev_ridge_sharpen", RAD, 1.5, masked).evaluate(160, 160, RECT, null, f)
		var worst := 0.0
		var moved := 0.0
		var nan_ok := nat.size() == f.size() and ora.size() == f.size()
		if nan_ok:
			for i in f.size():
				if is_nan(f[i]):
					nan_ok = nan_ok and is_nan(nat[i]) and is_nan(ora[i])
					continue
				worst = maxf(worst, absf(nat[i] - ora[i]))
				moved = maxf(moved, absf(nat[i] - f[i]))
		_check(nan_ok and worst <= ORACLE_TOL, "masked=%s worst %.6f m, NaN cells stay NaN" % [masked, worst])
		_check(moved > 5.0, "control: masked=%s output moved %.2f m" % [masked, moved])
	_ran += 1


func _line(p_h: PackedFloat32Array, p_n: int) -> PackedFloat32Array:
	return p_h.slice((p_n / 2) * p_n, (p_n / 2 + 1) * p_n)


## Width at half height of the tall ridge. Only the cells left of world x = 10, its side of the fixture.
func _half_width(p_line: PackedFloat32Array, p_cell: float) -> float:
	var cells := int(p_line.size() * (266.0 / 512.0))
	var peak := -INF
	for x in cells:
		peak = maxf(peak, p_line[x])
	var count := 0
	for x in cells:
		if p_line[x] >= peak * 0.5:
			count += 1
	return count * p_cell


func _max_of(p_line: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_line:
		m = maxf(m, v)
	return m


func _rc() -> void:
	print("[RC] the crest rises and narrows")
	var f := _field(256)
	var o := _graph(&"ridge_sharpen", RAD, 2.0).evaluate(256, 256, RECT, null, f)
	var pk0 := _max_of(_line(f, 256))
	var pk1 := _max_of(_line(o, 256))
	_check(pk1 > pk0 + 10.0, "peak %.2f -> %.2f m" % [pk0, pk1])
	var w0 := _half_width(_line(f, 256), 2.0)
	var w1 := _half_width(_line(o, 256), 2.0)
	_check(w1 < w0, "width at half height %.1f -> %.1f m" % [w0, w1])
	_check(_graph(&"ridge_sharpen", RAD, 0.0).evaluate(256, 256, RECT, null, f) == f, "control: amount 0 is the input to the bit")
	_ran += 1


func _rd() -> void:
	print("[RD] valleys do not move")
	var f := _field(256)
	var o := _graph(&"ridge_sharpen", RAD, 2.0).evaluate(256, 256, RECT, null, f)
	# Amount -1 is the input minus its positive lift, so an unchanged cell there is a cell below its blur.
	var probe := Pasture3DUtil.ridge_sharpen_grid(f, 256, 256, RECT, RAD, -1.0)
	var below := 0
	var above := 0
	var bad := 0
	for i in f.size():
		if probe[i] == f[i]:
			below += 1
			if o[i] != f[i]:
				bad += 1
		else:
			above += 1
	_check(bad == 0, "%d cell(s) below their surroundings moved" % bad)
	_check(below > 1000 and above > 1000, "control: %d cells below, %d above" % [below, above])
	_ran += 1


func _re() -> void:
	print("[RE] the mask gates it")
	var f := _field(256)
	var o := _graph(&"ridge_sharpen", RAD, 2.0, true).evaluate(256, 256, RECT, null, f)
	var low_moved := 0
	var tall_moved := 0.0
	for i in f.size():
		# The Remap clamps to 0 below 60 m, and the fixture's low ridge tops out under 46 m.
		if f[i] < 60.0 and o[i] != f[i]:
			low_moved += 1
		tall_moved = maxf(tall_moved, o[i] - f[i])
	_check(low_moved == 0, "%d cell(s) outside the mask moved" % low_moved)
	_check(tall_moved > 5.0, "control: the masked crest lifted %.2f m" % tall_moved)
	_ran += 1


## The lift along the mid line, interpolated to fixed world positions so grids can be compared.
func _lift_profile(p_n: int, p_radius: float) -> PackedFloat32Array:
	var f := _field(p_n)
	var o := _graph(&"ridge_sharpen", p_radius, 2.0).evaluate(p_n, p_n, RECT, null, f)
	var out := PackedFloat32Array()
	var a := _line(o, p_n)
	var b := _line(f, p_n)
	for k in range(4, 124):
		var t := (float(k) * p_n / 128.0) - 0.5
		var i0 := clampi(int(floor(t)), 0, p_n - 2)
		var u := t - i0
		out.append(lerpf(a[i0] - b[i0], a[i0 + 1] - b[i0 + 1], u))
	return out


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _rf() -> void:
	print("[RF] the look holds across resolutions")
	var mid := _lift_profile(256, RAD)
	var d_lo := _worst(_lift_profile(128, RAD), mid)
	var d_hi := _worst(_lift_profile(512, RAD), mid)
	var d_ctl := _worst(_lift_profile(256, RAD * 0.5), mid)
	_check(d_lo <= FIELD_TOL and d_hi <= FIELD_TOL, "128 vs 256 %.3f m, 512 vs 256 %.3f m (tol %.1f)" % [d_lo, d_hi, FIELD_TOL])
	_check(d_ctl > FIELD_TOL, "control: half the radius moves it %.3f m" % d_ctl)
	_ran += 1


func _rg() -> void:
	print("[RG] driven ports reach the kernel")
	var f := _field(256)
	var typed := _graph(&"ridge_sharpen", RAD, 2.0).evaluate(256, 256, RECT, null, f)
	var driven_graph := _graph(&"ridge_sharpen", 8.0, 0.5)
	var c1: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	var c2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c1.set("value", RAD)
	c2.set("value", 2.0)
	var nodes := driven_graph.nodes.duplicate()
	nodes.append(c1)
	nodes.append(c2)
	driven_graph.nodes = nodes
	var conns := driven_graph.connections.duplicate()
	conns.append(PackedInt32Array([3, 0, 1, 1]))
	conns.append(PackedInt32Array([4, 0, 1, 2]))
	driven_graph.connections = conns
	_check(driven_graph.native_supported(), "the driven graph stays native")
	var driven := driven_graph.evaluate(256, 256, RECT, null, f)
	_check(_worst(driven, typed) <= 1.0e-4, "driven == typed (worst %.6f m)" % _worst(driven, typed))
	var undriven := _graph(&"ridge_sharpen", 8.0, 0.5).evaluate(256, 256, RECT, null, f)
	_check(_worst(undriven, typed) > 1.0, "control: the values under the wires alone differ by %.2f m" % _worst(undriven, typed))
	_ran += 1


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])
