# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphCoastalErosionGate — the Coastal Erosion node. Fixture: 128² cells of 4 m, a straight coast along
# x = 0 with sea (-10 m) at x < 0. North half (z < 0): a +20 m plateau, exposure 1. South half (z >= 0): a
# low +0.2 m shore, exposure 0.
#
# CA  with no talus and no deposit, every cell equals the closed-form platform cut: min(h, sea - pd(1 - d/R))
#     for land with d_sea < R·exposure. The sheltered half is untouched. Control: retreat 0 leaves the input.
# CB  talus relaxation only touches the cut band and its rim: land 3+ cells beyond R is bit-identical to the
#     input. Control: iterations 8 differs from iterations 0 somewhere.
# CC  sheltered beach: cells within the beach band below the profile are raised exactly onto it at
#     deposit 1. Control: exposure unwired (reads 1) deposits nothing.
# CD  Input -> Wave Exposure -> Coastal Erosion -> Output is native_supported and the compiled program
#     equals the forced GDScript evaluator for height and the cut channel, sea_level unwired and wired.
#     Controls: wired exposure differs from unwired, and the cut channel is not the height.
# CE  the framework gives it the standard mask (last input). Control: Wave Exposure, whose port 0 output is
#     a MASK, gets none.
# CF  the op is in graph_op_ids. Control: a bogus op is not.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphCoastalErosionGate.tscn
extends Node

const CoastalErosion = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_coastal_erosion.gd")
const WaveExposure = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_wave_exposure.gd")
const RECT := Rect2(-256.0, -256.0, 512.0, 512.0)
const N := 128
const DX := 4.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphCoastalErosionGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "coastal_erosion_grid"):
		_check(false, "coastal_erosion_grid is not bound — rebuild the GDExtension")
	else:
		_ca()
		_cb()
		_cc()
		_cd()
		_ce()
		_cf()
	_check(_ran == 6, "all 6 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["COASTAL EROSION PASS" if _fail == 0 else "COASTAL EROSION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _w(i: int) -> Vector2:
	return Pasture3DTerrainGraph.cell_to_world(i % N, i / N, N, N, RECT)


func _coast() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for i in N * N:
		var w := _w(i)
		h[i] = -10.0 if w.x < 0.0 else (20.0 if w.y < 0.0 else 0.2)
	return h


func _exposure() -> PackedFloat32Array:
	var e := PackedFloat32Array()
	e.resize(N * N)
	for i in N * N:
		e[i] = 1.0 if _w(i).y < 0.0 else 0.0
	return e


## Distance from a land cell centre to the nearest water cell centre on this straight coast, metres.
func _d_sea(i: int) -> float:
	return _w(i).x + DX * 0.5


func _node() -> Pasture3DGraphNode:
	return CoastalErosion.new()


func _run(p_node: Pasture3DGraphNode, p_h: PackedFloat32Array, p_e: PackedFloat32Array) -> Array:
	return p_node.eval_grid_channels([p_h, p_e], N, N, null, RECT)


func _ca() -> void:
	print("[CA] the platform cut matches its closed form")
	var h := _coast()
	var n := _node()
	n.cliff_iterations = 0
	n.deposit = 0.0
	var out: PackedFloat32Array = _run(n, h, _exposure())[0]
	var worst := 0.0
	var cut_cells := 0
	for i in N * N:
		var want: float = h[i]
		if h[i] >= 0.0 and _w(i).y < 0.0:
			var d := _d_sea(i)
			if d < n.retreat:
				want = minf(h[i], n.sea_level - n.platform_depth * (1.0 - d / n.retreat))
				cut_cells += 1
		worst = maxf(worst, absf(out[i] - want))
	_check(worst <= 1.0e-4 and cut_cells > 100, "worst %.6f m over %d cut cells" % [worst, cut_cells])
	n.retreat = 0.0
	var none: PackedFloat32Array = _run(n, h, _exposure())[0]
	var diff := 0.0
	for i in N * N:
		diff = maxf(diff, absf(none[i] - h[i]))
	_check(diff == 0.0, "control: retreat 0 leaves the input (max change %.4f)" % diff)
	_ran += 1


func _cb() -> void:
	print("[CB] talus only touches the cut band and its rim")
	var h := _coast()
	var n := _node()
	n.deposit = 0.0
	var relaxed: PackedFloat32Array = _run(n, h, _exposure())[0]
	var outside := 0.0
	for i in N * N:
		if h[i] >= 0.0 and _d_sea(i) >= n.retreat + 3.0 * DX:
			outside = maxf(outside, absf(relaxed[i] - h[i]))
	_check(outside == 0.0, "land 3+ cells beyond the retreat line unchanged (max %.6f)" % outside)
	n.cliff_iterations = 0
	var wall: PackedFloat32Array = _run(n, h, _exposure())[0]
	var moved := 0.0
	for i in N * N:
		moved = maxf(moved, absf(relaxed[i] - wall[i]))
	_check(moved > 0.5, "control: talus moved the face by up to %.2f m" % moved)
	_ran += 1


func _cc() -> void:
	print("[CC] sheltered shore builds a beach onto the profile")
	var h := _coast()
	var n := _node()
	n.cliff_iterations = 0
	var res := _run(n, h, _exposure())
	var out: PackedFloat32Array = res[0]
	var worst := 0.0
	var raised := 0
	for i in N * N:
		var w := _w(i)
		if w.y < 0.0:
			continue
		var s := _d_sea(i) if h[i] >= 0.0 else -(-w.x + DX * 0.5)
		var want: float = h[i]
		if s >= -0.5 * n.beach_width and s <= n.beach_width:
			var target: float = n.sea_level + n.beach_height * s / n.beach_width
			if target > h[i]:
				want = target
				raised += 1
		worst = maxf(worst, absf(out[i] - want))
	_check(worst <= 1.0e-4 and raised > 100, "worst %.6f m over %d raised cells" % [worst, raised])
	var unwired: PackedFloat32Array = _run(n, h, PackedFloat32Array())[2]
	var dep := 0.0
	for v in unwired:
		dep = maxf(dep, v)
	_check(dep == 0.0, "control: exposure unwired deposits nothing (max %.4f m)" % dep)
	_ran += 1


func _graph(p_port: int, p_wired: bool, p_sea: float) -> Pasture3DTerrainGraph:
	var we := WaveExposure.new()
	we.shore_reach = 80.0
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), _node(),
			Pasture3DGraphNodeRegistry.create(&"output"), we]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, p_port, 2, 0])]
	if p_wired:
		conns.append(PackedInt32Array([0, 0, 3, 0]))
		conns.append(PackedInt32Array([3, 0, 1, 1]))
	if p_sea > -1000.0:
		var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_sea)
		nodes.append(c)
		conns.append(PackedInt32Array([nodes.size() - 1, 0, 1, 2]))
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


func _routes(p_port: int, p_wired: bool, p_sea: float) -> Array:
	var h := _coast()
	var g := _graph(p_port, p_wired, p_sea)
	var native_ok := g.native_supported()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, h)
	var g2 := _graph(p_port, p_wired, p_sea)
	g2.force_gdscript_evaluation = true
	var ora: PackedFloat32Array = g2.evaluate(N, N, RECT, null, h)
	return [native_ok, nat, ora]


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _cd() -> void:
	print("[CD] the compiled graph route equals the GDScript evaluator")
	var wired := _routes(0, true, -2000.0)
	var unwired := _routes(0, false, -2000.0)
	var sea := _routes(0, true, 1.0)
	var cut := _routes(1, true, -2000.0)
	_check(wired[0] and unwired[0] and sea[0] and cut[0], "all four graphs are native_supported")
	for pair in [["height, exposure wired", wired], ["height, exposure unwired", unwired],
			["height, sea_level = 1", sea], ["cut channel", cut]]:
		var w := _worst(pair[1][1], pair[1][2])
		_check(w <= 1.0e-4, "%s: worst %.7f m" % [pair[0], w])
	var moved := _worst(wired[1], unwired[1])
	_check(moved > 0.5 and moved < INF, "control: wiring exposure changes the height by %.2f m" % moved)
	var chan := _worst(wired[1], cut[1])
	_check(chan > 1.0 and chan < INF, "control: the cut channel is not the height (%.1f)" % chan)
	_ran += 1


func _ce() -> void:
	print("[CE] the standard mask")
	var ce: Pasture3DGraphNode = _node()
	var ins := ce.input_ports()
	var last: Pasture3DGraphPort = ins[ins.size() - 1] if ins.size() > 0 else null
	_check(last != null and last.id == &"mask", "the last input is the standard mask (%s)" % (str(last.id) if last else "none"))
	var we: Pasture3DGraphNode = WaveExposure.new()
	var wins := we.input_ports()
	var has := false
	for p in wins:
		has = has or p.id == &"mask"
	_check(not has, "control: Wave Exposure has no standard mask")
	_ran += 1


func _cf() -> void:
	print("[CF] stays native")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("coastal_erosion") or ids.has(&"coastal_erosion"), "coastal_erosion is a native op")
	_check(not (ids.has("coastal_erosion_bogus") or ids.has(&"coastal_erosion_bogus")), "control: a bogus op is not")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
