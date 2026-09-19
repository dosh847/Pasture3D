# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphColorBlendGate — native colour support for the Color Blend node.
#
#   A  Pasture3DUtil.color_blend_cells vs the [Dev/GD] Color Blend's GDScript loop: 6 modes x uniform/array
#      A and B x strengths, over a mask with NaN, out-of-range and a short tail, RGBA within 1e-6.
#      Control: the kernel's MIX against the oracle's ADD differs.
#   B  COLOR wires stay out of the scalar ancestry: the sink's eval order holds neither Const Color nor the
#      Blend, and the native scan does not blame a colour node. Control: the Blend as a root is blocked.
#   C  One pass: resolving the sink taps the Blend's mask in the sink's own evaluation, so `_tap_field` never
#      compiles its own (fallback_taps unchanged), and the sink receives the kernel's per-cell colours.
#      Control: a `_tap_field` with no pass behind it does count.
#   D  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphColorBlendGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(0.0, 0.0, 64.0, 64.0)
const EPS := 1.0e-6
const CRITERIA := ["A", "B", "C"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== GraphColorBlendGate: native Color Blend ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "color_blend_cells"):
		print("!! Pasture3DUtil.color_blend_cells is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	for entry in [["A", _a_parity], ["B", _b_ancestry], ["C", _c_one_pass]]:
		entry[1].call()
		if not _seen.has(entry[0]):
			print("!! [%s] returned without reporting" % entry[0])
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
	_check("D", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== COLOR BLEND %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
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


# --- fixtures ----------------------------------------------------------------------------------------
func _colours(p_n: int, p_seed: int) -> PackedColorArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var out := PackedColorArray()
	out.resize(p_n)
	for i in p_n:
		out[i] = Color(rng.randf(), rng.randf(), rng.randf(), rng.randf())
	return out


func _mask(p_n: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var m := PackedFloat32Array()
	m.resize(p_n - 37) # a short tail: cells past the end read 0
	for i in m.size():
		m[i] = rng.randf_range(-0.3, 1.3)
	m[5] = NAN
	m[9] = INF
	return m


func _worst(p_a: PackedColorArray, p_b: PackedColorArray) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		var d := p_a[i] - p_b[i]
		w = maxf(w, maxf(maxf(absf(d.r), absf(d.g)), maxf(absf(d.b), absf(d.a))))
	return w


# --- A. kernel parity --------------------------------------------------------------------------------
func _a_parity() -> void:
	print("[A] color_blend_cells matches the GDScript loop")
	var n := 4096
	var mask := _mask(n)
	var arr_a := _colours(n, 1)
	var arr_b := _colours(n - 100, 2) # short: the fallback past its end
	var worst := 0.0
	var cases := 0
	for mode in 6:
		for strength in [1.0, 0.37]:
			for pair in [[Color(0.8, 0.3, 0.1, 0.9), Color(0.2, 0.6, 0.9, 0.4)], [arr_a, arr_b], [arr_a, Color(0.5, 0.5, 0.5, 1.0)]]:
				var node := Pasture3DGraphNodeDevColorBlend.new()
				node.mode = mode
				node.strength = strength
				node.color_b = Color(0.1, 0.9, 0.3, 0.7)
				var up := {"a": pair[0], "b": pair[1]}
				var gd := node.graph_color_cells(up, mask, n)
				var cc: PackedColorArray = Pasture3DUtil.color_blend_cells(pair[0], pair[1], mask, n, mode, strength,
						node.color_a, node.color_b)
				worst = maxf(worst, _worst(gd, cc))
				cases += 1
	_check("A", worst <= EPS, "%d cases, worst RGBA error %s (want <= %s)" % [cases, str(worst), str(EPS)])
	var ctl_node := Pasture3DGraphNodeDevColorBlend.new()
	ctl_node.mode = Pasture3DGraphNodeColorBlend.Mode.ADD
	var gd_add := ctl_node.graph_color_cells({"a": arr_a, "b": arr_b}, mask, n)
	var cc_mix: PackedColorArray = Pasture3DUtil.color_blend_cells(arr_a, arr_b, mask, n, 0, 1.0, ctl_node.color_a, ctl_node.color_b)
	var d := _worst(gd_add, cc_mix)
	_control(d > 0.05, "kernel MIX vs oracle ADD differs by %s (want > 0.05)" % str(d))


# --- shared graph ------------------------------------------------------------------------------------
## Input -> Output; Const red -> Blend.a, Const blue -> Blend.b, Input -> Blend.mask; Blend -> Color Sink.color.
func _blend_graph() -> Pasture3DTerrainGraph:
	var red := Pasture3DGraphNodeConstColor.new()
	red.value = Color(1.0, 0.0, 0.0, 1.0)
	var blue := Pasture3DGraphNodeConstColor.new()
	blue.value = Color(0.0, 0.0, 1.0, 1.0)
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new(), red, blue,
			Pasture3DGraphNodeColorBlend.new(), Pasture3DGraphNodeColorSink.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [2, 0, 4, 0], [3, 0, 4, 1], [0, 0, 4, 2], [4, 0, 5, 1]]
	g.set_output(1)
	return g


## Height ix / 63: the Blend's mask ramps from 0 to 1 across the grid.
func _ramp_grid() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			z[iz * GW + ix] = float(ix) / float(GW - 1)
	return z


# --- B. colour wires out of the ancestry -------------------------------------------------------------
func _b_ancestry() -> void:
	print("[B] COLOR wires stay out of the scalar ancestry")
	var g := _blend_graph()
	var order: Array = g._eval_order(5)
	var rep: Dictionary = g.native_block_report(5)
	var blamed := int(rep.get("node", -1))
	var ok := not order.has(2) and not order.has(3) and not order.has(4) and not (blamed in [2, 3, 4])
	_check("B", ok, "sink eval order %s, native scan %s" % [str(order), str(rep) if not rep.is_empty() else "clean"])
	var ctl: Dictionary = g.native_block_report(4)
	_control(int(ctl.get("node", -1)) == 4, "the Blend as a root is blocked at node %s (want 4)" % str(ctl.get("node", -1)))


# --- C. one pass -------------------------------------------------------------------------------------
func _c_one_pass() -> void:
	print("[C] the Blend's mask rides the sink's single evaluation")
	var g := _blend_graph()
	var input := _ramp_grid()
	var before: int = Pasture3DGraphChannelSinks.fallback_taps
	var res: Dictionary = Pasture3DGraphChannelSinks._resolve_ports(g, g.nodes[5], 5, GW, GH, RECT, input)
	var extra: int = Pasture3DGraphChannelSinks.fallback_taps - before
	var c = res.get("values", {}).get("color", null)
	var want: PackedColorArray = Pasture3DUtil.color_blend_cells(Color(1, 0, 0, 1), Color(0, 0, 1, 1), input, GW * GH,
			0, 1.0, Color.WHITE, Color.BLACK)
	var err := _worst(c, want) if c is PackedColorArray else INF
	_check("C", extra == 0 and err <= EPS, "%d fallback compiles (want 0), per-cell error %s (%s)"
			% [extra, str(err), str(res.get("error", "no error"))])
	var ctx := {"gw": GW, "gh": GH, "rect": RECT, "input": input}
	var b2: int = Pasture3DGraphChannelSinks.fallback_taps
	var f := Pasture3DGraphChannelSinks._tap_field(g, 4, 2, ctx)
	var counted: int = Pasture3DGraphChannelSinks.fallback_taps - b2
	_control(counted == 1 and f.size() == GW * GH, "a _tap_field with no pass counts %d (want 1), %d cells" % [counted, f.size()])
