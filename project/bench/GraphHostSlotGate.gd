# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHostSlotGate — one graph shared by several brushes caches and freezes for each brush on its own.
#
# Every node keeps one cache slot per host (Pasture3DGraphNode.select_host); the host is named at the stamp
# (`Pasture3DTerrainGraph.set_host_params(values, paths, host_id)`). Before, one slot per node meant hosts
# evicting each other, and a FROZEN solver served host A's solve to host B (the native route serves a frozen
# solve by grid shape). Criteria:
#   HS  FROZEN thermal erosion, both routes: host 202 gets a solve of ITS input (equal to a fresh solve, not
#       stale), and host 101 is then served its own solve back, not stale.
#       Control: the same two evaluations under one host id serve 202 the solve of 101's input.
#   HG  GDScript route, LIVE: after both hosts evaluate, selecting host 101 shows 101's cached grid, and the
#       cache size counts both hosts' grids.
#       Control: under one host id the grid left is the last host's.
#   HA  a worker's freeze report adopted with its host id files into that host's slot, whichever is live.
#       Control: adopted with no host id it files into the live slot.
#   HO  a parameter override on one brush's modifier forgets that brush's solve only; the other brush sharing
#       the graph keeps its solve.
#       Control: the node's Bake (clear solver cache) drops both.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphHostSlotGate.tscn
extends Node

const CRITERIA: Array[String] = ["HS-gd", "HS-native", "HG", "HA", "HO"]
const GW := 32
const GH := 32
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const EPS := 1.0e-5
const H1 := 101
const H2 := 202

var _fail := 0
var _reported := {}


func _ready() -> void:
	print("=== GraphHostSlotGate: per-host caches on a shared graph ===\n")
	_hs(true)
	_hs(false)
	_hg()
	_ha()
	_ho()
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported, so nothing was measured" % name)
	print("\n=== %s (%d failures) ===\n" % ["GRAPH HOST SLOT PASS" if _fail == 0 else "GRAPH HOST SLOT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- criteria ------------------------------------------------------------------------------------------

func _hs(p_gd: bool) -> void:
	var a := _mound(90.0)
	var b := _mound(45.0)
	var fresh := _graph_with(_thermal(true))
	fresh.force_gdscript_evaluation = p_gd
	var fresh_b := fresh.evaluate(GW, GH, RECT, null, b)

	var node := _thermal(true)
	var g := _graph_with(node)
	g.force_gdscript_evaluation = p_gd
	g.set_host_params({}, {}, H1)
	var ra := g.evaluate(GW, GH, RECT, null, a)
	g.set_host_params({}, {}, H2)
	var rb := g.evaluate(GW, GH, RECT, null, b)
	var stale_b: bool = node._stale
	g.set_host_params({}, {}, H1)
	var ra2 := g.evaluate(GW, GH, RECT, null, a)
	var stale_a: bool = node._stale
	var own_b := _diff(rb, fresh_b)
	var own_a := _diff(ra2, ra)
	var apart := _diff(ra, fresh_b)

	# Control: one host id for both, which is what one slot per node was.
	var cn := _thermal(true)
	var cg := _graph_with(cn)
	cg.force_gdscript_evaluation = p_gd
	cg.set_host_params({}, {}, H1)
	cg.evaluate(GW, GH, RECT, null, a)
	var crb := cg.evaluate(GW, GH, RECT, null, b)
	var ctrl_wrong := _diff(crb, fresh_b)

	var ok := own_b < EPS and not stale_b and own_a < EPS and not stale_a and apart > 1.0 and ctrl_wrong > 1.0
	_check("HS-gd" if p_gd else "HS-native", ok,
			"host 2 vs fresh solve %.6f stale=%s | host 1 served back %.6f stale=%s | inputs apart %.3f | one slot (control) serves host 2 off by %.3f"
			% [own_b, stale_b, own_a, stale_a, apart, ctrl_wrong])


func _hg() -> void:
	var a := _mound(90.0)
	var b := _mound(45.0)
	var node := _thermal(false)
	var g := _graph_with(node)
	g.force_gdscript_evaluation = true
	g.set_host_params({}, {}, H1)
	var ra := g.evaluate(GW, GH, RECT, null, a)
	g.set_host_params({}, {}, H2)
	g.evaluate(GW, GH, RECT, null, b)
	var bytes: int = node.get_cache_size_bytes()
	g.select_host(H1)
	var kept := _diff(node.get_cached_grid(), ra)

	var cn := _thermal(false)
	var cg := _graph_with(cn)
	cg.force_gdscript_evaluation = true
	cg.set_host_params({}, {}, H1)
	cg.evaluate(GW, GH, RECT, null, a)
	cg.evaluate(GW, GH, RECT, null, b)
	var ctrl := _diff(cn.get_cached_grid(), ra)
	var ok := kept < EPS and bytes >= 2 * GW * GH * 4 and ctrl > 1.0
	_check("HG", ok, "host 1 grid kept %.6f | bytes %d for two hosts (>= %d) | one slot (control) holds host 2's, off by %.3f"
			% [kept, bytes, 2 * GW * GH * 4, ctrl])


func _ha() -> void:
	var node := _thermal(true)
	var g := _graph_with(node)
	g.set_host_params({}, {}, H2)
	var prog := g.compile_graph_program()
	var res: Dictionary = Pasture3DUtil.graph_eval_grid_frozen(prog, GW, GH, RECT, _mound(90.0))
	var reports: Array = res.get("frozen", [])
	g.select_host(H1) # another host stamped while the worker solved
	g.adopt_native_freeze(reports, H2)
	var live_empty: bool = node._cache.is_empty()
	g.select_host(H2)
	var filed: bool = not node._cache.is_empty()

	g.select_host(H1)
	g.adopt_native_freeze(reports)
	var ctrl_live: bool = not node._cache.is_empty()
	var ok := not reports.is_empty() and live_empty and filed and ctrl_live
	_check("HA", ok, "%d reports | live host untouched=%s, named host filed=%s | no host id (control) files live=%s"
			% [reports.size(), live_empty, filed, ctrl_live])


func _ho() -> void:
	var decl := Pasture3DGraphParam.new()
	decl.id = &"k"
	decl.type = Pasture3DGraphParam.Type.FLOAT
	decl.default_value = 35.0
	var node := _thermal(true)
	var g := _graph_with(node)
	g.parameters = [decl] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new()
	pn.param_id = &"k"
	var ip := g.add_node(pn)
	g.set_host_params({})
	if not g.connect_ports(ip, 0, g.nodes.find(node), 2):
		_check("HO", false, "fixture: param -> talus refused: %s" % g.wire_problem(ip, 0, g.nodes.find(node), 2))
		return
	var m1 := Pasture3DNodeGraph.new()
	m1.graph = g
	var m2 := Pasture3DNodeGraph.new()
	m2.graph = g
	var h1 := Node.new()
	var h2 := Node.new()
	m1.stamp_params(h1)
	g.evaluate(GW, GH, RECT, null, _mound(90.0))
	m2.stamp_params(h2)
	g.evaluate(GW, GH, RECT, null, _mound(45.0))
	var both: bool = not node._cache.is_empty()
	m1.set_param(&"k", 30.0)
	m2.stamp_params(h2)
	var other_kept: bool = not node._cache.is_empty()
	m1.stamp_params(h1)
	var own_gone: bool = node._cache.is_empty()
	m2.stamp_params(h2)
	node._clear_solver_cache()
	var ctrl_h2_gone: bool = node._cache.is_empty()
	m1.stamp_params(h1)
	g.evaluate(GW, GH, RECT, null, _mound(90.0))
	m2.stamp_params(h2)
	node._clear_solver_cache()
	m1.stamp_params(h1)
	var ctrl_h1_gone: bool = node._cache.is_empty()
	h1.free()
	h2.free()
	var ok := both and other_kept and own_gone and ctrl_h2_gone and ctrl_h1_gone
	_check("HO", ok, "solved=%s | edit on brush 1: brush 2 kept=%s, brush 1 dropped=%s | Bake (control) drops both=%s"
			% [both, other_kept, own_gone, ctrl_h2_gone and ctrl_h1_gone])


# ---- fixture -------------------------------------------------------------------------------------------

func _thermal(p_frozen: bool) -> Pasture3DGraphNode:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"erosion_thermal")
	n.set("evaluation", 1 if p_frozen else 0)
	return n


func _graph_with(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var i_n := g.add_node(p_node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_n, 0)
	g.connect_ports(i_n, 0, i_out, 0)
	return g


func _mound(p_h: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	var cx := float(GW - 1) * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var ddx := (float(ix) - cx) / cx
			var ddz := (float(iz) - cx) / cx
			s[iz * GW + ix] = p_h * maxf(0.0, 1.0 - (ddx * ddx + ddz * ddz))
	return s


func _diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
