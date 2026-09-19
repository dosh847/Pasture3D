# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSinkPretapGate — the channel-sink pass no longer re-solves the graph on the main thread.
#
#   A  The worker's deferred solve (the brush's own _graph_solve_one, over make_pending's entry) taps the
#      output AND the sink's fields in one pass: the height equals graph_eval_grid on the single-root
#      program bit for bit, and the sink field equals a fresh tap. Control: a graph with no sink gets no
#      tap program.
#   B  The sink pass uses those fields: _resolve_ports with the adopted taps runs no evaluation of its own
#      and returns the same mask. Control: a different surface gets no pre-tapped fields, and evaluates.
#   C  A FROZEN solver (Erosion) is served in a tap pass (the multi-root program now carries the freeze table).
#      Control: the same program with the table removed reports nothing served.
#   D  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphSinkPretapGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(0.0, 0.0, 256.0, 256.0)
const CRITERIA := ["A", "B", "C"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== GraphSinkPretapGate: the sink pass rides the height solve ===")
	for entry in [["A", _a_one_pass], ["B", _b_sink_uses_taps], ["C", _c_frozen_served]]:
		entry[1].call()
		if not _seen.has(entry[0]):
			print("!! [%s] returned without reporting" % entry[0])
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
	_check("D", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== SINK PRETAP %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


func _dome() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var u := (ix + 0.5) / GW - 0.5
			var v := (iz + 0.5) / GH - 0.5
			a[iz * GW + ix] = 60.0 * cos(minf(sqrt(u * u + v * v) / 0.5, 1.0) * PI * 0.5)
	return a


## Input -> Salève -> Output, and a Color Sink masked by Salève's eroded_rock (port 1).
func _graph(p_sink: bool) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var sal := Pasture3DGraphNodeHydraulicSaleve.new()
	sal.iterations = 4
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), sal, Pasture3DGraphNodeOutput.new()]
	var conns: Array = [[0, 0, 1, 0], [1, 0, 2, 0]]
	if p_sink:
		nodes.append(Pasture3DGraphNodeColorSink.new())
		conns.append([1, 1, 3, 0])
	g.nodes = nodes
	g.connections = conns
	g.set_output(2)
	return g


func _pending(p_mod: Pasture3DNodeGraph, p_z: PackedFloat32Array) -> Dictionary:
	return p_mod.make_pending({"pending": p_z, "pending_gw": GW, "pending_gh": GH, "pending_key": 1,
			"pending_rect": RECT}, "gate")


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _fresh_tap(p_g: Pasture3DTerrainGraph, p_node: int, p_port: int, p_z: PackedFloat32Array) -> PackedFloat32Array:
	var c: Dictionary = p_g.compile_graph_program_multi([p_node])
	var r: Dictionary = Pasture3DUtil.graph_eval_grid_taps(c["program"], GW, GH, RECT, p_z,
			PackedInt32Array([int(c["slot_of"][p_node])]), PackedInt32Array([p_port]))
	return r["fields"][0]


# --- A. one pass ---------------------------------------------------------------------------------------
func _a_one_pass() -> void:
	print("[A] the worker's solve taps the height and the sink's field in one pass")
	var z := _dome()
	var m := Pasture3DNodeGraph.new()
	m.graph = _graph(true)
	var st := _pending(m, z)
	var host := Pasture3DMound.new()
	var has_prog := st.has("taps_prog")
	host._graph_solve_one(st)
	var want_h: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(m.graph.compile_graph_program(), GW, GH, RECT, z)
	var dh := _worst(st.get("zo", PackedFloat32Array()), want_h)
	var sf: Dictionary = st.get("sink_fields", {})
	var key := Pasture3DGraphChannelSinks._field_key(1, 1)
	var df := _worst(sf.get(key, PackedFloat32Array()), _fresh_tap(m.graph, 1, 1, z))
	_check("A", has_prog and dh == 0.0 and df == 0.0, "tap program %s; height vs single-root %s m (want 0); sink field vs fresh tap %s m (want 0)"
			% [str(has_prog), str(dh), str(df)])
	var bare := Pasture3DNodeGraph.new()
	bare.graph = _graph(false)
	_control(not _pending(bare, z).has("taps_prog"), "a graph with no sink gets no tap program")
	host.free()


# --- B. the sink pass uses them ------------------------------------------------------------------------
func _b_sink_uses_taps() -> void:
	print("[B] the sink pass reads the worker's fields and evaluates nothing itself")
	var z := _dome()
	var m := Pasture3DNodeGraph.new()
	m.graph = _graph(true)
	var st := _pending(m, z)
	var host := Pasture3DMound.new()
	host._graph_solve_one(st)
	host.free()
	m.adopt_sink_taps(st)
	var sink = m.graph.nodes[3]
	var pre := m.sink_taps_for(z, GW, GH)
	var own0 := Pasture3DGraphChannelSinks.own_eval_count
	var pre0 := Pasture3DGraphChannelSinks.pretapped_count
	var got: Dictionary = Pasture3DGraphChannelSinks._resolve_ports(m.graph, sink, 3, GW, GH, RECT, z, pre)
	var own_d := Pasture3DGraphChannelSinks.own_eval_count - own0
	var pre_d := Pasture3DGraphChannelSinks.pretapped_count - pre0
	var fresh: Dictionary = Pasture3DGraphChannelSinks._resolve_ports(m.graph, sink, 3, GW, GH, RECT, z, {})
	var dm := _worst(got.get("mask", PackedFloat32Array()), fresh.get("mask", PackedFloat32Array()))
	_check("B", not pre.is_empty() and own_d == 0 and pre_d == 1 and dm == 0.0,
			"pre-tapped fields %d; own evaluations %d (want 0), pre-tapped passes %d (want 1); mask vs a fresh pass %s m (want 0)"
			% [pre.size(), own_d, pre_d, str(dm)])
	var moved := z.duplicate()
	moved[100] += 1.0
	var none := m.sink_taps_for(moved, GW, GH)
	var own1 := Pasture3DGraphChannelSinks.own_eval_count
	Pasture3DGraphChannelSinks._resolve_ports(m.graph, sink, 3, GW, GH, RECT, moved, none)
	_control(none.is_empty() and Pasture3DGraphChannelSinks.own_eval_count - own1 == 1,
			"a moved surface gets no pre-tapped fields and evaluates once")


# --- C. frozen served ----------------------------------------------------------------------------------
func _served(p_res: Dictionary) -> int:
	var n := 0
	for r in p_res.get("frozen", []):
		if bool((r as Dictionary).get("served", false)):
			n += 1
	return n


func _c_frozen_served() -> void:
	print("[C] a FROZEN solver is served in a tap pass")
	var z := _dome()
	# Erosion stands in for any solver with a native freeze key (Salève included; GraphNativeFreezeGate
	# covers each one's key parity). A and B cover the LIVE case, which no freeze can serve.
	var g := Pasture3DTerrainGraph.new()
	var ero := Pasture3DGraphNodeErosion.new()
	ero.evaluation = Pasture3DGraphSolverNode.Evaluation.FROZEN
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), ero, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	g.set_output(2)
	var res: Dictionary = Pasture3DUtil.graph_eval_grid_frozen(g.compile_graph_program(), GW, GH, RECT, z)
	g.adopt_native_freeze(res.get("frozen", []))
	var c: Dictionary = g.compile_graph_program_multi([1])
	var slots := PackedInt32Array([int(c["slot_of"][1])])
	var chans := PackedInt32Array([1])
	var on: Dictionary = Pasture3DUtil.graph_eval_grid_taps(c["program"], GW, GH, RECT, z, slots, chans)
	_check("C", _served(on) == 1, "solvers served from the freeze cache: %d (want 1)" % _served(on))
	var bare: Dictionary = (c["program"] as Dictionary).duplicate()
	bare.erase("frozen")
	var off: Dictionary = Pasture3DUtil.graph_eval_grid_taps(bare, GW, GH, RECT, z, slots, chans)
	_control(_served(off) == 0, "without the freeze table, served %d (want 0)" % _served(off))
