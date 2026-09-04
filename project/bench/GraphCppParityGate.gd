# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphCppParityGate — the native cell-run evaluator vs the GDScript oracle (terrain-graph C++ parity step).
#
# The claim: Pasture3DUtil.graph_cell_eval_grid (C++, src/pasture_3d_graph_ops.cpp), fed a program lowered
# by Pasture3DTerrainGraph.compile_cell_program, produces the SAME field as the GDScript folded evaluator
# (Pasture3DTerrainGraph.evaluate) to 1e-4 m — the same bar relief's C++ ops meet against their oracle. And
# the lowering's SCOPE holds: a graph carrying a grid node refuses to lower (stays on GDScript), a cell-only
# one lowers. House discipline: measure a field/flag and carry a control that must move if the path is dead.
extends Node

const GW := 40
const GH := 28
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const EPS := 1.0e-4 # native output stored to float32, same as the oracle's materialised grid

var _fail := 0


func _ready() -> void:
	print("=== GraphCppParityGate: native cell-run vs GDScript oracle ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_cell_eval_grid"):
		print("!! Pasture3DUtil.graph_cell_eval_grid is missing — the DLL is stale; rebuild the extension.")
		_fail += 1
		print("\n=== GRAPH CPP PARITY FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)
		return
	_a_chain_matches_native()
	_b_blend_modes_match_native()
	_c_grid_node_refuses_to_lower()
	_d_unwired_input_reads_zero()
	_e_terrace_matches_native()
	_f_the_mask_port_is_the_declared_one()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH CPP PARITY PASS" if _fail == 0 else "GRAPH CPP PARITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. A cell chain: native == GDScript evaluate, and the field is real (control) --------------------
func _a_chain_matches_native() -> void:
	print("[A] cell chain: native graph_cell_eval_grid == GDScript evaluate")
	var noise := _make_noise(5, 0.05)
	var g := _chain(noise, 6.0, 4.0, 0.5)
	var gd := g.evaluate(GW, GH, RECT)
	var nat := _native(g)
	var d := _max_abs_diff(gd, nat)
	print("    max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the native evaluator diverged from the oracle on a cell chain")
	# CONTROL: the paths are not both flat zero — the field must actually carry relief.
	var spread := _spread(nat)
	print("    control: native field spread = %.3f m (want > 0.05)" % spread)
	if spread <= 0.05:
		_fail += 1; print("    !! control dead — comparing two flat zeros would pass [A] for free")


# --- B. Every blend mode matches native; the modes differ from each other (control) ------------------
func _b_blend_modes_match_native() -> void:
	print("[B] each blend mode matches native (diamond A op B, A=noise, B=const)")
	var modes := {
		"ADD": Pasture3DGraphNodeBlend.Mode.ADD, "SUB": Pasture3DGraphNodeBlend.Mode.SUB,
		"MUL": Pasture3DGraphNodeBlend.Mode.MUL, "MAX": Pasture3DGraphNodeBlend.Mode.MAX,
		"MIN": Pasture3DGraphNodeBlend.Mode.MIN,
	}
	var fields := {}
	for name in modes:
		var g := _blend_graph(_make_noise(9, 0.06), 7.0, 1.5, modes[name])
		var nat := _native(g)
		var d := _max_abs_diff(g.evaluate(GW, GH, RECT), nat)
		print("    %-4s max |native - gdscript| = %.7f (want < %.6f)" % [name, d, EPS])
		if d > EPS:
			_fail += 1; print("    !! native diverged from the oracle on blend mode %s" % name)
		fields[name] = nat
	# CONTROL: the modes are genuinely different operations, so at least ADD and MUL must disagree — if the
	# compiler dropped `mode` and every mode did the same thing, native could still match GDScript and lie.
	var add_vs_mul := _max_abs_diff(fields["ADD"], fields["MUL"])
	print("    control: ADD vs MUL native fields differ by %.3f m (want > 0.05)" % add_vs_mul)
	if add_vs_mul <= 0.05:
		_fail += 1; print("    !! control dead — the blend mode is not reaching the native evaluator")


# --- C. A grid node refuses to lower; the same graph without it lowers (control) ---------------------
func _c_grid_node_refuses_to_lower() -> void:
	print("[C] a grid node stops the lowering (stays on the GDScript path)")
	var barrier := _grid_barrier(_make_noise(3, 0.05), 8.0, 3.0) # noise -> blend -> SMOOTH -> out
	var prog: Dictionary = barrier.compile_cell_program()
	print("    grid-barrier graph lowers to: %s (want empty)" % ("a program" if not prog.is_empty() else "{}"))
	if not prog.is_empty():
		_fail += 1; print("    !! a graph with a grid node lowered anyway — native would skip the Smooth")
	# CONTROL: drop the grid node and the SAME chain lowers to a program the native evaluator runs.
	var cell_only := _chain(_make_noise(3, 0.05), 8.0, 3.0, 1.0)
	var prog2: Dictionary = cell_only.compile_cell_program()
	print("    control: the cell-only chain lowers to: %s (want a program)" % ("a program" if not prog2.is_empty() else "{}"))
	if prog2.is_empty():
		_fail += 1; print("    !! a cell-only graph failed to lower")


# --- D. An unwired blend input reads 0 on both paths; wiring it changes the result (control) ---------
func _d_unwired_input_reads_zero() -> void:
	print("[D] an unwired blend input reads 0, native and oracle agree")
	# 0 noise -> 1 blend ADD, only port A wired; port B is unwired and must read 0 on both sides.
	var g := Pasture3DTerrainGraph.new()
	var noise := _noise(_make_noise(7, 0.05), 5.0)
	var blend := _blend(Pasture3DGraphNodeBlend.Mode.ADD)
	var nodes: Array[Pasture3DGraphNode] = [noise, blend]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])] # only A
	g.output_node = 1
	var d := _max_abs_diff(g.evaluate(GW, GH, RECT), _native(g))
	print("    max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! native and oracle disagree on an unwired input")
	# CONTROL: wire B to a const and the field moves — so the unwired port was really reading 0, not the
	# same value the wired one would give.
	var g2 := Pasture3DTerrainGraph.new()
	var noise2 := _noise(_make_noise(7, 0.05), 5.0)
	var konst := _const(3.0)
	var blend2 := _blend(Pasture3DGraphNodeBlend.Mode.ADD)
	var nodes2: Array[Pasture3DGraphNode] = [noise2, konst, blend2]
	g2.nodes = nodes2
	g2.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1])]
	g2.output_node = 2
	var moved := _max_abs_diff(_native(g), _native(g2))
	print("    control: wiring port B moves the native field by %.3f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the unwired port was not actually empty")


# --- E. Terrace node: native C++ == GDScript oracle ---------------------------------------------------
func _e_terrace_matches_native() -> void:
	print("[E] terrace node: native == GDScript evaluate")
	var g := Pasture3DTerrainGraph.new()
	var noise := _noise(_make_noise(11, 0.04), 25.0)
	var ter := Pasture3DGraphNodeRegistry.create(&"terrace")
	ter.set("band_height", 8.0)
	ter.set("hardness", 0.75)
	ter.set("amount", 0.9)
	var nodes: Array[Pasture3DGraphNode] = [noise, ter]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	g.output_node = 1
	var gd := g.evaluate(GW, GH, RECT)
	var nat := _native(g)
	var d := _max_abs_diff(gd, nat)
	print("    max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! native and oracle disagree on Terrace op")
	# Whole-graph evaluator parity
	var prog := g.compile_graph_program()
	var whole_nat := Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, PackedFloat32Array())
	var d_whole := _max_abs_diff(gd, whole_nat)
	print("    whole-graph max |native - gdscript| = %.7f (want < %.6f)" % [d_whole, EPS])
	if d_whole > EPS:
		_fail += 1; print("    !! whole-graph native and oracle disagree on Terrace op")


# --- F. A grid op reads its mask from the port the NODE declares (P2 §2.1) -----------------------------
#
# Six ops used to take their secondary GRID operand from `in1` unconditionally. That is Mudslide's mask
# port and nobody else's: Contrast declares `amount` on port 1 and `mask` on port 2, so the native and GPU
# evaluators bound a driving SCALAR as a per-cell mask and never read the real mask at all. Both halves
# failed together, which is why no gate caught it -- a graph with only a mask wired looked like a graph
# with nothing wired, and a graph with only a driven amount looked masked.
#
# So this criterion has to assert BOTH directions, and the second one is the one that would have caught it.
func _f_the_mask_port_is_the_declared_one() -> void:
	print("[F] Contrast reads its mask from port 2 and its amount from port 1")
	# Explicit window, not auto: an auto window is a function of the input's own extremes, so the two
	# variants below would normalise differently and the comparison would be measuring the window.
	var masked := _contrast_graph(true, true)
	var gd := _oracle(masked)
	var nat := Pasture3DUtil.graph_eval_grid(masked.compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
	var d := _max_abs_diff(gd, nat)
	print("    mask + driven amount   max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! native and oracle disagree with a mask on port 2")

	# THE INVERSE. No mask is wired here, only the driver on `amount` -- and that driver is a NOISE node,
	# not a Const, on purpose: a Const folds into the driven-parameter table and never occupies an input
	# slot, so `in1` would be -1 and the misread this asserts against could not even occur. A grid node
	# leaves a real slot on port 1, which is what the old code bound as the mask.
	var unmasked := _contrast_graph(false, true)
	var gd_u := _oracle(unmasked)
	var nat_u := Pasture3DUtil.graph_eval_grid(unmasked.compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
	var d_u := _max_abs_diff(gd_u, nat_u)
	print("    driven amount, NO mask max |native - gdscript| = %.7f (want < %.6f)" % [d_u, EPS])
	if d_u > EPS:
		_fail += 1; print("    !! the native path is treating the `amount` input as a mask")

	# CONTROL: the mask is actually read. If it were ignored the masked and unmasked fields would be the
	# same field, and both comparisons above would pass with the mask dropped on the floor.
	var moved := _max_abs_diff(nat, nat_u)
	print("    control: wiring the mask moves the native field by %.4f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the mask changed nothing, so F proves nothing")


## 0 noise -> 3 contrast port 0; 1 noise -> port 1 (`amount`, read as a SCALAR from cell 0); 2 noise -> port 2 (`mask`,
## a GRID) when p_mask. output 3.
func _contrast_graph(p_mask: bool, p_drive_amount: bool) -> Pasture3DTerrainGraph:
	var ct := Pasture3DGraphNodeRegistry.create(&"contrast")
	ct.set("explicit_window", true)
	ct.set("range_min", -30.0)
	ct.set("range_max", 30.0)
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(_make_noise(17, 0.045), 22.0), _noise(_make_noise(21, 0.03), 2.0),
		_noise(_make_noise(4, 0.02), 0.5), ct]
	var conns: Array = [[0, 0, 3, 0]]
	if p_drive_amount:
		conns.append([1, 0, 3, 1])
	if p_mask:
		conns.append([2, 0, 3, 2])
	return _graph(nodes, conns, 3)


# ---- helpers ----------------------------------------------------------------------------------------

## The GDScript ORACLE, and the toggle is not optional. Pasture3DTerrainGraph.evaluate() delegates to the
## native whole-graph evaluator whenever the graph is native_supported, so a bare evaluate() compared
## against graph_eval_grid compares the native path to ITSELF and passes no matter how wrong it is.
## force_gdscript_evaluation is what makes the reference an actual reference.
func _oracle(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var prev: bool = p_g.force_gdscript_evaluation
	p_g.force_gdscript_evaluation = true
	var out := p_g.evaluate(GW, GH, RECT)
	p_g.force_gdscript_evaluation = prev
	return out


func _native(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var prog: Dictionary = p_g.compile_cell_program()
	return Pasture3DUtil.graph_cell_eval_grid(prog, GW, GH, RECT)


## 0 noise(A) -> 2 blend ADD (b=1 const c1) -> 4 blend MUL (b=3 const c2); output 4.
func _chain(p_noise: FastNoiseLite, p_a: float, p_c1: float, p_c2: float) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(p_noise, p_a), _const(p_c1), _blend(Pasture3DGraphNodeBlend.Mode.ADD),
		_const(p_c2), _blend(Pasture3DGraphNodeBlend.Mode.MUL)]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 4, 0], [3, 0, 4, 1]], 4)


## 0 noise(A) -> 2 blend(mode) with b = 1 const(c); output 2.
func _blend_graph(p_noise: FastNoiseLite, p_a: float, p_c: float, p_mode) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [_noise(p_noise, p_a), _const(p_c), _blend(p_mode)]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1]], 2)


## 0 noise(A) -> 2 blend ADD (b = 1 const) -> 3 smooth; output 3. The blend feeds a GRID node.
func _grid_barrier(p_noise: FastNoiseLite, p_a: float, p_c: float) -> Pasture3DTerrainGraph:
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(p_noise, p_a), _const(p_c), _blend(Pasture3DGraphNodeBlend.Mode.ADD), sm]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]], 3)


func _graph(p_nodes: Array[Pasture3DGraphNode], p_conns: Array, p_out: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	g.nodes = p_nodes
	var conns: Array = []
	for c in p_conns:
		conns.append(PackedInt32Array(c))
	g.connections = conns
	g.output_node = p_out
	return g


func _noise(p_noise: FastNoiseLite, p_a: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_a
	return n


func _const(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_v
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = p_seed; n.frequency = p_freq
	return n


func _spread(p: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo if p.size() > 0 else 0.0


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
