# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphShoreCharacterGate — the Shore Character node. Fixture: 1024 m square of 8 m cells, sea at -10 m, a
# +10 m square island |x|,|z| < 300 with a bay 160 m wide cut from z = 60 to the south shore, and a headland
# 60 m wide running north from z = -300 to z = -460.
#
# SA  shape only: the shore at the bay head reads cliff < 0.3 and the headland tip > 0.7. Control: with only
#     a uniform exposure weighted, the two read the same.
# SB  exposure only: an exposure ramping west to east gives a cliff that never falls along a row and spans
#     > 0.5. Control: exposure unwired gives a uniform cliff.
# SC  backshore only: raising the ground behind the north shore to +60 m turns that shore to cliff (> 0.9)
#     while a south shore 600 m away stays within 1e-6 of its old value. Control: with backshore weight 0
#     the north shore does not change.
# SD  hardness is in world metres: the 64² and 128² fields agree within 0.05 at shared points. Control: a
#     different seed differs by > 0.2 somewhere.
# SE  erosion = exposure · (1 - hardness) and beach = 1 - cliff, within float rounding.
# SF  Input -> Shore Character -> Output (Wave Exposure wired and unwired) is native_supported and equals
#     the forced GDScript evaluator for cliff and erosion. Control: the two channels differ.
# SG  no standard mask (port 0 is a MASK), and the op is in graph_op_ids. Control: a bogus op is not.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphShoreCharacterGate.tscn
extends Node

const ShoreCharacter = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_shore_character.gd")
const WaveExposure = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_wave_exposure.gd")
const RECT := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const N := 128
const DX := 8.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphShoreCharacterGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "shore_character_grid"):
		_check(false, "shore_character_grid is not bound — rebuild the GDExtension")
	else:
		_sa()
		_sb()
		_sc()
		_sd()
		_se()
		_sf()
		_sg()
	_check(_ran == 7, "all 7 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["SHORE CHARACTER PASS" if _fail == 0 else "SHORE CHARACTER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


static func _is_land(w: Vector2) -> bool:
	var square := absf(w.x) < 300.0 and absf(w.y) < 300.0
	var bay := absf(w.x) < 80.0 and w.y > 60.0
	var headland := absf(w.x) < 30.0 and w.y <= -300.0 and w.y > -460.0
	return (square and not bay) or headland


func _island(p_n: int = N, p_raise_north := false) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_n * p_n)
	for i in p_n * p_n:
		var w := Pasture3DTerrainGraph.cell_to_world(i % p_n, i / p_n, p_n, p_n, RECT)
		if not _is_land(w):
			h[i] = -10.0
		else:
			h[i] = 60.0 if p_raise_north and w.y < -100.0 else 10.0
	return h


func _at(p_x: float, p_z: float) -> int:
	return int(floor((p_z - RECT.position.y) / DX)) * N + int(floor((p_x - RECT.position.x) / DX))


func _node() -> Pasture3DGraphNode:
	var n := ShoreCharacter.new()
	n.bay_radius = 150.0
	n.cove_radius = 40.0
	return n


## Only the named signal weighted.
func _only(p_which: String) -> Pasture3DGraphNode:
	var n := _node()
	n.shape_weight = 1.0 if p_which == "shape" else 0.0
	n.exposure_weight = 1.0 if p_which == "exposure" else 0.0
	n.backshore_weight = 1.0 if p_which == "backshore" else 0.0
	return n


func _run(p_node: Pasture3DGraphNode, p_h: PackedFloat32Array, p_e: PackedFloat32Array, p_n: int = N) -> Array:
	return p_node.eval_grid_channels([p_h, p_e], p_n, p_n, null, RECT)


func _sa() -> void:
	print("[SA] bays read beach, headlands read cliff")
	var head := _at(0.0, 52.0) # land, the head of the bay
	var tip := _at(0.0, -452.0) # land, the headland tip
	var c: PackedFloat32Array = _run(_only("shape"), _island(), PackedFloat32Array())[0]
	_check(c[head] < 0.3 and c[tip] > 0.7, "bay head %.3f, headland tip %.3f" % [c[head], c[tip]])
	var u: PackedFloat32Array = _run(_only("exposure"), _island(), PackedFloat32Array())[0]
	_check(u[head] == u[tip], "control: exposure alone reads %.3f and %.3f" % [u[head], u[tip]])
	_ran += 1


func _sb() -> void:
	print("[SB] cliff follows exposure")
	var e := PackedFloat32Array()
	e.resize(N * N)
	for i in N * N:
		e[i] = float(i % N) / float(N - 1)
	var n := _only("exposure")
	n.softness = 1.0
	var c: PackedFloat32Array = _run(n, _island(), e)[0]
	var row := N / 2
	var falls := 0
	for ix in N - 1:
		if c[row * N + ix + 1] < c[row * N + ix] - 1e-6:
			falls += 1
	var span: float = c[row * N + N - 1] - c[row * N]
	_check(falls == 0 and span > 0.5, "%d falls along the row, span %.3f" % [falls, span])
	var u: PackedFloat32Array = _run(n, _island(), PackedFloat32Array())[0]
	var lo := INF
	var hi := -INF
	for v in u:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check(hi - lo == 0.0, "control: exposure unwired spans %.4f" % (hi - lo))
	_ran += 1


func _sc() -> void:
	print("[SC] high ground behind a shore makes cliff")
	var north := _at(-200.0, -292.0) # land, first rows inside the north shore
	var south := _at(-200.0, 292.0)
	var n := _only("backshore")
	var base: PackedFloat32Array = _run(n, _island(), PackedFloat32Array())[0]
	var raised: PackedFloat32Array = _run(n, _island(N, true), PackedFloat32Array())[0]
	_check(raised[north] > 0.9 and base[north] < 0.1, "north shore %.3f -> %.3f" % [base[north], raised[north]])
	_check(absf(raised[south] - base[south]) <= 1e-6, "south shore unchanged (%.7f)" % absf(raised[south] - base[south]))
	var off := _only("backshore")
	off.backshore_weight = 0.0
	off.shape_weight = 1.0
	var a: PackedFloat32Array = _run(off, _island(), PackedFloat32Array())[0]
	var b: PackedFloat32Array = _run(off, _island(N, true), PackedFloat32Array())[0]
	_check(a[north] == b[north], "control: backshore weight 0 leaves the north shore at %.3f" % b[north])
	_ran += 1


func _hardness(p_n: int, p_seed: int) -> PackedFloat32Array:
	var n := _node()
	n.seed = p_seed
	return _run(n, _island(p_n), PackedFloat32Array(), p_n)[2]


func _sd() -> void:
	print("[SD] hardness does not move with resolution")
	var fine := _hardness(128, 0)
	var coarse := _hardness(64, 0)
	var other := _hardness(64, 7)
	var worst := 0.0
	var seed_diff := 0.0
	for i in 64 * 64:
		var w := Pasture3DTerrainGraph.cell_to_world(i % 64, i / 64, 64, 64, RECT)
		var f: float = fine[_at(w.x, w.y)]
		worst = maxf(worst, absf(coarse[i] - f))
		seed_diff = maxf(seed_diff, absf(other[i] - coarse[i]))
	_check(worst <= 0.05, "64² vs 128²: worst %.4f" % worst)
	_check(seed_diff > 0.2, "control: another seed differs by %.3f" % seed_diff)
	_ran += 1


func _se() -> void:
	print("[SE] erosion and beach are their formulas")
	var e := PackedFloat32Array()
	e.resize(N * N)
	for i in N * N:
		e[i] = float(i % 7) / 6.0
	var r := _run(_node(), _island(), e)
	var worst_e := 0.0
	var worst_b := 0.0
	for i in N * N:
		worst_e = maxf(worst_e, absf(r[3][i] - e[i] * (1.0 - r[2][i])))
		worst_b = maxf(worst_b, absf(r[1][i] - (1.0 - r[0][i])))
	_check(worst_e <= 1e-6 and worst_b <= 1e-6, "erosion worst %.8f, beach worst %.8f" % [worst_e, worst_b])
	_ran += 1


func _graph(p_port: int, p_wired: bool) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), _node(),
			Pasture3DGraphNodeRegistry.create(&"output"), WaveExposure.new()]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, p_port, 2, 0])]
	if p_wired:
		conns.append(PackedInt32Array([0, 0, 3, 0]))
		conns.append(PackedInt32Array([3, 0, 1, 1]))
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


func _routes(p_port: int, p_wired: bool) -> Array:
	var h := _island()
	var g := _graph(p_port, p_wired)
	var native_ok := g.native_supported()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, h)
	var g2 := _graph(p_port, p_wired)
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


func _sf() -> void:
	print("[SF] the compiled graph route equals the GDScript evaluator")
	var wired := _routes(0, true)
	var unwired := _routes(0, false)
	var ero := _routes(3, true)
	_check(wired[0] and unwired[0] and ero[0], "all three graphs are native_supported")
	for pair in [["cliff, exposure wired", wired], ["cliff, exposure unwired", unwired], ["erosion channel", ero]]:
		var w := _worst(pair[1][1], pair[1][2])
		_check(w <= 1.0e-5, "%s: worst %.7f" % [pair[0], w])
	var chan := _worst(wired[1], ero[1])
	_check(chan > 0.1 and chan < INF, "control: erosion is not cliff (%.3f)" % chan)
	_ran += 1


func _sg() -> void:
	print("[SG] no standard mask, stays native")
	var has := false
	for p in _node().input_ports():
		has = has or p.id == &"mask"
	_check(not has, "Shore Character has no standard mask")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("shore_character") or ids.has(&"shore_character"), "shore_character is a native op")
	_check(not (ids.has("shore_character_bogus") or ids.has(&"shore_character_bogus")), "control: a bogus op is not")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
