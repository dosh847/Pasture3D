# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathOpsParityGate — asserts mathematical parity between C++ native operations and [Dev/GD] reference nodes.
extends Node

const DevPathDrape = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_drape.gd")
const DevPathWidthField = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_width_field.gd")
const DevPathFromFlow = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_from_flow.gd")
const DevPathResample = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_resample.gd")
const DevPathSmooth = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_smooth.gd")
const DevPathDecimate = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_decimate.gd")
const DevPathFractalize = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_fractalize.gd")
const DevPathMeanderize = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_meanderize.gd")
const DevPathWidth = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_path_width.gd")

const CRITERIA: Array[String] = [
	"A_DRAPE",
	"B_WIDTH_FIELD",
	"C_FROM_FLOW",
	"D_RESAMPLE",
	"E_SMOOTH",
	"F_DECIMATE",
	"G_FRACTALIZE",
	"H_MEANDERIZE",
	"I_WIDTH",
	"J_FAIL_FAST"
]

const GW := 64
const GH := 64
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0)

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathOpsParityGate: C++ vs GDScript Oracle Parity ===")

	_test_drape_parity()
	_test_width_field_parity()
	_test_from_flow_parity()
	_test_resample_parity()
	_test_smooth_parity()
	_test_decimate_parity()
	_test_fractalize_parity()
	_test_meanderize_parity()
	_test_width_parity()
	_test_fail_fast_assertion()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH OPS PARITY %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

func _make_path(p_closed: bool = false) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.closed = p_closed
	var pts := PackedVector2Array()
	var hw := PackedFloat32Array()
	var hs := PackedFloat32Array()
	var count := 12
	for i in count:
		var f := float(i) / float(count - 1)
		var x := -60.0 + f * 120.0
		var y := 30.0 * sin(f * TAU)
		if p_closed:
			var ang := f * TAU
			x = 50.0 * cos(ang)
			y = 40.0 * sin(ang)
		pts.append(Vector2(x, y))
		hw.append(2.0 + 3.0 * f)
		hs.append(10.0 + 15.0 * f)
	p.points = pts
	p.half_widths = hw
	p.heights = hs
	return p


func _make_grid() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var fx := float(ix) / float(GW - 1)
			var fz := float(iz) / float(GH - 1)
			g[iz * GW + ix] = 20.0 + 50.0 * sin(fx * 3.0) + 20.0 * cos(fz * 4.0)
	return g


func _make_flow_grid() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var dx := (float(ix) - float(GW) * 0.5) / float(GW)
			var dz := (float(iz) - float(GH) * 0.5) / float(GH)
			var dist := sqrt(dx * dx + dz * dz)
			g[iz * GW + ix] = maxf(10.0 - dist * 15.0, 0.0)
	return g


# ---- tests --------------------------------------------------------------------------------------

func _test_drape_parity() -> void:
	var grid := _make_grid()
	var src_open := _make_path(false)
	var src_closed := _make_path(true)

	# 1. Plain drape open
	var prod := Pasture3DGraphNodePathDrape.new()
	prod.offset = 1.5
	prod.force_downhill = false
	prod.eval_grid([grid], GW, GH, null, RECT)
	var out_prod := prod.eval_path([src_open])

	var dev = DevPathDrape.new()
	dev.offset = 1.5
	dev.force_downhill = false
	dev.eval_grid([grid], GW, GH, null, RECT)
	var out_dev = dev.eval_path([src_open])

	var worst_diff := 0.0
	for i in out_prod.heights.size():
		worst_diff = maxf(worst_diff, absf(out_prod.heights[i] - out_dev.heights[i]))

	# 2. Force downhill open
	prod.force_downhill = true
	prod.min_drop = 0.05
	out_prod = prod.eval_path([src_open])

	dev.force_downhill = true
	dev.min_drop = 0.05
	out_dev = dev.eval_path([src_open])

	for i in out_prod.heights.size():
		worst_diff = maxf(worst_diff, absf(out_prod.heights[i] - out_dev.heights[i]))

	# 3. Closed path
	prod.eval_grid([grid], GW, GH, null, RECT)
	out_prod = prod.eval_path([src_closed])
	dev.eval_grid([grid], GW, GH, null, RECT)
	out_dev = dev.eval_path([src_closed])

	for i in out_prod.heights.size():
		worst_diff = maxf(worst_diff, absf(out_prod.heights[i] - out_dev.heights[i]))

	_check("A_DRAPE", worst_diff < 1e-4, "PathDrape C++ vs GDScript max height diff: %.6f m" % worst_diff)


func _test_width_field_parity() -> void:
	var grid := _make_grid()
	var src := _make_path(false)

	var prod := Pasture3DGraphNodePathWidthField.new()
	prod.field_min = 0.0
	prod.field_max = 50.0
	prod.half_width_min = 1.0
	prod.half_width_max = 12.0
	prod.eval_grid([grid], GW, GH, null, RECT)
	var out_prod := prod.eval_path([src])

	var dev = DevPathWidthField.new()
	dev.field_min = 0.0
	dev.field_max = 50.0
	dev.half_width_min = 1.0
	dev.half_width_max = 12.0
	dev.eval_grid([grid], GW, GH, null, RECT)
	var out_dev = dev.eval_path([src])

	var worst_diff := 0.0
	for i in out_prod.half_widths.size():
		worst_diff = maxf(worst_diff, absf(out_prod.half_widths[i] - out_dev.half_widths[i]))

	_check("B_WIDTH_FIELD", worst_diff < 1e-3, "PathWidthField C++ vs GDScript max width diff: %.6f m" % worst_diff)


func _test_from_flow_parity() -> void:
	var flow := _make_flow_grid()
	var surf := _make_grid()

	var prod := Pasture3DGraphNodePathFromFlow.new()
	prod.seed_mode = Pasture3DGraphNodePathFromFlow.Seed.OUTLET
	prod.min_flow = 0.5
	prod.step_cells = 2
	prod.max_points = 64
	prod.half_width = 4.5
	prod.eval_grid([flow, surf], GW, GH, null, RECT)
	var out_prod := prod.eval_path([])

	var dev = DevPathFromFlow.new()
	dev.seed_mode = 0 # OUTLET
	dev.min_flow = 0.5
	dev.step_cells = 2
	dev.max_points = 64
	dev.half_width = 4.5
	dev.eval_grid([flow, surf], GW, GH, null, RECT)
	var out_dev = dev.eval_path([])

	var ok: bool = out_prod != null and out_dev != null and out_prod.points.size() == out_dev.points.size()
	var worst_diff := 0.0
	if ok:
		for i in out_prod.points.size():
			worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))
			worst_diff = maxf(worst_diff, absf(out_prod.half_widths[i] - out_dev.half_widths[i]))
			worst_diff = maxf(worst_diff, absf(out_prod.heights[i] - out_dev.heights[i]))

	_check("C_FROM_FLOW", ok and worst_diff < 1e-4,
			"PathFromFlow C++ vs GDScript (points: %d, max diff: %.6f)" % [out_prod.points.size() if out_prod else 0, worst_diff])


func _test_resample_parity() -> void:
	var src_open := _make_path(false)
	var src_closed := _make_path(true)

	var worst_diff := 0.0
	var all_ok := true

	for method_idx in [0, 1, 2, 3]:
		for path_in in [src_open, src_closed]:
			var prod := Pasture3DGraphNodePathResample.new()
			prod.method = method_idx
			prod.step = 3.5
			var out_prod := prod.eval_path([path_in])

			var dev = DevPathResample.new()
			dev.method = method_idx
			dev.step = 3.5
			var out_dev = dev.eval_path([path_in])

			if out_prod.points.size() != out_dev.points.size():
				all_ok = false
				break
			for i in out_prod.points.size():
				worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))
				worst_diff = maxf(worst_diff, absf(out_prod.half_widths[i] - out_dev.half_widths[i]))
				worst_diff = maxf(worst_diff, absf(out_prod.heights[i] - out_dev.heights[i]))

	_check("D_RESAMPLE", all_ok and worst_diff < 1e-4,
			"PathResample C++ vs GDScript max diff across all methods: %.6f" % worst_diff)


func _test_smooth_parity() -> void:
	var src_open := _make_path(false)
	var src_closed := _make_path(true)
	var worst_diff := 0.0

	for path_in in [src_open, src_closed]:
		for pin in [true, false]:
			var prod := Pasture3DGraphNodePathSmooth.new()
			prod.window = 3
			prod.intensity = 0.75
			prod.inertia = 0.2
			prod.pin_ends = pin
			var out_prod := prod.eval_path([path_in])

			var dev = DevPathSmooth.new()
			dev.window = 3
			dev.intensity = 0.75
			dev.inertia = 0.2
			dev.pin_ends = pin
			var out_dev = dev.eval_path([path_in])

			for i in out_prod.points.size():
				worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))

	_check("E_SMOOTH", worst_diff < 1e-4, "PathSmooth C++ vs GDScript max point diff: %.6f" % worst_diff)


func _test_decimate_parity() -> void:
	var src := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var hw := PackedFloat32Array()
	var hs := PackedFloat32Array()
	for i in 60:
		var f := float(i) / 59.0
		pts.append(Vector2(-100.0 + f * 200.0, 40.0 * sin(f * 4.0 * PI)))
		hw.append(3.0)
		hs.append(15.0)
	src.points = pts
	src.half_widths = hw
	src.heights = hs

	var prod := Pasture3DGraphNodePathDecimate.new()
	prod.target_points = 20
	prod.min_area = 5.0
	var out_prod := prod.eval_path([src])

	var dev = DevPathDecimate.new()
	dev.target_points = 20
	dev.min_area = 5.0
	var out_dev = dev.eval_path([src])

	var ok: bool = out_prod.points.size() == out_dev.points.size()
	var worst_diff := 0.0
	if ok:
		for i in out_prod.points.size():
			worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))

	_check("F_DECIMATE", ok and worst_diff < 1e-4,
			"PathDecimate C++ vs GDScript (%d pts, max diff: %.6f)" % [out_prod.points.size(), worst_diff])


func _test_fractalize_parity() -> void:
	var src := _make_path(false)

	var prod := Pasture3DGraphNodePathFractalize.new()
	prod.wavelength = 40.0
	prod.lacunarity = 2.0
	prod.iterations = 3
	prod.sigma = 4.0
	prod.persistence = 0.5
	prod.seed = 1234
	var out_prod := prod.eval_path([src])

	var dev = DevPathFractalize.new()
	dev.wavelength = 40.0
	dev.lacunarity = 2.0
	dev.iterations = 3
	dev.sigma = 4.0
	dev.persistence = 0.5
	dev.seed = 1234
	var out_dev = dev.eval_path([src])

	var ok: bool = out_prod.points.size() == out_dev.points.size()
	var worst_diff := 0.0
	if ok:
		for i in out_prod.points.size():
			worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))

	_check("G_FRACTALIZE", ok and worst_diff < 1e-4,
			"PathFractalize C++ vs GDScript (%d pts, max diff: %.6f)" % [out_prod.points.size(), worst_diff])


func _test_meanderize_parity() -> void:
	var src := _make_path(false)

	var prod := Pasture3DGraphNodePathMeanderize.new()
	prod.ratio = 0.3
	prod.noise_ratio = 0.05
	prod.seed = 777
	prod.iterations = 2
	prod.edge_divisions = 2
	prod.min_segment_length = 5.0
	prod.remove_loops = true
	var out_prod := prod.eval_path([src])

	var dev = DevPathMeanderize.new()
	dev.ratio = 0.3
	dev.noise_ratio = 0.05
	dev.seed = 777
	dev.iterations = 2
	dev.edge_divisions = 2
	dev.min_segment_length = 5.0
	dev.remove_loops = true
	var out_dev = dev.eval_path([src])

	var ok: bool = out_prod.points.size() == out_dev.points.size()
	var worst_diff := 0.0
	if ok:
		for i in out_prod.points.size():
			worst_diff = maxf(worst_diff, out_prod.points[i].distance_to(out_dev.points[i]))

	_check("H_MEANDERIZE", ok and worst_diff < 1e-3,
			"PathMeanderize C++ vs GDScript (%d pts, max diff: %.6f)" % [out_prod.points.size(), worst_diff])


func _test_width_parity() -> void:
	var src := _make_path(false)

	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 3.0))

	var prod := Pasture3DGraphNodePathWidth.new()
	prod.mode = Pasture3DGraphNodePathWidth.Mode.SCALE
	prod.half_width = 2.0
	prod.along = curve
	var out_prod := prod.eval_path([src])

	var dev = DevPathWidth.new()
	dev.mode = 1 # SCALE
	dev.half_width = 2.0
	dev.along = curve
	var out_dev = dev.eval_path([src])

	var worst_diff := 0.0
	for i in out_prod.half_widths.size():
		worst_diff = maxf(worst_diff, absf(out_prod.half_widths[i] - out_dev.half_widths[i]))

	_check("I_WIDTH", worst_diff < 1e-3, "PathWidth C++ vs GDScript max width diff: %.6f" % worst_diff)


func _test_fail_fast_assertion() -> void:
	var methods := [
		"path_drape_solve",
		"path_width_field_solve",
		"path_from_flow_solve",
		"path_resample_solve",
		"path_smooth_solve",
		"path_decimate_solve",
		"path_fractalize_solve",
		"path_meanderize_solve",
		"path_width_solve"
	]
	var all_bound := true
	for m in methods:
		if not ClassDB.class_has_method("Pasture3DUtil", m):
			all_bound = false
			print("!! Missing ClassDB method on Pasture3DUtil: ", m)

	_check("J_FAIL_FAST", all_bound, "All 9 path operation methods bound on Pasture3DUtil")
