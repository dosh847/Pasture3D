# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphRampPresetGate — Phase 5 of PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md (§9): palette visibility and
# the preset gradients.
#
#   A  Gradient, Value Ramp and Color Ramp are in the palette with the dev flag OFF, and each constructs.
#      Control: their [Dev/GD] twins are absent with the flag off and present with it on.
#   B  Every preset under addons/pasture_3d/graph/presets/ loads as a Gradient with at least two stops, and
#      through BOTH ramps matches Gradient.sample: the Value Ramp natively (graph_eval_grid), the Color Ramp
#      through color_ramp_cells. Control: a default Gradient.new() gives a different ramp from every preset,
#      so a preset that silently failed to load (and fell back to a default) cannot pass.
#   C  Every criterion completed.
#
# Headless-safe.  Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphRampPresetGate.tscn
extends Node

const PRESET_DIR := "res://addons/pasture_3d/graph/presets/"
const PRESETS := ["earth_tones.tres", "snowline.tres", "slope_bands.tres"]
const PRODUCTION := [&"gradient", &"value_ramp", &"color_ramp"]
const DEV := [&"dev_gradient", &"dev_value_ramp", &"dev_color_ramp"]
const N := 1025
const EPS := 1.0e-5
const CRITERIA := ["A", "B"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== GraphRampPresetGate: palette visibility and preset gradients (spec §9, Phase 5) ===")
	_a_palette()
	_b_presets()
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
		else:
			print("!! criterion %s never reported" % name)
	_check("C", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== RAMP PRESETS %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
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


func _ops(p_include_dev: bool) -> Array:
	var out := []
	for e in Pasture3DGraphNodeRegistry.entries(p_include_dev):
		out.append(e["op"])
	return out


# --- A. palette ----------------------------------------------------------------------------------------
func _a_palette() -> void:
	print("[A] the three nodes are in the palette with the dev flag off")
	var off := _ops(false)
	var on := _ops(true)
	var missing := []
	var unbuilt := []
	for op in PRODUCTION:
		if not off.has(op):
			missing.append(op)
		var n := Pasture3DGraphNodeRegistry.create(op)
		if n == null or n.op() != op:
			unbuilt.append(op)
	_check("A", missing.is_empty() and unbuilt.is_empty(),
			"missing with the flag off: %s; failed to construct: %s" % [str(missing), str(unbuilt)])
	var leaked := []
	var absent := []
	for op in DEV:
		if off.has(op):
			leaked.append(op)
		if not on.has(op):
			absent.append(op)
	_control(leaked.is_empty() and absent.is_empty(),
			"[Dev/GD] twins visible with the flag off: %s; missing with it on: %s" % [str(leaked), str(absent)])


# --- B. presets ----------------------------------------------------------------------------------------
func _inputs() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N)
	for i in N:
		h[i] = lerpf(-0.1, 1.1, float(i) / float(N - 1))
	return h


func _value_ramp_native(p_g: Gradient, p_h: PackedFloat32Array) -> PackedFloat32Array:
	var v := Pasture3DGraphNodeValueRamp.new()
	v.gradient = p_g
	v.channel = Pasture3DGraphNodeValueRamp.Channel.LUMINANCE
	v.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.MASK
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), v, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, 1, Rect2(0.0, 0.0, N, 1.0), p_h)


func _value_ramp_oracle(p_g: Gradient, p_h: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(N)
	for i in N:
		var c := p_g.sample(clampf(p_h[i], 0.0, 1.0))
		out[i] = clampf(Pasture3DGraphNodeValueRamp.reduce(c, Pasture3DGraphNodeValueRamp.Channel.LUMINANCE), 0.0, 1.0)
	return out


func _color_ramp_cells(p_g: Gradient, p_h: PackedFloat32Array, p_dev: bool) -> PackedColorArray:
	var c: Pasture3DGraphNodeColorRamp = Pasture3DGraphNodeDevColorRamp.new() if p_dev else Pasture3DGraphNodeColorRamp.new()
	c.gradient = p_g
	return c.graph_color_cells({}, p_h, N)


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _worst_rgba(p_a: PackedColorArray, p_b: PackedColorArray) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, maxf(maxf(absf(p_a[i].r - p_b[i].r), absf(p_a[i].g - p_b[i].g)),
				maxf(absf(p_a[i].b - p_b[i].b), absf(p_a[i].a - p_b[i].a))))
	return w


func _b_presets() -> void:
	print("[B] every preset loads and evaluates exactly in both ramps")
	var h := _inputs()
	var default_value := _value_ramp_native(Gradient.new(), h)
	var ok := true
	var ctl_min := INF
	var lines := []
	for file in PRESETS:
		var res = load(PRESET_DIR + file)
		if not (res is Gradient) or (res as Gradient).get_point_count() < 2:
			ok = false
			lines.append("%s: did not load as a Gradient with >= 2 stops (%s)" % [file, str(res)])
			continue
		var g: Gradient = res
		var vw := _worst(_value_ramp_native(g, h), _value_ramp_oracle(g, h))
		var cw := _worst_rgba(_color_ramp_cells(g, h, false), _color_ramp_cells(g, h, true))
		ok = ok and vw <= EPS and cw <= EPS
		ctl_min = minf(ctl_min, _worst(_value_ramp_native(g, h), default_value))
		lines.append("%s (%d stops, mode %d): value ramp %s, color ramp %s" % [file, g.get_point_count(),
				g.interpolation_mode, str(vw), str(cw)])
	_check("B", ok, " | ".join(lines))
	_control(ctl_min > 1.0e-2, "the default Gradient differs from every preset by at least %s (want > 1e-2)" % str(ctl_min))
