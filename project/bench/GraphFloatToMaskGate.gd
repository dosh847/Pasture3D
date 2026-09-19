# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFloatToMaskGate — the Float to Mask node.
#
#   A  Pasture3DUtil.float_to_mask_grid vs the [Dev/GD] GDScript body: both range modes x every post option,
#      over a field with NaN and INF, within 1e-6. Control: FIXED against AUTO on the same field differs.
#   B  The window: FIXED maps in_min/mid/in_max to 0/0.5/1; AUTO clips outliers so the median of a ramp
#      with a 1e6 spike reads ~0.5. Control: AUTO at 0/100 percent lets the spike flatten it below 0.01.
#   C  Native route: Input -> Float to Mask lowers (op 66), and the program's tap equals the kernel.
#      Control: the [Dev/GD] node does not lower.
#   D  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphFloatToMaskGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(0.0, 0.0, 64.0, 64.0)
const EPS := 1.0e-6
const CRITERIA := ["A", "B", "C"]

var _fail := 0
var _seen := {}


func _ready() -> void:
	print("=== GraphFloatToMaskGate: Float to Mask ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "float_to_mask_grid"):
		print("!! Pasture3DUtil.float_to_mask_grid is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	for entry in [["A", _a_parity], ["B", _b_window], ["C", _c_native]]:
		entry[1].call()
		if not _seen.has(entry[0]):
			print("!! [%s] returned without reporting" % entry[0])
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
	_check("D", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== FLOAT TO MASK %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
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


## Metres of "erosion": a noisy bowl, with holes.
func _field() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var u := (ix - 31.5) / 32.0
			var v := (iz - 31.5) / 32.0
			a[iz * GW + ix] = 9.0 * (u * u + v * v) + rng.randf_range(-0.5, 0.5)
	a[100] = NAN
	a[200] = INF
	return a


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _configure(p_node: Pasture3DGraphNodeFloatToMask, p_mode: int, p_combo: int) -> void:
	p_node.range_mode = p_mode
	p_node.in_min = 0.5
	p_node.in_max = 7.0
	p_node.low_percentile = 5.0
	p_node.high_percentile = 90.0
	p_node.invert = (p_combo & 1) != 0
	p_node.gamma = 2.2 if (p_combo & 2) != 0 else 1.0
	p_node.smooth_edges = (p_combo & 4) != 0
	p_node.blur_passes = 3 if (p_combo & 8) != 0 else 0


# --- A. kernel parity --------------------------------------------------------------------------------
func _a_parity() -> void:
	print("[A] float_to_mask_grid matches the GDScript body")
	var f := _field()
	var worst := 0.0
	var cases := 0
	for mode in 2:
		for combo in 16:
			var dev := Pasture3DGraphNodeDevFloatToMask.new()
			_configure(dev, mode, combo)
			var gd := dev.eval_grid([f], GW, GH, null, RECT)
			var cc: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(f, GW, GH, dev.mask_params())
			worst = maxf(worst, _worst(gd, cc))
			cases += 1
	_check("A", worst <= EPS, "%d cases, worst error %s (want <= %s)" % [cases, str(worst), str(EPS)])
	var n := Pasture3DGraphNodeFloatToMask.new()
	_configure(n, 0, 0)
	var fixed: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(f, GW, GH, n.mask_params())
	n.range_mode = Pasture3DGraphNodeFloatToMask.RangeMode.AUTO
	var auto: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(f, GW, GH, n.mask_params())
	var d := _worst(fixed, auto)
	_control(d > 0.05, "FIXED vs AUTO differ by %s (want > 0.05)" % str(d))


# --- B. window ---------------------------------------------------------------------------------------
func _b_window() -> void:
	print("[B] the window: fixed metres map exactly, auto percentiles clip outliers")
	var n := Pasture3DGraphNodeFloatToMask.new()
	n.in_min = 2.0
	n.in_max = 6.0
	var probe := PackedFloat32Array([2.0, 4.0, 6.0, 9.0])
	var fm: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(probe, 4, 1, n.mask_params())
	var fixed_ok := absf(fm[0]) < EPS and absf(fm[1] - 0.5) < EPS and absf(fm[2] - 1.0) < EPS and absf(fm[3] - 1.0) < EPS
	var ramp := PackedFloat32Array()
	ramp.resize(1001)
	for i in 1001:
		ramp[i] = float(i) * 0.01 # 0..10 m
	ramp[1000] = 1.0e6
	n.range_mode = Pasture3DGraphNodeFloatToMask.RangeMode.AUTO
	var am: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(ramp, 1001, 1, n.mask_params())
	var med := am[500]
	_check("B", fixed_ok and absf(med - 0.5) < 0.02, "fixed %s (want [0, 0.5, 1, 1]); auto median %.4f (want ~0.5)" % [str(fm), med])
	n.low_percentile = 0.0
	n.high_percentile = 100.0
	var raw: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(ramp, 1001, 1, n.mask_params())
	_control(raw[500] < 0.01, "auto at 0/100%% reads the median as %s (want < 0.01)" % str(raw[500]))


# --- C. native route ---------------------------------------------------------------------------------
func _graph(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_node, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	g.set_output(2)
	return g


func _c_native() -> void:
	print("[C] Float to Mask lowers and the program's tap equals the kernel")
	var node := Pasture3DGraphNodeFloatToMask.new()
	_configure(node, 1, 15)
	var g := _graph(node)
	var rep: Dictionary = g.native_block_report(1)
	var f := _field()
	var tap := PackedFloat32Array()
	var compiled: Dictionary = g.compile_graph_program_multi([1])
	if not compiled.is_empty():
		var res: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], GW, GH, RECT, f,
				PackedInt32Array([int(compiled["slot_of"][1])]), PackedInt32Array([0]))
		var fields: Array = res.get("fields", [])
		if not fields.is_empty():
			tap = fields[0]
	var want: PackedFloat32Array = Pasture3DUtil.float_to_mask_grid(f, GW, GH, node.mask_params())
	var err := _worst(tap, want)
	_check("C", rep.is_empty() and err <= EPS, "block report %s, tap error %s"
			% ["clean" if rep.is_empty() else str(rep), str(err)])
	var dev := Pasture3DGraphNodeDevFloatToMask.new()
	var drep: Dictionary = _graph(dev).native_block_report(1)
	_control(int(drep.get("node", -1)) == 1, "the [Dev/GD] node blocks at node %s (want 1)" % str(drep.get("node", -1)))
