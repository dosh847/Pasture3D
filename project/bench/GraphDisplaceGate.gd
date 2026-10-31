# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDisplaceGate — Displace reads its input at a point moved by two offset fields, in metres.
#
# DB is the criterion that says this node does what Warp cannot: a constant dx of 30 m must move a cone's
# mass centroid by 30 m, and the old Warp node, given a comparable strength, must not — Warp adds its own
# warped noise on top of the input and never resamples the input itself.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphDisplaceGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const PARITY_EPS := 2.0e-5 # one float32 ulp at 200 m; both routes round a double to float
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphDisplaceGate: move the input by offset fields ===\n")
	_da_identity()
	_db_constant_offset_moves_mass()
	_dc_offset_is_metric()
	_dd_mask_scales_the_offset()
	_de_parity_and_route()
	_df_gpu()
	print("\n=== %s (%d failures) ===\n" % ["DISPLACE PASS" if _fail == 0 else "DISPLACE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- DA. unwired offsets or amount 0 is the identity -------------------------------------------------
func _da_identity() -> void:
	print("[DA] unwired offsets, or amount 0, return the input unchanged")
	var cone := _cone(140.0, 200.0)
	var d0 := _max_abs_diff(_displace_graph(null, null, null, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone), cone)
	var d1 := _max_abs_diff(_displace_graph(30.0, 0.0, null, 1.0, 0.0).evaluate(GW, GH, RECT, null, cone), cone)
	print("    unwired: %.9f, amount 0: %.9f (want 0 exactly)" % [d0, d1])
	if d0 > 0.0 or d1 > 0.0:
		_fail += 1; print("    !! the pass-through cases moved the surface")
	# CONTROL: the same graph with amount 1 must move it.
	var c := _max_abs_diff(_displace_graph(30.0, 0.0, null, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone), cone)
	print("    control: dx = 30 m, amount 1 moves it by %.3f m (want > 1)" % c)
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the node never displaces anything")


# --- DB. a constant offset translates the landform --------------------------------------------------
func _db_constant_offset_moves_mass() -> void:
	print("[DB] dx = +30 m reads the cone 30 m east, so its centroid moves 30 m WEST")
	var cone := _cone(140.0, 200.0)
	var c0 := _centroid(cone)
	var moved := _displace_graph(30.0, -20.0, null, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone)
	var shift := _centroid(moved) - c0
	print("    centroid shift = (%.2f, %.2f) m (want (-30, +20) within 2 m)" % [shift.x, shift.y])
	if absf(shift.x + 30.0) > 2.0 or absf(shift.y - 20.0) > 2.0:
		_fail += 1; print("    !! the offset did not translate the landform by its value in metres")

	# CONTROL: the Warp node at strength 30 is the node this one replaces for the job, and it cannot move
	# the cone at all. If it passed the same test, the test would not be measuring displacement.
	var w := Pasture3DGraphNodeWarp.new()
	w.strength = 30.0
	var warped := _build_chain([w]).evaluate(GW, GH, RECT, null, cone)
	var ws := _centroid(warped) - c0
	print("    control: Warp (strength 30) shifts the centroid by (%.2f, %.2f) m (want far from (-30, +20))"
			% [ws.x, ws.y])
	if absf(ws.x + 30.0) <= 2.0 and absf(ws.y - 20.0) <= 2.0:
		_fail += 1; print("    !! control dead — Warp passed a test it cannot pass, so DB measures nothing")


# --- DC. offsets are metres, not cells --------------------------------------------------------------
func _dc_offset_is_metric() -> void:
	print("[DC] the same offset in metres gives the same surface at two resolutions")
	var lo_n := 65
	var hi_n := 129
	var lo := _displace_graph(30.0, 10.0, null, 1.0, 1.0).evaluate(lo_n, lo_n, RECT, null, _cone_at(lo_n, 140.0, 200.0))
	var hi := _displace_graph(30.0, 10.0, null, 1.0, 1.0).evaluate(hi_n, hi_n, RECT, null, _cone_at(hi_n, 140.0, 200.0))
	var worst := _cross_resolution_diff(lo, lo_n, hi, hi_n)
	print("    max |65^2 - 129^2| = %.3f m (want < 10 m, 5%% of the relief)" % worst)
	if worst > 10.0:
		_fail += 1; print("    !! the offset is behaving as CELLS — it doubles when the grid does")
	# CONTROL: half the offset must differ by more than the tolerance.
	var half := _displace_graph(15.0, 5.0, null, 1.0, 1.0).evaluate(hi_n, hi_n, RECT, null, _cone_at(hi_n, 140.0, 200.0))
	var cw := _cross_resolution_diff(lo, lo_n, half, hi_n)
	print("    control: half the offset differs by %.3f m (want > 10)" % cw)
	if cw <= 10.0:
		_fail += 1; print("    !! control dead — this fixture cannot tell two offsets apart")


# --- DD. the mask scales the offset -----------------------------------------------------------------
func _dd_mask_scales_the_offset() -> void:
	print("[DD] a mask of 0.5 is the same as half the offset")
	var cone := _cone(140.0, 200.0)
	var masked := _displace_graph(30.0, -20.0, 0.5, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone)
	var halved := _displace_graph(15.0, -10.0, null, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone)
	var d := _max_abs_diff(masked, halved)
	print("    max |mask 0.5 - half offset| = %.6f m (want < 1e-3)" % d)
	if d > 1.0e-3:
		_fail += 1; print("    !! the mask does not scale the displacement")
	# CONTROL: the unmasked full offset must differ from the halved one.
	var full := _displace_graph(30.0, -20.0, null, 1.0, 1.0).evaluate(GW, GH, RECT, null, cone)
	var c := _max_abs_diff(full, halved)
	print("    control: full vs half offset differs by %.3f m (want > 1)" % c)
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the fixture cannot see the mask")


# --- DE. parity + the native route ------------------------------------------------------------------
func _de_parity_and_route() -> void:
	print("[DE] native == oracle on noise offsets, and the node takes the native C++ route")
	var cone := _cone(140.0, 200.0)
	var g := _noise_graph(40.0, 1.3, 1.0)
	if not g.native_supported():
		_fail += 1
		print("    !! native_supported() = FALSE — the op is missing from k_ops, which drops the WHOLE graph")
		print("       onto the GDScript evaluator.")
		return
	var native := g.evaluate(GW, GH, RECT, null, cone)
	var dev := Pasture3DGraphNodeDevDisplace.new()
	dev.scale = 1.3
	dev.amount = 1.0
	var oracle := dev.solve(cone, _noise_field(11, 40.0), _noise_field(23, 40.0), PackedFloat32Array(), GW, GH, RECT)
	var d := _max_abs_diff(native, oracle)
	print("    max |native - oracle| = %.9f (want < %s)" % [d, str(PARITY_EPS)])
	if d > PARITY_EPS:
		_fail += 1; print("    !! the C++ kernel and the oracle disagree")
	if _max_abs_diff(native, cone) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the noise offsets were a pass-through, so parity compared nothing")


# --- GPU route --------------------------------------------------------------------------------------
func _df_gpu() -> void:
	print("[gpu] the node takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var cone := _cone(140.0, 200.0)
	var cases := {"noise": _noise_graph(40.0, 1.3, 1.0), "masked": _displace_graph(30.0, -20.0, 0.5, 1.0, 1.0),
			"dx only": _displace_graph(30.0, null, null, 1.0, 1.0)}
	for label in cases:
		var g: Pasture3DTerrainGraph = cases[label]
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH, RECT, cone)
		if gpu.is_empty():
			var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_build_chain([]).compile_graph_program(), GW, GH, RECT, cone)
			if ctrl.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    %-8s !! the GPU bailed here but not on a bare in->out graph; the bail is graph-wide." % label)
			continue
		var cpu := g.evaluate(GW, GH, RECT, null, cone)
		var d := _max_abs_diff(gpu, cpu)
		print("    %-8s max |gpu - cpu| = %.8f" % [label, d])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel")
		if _max_abs_diff(gpu, cone) <= 1.0:
			_fail += 1; print("      !! NO-SIGNAL — the GPU returned the input unchanged")


# --- helpers ----------------------------------------------------------------------------------------
## Input -> Displace -> Output, with Const nodes on dx / dy / mask for each value that is not null.
func _displace_graph(p_dx, p_dy, p_mask, p_scale: float, p_amount: float) -> Pasture3DTerrainGraph:
	var dn := Pasture3DGraphNodeDisplace.new()
	dn.scale = p_scale
	dn.amount = p_amount
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), dn, Pasture3DGraphNodeOutput.new()]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	var vals := [p_dx, p_dy, p_mask]
	for k in 3:
		if vals[k] == null:
			continue
		var c := Pasture3DGraphNodeConst.new()
		c.value = float(vals[k])
		nodes.append(c)
		conns.append(PackedInt32Array([nodes.size() - 1, 0, 1, k + 1]))
	var g := Pasture3DTerrainGraph.new()
	g.nodes = nodes
	g.connections = conns
	return g


func _noise_graph(p_amp: float, p_scale: float, p_amount: float) -> Pasture3DTerrainGraph:
	var dn := Pasture3DGraphNodeDisplace.new()
	dn.scale = p_scale
	dn.amount = p_amount
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), dn, Pasture3DGraphNodeOutput.new(),
			_noise_node(11, p_amp), _noise_node(23, p_amp)]
	var g := Pasture3DTerrainGraph.new()
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0]),
			PackedInt32Array([3, 0, 1, 1]), PackedInt32Array([4, 0, 1, 2])]
	return g


func _make_noise(p_seed: int) -> FastNoiseLite:
	var fn := FastNoiseLite.new()
	fn.seed = p_seed
	fn.frequency = 0.01
	return fn


func _noise_node(p_seed: int, p_amp: float) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeNoise.new()
	n.noise = _make_noise(p_seed)
	n.amplitude = p_amp
	return n


## What the Noise node produces, sampled independently so the oracle does not take its input from the
## route it is checking.
func _noise_field(p_seed: int, p_amp: float) -> PackedFloat32Array:
	var fn := _make_noise(p_seed)
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = p_amp * fn.get_noise_2d(w.x, w.y)
	return a


func _build_chain(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(PackedInt32Array([i, 0, i + 1, 0]))
	g.connections = conns
	return g


func _cone(p_radius: float, p_height: float) -> PackedFloat32Array:
	return _cone_at(GW, p_radius, p_height)


func _cone_at(p_n: int, p_radius: float, p_height: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			a[iz * p_n + ix] = maxf(0.0, 1.0 - w.length() / p_radius) * p_height
	return a


func _centroid(p_g: PackedFloat32Array) -> Vector2:
	var c := Vector2.ZERO
	var mass := 0.0
	for iz in GH:
		for ix in GW:
			var v := p_g[iz * GW + ix]
			if is_nan(v) or v <= 0.0:
				continue
			c += Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT) * v
			mass += v
	return c / mass if mass > 0.0 else Vector2.ZERO


func _cross_resolution_diff(p_a: PackedFloat32Array, p_an: int, p_b: PackedFloat32Array, p_bn: int) -> float:
	var worst := 0.0
	var dx := RECT.size.x / float(p_bn)
	var dz := RECT.size.y / float(p_bn)
	for iz in range(4, p_an - 4):
		for ix in range(4, p_an - 4):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_an, p_an, RECT)
			var bx := clampi(int((w.x - RECT.position.x) / dx), 0, p_bn - 1)
			var bz := clampi(int((w.y - RECT.position.y) / dz), 0, p_bn - 1)
			worst = maxf(worst, absf(p_a[iz * p_an + ix] - p_b[bz * p_bn + bx]))
	return worst


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) and is_nan(y):
			continue
		if is_nan(x) or is_nan(y):
			return INF
		m = maxf(m, absf(x - y))
	return m
