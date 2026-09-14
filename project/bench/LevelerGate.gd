# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerGate — the Leveler's behavioural criteria A-H (PASTURE3D_GRAPH_LEVELER_SPEC.md §7), on EVERY route
# a user can reach:
#
#   ORACLE  Pasture3DGraphNodeDevLeveler.eval_grid_channels (the [Dev/GD] definition)
#   NATIVE  Pasture3DGraphNodeLeveler.eval_grid_channels -> Pasture3DUtil.leveler_grid
#   GRAPH   the lowered program (GRAPH_OP_LEVELER) through graph_eval_grid, with the loop, mask and target
#           arriving BY WIRE, one compile per output channel, native_supported() asserted every time
#
# Parity (P), thread identity (T) and the GPU criterion live in their own gates, because they compare two
# implementations rather than one against the spec:
#   P, T  bench/LevelerNativeParityGate.tscn   (headless)
#   GPU   bench/LevelerGpuGate.tscn            (windowed; NO-SIGNAL headless)
# Running A-H on all three routes here is not redundant with P: parity proves the routes agree, and agreeing
# is exactly what two routes sharing one wrong rule do.
#
# Every criterion has a control that must fail, and every criterion counts its completion.
# Warnings are node state, which a lowered program never touches, so the GRAPH route skips those checks.
#
# Headless is fine.
#   Godot_v4.7-stable_win64_console.exe --headless --path project bench/LevelerGate.tscn
extends Node

enum Route { ORACLE, NATIVE, GRAPH }

const GW := 64
const GH := 64
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0) # 2 m cells, centres on odd metres
const HALF := 20.0 # square loop half-size
const EPS := 1.0e-4
const PER_ROUTE := 8

var _fail := 0
var _ran := 0
var _route: Route = Route.ORACLE


func _ready() -> void:
	print("=== LevelerGate: criteria A-H on the oracle, native and lowered-graph routes (spec §7) ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "leveler_grid"):
		print("!! Pasture3DUtil.leveler_grid is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return
	for r in [Route.ORACLE, Route.NATIVE, Route.GRAPH]:
		_route = r
		print("\n--- route %s ---" % Route.keys()[r])
		_a_level_at_height()
		_b_statistics()
		_c_cut_fill()
		_d_feather_is_outside()
		_e_feather_from_path_width()
		_f_pass_through_cases()
		_g_walls_only_where_moved()
		_h_non_finite_is_outside()
	var want := PER_ROUTE * Route.size()
	if _ran != want:
		_fail += 1
		print("\n!! only %d of %d criteria completed" % [_ran, want])
	print("\n=== %s (%d failures, %d/%d criteria ran) ===\n" % [
		"LEVELER GATE PASS" if _fail == 0 else "LEVELER GATE FAIL", _fail, _ran, want])
	get_tree().quit(0 if _fail == 0 else 1)


# --- fixtures ---------------------------------------------------------------------------------------

func _world(p_i: int) -> Vector2:
	var dx := RECT.size.x / GW
	return Vector2(RECT.position.x + (float(p_i % GW) + 0.5) * dx, RECT.position.y + (float(p_i / GW) + 0.5) * dx)


func _index_at(p_x: float, p_z: float) -> int:
	var dx := RECT.size.x / GW
	return int(floor((p_z - RECT.position.y) / dx)) * GW + int(floor((p_x - RECT.position.x) / dx))


## A tilted plane with a bump, so no statistic coincides with another and no cell sits at the level.
func _sloped() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(GW * GH)
	for i in h.size():
		var w := _world(i)
		h[i] = 10.0 + 0.2 * w.x + 0.1 * w.y + 6.0 * exp(-(pow(w.x - 8.0, 2.0) + pow(w.y + 6.0, 2.0)) / 60.0)
	return h


func _square(p_widths := PackedFloat32Array()) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(-HALF, -HALF), Vector2(HALF, -HALF), Vector2(HALF, HALF), Vector2(-HALF, HALF)])
	p.half_widths = p_widths
	p.closed = true
	return p


## Independent of Pasture3DGraphPath: an axis-aligned square needs no polygon test.
func _in_square(p_w: Vector2) -> bool:
	return absf(p_w.x) < HALF and absf(p_w.y) < HALF


func _square_distance(p_w: Vector2) -> float:
	return Vector2(maxf(absf(p_w.x) - HALF, 0.0), maxf(absf(p_w.y) - HALF, 0.0)).length()


## Negative inside the square (distance to the nearest edge), positive outside.
func _square_signed(p_w: Vector2) -> float:
	return -(HALF - maxf(absf(p_w.x), absf(p_w.y))) if _in_square(p_w) else _square_distance(p_w)


func _node() -> Pasture3DGraphNodeLevelerBase:
	var n: Pasture3DGraphNodeLevelerBase = Pasture3DGraphNodeDevLeveler.new() if _route == Route.ORACLE \
			else Pasture3DGraphNodeLeveler.new()
	n.feather = 6.0
	return n


## The five channels for this route. A mask must be uniform: on the GRAPH route it arrives from a Const.
func _run(p_node: Pasture3DGraphNodeLevelerBase, p_h: PackedFloat32Array, p_path, p_mask = null, p_target = null) -> Array:
	var n := GW * GH
	if _route != Route.GRAPH:
		p_node.set_path_inputs([null, p_path, null, null])
		var mask: PackedFloat32Array = p_mask if p_mask != null else Pasture3DGraphOps.filled(n, 1.0)
		var tgt: PackedFloat32Array = Pasture3DGraphOps.filled(n, float(p_target)) if p_target != null \
				else Pasture3DGraphOps.filled(n, p_node.input_unwired_default(3))
		return p_node.eval_grid_channels([p_h, Pasture3DGraphOps.zeros(n), mask, tgt], GW, GH, null, RECT)

	var out := []
	for ch in 5:
		var src := Pasture3DGraphNodeRoadSource.new()
		src.path = p_path
		var mconst := Pasture3DGraphNodeConst.new()
		mconst.value = float(p_mask[0]) if p_mask != null else 1.0
		var tconst := Pasture3DGraphNodeConst.new()
		tconst.value = float(p_target) if p_target != null else 0.0
		var g := Pasture3DTerrainGraph.new()
		var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_node, Pasture3DGraphNodeOutput.new(),
				src, mconst, tconst]
		g.nodes = nodes
		var conns: Array = [[0, 0, 1, 0], [1, ch, 2, 0]]
		if p_path != null:
			conns.append([3, 0, 1, 1])
		if p_mask != null:
			conns.append([4, 0, 1, 2])
		if p_target != null:
			conns.append([5, 0, 1, 3])
		g.connections = conns
		if not g.native_supported():
			_check(false, "the graph route did not lower (channel %d) — this would have measured GDScript" % ch)
		out.append(Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), GW, GH, RECT, p_h))
	return out


func _check(p_ok: bool, p_msg: String) -> void:
	if not p_ok:
		_fail += 1
		print("    !! [%s] %s" % [Route.keys()[_route], p_msg])


func _warns(p_node: Pasture3DGraphNodeLevelerBase) -> bool:
	return _route == Route.GRAPH or p_node.node_warnings().size() > 0


# --- A ----------------------------------------------------------------------------------------------
func _a_level_at_height() -> void:
	print("[A] Level at Height: the interior sits at the target; beyond the feather nothing moves")
	var h := _sloped()
	var node := _node()
	node.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	node.target_height = 3.5
	var o: Array = _run(node, h, _square())
	var worst_in := 0.0
	var worst_far := 0.0
	var interior := 0
	for i in h.size():
		var w := _world(i)
		if _in_square(w):
			interior += 1
			worst_in = maxf(worst_in, absf(o[0][i] - 3.5))
		elif _square_distance(w) >= node.feather:
			worst_far = maxf(worst_far, absf(o[0][i] - h[i]))
	print("    interior cells %d, max |h - target| = %.6f, max change beyond feather = %.6f" % [interior, worst_in, worst_far])
	_check(interior > 0, "NO-SIGNAL: no interior cells")
	_check(worst_in < EPS, "interior is not at the target")
	_check(worst_far < EPS, "cells beyond the feather moved")
	# Socket override: a wired target must win over the inspector value.
	var o2: Array = _run(node, h, _square(), null, -7.0)
	var at := _index_at(1.0, 1.0)
	print("    wired target -7: centre = %.4f, level_value = %.4f" % [o2[0][at], o2[2][0]])
	_check(absf(o2[0][at] + 7.0) < EPS and absf(o2[2][0] + 7.0) < EPS, "the target_height socket does not override")
	# CONTROL: the untouched input fails the interior test, or A passes for a no-op.
	var ctrl := 0.0
	for i in h.size():
		if _in_square(_world(i)):
			ctrl = maxf(ctrl, absf(h[i] - 3.5))
	print("    control: input differs from target by up to %.3f (want > 1)" % ctrl)
	_check(ctrl > 1.0, "control dead: the fixture is already at the target")
	_ran += 1


# --- B ----------------------------------------------------------------------------------------------
func _b_statistics() -> void:
	print("[B] Flatten statistics equal an independent computation over the fully-inside cells")
	var h := _sloped()
	var vals: Array[float] = []
	var ring_vals: Array[float] = []
	for i in h.size():
		var w := _world(i)
		if _in_square(w):
			vals.append(h[i])
		elif _square_distance(w) < 6.0:
			ring_vals.append(h[i])
	vals.sort()
	var sum := 0.0
	for v in vals:
		sum += v
	var S := Pasture3DGraphNodeLevelerBase.Statistic
	var want := {
		S.MEAN: sum / vals.size(),
		S.MIN: vals[0],
		S.MAX: vals[vals.size() - 1],
		# The LOWER median, rank ceil(N/2) — what a histogram can estimate.
		S.MEDIAN: vals[(vals.size() + 1) / 2 - 1],
	}
	var node := _node()
	var bin_width: float = (vals[vals.size() - 1] - vals[0]) / float(node.median_bins)
	var median_got := NAN
	for s in want:
		node.statistic = s
		var o: Array = _run(node, h, _square())
		var tol := EPS
		if s == S.MEDIAN:
			tol = bin_width + 1.0e-5
		var got: float = o[2][0]
		if s == S.MEDIAN:
			median_got = got
		print("    %s: got %.6f want %.6f (tol %.6f)" % [S.keys()[s], got, want[s], tol])
		_check(absf(got - want[s]) <= tol, "statistic %s is wrong" % S.keys()[s])
	# CONTROL: the next order statistic up must fall outside the median tolerance.
	var upper: float = vals[(vals.size() + 1) / 2]
	print("    control: next order statistic %.6f is %.6f from the median (want > one bin %.6f)" % [
		upper, absf(upper - median_got), bin_width])
	_check(absf(upper - median_got) > bin_width + 1.0e-5, "control dead: the median rank is not resolvable on this fixture")
	# CONTROL (spec): a statistic computed over A > 0 — the feather ring included — must differ.
	var sum2 := sum
	for v in ring_vals:
		sum2 += v
	var wide: float = sum2 / float(vals.size() + ring_vals.size())
	print("    control: mean including the ring = %.4f vs %.4f (want differ > 0.05)" % [wide, want[S.MEAN]])
	_check(absf(wide - want[S.MEAN]) > 0.05, "control dead: ring and interior means coincide on this fixture")
	_ran += 1


# --- C ----------------------------------------------------------------------------------------------
func _c_cut_fill() -> void:
	print("[C] Cut Only never raises, Fill Only never lowers; Both does both")
	var h := _sloped()
	var node := _node()
	var counts := {}
	for cf in [0, 1, 2]:
		node.cut_fill = cf
		var o: Array = _run(node, h, _square())
		var up := 0
		var down := 0
		for i in h.size():
			if o[0][i] > h[i] + 1e-5: up += 1
			if o[0][i] < h[i] - 1e-5: down += 1
		counts[cf] = [up, down]
		print("    %s: raised %d, lowered %d" % [Pasture3DGraphNodeLevelerBase.CutFill.keys()[cf], up, down])
	_check(counts[1][0] == 0 and counts[1][1] > 0, "Cut Only raised a cell or cut nothing")
	_check(counts[2][1] == 0 and counts[2][0] > 0, "Fill Only lowered a cell or filled nothing")
	# CONTROL (spec): Both must raise AND lower.
	_check(counts[0][0] > 0 and counts[0][1] > 0, "control dead: Both is one-sided on this fixture")
	_ran += 1


# --- D ----------------------------------------------------------------------------------------------
## [ring cells, violations] of the outside-wall rule: every interior cell at the level, every ring cell
## strictly between its input and the level, every cell at d >= F untouched.
func _d_violations(p_out: PackedFloat32Array, p_h: PackedFloat32Array, p_level: float, p_feather: float) -> Array:
	var ring := 0
	var bad := 0
	for i in p_h.size():
		var w := _world(i)
		var d := _square_distance(w)
		if _in_square(w):
			if absf(p_out[i] - p_level) > EPS: bad += 1
		elif d < p_feather:
			ring += 1
			var lo := minf(p_h[i], p_level) - EPS
			var hi := maxf(p_h[i], p_level) + EPS
			if p_out[i] < lo or p_out[i] > hi or absf(p_out[i] - p_level) < EPS or absf(p_out[i] - p_h[i]) < EPS:
				bad += 1
		elif absf(p_out[i] - p_h[i]) > EPS:
			bad += 1
	return [ring, bad]


func _d_feather_is_outside() -> void:
	print("[D] the wall is OUTSIDE: interior at the level, ring strictly between, d >= F untouched")
	var h := _sloped()
	var node := _node()
	node.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	node.target_height = 40.0
	var o: Array = _run(node, h, _square())
	var r: Array = _d_violations(o[0], h, 40.0, node.feather)
	print("    ring cells %d, violations %d" % [r[0], r[1]])
	_check(r[0] > 0, "NO-SIGNAL: no ring cells")
	_check(r[1] == 0, "the feather is not a strictly-between wall outside the area")
	# CONTROL (spec): a CENTRED feather — the wall straddling the edge, F/2 inside and F/2 out — must fail
	# the same rule. Built here by hand with the node's own default falloff, so the only difference is where
	# the wall sits.
	var centred := PackedFloat32Array()
	centred.resize(h.size())
	for i in h.size():
		var t := clampf((_square_signed(_world(i)) + node.feather * 0.5) / node.feather, 0.0, 1.0)
		var wgt := 1.0 - t * t * (3.0 - 2.0 * t)
		centred[i] = h[i] + (40.0 - h[i]) * wgt
	var rc: Array = _d_violations(centred, h, 40.0, node.feather)
	print("    control: a centred feather has %d violation(s) (want > 0)" % rc[1])
	_check(rc[1] > 0, "control dead: the rule cannot tell an outside wall from a centred one")
	_ran += 1


# --- E ----------------------------------------------------------------------------------------------
func _e_feather_from_path_width() -> void:
	print("[E] Feather From Path Width: the wall is 2 m at the bottom edge and 12 m at the top")
	var h := _sloped()
	# Vertices: (-20,-20) (20,-20) (20,20) (-20,20). Bottom edge 2..2, top edge 12..12.
	var loop := _square(PackedFloat32Array([2.0, 2.0, 12.0, 12.0]))
	var node := _node()
	node.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	node.target_height = 40.0
	node.feather_from_path_width = true
	var o: Array = _run(node, h, loop)
	var bottom := _index_at(1.0, -27.0) # 7 m below the bottom edge
	var top := _index_at(1.0, 27.0) # 7 m above the top edge
	var db := absf(o[0][bottom] - h[bottom])
	var dt := absf(o[0][top] - h[top])
	print("    moved at 7 m: bottom %.4f (want 0), top %.4f (want > 0)" % [db, dt])
	_check(db < EPS, "the narrow edge's wall reaches past its width")
	_check(dt > 0.01, "the wide edge's wall does not reach its width")
	# CONTROL (spec): a constant feather cannot produce the asymmetry — at 5 m neither side moves at 7 m.
	node.feather_from_path_width = false
	node.feather = 5.0
	var o2: Array = _run(node, h, loop)
	var cb := absf(o2[0][bottom] - h[bottom])
	var ct := absf(o2[0][top] - h[top])
	print("    control: constant feather moved bottom %.4f, top %.4f (want both 0)" % [cb, ct])
	_check(cb < EPS and ct < EPS, "control: a constant feather is not symmetric")
	_ran += 1


# --- F ----------------------------------------------------------------------------------------------
func _f_pass_through_cases() -> void:
	print("[F] an open loop is ignored and an empty core passes the height through, with warnings")
	var h := _sloped()
	var node := _node()
	var open := _square()
	open.closed = false
	var o: Array = _run(node, h, open)
	# An open loop is ignored: the area falls back to every finite cell, so the whole grid flattens.
	var spread := 0.0
	for i in h.size():
		spread = maxf(spread, absf(o[0][i] - o[2][0]))
	var warned_open := _warns(node)
	print("    open loop: output spread about level %.6f (whole grid flattened), warned %s" % [spread, warned_open])
	_check(spread < EPS, "an open loop was not ignored")
	_check(warned_open, "an open loop raised no warning")
	# Empty core: a mask that never reaches 1.
	var node2 := _node()
	var o2: Array = _run(node2, h, null, Pasture3DGraphOps.filled(GW * GH, 0.5))
	var diff := 0.0
	for i in h.size():
		diff = maxf(diff, absf(o2[0][i] - h[i]))
	var warned_empty := _warns(node2)
	print("    empty core: max change %.6f (want 0), level_value NaN %s, warned %s" % [diff, is_nan(o2[2][0]), warned_empty])
	_check(diff == 0.0 and is_nan(o2[2][0]) and warned_empty, "an empty core did not pass through with a warning")
	# CONTROL: a mask of 1 must NOT pass through.
	var o3: Array = _run(_node(), h, null, Pasture3DGraphOps.filled(GW * GH, 1.0))
	var d3 := 0.0
	for i in h.size():
		d3 = maxf(d3, absf(o3[0][i] - h[i]))
	print("    control: full mask changed up to %.3f (want > 1)" % d3)
	_check(d3 > 1.0, "control dead: a full mask did nothing")
	_ran += 1


# --- G ----------------------------------------------------------------------------------------------
## Ring cells whose walls value is not clamp(|delta| / wall_depth) (BAND), and how many of them have a
## fractional expectation — the cells that can tell scaling from a plain ring mask.
func _g_scaling_mismatches(p_walls: PackedFloat32Array, p_delta: PackedFloat32Array, p_depth: float) -> Array:
	var bad := 0
	var fractional := 0
	for i in p_walls.size():
		var w := _world(i)
		if _in_square(w) or _square_distance(w) >= 6.0:
			continue
		var want := clampf(absf(p_delta[i]) / p_depth, 0.0, 1.0) if p_delta[i] != 0.0 else 0.0
		if want > 0.01 and want < 0.99:
			fractional += 1
		if absf(p_walls[i] - want) > 1.0e-4:
			bad += 1
	return [bad, fractional]


func _g_walls_only_where_moved() -> void:
	print("[G] walls: zero inside, zero where nothing moved, scaled by movement in the ring")
	var node := _node()
	node.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	node.target_height = 5.0
	var flat := Pasture3DGraphOps.filled(GW * GH, 5.0)
	var o: Array = _run(node, flat, _square())
	var wmax := 0.0
	for i in flat.size():
		wmax = maxf(wmax, o[4][i])
	print("    flat ground already at the level: max walls %.6f (want 0)" % wmax)
	_check(wmax == 0.0, "walls fired where no cell moved")
	var h := _sloped()
	node.target_height = 40.0
	var o2: Array = _run(node, h, _square())
	var inside_walls := 0.0
	var ring_walls := 0.0
	for i in h.size():
		var w := _world(i)
		if _in_square(w):
			inside_walls = maxf(inside_walls, o2[4][i])
		elif _square_distance(w) < node.feather:
			ring_walls = maxf(ring_walls, o2[4][i])
	print("    sloped: max walls inside %.6f (want 0), in ring %.4f (want > 0.5)" % [inside_walls, ring_walls])
	_check(inside_walls == 0.0, "walls fired inside the area")
	_check(ring_walls > 0.5, "control dead: walls never fires in the ring")
	# SCALING: with a deep wall_depth, ring walls must be clamp(|delta| / wall_depth).
	node.wall_depth = 20.0
	var o3: Array = _run(node, h, _square())
	var m: Array = _g_scaling_mismatches(o3[4], o3[3], 20.0)
	print("    wall_depth 20: %d mismatch(es) against clamp(|delta|/depth) (want 0), %d fractional cells" % [m[0], m[1]])
	_check(m[1] > 0, "NO-SIGNAL: no ring cell has a fractional movement weight")
	_check(m[0] == 0, "walls is not scaled by movement")
	# CONTROL (spec): a ring mask WITHOUT movement scaling — 1 wherever a ring cell moved — must fail.
	var unscaled := PackedFloat32Array()
	unscaled.resize(h.size())
	for i in h.size():
		var w := _world(i)
		unscaled[i] = 1.0 if not _in_square(w) and _square_distance(w) < 6.0 and o3[3][i] != 0.0 else 0.0
	var mc: Array = _g_scaling_mismatches(unscaled, o3[3], 20.0)
	print("    control: an unscaled ring mask has %d mismatch(es) (want > 0)" % mc[0])
	_check(mc[0] > 0, "control dead: scaling cannot be told from a plain ring mask")
	# SLOPE shape differs from BAND somewhere in the ring.
	node.wall_depth = 1.0
	node.walls_shape = Pasture3DGraphNodeLevelerBase.WallsShape.SLOPE
	var o4: Array = _run(node, h, _square())
	var shape_diff := 0.0
	for i in h.size():
		shape_diff = maxf(shape_diff, absf(o4[4][i] - o2[4][i]))
	print("    SLOPE vs BAND differ by up to %.4f (want > 0.1)" % shape_diff)
	_check(shape_diff > 0.1, "walls_shape does nothing")
	_ran += 1


# --- H ----------------------------------------------------------------------------------------------
func _h_non_finite_is_outside() -> void:
	print("[H] non-finite height (outside a brush footprint) is outside the area and the statistic")
	var h := _sloped()
	var cut := 0
	for i in h.size():
		if _world(i).x > 10.0:
			h[i] = NAN
			cut += 1
	var node := _node()
	var o: Array = _run(node, h, _square())
	var sum := 0.0
	var count := 0
	var nan_kept := true
	for i in h.size():
		var w := _world(i)
		if is_nan(h[i]):
			if not is_nan(o[0][i]): nan_kept = false
		elif _in_square(w):
			sum += h[i]
			count += 1
	var want := sum / float(count)
	print("    NaN cells %d, NaN preserved %s, mean %.6f want %.6f" % [cut, nan_kept, o[2][0], want])
	_check(nan_kept, "a non-finite cell was written")
	_check(absf(o[2][0] - want) < EPS, "the mean included or mishandled non-finite cells")
	# CONTROL: the mean over the square ignoring the NaN cut must differ.
	var h0 := _sloped()
	var s0 := 0.0
	var c0 := 0
	for i in h0.size():
		if _in_square(_world(i)):
			s0 += h0[i]
			c0 += 1
	print("    control: uncut mean %.4f (want differ > 0.05)" % (s0 / c0))
	_check(absf(s0 / c0 - want) > 0.05, "control dead: the cut does not change the mean")
	_ran += 1
