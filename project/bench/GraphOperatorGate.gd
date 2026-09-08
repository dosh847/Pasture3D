# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphOperatorGate — the operator expansion: the FLOAT plumbing, the five new Blend modes across all
# three kernels, and the COLOUR sideband.
#
# The claims, in order:
#   [A] A value port can be DRIVEN. `Const Float` emits PortType.FLOAT, the connection matrix crosses the
#       scalar values with the scalar fields, and a Salève's dx/dy — the ports the user could not set at
#       all — are typed as the grids they are actually read as.
#   [B] Every Blend mode agrees across FOUR implementations: the CPU cell kernel, the CPU grid kernel,
#       the GDScript node, and (not here) the GPU shader. The five new modes are defined in the same
#       four places, and a divergence in any one of them is silent in ordinary use.
#   [C] The degenerate cases are DEFINED, not left to the FPU. DIV by zero and POW of a negative are the
#       two that produce an inf or a NaN if nobody decides, and either one is a hole in the terrain that
#       survives every downstream op.
#   [D] The COLOUR sideband resolves. Const Color — the only producer of a COLOR port in the registry —
#       reaches a Color Sink, Color Mix folds two of them, and a node carrying no colour is still refused.
#   [E] Color Mix costs the graph nothing. It is not in `graph_op_ids()` and a graph containing one still
#       reports `native_supported()`, because a COLOR port is never tapped and so the node is never an
#       ancestor of a compile root. §10: one op the kernel does not know drops the WHOLE graph.
#
# ---- WHAT THIS GATE CANNOT SAY ----
#
# It does not run the GPU shader. `src/pasture_3d_graph_gpu.cpp` carries a fourth copy of the mode
# arithmetic and only GraphGpuParityGate, on a machine with a RenderingDevice, can compare it.
#
# [D] stops at `_resolve_ports` — the colour that reaches the writer. Whether that colour lands on a
# layer is GraphSinkBakeGate's claim, not this one.
extends Node

const GW := 40
const GH := 28
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const EPS := 1.0e-4 # both native routes store to float32; so does the oracle's materialised grid

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== GraphOperatorGate: value ports, blend modes, colour sideband ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_cell_eval_grid"):
		print("!! Pasture3DUtil.graph_cell_eval_grid is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return
	_a_value_ports_can_be_driven()
	_b_every_mode_agrees_across_kernels()
	_c_degenerate_cases_are_defined()
	_d_the_colour_sideband_resolves()
	_e_color_mix_costs_nothing()
	print("\n    completed checks: %d" % _checks)
	if _checks < 36:
		print("    !! FEWER CHECKS COMPLETED THAN EXPECTED — a criterion threw before it asserted.")
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["GRAPH OPERATOR PASS" if _fail == 0 else "GRAPH OPERATOR FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _ok(p_cond: bool, p_msg: String) -> void:
	_checks += 1
	if not p_cond:
		_fail += 1
		print("    !! %s" % p_msg)


# --- A. A value port can be driven -------------------------------------------------------------------
func _a_value_ports_can_be_driven() -> void:
	print("[A] the FLOAT plumbing: a value port has a producer, a wire and an effect")
	var T := Pasture3DGraphNode.PortType

	var c := Pasture3DGraphNodeConst.new()
	var ct: PackedInt32Array = c.output_port_types()
	print("    Const Float output type = %s (want [FLOAT=%d])" % [str(ct), T.FLOAT])
	_ok(ct.size() == 1 and int(ct[0]) == T.FLOAT,
			"Const Float does not emit FLOAT — every FLOAT port in the plugin is then unwireable")

	# The Salève's dx/dy: read as `p_inputs[1] as PackedFloat32Array`, so they are FIELDS. Declared FLOAT
	# they were both mistyped AND inert, since a field type has no inline property to fall back to.
	var sal := Pasture3DGraphNodeHydraulicSaleve.new()
	var st: PackedInt32Array = sal.input_port_types()
	print("    Saleve input types = %s (want dx/dy = SIGNED=%d)" % [str(st), T.SIGNED])
	_ok(st.size() >= 3 and int(st[1]) == T.SIGNED and int(st[2]) == T.SIGNED,
			"the Saleve's dx/dy are not typed as the grids they are read as")

	# THE REAL MATRIX. register_connection_types is static, so this is the same call the editor makes.
	var ge := GraphEdit.new()
	add_child(ge)
	Pasture3DGraphEditor.register_connection_types(ge)
	var want_valid := [[T.FLOAT, T.FLOAT], [T.FLOAT, T.HEIGHT], [T.HEIGHT, T.FLOAT], [T.INT, T.INT],
			[T.HEIGHT, T.INT], [T.MASK, T.FLOAT], [T.SIGNED, T.SIGNED]]
	for pair in want_valid:
		var v: bool = ge.is_valid_connection_type(pair[0], pair[1])
		print("    %d -> %d valid = %s (want true)" % [pair[0], pair[1], v])
		_ok(v, "the matrix refuses a wire the evaluator already implements (%d -> %d)" % [pair[0], pair[1]])
	# CONTROL: the crossing is SELECTIVE. A PATH carries a resource and a COLOR four floats; if these
	# came back valid too, the loop above would be measuring "everything connects to everything".
	var want_invalid := [[T.FLOAT, T.PATH], [T.PATH, T.FLOAT], [T.COLOR, T.HEIGHT], [T.HEIGHT, T.COLOR]]
	for pair in want_invalid:
		var v: bool = ge.is_valid_connection_type(pair[0], pair[1])
		print("    control: %d -> %d valid = %s (want false)" % [pair[0], pair[1], v])
		_ok(not v, "the matrix permits %d -> %d — the crossing is not selective" % [pair[0], pair[1]])
	ge.queue_free()

	# AND IT HAS AN EFFECT. Driving Furrows' `direction` must move the field; a wire the compiler
	# accepted and then ignored would satisfy every type check above.
	# BOTH ROUTES. The native evaluator reads a driven param through `native_param_ports()` and the
	# GDScript one as `p_inputs[n][0]`; they are separate implementations of the same contract, and
	# `evaluate()` silently picks the native one whenever it can — so testing it alone tests one.
	for forced in [false, true]:
		var undriven := _furrows_field(false, forced)
		var driven := _furrows_field(true, forced)
		var d := _max_abs_diff(undriven, driven)
		print("    %-8s driven vs undriven furrows.direction: max |diff| = %.6f (want > 0.01)"
				% ["gdscript" if forced else "native", d])
		_ok(d > 0.01, "wiring a Const Float into a value port changed nothing on the %s route"
				% ("gdscript" if forced else "native"))


func _furrows_field(p_drive: bool, p_force_gd: bool = false) -> PackedFloat32Array:
	var f := Pasture3DGraphNodeFurrows.new()
	var nodes: Array[Pasture3DGraphNode] = [f, _const(35.0)]
	var conns: Array = []
	if p_drive:
		# Port 1 is `direction`; see the node's own eval, which reads it as cell 0 of the source buffer.
		conns.append([1, 0, 0, 1])
	var g := _graph(nodes, conns, 0)
	if p_force_gd:
		return _oracle(g)
	return g.evaluate(GW, GH, RECT)


# --- B. Every mode agrees across the kernels ----------------------------------------------------------
func _b_every_mode_agrees_across_kernels() -> void:
	print("[B] each Blend mode: CPU cell kernel == CPU grid kernel == GDScript node")
	var M := Pasture3DGraphNodeBlend.Mode
	var modes := {"ADD": M.ADD, "SUB": M.SUB, "MUL": M.MUL, "MAX": M.MAX, "MIN": M.MIN,
			"MIX": M.MIX, "DIV": M.DIV, "POW": M.POW, "DIFFERENCE": M.DIFFERENCE,
			"SCREEN": M.SCREEN, "OVERLAY": M.OVERLAY}
	var fields := {}
	var worst := 0.0
	for name in modes:
		var g := _blend_graph(modes[name])
		var gd := _oracle(g)
		var cell: PackedFloat32Array = Pasture3DUtil.graph_cell_eval_grid(g.compile_cell_program(), GW, GH, RECT)
		var grid: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), GW, GH,
				RECT, PackedFloat32Array())
		var dc := _max_abs_diff(gd, cell)
		var dg := _max_abs_diff(gd, grid)
		print("    %-10s cell %.7f  grid %.7f  (want < %.6f)" % [name, dc, dg, EPS])
		_ok(dc < EPS, "the CPU CELL kernel diverges from the GDScript node on %s" % name)
		_ok(dg < EPS, "the CPU GRID kernel diverges from the GDScript node on %s" % name)
		fields[name] = grid
		worst = maxf(worst, maxf(dc, dg))
	# CONTROL 1: the modes are genuinely different operations. If the compiler dropped `mode`, every
	# comparison above would be one implementation against itself and would pass for free.
	var distinct := {}
	for name in fields:
		distinct[_signature(fields[name])] = true
	print("    control: %d modes produce %d distinct fields (want %d)" % [fields.size(), distinct.size(), fields.size()])
	_ok(distinct.size() == fields.size(), "two modes produced the same field — `mode` is not reaching a kernel")
	# CONTROL 2: the comparison can SEE a divergence. Cross ADD's native field against MUL's oracle;
	# a tolerance loose enough to hide a wrong mode would swallow this too.
	var cross := _max_abs_diff(fields["ADD"], _oracle(_blend_graph(M.MUL)))
	print("    control: ADD-native vs MUL-oracle = %.4f (want > %.6f, i.e. detectable)" % [cross, EPS])
	_ok(cross > EPS, "the comparison cannot detect a wrong mode — [B] measured nothing")


# --- C. The degenerate cases are defined --------------------------------------------------------------
func _c_degenerate_cases_are_defined() -> void:
	print("[C] DIV by zero and POW of a negative are decided, not left to the FPU")
	var M := Pasture3DGraphNodeBlend.Mode
	# a = -3 (negative, so POW's guard fires), b = 0 (so DIV's guard fires). Both kernels and the node.
	for entry in [["DIV", M.DIV], ["POW", M.POW]]:
		var g := _const_blend_graph(-3.0, 0.0, entry[1])
		var gd := _oracle(g)
		var cell: PackedFloat32Array = Pasture3DUtil.graph_cell_eval_grid(g.compile_cell_program(), GW, GH, RECT)
		var grid: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), GW, GH,
				RECT, PackedFloat32Array())
		print("    %s(-3, 0): gdscript %s  cell %s  grid %s (want 0, finite, everywhere)"
				% [entry[0], _first(gd), _first(cell), _first(grid)])
		_ok(_all_finite(gd) and _all_finite(cell) and _all_finite(grid),
				"%s produced a non-finite cell — that is a hole every downstream op carries" % entry[0])
		_ok(absf(_first(gd)) < EPS and absf(_first(cell)) < EPS and absf(_first(grid)) < EPS,
				"%s's degenerate case is not the declared 0 in all three implementations" % entry[0])
	# CONTROL: the same modes on ORDINARY operands are not 0, so [C] is not asserting that DIV is
	# always zero — it is asserting that the guard fires exactly where it is declared to.
	var ok_div := _oracle(_const_blend_graph(6.0, 2.0, M.DIV))
	print("    control: DIV(6, 2) = %s (want 3)" % _first(ok_div))
	_ok(absf(_first(ok_div) - 3.0) < EPS, "DIV is broken for ordinary operands — the guard is swallowing everything")


# --- D. The colour sideband resolves ------------------------------------------------------------------
func _d_the_colour_sideband_resolves() -> void:
	print("[D] a COLOR port resolves from the wired node, and folds through Color Mix")

	# 1 — A Const Color reaches a Color Sink. This is the defect: the resolver asked `"color" in node`,
	# Const Color's export is named `value`, and so the ONE legal source was refused by name.
	var res := _resolve_sink([_mask_source(), _const_color(Color(0.25, 0.5, 0.75, 1.0))], true)
	print("    Const Color -> Color Sink: %s" % str(res.get("error", res.get("values", {}).get("color", "<none>"))))
	_ok(not res.has("error"), "a Const Color wired into a Color Sink was refused: %s" % str(res.get("error", "")))
	var got = res.get("values", {}).get("color", null)
	_ok(got is Color and absf(got.r - 0.25) < 0.001 and absf(got.b - 0.75) < 0.001,
			"the resolved colour is not the Const Color's own value")

	# 2 — Color Mix folds. MUL of white by (0.5,0.5,0.5) at factor 1 is a half-grey.
	var mix := Pasture3DGraphNodeColorMix.new()
	mix.mode = Pasture3DGraphNodeColorMix.Mode.MUL
	mix.factor = 1.0
	var res2 := _resolve_sink([_mask_source(), _const_color(Color(0.5, 0.5, 0.5, 1.0)), mix], true,
			[[1, 0, 2, 1]], 2)
	var got2 = res2.get("values", {}).get("color", null)
	print("    Color Mix MUL(white, 0.5 grey) = %s (want ~0.5 grey)" % str(got2))
	_ok(got2 is Color and absf(got2.r - 0.5) < 0.002, "Color Mix did not fold its wired `b` input")

	# 3 — factor is not decorative. The SAME fold at 0 must be pure A (white).
	mix.factor = 0.0
	var res3 := _resolve_sink([_mask_source(), _const_color(Color(0.5, 0.5, 0.5, 1.0)), mix], true,
			[[1, 0, 2, 1]], 2)
	var got3 = res3.get("values", {}).get("color", null)
	print("    control: the same Mix at factor 0 = %s (want white)" % str(got3))
	_ok(got3 is Color and absf(got3.r - 1.0) < 0.002, "`factor` changed nothing — the fold ignores it")

	# 4 — CONTROL: the refusal still works. A node with no colour on a COLOR port must be named, not
	# silently replaced by the sink's own tint (§4.4: an optional input that falls back is an impostor).
	var res4 := _resolve_sink([_mask_source(), _const(3.0)], true)
	print("    control: a colourless node on the COLOR port -> %s (want an error)" % str(res4.get("error", "<accepted>")))
	_ok(res4.has("error"), "a node carrying no colour was accepted on a COLOR port")


# --- E. Color Mix costs the graph nothing --------------------------------------------------------------
func _e_color_mix_costs_nothing() -> void:
	print("[E] Color Mix never lowers, so it cannot take the graph off the native path")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	print("    graph_op_ids() knows color_mix = %s (want false; it knows %d ops)"
			% [str(ids.has("color_mix")), ids.size()])
	_ok(not ids.has("color_mix"), "color_mix claims a kernel op id it has no kernel for")
	# CONTROL: the table is the real one, not an empty dictionary that would make the line above free.
	_ok(ids.has("blend"), "graph_op_ids() does not know `blend` — the table read is not the kernel's")

	# A whole graph: noise -> output, PLUS a Color Mix feeding a Color Sink off to the side.
	var mix := Pasture3DGraphNodeColorMix.new()
	var nodes: Array[Pasture3DGraphNode] = [_noise(4.0), Pasture3DGraphNodeOutput.new(),
			_const_color(Color.RED), mix, _color_sink()]
	var g := _graph(nodes, [[0, 0, 1, 0], [2, 0, 3, 1], [3, 0, 4, 1], [0, 0, 4, 0]], 1)
	var sup: bool = g.native_supported()
	print("    native_supported() with a Color Mix in the graph = %s (want true)" % str(sup))
	_ok(sup, "a Color Mix dropped the whole graph onto the GDScript evaluator (§10)")

	# CONTROL: native_supported() is capable of answering false on THIS graph, so the check above is
	# reading the graph rather than a constant. Same nodes, same wires, one flag.
	g.force_gdscript_evaluation = true
	var sup2: bool = g.native_supported()
	print("    control: the same graph forced to GDScript reports %s (want false)" % str(sup2))
	_ok(not sup2, "native_supported() answers true unconditionally — [E] measured nothing")


# --- fixtures ------------------------------------------------------------------------------------------
func _resolve_sink(p_nodes: Array, p_wire_color: bool, p_extra: Array = [], p_color_src: int = 1) -> Dictionary:
	# 0 is the mask source, the sink is appended last. Port 0 of a Color Sink is `mask`, port 1 `color`.
	var nodes: Array[Pasture3DGraphNode] = []
	for n in p_nodes:
		nodes.append(n)
	var sink := _color_sink()
	var si := nodes.size()
	nodes.append(sink)
	var conns: Array = [[0, 0, si, 0]]
	for e in p_extra:
		conns.append(e)
	if p_wire_color:
		conns.append([p_color_src, 0, si, 1])
	var g := _graph(nodes, conns, -1)
	return Pasture3DGraphChannelSinks._resolve_ports(g, sink, si, GW, GH, RECT, PackedFloat32Array())


func _mask_source() -> Pasture3DGraphNode:
	return _const(1.0)


func _color_sink() -> Pasture3DGraphNodeColorSink:
	return Pasture3DGraphNodeColorSink.new()


func _const_color(p_c: Color) -> Pasture3DGraphNodeConstColor:
	var n := Pasture3DGraphNodeConstColor.new(); n.value = p_c
	return n


## 0 noise -> blend.a, 1 const -> blend.b, blend is the output. The operands span negatives and a
## crossing of 0.5, so OVERLAY's branch and POW's guard both fire somewhere in the field.
func _blend_graph(p_mode) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [_noise(1.4), _const(0.7), _blend(p_mode)]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1]], 2)


func _const_blend_graph(p_a: float, p_b: float, p_mode) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [_const(p_a), _const(p_b), _blend(p_mode)]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1]], 2)


func _graph(p_nodes: Array[Pasture3DGraphNode], p_conns: Array, p_out: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	g.nodes = p_nodes
	var conns: Array = []
	for c in p_conns:
		conns.append(PackedInt32Array(c))
	g.connections = conns
	g.output_node = p_out
	return g


func _noise(p_a: float) -> Pasture3DGraphNodeNoise:
	var nz := FastNoiseLite.new(); nz.seed = 11; nz.frequency = 0.06
	var n := Pasture3DGraphNodeNoise.new(); n.noise = nz; n.amplitude = p_a
	return n


func _const(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_v
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


## The GDScript node's own answer.
##
## `evaluate()` alone is NOT an oracle: it takes the native route whenever `native_supported()` says it
## can, so a parity check written against it compares the kernel with itself and passes with the GDScript
## node arbitrarily broken. That is what this gate did on its first run — the OVERLAY threshold was moved
## to 0.4 in the node, and [B] still reported a 1e-7 agreement. `force_gdscript_evaluation` is what makes
## the reference an actual reference.
func _oracle(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var prev: bool = p_g.force_gdscript_evaluation
	p_g.force_gdscript_evaluation = true
	var f: PackedFloat32Array = p_g.evaluate(GW, GH, RECT)
	p_g.force_gdscript_evaluation = prev
	return f


func _first(p: PackedFloat32Array) -> float:
	return p[0] if p.size() > 0 else NAN


func _all_finite(p: PackedFloat32Array) -> bool:
	for v in p:
		if not is_finite(v):
			return false
	return true


## A cheap order-sensitive digest, so "these two modes produced the same field" is one comparison.
func _signature(p: PackedFloat32Array) -> String:
	var s := 0.0
	for i in range(p.size()):
		s += p[i] * float(i + 1)
	return String.num(s, 4)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.size() == 0:
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if not is_finite(p_a[i]) and not is_finite(p_b[i]):
			continue
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
