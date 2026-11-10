# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSubgraphGate — subgraphs (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §11, P7).
#
# A Subgraph node never runs: a graph holding one is FLATTENED and every evaluator runs the flat view. So the
# question every criterion asks is whether the flat view is the graph the author would have built by hand.
#
#   [A] A grouped graph and its inline original compile to equivalent programs and evaluate bit-identically,
#       on the native route and the GDScript route.
#       Control: editing a node INSIDE the child changes the grouped result.
#   [B] Two instances of one child with different parameter values differ, and each equals the inline graph
#       with that value typed into a Const; a wired parameter port reads its wire.
#       Control: equal values give equal outputs.
#   [C] Editing a shared child re-bakes every parent that references it (`changed`, content key, result).
#       Control: a parent that does not reference it hears nothing.
#   [D] A graph that contains itself (directly, and through a second graph) is refused with a warning naming
#       the loop, passes its first input through, and raises no error.
#   [E] An incompatible child passes port 0 through and the parent's other nodes still run.
#       Control: the same child made compatible does not pass through.
#   [F] Group then Ungroup gives a program equal to the original, with and without a Parameter node in the
#       selection. Control: an edit inside the child before ungrouping does not.
#   [G] A graph's edit reach (what a rect bake pads by) is the same grouped as inline for a finite-reach node.
#       Control: an INF-reach node inside the subgraph makes it INF (the whole-footprint bake).
#   [H] The editor (§11.5): Group and Ungroup are ONE undo step each and undo restores the original program;
#       opening a Subgraph node shows its child with a breadcrumb, and the breadcrumb leads back.
#       Control: Group with nothing selected records no step.
#
# Programs are compared by a MERKLE SIGNATURE of the output slot (op, every per-slot param, and the signatures
# of its input slots, recursively), so two programs whose slots are numbered differently but compute the same
# thing compare equal, and any difference in what reaches the output does not.
#
# Every check goes through `_check`, which counts. The run fails unless EXPECTED_RAN checks reached their
# assert, so a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphSubgraphGate.tscn
extends Node

const GW := 48
const RECT := Rect2(-24.0, -24.0, 48.0, 48.0)
const EXPECTED_RAN := 43

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("\n=== GraphSubgraphGate: subgraphs (ports spec §11) ===\n")
	_criterion_a()
	_criterion_b()
	_criterion_c()
	_criterion_d()
	_criterion_e()
	_criterion_f()
	_criterion_g()
	_criterion_h()
	print("\n    checks reached: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1
		print("    !! the number of checks that ran is not the expected count; a criterion stopped early or changed")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SUBGRAPH PASS" if _fail == 0 else "GRAPH SUBGRAPH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	print("    %s %s" % ["ok" if p_ok else "!!", p_what])
	if not p_ok:
		_fail += 1


# ---- [A] ------------------------------------------------------------------------------------------------

func _criterion_a() -> void:
	print("[A] grouped and inline agree")
	var inline := _base()
	var grouped := _base()
	var r := grouped.group_into_subgraph([1, 2, 3, 4])
	_check(not r.has("error") and grouped.has_subgraphs(), "the selection grouped: %s" % str(r.get("error", "ok")))
	if r.has("error"):
		return
	_check(grouped.native_supported(), "the grouped graph lowers natively")
	_check(_sig(inline.compile_graph_program()) == _sig(grouped.compile_graph_program()),
			"the grouped and inline programs are equivalent")
	var surf := _bumpy(GW)
	for route in ["native", "gdscript"]:
		inline.force_gdscript_evaluation = route == "gdscript"
		grouped.force_gdscript_evaluation = route == "gdscript"
		var a := inline.evaluate(GW, GW, RECT, null, surf)
		var b := grouped.evaluate(GW, GW, RECT, null, surf)
		_check(a.size() == GW * GW and _diff(a, b) == 0.0, "%s: grouped bakes bit-identical to inline (%.6f)" % [route, _diff(a, b)])
	inline.force_gdscript_evaluation = false
	grouped.force_gdscript_evaluation = false
	# The standard mask on a Subgraph node is a Blend MIX of (input 0, output 0, mask) after it, as on any node.
	var mixed := _base()
	var m_c := Pasture3DGraphNodeConst.new(); m_c.value = 0.3
	var arr := mixed.nodes.duplicate()
	arr.append(_blend(Pasture3DGraphNodeBlend.Mode.MIX)); arr.append(m_c)
	mixed.nodes = arr
	mixed.disconnect_ports(4, 0, 5, 0)
	_wire(mixed, 0, 0, 6, 0); _wire(mixed, 4, 0, 6, 1); _wire(mixed, 7, 0, 6, 2); _wire(mixed, 6, 0, 5, 0)
	var masked := _base()
	var rm := masked.group_into_subgraph([1, 2, 3, 4])
	var msub: Pasture3DGraphNode = masked.nodes[int(rm["index"])]
	var m_c2 := Pasture3DGraphNodeConst.new(); m_c2.value = 0.3
	var arr2 := masked.nodes.duplicate(); arr2.append(m_c2); masked.nodes = arr2
	_wire(masked, masked.nodes.size() - 1, 0, int(rm["index"]), msub.framework_mask_port())
	_check(msub.framework_mask_port() >= 0 and _diff(mixed.evaluate(GW, GW, RECT, null, surf), masked.evaluate(GW, GW, RECT, null, surf)) == 0.0,
			"a masked Subgraph node equals Blend MIX(input, result, mask) inline")
	# CONTROL: a node inside the child.
	var child: Pasture3DTerrainGraph = r["child"]
	var c := _first(child, &"const")
	c.value = 9.0
	var a2 := inline.evaluate(GW, GW, RECT, null, surf)
	var b2 := grouped.evaluate(GW, GW, RECT, null, surf)
	_check(_diff(a2, b2) > 1.0, "control: a child edit moves the grouped bake off the inline one (%.3f m)" % _diff(a2, b2))


# ---- [B] ------------------------------------------------------------------------------------------------

func _criterion_b() -> void:
	print("[B] two instances, two values")
	var child := _amp_child()
	var p := Pasture3DTerrainGraph.create_empty()
	var sa := _sub(child); sa.set("values/amp", 3.0)
	var sb := _sub(child); sb.set("values/amp", 5.0)
	p.nodes = [Pasture3DGraphNodeInput.new(), sa, sb, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(p, 0, 0, 1, 0); _wire(p, 0, 0, 2, 0); _wire(p, 1, 0, 3, 0)
	var surf := _bumpy(GW)
	for route in ["native", "gdscript"]:
		p.force_gdscript_evaluation = route == "gdscript"
		var ea := p.evaluate(GW, GW, RECT, null, surf, 1)
		var eb := p.evaluate(GW, GW, RECT, null, surf, 2)
		var ia := _add_twin(3.0).evaluate(GW, GW, RECT, null, surf)
		var ib := _add_twin(5.0).evaluate(GW, GW, RECT, null, surf)
		_check(absf(_diff(ea, eb) - 2.0) < 1.0e-4, "%s: amp 3 and amp 5 differ by 2 m (%.6f)" % [route, _diff(ea, eb)])
		_check(_diff(ea, ia) == 0.0 and _diff(eb, ib) == 0.0, "%s: each instance equals its inline Const (%.6f, %.6f)" % [route, _diff(ea, ia), _diff(eb, ib)])
	p.force_gdscript_evaluation = false
	# A wired parameter port reads its wire, not the stored value.
	var k := Pasture3DGraphNodeConst.new(); k.value = 7.0
	var arr := p.nodes.duplicate(); arr.append(k); p.nodes = arr
	_wire(p, 4, 0, 1, sa.input_index_of(&"amp"))
	var ew := p.evaluate(GW, GW, RECT, null, surf, 1)
	_check(_diff(ew, _add_twin(7.0).evaluate(GW, GW, RECT, null, surf)) == 0.0, "a wired parameter port reads its wire (7)")
	# CONTROL: equal values.
	var q := Pasture3DTerrainGraph.create_empty()
	var qa := _sub(child); qa.set("values/amp", 4.0)
	var qb := _sub(child); qb.set("values/amp", 4.0)
	q.nodes = [Pasture3DGraphNodeInput.new(), qa, qb] as Array[Pasture3DGraphNode]
	_wire(q, 0, 0, 1, 0); _wire(q, 0, 0, 2, 0)
	_check(_diff(q.evaluate(GW, GW, RECT, null, surf, 1), q.evaluate(GW, GW, RECT, null, surf, 2)) == 0.0,
			"control: equal values give equal outputs")
	_check(qa.get("values/amp") == 4.0 and float(_sub(child).get("values/amp")) == 1.0,
			"an instance reads back its value; a fresh one reads the declared default")


# ---- [C] ------------------------------------------------------------------------------------------------

func _criterion_c() -> void:
	print("[C] a shared child re-bakes every parent that references it")
	var child := _amp_child()
	var p1 := _parent_of(child)
	var p2 := _parent_of(child)
	var p3 := _add_twin(1.0)
	var surf := _bumpy(GW)
	var b1 := p1.evaluate(GW, GW, RECT, null, surf)
	var b2 := p2.evaluate(GW, GW, RECT, null, surf)
	var counts := {"p1": 0, "p2": 0, "p3": 0}
	p1.changed.connect(func(): counts["p1"] += 1)
	p2.changed.connect(func(): counts["p2"] += 1)
	p3.changed.connect(func(): counts["p3"] += 1)
	var k1 := p1.content_key()
	var k3 := p3.content_key()
	var blend: Pasture3DGraphNodeBlend = _first(child, &"blend")
	blend.mode = Pasture3DGraphNodeBlend.Mode.SUB
	_check(counts["p1"] >= 1 and counts["p2"] >= 1, "both referencing parents emitted changed (%d, %d)" % [counts["p1"], counts["p2"]])
	_check(p1.content_key() != k1, "the parent's content key moved")
	var a1 := p1.evaluate(GW, GW, RECT, null, surf)
	var a2 := p2.evaluate(GW, GW, RECT, null, surf)
	_check(_diff(a1, b1) > 1.0 and _diff(a2, b2) > 1.0, "both parents' results follow the child (%.3f, %.3f m)" % [_diff(a1, b1), _diff(a2, b2)])
	_check(counts["p3"] == 0 and p3.content_key() == k3, "control: a parent that does not reference the child heard nothing")


# ---- [D] ------------------------------------------------------------------------------------------------

func _criterion_d() -> void:
	print("[D] a graph that contains itself is refused")
	var surf := _bumpy(GW)
	# Directly: g holds a Subgraph node naming g.
	var g := Pasture3DTerrainGraph.create_empty()
	var s := Pasture3DGraphNodeSubgraph.new()
	var sin := Pasture3DGraphNodeSubgraphInput.new()
	var sout := Pasture3DGraphNodeSubgraphOutput.new()
	g.nodes = [sin, s, sout, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	s.graph = g
	_wire(g, 0, 0, 1, 0); _wire(g, 1, 0, 2, 0); _wire(g, 1, 0, 3, 0)
	var out := g.evaluate(GW, GW, RECT, null, surf)
	_check(out.size() == GW * GW and _diff(out, _filled(GW * GW, 0.0)) == 0.0,
			"a self-containing graph evaluates, passing its input (default 0) through")
	_check(_has_line(g.graph_warnings(), "contains itself"), "it is warned: %s" % str(g.graph_warnings()))
	# Through a second graph: a -> b -> a, run from a parent.
	var ga := _passthrough_child()
	var gb := _passthrough_child()
	_first(ga, &"subgraph").graph = gb
	_first(gb, &"subgraph").graph = ga
	var p := _parent_of(ga)
	var po := p.evaluate(GW, GW, RECT, null, surf)
	_check(_diff(po, surf) == 0.0, "a two-graph loop evaluates and passes the input through (%.6f)" % _diff(po, surf))
	var w := p.graph_warnings()
	var named := false
	for l in ga.graph_warnings() + gb.graph_warnings() + w:
		if l.contains("contains itself") and l.contains("->"):
			named = true
	_check(named, "the loop is named in a warning")
	# A graph that holds itself is a reference cycle like any self-referencing resource; break it so the run
	# exits without leaking.
	s.graph = null
	_first(ga, &"subgraph").graph = null
	_first(gb, &"subgraph").graph = null


# ---- [E] ------------------------------------------------------------------------------------------------

func _criterion_e() -> void:
	print("[E] an incompatible child passes port 0 through")
	var surf := _bumpy(GW)
	var child := _amp_child()
	var p := Pasture3DTerrainGraph.create_empty()
	var s := _sub(child); s.set("values/amp", 3.0)
	var k := Pasture3DGraphNodeConst.new(); k.value = 2.0
	p.nodes = [Pasture3DGraphNodeInput.new(), s, k, _blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(p, 0, 0, 1, 0); _wire(p, 1, 0, 3, 0); _wire(p, 2, 0, 3, 1); _wire(p, 3, 0, 4, 0)
	var ok := p.evaluate(GW, GW, RECT, null, surf)
	_check(_diff(ok, _plus(surf, 5.0)) < 1.0e-4, "control: the compatible child runs (input + 3 + 2)")
	child.format_version = Pasture3DTerrainGraph.FORMAT_CURRENT + 1
	var bad := p.evaluate(GW, GW, RECT, null, surf)
	_check(_diff(bad, _plus(surf, 2.0)) < 1.0e-4, "an incompatible child passes its input through and the Blend still runs (input + 2): %.6f" % _diff(bad, _plus(surf, 2.0)))
	_check(_has_line(s.node_warnings(), "passes its first input through"), "the Subgraph node warns")


# ---- [F] ------------------------------------------------------------------------------------------------

func _criterion_f() -> void:
	print("[F] Group then Ungroup")
	var orig := _base()
	var g := _base()
	var r := g.group_into_subgraph([1, 2, 3, 4])
	var si := int(r.get("index", -1))
	var made := g.ungroup_subgraph(si)
	_check(not made.is_empty() and not g.has_subgraphs(), "ungrouped back to ordinary nodes (%d made)" % made.size())
	_check(_sig(orig.compile_graph_program()) == _sig(g.compile_graph_program()), "the program equals the original")
	# With a Parameter node in the selection.
	var po := _param_base()
	var pg := _param_base()
	var rp := pg.group_into_subgraph([1, 2])
	_check(not rp.has("error") and rp["child"].find_param(&"lift") != null, "grouping a Parameter declares it in the child")
	po.host_params = {&"lift": 4.5}; po._apply_params()
	pg.host_params = {&"lift": 4.5}; pg._apply_params()
	var surf := _bumpy(GW)
	_check(_diff(po.evaluate(GW, GW, RECT, null, surf), pg.evaluate(GW, GW, RECT, null, surf)) == 0.0,
			"the grouped Parameter still reads the host's value")
	pg.ungroup_subgraph(int(rp["index"]))
	_check(_sig(po.compile_graph_program()) == _sig(pg.compile_graph_program()), "and ungrouping gives the original program back")
	# CONTROL.
	var g2 := _base()
	var r2 := g2.group_into_subgraph([1, 2, 3, 4])
	_first(r2["child"], &"const").value = 9.0
	g2.ungroup_subgraph(int(r2["index"]))
	_check(_sig(orig.compile_graph_program()) != _sig(g2.compile_graph_program()), "control: a child edit before Ungroup changes the program")


# ---- [G] ------------------------------------------------------------------------------------------------

func _criterion_g() -> void:
	print("[G] edit reach through a subgraph")
	var inline := _leveler_graph(Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT)
	var grouped := _leveler_graph(Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT)
	var r := grouped.group_into_subgraph([1])
	_check(not r.has("error"), "the Leveler grouped: %s" % str(r.get("error", "ok")))
	var ri := inline.edit_reach()
	var rg := grouped.edit_reach()
	_check(is_finite(ri) and ri > 0.0 and rg == ri, "the grouped reach equals the inline one: %.3f vs %.3f m" % [rg, ri])
	var mi := _mound_reach(inline)
	var mg := _mound_reach(grouped)
	_check(is_finite(mi) and mg == mi, "a Mound pads its rect bake the same: %.3f vs %.3f m" % [mg, mi])
	# CONTROL: FLATTEN is INF.
	_first(r["child"], &"leveler").mode = Pasture3DGraphNodeLevelerBase.Mode.FLATTEN
	_check(is_inf(grouped.edit_reach()) and is_inf(_mound_reach(grouped)), "control: an INF-reach node inside sends it whole-footprint")


# ---- [H] ------------------------------------------------------------------------------------------------

func _criterion_h() -> void:
	print("[H] the editor: Group / Ungroup undo, open and back")
	var g := _base()
	var orig_sig := _sig(_base().compile_graph_program())
	var ed: Pasture3DGraphEditor = load("res://addons/pasture_3d/src/graph_editor.gd").new()
	add_child(ed)
	ed.initialize(null)
	ed.edit_graph(g)
	var ur: UndoRedo = ed._local_undo_redo
	var steps0 := ur.get_history_count()
	# CONTROL: nothing selected.
	ed.group_selected_into_subgraph()
	_check(ur.get_history_count() == steps0 and not g.has_subgraphs(), "control: Group with nothing selected records no step")
	_select(ed, [1, 2, 3, 4])
	ed.group_selected_into_subgraph()
	_check(ur.get_history_count() == steps0 + 1 and g.has_subgraphs() and g.nodes.size() == 3,
			"Group is one undo step (%d -> %d) and leaves 3 nodes (%d)" % [steps0, ur.get_history_count(), g.nodes.size()])
	ur.undo()
	_check(not g.has_subgraphs() and _sig(g.compile_graph_program()) == orig_sig, "undo restores the original program")
	ur.redo()
	var si := -1
	for i in range(g.nodes.size()):
		if g.nodes[i] != null and g.nodes[i].op() == &"subgraph":
			si = i
	_check(si >= 0, "redo groups again")
	if si < 0:
		ed.queue_free()
		return
	var child: Pasture3DTerrainGraph = g.nodes[si].graph
	ed.open_subgraph(si)
	_check(ed.graph == child and ed.subgraph_depth() == 1 and ed._crumb_bar.visible, "opening the Subgraph node shows its child, with a breadcrumb")
	ed.close_subgraph_to(0)
	_check(ed.graph == g and ed.subgraph_depth() == 0 and not ed._crumb_bar.visible, "the breadcrumb leads back")
	var steps1 := ur.get_history_count()
	_select(ed, [si])
	ed.ungroup_selected_subgraph()
	_check(ur.get_history_count() == steps1 + 1 and not g.has_subgraphs() and _sig(g.compile_graph_program()) == orig_sig,
			"Ungroup is one undo step and gives the original program")
	ur.undo()
	_check(g.has_subgraphs() and _sig(g.compile_graph_program()) == orig_sig, "undoing Ungroup brings the Subgraph node back, same program")
	# The panel's headless UndoRedo is never freed (every editor gate leaks that one object); its history
	# would take the graphs with it.
	ur.clear_history()
	ed.queue_free()


func _select(p_ed, p_indices: Array) -> void:
	for c in p_ed._graphedit.get_children():
		if c is GraphElement:
			c.set_selected(c is GraphNode and p_indices.has(p_ed._idx(c.name)))


# ---- fixtures -------------------------------------------------------------------------------------------

## Input(0) -> Blend ADD(2) <- Noise(1); -> Blend ADD(4) <- Const 2.5(3); -> Output(5).
func _base() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var nz := Pasture3DGraphNodeNoise.new()
	var c := Pasture3DGraphNodeConst.new(); c.value = 2.5
	g.nodes = [Pasture3DGraphNodeInput.new(), nz, _blend(Pasture3DGraphNodeBlend.Mode.ADD), c,
			_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 2, 0); _wire(g, 1, 0, 2, 1); _wire(g, 2, 0, 4, 0); _wire(g, 3, 0, 4, 1); _wire(g, 4, 0, 5, 0)
	return g


## Input(0) -> Blend ADD(2) <- Parameter lift(1) -> Output(3).
func _param_base() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.parameters = [_decl(&"lift", 1.0)] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new(); pn.param_id = &"lift"
	g.nodes = [Pasture3DGraphNodeInput.new(), pn, _blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 2, 0); _wire(g, 1, 0, 2, 1); _wire(g, 2, 0, 3, 0)
	return g


## Subgraph Input `in` -> Blend ADD <- Parameter `amp` (default 1) -> Subgraph Output `out`.
func _amp_child() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.parameters = [_decl(&"amp", 1.0)] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new(); pn.param_id = &"amp"
	g.nodes = [Pasture3DGraphNodeSubgraphInput.new(), pn, _blend(Pasture3DGraphNodeBlend.Mode.ADD),
			Pasture3DGraphNodeSubgraphOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 2, 0); _wire(g, 1, 0, 2, 1); _wire(g, 2, 0, 3, 0)
	g.output_node = 3
	return g


## Subgraph Input -> Subgraph(unassigned) -> Subgraph Output.
func _passthrough_child() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = [Pasture3DGraphNodeSubgraphInput.new(), Pasture3DGraphNodeSubgraph.new(),
			Pasture3DGraphNodeSubgraphOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 2, 0) # the direct wire stands until the Subgraph node has ports
	g.output_node = 2
	return g


## Input -> Subgraph(child) -> Output.
func _parent_of(p_child: Pasture3DTerrainGraph) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = [Pasture3DGraphNodeInput.new(), _sub(p_child), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 1, 0); _wire(g, 1, 0, 2, 0)
	return g


## Input -> Blend ADD <- Const v -> Output.
func _add_twin(p_v: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var c := Pasture3DGraphNodeConst.new(); c.value = p_v
	g.nodes = [Pasture3DGraphNodeInput.new(), c, _blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 2, 0); _wire(g, 1, 0, 2, 1); _wire(g, 2, 0, 3, 0)
	return g


## Input -> Leveler(mode, INSIDE wall) -> Output.
func _leveler_graph(p_mode: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var lv := Pasture3DGraphNodeLeveler.new()
	lv.mode = p_mode
	lv.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.INSIDE
	lv.feather = 12.0
	g.nodes = [Pasture3DGraphNodeInput.new(), lv, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 0, 1, 0); _wire(g, 1, 0, 2, 0)
	return g


## What a Mound hosting `p_g` pads a point drag's rect bake by (its reach past the brush's own shape).
func _mound_reach(p_g: Pasture3DTerrainGraph) -> float:
	var m := Pasture3DMound.new()
	var h := Pasture3DNodeGraph.new()
	h.graph = p_g
	h.feather_mode = Pasture3DNodeGraph.FeatherMode.OFF
	m.modifiers = [h] as Array[Pasture3DNode]
	var reach: float = m._stack_edit_reach(0.0)
	m.free()
	return reach


func _sub(p_child: Pasture3DTerrainGraph) -> Pasture3DGraphNodeSubgraph:
	var s := Pasture3DGraphNodeSubgraph.new()
	s.graph = p_child
	return s


func _decl(p_id: StringName, p_default: float) -> Pasture3DGraphParam:
	var d := Pasture3DGraphParam.new()
	d.id = p_id
	d.default_value = p_default
	d.range_min = -20.0
	d.range_max = 20.0
	return d


func _blend(p_mode: int) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _first(p_g: Pasture3DTerrainGraph, p_op: StringName) -> Pasture3DGraphNode:
	for n in p_g.nodes:
		if n != null and n.op() == p_op:
			return n
	return null


func _wire(p_g: Pasture3DTerrainGraph, p_from: int, p_fp: int, p_to: int, p_port: int) -> void:
	if not p_g.connect_ports(p_from, p_fp, p_to, p_port):
		_fail += 1
		print("    !! fixture wire %d:%d -> %d:%d refused: %s" % [p_from, p_fp, p_to, p_port, p_g.wire_problem(p_from, p_fp, p_to, p_port)])


## The Merkle signature of a compiled program's output slot.
func _sig(p_prog: Dictionary) -> int:
	if p_prog.is_empty():
		return 0
	var ops: PackedInt32Array = p_prog["ops"]
	var memo := {}
	return _slot_sig(p_prog, int(p_prog["output"]), ops.size(), memo)


const _SLOT_INPUTS := ["in0", "in1", "in2", "in3", "in_aux"]


func _slot_sig(p_prog: Dictionary, p_s: int, p_n: int, p_memo: Dictionary) -> int:
	if p_s < 0 or p_s >= p_n:
		return -1
	if p_memo.has(p_s):
		return p_memo[p_s]
	var parts: Array = []
	var keys: Array = p_prog.keys()
	keys.sort()
	for k in keys:
		var v = p_prog[k]
		if not (v is PackedInt32Array or v is PackedFloat32Array or v is Array):
			continue
		if v.size() != p_n:
			continue
		if _SLOT_INPUTS.has(k):
			parts.append([k, _slot_sig(p_prog, int(v[p_s]), p_n, p_memo)])
		else:
			parts.append([k, str(v[p_s])])
	var h := hash(parts)
	p_memo[p_s] = h
	return h


func _bumpy(p_gw: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gw)
	for iz in range(p_gw):
		for ix in range(p_gw):
			out[iz * p_gw + ix] = 6.0 * sin(float(ix) * 0.7) * cos(float(iz) * 0.5) + (8.0 if (ix / 6 + iz / 6) % 2 == 0 else 0.0)
	return out


func _plus(p_a: PackedFloat32Array, p_v: float) -> PackedFloat32Array:
	var out := p_a.duplicate()
	for i in range(out.size()):
		out[i] += p_v
	return out


func _filled(p_n: int, p_v: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n)
	out.fill(p_v)
	return out


func _diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var worst := 0.0
	for i in range(p_a.size()):
		worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _has_line(p_lines: PackedStringArray, p_needle: String) -> bool:
	for l in p_lines:
		if l.contains(p_needle):
			return true
	return false
