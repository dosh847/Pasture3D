# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGradientGate — the Gradient node (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §4.8).
#
#   A  Oracle ([Dev/GD] eval) vs native, 7 shapes x 3 repeats x 6 profiles (MASK and HEIGHT alternating), plus
#      warped cases, within 1e-5 of the output span. Control: the oracle with invert toggled. SPHERICAL rim
#      cells (0 < un-profiled dome < 0.02) take a slope bound instead: sqrt(1 - u^2) is unbounded in slope
#      there and the oracle's Vector2 is float32.
#   B  Native vs GPU through graph_eval_grid_gpu DIRECTLY, same sweep, within 1e-4. Control: end +1 m on the GPU.
#   C  Metric invariance: 1 m and 4 m bakes agree at shared world points. Control: a copy whose L scales with
#      the cell size.
#   D  SPHERICAL is sqrt(0.75) at d = L/2 and 0 for d >= L. Control: RADIAL at L/2.
#   E  Swapping start / end on LINEAR + CLAMP gives 1 - t.
#   F  Gradient -> Blend folds (not materialised). Control: a needs_grid() = true copy materialises.
#   G  A Const driving end_x moves the native result. Control: a Const equal to the property does not.
#   H  Host follows the brush: a HOST gradient on a Mound moved +200 m X and yawed 90 deg bakes the same field,
#      moved and rotated, read from the TERRAIN. Control: the WORLD-space fixture must not follow.
#   I  Moving the host bumps the graph revision once; an unchanged resolve does not.
#   J  A 2x-scaled host does not change the metre length. Control: a copy applying the full basis differs.
#   K  Every criterion that was not skipped completed.
#
# Wraps: a REPEAT seam and ANGULAR's ray are true discontinuities where a float's last ulp decides the side,
# so those shapes compare wrap-aware (an error of one full output span is a seam, not a disagreement).
#
# WINDOWED for B. Headless, B is SKIPPED and the verdict is PARTIAL, never PASS.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphGradientGate.tscn
extends Node

const GW := 64
const GH := 48
const RECT := Rect2(-300.0, -250.0, 720.0, 600.0)
const EPS_A := 1.0e-5
const EPS_B := 1.0e-4
const RIM := 0.02 # un-profiled SPHERICAL dome value below which a cell is on the rim (u > 0.9998)
const DU := 2.0e-7 # the oracle's float32 error in u = d / L at this fixture's few hundred metres
const RIM_GAIN := 3.0 # steepest profile slope in the sweep: EXPONENTIAL at hardness 2.7
const CRITERIA := ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
const DEMO_DATA := "res://demo/data"
const SITE := Vector3(200.0, 0.0, 160.0)
const HALF := 50.0

var _fail := 0
var _seen := {}
var _skipped := {}
var _gpu_ok := false


func _ready() -> void:
	print("=== GraphGradientGate: Gradient node (spec §4.8) ===")
	if not Pasture3DUtil.graph_op_ids().has(&"gradient"):
		print("!! gradient is not in graph_op_ids() — rebuild the GDExtension")
		get_tree().quit(1)
		return
	_gpu_ok = not Pasture3DUtil.graph_eval_grid_gpu(_graph(_node({})).compile_graph_program(), GW, GH, RECT,
			_zeros(GW * GH)).is_empty()
	_run("A", _a_oracle)
	if _gpu_ok:
		_run("B", _b_gpu)
	else:
		print("    NO-SIGNAL: the GPU refused (no RenderingDevice). B SKIPPED.")
		_skipped["B"] = true
	_run("C", _c_invariance)
	_run("D", _d_spherical)
	_run("E", _e_swap)
	_run("F", _f_fold)
	_run("G", _g_driven)
	_run("H", _h_host_follows)
	_run("I", _i_invalidation)
	_run("J", _j_scale)

	var required := CRITERIA.size() - _skipped.size()
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
		elif not _skipped.has(name):
			print("!! criterion %s never reported" % name)
	_check("K", completed == required, "%d of %d non-skipped criteria completed" % [completed, required])
	var verdict := "FAIL" if _fail > 0 else ("PARTIAL" if not _skipped.is_empty() else "PASS")
	print("=== GRADIENT %s (%d failures, %d skipped) ===" % [verdict, _fail, _skipped.size()])
	get_tree().quit(0 if _fail == 0 else 1)


func _run(p_name: String, p_fn: Callable) -> void:
	p_fn.call()
	if not _seen.has(p_name) and not _skipped.has(p_name):
		print("!! [%s] returned without reporting" % p_name)


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
func _zeros(p_n: int) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(p_n)
	return z


func _curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.3, 0.65))
	c.add_point(Vector2(1.0, 1.0))
	return c


## A WORLD-space gradient with `p_cfg` applied over the defaults below.
func _node(p_cfg: Dictionary, p_dev := false) -> Pasture3DGraphNodeGradient:
	var n: Pasture3DGraphNodeGradient = Pasture3DGraphNodeDevGradient.new() if p_dev else Pasture3DGraphNodeGradient.new()
	n.space = Pasture3DGraphNodeGradient.Space.WORLD
	# Off the cell lattice's rational ray: (-40, 30) put cell (39, 16) exactly on ANGULAR's seam, where the
	# sign of a zero decides the side, and under MIRROR + warp a seam error is 1 - 2 delta, not a full span.
	n.start = Vector2(-40.3, 30.7)
	n.end = Vector2(260.0, -90.0)
	n.hardness = 2.7
	n.height_min = -15.0
	n.height_max = 85.0
	n.curve = _curve()
	for k in p_cfg:
		n.set(k, p_cfg[k])
	return n


func _copy(p_n: Pasture3DGraphNodeGradient, p_dev: bool) -> Pasture3DGraphNodeGradient:
	var c := _node({}, p_dev)
	for k in ["shape", "space", "start", "end", "profile", "hardness", "curve", "repeat", "invert",
			"output_mode", "height_min", "height_max", "distance_noise"]:
		c.set(k, p_n.get(k))
	c.host_xform = p_n.host_xform
	return c


func _warp_noise() -> Pasture3DGraphNodeNoise:
	var fnl := FastNoiseLite.new()
	fnl.seed = 4242
	fnl.frequency = 0.01
	var nn := Pasture3DGraphNodeNoise.new()
	nn.noise = fnl
	nn.amplitude = 1.0
	return nn


## Gradient -> Output; optionally a Noise on warp and a Const on `p_port`.
func _graph(p_n: Pasture3DGraphNode, p_warp := false, p_port := -1, p_value := 0.0) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_n, Pasture3DGraphNodeOutput.new()]
	var conns := [[0, 0, 1, 0]]
	if p_warp:
		nodes.append(_warp_noise())
		conns.append([nodes.size() - 1, 0, 0, 0])
	if p_port >= 0:
		var k := Pasture3DGraphNodeConst.new()
		k.value = p_value
		nodes.append(k)
		conns.append([nodes.size() - 1, 0, 0, p_port])
	g.nodes = nodes
	g.connections = conns
	return g


func _native(p_g: Pasture3DTerrainGraph, p_gw := GW, p_gh := GH, p_rect := RECT) -> PackedFloat32Array:
	var prog = p_g.compile_graph_program()
	return Pasture3DUtil.graph_eval_grid(prog, p_gw, p_gh, p_rect, _zeros(p_gw * p_gh))


func _gpu(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_g.compile_graph_program(), GW, GH, RECT, _zeros(GW * GH))


func _warp_grid() -> PackedFloat32Array:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [_warp_noise(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return _native(g)


func _oracle(p_n: Pasture3DGraphNodeGradient, p_warp: PackedFloat32Array, p_invert_flip := false) -> PackedFloat32Array:
	var o := _copy(p_n, true)
	if p_invert_flip:
		o.invert = not o.invert
	var lut := o.curve_lut()
	var out := _zeros(GW * GH)
	var inputs := PackedFloat32Array([NAN, NAN, NAN, NAN, NAN, NAN, NAN])
	var dx := RECT.size.x / GW
	var dz := RECT.size.y / GH
	for iz in GH:
		var wz := RECT.position.y + (iz + 0.5) * dz
		for ix in GW:
			var i := iz * GW + ix
			inputs[0] = p_warp[i] if p_warp.size() == GW * GH else NAN
			out[i] = o.evaluate_at(RECT.position.x + (ix + 0.5) * dx, wz, inputs, lut)
	return out


func _span(p_n: Pasture3DGraphNodeGradient) -> float:
	return absf(p_n.height_max - p_n.height_min) if p_n.output_mode == Pasture3DGraphNodeGradient.OutputMode.HEIGHT else 1.0


func _wraps(p_n: Pasture3DGraphNodeGradient) -> bool:
	return p_n.repeat == Pasture3DGraphNodeGradient.Repeat.REPEAT or p_n.shape == Pasture3DGraphNodeGradient.Shape.ANGULAR


## Worst |a - b|; INF on a size or NaN-pattern mismatch. Wrap-aware subtracts one full span at a seam.
func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array, p_span := 1.0, p_wrap := false) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		if is_nan(p_a[i]) or is_nan(p_b[i]):
			if is_nan(p_a[i]) != is_nan(p_b[i]):
				return INF
			continue
		var e := absf(p_a[i] - p_b[i])
		if p_wrap:
			e = minf(e, absf(e - p_span))
		w = maxf(w, e)
	return w


func _sweep() -> Array:
	var cases := []
	var k := 0
	for sh in 7:
		for rp in 3:
			for pf in 6:
				cases.append({"shape": sh, "repeat": rp, "profile": pf, "output_mode": k % 2})
				k += 1
	return cases


# --- A. oracle vs native -----------------------------------------------------------------------------
func _a_oracle() -> void:
	print("[A] oracle == native within %s x span, 126 cases + warp" % str(EPS_A))
	var warp := _warp_grid()
	var cases := _sweep()
	cases.append({"shape": Pasture3DGraphNodeGradient.Shape.RADIAL, "distance_noise": 25.0, "warp": true})
	cases.append({"shape": Pasture3DGraphNodeGradient.Shape.ANGULAR, "distance_noise": 25.0, "warp": true, "repeat": Pasture3DGraphNodeGradient.Repeat.MIRROR})
	var passed := 0
	var worst := 0.0
	var ctl := INF
	var rim_cells := 0
	for ci in cases.size():
		var cfg: Dictionary = cases[ci].duplicate()
		var warped := bool(cfg.get("warp", false))
		cfg.erase("warp")
		var n := _node(cfg)
		var nat := _native(_graph(n, warped))
		var ora := _oracle(n, warp if warped else PackedFloat32Array())
		var span := _span(n)
		var w := _worst(nat, ora, span, _wraps(n)) / span
		var ok := w <= EPS_A
		if not ok and n.shape == Pasture3DGraphNodeGradient.Shape.SPHERICAL:
			# The dome's rim: d(sqrt(1 - u^2))/du is unbounded as u -> 1, and the oracle's Vector2 is float32,
			# so ~DU of u error becomes up to sqrt(2 DU) there. Rim cells (un-profiled dome < RIM) take that
			# bound times the steepest profile gain; every other cell keeps EPS_A.
			var plain := _copy(n, true)
			plain.profile = Pasture3DGraphNodeGradient.Profile.LINEAR
			plain.invert = false
			plain.output_mode = Pasture3DGraphNodeGradient.OutputMode.MASK
			var dome := _oracle(plain, warp if warped else PackedFloat32Array())
			var rim := 0
			w = 0.0
			ok = true
			for i in nat.size():
				var raw := absf(nat[i] - ora[i])
				if _wraps(n):
					raw = minf(raw, absf(raw - span))
				var e := raw / span
				if dome[i] > 0.0 and dome[i] < RIM: # past L the dome is exactly 0 and keeps EPS_A
					rim += 1
					ok = ok and e <= EPS_A + RIM_GAIN * sqrt(2.0 * DU)
				else:
					ok = ok and e <= EPS_A
					w = maxf(w, e)
			if ok:
				rim_cells += rim
		worst = maxf(worst, w)
		if ok:
			passed += 1
		else:
			print("    !! %s: worst |native - oracle| / span %s" % [str(cases[ci]), str(w)])
		if ci % 7 == 0:
			ctl = minf(ctl, _worst(nat, _oracle(n, warp if warped else PackedFloat32Array(), true), span, _wraps(n)) / span)
	_check("A", passed == cases.size(), "%d of %d cases; worst error/span %s off the rim; %d SPHERICAL rim cells on the slope bound"
			% [passed, cases.size(), str(worst), rim_cells])
	_control(ctl > 1.0e-2, "oracle with invert toggled: smallest worst error/span %s (want > 1e-2)" % str(ctl))


# --- B. native vs GPU --------------------------------------------------------------------------------
func _b_gpu() -> void:
	print("[B] native == GPU (direct) within %s x span" % str(EPS_B))
	var cases := _sweep()
	cases.append({"shape": Pasture3DGraphNodeGradient.Shape.DIAMOND, "distance_noise": 25.0, "warp": true})
	var passed := 0
	var worst := 0.0
	var ctl := INF
	var served := 0
	for c in cases:
		var cfg: Dictionary = c.duplicate()
		var warped := bool(cfg.get("warp", false))
		cfg.erase("warp")
		var n := _node(cfg)
		var g := _graph(n, warped)
		var nat := _native(g)
		var gpu := _gpu(g)
		if gpu.size() == GW * GH:
			served += 1
		var span := _span(n)
		var w := _worst(gpu, nat, span, _wraps(n)) / span
		worst = maxf(worst, w)
		if w <= EPS_B:
			passed += 1
		else:
			print("    !! %s: worst |GPU - native| / span %s" % [str(c), str(w)])
		var moved := _copy(n, false)
		moved.end = n.end + Vector2(1.0, 0.0)
		ctl = minf(ctl, _worst(_gpu(_graph(moved, warped)), nat, span, _wraps(n)) / span)
	_check("B", passed == cases.size() and served == cases.size(),
			"%d of %d cases, %d served by the GPU; worst error/span %s" % [passed, cases.size(), served, str(worst)])
	_control(ctl > EPS_B, "end +1 m on the GPU: smallest worst error/span %s (want > %s)" % [str(ctl), str(EPS_B)])


# --- C. metric invariance ----------------------------------------------------------------------------
func _c_invariance() -> void:
	print("[C] 1 m and 4 m bakes agree at shared world points")
	const W4 := 60
	const H4 := 50
	var r1 := Rect2(-100.0, -80.0, W4 * 4.0, H4 * 4.0)
	var r4 := Rect2(-101.5, -81.5, W4 * 4.0, H4 * 4.0)
	var worst := 0.0
	var ctl := INF
	for sh in 7:
		var n := _node({"shape": sh, "start": Vector2(10.0, 15.0), "end": Vector2(90.0, -20.0)})
		var a := _native(_graph(n), W4 * 4, H4 * 4, r1)
		var b := _native(_graph(n), W4, H4, r4)
		# The control: a copy whose L is multiplied by the cell size, as a kernel measuring in cells would be.
		var scaled := _copy(n, false)
		scaled.end = n.start + (n.end - n.start) * 4.0
		var bc := _native(_graph(scaled), W4, H4, r4)
		var sub := _zeros(W4 * H4)
		for iz in H4:
			for ix in W4:
				sub[iz * W4 + ix] = a[(iz * 4) * (W4 * 4) + ix * 4]
		worst = maxf(worst, _worst(sub, b, 1.0, _wraps(n)))
		if sh != Pasture3DGraphNodeGradient.Shape.ANGULAR: # ANGULAR has no length to scale
			ctl = minf(ctl, _worst(sub, bc, 1.0, _wraps(n)))
	_check("C", worst <= EPS_B, "worst |1 m - 4 m| at shared points %s" % str(worst))
	_control(ctl > EPS_B, "L scaled by cell size: smallest worst %s (want > %s)" % [str(ctl), str(EPS_B)])


# --- D. spherical ------------------------------------------------------------------------------------
func _at(p_n: Pasture3DGraphNodeGradient, p_x: float, p_z: float) -> float:
	var r := _native(_graph(p_n), 1, 1, Rect2(p_x - 0.5, p_z - 0.5, 1.0, 1.0))
	return r[0] if r.size() == 1 else NAN


func _d_spherical() -> void:
	print("[D] SPHERICAL: sqrt(0.75) at L/2, 0 at and past L")
	var cfg := {"shape": Pasture3DGraphNodeGradient.Shape.SPHERICAL, "start": Vector2(10.0, 20.0), "end": Vector2(110.0, 20.0)}
	var n := _node(cfg)
	var half := _at(n, 60.0, 20.0)
	var at_l := _at(n, 110.0, 20.0)
	var past := _at(n, 160.0, 20.0)
	_check("D", absf(half - sqrt(0.75)) <= EPS_A and absf(at_l) <= EPS_A and absf(past) <= EPS_A,
			"L/2 %s (want %s), L %s, 1.5 L %s" % [str(half), str(sqrt(0.75)), str(at_l), str(past)])
	cfg["shape"] = Pasture3DGraphNodeGradient.Shape.RADIAL
	var radial := _at(_node(cfg), 60.0, 20.0)
	_control(absf(radial - sqrt(0.75)) > EPS_A, "RADIAL at L/2 reads %s" % str(radial))


# --- E. swap -----------------------------------------------------------------------------------------
func _e_swap() -> void:
	print("[E] LINEAR + CLAMP with start / end swapped is 1 - t")
	var n := _node({"shape": Pasture3DGraphNodeGradient.Shape.LINEAR})
	var s := _node({"shape": Pasture3DGraphNodeGradient.Shape.LINEAR, "start": n.end, "end": n.start})
	var a := _native(_graph(n))
	var b := _native(_graph(s))
	var inv := _zeros(a.size())
	for i in a.size():
		inv[i] = 1.0 - a[i]
	var w := _worst(b, inv)
	var ctl := _worst(b, a)
	_check("E", w <= EPS_A, "worst |swapped - (1 - t)| %s" % str(w))
	_control(ctl > 0.1, "swapped vs unswapped differ by %s" % str(ctl))


# --- F. fold ----------------------------------------------------------------------------------------
func _fold_graph(p_n: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_n, blend, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
	return g


func _f_fold() -> void:
	print("[F] Gradient -> Blend folds into one cell program")
	var plan: Dictionary = _fold_graph(_node({}))._fold_plan()
	var folded := not bool(plan["materialize"][1])
	_check("F", folded, "gradient materialize = %s (want false)" % str(plan["materialize"][1]))
	var s := GDScript.new()
	s.source_code = "extends Pasture3DGraphNodeGradient\nfunc needs_grid() -> bool:\n\treturn true\n"
	s.reload()
	var forced: Pasture3DGraphNode = s.new()
	var plan2: Dictionary = _fold_graph(forced)._fold_plan()
	_control(bool(plan2["materialize"][1]), "needs_grid() = true copy materialize = %s" % str(plan2["materialize"][1]))


# --- Pasture3DGraphNodeGradient. driven ---------------------------------------------------------------------------------------
func _g_driven() -> void:
	print("[G] a Const driving end_x moves native")
	var n := _node({"shape": Pasture3DGraphNodeGradient.Shape.LINEAR})
	var base := _native(_graph(n))
	var driven := _native(_graph(n, false, 3, 400.0))
	var same := _native(_graph(n, false, 3, n.end.x))
	var w := _worst(base, driven)
	_check("G", w > 1.0e-3 and driven.size() == GW * GH, "end_x 400 vs 260 moves the result by %s" % str(w))
	_control(_worst(base, same) <= EPS_A, "a Const equal to end.x moves it by %s" % str(_worst(base, same)))


# --- H. host follows the brush, read from the terrain ------------------------------------------------
func _h_host_follows() -> void:
	print("[H] a HOST gradient follows a moved and yawed brush, read from the terrain")
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var vs: float = terrain.vertex_spacing
	var site2 := SITE + Vector3(200.0, 0.0, 0.0)
	if not is_finite(terrain.data.get_height(SITE)) or not is_finite(terrain.data.get_height(site2)):
		print("    !! no terrain at the fixture sites")
		root.queue_free()
		return
	var mound := Pasture3DMound.new()
	mound.name = "GradientHost"
	root.add_child(mound)
	mound.terrain = terrain
	mound.height = 20.0
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-HALF, 0, -HALF), Vector3(HALF, 0, -HALF), Vector3(HALF, 0, HALF), Vector3(-HALF, 0, HALF)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	mound.add_child(path)

	var offsets: Array[Vector2] = []
	var reach := HALF - vs * 6.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			offsets.append(Vector2(snappedf(x, vs), snappedf(z, vs)))
			z += vs * 4.0
		x += vs * 4.0

	var host := _node({"space": Pasture3DGraphNodeGradient.Space.HOST, "shape": Pasture3DGraphNodeGradient.Shape.LINEAR, "start": Vector2(-40.0, -10.0),
			"end": Vector2(40.0, 10.0), "output_mode": Pasture3DGraphNodeGradient.OutputMode.HEIGHT, "height_min": 0.0, "height_max": 8.0})
	var world := _node({"space": Pasture3DGraphNodeGradient.Space.WORLD, "shape": Pasture3DGraphNodeGradient.Shape.LINEAR, "start": Vector2(SITE.x - 40.0, SITE.z - 10.0),
			"end": Vector2(SITE.x + 40.0, SITE.z + 10.0), "output_mode": Pasture3DGraphNodeGradient.OutputMode.HEIGHT, "height_min": 0.0,
			"height_max": 8.0})
	var d_host := _h_delta_pair(mound, host, offsets, site2)
	var d_world := _h_delta_pair(mound, world, offsets, site2)
	root.queue_free()
	if d_host.is_empty() or d_world.is_empty():
		_check("H", false, "a bake read no terrain")
		return
	_check("H", d_host[0] <= EPS_B and d_host[1] > 1.0,
			"HOST: worst |moved - original| at mapped points %s m over %d probes; field relief %s m" % [str(d_host[0]), offsets.size(), str(d_host[1])])
	_control(d_world[0] > 0.1, "WORLD: worst |moved - original| %s m (want > 0.1)" % str(d_world[0]))


## [worst difference of the gradient's contribution between the two placements at mapped points, relief].
func _h_delta_pair(p_mound: Pasture3DMound, p_n: Pasture3DGraphNodeGradient, p_offsets: Array[Vector2], p_site2: Vector3) -> Array:
	var g := _fold_graph(p_n)
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	mod.evaluation = Pasture3DNode.Evaluation.LIVE
	var none: Array[Pasture3DNode] = []
	var with: Array[Pasture3DNode] = [mod]
	var fields := []
	for placement in [[SITE, 0.0], [p_site2, PI * 0.5]]:
		p_mound.global_position = placement[0]
		p_mound.rotation = Vector3(0.0, placement[1], 0.0)
		var yaw: float = placement[1]
		var pts: Array[Vector3] = []
		for o in p_offsets:
			# local (x, z) -> world, the Y rotation's own mapping: +X to (cos, -sin), +Z to (sin, cos)
			pts.append(Vector3(placement[0].x + cos(yaw) * o.x + sin(yaw) * o.y, 0.0,
					placement[0].z - sin(yaw) * o.x + cos(yaw) * o.y))
		p_mound.modifiers = none
		var bare := _bake(p_mound, pts)
		p_mound.modifiers = with
		var baked := _bake(p_mound, pts)
		var f := []
		for i in pts.size():
			if not is_finite(bare[i]) or not is_finite(baked[i]):
				return []
			f.append(baked[i] - bare[i])
		fields.append(f)
	var worst := 0.0
	var lo := INF
	var hi := -INF
	for i in p_offsets.size():
		worst = maxf(worst, absf(float(fields[0][i]) - float(fields[1][i])))
		lo = minf(lo, float(fields[0][i]))
		hi = maxf(hi, float(fields[0][i]))
	return [worst, hi - lo]


func _bake(p_mound: Pasture3DMound, p_pts: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_pts:
		out.append(p_mound.terrain.data.get_height(p))
	return out


# --- I. invalidation ---------------------------------------------------------------------------------
func _i_invalidation() -> void:
	print("[I] moving the host bumps the revision once; an unchanged resolve does not")
	var n := _node({"space": Pasture3DGraphNodeGradient.Space.HOST})
	var g := _graph(n)
	var host := Node3D.new()
	host.position = Vector3(50.0, 0.0, 20.0)
	Pasture3DGraphSources.resolve(g, host)
	var k0 := g.content_key()
	host.position.x += 200.0
	Pasture3DGraphSources.resolve(g, host)
	var k1 := g.content_key()
	Pasture3DGraphSources.resolve(g, host)
	var k2 := g.content_key()
	host.position.x += 5.0e-5
	Pasture3DGraphSources.resolve(g, host)
	var k3 := g.content_key()
	host.free()
	_check("I", k1 - k0 == 1 and k2 == k1 and k3 == k2,
			"move +200 m bumped %d (want 1); unchanged resolve bumped %d; a 5e-5 m move bumped %d (want 0, 0)" % [k1 - k0, k2 - k1, k3 - k2])


# --- J. host scale -----------------------------------------------------------------------------------
func _j_scale() -> void:
	print("[J] a 2x-scaled host does not stretch a HOST gradient")
	var cfg := {"space": Pasture3DGraphNodeGradient.Space.HOST, "shape": Pasture3DGraphNodeGradient.Shape.RADIAL, "start": Vector2(5.0, -12.0), "end": Vector2(120.0, 30.0)}
	var plain := _node(cfg)
	var scaled := _node(cfg)
	var h1 := Node3D.new()
	h1.position = Vector3(30.0, 0.0, -40.0)
	h1.rotation.y = 0.6
	var h2 := Node3D.new()
	h2.position = h1.position
	h2.rotation.y = 0.6
	h2.scale = Vector3(2.0, 2.0, 2.0)
	var ga := _graph(plain)
	var gb := _graph(scaled)
	Pasture3DGraphSources.resolve(ga, h1)
	Pasture3DGraphSources.resolve(gb, h2)
	var a := _native(ga)
	var b := _native(gb)
	# The control: a copy that applies the full basis, i.e. start and end scaled by 2 about the host.
	var full := _copy(scaled, false)
	full.start = scaled.start * 2.0
	full.end = scaled.end * 2.0
	var c := _native(_graph(full))
	h1.free()
	h2.free()
	var w := _worst(a, b)
	_check("J", w <= EPS_A and a.size() == GW * GH, "scaled vs unscaled host worst %s" % str(w))
	_control(_worst(a, c) > 1.0e-2, "full-basis copy differs by %s" % str(_worst(a, c)))
