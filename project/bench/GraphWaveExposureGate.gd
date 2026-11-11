# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphWaveExposureGate — the Wave Exposure node. Fixture: 128² cells of 8 m, sea at -10 m, a +10 m square
# island x,z in [-200, 200] with a cove 24 m wide cut 160 m into its south shore.
#
# WA  one direction (from north) gives the exact axis fetch: every water cell reads 8 m times the run of
#     water cells to its north, every land cell its shore's value faded by shore_reach. Control: the same
#     formula with the wrong direction (from south) misses by hundreds of metres.
# WB  the back of the cove is sheltered: under half the exposure of the open south shore. Control: the open
#     shore cell itself reads above 0.3, so this is not 0 against 0.
# WC  a north wind at strength 1 makes the north shore more exposed than the south. Control: a south wind
#     flips the order.
# WD  shore_reach carries exposure inland: a land cell 16 m behind the north shore reads > 0 at 40 m reach
#     and exactly 0 at 0 m reach. Control: the shore cell itself reads > 0 at both.
# WE  Input -> Wave Exposure -> Output is native_supported and the compiled program equals the forced
#     GDScript evaluator, for exposure and for the fetch channel, with sea_level unwired and wired to a Const.
#     Controls: wiring sea_level = 20 m (above the island) changes the field, and fetch is not exposure.
# WF  the op is in graph_op_ids. Control: a bogus op is not.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphWaveExposureGate.tscn
extends Node

const WaveExposure = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_wave_exposure.gd")
const RECT := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const N := 128
const DX := 8.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphWaveExposureGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "wave_exposure_grid"):
		_check(false, "wave_exposure_grid is not bound — rebuild the GDExtension")
	else:
		_wa()
		_wb()
		_wc()
		_wd()
		_we()
		_wf()
	_check(_ran == 6, "all 6 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["WAVE EXPOSURE PASS" if _fail == 0 else "WAVE EXPOSURE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


static func _is_land(w: Vector2) -> bool:
	var in_square := absf(w.x) < 200.0 and absf(w.y) < 200.0
	var in_cove := absf(w.x) < 12.0 and w.y > 40.0
	return in_square and not in_cove


func _island() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for iz in N:
		for ix in N:
			h[iz * N + ix] = 10.0 if _is_land(Pasture3DTerrainGraph.cell_to_world(ix, iz, N, N, RECT)) else -10.0
	return h


func _node() -> Pasture3DGraphNode:
	var n := WaveExposure.new()
	n.max_fetch = 2000.0
	return n


func _run(p_node: Pasture3DGraphNode, p_h: PackedFloat32Array) -> Array:
	return p_node.eval_grid_channels([p_h], N, N, null, RECT)


func _cell(ix: int, iz: int) -> int:
	return iz * N + ix


## The world cell index of a point.
func _at(p_x: float, p_z: float) -> int:
	var ix := int(floor((p_x - RECT.position.x) / DX))
	var iz := int(floor((p_z - RECT.position.y) / DX))
	return _cell(ix, iz)


## Expected one-direction fetch: water reads DX times the run of water cells upwind (inclusive, capped),
## land reads the value of the cell upwind of it carried over land and faded. Edge is open (max_fetch).
func _expect_axis(p_h: PackedFloat32Array, p_from_north: bool, p_max: float, p_reach: float) -> PackedFloat32Array:
	var e := PackedFloat32Array()
	e.resize(N * N)
	var dz := -1 if p_from_north else 1
	for ix in N:
		var zs: Array = range(N) if p_from_north else range(N - 1, -1, -1)
		var f := 0.0
		var carried := 0.0
		var d := 0.0
		var first := true
		for iz in zs:
			var i := _cell(ix, iz)
			var water := p_h[i] < 0.0
			if first:
				# Upwind of the first row is off-grid: open sea.
				f = p_max
				carried = p_max
				d = 0.0
				first = false
			if water:
				f = minf(DX + f, p_max)
				carried = f
				d = 0.0
				e[i] = f
			else:
				d = minf(DX + d, p_reach + 2.0 * DX)
				f = 0.0
				var into := d - DX
				var fade := clampf(1.0 - into / p_reach, 0.0, 1.0) if p_reach > 0.0 else (1.0 if into <= 1e-6 else 0.0)
				e[i] = carried * fade
	return e


func _wa() -> void:
	print("[WA] one direction gives the exact axis fetch")
	var h := _island()
	var n := _node()
	n.directions = 1
	n.wind_direction = 0.0
	var fetch: PackedFloat32Array = _run(n, h)[1]
	var want := _expect_axis(h, true, n.max_fetch, n.shore_reach)
	var wrong := _expect_axis(h, false, n.max_fetch, n.shore_reach)
	var worst := 0.0
	var worst_wrong := 0.0
	for i in N * N:
		worst = maxf(worst, absf(fetch[i] - want[i]))
		worst_wrong = maxf(worst_wrong, absf(fetch[i] - wrong[i]))
	_check(worst <= 1.0e-3, "worst %.5f m against the run-length formula" % worst)
	_check(worst_wrong > 100.0, "control: the opposite direction misses by %.0f m" % worst_wrong)
	_ran += 1


func _wb() -> void:
	print("[WB] the back of the cove is sheltered")
	var e: PackedFloat32Array = _run(_node(), _island())[0]
	var back := e[_at(0.0, 52.0)] # water, 12 m from the cove's inner end
	var open := e[_at(-100.0, 204.0)] # water, just off the open south shore
	_check(back < 0.5 * open, "cove back %.3f vs open shore %.3f" % [back, open])
	_check(open > 0.3, "control: the open shore reads %.3f" % open)
	_ran += 1


func _wc() -> void:
	print("[WC] a prevailing wind favours the shore it blows onto")
	var h := _island()
	var north_shore := _at(-100.0, -196.0) # land, first row inside the north shore
	var south_shore := _at(-100.0, 196.0)
	var n := _node()
	n.wind_strength = 1.0
	n.wind_direction = 0.0
	var e: PackedFloat32Array = _run(n, h)[0]
	_check(e[north_shore] > 3.0 * e[south_shore], "north wind: north %.3f, south %.3f" % [e[north_shore], e[south_shore]])
	n.wind_direction = 180.0
	var s: PackedFloat32Array = _run(n, h)[0]
	_check(s[south_shore] > 3.0 * s[north_shore], "control: south wind: south %.3f, north %.3f" % [s[south_shore], s[north_shore]])
	_ran += 1


func _wd() -> void:
	print("[WD] shore_reach carries exposure inland")
	var h := _island()
	var shore := _at(-100.0, -196.0)
	var inland := _at(-100.0, -180.0) # two cells behind the shore cell
	var n := _node()
	n.shore_reach = 40.0
	var a: PackedFloat32Array = _run(n, h)[0]
	n.shore_reach = 0.0
	var b: PackedFloat32Array = _run(n, h)[0]
	_check(a[inland] > 0.0 and b[inland] == 0.0, "inland cell: %.4f at 40 m, %.4f at 0 m" % [a[inland], b[inland]])
	_check(a[shore] > 0.0 and b[shore] > 0.0, "control: the shore cell reads %.3f and %.3f" % [a[shore], b[shore]])
	_ran += 1


func _graph(p_port: int, p_sea: float) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), _node(),
			Pasture3DGraphNodeRegistry.create(&"output")]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, p_port, 2, 0])]
	if p_sea > -1000.0:
		var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_sea)
		nodes.append(c)
		conns.append(PackedInt32Array([3, 0, 1, 1]))
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


func _routes(p_port: int, p_sea: float) -> Array:
	var h := _island()
	var g := _graph(p_port, p_sea)
	var native_ok := g.native_supported()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, h)
	var g2 := _graph(p_port, p_sea)
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


func _we() -> void:
	print("[WE] the compiled graph route equals the GDScript evaluator")
	var unwired := _routes(0, -2000.0)
	var raised := _routes(0, 20.0)
	var fetch := _routes(1, -2000.0)
	_check(unwired[0] and raised[0] and fetch[0], "all three graphs are native_supported")
	for pair in [["exposure, sea_level unwired", unwired], ["exposure, sea_level = 20", raised], ["fetch channel", fetch]]:
		var w := _worst(pair[1][1], pair[1][2])
		_check(w <= 1.0e-4, "%s: worst %.7f" % [pair[0], w])
	var moved := _worst(unwired[1], raised[1])
	_check(moved > 0.1 and moved < INF, "control: wiring sea_level = 20 moves exposure by %.3f" % moved)
	var chan := _worst(unwired[1], fetch[1])
	_check(chan > 10.0 and chan < INF, "control: the fetch channel is not exposure (%.1f)" % chan)
	_ran += 1


func _wf() -> void:
	print("[WF] stays native")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("wave_exposure") or ids.has(&"wave_exposure"), "wave_exposure is a native op")
	_check(not (ids.has("wave_exposure_bogus") or ids.has(&"wave_exposure_bogus")), "control: a bogus op is not")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
