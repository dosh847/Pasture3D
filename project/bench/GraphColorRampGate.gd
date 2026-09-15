# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphColorRampGate — the Color Ramp node (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §7.5).
#
#   A  Pasture3DUtil.color_ramp_cells vs Gradient.sample ([Dev/GD] graph_color_cells), 3 modes x 3 colour
#      spaces x 3 repeats over 4097 inputs, RGBA within 1e-5 (CUBIC or OKLAB 1e-4). Control: a 256-entry LUT
#      misses a CONSTANT band edge.
#   B  The equal-offset tie agrees with VR-C on the same fixture: the later sorted stop, and the Value Ramp's
#      RED channel reads the same value.
#   C  Paints the colour map: Input -> Color Ramp -> Color Sink writes the expected sRGB per cell, read back
#      from terrain colour data. Control: a Const Color into the same sink fails the per-cell comparison.
#   D  Color Ramp and Value Ramp (channel RED) agree per cell on the same gradient and field.
#   E  The native route is kept with a Color Ramp branch hanging off the height branch. Control: a genuinely
#      unlowerable node on the height branch reports false.
#   F  color_field_port is the port tapped: the resolver hands the sink a per-cell array. Control: a Color Ramp
#      answering -1 falls back to one uniform colour and fails C's comparison. Color Blend's own coverage is
#      GraphOperatorGate, re-run separately.
#   G  Wiring: COLOR -> HEIGHT is refused by the editor's connection table. Control: HEIGHT -> MASK, a pair the
#      table does register, reads as accepted (so the query sees the table). GraphEdit allows same-type wires
#      without registering them, so COLOR -> COLOR cannot serve as the control.
#   H  An in-place gradient.set_color repaints on the next bake.
#   I  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphColorRampGate.tscn
extends Node

const N := 4097
const X_LO := -30.0
const X_HI := 90.0
const IN_MIN := -20.0
const IN_MAX := 80.0
const EPS_A := 1.0e-5
const EPS_A_LOOSE := 1.0e-4
const GW := 64
const GH := 64
const RECT := Rect2(0.0, 0.0, 64.0, 64.0)
## The colour map is stored at 8 bits a channel.
const EPS_PAINT := 2.0 / 255.0
const CRITERIA := ["A", "B", "C", "D", "E", "F", "G", "H"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== GraphColorRampGate: Color Ramp node (spec §7.5) ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "color_ramp_cells"):
		print("!! Pasture3DUtil.color_ramp_cells is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	for entry in [["A", _a_cells], ["B", _b_tie], ["C", _c_paint], ["D", _d_value_ramp], ["E", _e_native],
			["F", _f_field_port], ["G", _g_wiring], ["H", _h_invalidation]]:
		entry[1].call()
		if not _seen.has(entry[0]):
			print("!! [%s] returned without reporting" % entry[0])
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
	_check("I", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== COLOR RAMP %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
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
## The Value Ramp gate's five stops, out of order, alpha varying.
func _gradient(p_mode := 0, p_space := 0) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.8, 0.1, 0.45, 0.62, 0.95])
	g.colors = PackedColorArray([Color(0.9, 0.2, 0.1, 1.0), Color(0.05, 0.4, 0.9, 0.3), Color(1.0, 1.0, 0.2, 0.8),
			Color(0.3, 0.0, 0.6, 0.5), Color(0.1, 0.9, 0.4, 0.0)])
	g.interpolation_mode = p_mode
	g.interpolation_color_space = p_space
	return g


func _opaque() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	g.colors = PackedColorArray([Color(0.1, 0.3, 0.8), Color(0.9, 0.8, 0.2), Color(0.6, 0.1, 0.1)])
	return g


func _ramp(p_gradient: Gradient, p_min := IN_MIN, p_max := IN_MAX, p_repeat := 0, p_dev := false) -> Pasture3DGraphNodeColorRamp:
	var n: Pasture3DGraphNodeColorRamp = Pasture3DGraphNodeDevColorRamp.new() if p_dev else Pasture3DGraphNodeColorRamp.new()
	n.gradient = p_gradient
	n.input_min = p_min
	n.input_max = p_max
	n.repeat = p_repeat
	return n


func _inputs() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N)
	for i in N:
		h[i] = lerpf(X_LO, X_HI, float(i) / float(N - 1))
	h[7] = NAN # a no-data cell takes the colour at offset 0 on both sides
	return h


func _rgba_worst(p_a: PackedColorArray, p_b: PackedColorArray) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, maxf(absf(p_a[i].r - p_b[i].r), maxf(absf(p_a[i].g - p_b[i].g),
				maxf(absf(p_a[i].b - p_b[i].b), absf(p_a[i].a - p_b[i].a)))))
	return w


# --- A. cells vs Gradient.sample ---------------------------------------------------------------------
func _a_cells() -> void:
	print("[A] color_ramp_cells == Gradient.sample, 27 cases x %d inputs, RGBA" % N)
	var h := _inputs()
	var passed := 0
	var total := 0
	var worst := 0.0
	var worst_loose := 0.0
	for mode in 3:
		for space in 3:
			for rp in 3:
				total += 1
				var g := _gradient(mode, space)
				var nat := _ramp(g, IN_MIN, IN_MAX, rp).graph_color_cells({}, h, N)
				var ora := _ramp(g, IN_MIN, IN_MAX, rp, true).graph_color_cells({}, h, N)
				var w := _rgba_worst(nat, ora)
				var loose := mode == Gradient.GRADIENT_INTERPOLATE_CUBIC or space == Gradient.GRADIENT_COLOR_SPACE_OKLAB
				if loose:
					worst_loose = maxf(worst_loose, w)
				else:
					worst = maxf(worst, w)
				if w <= (EPS_A_LOOSE if loose else EPS_A):
					passed += 1
				else:
					print("    !! mode %d space %d repeat %d: worst RGBA %s" % [mode, space, rp, str(w)])
	_check("A", passed == total, "%d of %d cases; worst %s (tight), %s (CUBIC/OKLAB)" % [passed, total, str(worst), str(worst_loose)])
	var g := _gradient(Gradient.GRADIENT_INTERPOLATE_CONSTANT)
	var ctl := 0.0
	for i in N:
		if not is_finite(h[i]):
			continue
		var t := clampf((h[i] - IN_MIN) / (IN_MAX - IN_MIN), 0.0, 1.0)
		ctl = maxf(ctl, absf(g.sample(t).r - g.sample(roundf(t * 255.0) / 255.0).r))
	_control(ctl > 1.0e-2, "256-entry LUT vs exact at CONSTANT band edges: worst red %s (want > 1e-2)" % str(ctl))


# --- B. tie ------------------------------------------------------------------------------------------
func _b_tie() -> void:
	print("[B] the equal-offset tie agrees with VR-C")
	var red := Color(1.0, 0.0, 0.0)
	var blue := Color(0.0, 0.0, 1.0)
	var h := PackedFloat32Array([0.6, 0.75])
	var ok := true
	var lines := []
	for order in [[red, blue], [blue, red]]:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.5, 0.5, 1.0])
		g.colors = PackedColorArray([Color.BLACK, order[0], order[1], Color.WHITE])
		g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
		var later := Pasture3DGraphNodeValueRamp.stops_of(g)[2 * 5 + 1]
		var cr := _ramp(g, 0.0, 1.0).graph_color_cells({}, h, 2)
		var vr := _value_ramp(g, 0.0, 1.0)
		var vr_out := _native(_graph(vr), h)
		ok = ok and cr.size() == 2 and cr[0].r == later and cr[1].r == later and vr_out.size() == 2 \
				and vr_out[0] == later and vr_out[1] == later
		lines.append("later red %s: color ramp %s, value ramp %s" % [str(later), str([cr[0].r, cr[1].r] if cr.size() == 2 else cr), str(vr_out)])
	_check("B", ok, " | ".join(lines))


func _value_ramp(p_g: Gradient, p_min: float, p_max: float) -> Pasture3DGraphNodeValueRamp:
	var v := Pasture3DGraphNodeValueRamp.new()
	v.gradient = p_g
	v.input_min = p_min
	v.input_max = p_max
	v.channel = Pasture3DGraphNodeValueRamp.Channel.RED
	v.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.MASK
	return v


func _graph(p_n: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_n, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return g


func _native(p_g: Pasture3DTerrainGraph, p_in: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), p_in.size(), 1, Rect2(0.0, 0.0, p_in.size(), 1.0), p_in)


# --- C / F / H. painting ------------------------------------------------------------------------------
func _terrain(p_name: String) -> Pasture3D:
	var t := Pasture3D.new()
	t.name = p_name
	t.vertex_spacing = 1.0
	add_child(t)
	if t.data == null:
		return null
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in GH:
		for ix in GW:
			t.data.set_height(Vector3(ix + 0.5, 0.0, iz + 0.5), float(ix))
	return t


## Height = column index, so t = ix / 63 across the footprint.
func _column_grid() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			z[iz * GW + ix] = float(ix)
	return z


## Input -> Output, and Input -> [p_color_src] -> Color Sink.color.
func _paint_graph(p_color_src: Pasture3DGraphNode, p_tapped := true) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new(), p_color_src,
			Pasture3DGraphNodeColorSink.new()]
	g.nodes = nodes
	var conns := [[0, 0, 1, 0], [2, 0, 3, 1]]
	if p_tapped:
		conns.append([0, 0, 2, 0])
	g.connections = conns
	g.set_output(1)
	return g


## Worst RGB error of the painted colour map against Gradient.sample(ix / 63), or INF if nothing was written.
func _paint_error(p_t: Pasture3D, p_g: Pasture3DTerrainGraph, p_expect: Gradient) -> float:
	var report: Dictionary = Pasture3DGraphChannelSinks.run(p_g, p_t, "pasture3d_brush:ColorRampGate", GW, GH, RECT, _column_grid())
	if int(report["written"]) <= 0:
		print("    !! nothing written: %s" % str(report["skipped"]))
		return INF
	var w := 0.0
	for iz in range(0, GH, 3):
		for ix in GW:
			var got: Color = p_t.data.get_color(Vector3(ix + 0.5, 0.0, iz + 0.5))
			var want := p_expect.sample(float(ix) / 63.0)
			w = maxf(w, maxf(absf(got.r - want.r), maxf(absf(got.g - want.g), absf(got.b - want.b))))
	return w


func _c_paint() -> void:
	print("[C] Input -> Color Ramp -> Color Sink paints the gradient per cell, read from terrain colour data")
	var t := _terrain("ColorRampGateC")
	if t == null:
		_check("C", false, "the fixture terrain has no data")
		return
	var g := _opaque()
	var err := _paint_error(t, _paint_graph(_ramp(g, 0.0, 63.0)), g)
	_check("C", err <= EPS_PAINT, "worst painted RGB error %s over every column (want <= %s)" % [str(err), str(EPS_PAINT)])
	var k := Pasture3DGraphNodeConstColor.new()
	k.value = g.sample(0.5)
	var ctl := _paint_error(t, _paint_graph(k, false), g)
	_control(ctl > 0.1, "a Const Color into the same sink: worst error %s (want > 0.1)" % str(ctl))
	t.queue_free()


# --- D. value ramp agreement -------------------------------------------------------------------------
func _d_value_ramp() -> void:
	print("[D] Color Ramp red == Value Ramp channel RED, per cell")
	var h := _inputs()
	h[7] = 0.0 # the Value Ramp passes NaN through; this criterion compares mapped values only
	var worst := 0.0
	for mode in 3:
		var g := _gradient(mode, Gradient.GRADIENT_COLOR_SPACE_SRGB)
		var cr := _ramp(g, IN_MIN, IN_MAX).graph_color_cells({}, h, N)
		var vr := _native(_graph(_value_ramp(g, IN_MIN, IN_MAX)), h)
		if cr.size() != N or vr.size() != N:
			worst = INF
			break
		for i in N:
			worst = maxf(worst, absf(clampf(cr[i].r, 0.0, 1.0) - vr[i]))
	_check("D", worst <= 1.0e-6, "worst |color ramp red - value ramp| %s over 3 modes" % str(worst))


# --- E. native route ---------------------------------------------------------------------------------
func _e_native() -> void:
	print("[E] a Color Ramp branch keeps native_supported()")
	var noise := Pasture3DGraphNodeNoise.new()
	noise.noise = FastNoiseLite.new()
	var nodes: Array[Pasture3DGraphNode] = [noise, Pasture3DGraphNodeOutput.new(), _ramp(_opaque()), Pasture3DGraphNodeColorSink.new()]
	var g := Pasture3DTerrainGraph.new()
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [0, 0, 2, 0], [2, 0, 3, 1]]
	g.set_output(1)
	var sup: bool = g.native_supported()
	_check("E", sup, "native_supported() with Noise -> Output and Noise -> Color Ramp -> Color Sink = %s" % str(sup))
	var dev := Pasture3DGraphNodeDevValueRamp.new()
	var nodes2: Array[Pasture3DGraphNode] = [noise, Pasture3DGraphNodeOutput.new(), _ramp(_opaque()), Pasture3DGraphNodeColorSink.new(), dev]
	var g2 := Pasture3DTerrainGraph.new()
	g2.nodes = nodes2
	g2.connections = [[0, 0, 4, 0], [4, 0, 1, 0], [0, 0, 2, 0], [2, 0, 3, 1]]
	g2.set_output(1)
	var sup2: bool = g2.native_supported()
	_control(not sup2, "a [Dev/GD] Value Ramp on the height branch reports %s (want false)" % str(sup2))


# --- F. field port -----------------------------------------------------------------------------------
func _f_field_port() -> void:
	print("[F] color_field_port() is the port tapped")
	var g := _paint_graph(_ramp(_opaque(), 0.0, 63.0))
	var res: Dictionary = Pasture3DGraphChannelSinks._resolve_ports(g, g.nodes[3], 3, GW, GH, RECT, _column_grid())
	var c = res.get("values", {}).get("color", null)
	_check("F", c is PackedColorArray and c.size() == GW * GH, "the sink received %s"
			% ("%d per-cell colours" % c.size() if c is PackedColorArray else str(c)))
	var t := _terrain("ColorRampGateF")
	if t == null:
		_control(false, "the fixture terrain has no data")
		return
	var s := GDScript.new()
	s.source_code = "extends Pasture3DGraphNodeColorRamp\nfunc color_field_port() -> int:\n\treturn -1\n"
	s.reload()
	var blind: Pasture3DGraphNodeColorRamp = s.new()
	blind.gradient = _opaque()
	blind.input_min = 0.0
	blind.input_max = 63.0
	var ctl := _paint_error(t, _paint_graph(blind), _opaque())
	_control(ctl > 0.1, "a Color Ramp answering -1 paints uniformly: worst error %s (want > 0.1)" % str(ctl))
	t.queue_free()


# --- G. wiring ---------------------------------------------------------------------------------------
func _g_wiring() -> void:
	print("[G] COLOR -> HEIGHT is refused by the editor's connection table")
	var script = load("res://addons/pasture_3d/src/graph_editor.gd")
	if script == null:
		_check("G", false, "graph_editor.gd did not load")
		return
	var ge := GraphEdit.new()
	script.register_connection_types(ge)
	var refused := not ge.is_valid_connection_type(Pasture3DGraphNode.PortType.COLOR, Pasture3DGraphNode.PortType.HEIGHT)
	var ctl := ge.is_valid_connection_type(Pasture3DGraphNode.PortType.HEIGHT, Pasture3DGraphNode.PortType.MASK)
	ge.free()
	_check("G", refused, "COLOR -> HEIGHT valid = %s (want false)" % str(not refused))
	_control(ctl, "HEIGHT -> MASK valid = %s (want true)" % str(ctl))


# --- H. in-place edit --------------------------------------------------------------------------------
func _h_invalidation() -> void:
	print("[H] an in-place gradient.set_color repaints on the next bake")
	var t := _terrain("ColorRampGateH")
	if t == null:
		_check("H", false, "the fixture terrain has no data")
		return
	var g := _opaque()
	var graph := _paint_graph(_ramp(g, 0.0, 63.0))
	var first := _paint_error(t, graph, g)
	var before: Color = t.data.get_color(Vector3(0.5, 0.0, 0.5))
	g.set_color(0, Color(0.95, 0.05, 0.6))
	var second := _paint_error(t, graph, g)
	var after: Color = t.data.get_color(Vector3(0.5, 0.0, 0.5))
	t.queue_free()
	_check("H", first <= EPS_PAINT and second <= EPS_PAINT and not before.is_equal_approx(after),
			"column 0 painted %s then %s; both bakes match their gradient (%s, %s)" % [str(before), str(after), str(first), str(second)])
