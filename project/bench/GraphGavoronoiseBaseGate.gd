# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGavoronoiseBaseGate — Gavoronoise with `base` wired erodes THAT surface along its own slope (§7.2).
#
# BB is the criterion that says the gullies follow the input. On a cone the downhill is radial, so gullies
# running down it vary ACROSS the radius: east of the peak the detail changes along Z, north of it along X.
# The control is the generator form's detail, which follows its own landform, not the cone, and so cannot
# score high in both sectors.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphGavoronoiseBaseGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const ORACLE_N := 48
const PARITY_EPS := 5.0e-5 # a few float32 ulps at 200 m
const GPU_TOL := 2.0e-2

var _fail := 0


func _ready() -> void:
	print("=== GraphGavoronoiseBaseGate: erode a wired surface along its own slope ===\n")
	_ba_zero_strength_is_the_input()
	_bb_gullies_follow_the_input()
	_bc_below_the_cut_is_untouched()
	_bd_parity_and_route()
	_be_gpu()
	print("\n=== %s (%d failures) ===\n" % ["GAVORONOISE BASE PASS" if _fail == 0 else "GAVORONOISE BASE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BA. strength 0 returns the input, bit for bit ----------------------------------------------------
func _ba_zero_strength_is_the_input() -> void:
	print("[BA] erosion_strength 0 returns the input exactly; NaN passes through")
	var cone := _cone()
	cone[5] = NAN
	var n := _gav()
	n.erosion_strength = 0.0
	var got := _wired(n).evaluate(GW, GH, RECT, null, cone)
	var d := _max_abs_diff(got, cone)
	print("    max |out - in| = %.9f (want 0 exactly)" % d)
	if d > 0.0:
		_fail += 1; print("    !! strength 0 changed the surface")
	# CONTROL: a non-zero strength must change it, and keep the NaN.
	var on := _wired(_gav()).evaluate(GW, GH, RECT, null, cone)
	var c := _max_abs_diff_finite(on, cone)
	print("    control: strength 0.1 moves it by %.3f m (want > 1); NaN kept: %s" % [c, str(is_nan(on[5]))])
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the base form does nothing")
	if not is_nan(on[5]):
		_fail += 1; print("    !! a NaN input cell came out finite")


# --- BB. gullies run down the input ------------------------------------------------------------------
func _bb_gullies_follow_the_input() -> void:
	print("[BB] on a cone, the gully detail varies across the downhill: along Z east of the peak, along X north")
	var cone := _cone()
	var detail := _sub(_wired(_gav()).evaluate(GW, GH, RECT, null, cone), cone)
	var e := _sector_anisotropy(detail, Vector2(1, 0))
	var nn := _sector_anisotropy(detail, Vector2(0, 1))
	print("    base form: east %.2f, north %.2f (want both > 3)" % [e, nn])
	if e <= 3.0 or nn <= 3.0:
		_fail += 1; print("    !! the gullies do not follow the cone's radial downhill")
	# CONTROL: the generator's gullies follow its own landform, so they cannot be radial on both sides.
	var gn := _gav()
	gn.erosion_strength = 0.0
	var gen_base := _standalone(gn).evaluate(GW, GH, RECT)
	var gen_detail := _sub(_standalone(_gav()).evaluate(GW, GH, RECT), gen_base)
	var ce := _sector_anisotropy(gen_detail, Vector2(1, 0))
	var cn := _sector_anisotropy(gen_detail, Vector2(0, 1))
	print("    control: generator east %.2f, north %.2f (want at least one <= 3)" % [ce, cn])
	if ce > 3.0 and cn > 3.0:
		_fail += 1; print("    !! control dead — any gully field passes, so BB measures nothing")
	if _relief(gen_detail) <= 0.5:
		_fail += 1; print("    !! NO-SIGNAL — the control's detail is flat")


# --- BC. below z_cut_min nothing changes --------------------------------------------------------------
func _bc_below_the_cut_is_untouched() -> void:
	print("[BC] cells below z_cut_min * amplitude are not eroded")
	var cone := _cone()
	var n := _gav()
	n.z_cut_min = 0.5
	n.z_cut_max = 0.8
	var got := _wired(n).evaluate(GW, GH, RECT, null, cone)
	var worst := 0.0
	var count := 0
	for i in cone.size():
		if cone[i] < 0.5 * n.amplitude:
			worst = maxf(worst, absf(got[i] - cone[i]))
			count += 1
	print("    %d low cells, max change %.9f m (want 0)" % [count, worst])
	if worst > 0.0 or count == 0:
		_fail += 1; print("    !! erosion leaked below the cut")
	# CONTROL: with the cut at 0 those cells must change.
	n.z_cut_min = 0.0
	got = _wired(n).evaluate(GW, GH, RECT, null, cone)
	var moved := 0.0
	for i in cone.size():
		if cone[i] < 0.5 * n.amplitude and cone[i] > 10.0:
			moved = maxf(moved, absf(got[i] - cone[i]))
	print("    control: with z_cut_min 0 they move by %.3f m (want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1; print("    !! control dead — the low cells are never eroded anyway")


# --- BD. parity + the native route -------------------------------------------------------------------
func _bd_parity_and_route() -> void:
	print("[BD] kernel == oracle on the base form, and the graph takes the native route to it")
	var rect := RECT
	var cone := _cone_at(ORACLE_N)
	for cfg in [[0.0, 2.0, 8], [30.0, 0.5, 3], [0.0, 0.0, 1]]: # branch 0: parallel gullies, still eroding
		var n := _gav()
		n.base_smoothing = cfg[0]
		n.branch_strength = cfg[1]
		n.octaves = cfg[2]
		var kp: Dictionary = n.kernel_params(n.amplitude, n.angle_deg, n.frequency)
		var direct: PackedFloat32Array = Pasture3DUtil.gavoronoise_base_grid(ORACLE_N, ORACLE_N, rect, kp, cone,
				n.base_smoothing)
		var dev := Pasture3DGraphNodeDevGavoronoise.new()
		for k in kp:
			dev.set(k, kp[k])
		dev.base_smoothing = n.base_smoothing
		var oracle := dev.solve_base(ORACLE_N, ORACLE_N, rect, cone)
		var d := _max_abs_diff(direct, oracle)
		print("    smoothing %.0f branch %.1f oct %d  kernel vs oracle %.9f (want < %s)"
				% [cfg[0], cfg[1], cfg[2], d, str(PARITY_EPS)])
		if d > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree")
		if _max_abs_diff(direct, cone) <= 0.5:
			_fail += 1; print("      !! NO-SIGNAL — the kernel returned the input, parity compared nothing")
	# The route, with the program's float32 params given to the direct call.
	var n2 := _gav()
	n2.base_smoothing = 30.0
	var g := _wired(n2)
	if not g.native_supported():
		_fail += 1; print("    !! native_supported() = FALSE — the WHOLE graph drops to the GDScript evaluator")
		return
	var kp2: Dictionary = n2.kernel_params(n2.amplitude, n2.angle_deg, n2.frequency)
	for k in kp2:
		if kp2[k] is float:
			kp2[k] = _f32(kp2[k])
	var big := _cone()
	var dr := _max_abs_diff(g.evaluate(GW, GH, RECT, null, big),
			Pasture3DUtil.gavoronoise_base_grid(GW, GH, RECT, kp2, big, _f32(n2.base_smoothing)))
	print("    graph route vs kernel with float32 params: %.9f (want 0)" % dr)
	if dr > 0.0:
		_fail += 1; print("    !! the graph route does not reach the base kernel with the node's parameters")


# --- BE. GPU route -----------------------------------------------------------------------------------
func _be_gpu() -> void:
	print("[BE] the base form takes the GPU path and agrees with the CPU")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var cone := _cone()
	for cfg in [[0.0, 8], [30.0, 3], [-1.0, 8]]:
		var n := _gav()
		n.base_smoothing = maxf(cfg[0], 0.0)
		n.octaves = cfg[1]
		if cfg[0] < 0.0:
			n.erosion_strength = 0.0 # the COPY early-out
		var g := _wired(n)
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
			print("    !! the GPU bailed here but not on a bare in->out graph; the bail is graph-wide.")
			continue
		var cpu := g.evaluate(GW, GH, RECT, null, cone)
		var d := _max_abs_diff(gpu, cpu)
		print("    smoothing %.0f oct %d strength %.2f  max |gpu - cpu| = %.6f m (want < %s)"
				% [n.base_smoothing, n.octaves, n.erosion_strength, d, str(GPU_TOL)])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel")


# --- helpers -----------------------------------------------------------------------------------------
## Gullies every ~20 m on a 5 m grid: frequency 1/80 cycles/m, four erosion cells per base cell.
func _gav() -> Pasture3DGraphNodeGavoronoise:
	var n := Pasture3DGraphNodeGavoronoise.new()
	n.amplitude = 200.0
	n.frequency = 1.0 / 80.0
	n.octaves = 4
	n.seed = 7
	n.z_cut_min = 0.0
	n.z_cut_max = 1.0
	n.erosion_strength = 0.1
	return n


func _standalone(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_node, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	return g


## Input -> Gavoronoise.base (port 3) -> Output.
func _wired(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_node, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 3]), PackedInt32Array([1, 0, 2, 0])]
	return g


func _cone() -> PackedFloat32Array:
	return _cone_at(GW)


func _cone_at(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			a[iz * p_n + ix] = maxf(0.0, 1.0 - w.length() / 230.0) * 200.0
	return a


## Over a 60-degree wedge around `p_axis`, 60-200 m from the peak: the ratio of summed squared gradient
## ACROSS the axis to summed squared gradient ALONG it. High means the field varies across the downhill,
## i.e. its crests run down it.
func _sector_anisotropy(p_g: PackedFloat32Array, p_axis: Vector2) -> float:
	var across := Vector2(-p_axis.y, p_axis.x)
	var s_across := 0.0
	var s_along := 0.0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var r := w.length()
			if r < 60.0 or r > 200.0 or w.normalized().dot(p_axis) < cos(deg_to_rad(30.0)):
				continue
			var gr := Vector2(p_g[iz * GW + ix + 1] - p_g[iz * GW + ix - 1], p_g[(iz + 1) * GW + ix] - p_g[(iz - 1) * GW + ix])
			s_across += pow(gr.dot(across), 2.0)
			s_along += pow(gr.dot(p_axis), 2.0)
	return s_across / maxf(s_along, 1.0e-9)


func _sub(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var out := p_a.duplicate()
	for i in out.size():
		out[i] -= p_b[i]
	return out


func _f32(p_v: float) -> float:
	return PackedFloat32Array([p_v])[0]


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_g:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _max_abs_diff_finite(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in p_a.size():
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


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
