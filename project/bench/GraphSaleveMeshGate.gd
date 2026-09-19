# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSaleveMeshGate: phase S2 of PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md — the coarse irregular solve and
# its reconstruction onto the grid.
#
#   A  reconstruction reproduces a plane (LINEAR and GRADIENT)
#   B  GRADIENT reproduces a paraboloid within tolerance; control: NEAREST must not
#   C  a full default solve (fBm warp on) writes no NaN into finite cells
#   D  channel directions on a cone have no 45-degree peaks; control: the S1 grid solver must
#   E  the node lowers every S2 export into its LUT, in the order the native op reads it
#   F  the compiled native program matches the node's dictionary route; control: defaults do not
#
# The solver is called directly; nothing here reconstructs anything itself.

extends Node

const HydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_saleve.gd")

const GW := 128
const GH := 128
const RECT := Rect2(0, 0, 256, 256)
const EXPECTED := 6
const PARABOLOID_TOL := 0.12 # metres, on a 50 m paraboloid; LINEAR measures 0.13, GRADIENT 0.09
const AXIS_WINDOW_DEG := 3.0
const AXIS_FRACTION_MAX := 0.35

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphSaleveMeshGate: Salève S2 mesh solve and reconstruction ===\n")
	_a_plane()
	_b_paraboloid()
	_c_no_nan()
	_d_orientation()
	_e_lowering()
	_f_native_route()
	var ok := _fail == 0 and _done == EXPECTED
	print("\n=== %s (%d failures, %d/%d criteria completed) ===" % [
		"SALEVE MESH PASS" if ok else "SALEVE MESH FAIL", _fail, _done, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _a_plane() -> void:
	print("[A] a plane reconstructs exactly")
	var plane := _field(func(x: float, z: float) -> float: return 0.2 * x - 0.1 * z + 7.0)
	var worst := 0.0
	for mode in [0, 1]:
		var out: PackedFloat32Array = _recon(plane, mode).height
		var e := _max_err(out, plane)
		print("    reconstruction %s: max |err| %.6f m (want < 0.001)" % ["LINEAR" if mode == 0 else "GRADIENT", e])
		worst = maxf(worst, e)
	if worst >= 1.0e-3:
		_fail += 1
		print("    !! a plane did not survive reconstruction")
		return
	_done += 1


func _b_paraboloid() -> void:
	print("\n[B] a paraboloid reconstructs within %.2f m" % PARABOLOID_TOL)
	var para := _paraboloid()
	var e_grad := _max_err(_recon(para, 1).height, para)
	var e_lin := _max_err(_recon(para, 0).height, para)
	var e_near := _max_err(_recon(para, 2).height, para)
	print("    GRADIENT %.4f m (want < %.2f), LINEAR %.4f m (reported), control NEAREST %.4f m (want >= %.2f)"
			% [e_grad, PARABOLOID_TOL, e_lin, e_near, PARABOLOID_TOL])
	if e_near < PARABOLOID_TOL:
		_fail += 1
		print("    !! nearest-vertex passed too, so the tolerance separates nothing")
		return
	if e_grad >= PARABOLOID_TOL:
		_fail += 1
		print("    !! GRADIENT reconstruction is not accurate enough")
		return
	_done += 1


func _c_no_nan() -> void:
	print("\n[C] a full default solve writes no NaN")
	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(_cone(), GW, GH, RECT, {"seed": 3})
	var bad := 0
	for key in ["height", "eroded_rock", "sediment"]:
		for v in (res[key] as PackedFloat32Array):
			if not is_finite(v):
				bad += 1
	print("    non-finite cells across the three outputs: %d (want 0); vertices %d" % [bad, int(res.vertex_count)])
	if bad != 0 or int(res.vertex_count) < 100:
		_fail += 1
		print("    !! the solve wrote NaN, or never built a mesh")
		return
	_done += 1


func _d_orientation() -> void:
	print("\n[D] channel directions on a cone are not locked to 45 degrees")
	var mesh := _axis_fraction(false)
	var grid := _axis_fraction(true)
	print("    channel edges within %.0f deg of a multiple of 45: mesh %.3f (want < %.2f), control grid %.3f (want >= %.2f)"
			% [AXIS_WINDOW_DEG, mesh, AXIS_FRACTION_MAX, grid, AXIS_FRACTION_MAX])
	if grid < AXIS_FRACTION_MAX:
		_fail += 1
		print("    !! the grid control is not axis-locked, so the histogram measures nothing")
		return
	if mesh >= AXIS_FRACTION_MAX:
		_fail += 1
		print("    !! mesh channels are still axis-locked")
		return
	_done += 1


func _e_lowering() -> void:
	print("\n[E] every S2 export reaches the native LUT")
	var node := HydraulicSaleve.new()
	node.control_points = 4321
	node.point_spacing = 3.5
	node.reconstruction = HydraulicSaleve.Reconstruction.LINEAR
	node.default_warp = false
	node.warp_amount = 2.25
	node.warp_size = 40.0
	var ext: PackedFloat32Array = node.native_lower().get("lut", PackedFloat32Array())
	var want := PackedFloat32Array([4321.0, 3.5, 0.0, 0.0, 2.25, 40.0])
	print("    lut %s (want %s)" % [ext, want])
	node.warp_size = 41.0
	var moved: PackedFloat32Array = node.native_lower().get("lut", PackedFloat32Array())
	if ext != want:
		_fail += 1
		print("    !! the LUT does not carry the exports in the native op's order")
		return
	if moved == ext:
		_fail += 1
		print("    !! control: changing warp_size did not change the LUT")
		return
	_done += 1


func _f_native_route() -> void:
	print("
[F] the compiled program reads the LUT (native route == dictionary route)")
	var graph := Pasture3DTerrainGraph.new()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var node = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	node.control_points = 2500
	node.reconstruction = HydraulicSaleve.Reconstruction.LINEAR
	node.warp_amount = 6.0
	node.iterations = 30
	var id_cone: int = graph.add_node(cone)
	var id_sal: int = graph.add_node(node)
	graph.connect_ports(id_cone, 0, id_sal, 0)
	var rect := Rect2(0, 0, 256, 256)
	var surface: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(id_cone), GW, GH, rect, PackedFloat32Array())
	var native: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(id_sal), GW, GH, rect, PackedFloat32Array())
	var dict_route: PackedFloat32Array = node._solve_dynamic(surface, GW, GH, rect, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array())[0]
	var defaults: PackedFloat32Array = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, GW, GH, rect, {"iterations": 30}).height
	var d_route := _max_err(native, dict_route)
	var d_ctrl := _max_err(native, defaults)
	print("    native vs dictionary route %.6f m (want < 0.0001); control vs S2 defaults %.4f m (want > 0.01)" % [d_route, d_ctrl])
	if native.size() != GW * GH or d_ctrl <= 0.01:
		_fail += 1
		print("    !! the control matched, so the LUT settings never reached the kernel (or nothing ran)")
		return
	if d_route >= 1.0e-4:
		_fail += 1
		print("    !! the native program and the node's own solve disagree")
		return
	_done += 1


# ---- helpers ------------------------------------------------------------------------------------

func _recon(p_surface: PackedFloat32Array, p_mode: int) -> Dictionary:
	return Pasture3DUtil.hydraulic_saleve_solve_grid(p_surface, GW, GH, RECT, {
		"reconstruct_only": true, "reconstruction": p_mode, "control_points": 1500, "seed": 11})


func _axis_fraction(p_grid: bool) -> float:
	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(_cone(), GW, GH, RECT, {
		"seed": 5, "debug_network": true, "grid_solve": p_grid, "control_points": 6000, "drainage_noise": 0.3})
	var rec: PackedInt32Array = res.receivers
	var area: PackedFloat32Array = res.drainage_area
	var verts: PackedVector2Array = res.vertices
	# Channels: vertices draining at least 20x the mean vertex area.
	var mean := 0.0
	for i in range(rec.size()):
		mean += area[i] if rec[i] == i else 0.0
	mean /= float(rec.size())
	var hits := 0
	var total := 0
	for i in range(rec.size()):
		if rec[i] == i or area[i] < 20.0 * mean:
			continue
		var d := verts[rec[i]] - verts[i]
		var deg := rad_to_deg(atan2(d.y, d.x))
		var off := absf(fposmod(deg + 22.5, 45.0) - 22.5)
		total += 1
		if off <= AXIS_WINDOW_DEG:
			hits += 1
	return float(hits) / float(maxi(total, 1))


func _field(p_f: Callable) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var x := RECT.position.x + (ix + 0.5) * RECT.size.x / GW
			var z := RECT.position.y + (iz + 0.5) * RECT.size.y / GH
			a[iz * GW + ix] = p_f.call(x, z)
	return a


func _paraboloid() -> PackedFloat32Array:
	return _field(func(x: float, z: float) -> float:
		var u := (x - 128.0) / 128.0
		var v := (z - 128.0) / 128.0
		return 50.0 * (u * u + v * v))


func _cone() -> PackedFloat32Array:
	return _field(func(x: float, z: float) -> float:
		var r := Vector2(x - 128.0, z - 128.0).length() / 128.0
		return 80.0 * maxf(0.0, 1.0 - r) + 2.0)


# Interior cells only: the outermost cell ring samples outside the point hull's cell-centre range.
func _max_err(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var m := 0.0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			m = maxf(m, absf(p_a[iz * GW + ix] - p_b[iz * GW + ix]))
	return m
