# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerOracleGate — the [Dev/GD] Leveler against independent computations
# (PASTURE3D_GRAPH_LEVELER_SPEC.md §7, the oracle-level criteria A-H).
#
# The native, thread and GPU criteria (P, T, GPU) belong to the kernel's gate, not this one: there is no
# kernel yet, and a parity criterion run against the oracle alone would compare it with itself.
#
# Every criterion has a control that must fail, and every criterion counts its completion: a criterion
# that throws before asserting would otherwise pass by adding nothing to _fail.
#
# Headless is fine — nothing here touches a RenderingDevice.
#   Godot_v4.7-stable_win64_console.exe --headless --path project bench/LevelerOracleGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0) # 2 m cells, centres on odd metres
const HALF := 20.0 # square loop half-size
const EPS := 1.0e-4
const CRITERIA := 8

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== LevelerOracleGate: [Dev/GD] Leveler (spec §7, A-H) ===\n")
	_a_level_at_height()
	_b_statistics()
	_c_cut_fill()
	_d_feather_is_outside()
	_e_feather_from_path_width()
	_f_pass_through_cases()
	_g_walls_only_where_moved()
	_h_non_finite_is_outside()
	if _ran != CRITERIA:
		_fail += 1
		print("\n!! only %d of %d criteria completed" % [_ran, CRITERIA])
	print("\n=== %s (%d failures, %d/%d criteria ran) ===\n" % [
		"LEVELER ORACLE PASS" if _fail == 0 else "LEVELER ORACLE FAIL", _fail, _ran, CRITERIA])
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


func _node() -> Pasture3DGraphNodeDevLeveler:
	var n := Pasture3DGraphNodeDevLeveler.new()
	n.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE # A-H are the outward wall's criteria
	n.feather = 6.0
	return n


func _run(p_node: Pasture3DGraphNodeDevLeveler, p_h: PackedFloat32Array, p_path, p_mask = null, p_target = null) -> Array:
	var n := GW * GH
	p_node.set_path_inputs([null, p_path, null, null])
	var mask: PackedFloat32Array = p_mask if p_mask != null else Pasture3DGraphOps.filled(n, 1.0)
	var tgt: PackedFloat32Array = Pasture3DGraphOps.filled(n, float(p_target)) if p_target != null \
			else Pasture3DGraphOps.filled(n, p_node.input_unwired_default(3))
	return p_node.eval_grid_channels([p_h, Pasture3DGraphOps.zeros(n), mask, tgt], GW, GH, null, RECT)


func _check(p_ok: bool, p_msg: String) -> void:
	if not p_ok:
		_fail += 1
		print("    !! " + p_msg)


# --- A ----------------------------------------------------------------------------------------------
func _a_level_at_height() -> void:
	print("[A] Level at Height: the interior sits at the target; beyond the feather nothing moves")
	var h := _sloped()
	var node := _node()
	node.mode = Pasture3DGraphNodeDevLeveler.Mode.LEVEL_AT_HEIGHT
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
	var want := {
		Pasture3DGraphNodeDevLeveler.Statistic.MEAN: sum / vals.size(),
		Pasture3DGraphNodeDevLeveler.Statistic.MIN: vals[0],
		Pasture3DGraphNodeDevLeveler.Statistic.MAX: vals[vals.size() - 1],
		# The LOWER median, rank ceil(N/2) — what a histogram can estimate. The midpoint of the two middle
		# values is not: on sparse data they sit further apart than any bin, so no binned median reaches it.
		Pasture3DGraphNodeDevLeveler.Statistic.MEDIAN: vals[(vals.size() + 1) / 2 - 1],
	}
	var node := _node()
	var bin_width: float = (vals[vals.size() - 1] - vals[0]) / float(node.median_bins)
	var median_got := NAN
	for s in want:
		node.statistic = s
		var o: Array = _run(node, h, _square())
		var tol := EPS
		if s == Pasture3DGraphNodeDevLeveler.Statistic.MEDIAN:
			tol = bin_width + 1.0e-6
		var got: float = o[2][0]
		if s == Pasture3DGraphNodeDevLeveler.Statistic.MEDIAN:
			median_got = got
		print("    %s: got %.6f want %.6f (tol %.6f)" % [Pasture3DGraphNodeDevLeveler.Statistic.keys()[s], got, want[s], tol])
		_check(absf(got - want[s]) <= tol, "statistic %s is wrong" % Pasture3DGraphNodeDevLeveler.Statistic.keys()[s])
	# CONTROL: the next order statistic up must fall outside the median tolerance, or the median check
	# cannot tell the lower median from its neighbour and a rank off-by-one would pass.
	var upper: float = vals[(vals.size() + 1) / 2]
	print("    control: next order statistic %.6f is %.6f from the median (want > one bin %.6f)" % [
		upper, absf(upper - median_got), bin_width])
	_check(absf(upper - median_got) > bin_width + 1.0e-6, "control dead: the median rank is not resolvable on this fixture")
	# CONTROL: a mean that also counts the feather ring must differ, or B cannot see a sample-area bug.
	var sum2 := sum
	for v in ring_vals:
		sum2 += v
	var wide: float = sum2 / float(vals.size() + ring_vals.size())
	print("    control: mean including the ring = %.4f vs %.4f (want differ > 0.05)" % [wide, want[0]])
	_check(absf(wide - want[0]) > 0.05, "control dead: ring and interior means coincide on this fixture")
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
			if o[0][i] > h[i] + 1e-6: up += 1
			if o[0][i] < h[i] - 1e-6: down += 1
		counts[cf] = [up, down]
		print("    %s: raised %d, lowered %d" % [Pasture3DGraphNodeDevLeveler.CutFill.keys()[cf], up, down])
	_check(counts[1][0] == 0 and counts[1][1] > 0, "Cut Only raised a cell or cut nothing")
	_check(counts[2][1] == 0 and counts[2][0] > 0, "Fill Only lowered a cell or filled nothing")
	# CONTROL: Both must raise AND lower, or the cut/fill checks pass on a one-sided fixture.
	_check(counts[0][0] > 0 and counts[0][1] > 0, "control dead: Both is one-sided on this fixture")
	_ran += 1


# --- D ----------------------------------------------------------------------------------------------
func _d_feather_is_outside() -> void:
	print("[D] the wall is OUTSIDE: every interior cell is at the level, ring cells are between, far cells untouched")
	var h := _sloped()
	var node := _node()
	node.mode = Pasture3DGraphNodeDevLeveler.Mode.LEVEL_AT_HEIGHT
	node.target_height = 40.0
	var o: Array = _run(node, h, _square())
	var ring := 0
	var bad := 0
	for i in h.size():
		var w := _world(i)
		var d := _square_distance(w)
		if _in_square(w):
			if absf(o[0][i] - 40.0) > EPS: bad += 1
		elif d < node.feather:
			ring += 1
			var lo := minf(h[i], 40.0) - EPS
			var hi := maxf(h[i], 40.0) + EPS
			if o[0][i] < lo or o[0][i] > hi or absf(o[0][i] - 40.0) < EPS or absf(o[0][i] - h[i]) < EPS:
				bad += 1
	print("    ring cells %d, violations %d" % [ring, bad])
	_check(ring > 0, "NO-SIGNAL: no ring cells")
	_check(bad == 0, "the feather is not a strictly-between wall outside the area")
	# CONTROL: feather 0 must leave the ring untouched, or D cannot tell a wall from a hard edge.
	node.feather = 0.0
	var o2: Array = _run(node, h, _square())
	var moved := 0
	for i in h.size():
		var w := _world(i)
		if not _in_square(w) and absf(o2[0][i] - h[i]) > EPS:
			moved += 1
	print("    control: hard edge moved %d outside cells (want 0)" % moved)
	_check(moved == 0, "control: a zero feather still built a wall")
	_ran += 1


# --- E ----------------------------------------------------------------------------------------------
func _e_feather_from_path_width() -> void:
	print("[E] Feather From Path Width: the wall is 2 m at the bottom edge and 12 m at the top")
	var h := _sloped()
	# Vertices: (-20,-20) (20,-20) (20,20) (-20,20). Bottom edge 2..2, top edge 12..12.
	var loop := _square(PackedFloat32Array([2.0, 2.0, 12.0, 12.0]))
	var node := _node()
	node.mode = Pasture3DGraphNodeDevLeveler.Mode.LEVEL_AT_HEIGHT
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
	# CONTROL: a constant 5 m feather treats both sides alike.
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
	print("[F] an open loop and an empty core both pass the height through, with a warning")
	var h := _sloped()
	var node := _node()
	var open := _square()
	open.closed = false
	var o: Array = _run(node, h, open)
	# An open loop is ignored: the area falls back to every finite cell, so the whole grid flattens.
	var spread := 0.0
	for i in h.size():
		spread = maxf(spread, absf(o[0][i] - o[2][0]))
	var warned_open := node.node_warnings().size() > 0
	print("    open loop: output spread about level %.6f (whole grid flattened), warned %s" % [spread, warned_open])
	_check(spread < EPS, "an open loop was not ignored")
	_check(warned_open, "an open loop raised no warning")
	# Empty core: a mask that never reaches 1.
	var node2 := _node()
	var half := Pasture3DGraphOps.filled(GW * GH, 0.5)
	var o2: Array = _run(node2, h, null, half)
	var diff := 0.0
	for i in h.size():
		diff = maxf(diff, absf(o2[0][i] - h[i]))
	var warned_empty := node2.node_warnings().size() > 0
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
func _g_walls_only_where_moved() -> void:
	print("[G] walls is the ring only, scaled by movement: zero inside, zero where nothing moved")
	var node := _node()
	node.mode = Pasture3DGraphNodeDevLeveler.Mode.LEVEL_AT_HEIGHT
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
	# CONTROL: the ring must actually carry walls, or the zero checks pass on an output that is always 0.
	_check(ring_walls > 0.5, "control dead: walls never fires in the ring")
	# SLOPE shape differs from BAND somewhere in the ring.
	node.walls_shape = Pasture3DGraphNodeDevLeveler.WallsShape.SLOPE
	var o3: Array = _run(node, h, _square())
	var shape_diff := 0.0
	for i in h.size():
		shape_diff = maxf(shape_diff, absf(o3[4][i] - o2[4][i]))
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
