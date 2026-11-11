# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphIsletScatterGate — the Islet Scatter node. Fixture: 1024 m square, sea at -20 m, a +20 m mainland at
# x >= 300 (a straight coast).
#
# IA  every raised cell lies in the offshore band widened by the largest islet radius. Control: density 0
#     leaves the input bit-identical, and density 1 raises cells at all.
# IB  islets only raise, and every masked cell stands above sea level. Control: the masks are not empty.
# IC  placement is in world metres: islet cells at 64² land on islet cells at 128² far more often than with
#     a different seed. Not 1.0: a centre near the band edge can flip with the distance transform at 8 vs 16 m.
# ID  exposure 0 makes no stacks; exposure 1 with stack_fraction 1 makes no islets. Each is the other's
#     control (both runs place something).
# IE  Input -> Islet Scatter -> Output (Wave Exposure wired and unwired, and a Const sea_level) is
#     native_supported and equals the forced GDScript evaluator for height and the islets channel.
#     Controls: the islets channel is not the height, and sea_level = 5 moves the field.
# IF  the standard mask is the last input, and the op is in graph_op_ids. Control: a bogus op is not.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphIsletScatterGate.tscn
extends Node

const IsletScatter = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_islet_scatter.gd")
const WaveExposure = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_wave_exposure.gd")
const RECT := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const N := 128
const COAST := 300.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphIsletScatterGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "islet_scatter_grid"):
		_check(false, "islet_scatter_grid is not bound — rebuild the GDExtension")
	else:
		_ia()
		_ib()
		_ic()
		_id()
		_ie()
		_if()
	_check(_ran == 6, "all 6 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["ISLET SCATTER PASS" if _fail == 0 else "ISLET SCATTER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _w(i: int, p_n: int = N) -> Vector2:
	return Pasture3DTerrainGraph.cell_to_world(i % p_n, i / p_n, p_n, p_n, RECT)


func _coast(p_n: int = N) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_n * p_n)
	for i in p_n * p_n:
		h[i] = 20.0 if _w(i, p_n).x >= COAST else -20.0
	return h


func _const(p_v: float, p_n: int = N) -> PackedFloat32Array:
	var e := PackedFloat32Array()
	e.resize(p_n * p_n)
	e.fill(p_v)
	return e


func _node() -> Pasture3DGraphNode:
	var n := IsletScatter.new()
	n.spacing = 100.0
	n.density = 1.0
	return n


func _run(p_node: Pasture3DGraphNode, p_h: PackedFloat32Array, p_e: PackedFloat32Array, p_n: int = N) -> Array:
	return p_node.eval_grid_channels([p_h, p_e], p_n, p_n, null, RECT)


func _ia() -> void:
	print("[IA] islets stay in the offshore band")
	var h := _coast()
	var n := _node()
	n.roughness = 0.0
	var out: PackedFloat32Array = _run(n, h, PackedFloat32Array())[0]
	var reach: float = n.radius_max
	var outside := 0
	var raised := 0
	for i in N * N:
		if out[i] != h[i]:
			raised += 1
			var d := COAST - _w(i).x
			if d < n.min_offshore - reach or d > n.max_offshore + reach:
				outside += 1
	_check(outside == 0 and raised > 50, "%d raised cells, %d outside the band" % [raised, outside])
	n.density = 0.0
	var none: PackedFloat32Array = _run(n, h, PackedFloat32Array())[0]
	_check(none == h, "control: density 0 leaves the input bit-identical")
	_ran += 1


func _ib() -> void:
	print("[IB] islets only raise, masks stand above the sea")
	var h := _coast()
	var res := _run(_node(), h, _const(0.5))
	var out: PackedFloat32Array = res[0]
	var bad := 0
	var masked := 0
	for i in N * N:
		if out[i] < h[i]:
			bad += 1
		if res[1][i] > 0.5 or res[2][i] > 0.5:
			masked += 1
			if out[i] <= 0.0:
				bad += 1
	_check(bad == 0, "%d cells lowered or masked below sea" % bad)
	_check(masked > 20, "control: %d masked cells" % masked)
	_ran += 1


## Fraction of offshore above-sea cells at 64² whose 128² cell at the same world point is also above sea.
func _agree(p_seed_b: int) -> float:
	var a := _node()
	var b := _node()
	b.seed = p_seed_b
	var fine: PackedFloat32Array = _run(a, _coast(), PackedFloat32Array())[0]
	var coarse: PackedFloat32Array = _run(b, _coast(64), PackedFloat32Array(), 64)[0]
	var hit := 0
	var tot := 0
	for i in 64 * 64:
		var w := _w(i, 64)
		if w.x >= COAST or coarse[i] <= 0.0:
			continue
		tot += 1
		var fx := int(floor((w.x - RECT.position.x) / 8.0))
		var fz := int(floor((w.y - RECT.position.y) / 8.0))
		if fine[fz * N + fx] > 0.0:
			hit += 1
	return float(hit) / maxf(float(tot), 1.0)


func _ic() -> void:
	print("[IC] placement does not move with resolution")
	var same := _agree(0)
	var other := _agree(7)
	_check(same > 0.75, "64² vs 128², same seed: %.2f agree" % same)
	_check(other < same - 0.3, "control: another seed agrees %.2f" % other)
	_ran += 1


static func _count(p_m: PackedFloat32Array) -> int:
	var c := 0
	for v in p_m:
		if v > 0.5:
			c += 1
	return c


func _id() -> void:
	print("[ID] exposure picks stacks")
	var n := _node()
	n.stack_fraction = 1.0
	var calm := _run(n, _coast(), _const(0.0))
	var rough := _run(n, _coast(), _const(1.0))
	_check(_count(calm[2]) == 0 and _count(calm[1]) > 20, "exposure 0: %d stack, %d islet cells" % [_count(calm[2]), _count(calm[1])])
	_check(_count(rough[1]) == 0 and _count(rough[2]) > 5, "exposure 1: %d islet, %d stack cells" % [_count(rough[1]), _count(rough[2])])
	_ran += 1


func _graph(p_port: int, p_wired: bool, p_sea: float) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), _node(),
			Pasture3DGraphNodeRegistry.create(&"output"), WaveExposure.new()]
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


func _ie() -> void:
	print("[IE] the compiled graph route equals the GDScript evaluator")
	var wired := _routes(0, true, -2000.0)
	var unwired := _routes(0, false, -2000.0)
	var sea := _routes(0, true, 5.0)
	var isl := _routes(1, true, -2000.0)
	_check(wired[0] and unwired[0] and sea[0] and isl[0], "all four graphs are native_supported")
	for pair in [["height, exposure wired", wired], ["height, exposure unwired", unwired],
			["height, sea_level = 5", sea], ["islets channel", isl]]:
		var w := _worst(pair[1][1], pair[1][2])
		_check(w <= 1.0e-4, "%s: worst %.7f m" % [pair[0], w])
	var moved := _worst(wired[1], sea[1])
	_check(moved > 1.0 and moved < INF, "control: sea_level = 5 moves the height by %.2f m" % moved)
	var chan := _worst(wired[1], isl[1])
	_check(chan > 1.0 and chan < INF, "control: the islets channel is not the height (%.1f)" % chan)
	_ran += 1


func _if() -> void:
	print("[IF] standard mask, stays native")
	var ins := _node().input_ports()
	var last: Pasture3DGraphPort = ins[ins.size() - 1] if ins.size() > 0 else null
	_check(last != null and last.id == &"mask", "the last input is the standard mask (%s)" % (str(last.id) if last else "none"))
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("islet_scatter") or ids.has(&"islet_scatter"), "islet_scatter is a native op")
	_check(not (ids.has("islet_scatter_bogus") or ids.has(&"islet_scatter_bogus")), "control: a bogus op is not")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
