# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerHostLoopGate — an EMPTY `loop` socket reads the host brush's own outline.
#
#   N  native route: empty socket + host loop matches the oracle handed that loop, on every channel; the
#      CONTROL is the oracle with no loop, which must differ (else N cannot tell the fallback from nothing).
#   G  GDScript route (force_gdscript_evaluation): the same, through `_path_inputs`.
#   W  a WIRED loop wins over the host loop, on both routes.
#   C  `resolve_host_loops` with no host clears the loop, and the graph is back to the no-loop answer.
#   B  `graph_host_loop` on a real closed brush is the baked ring in world XZ; an open spline gives null.
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const EPS := 2.0e-4
const CRITERIA := 5
const CFG := {"mode": 1, "target_height": -4.0, "feather_side": 0, "feather": 8.0, "walls_shape": 0}

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== LevelerHostLoopGate: empty loop socket reads the host brush outline ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "leveler_grid"):
		print("!! Pasture3DUtil.leveler_grid is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	var h := _sloped()
	var host := _ring(22.0, Vector2(4.0, -3.0))
	var wired := _ring(12.0, Vector2(-10.0, 8.0))
	var want_host: Array = _oracle(h, host)
	var want_wired: Array = _oracle(h, wired)
	var want_none: Array = _oracle(h, null)
	_n(h, host, want_host, want_none)
	_g(h, host, want_host)
	_w(h, host, wired, want_wired, want_host)
	_c(h, host, want_none)
	_b()
	if _ran != CRITERIA:
		_fail += 1
		print("\n!! only %d of %d criteria completed" % [_ran, CRITERIA])
	print("\n=== %s (%d failures, %d/%d criteria ran) ===\n" % [
		"LEVELER HOST LOOP PASS" if _fail == 0 else "LEVELER HOST LOOP FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(0 if _fail == 0 else 1)


func _n(p_h: PackedFloat32Array, p_host: Pasture3DGraphPath, p_want: Array, p_none: Array) -> void:
	print("[N] native route: empty socket reads the host loop")
	for ch in 5:
		var g := _graph(ch, null)
		(g.nodes[2] as Pasture3DGraphNodeLevelerBase).set_host_loop(p_host)
		var w := _worst(_native(g, p_h), p_want[ch])
		print("    channel %d: worst %.7f" % [ch, w])
		if w > EPS:
			_fail += 1
			print("    !! channel %d does not match the oracle given the host loop" % ch)
	var cw := maxf(_worst(p_want[0], p_none[0]), _worst(p_want[4], p_none[4]))
	print("    control: host loop vs no loop differ by %.3f (want > 1)" % cw)
	if cw <= 1.0:
		_fail += 1
		print("    !! control dead: the fixture cannot tell the host loop from no loop")
	_ran += 1


func _g(p_h: PackedFloat32Array, p_host: Pasture3DGraphPath, p_want: Array) -> void:
	print("[G] GDScript route: empty socket reads the host loop")
	for ch in [0, 4]:
		var g := _graph(ch, null)
		g.force_gdscript_evaluation = true
		(g.nodes[2] as Pasture3DGraphNodeLevelerBase).set_host_loop(p_host)
		var w := _worst(g.evaluate(GW, GH, RECT, null, p_h), p_want[ch])
		print("    channel %d: worst %.7f" % [ch, w])
		if w > EPS:
			_fail += 1
			print("    !! channel %d does not match the oracle given the host loop" % ch)
	_ran += 1


func _w(p_h: PackedFloat32Array, p_host: Pasture3DGraphPath, p_wired: Pasture3DGraphPath, p_want: Array,
		p_host_want: Array) -> void:
	print("[W] a wired loop wins over the host loop")
	for gd in [false, true]:
		var g := _graph(4, p_wired)
		g.force_gdscript_evaluation = gd
		(g.nodes[2] as Pasture3DGraphNodeLevelerBase).set_host_loop(p_host)
		var got: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, p_h) if gd else _native(g, p_h)
		var w := _worst(got, p_want[4])
		var wh := _worst(got, p_host_want[4])
		print("    %s: vs wired %.7f, vs host %.3f" % ["gdscript" if gd else "native", w, wh])
		if w > EPS or wh <= 0.5:
			_fail += 1
			print("    !! the wired loop did not override the host loop")
	_ran += 1


func _c(p_h: PackedFloat32Array, p_host: Pasture3DGraphPath, p_none: Array) -> void:
	print("[C] resolving with no host clears the loop")
	var g := _graph(4, null)
	var lev := g.nodes[2] as Pasture3DGraphNodeLevelerBase
	lev.set_host_loop(p_host)
	Pasture3DGraphSources.resolve_host_loops(g, null)
	var w := _worst(_native(g, p_h), p_none[4])
	print("    host_loop null: %s, vs no-loop oracle %.7f" % [str(lev.host_loop == null), w])
	if lev.host_loop != null or w > EPS:
		_fail += 1
		print("    !! the host loop survived a hostless resolve")
	_ran += 1


func _b() -> void:
	print("[B] graph_host_loop on a real brush")
	var m := Pasture3DMound.new()
	var sp := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(-10, 0, -10), Vector3(10, 0, -10), Vector3(10, 0, 10), Vector3(-10, 0, 10)]:
		c.add_point(p)
	sp.curve = c
	sp.position = Vector3(100.0, 0.0, 50.0)
	m.add_child(sp)
	var loop := m.graph_host_loop()
	var ok := loop != null and loop.closed and loop.points.size() >= 4
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	if ok:
		for p in loop.points:
			lo = lo.min(p)
			hi = hi.max(p)
		ok = lo.distance_to(Vector2(90, 40)) < 0.01 and hi.distance_to(Vector2(110, 60)) < 0.01
	print("    closed mound: %s, %d points, box %s..%s" % [str(loop != null), loop.points.size() if loop else 0,
			str(lo), str(hi)])
	if not ok:
		_fail += 1
		print("    !! the brush ring is missing or not in world XZ")
	m.free()
	var s := Pasture3DSpline.new()
	var sp2 := Path3D.new()
	sp2.curve = c.duplicate()
	s.add_child(sp2)
	var open_closed: bool = s._is_closed()
	var open_loop := s.graph_host_loop()
	print("    open spline (closed=%s): loop %s" % [str(open_closed), str(open_loop)])
	if not open_closed and open_loop != null:
		_fail += 1
		print("    !! an open spline offered a loop")
	s.free()
	_ran += 1


## Input -> Leveler.height; RoadSource -> Leveler.loop only when `p_wired`; Leveler[ch] -> Output.
func _graph(p_channel: int, p_wired) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = p_wired
	var lev := Pasture3DGraphNodeLeveler.new()
	for k in CFG:
		lev.set(String(k), CFG[k])
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), src, lev, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	var conns: Array = [[0, 0, 2, 0], [2, p_channel, 3, 0]]
	if p_wired != null:
		conns.append([1, 0, 2, 1])
	g.connections = conns
	return g


func _native(p_g: Pasture3DTerrainGraph, p_h: PackedFloat32Array) -> PackedFloat32Array:
	var prog := p_g.compile_graph_program()
	if prog.is_empty() or not p_g.native_supported():
		return PackedFloat32Array()
	return Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, p_h)


func _oracle(p_h: PackedFloat32Array, p_path) -> Array:
	var ora := Pasture3DGraphNodeDevLeveler.new()
	for k in CFG:
		ora.set(String(k), CFG[k])
	var n := GW * GH
	ora.set_path_inputs([null, p_path, null, null])
	return ora.eval_grid_channels([p_h, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.filled(n, 1.0),
			Pasture3DGraphOps.filled(n, ora.input_unwired_default(3))], GW, GH, null, RECT)


func _ring(p_half: float, p_c: Vector2) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([p_c + Vector2(-p_half, -p_half), p_c + Vector2(p_half, -p_half),
			p_c + Vector2(p_half, p_half), p_c + Vector2(-p_half * 0.6, p_half)])
	p.closed = true
	return p


func _sloped() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(GW * GH)
	var dx := RECT.size.x / GW
	var dz := RECT.size.y / GH
	for iz in GH:
		for ix in GW:
			var x := RECT.position.x + (ix + 0.5) * dx
			var z := RECT.position.y + (iz + 0.5) * dz
			h[iz * GW + ix] = 10.0 + 0.2 * x + 0.1 * z + 0.8 * sin(x * 0.37) * cos(z * 0.23)
	return h


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		var an := is_nan(p_a[i])
		var bn := is_nan(p_b[i])
		if an and bn:
			continue
		if an != bn:
			return INF
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w
