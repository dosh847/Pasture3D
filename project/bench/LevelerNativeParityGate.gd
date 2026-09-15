# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerNativeParityGate — the C++ Leveler against its [Dev/GD] oracle (PASTURE3D_GRAPH_LEVELER_SPEC.md §7,
# criteria P, T, R).
#
#   P  the Pasture3DUtil binding (tier 2) matches the oracle on every route and a spread of configs.
#   T  the kernel is bit-identical at one thread and at N, on a grid large enough that N actually splits —
#      proved by parallel_dispatch_count, because a small grid runs serial and serial-vs-serial passes having
#      measured nothing.
#   R  the LOWERED graph program (tier 3, GRAPH_OP_LEVELER) matches the oracle on every channel, with the
#      target and the mask arriving by wire. Compared against the oracle, never against evaluate(): that
#      takes the native route and would compare the kernel with itself.
#
# The GPU criterion belongs to step 4 of the spec; there is no shader yet.
#
# Headless is fine:
#   Godot_v4.7-stable_win64_console.exe --headless --path project bench/LevelerNativeParityGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const HALF := 20.0
## Oracle vs kernel. The oracle queries the path through float32 Vector2s and runs its JFA in double; the
## kernel queries in double and its JFA writes float32. Well above both, well below any rule difference.
const EPS := 2.0e-4
const BIG := 512
const CRITERIA := 3

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== LevelerNativeParityGate: native Leveler vs [Dev/GD] oracle (spec §7, P T R) ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "leveler_grid"):
		print("!! Pasture3DUtil.leveler_grid is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	_p_binding_parity()
	_t_thread_identity()
	_r_lowered_route()
	if _ran != CRITERIA:
		_fail += 1
		print("\n!! only %d of %d criteria completed" % [_ran, CRITERIA])
	print("\n=== %s (%d failures, %d/%d criteria ran) ===\n" % [
		"LEVELER NATIVE PASS" if _fail == 0 else "LEVELER NATIVE FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(0 if _fail == 0 else 1)


# --- fixtures ---------------------------------------------------------------------------------------

func _sloped(p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_gw * p_gh)
	var dx := p_rect.size.x / p_gw
	var dz := p_rect.size.y / p_gh
	for iz in p_gh:
		for ix in p_gw:
			var x := p_rect.position.x + (ix + 0.5) * dx
			var z := p_rect.position.y + (iz + 0.5) * dz
			h[iz * p_gw + ix] = 10.0 + 0.2 * x + 0.1 * z + 6.0 * exp(-(pow(x - 8.0, 2.0) + pow(z + 6.0, 2.0)) / 60.0) \
					+ 0.8 * sin(x * 0.37) * cos(z * 0.23)
	return h


func _square(p_half: float, p_widths := PackedFloat32Array()) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(-p_half, -p_half), Vector2(p_half, -p_half), Vector2(p_half, p_half),
			Vector2(-p_half * 0.6, p_half), Vector2(-p_half, p_half * 0.3)])
	p.half_widths = p_widths
	p.closed = true
	return p


## A radial mask: 1 inside r = 14, falling to 0 at r = 24. Shapes the area, so it forces the JFA route.
func _soft_mask(p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_gw * p_gh)
	var dx := p_rect.size.x / p_gw
	var dz := p_rect.size.y / p_gh
	for iz in p_gh:
		for ix in p_gw:
			var x := p_rect.position.x + (ix + 0.5) * dx
			var z := p_rect.position.y + (iz + 0.5) * dz
			m[iz * p_gw + ix] = clampf((24.0 - sqrt(x * x + z * z)) / 10.0, 0.0, 1.0)
	return m


func _falloff_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(0.3, 0.9))
	c.add_point(Vector2(0.7, 0.2))
	c.add_point(Vector2(1.0, 0.0))
	return c


## Outward unless the config says otherwise, so the original cases keep measuring what they were written for.
func _apply(p_node: Pasture3DGraphNode, p_cfg: Dictionary) -> void:
	p_node.set("feather_side", Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE)
	for k in p_cfg:
		p_node.set(String(k), p_cfg[k])


func _channels(p_node: Pasture3DGraphNodeLevelerBase, p_h: PackedFloat32Array, p_path, p_mask,
		p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	p_node.set_path_inputs([null, p_path, null, null])
	var mask: PackedFloat32Array = p_mask if p_mask != null else Pasture3DGraphOps.filled(n, 1.0)
	return p_node.eval_grid_channels([p_h, Pasture3DGraphOps.zeros(n), mask,
			Pasture3DGraphOps.filled(n, p_node.input_unwired_default(3))], p_gw, p_gh, null, p_rect)


## NaN-aware worst difference. NaN on exactly one side is a rule difference, not a rounding one.
func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		var an := is_nan(p_a[i])
		var bn := is_nan(p_b[i])
		if an and bn:
			continue
		if an != bn:
			return INF
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _worst_channels(p_a: Array, p_b: Array) -> float:
	var w := 0.0
	for c in 5:
		w = maxf(w, _worst(p_a[c], p_b[c]))
	return w


# --- P. the binding matches the oracle --------------------------------------------------------------
func _p_binding_parity() -> void:
	print("[P] Pasture3DUtil.leveler_grid matches the oracle on every route and config")
	var h := _sloped(GW, GH, RECT)
	var widths := PackedFloat32Array([2.0, 2.0, 12.0, 12.0, 6.0])
	var soft := _soft_mask(GW, GH, RECT)
	var nan_h := h.duplicate()
	for i in nan_h.size():
		if i % GW > 44:
			nan_h[i] = NAN
	var open := _square(HALF, widths)
	open.closed = false
	var routes := [
		["loop (exact)", h, _square(HALF, widths), null],
		["mask (JFA)", h, null, soft],
		["loop+mask (JFA)", h, _square(HALF, widths), soft],
		["none (whole grid)", h, null, null],
		["NaN footprint", nan_h, _square(HALF, widths), null],
		["open loop (ignored)", h, open, soft],
		["empty core", h, null, Pasture3DGraphOps.filled(GW * GH, 0.5)],
	]
	var cfgs := [
		{"mode": 0, "statistic": 0},
		{"mode": 0, "statistic": 1},
		{"mode": 0, "statistic": 2},
		{"mode": 0, "statistic": 3},
		{"mode": 0, "statistic": 1, "median_bins": 64},
		{"mode": 1, "target_height": 22.5},
		{"mode": 1, "target_height": 22.5, "cut_fill": 1},
		{"mode": 0, "statistic": 0, "cut_fill": 2},
		{"mode": 1, "target_height": 22.5, "walls_shape": 1, "wall_depth": 3.0},
		{"mode": 1, "target_height": 22.5, "feather_from_path_width": true, "path_width_scale": 1.5},
		{"mode": 1, "target_height": 22.5, "feather": 0.0},
		{"mode": 1, "target_height": 22.5, "falloff": _falloff_curve(), "walls_shape": 1},
		# INSIDE: the wall within the area, from the loop / mask / footprint / grid border.
		{"mode": 1, "target_height": 22.5, "feather_side": 0},
		{"mode": 0, "statistic": 1, "feather_side": 0, "cut_fill": 1},
		{"mode": 1, "target_height": 22.5, "feather_side": 0, "feather_from_path_width": true, "walls_shape": 1,
				"falloff": _falloff_curve()},
	]
	var cases := 0
	var moved_cases := 0
	var worst := 0.0
	for r in routes:
		for cfg in cfgs:
			var ora := Pasture3DGraphNodeDevLeveler.new()
			var nat := Pasture3DGraphNodeLeveler.new()
			ora.feather = 6.0
			nat.feather = 6.0
			_apply(ora, cfg)
			_apply(nat, cfg)
			var a: Array = _channels(ora, r[1], r[2], r[3], GW, GH, RECT)
			var b: Array = _channels(nat, r[1], r[2], r[3], GW, GH, RECT)
			var w := _worst_channels(a, b)
			worst = maxf(worst, w)
			cases += 1
			if _worst(a[0], r[1]) > 1.0e-3:
				moved_cases += 1
			if w > EPS or ora.last_core_count != nat.last_core_count:
				_fail += 1
				print("    !! %s %s: worst %.7f, core %d vs %d" % [r[0], str(cfg), w, ora.last_core_count,
						nat.last_core_count])
	print("    %d cases, %d moved the terrain, worst |native - oracle| over 5 channels = %.7f (want < %s)"
			% [cases, moved_cases, worst, str(EPS)])
	# CONTROL: most cases must actually level something, or P compared pass-throughs.
	if moved_cases < cases / 2:
		_fail += 1
		print("    !! control: only %d of %d cases moved the terrain" % [moved_cases, cases])
	# CONTROL: a parameter off by 1.5 m of feather must be visible, or EPS is too loose to see a rule.
	var ora2 := Pasture3DGraphNodeDevLeveler.new()
	var nat2 := Pasture3DGraphNodeLeveler.new()
	_apply(ora2, {})
	_apply(nat2, {})
	ora2.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	nat2.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	ora2.target_height = 22.5
	nat2.target_height = 22.5
	ora2.feather = 6.0
	nat2.feather = 7.5
	var cw := _worst_channels(_channels(ora2, h, _square(HALF), null, GW, GH, RECT),
			_channels(nat2, h, _square(HALF), null, GW, GH, RECT))
	print("    control: a 1.5 m feather difference reads %.4f (want > 0.01)" % cw)
	if cw <= 0.01:
		_fail += 1
		print("    !! control dead: parity cannot see a feather change")
	_ran += 1


# --- T. one thread and N threads agree bit for bit ---------------------------------------------------
func _t_thread_identity() -> void:
	print("[T] the kernel is bit-identical at 1 thread and at N on a %d^2 grid" % BIG)
	var rect := Rect2(-256.0, -256.0, 512.0, 512.0)
	var h := _sloped(BIG, BIG, rect)
	var soft := PackedFloat32Array()
	soft.resize(BIG * BIG)
	for iz in BIG:
		for ix in BIG:
			var x := -256.0 + ix + 0.5
			var z := -256.0 + iz + 0.5
			soft[iz * BIG + ix] = clampf((150.0 - sqrt(x * x + z * z)) / 40.0, 0.0, 1.0)
	var loop := _square(120.0, PackedFloat32Array([4.0, 4.0, 20.0, 20.0, 10.0]))
	var runs := [
		["MEAN, mask route", {"mode": 0, "statistic": 0}, null, soft],
		["MEDIAN, exact loop", {"mode": 0, "statistic": 1}, loop, null],
		["LEVEL, path width, SLOPE", {"mode": 1, "target_height": 5.0, "feather_from_path_width": true,
				"walls_shape": 1}, loop, null],
		["LEVEL INSIDE, mask route", {"mode": 1, "target_height": 5.0, "feather_side": 0, "feather": 30.0}, null, soft],
	]
	for r in runs:
		var node := Pasture3DGraphNodeLeveler.new()
		_apply(node, r[1])
		Pasture3DUtil.set_max_threads(1)
		var c0: int = Pasture3DUtil.parallel_dispatch_count()
		var serial: Array = _channels(node, h, r[2], r[3], BIG, BIG, rect)
		var c1: int = Pasture3DUtil.parallel_dispatch_count()
		Pasture3DUtil.set_max_threads(0)
		var threaded: Array = _channels(node, h, r[2], r[3], BIG, BIG, rect)
		var c2: int = Pasture3DUtil.parallel_dispatch_count()
		var same := true
		for c in 5:
			if _worst(serial[c], threaded[c]) != 0.0:
				same = false
		print("    %s: identical %s, serial arm split %d region(s) (want 0), threaded arm split %d (want > 0)"
				% [r[0], str(same), c1 - c0, c2 - c1])
		if not same:
			_fail += 1
			print("    !! one thread and N threads disagree")
		if c1 != c0:
			_fail += 1
			print("    !! the serial arm split, so it was not serial")
		if c2 <= c1:
			_fail += 1
			print("    !! NO-SIGNAL: the threaded arm never split, so this compared serial with serial")
	Pasture3DUtil.set_max_threads(0)
	_ran += 1


# --- R. the lowered program matches the oracle --------------------------------------------------------
func _r_lowered_route() -> void:
	print("[R] the lowered program (GRAPH_OP_LEVELER) matches the oracle on every channel, inputs by wire")
	var h := _sloped(GW, GH, RECT)
	var loop := _square(HALF, PackedFloat32Array([2.0, 2.0, 12.0, 12.0, 6.0]))

	# The mask the lowered PathMask produces, reproduced by its own oracle for the Leveler oracle's input.
	var pm_ora := Pasture3DGraphNodeDevPathMask.new()
	pm_ora.feather = 6.0
	pm_ora.set_path_inputs([loop])
	var pm_grid: PackedFloat32Array = pm_ora.eval_grid([], GW, GH, null, RECT)

	var graphs := [
		# A: exact loop, target wired from a Const, LEVEL_AT_HEIGHT with walls SLOPE.
		{"name": "loop + wired target", "cfg": {"mode": 1, "walls_shape": 1, "feather": 6.0}, "target": -3.0,
				"mask": null, "path": loop},
		# B: mask wired from a Path Mask, no loop: the JFA route, MEDIAN.
		{"name": "wired mask, MEDIAN", "cfg": {"mode": 0, "statistic": 1, "feather": 6.0}, "target": null,
				"mask": pm_grid, "path": null},
		# C: exact loop, INSIDE wall, wired target.
		{"name": "loop INSIDE", "cfg": {"mode": 1, "feather_side": 0, "feather": 8.0}, "target": 4.0,
				"mask": null, "path": loop},
	]
	var checked := 0
	for gd in graphs:
		var ora := Pasture3DGraphNodeDevLeveler.new()
		_apply(ora, gd["cfg"])
		if gd["target"] != null:
			ora.target_height = float(gd["target"]) # the oracle reads the wire as its unwired default
		var want: Array = _channels(ora, h, gd["path"], gd["mask"], GW, GH, RECT)
		for ch in 5:
			var g := _leveler_graph(gd, ch, loop)
			var ok_lower: bool = g.native_supported()
			var prog := g.compile_graph_program()
			var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, h) \
					if not prog.is_empty() else PackedFloat32Array()
			var w := _worst(got, want[ch])
			checked += 1
			print("    %s, channel %d: native_supported %s, worst %.7f" % [gd["name"], ch, str(ok_lower), w])
			if not ok_lower or prog.is_empty() or w > EPS:
				_fail += 1
				print("    !! channel %d did not lower or disagrees" % ch)
	# CONTROL: the same graph with the Leveler muted lowers to a pass-through, which must disagree.
	var gm := _leveler_graph(graphs[0], 0, loop)
	(gm.nodes[2] as Pasture3DGraphNode).muted = true
	var passthru: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(gm.compile_graph_program(), GW, GH, RECT, h)
	var ora_c := Pasture3DGraphNodeDevLeveler.new()
	_apply(ora_c, graphs[0]["cfg"])
	ora_c.target_height = -3.0
	var cw := _worst(passthru, _channels(ora_c, h, loop, null, GW, GH, RECT)[0])
	print("    control: a muted Leveler differs from the oracle by %.3f (want > 1)" % cw)
	if cw <= 1.0:
		_fail += 1
		print("    !! control dead: R cannot tell a lowered Leveler from a pass-through")
	if checked != 15:
		_fail += 1
	_ran += 1


## Input -> Leveler.height; RoadSource -> Leveler.loop (A) or -> PathMask -> Leveler.mask (B);
## Const -> Leveler.target_height (A); Leveler[ch] -> Output.
func _leveler_graph(p_gd: Dictionary, p_channel: int, p_loop: Pasture3DGraphPath) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = p_loop
	var lev := Pasture3DGraphNodeLeveler.new()
	_apply(lev, p_gd["cfg"])
	var pm := Pasture3DGraphNodePathMask.new()
	pm.feather = 6.0
	var cst := Pasture3DGraphNodeConst.new()
	cst.value = float(p_gd["target"]) if p_gd["target"] != null else 0.0
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), src, lev,
			Pasture3DGraphNodeOutput.new(), pm, cst]
	g.nodes = nodes
	var conns: Array = [[0, 0, 2, 0], [2, p_channel, 3, 0]]
	if p_gd["path"] != null:
		conns.append([1, 0, 2, 1])
	if p_gd["mask"] != null:
		conns.append([1, 0, 4, 0])
		conns.append([4, 0, 2, 2])
	if p_gd["target"] != null:
		conns.append([5, 0, 2, 3])
	g.connections = conns
	return g
