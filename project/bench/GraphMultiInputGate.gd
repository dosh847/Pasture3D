# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMultiInputGate — multi-input ports and the Combine node (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md
# §12, P8).
#
# A Combine node never runs: the flat view replaces it with a left fold of Blends over its wires in row order.
# So every criterion asks whether that fold is the chain an author would have wired by hand.
#
#   [A] An N-input Combine equals the hand-built chain of Blends bit-for-bit, for every mode, on the native
#       and the GDScript route, and the two compile to equivalent programs.
#       Control: a hand chain with one step changed to SUB does not match.
#   [B] Reordering the wires of an ADD stays within float tolerance; of a MAX, exactly equal.
#       Control: the reordered program differs from the original (the reorder reached the compiler).
#   [C] Wiring: a multi port keeps every wire in order, the same wire twice is one, a disconnect takes out
#       only its wire, and the order survives a save and a load. None reads 0 (with a warning), one wire
#       passes through, a muted Combine passes its first wire.
#       Control: a two-input Blend port still replaces its wire.
#   [D] A mode edit re-folds: the result follows the new mode and equals the new hand chain.
#       Control: assigning the mode it already has does not rebuild the flat view.
#   [E] A Combine inside a subgraph, and Group then Ungroup around a Combine, keep the program.
#   [F] The editor: wires made into a Combine through the panel all stay, and undoing a disconnect puts the
#       wire back IN ITS PLACE, not at the end. Control: undoing a connect into a Blend port restores the
#       wire it replaced.
#
# Programs are compared by a Merkle signature of the output slot (GraphSubgraphGate explains it). Every check
# counts; the run fails unless EXPECTED_RAN were reached.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphMultiInputGate.tscn
extends Node

const GW := 48
const RECT := Rect2(-24.0, -24.0, 48.0, 48.0)
const EXPECTED_RAN := 42
const TMP := "user://graph_multi_input_gate.tres"

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("\n=== GraphMultiInputGate: multi-input ports (ports spec §12) ===\n")
	_criterion_a()
	_criterion_b()
	_criterion_c()
	_criterion_d()
	_criterion_e()
	_criterion_f()
	print("\n    checks reached: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1
		print("    !! the number of checks that ran is not the expected count; a criterion stopped early or changed")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH MULTI INPUT PASS" if _fail == 0 else "GRAPH MULTI INPUT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	print("    %s %s" % ["ok" if p_ok else "!!", p_what])
	if not p_ok:
		_fail += 1


const MODE_NAMES := ["ADD", "MAX", "MIN", "MUL"]


# ---- [A] ------------------------------------------------------------------------------------------------

func _criterion_a() -> void:
	print("[A] an N-input Combine is the hand-built chain of Blends")
	var surf := _bumpy(GW)
	for m in range(4):
		var c := _combine_graph(m, 5)
		var h := _chain_graph(_blend_of(m), 5)
		_check(_sig(c.compile_graph_program()) == _sig(h.compile_graph_program()),
				"%s x5: equivalent programs" % MODE_NAMES[m])
		for route in ["native", "gdscript"]:
			c.force_gdscript_evaluation = route == "gdscript"
			h.force_gdscript_evaluation = route == "gdscript"
			var a := c.evaluate(GW, GW, RECT, null, surf)
			var b := h.evaluate(GW, GW, RECT, null, surf)
			_check(a.size() == GW * GW and _diff(a, b) == 0.0,
					"%s x5 %s: bit-identical to the chain (%.6f)" % [MODE_NAMES[m], route, _diff(a, b)])
	for n in [2, 3]:
		var c := _combine_graph(0, n)
		var h := _chain_graph(Pasture3DGraphNodeBlend.Mode.ADD, n)
		_check(_sig(c.compile_graph_program()) == _sig(h.compile_graph_program()), "ADD x%d: equivalent programs" % n)
		var d := _diff(c.evaluate(GW, GW, RECT, null, surf), h.evaluate(GW, GW, RECT, null, surf))
		_check(d == 0.0, "ADD x%d native: bit-identical (%.6f)" % [n, d])
	_check(_combine_graph(0, 5).native_supported(), "a graph with a Combine lowers natively")
	# CONTROL: one step of the hand chain changed.
	var off := _chain_graph(Pasture3DGraphNodeBlend.Mode.ADD, 5)
	for nd in off.nodes:
		if nd is Pasture3DGraphNodeBlend:
			nd.mode = Pasture3DGraphNodeBlend.Mode.SUB
			break
	var dc := _diff(_combine_graph(0, 5).evaluate(GW, GW, RECT, null, surf), off.evaluate(GW, GW, RECT, null, surf))
	_check(dc > 0.01, "control: a chain with one SUB step differs (%.4f)" % dc)


# ---- [B] ------------------------------------------------------------------------------------------------

func _criterion_b() -> void:
	print("[B] reordering wires")
	var surf := _bumpy(GW)
	for m in [0, 1]:
		var fwd := _combine_graph(m, 5)
		var rev := _combine_graph(m, 5, true)
		_check(_sig(fwd.compile_graph_program()) != _sig(rev.compile_graph_program()),
				"control: the %s reorder reaches the compiler (programs differ)" % MODE_NAMES[m])
		for route in ["native", "gdscript"]:
			fwd.force_gdscript_evaluation = route == "gdscript"
			rev.force_gdscript_evaluation = route == "gdscript"
			var d := _diff(fwd.evaluate(GW, GW, RECT, null, surf), rev.evaluate(GW, GW, RECT, null, surf))
			if m == 0:
				_check(d <= 1e-3, "ADD %s: reversed within float tolerance (%.8f)" % [route, d])
			else:
				_check(d == 0.0, "MAX %s: reversed exactly equal (%.8f)" % [route, d])


# ---- [C] ------------------------------------------------------------------------------------------------

func _criterion_c() -> void:
	print("[C] wiring a multi port")
	var g := _sources()
	var ci := g.add_node(Pasture3DGraphNodeCombine.new())
	var oi := g.add_node(Pasture3DGraphNodeOutput.new())
	_wire(g, ci, 0, oi, 0)
	g.output_node = oi
	for s in [2, 0, 3]:
		_wire(g, s, 0, ci, 0)
	_check(_into(g, ci) == [2, 0, 3], "three wires stay, in the order made: %s" % str(_into(g, ci)))
	g.connect_ports(0, 0, ci, 0)
	_check(_into(g, ci) == [2, 0, 3], "the same wire twice is one wire: %s" % str(_into(g, ci)))
	g.disconnect_ports(0, 0, ci, 0)
	_check(_into(g, ci) == [2, 3], "a disconnect takes out only its wire: %s" % str(_into(g, ci)))
	_wire(g, 4, 0, ci, 0)
	var sig := _sig(g.compile_graph_program())
	var err := ResourceSaver.save(g, TMP)
	var back: Pasture3DTerrainGraph = ResourceLoader.load(TMP, "", ResourceLoader.CACHE_MODE_IGNORE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	_check(err == OK and back != null and _into(back, ci) == [2, 3, 4] and _sig(back.compile_graph_program()) == sig,
			"the order survives a save and a load: %s" % (str(_into(back, ci)) if back != null else "load failed"))
	# CONTROL: an ordinary input still replaces.
	var bl := g.add_node(_blend(Pasture3DGraphNodeBlend.Mode.ADD))
	_wire(g, 0, 0, bl, 0)
	_wire(g, 2, 0, bl, 0)
	_check(_into(g, bl) == [2], "control: a Blend port keeps only its last wire: %s" % str(_into(g, bl)))

	var surf := _bumpy(GW)
	var none := _combine_graph(0, 0)
	var z := none.evaluate(GW, GW, RECT, null, surf)
	_check(z.size() == GW * GW and _diff(z, _filled(GW * GW, 0.0)) == 0.0, "no wires reads 0")
	_check(_has_line(none.graph_warnings(), "in (any number)"), "no wires is warned about as an unwired required input")
	var one := _combine_graph(0, 1)
	var d1 := _diff(one.evaluate(GW, GW, RECT, null, surf), surf)
	_check(d1 == 0.0, "one wire passes through (%.6f)" % d1)
	var muted := _combine_graph(0, 5)
	_first(muted, &"combine").muted = true
	var dm := _diff(muted.evaluate(GW, GW, RECT, null, surf), surf)
	_check(dm == 0.0, "a muted Combine passes its first wire (%.6f)" % dm)


# ---- [D] ------------------------------------------------------------------------------------------------

func _criterion_d() -> void:
	print("[D] a mode edit re-folds")
	var surf := _bumpy(GW)
	var g := _combine_graph(1, 5)
	var before := g.evaluate(GW, GW, RECT, null, surf)
	var builds := g.flat_build_count
	var cn: Pasture3DGraphNodeCombine = _first(g, &"combine")
	cn.mode = Pasture3DGraphNodeCombine.Mode.MAX
	g.flat_view()
	_check(g.flat_build_count == builds, "control: assigning the same mode does not rebuild (%d -> %d)" % [builds, g.flat_build_count])
	cn.mode = Pasture3DGraphNodeCombine.Mode.MIN
	var after := g.evaluate(GW, GW, RECT, null, surf)
	_check(g.flat_build_count > builds and _diff(before, after) > 0.01, "MAX -> MIN rebuilt the fold and moved the result")
	var dh := _diff(after, _chain_graph(Pasture3DGraphNodeBlend.Mode.MIN, 5).evaluate(GW, GW, RECT, null, surf))
	_check(dh == 0.0, "and equals the hand MIN chain (%.6f)" % dh)


# ---- [E] ------------------------------------------------------------------------------------------------

func _criterion_e() -> void:
	print("[E] Combine and subgraphs")
	var surf := _bumpy(GW)
	# A child holding a Combine of its Subgraph Input and two Consts, used through a Subgraph node.
	var child := Pasture3DTerrainGraph.create_empty()
	var c1 := Pasture3DGraphNodeConst.new(); c1.value = 1.75
	var c2 := Pasture3DGraphNodeConst.new(); c2.value = -0.4
	var cb := Pasture3DGraphNodeCombine.new()
	child.nodes = [Pasture3DGraphNodeSubgraphInput.new(), c1, c2, cb, Pasture3DGraphNodeSubgraphOutput.new()] as Array[Pasture3DGraphNode]
	_wire(child, 0, 0, 3, 0); _wire(child, 1, 0, 3, 0); _wire(child, 2, 0, 3, 0); _wire(child, 3, 0, 4, 0)
	child.output_node = 4
	var parent := Pasture3DTerrainGraph.create_empty()
	var sub := Pasture3DGraphNodeSubgraph.new(); sub.graph = child
	parent.nodes = [Pasture3DGraphNodeInput.new(), sub, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(parent, 0, 0, 1, 0); _wire(parent, 1, 0, 2, 0)
	parent.output_node = 2
	var d := _diff(parent.evaluate(GW, GW, RECT, null, surf), _plus(surf, 1.75 - 0.4))
	_check(d < 1e-4, "a Combine inside a subgraph folds its wires (%.6f)" % d)
	# Group the Combine with two of its sources, then Ungroup.
	var g := _combine_graph(0, 5)
	var orig := _sig(g.compile_graph_program())
	var ci := g.nodes.find(_first(g, &"combine"))
	var r := g.group_into_subgraph([1, 2, ci])
	_check(not r.has("error") and _sig(g.compile_graph_program()) == orig,
			"grouping a Combine with two of its sources keeps the program: %s" % str(r.get("error", "ok")))
	var made := g.ungroup_subgraph(int(r.get("index", -1))) if not r.has("error") else []
	_check(not made.is_empty() and _sig(g.compile_graph_program()) == orig, "ungrouping it again keeps the program")


# ---- [F] ------------------------------------------------------------------------------------------------

func _criterion_f() -> void:
	print("[F] the editor")
	var g := _sources()
	var ci := g.add_node(Pasture3DGraphNodeCombine.new())
	var bl := g.add_node(_blend(Pasture3DGraphNodeBlend.Mode.ADD))
	var oi := g.add_node(Pasture3DGraphNodeOutput.new())
	_wire(g, ci, 0, oi, 0)
	g.output_node = oi
	var ed: Pasture3DGraphEditor = load("res://addons/pasture_3d/src/graph_editor.gd").new()
	add_child(ed)
	ed.initialize(null)
	ed.edit_graph(g)
	var ur: UndoRedo = ed._local_undo_redo
	for s in [1, 2, 3]:
		ed._action_connect(s, 0, ci, 0)
	_check(_into(g, ci) == [1, 2, 3], "three wires made in the panel all stay: %s" % str(_into(g, ci)))
	ed._action_disconnect(1, 0, ci, 0)
	ur.undo()
	_check(_into(g, ci) == [1, 2, 3], "undoing a disconnect puts the wire back in its place: %s" % str(_into(g, ci)))
	# CONTROL: an ordinary port.
	ed._action_connect(0, 0, bl, 0)
	ed._action_connect(4, 0, bl, 0)
	ur.undo()
	_check(_into(g, bl) == [0], "control: undoing a connect into a Blend port restores the wire it replaced: %s" % str(_into(g, bl)))
	ur.clear_history()
	ed.queue_free()


# ---- fixtures -------------------------------------------------------------------------------------------

## Five sources: Input(0), Noise ×3.7 (1), Noise ×0.013 (2), Const 1234.567 (3), Const -0.3 (4). Different
## magnitudes, so the order of an ADD moves float32 rounding.
func _sources() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var n1 := Pasture3DGraphNodeNoise.new(); n1.amplitude = 3.7; n1.noise = _fnl(11, 0.07)
	var n2 := Pasture3DGraphNodeNoise.new(); n2.amplitude = 0.013; n2.noise = _fnl(29, 0.31)
	var k1 := Pasture3DGraphNodeConst.new(); k1.value = 1234.567
	var k2 := Pasture3DGraphNodeConst.new(); k2.value = -0.3
	g.nodes = [Pasture3DGraphNodeInput.new(), n1, n2, k1, k2] as Array[Pasture3DGraphNode]
	return g


## A Noise node with no FastNoiseLite reads 0, which would make every source but two a constant.
func _fnl(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = p_seed
	n.frequency = p_freq
	return n


## The first `p_n` sources folded by a Combine in mode `p_mode` (reversed order when `p_rev`) -> Output.
func _combine_graph(p_mode: int, p_n: int, p_rev := false) -> Pasture3DTerrainGraph:
	var g := _sources()
	var cn := Pasture3DGraphNodeCombine.new(); cn.mode = p_mode
	var ci := g.add_node(cn)
	var oi := g.add_node(Pasture3DGraphNodeOutput.new())
	var order := range(p_n)
	if p_rev:
		order.reverse()
	for s in order:
		_wire(g, s, 0, ci, 0)
	_wire(g, ci, 0, oi, 0)
	g.output_node = oi
	return g


## The same fold wired by hand: ((s0 op s1) op s2) … -> Output.
func _chain_graph(p_blend_mode: int, p_n: int) -> Pasture3DTerrainGraph:
	var g := _sources()
	var oi := g.add_node(Pasture3DGraphNodeOutput.new())
	var acc := 0
	for j in range(1, p_n):
		var bi := g.add_node(_blend(p_blend_mode))
		_wire(g, acc, 0, bi, 0)
		_wire(g, j, 0, bi, 1)
		acc = bi
	_wire(g, acc, 0, oi, 0)
	g.output_node = oi
	return g


func _blend_of(p_combine_mode: int) -> int:
	return [Pasture3DGraphNodeBlend.Mode.ADD, Pasture3DGraphNodeBlend.Mode.MAX,
			Pasture3DGraphNodeBlend.Mode.MIN, Pasture3DGraphNodeBlend.Mode.MUL][p_combine_mode]


## The sources wired into input 0 of node `p_to`, in row order.
func _into(p_g: Pasture3DTerrainGraph, p_to: int) -> Array:
	var out: Array = []
	for c in p_g.connections:
		if int(c[2]) == p_to and int(c[3]) == 0:
			out.append(int(c[0]))
	return out


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
		elif v[p_s] is Object:
			# A program holds a noise slot's FastNoiseLite by reference; two equal ones are one program.
			parts.append([k, var_to_str(v[p_s]) if v[p_s] != null else "null"])
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
