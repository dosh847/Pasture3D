# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphRecastCanyonGate — Recast Canyon reshapes the band between a floor and a cut height with a power curve.
#
# RA checks the formula against HighMap's own (vcut * (z / vcut)^gamma below the cut, with the floor at 0).
# RB checks what the node is FOR: gamma < 1 must steepen the walls at the floor, gamma > 1 must flatten it,
# and the two must disagree — so each is the other's control.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphRecastCanyonGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const PARITY_EPS := 2.0e-5 # one float32 ulp at 200 m
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphRecastCanyonGate: a power curve between floor and cut ===\n")
	_ra_matches_highmap()
	_rb_gamma_shapes_the_floor()
	_rc_noise_and_mask()
	_rd_parity_and_route()
	_re_gpu()
	print("\n=== %s (%d failures) ===\n" % ["RECAST CANYON PASS" if _fail == 0 else "RECAST CANYON FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- RA. HighMap's formula, and pass-through outside the band ----------------------------------------
func _ra_matches_highmap() -> void:
	print("[RA] floor 0: z < cut becomes cut * (z / cut)^gamma; z >= cut is untouched")
	var cone := _cone(200.0, 200.0)
	var cut := 120.0
	var out := _graph(cut, 0.0, 0.5, 1.0, null, null).evaluate(GW, GH, RECT, null, cone)
	var worst := 0.0
	var above := 0.0
	for i in cone.size():
		var z := cone[i]
		var want := z if (z >= cut or z <= 0.0) else cut * pow(z / cut, 0.5)
		worst = maxf(worst, absf(out[i] - want))
		if z >= cut:
			above = maxf(above, absf(out[i] - z))
	print("    max |node - HighMap| = %.6f m (want < 1e-3); above the cut it moved %.9f m (want 0)" % [worst, above])
	if worst > 1.0e-3:
		_fail += 1; print("    !! the node does not compute HighMap's recast")
	if above > 0.0:
		_fail += 1; print("    !! ground above the cut moved")
	# CONTROL: the band must actually change, or a pass-through would match the formula at gamma near 1.
	var moved := _max_abs_diff(out, cone)
	print("    control: the band moved by %.3f m (want > 10)" % moved)
	if moved <= 10.0:
		_fail += 1; print("    !! control dead — the recast changed nothing, so RA compared nothing")


# --- RB. gamma < 1 steepens the floor, gamma > 1 flattens it -----------------------------------------
func _rb_gamma_shapes_the_floor() -> void:
	print("[RB] the slope just above the floor: gamma 0.5 steeper than the input, gamma 2 shallower")
	var cone := _cone(200.0, 200.0) # 1 m/m everywhere on the flank
	var s_in := _floor_slope(cone, 20.0)
	var s_lo := _floor_slope(_graph(120.0, 20.0, 0.5, 1.0, null, null).evaluate(GW, GH, RECT, null, cone), 20.0)
	var s_hi := _floor_slope(_graph(120.0, 20.0, 2.0, 1.0, null, null).evaluate(GW, GH, RECT, null, cone), 20.0)
	print("    mean slope in the lowest 15 m of the band: input %.3f, gamma 0.5 %.3f, gamma 2 %.3f" % [s_in, s_lo, s_hi])
	if s_lo <= s_in * 1.3:
		_fail += 1; print("    !! gamma < 1 did not steepen the walls at the floor")
	if s_hi >= s_in * 0.7:
		_fail += 1; print("    !! gamma > 1 did not flatten the floor")


# --- RC. noise moves the cut; mask scales the change -------------------------------------------------
func _rc_noise_and_mask() -> void:
	print("[RC] noise = +20 is the same as cut + 20; mask 0.5 is the same as amount 0.5")
	var cone := _cone(200.0, 200.0)
	var noised := _graph(100.0, 0.0, 0.5, 1.0, 20.0, null).evaluate(GW, GH, RECT, null, cone)
	var raised := _graph(120.0, 0.0, 0.5, 1.0, null, null).evaluate(GW, GH, RECT, null, cone)
	var d := _max_abs_diff(noised, raised)
	var base := _graph(100.0, 0.0, 0.5, 1.0, null, null).evaluate(GW, GH, RECT, null, cone)
	var c := _max_abs_diff(noised, base)
	print("    |noise 20 - cut 120| = %.6f (want < 1e-3); control |noise 20 - no noise| = %.3f (want > 1)" % [d, c])
	if d > 1.0e-3:
		_fail += 1; print("    !! the noise does not offset the cut height")
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the noise changed nothing")
	var masked := _graph(120.0, 0.0, 0.5, 1.0, null, 0.5).evaluate(GW, GH, RECT, null, cone)
	var half := _graph(120.0, 0.0, 0.5, 0.5, null, null).evaluate(GW, GH, RECT, null, cone)
	var m := _max_abs_diff(masked, half)
	var mc := _max_abs_diff(masked, raised)
	print("    |mask 0.5 - amount 0.5| = %.6f (want < 1e-3); control |mask 0.5 - full| = %.3f (want > 1)" % [m, mc])
	if m > 1.0e-3:
		_fail += 1; print("    !! the mask does not scale the recast")
	if mc <= 1.0:
		_fail += 1; print("    !! control dead — the mask changed nothing")


# --- RD. parity + the native route -------------------------------------------------------------------
func _rd_parity_and_route() -> void:
	print("[RD] native == oracle with a noise cut, and the node takes the native C++ route")
	var cone := _cone(200.0, 200.0)
	for gam in [0.5, 2.5]:
		var g := _noise_graph(110.0, 15.0, gam, 0.8)
		if not g.native_supported():
			_fail += 1
			print("    !! native_supported() = FALSE — the op is missing from k_ops, which drops the WHOLE graph")
			print("       onto the GDScript evaluator.")
			return
		var native := g.evaluate(GW, GH, RECT, null, cone)
		var dev := Pasture3DGraphNodeDevRecastCanyon.new()
		dev.cut_height = 110.0
		dev.floor_height = 15.0
		dev.gamma = gam
		dev.amount = 0.8
		var oracle := dev.solve(cone, _noise_field(31, 25.0), PackedFloat32Array())
		var d := _max_abs_diff(native, oracle)
		print("    gamma %.1f  max |native - oracle| = %.9f (want < %s)" % [gam, d, str(PARITY_EPS)])
		if d > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree")
		if _max_abs_diff(native, cone) <= 1.0:
			_fail += 1; print("      !! NO-SIGNAL — a pass-through, so parity compared nothing")


# --- GPU route ---------------------------------------------------------------------------------------
func _re_gpu() -> void:
	print("[gpu] the node takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var cone := _cone(200.0, 200.0)
	var cases := {"noise": _noise_graph(110.0, 15.0, 0.5, 0.8), "masked": _graph(120.0, 0.0, 2.0, 1.0, 10.0, 0.5),
			"plain": _graph(120.0, 0.0, 0.5, 1.0, null, null)}
	for label in cases:
		var g: Pasture3DTerrainGraph = cases[label]
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH, RECT, cone)
		if gpu.is_empty():
			var bare := Pasture3DTerrainGraph.new()
			var bn: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
			bare.nodes = bn
			bare.connections = [PackedInt32Array([0, 0, 1, 0])]
			var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(bare.compile_graph_program(), GW, GH, RECT, cone)
			if ctrl.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    %-7s !! the GPU bailed here but not on a bare in->out graph; the bail is graph-wide." % label)
			continue
		var cpu := g.evaluate(GW, GH, RECT, null, cone)
		var d := _max_abs_diff(gpu, cpu)
		print("    %-7s max |gpu - cpu| = %.8f" % [label, d])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel")
		if _max_abs_diff(gpu, cone) <= 1.0:
			_fail += 1; print("      !! NO-SIGNAL — the GPU returned the input unchanged")


# --- helpers -----------------------------------------------------------------------------------------
func _node(p_cut: float, p_floor: float, p_gamma: float, p_amount: float) -> Pasture3DGraphNodeRecastCanyon:
	var n := Pasture3DGraphNodeRecastCanyon.new()
	n.cut_height = p_cut
	n.floor_height = p_floor
	n.gamma = p_gamma
	n.amount = p_amount
	return n


## Input -> Recast Canyon -> Output, with Const nodes on noise / mask for each value that is not null.
func _graph(p_cut: float, p_floor: float, p_gamma: float, p_amount: float, p_noise, p_mask) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _node(p_cut, p_floor, p_gamma, p_amount),
			Pasture3DGraphNodeOutput.new()]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	var vals := [p_noise, p_mask]
	for k in 2:
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


func _noise_graph(p_cut: float, p_floor: float, p_gamma: float, p_amount: float) -> Pasture3DTerrainGraph:
	var nz := Pasture3DGraphNodeNoise.new()
	nz.noise = _make_noise(31)
	nz.amplitude = 25.0
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _node(p_cut, p_floor, p_gamma, p_amount),
			Pasture3DGraphNodeOutput.new(), nz]
	var g := Pasture3DTerrainGraph.new()
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0]), PackedInt32Array([3, 0, 1, 1])]
	return g


func _make_noise(p_seed: int) -> FastNoiseLite:
	var fn := FastNoiseLite.new()
	fn.seed = p_seed
	fn.frequency = 0.01
	return fn


func _noise_field(p_seed: int, p_amp: float) -> PackedFloat32Array:
	var fn := _make_noise(p_seed)
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = p_amp * fn.get_noise_2d(w.x, w.y)
	return a


func _cone(p_radius: float, p_height: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = maxf(0.0, 1.0 - w.length() / p_radius) * p_height
	return a


## Mean central-difference slope magnitude over cells whose INPUT-cone height is within 15 m above the floor.
## The cell set is chosen from the cone's radius, so every surface is measured over the same ground.
func _floor_slope(p_g: PackedFloat32Array, p_floor: float) -> float:
	var cell := RECT.size.x / float(GW)
	var sum := 0.0
	var count := 0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var r := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT).length()
			var z_cone := maxf(0.0, 1.0 - r / 200.0) * 200.0
			if z_cone <= p_floor + 2.0 or z_cone > p_floor + 15.0:
				continue
			var gx := (p_g[iz * GW + ix + 1] - p_g[iz * GW + ix - 1]) / (2.0 * cell)
			var gz := (p_g[(iz + 1) * GW + ix] - p_g[(iz - 1) * GW + ix]) / (2.0 * cell)
			sum += sqrt(gx * gx + gz * gz)
			count += 1
	return sum / float(maxi(count, 1))


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
