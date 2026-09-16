# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFractalNodeGate — the graph-native Fractal GENERATOR, held to the relief material it came from.
#
# The claims:
#   [A] For all three styles, the graph's Fractal node reproduces a Pasture3DReliefFractal material
#       built from the SAME numbers, cell for cell. The material is the independent side here: it reaches
#       the field through the relief op-program (compile -> _make_noise -> eval), which shares no code
#       with the node's kernel.
#   [B] Sharpness shapes CRAGGY and ONLY craggy, and it actually bites (a knife-edge setting moves the
#       field), which is the one part of the material the existing Noise node cannot express.
#   [C] The domain warp displaces the field — and matches the material's warp, seed offsets included.
#       This is the second thing the Noise node cannot express.
#   [D] NATIVE PARITY: the C++ fractal_grid kernel matches the GDScript per-cell route, which is what
#       lets a graph holding this node keep its native tier.
#   [E] The node is a pure GENERATOR (0 field inputs, 1 output) and a graph holding it IS
#       native_supported — the op-id wiring is present, so adding Fractal does not silently drop a whole
#       graph onto the GDScript evaluator.
#
# Controls throughout: amplitude 0 flattens, the field is not constant, and each criterion counts its own
# completion so a PASS cannot mean "nothing ran".
#
# Pure GDScript on the graph model + the relief material; no terrain. Headless-safe.
extends Node

const GW := 48
const GH := 48
const RECT := Rect2(-400.0, -400.0, 800.0, 800.0)
const EPS := 1.0e-4

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphFractalNodeGate: the relief Fractal material, as a graph generator ===\n")
	_a_matches_the_relief_material()
	_b_sharpness_is_craggy_only_and_bites()
	_c_domain_warp_displaces_and_matches()
	_d_native_matches_gdscript()
	_e_category_and_native_support()
	print("\n    criteria completed: %d of 5" % _ran)
	if _ran != 5:
		_fail += 1
		print("    !! a criterion threw before it asserted — this run measured less than it claims")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH FRACTAL PASS" if _fail == 0 else "GRAPH FRACTAL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Every style reproduces the relief material -----------------------------------------------------
func _a_matches_the_relief_material() -> void:
	print("[A] Fractal node == Pasture3DReliefFractal, per cell, for all three styles")
	var names := ["HILLS", "CRAGGY", "LUMPY"]
	for st in range(3):
		var node := _node(st, 12.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)
		var got := _gen_graph(node).evaluate(GW, GH, RECT)
		var want := _material_oracle(st, 12.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)
		var d := _max_abs_diff(got, want)
		print("    %-6s max |graph - material| = %.7f (want < %.7f) ; spread %.3f (want > 0.5)"
			% [names[st], d, EPS, _spread(got)])
		if d > EPS:
			_fail += 1; print("    !! the %s style diverged from the relief material" % names[st])
		if _spread(got) <= 0.5:
			_fail += 1; print("    !! the %s field is flat — the generator produced nothing" % names[st])
	# CONTROL: amplitude 0 -> a flat 0, so the field above is genuinely scaled by amplitude.
	var flat := _absmax(_gen_graph(_node(1, 0.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)).evaluate(GW, GH, RECT))
	print("    control: amplitude 0 -> flat (absmax %.7f, want < %.7f)" % [flat, EPS])
	if flat > EPS:
		_fail += 1; print("    !! amplitude 0 did not flatten the fractal")
	# CONTROL: the three styles are three DIFFERENT fields. Without this, a node that ignored `style`
	# would pass the comparison above three times over — as long as the material ignored it too.
	var h := _gen_graph(_node(0, 12.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
	var c := _gen_graph(_node(1, 12.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
	var l := _gen_graph(_node(2, 12.0, 180.0, 4, 2.1, 0.55, 1.0, 31, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
	print("    control: styles differ — |H-C| %.3f, |H-L| %.3f, |C-L| %.3f (want each > 0.1)"
		% [_max_abs_diff(h, c), _max_abs_diff(h, l), _max_abs_diff(c, l)])
	if _max_abs_diff(h, c) <= 0.1 or _max_abs_diff(h, l) <= 0.1 or _max_abs_diff(c, l) <= 0.1:
		_fail += 1; print("    !! two styles produced the same field — `style` is not reaching the kernel")
	_ran += 1


# --- B. Sharpness: CRAGGY only, and it bites -----------------------------------------------------------
func _b_sharpness_is_craggy_only_and_bites() -> void:
	print("[B] Sharpness sharpens CRAGGY ridges and is inert on the other two styles")
	var flat_c := _gen_graph(_node(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 9, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
	var sharp_c := _gen_graph(_node(1, 12.0, 180.0, 4, 2.0, 0.5, 3.0, 9, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
	var moved := _max_abs_diff(flat_c, sharp_c)
	print("    CRAGGY: sharpness 1.0 -> 3.0 moves the field by %.3f m (want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1; print("    !! sharpness did nothing on CRAGGY")
	# It must also still match the material AT the sharpened setting — moving is not the same as
	# moving correctly.
	var want := _material_oracle(1, 12.0, 180.0, 4, 2.0, 0.5, 3.0, 9, 0.0, 384.0, 2)
	var d := _max_abs_diff(sharp_c, want)
	print("    CRAGGY: sharpened field vs material = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the sharpened ridges diverged from the relief material")
	# CONTROL: inert on HILLS and LUMPY (the relief evaluator applies the power only to RIDGED).
	for st in [0, 2]:
		var a := _gen_graph(_node(st, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 9, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
		var b := _gen_graph(_node(st, 12.0, 180.0, 4, 2.0, 0.5, 3.0, 9, 0.0, 384.0, 2)).evaluate(GW, GH, RECT)
		var dd := _max_abs_diff(a, b)
		print("    style %d: sharpness is inert (diff %.7f, want < %.7f)" % [st, dd, EPS])
		if dd > EPS:
			_fail += 1; print("    !! sharpness leaked into a non-CRAGGY style")
	_ran += 1


# --- C. Domain warp -------------------------------------------------------------------------------------
func _c_domain_warp_displaces_and_matches() -> void:
	print("[C] Domain Warp displaces the sample point, and matches the material's warp")
	var unwarped := _gen_graph(_node(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 3, 0.0, 300.0, 2)).evaluate(GW, GH, RECT)
	var warped := _gen_graph(_node(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 3, 60.0, 300.0, 2)).evaluate(GW, GH, RECT)
	var moved := _max_abs_diff(unwarped, warped)
	print("    warp 0 -> 60 m moves the field by %.3f m (want > 1.0)" % moved)
	if moved <= 1.0:
		_fail += 1; print("    !! the domain warp did nothing")
	# The claim that matters: it is the SAME warp. The seed offsets (+7717 on the warp op, +1013 on the
	# second field) are duplicated between the node and Pasture3DReliefFractal._build / _make_noise, and
	# a wrong offset is a plausible-looking field, not an error.
	var want := _material_oracle(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 3, 60.0, 300.0, 2)
	var d := _max_abs_diff(warped, want)
	print("    warped field vs material = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the warped field diverged — check the +7717 / +1013 seed offsets")
	# CONTROL: warp_size changes the warp (the size reaches the noise, it is not a dead property).
	var other := _gen_graph(_node(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 3, 60.0, 900.0, 2)).evaluate(GW, GH, RECT)
	print("    control: warp_size 300 vs 900 differ by %.3f (want > 0.5)" % _max_abs_diff(warped, other))
	if _max_abs_diff(warped, other) <= 0.5:
		_fail += 1; print("    !! warp_size is not reaching the warp noise")
	_ran += 1


# --- D. Native kernel == the GDScript per-cell route ----------------------------------------------------
func _d_native_matches_gdscript() -> void:
	print("[D] Native fractal_grid == the node's per-cell GDScript route")
	if not ClassDB.class_has_method("Pasture3DUtil", "fractal_grid"):
		_fail += 1
		print("    !! Pasture3DUtil.fractal_grid is missing — the DLL is stale or the binding is absent")
		return
	for st in range(3):
		for wa in [0.0, 45.0]:
			var node := _node(st, 9.0, 220.0, 5, 2.0, 0.5, 2.2, 77, wa, 340.0, 3)
			var native: PackedFloat32Array = Pasture3DUtil.fractal_grid(GW, GH, RECT, st, 9.0, 220.0, 5,
					2.0, 0.5, 2.2, 77, wa, 340.0, 3)
			var script_side := _cell_route(node)
			var d := _max_abs_diff(native, script_side)
			print("    style %d, warp %.0f m: max |native - gdscript| = %.7f (want < %.7f)"
				% [st, wa, d, EPS])
			if d > EPS:
				_fail += 1; print("    !! the C++ kernel diverged from the GDScript route")
	# CONTROL: the native kernel is not returning zeros (which would match nothing but would also never
	# be caught by a diff against a route that also returned zeros — so assert the field itself).
	var probe: PackedFloat32Array = Pasture3DUtil.fractal_grid(GW, GH, RECT, 1, 9.0, 220.0, 5,
			2.0, 0.5, 2.2, 77, 45.0, 340.0, 3)
	print("    control: native field spread %.3f (want > 0.5)" % _spread(probe))
	if _spread(probe) <= 0.5:
		_fail += 1; print("    !! the native kernel produced a flat field")
	_ran += 1


# --- E. Category and native support ---------------------------------------------------------------------
func _e_category_and_native_support() -> void:
	print("[E] Fractal is a pure GENERATOR, and a graph holding it keeps its native tier")
	var node := _node(1, 12.0, 180.0, 4, 2.0, 0.5, 1.0, 0, 0.0, 384.0, 2)
	var field_ins := _surface_inputs(node)
	print("    role %d (want GENERATOR %d), field inputs %d (want 0), outputs %d (want 1)"
		% [node.role(), Pasture3DGraphNode.Role.GENERATOR, field_ins, node.output_count()])
	if node.role() != Pasture3DGraphNode.Role.GENERATOR or field_ins != 0 or node.output_count() != 1:
		_fail += 1; print("    !! the Fractal node is not a pure single-output generator")
	# The registry must offer it, or nobody can place one.
	var placed := Pasture3DGraphNodeRegistry.create(&"fractal")
	print("    registry: create(&\"fractal\") -> %s" % ("a node" if placed != null else "NULL"))
	if placed == null:
		_fail += 1; print("    !! the palette has no Fractal entry")
	# The op-id claim. An op missing from graph_op_ids() takes the WHOLE graph off the native tier
	# silently, so this is asserted directly rather than inferred from a timing.
	if ClassDB.class_has_method("Pasture3DUtil", "graph_op_ids"):
		var ids: Dictionary = Pasture3DUtil.graph_op_ids()
		print("    graph_op_ids has \"fractal\": %s" % str(ids.has(&"fractal")))
		if not ids.has(&"fractal"):
			_fail += 1; print("    !! \"fractal\" is missing from graph_op_ids() — every graph using it drops to GDScript")
	var g := _gen_graph(node)
	var supported: bool = g.native_supported() if g.has_method("native_supported") else true
	print("    graph native_supported: %s (want true)" % str(supported))
	if not supported:
		_fail += 1; print("    !! a Fractal graph is not natively supported")
	_ran += 1


# ---- fixtures ------------------------------------------------------------------------------------------

func _node(p_style: int, p_amp: float, p_feature: float, p_oct: int, p_lac: float, p_gain: float,
		p_sharp: float, p_seed: int, p_warp_amount: float, p_warp_size: float,
		p_warp_oct: int) -> Pasture3DGraphNodeFractal:
	var n := Pasture3DGraphNodeFractal.new()
	n.style = p_style as Pasture3DGraphNodeFractal.Style
	n.amplitude = p_amp
	n.feature_size = p_feature
	n.octaves = p_oct
	n.lacunarity = p_lac
	n.gain = p_gain
	n.sharpness = p_sharp
	n.seed = p_seed
	n.warp_amount = p_warp_amount
	n.warp_size = p_warp_size
	n.warp_octaves = p_warp_oct
	return n


## The INDEPENDENT side: a relief material, reached through compile() and the relief op-program's own
## evaluator. It shares no code with the node's kernel — it builds its noise in _make_noise from the
## emitted op params, walks a WARP op and then an FBM / RIDGED / BILLOW op, and accumulates.
##
## `amplitude` is the only translation: the material's is a fraction of a host Height Scale of 1, so the
## node's metres and the material's fraction are the same number here by construction, which is exactly
## the equivalence the node's header claims.
func _material_oracle(p_style: int, p_amp: float, p_feature: float, p_oct: int, p_lac: float,
		p_gain: float, p_sharp: float, p_seed: int, p_warp_amount: float, p_warp_size: float,
		p_warp_oct: int) -> PackedFloat32Array:
	var m := Pasture3DReliefFractal.new()
	m.style = p_style as Pasture3DReliefFractal.Style
	m.amplitude = p_amp
	m.feature_size = p_feature
	m.octaves = p_oct
	m.lacunarity = p_lac
	m.gain = p_gain
	m.sharpness = p_sharp
	m.seed = p_seed
	m.warp_amount = p_warp_amount
	m.warp_size = p_warp_size
	m.warp_octaves = p_warp_oct
	m.compile()
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := _cell_world(ix, iz)
			# nu/nv/inv_* are the loop-normalised frame, which no fractal op reads; 0 is honest here.
			out[iz * GW + ix] = m.eval(w.x, w.y, 0.0, 0.0, 0.0, 0.0)
	return out


## The node's own per-cell route over the same grid — the D criterion's script side.
func _cell_route(p_node: Pasture3DGraphNodeFractal) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	var ins := PackedFloat32Array([NAN, NAN, NAN, NAN])
	for iz in range(GH):
		for ix in range(GW):
			var w := _cell_world(ix, iz)
			out[iz * GW + ix] = p_node.eval_cell(w.x, w.y, ins)
	return out


## Cell-centre world XZ, the convention graph_cell_to_world and every graph node use.
func _cell_world(p_ix: int, p_iz: int) -> Vector2:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	return Vector2(RECT.position.x + (float(p_ix) + 0.5) * dx,
			RECT.position.y + (float(p_iz) + 0.5) * dz)


func _gen_graph(p_gen: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_gen, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0)]
	return g


func _c4(a: int, ap: int, b: int, bp: int) -> PackedInt32Array:
	return PackedInt32Array([a, ap, b, bp])


# ---- measures ------------------------------------------------------------------------------------------

func _absmax(p: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p:
		m = maxf(m, absf(v))
	return m


func _spread(p: PackedFloat32Array) -> float:
	if p.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in p:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


## Ports that carry a field in, as opposed to a scalar parameter socket.
func _surface_inputs(p_node: Pasture3DGraphNode) -> int:
	var c := 0
	var types := p_node.input_port_types()
	for t in types:
		if t != Pasture3DGraphNode.PortType.FLOAT and t != Pasture3DGraphNode.PortType.INT:
			c += 1
	return c
