# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathShapeGate — the five reshape nodes (S5).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. Five PATH -> PATH nodes, all pure functions of the input path and
# their own scalars. None of them touches the native tier: the S4 pre-pass resolves them host-side, so
# what reaches the kernel is one flat polyline. That is what makes the family cheap and it is also what
# makes it easy to ship broken — nothing downstream can tell a reshaped path from a drawn one.
#
# ---- WHY "THE PATH CHANGED" IS NOT A CRITERION ----
#
# Every one of these nodes changes the path. So does a node that mangles it, and so does a node whose
# only effect is to drop the widths. Each criterion therefore measures the property the node exists for,
# and carries the control that separates it from the plausible wrong answer:
#
#   [A] each node changes the line AND is the identity at zero strength, byte for byte. The identity half
#       is the control: a node that changed the path unconditionally would pass the first half alone.
#   [B] a seed is STABLE — the same seed twice is byte-identical, a different seed is not. Not "random":
#       an unstable reshape moves the terrain under a frozen graph and reads as cache corruption.
#   [C] Resample at 1 m puts vertices 1 m apart AND preserves arc length. Spacing alone would pass on a
#       node that resampled a straight chord between the endpoints.
#   [D] Meanderize LENGTHENS the line, and `remove_loops` leaves it non-self-intersecting. Length is the
#       criterion because the sign error this algorithm invites does not mirror the river, it
#       STRAIGHTENS it — silent at one iteration, total at six (see the node's header).
#   [E] widths and heights survive a reshape, resampled onto the new vertices; and a path carrying none
#       still carries none rather than gaining zeros. NaN is "no data" in a HEIGHT array, and a reshape
#       that helpfully filled it with 0.0 would drag a ridge drawn at 400 m to sea level.
#   [F] a reshape DROPS a solved road profile and Path Width KEEPS it. A stale alignment describes the
#       line the path used to be, and `can_grade()` would still answer true.
#   [G] the query cost of a reshaped path grows no worse than its vertex count. Measured as a RATIO
#       against the same line before the reshape, so it says nothing about how fast this machine is.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathShapeGate: the reshape family (S5) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4")

	_a_each_node_reshapes_and_is_the_identity_at_zero()
	_b_seeds_are_stable()
	_c_resample_spacing_and_arc_length()
	_d_meanderize_lengthens_and_removes_loops()
	_e_values_survive_a_reshape()
	_f_a_reshape_drops_the_road_profile()
	_g_a_reshaped_path_is_still_cheap_to_query()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH SHAPE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## A drawn line: few points, a real bend, per-vertex widths and heights.
##
## Nine points is what a hand-drawn river actually is, and it matters here — a fixture already dense
## enough would let Resample look like it worked while doing nothing, and would give Smooth and Decimate
## far more to chew on than they ever get in practice.
func _drawn() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 9:
		var f := float(i) / 8.0
		pts.append(Vector2(-140.0 + f * 280.0, 60.0 * sin(f * PI * 1.4)))
		w.append(3.0 + 9.0 * f)
		h.append(120.0 - 40.0 * f)
	p.points = pts
	p.half_widths = w
	p.heights = h
	return p


## The same line, densified, for the nodes that need something to work on. Uses the production Resample,
## deliberately: if Resample is broken, [C] says so directly rather than every other criterion failing
## for a reason none of them names.
func _dense() -> Pasture3DGraphPath:
	var r := Pasture3DGraphNodePathResample.new()
	r.step = 4.0
	return _run(r, _drawn())


## Run one node's `eval_path` and return the result. A fresh instance per call, because these nodes keep
## ONE output instance by design and comparing a node's output against itself would compare a path to
## the same object.
func _run(p_node: Pasture3DGraphNodePathShape, p_in: Pasture3DGraphPath) -> Pasture3DGraphPath:
	return p_node.eval_path([p_in])


func _length(p_path: Pasture3DGraphPath) -> float:
	var d := 0.0
	for i in range(1, p_path.points.size()):
		d += p_path.points[i].distance_to(p_path.points[i - 1])
	return d


func _same_points(p_a: Pasture3DGraphPath, p_b: Pasture3DGraphPath) -> bool:
	return p_a.points == p_b.points


## True when any two non-adjacent segments cross. The definition [D] is written against, and the same one
## the node's `_cut_loops` uses, deliberately — a second definition here would be testing whether two
## intersection routines agree rather than whether the path has a loop.
func _self_intersects(p_path: Pasture3DGraphPath) -> int:
	var pts := p_path.points
	var hits := 0
	for i in range(pts.size() - 1):
		for j in range(i + 2, pts.size() - 1):
			if Geometry2D.segment_intersects_segment(pts[i], pts[i + 1], pts[j], pts[j + 1]) != null:
				hits += 1
	return hits


# ---- criteria -----------------------------------------------------------------------------------

## [A] Each of the five changes the path, and each is the identity at its zero setting.
##
## The identity half is the control, and it is byte-for-byte rather than approximate on purpose: a node
## that ran its algorithm and happened to move nothing measurable would pass a tolerance and fail this.
func _a_each_node_reshapes_and_is_the_identity_at_zero() -> void:
	print("[A] each reshape changes the line, and is the identity at zero strength")
	var dense := _dense()
	var moved := PackedStringArray()
	var not_moved := PackedStringArray()
	var not_identity := PackedStringArray()

	# [node, the settings that make it work, the settings that make it the identity]
	var cases := [
		["Resample", Pasture3DGraphNodePathResample.new(), {"step": 2.0}, {}],
		["Smooth", Pasture3DGraphNodePathSmooth.new(), {"window": 6, "intensity": 1.0},
				{"intensity": 0.0}],
		["Decimate", Pasture3DGraphNodePathDecimate.new(), {"target_points": 12},
				{"target_points": 100000}],
		["Fractalize", Pasture3DGraphNodePathFractalize.new(), {"iterations": 3, "sigma": 6.0},
				{"sigma": 0.0}],
		["Meanderize", Pasture3DGraphNodePathMeanderize.new(),
				{"iterations": 2, "ratio": 0.5, "noise_ratio": 0.1},
				{"ratio": 0.0, "noise_ratio": 0.0}],
	]
	for c in cases:
		var title: String = c[0]
		# Resample has no zero setting: putting a vertex every N metres is what it IS, and a step of
		# nearly nothing is its BUSIEST case, not its idlest. Its genuine identity is a step longer than
		# the whole line, which cannot place a second vertex and so passes the input through untouched.
		#
		# The first version of this criterion asked for a 0.05 m step and asserted the input came back,
		# on the theory that the vertex cap would refuse it. It did not: 6 700 vertices is well inside
		# the cap, so the node resampled exactly as asked and the gate called a correct answer a failure.
		if title == "Resample":
			c[3] = {"step": 10000.0}

		var work: Pasture3DGraphNodePathShape = c[1]
		for k in c[2]:
			work.set(k, c[2][k])
		var got := _run(work, dense)
		if got != null and not _same_points(got, dense):
			moved.append(title)
		else:
			not_moved.append(title)

		var idle: Pasture3DGraphNodePathShape = (c[1] as Object).duplicate()
		for k in c[3]:
			idle.set(k, c[3][k])
		var same := _run(idle, dense)
		if same == null or not _same_points(same, dense):
			not_identity.append(title)

	print("    changed the line: %s" % str(moved))
	print("    control, identity at zero: %d of 5 (failures: %s)"
			% [5 - not_identity.size(), "none" if not_identity.is_empty() else str(not_identity)])
	_check("A", moved.size() == 5 and not_identity.is_empty(),
			"all five reshape, and all five are the identity at zero")


## [B] Fractalize and Meanderize are STABLE under a seed, not merely random.
##
## Byte-for-byte on a repeat, and different on a different seed. The second half is the control: a node
## that ignored its seed entirely would pass the first half perfectly.
func _b_seeds_are_stable() -> void:
	print("[B] the seeded reshapes are stable under a seed, and vary with it")
	var dense := _dense()
	var rows := PackedStringArray()
	var ok := true
	for title in ["Fractalize", "Meanderize"]:
		var mk := func(p_seed: int) -> Pasture3DGraphNodePathShape:
			if title == "Fractalize":
				var f := Pasture3DGraphNodePathFractalize.new()
				f.iterations = 4
				f.sigma = 5.0
				f.seed = p_seed
				return f
			var m := Pasture3DGraphNodePathMeanderize.new()
			m.iterations = 3
			m.ratio = 0.4
			m.noise_ratio = 0.2
			m.seed = p_seed
			return m
		var a := _run(mk.call(7) as Pasture3DGraphNodePathShape, dense)
		var b := _run(mk.call(7) as Pasture3DGraphNodePathShape, dense)
		var c := _run(mk.call(8) as Pasture3DGraphNodePathShape, dense)
		var stable := a.points == b.points
		var varies := a.points != c.points
		rows.append("%s stable=%s varies=%s" % [title, str(stable), str(varies)])
		ok = ok and stable and varies
	print("    %s" % str(rows))
	_check("B", ok, "the same seed reproduces the path, and a different seed does not")


## [C] Resample at 1 m puts vertices 1 m apart AND keeps the line where it was.
##
## Both halves, because either alone is passable by a wrong implementation: a node that resampled the
## straight chord between the endpoints would have perfect spacing, and a node that returned its input
## untouched would have perfect arc length.
func _c_resample_spacing_and_arc_length() -> void:
	print("[C] Path Resample at 1 m: spacing is 1 m, and the arc length is preserved")
	var drawn := _drawn()
	var r := Pasture3DGraphNodePathResample.new()
	r.step = 1.0
	var got := _run(r, drawn)

	var worst_gap := 0.0
	for i in range(1, got.points.size()):
		# The final vertex is the line's end, which lands wherever the length ran out, so it is measured
		# as "no longer than a step" rather than "exactly a step".
		worst_gap = maxf(worst_gap, got.points[i].distance_to(got.points[i - 1]))
	var l_in := _length(drawn)
	var l_out := _length(got)
	var drift: float = absf(l_out - l_in)

	print("    %d vertices in, %d out; worst gap %.4f m; arc length %.3f -> %.3f m (drift %.4f)"
			% [drawn.points.size(), got.points.size(), worst_gap, l_in, l_out, drift])
	# LINEAR resampling walks the input polyline itself, so the output line IS the input line and the
	# arc length is preserved to float rounding, not to a cell. The spec allowed a cell; measuring the
	# tighter true property is what would catch a resample that quietly cut a corner.
	_check("C", got.points.size() > drawn.points.size() and worst_gap <= 1.0 + 1.0e-3
			and drift < 0.05,
			"%d vertices at most %.4f m apart, arc length preserved to %.4f m"
					% [got.points.size(), worst_gap, drift])


## [D] Meanderize LENGTHENS the line, and `remove_loops` leaves it clean.
##
## Length rather than appearance, for the reason the node's header gives: the sign error this algorithm
## invites straightens the river instead of mirroring it, and a straightened line still looks like a line.
## The loop half needs a fixture that actually loops, so the settings are deliberately past the point of
## good taste — a gentle meander would make the control vacuous by never crossing itself.
func _d_meanderize_lengthens_and_removes_loops() -> void:
	print("[D] Meanderize lengthens the line; remove_loops leaves no self-intersection")
	var dense := _dense()
	var l_in := _length(dense)

	var gentle := Pasture3DGraphNodePathMeanderize.new()
	gentle.iterations = 4
	gentle.ratio = 0.4
	gentle.noise_ratio = 0.1
	gentle.seed = 3
	var meandered := _run(gentle, dense)
	var l_out := _length(meandered)

	# Hard enough to tie itself in knots, so the control is not vacuous — and run on the SPARSE drawn line
	# rather than the dense one, because this gate's own `_self_intersects` is the naive pairwise scan and
	# is meant to stay an independent definition rather than grow the node's bucket index. Nine points
	# through four iterations is 144, which knots readily and scans instantly.
	var knotty := _drawn()
	var wild := func(p_remove: bool) -> Pasture3DGraphPath:
		var m := Pasture3DGraphNodePathMeanderize.new()
		m.iterations = 4
		m.ratio = 1.4
		m.noise_ratio = 0.5
		m.seed = 11
		m.edge_divisions = 3
		m.remove_loops = p_remove
		return _run(m, knotty)
	var cut: Pasture3DGraphPath = wild.call(true)
	var uncut: Pasture3DGraphPath = wild.call(false)
	var hits_cut := _self_intersects(cut)
	var hits_uncut := _self_intersects(uncut)

	print("    arc length %.1f -> %.1f m (x%.2f)" % [l_in, l_out, l_out / maxf(l_in, 1.0e-6)])
	print("    crossings with remove_loops on: %d; control, off: %d" % [hits_cut, hits_uncut])
	_check("D", l_out > l_in * 1.05 and hits_cut == 0 and hits_uncut > 0,
			"lengthened x%.2f, and %d crossings became 0" % [l_out / maxf(l_in, 1.0e-6), hits_uncut])


## [E] Widths and heights are carried onto the new vertices — and a path carrying none still carries none.
##
## The second half is the control, and it is the one that matters: an implementation that resized the
## arrays to the new vertex count would fill them with 0.0, and a HEIGHT array of zeros is not "no data",
## it is sea level. Every ridge drawn at 400 m would quietly come back at 0.
func _e_values_survive_a_reshape() -> void:
	print("[E] widths and heights are resampled onto the new vertices, and absent ones stay absent")
	var drawn := _drawn()
	var r := Pasture3DGraphNodePathResample.new()
	r.step = 3.0
	var got := _run(r, drawn)

	var sized := got.half_widths.size() == got.points.size() and got.heights.size() == got.points.size()
	# The values must be INTERPOLATED, not merely present: a range as wide as the input's, and inside it.
	var w_lo := INF
	var w_hi := -INF
	for v in got.half_widths:
		w_lo = minf(w_lo, v)
		w_hi = maxf(w_hi, v)
	var in_range: bool = w_lo >= 3.0 - 0.01 and w_hi <= 12.0 + 0.01 and (w_hi - w_lo) > 8.0

	# CONTROL: a path with no widths and no heights.
	var bare := Pasture3DGraphPath.new()
	bare.points = drawn.points
	var r2 := Pasture3DGraphNodePathResample.new()
	r2.step = 3.0
	var bare_out := _run(r2, bare)
	var stayed_empty := bare_out.half_widths.is_empty() and bare_out.heights.is_empty()

	print("    %d vertices, %d widths, %d heights; width range %.2f..%.2f m"
			% [got.points.size(), got.half_widths.size(), got.heights.size(), w_lo, w_hi])
	print("    control, a path with neither: %d widths, %d heights"
			% [bare_out.half_widths.size(), bare_out.heights.size()])
	_check("E", sized and in_range and stayed_empty,
			"carried and interpolated, and an empty array did not become zeros")


## [F] A reshape drops a solved road profile; Path Width keeps it.
##
## The alignment and the `sample_*` arrays describe a SPECIFIC centreline. Move the line and they describe
## somewhere else while `can_grade()` still answers true — a road silently graded to the profile of the
## path it used to be. Path Width is the control, and it is the half that proves the drop is a decision
## rather than the base class losing the fields.
func _f_a_reshape_drops_the_road_profile() -> void:
	print("[F] a reshape drops the solved road profile; Path Width keeps it")
	var drawn := _drawn()
	drawn.alignment = Pasture3DRoadAlignment.new()
	drawn.alignment.ds = 4.0
	drawn.alignment.s0 = 0.0
	var z := PackedFloat32Array()
	var half := PackedFloat32Array()
	for i in 40:
		z.append(100.0 - float(i))
		half.append(4.0)
	drawn.alignment.z = z
	drawn.sample_half_widths = half
	var graded_before := drawn.can_grade()

	var sm := Pasture3DGraphNodePathSmooth.new()
	sm.window = 4
	var smoothed := _run(sm, drawn)

	var pw := Pasture3DGraphNodePathWidth.new()
	pw.half_width = 9.0
	var widened := _run(pw, drawn)

	print("    input can_grade = %s; after Smooth = %s; after Path Width = %s"
			% [str(graded_before), str(smoothed.can_grade()), str(widened.can_grade())])
	_check("F", graded_before and not smoothed.can_grade() and widened.can_grade(),
			"the reshape dropped the profile and the width filter kept it")


## [G] A reshaped path does not cost more to QUERY than the vertices it added.
##
## ---- WHY THIS CRITERION EXISTS ----
##
## Everything above measures the shape of the answer. This measures what the answer costs the node that
## consumes it, which is the thing nobody downstream can see: Path Carve receives a polyline and has no
## way to tell 4000 vertices from 250, and the user sees only that the graph stopped responding.
##
## It caught a real one. `Pasture3DPathGeom` sized its bucket grid from the MEAN SEGMENT LENGTH, floored
## at 0.5 m. Meanderize turns a 250-point line into ~4000, the mean segment falls to 13 cm, the floor pins
## the cell at 0.5 m — and a uniform grid's cost is paid per RING, so a query 150 m from the line then
## walks 300 shells and visits ~90 000 bucket coordinates. For ONE cell. Measured at 128x128: 11.8 s, and
## at 512x512 it did not finish. The cell is now sized by the bounding box (about one segment per cell by
## area), and the same query is 47 ms.
##
## ---- WHY A RATIO AND NOT A BUDGET ----
##
## A millisecond budget measures the machine and fails on somebody else's laptop. The ratio against the
## SAME LINE before the reshape is the property that was actually wrong: 16x the vertices cost 2800x the
## query, and it should cost about 16x. The bound is set well above what a correct index does (~11x) and
## far below what the old one did, so the number in the print is the interesting part and the threshold
## only has to separate two answers three orders of magnitude apart.
func _g_a_reshaped_path_is_still_cheap_to_query() -> void:
	print("[G] a reshaped path costs no more to query than the vertices it added")
	var drawn := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	for i in 250:
		var f := float(i) / 249.0
		pts.append(Vector2(-200.0 + f * 400.0, 80.0 * sin(f * PI * 1.3)))
		w.append(20.0)
	drawn.points = pts
	drawn.half_widths = w

	var mea := Pasture3DGraphNodePathMeanderize.new()
	var river := _run(mea, drawn)
	var grew := float(river.points.size()) / float(drawn.points.size())

	var rect := Rect2(-256.0, -256.0, 512.0, 512.0)
	var t0 := Time.get_ticks_usec()
	Pasture3DUtil.path_query_grid(drawn.points, drawn.half_widths, 128, 128, rect, 1.0e9, 1.0e9,
			PackedFloat32Array())
	var t1 := Time.get_ticks_usec()
	Pasture3DUtil.path_query_grid(river.points, river.half_widths, 128, 128, rect, 1.0e9, 1.0e9,
			PackedFloat32Array())
	var t2 := Time.get_ticks_usec()
	var before: float = maxf(float(t1 - t0), 1.0)
	var after: float = float(t2 - t1)
	var slowdown: float = after / before

	print("    %d -> %d vertices (x%.1f); 128x128 query %.1f ms -> %.1f ms (x%.1f)"
			% [drawn.points.size(), river.points.size(), grew, before / 1000.0, after / 1000.0,
				slowdown])
	print("    control, the bound: x%.0f. The formula this replaced measured x2800 here." % 40.0)
	_check("G", river.points.size() > drawn.points.size() * 4 and slowdown < 40.0,
			"the reshape multiplied the vertices and the query cost followed them, not their square")
