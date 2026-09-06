# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathDeriveGate — the three GRID → PATH nodes (S7a).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5, §8.4. Path Drape, Path Width from Field and Path from Flow read a
# grid the graph is building and produce geometry from it. That inversion is what the S4 pre-pass cannot
# serve, and every criterion here exists because some part of it is silent when wrong:
#
#   [A] a draped path's heights equal the surface at its vertices. Control: the SAME path, undraped,
#       does not — otherwise a drape that did nothing would pass on a fixture whose authored heights
#       happened to be near the ground.
#   [B] force-downhill gives a non-increasing height sequence, on a fixture that RISES. Control: the
#       same drape without it rises, which is what makes the fixture a test rather than a tautology.
#   [C] widths read off a field widen downstream. Control: a constant field gives a constant width, so
#       the criterion is measuring the remap and not the node's default.
#   [D] each of the three takes the graph OFF the native tier, asserted through `native_supported()`
#       directly. Control: the same graph without the node lowers. A bail nobody verifies is a bail that
#       quietly stopped happening (`op-ids-omission-drops-graph-to-gdscript` is the other way this fails,
#       and the reason the three ops are in `graph_op_ids` despite never reaching a native compile).
#   [E] Path from Flow follows the MAIN STEM and comes back running downstream. Two halves, because a
#       trace that took the tributary at the confluence is still a river-shaped line, and one left
#       un-reversed is still the right set of points.
#   [F] the memo re-derives when the field changes and NOT otherwise. This is the criterion the whole
#       `path_eval_salt` mechanism exists for: `_resolved_path_of` keys on path digests and node
#       revisions, and an erosion re-solving above moves neither, so without the salt a river would be
#       traced once and served forever (`memoised-programs-hide-invalidation`).
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F"]

const GW := 96
const GH := 96
const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathDeriveGate: grid-reading geometry (S7a) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5, §8.4")

	_a_a_drape_takes_the_surfaces_heights()
	_b_force_downhill_never_rises()
	_c_width_from_a_field_widens_downstream()
	_d_each_derive_takes_the_graph_off_native()
	_e_a_traced_river_follows_the_main_stem()
	_f_the_memo_re_derives_only_when_the_field_moves()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH DERIVE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## The world XZ of a cell centre, in the evaluator's own convention. Written here rather than borrowed
## from the node under test: a gate that shares the code's idea of where a cell is cannot catch a half-
## cell shift, which is exactly the mistake `sample_grid`'s comment warns about.
func _centre(p_ix: int, p_iz: int) -> Vector2:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	return Vector2(RECT.position.x + (float(p_ix) + 0.5) * dx, RECT.position.y + (float(p_iz) + 0.5) * dz)


## A surface that FALLS with +x and has a cross-slope, so a drape onto it is distinguishable from a
## constant in both axes and a path running +x runs downhill.
func _falling_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _centre(ix, iz)
			g[iz * GW + ix] = 100.0 - 0.15 * w.x + 0.04 * w.y
	return g


## The same, RISING with +x. [B]'s fixture: a path drawn along +x on this ground climbs, so a drape that
## quietly sorted its heights, or one whose clamp ran the wrong way, is visible.
func _rising_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _centre(ix, iz)
			g[iz * GW + ix] = 40.0 + 0.15 * w.x + 0.04 * w.y
	return g


## A field rising with +x, standing in for flow accumulation in [C].
##
## A controlled ramp rather than a real Erosion solve, deliberately: what [C] measures is the REMAP from
## field value to half-width, and an erosion field would put the solver's own behaviour inside the
## measurement — it has `ErosionGate` for that, and a criterion that fails for two possible reasons
## names neither.
func _ramp_field() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			g[iz * GW + ix] = clampf((_centre(ix, iz).x + 200.0) / 400.0, 0.0, 1.0)
	return g


func _constant_field(p_v: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	g.fill(p_v)
	return g


## A flow-accumulation field with a MAIN STEM and a weaker TRIBUTARY meeting it.
##
## The confluence is the whole point of the fixture. A trace that steps to the highest neighbour follows
## the stem; one that steps to any neighbour above threshold, or that breaks a tie by scan order, takes
## the tributary and produces a line that still looks like a river.
func _confluence_field() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	g.fill(0.0)
	var mid := GH / 2
	# Main stem: straight along +x at z = mid, accumulation growing downstream.
	for ix in GW:
		var a: float = 1.0 + 9.0 * float(ix) / float(GW - 1)
		g[mid * GW + ix] = a
		# A shoulder either side, well below the stem, so the walk has real neighbours to reject rather
		# than a channel one cell wide with nothing but zeros around it.
		if mid > 0:
			g[(mid - 1) * GW + ix] = a * 0.25
		if mid + 1 < GH:
			g[(mid + 1) * GW + ix] = a * 0.25
	# Tributary: a diagonal joining the stem at the halfway point, always weaker than the stem there.
	var join := GW / 2
	for k in range(1, mini(join, mid)):
		var ix := join - k
		var iz := mid - k
		if ix >= 0 and iz >= 0:
			g[iz * GW + ix] = maxf(g[iz * GW + ix], 0.5 + 3.0 * float(ix) / float(GW - 1))
	return g


## A drawn line running +x across the middle of the domain, with FLAT authored heights.
##
## Flat on purpose: [A]'s control is that the undraped path does not match the ground, and a fixture
## whose authored heights were already near the surface would make that control weak.
func _line() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var h := PackedFloat32Array()
	var w := PackedFloat32Array()
	for i in 17:
		var f := float(i) / 16.0
		pts.append(Vector2(-150.0 + f * 300.0, 30.0 * sin(f * PI)))
		h.append(0.0)
		w.append(5.0)
	p.points = pts
	p.heights = h
	p.half_widths = w
	return p


func _source(p_path: Pasture3DGraphPath) -> Pasture3DGraphNodeSplineSource:
	var s := Pasture3DGraphNodeSplineSource.new()
	s.path = p_path
	return s


func _carve() -> Pasture3DGraphNodePathCarve:
	var c := Pasture3DGraphNodePathCarve.new()
	c.cross_section = Pasture3DGraphNodePathCarve.CrossSection.BED
	c.blend = Pasture3DGraphNodePathCarve.Blend.MIN
	c.width_source = Pasture3DGraphNodePathCarve.WidthSource.PATH
	c.follow_path_height = true
	c.offset = 0.0
	return c


## Input → derive.grid, Source → derive.path, derive → Carve.path, Input → Carve.surface, Carve → Output.
##
## The carve is not decorative: a derive node whose path nothing consumes is never asked for one, so
## `eval_path` would not run and the gate would measure an object that was only ever constructed.
func _chain(p_derive: Pasture3DGraphNodePathDerive, p_path: Pasture3DGraphPath) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(p_path), p_derive, _carve(),
		Pasture3DGraphNodeOutput.new()]
	g.nodes = ns
	g.connections = [
		[0, 0, 2, 1],  # Input  -> derive port 1 (surface / field)
		[1, 0, 2, 0],  # Source -> derive port 0 (path)
		[2, 0, 3, 1],  # derive -> Carve.path
		[0, 0, 3, 0],  # Input  -> Carve.surface
		[3, 0, 4, 0],  # Carve  -> Output
	]
	return g


## The Path from Flow shape: it has no path input, so the source is gone and the flow goes to port 0.
func _flow_chain(p_node: Pasture3DGraphNodePathFromFlow) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), p_node, _carve(), Pasture3DGraphNodeOutput.new()]
	g.nodes = ns
	g.connections = [
		[0, 0, 1, 0],  # Input -> flow
		[1, 0, 2, 1],  # trace -> Carve.path
		[0, 0, 2, 0],  # Input -> Carve.surface
		[2, 0, 3, 0],
	]
	return g


func _drape(p_downhill: bool, p_drop: float = 0.001) -> Pasture3DGraphNodePathDrape:
	var d := Pasture3DGraphNodePathDrape.new()
	d.force_downhill = p_downhill
	d.min_drop = p_drop
	return d


## Bilinear read of a grid, written independently of the node's own sampler for the reason `_centre` is.
func _sample(p_grid: PackedFloat32Array, p_w: Vector2) -> float:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	var fx: float = (p_w.x - (RECT.position.x + 0.5 * dx)) / dx
	var fz: float = (p_w.y - (RECT.position.y + 0.5 * dz)) / dz
	var x0 := clampi(int(floor(fx)), 0, GW - 1)
	var z0 := clampi(int(floor(fz)), 0, GH - 1)
	var x1 := clampi(x0 + 1, 0, GW - 1)
	var z1 := clampi(z0 + 1, 0, GH - 1)
	var tx: float = clampf(fx - floor(fx), 0.0, 1.0)
	var tz: float = clampf(fz - floor(fz), 0.0, 1.0)
	return lerpf(
		lerpf(p_grid[z0 * GW + x0], p_grid[z0 * GW + x1], tx),
		lerpf(p_grid[z1 * GW + x0], p_grid[z1 * GW + x1], tx), tz)


# ---- criteria -----------------------------------------------------------------------------------

## [A] the draped path's heights are the surface at its vertices. Control: undraped, they are not.
func _a_a_drape_takes_the_surfaces_heights() -> void:
	var surf := _falling_surface()
	var line := _line()
	var d := _drape(false)
	var g := _chain(d, line)
	g.evaluate(GW, GH, RECT, null, surf)

	var out: Pasture3DGraphPath = d.derived_path()
	_check("A", d.capture_count > 0 and out != null and out.points.size() == line.points.size(),
			"the derive captured %d grid(s) and produced %d vertex(es)"
			% [d.capture_count, 0 if out == null else out.points.size()])
	if out == null:
		return

	var worst := 0.0
	for i in out.points.size():
		worst = maxf(worst, absf(out.heights[i] - _sample(surf, out.points[i])))
	# One tenth of a millimetre. The two samplers are written independently but implement the same
	# bilinear read, so anything above float noise here is a real disagreement about WHERE a cell is.
	_check("A", worst < 1.0e-4, "draped heights match the surface at every vertex: worst %.6f m" % worst)

	var worst_undraped := 0.0
	for i in line.points.size():
		worst_undraped = maxf(worst_undraped, absf(line.heights[i] - _sample(surf, line.points[i])))
	_check("A", worst_undraped > 10.0,
			"CONTROL the undraped line does NOT match the ground: worst %.2f m" % worst_undraped)


## [B] force-downhill produces a non-increasing sequence on ground that rises. Control: without it, the
## same drape rises.
func _b_force_downhill_never_rises() -> void:
	var surf := _rising_surface()
	var line := _line()

	var plain := _drape(false)
	var g1 := _chain(plain, line)
	g1.evaluate(GW, GH, RECT, null, surf)
	var undamped: Pasture3DGraphPath = plain.derived_path()

	var rises := 0
	for i in range(1, undamped.heights.size()):
		if undamped.heights[i] > undamped.heights[i - 1]:
			rises += 1
	_check("B", rises > 0,
			"CONTROL the fixture climbs: %d of %d step(s) rise without force-downhill"
			% [rises, undamped.heights.size() - 1])

	var drop := 0.01
	var forced := _drape(true, drop)
	var g2 := _chain(forced, line)
	g2.evaluate(GW, GH, RECT, null, surf)
	var out: Pasture3DGraphPath = forced.derived_path()

	var bad := 0
	var worst_gap := 0.0
	for i in range(1, out.heights.size()):
		var run: float = out.points[i].distance_to(out.points[i - 1])
		var want: float = out.heights[i - 1] - drop * run
		if out.heights[i] > want + 1.0e-4:
			bad += 1
		worst_gap = maxf(worst_gap, out.heights[i] - want)
	_check("B", bad == 0,
			"forced: 0 step(s) rise and every one falls at least %.3f m/m — worst overshoot %.6f m"
			% [drop, worst_gap])

	# It LOWERS and never raises: the clamp is one-sided, and a symmetric smoothing would pass the
	# monotonicity test above while lifting the head of the line off the ground it was draped onto.
	var lifted := 0
	for i in out.heights.size():
		if out.heights[i] > undamped.heights[i] + 1.0e-4:
			lifted += 1
	_check("B", lifted == 0, "the clamp only ever lowers: %d vertex(es) raised (want 0)" % lifted)


## [C] widths read off a field widen downstream. Control: a constant field gives a constant width.
func _c_width_from_a_field_widens_downstream() -> void:
	var line := _line()

	var n := Pasture3DGraphNodePathWidthField.new()
	n.field_min = 0.0
	n.field_max = 1.0
	n.half_width_min = 2.0
	n.half_width_max = 20.0
	var g := _chain(n, line)
	g.evaluate(GW, GH, RECT, null, _ramp_field())
	var out: Pasture3DGraphPath = n.derived_path()

	var falls := 0
	for i in range(1, out.half_widths.size()):
		if out.half_widths[i] < out.half_widths[i - 1] - 1.0e-5:
			falls += 1
	var first: float = out.half_widths[0]
	var last: float = out.half_widths[out.half_widths.size() - 1]
	_check("C", falls == 0 and last > first + 5.0,
			"widths grow monotonically downstream: %.2f m -> %.2f m, %d reversal(s)"
			% [first, last, falls])

	# The endpoints are the remap's own endpoints, not merely bigger numbers: the line spans x = -150 to
	# +150 of a field defined over -200..+200, so the ends read 0.125 and 0.875 of the range.
	var want_first: float = lerpf(2.0, 20.0, 0.125)
	var want_last: float = lerpf(2.0, 20.0, 0.875)
	_check("C", absf(first - want_first) < 0.1 and absf(last - want_last) < 0.1,
			"and they are the mapped values, not just larger: want %.2f / %.2f m" % [want_first, want_last])

	var c := Pasture3DGraphNodePathWidthField.new()
	c.field_min = 0.0
	c.field_max = 1.0
	c.half_width_min = 2.0
	c.half_width_max = 20.0
	var g2 := _chain(c, line)
	g2.evaluate(GW, GH, RECT, null, _constant_field(0.5))
	var flat: Pasture3DGraphPath = c.derived_path()
	var spread := 0.0
	for i in flat.half_widths.size():
		spread = maxf(spread, absf(flat.half_widths[i] - flat.half_widths[0]))
	_check("C", spread < 1.0e-4 and absf(flat.half_widths[0] - 11.0) < 0.01,
			"CONTROL a constant field gives one width everywhere: %.2f m, spread %.6f m"
			% [flat.half_widths[0], spread])


## [D] each of the three takes the graph off the native tier, and the same graph without it lowers.
func _d_each_derive_takes_the_graph_off_native() -> void:
	var line := _line()

	# The control FIRST: without it, "not native" is unfalsifiable — a graph that never lowered for an
	# unrelated reason would report three passes and measure nothing.
	var bare := Pasture3DTerrainGraph.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(line), _carve(), Pasture3DGraphNodeOutput.new()]
	bare.nodes = ns
	bare.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
	_check("D", bare.native_supported(),
			"CONTROL Source -> Carve -> Output lowers natively: native_supported = %s"
			% bare.native_supported())

	for entry in [
		["Path Drape", _drape(false)],
		["Path Width from Field", Pasture3DGraphNodePathWidthField.new()],
	]:
		var g := _chain(entry[1], line)
		_check("D", not g.native_supported() and entry[1].blocks_native(),
				"%s: native_supported = %s, blocks_native = %s (want false, true)"
				% [entry[0], g.native_supported(), entry[1].blocks_native()])

	var f := Pasture3DGraphNodePathFromFlow.new()
	var gf := _flow_chain(f)
	_check("D", not gf.native_supported() and f.blocks_native(),
			"Path from Flow: native_supported = %s, blocks_native = %s (want false, true)"
			% [gf.native_supported(), f.blocks_native()])


## [E] the trace follows the main stem, and comes back running downstream.
func _e_a_traced_river_follows_the_main_stem() -> void:
	var field := _confluence_field()
	var n := Pasture3DGraphNodePathFromFlow.new()
	n.seed_mode = Pasture3DGraphNodePathFromFlow.Seed.OUTLET
	n.min_flow = 1.5
	n.step_cells = 1
	n.half_width = 3.0
	var g := _flow_chain(n)
	g.evaluate(GW, GH, RECT, null, field)
	var out: Pasture3DGraphPath = n.derived_path()

	_check("E", out != null and out.points.size() > 8,
			"the trace produced a line: %d vertex(es)" % [0 if out == null else out.points.size()])
	if out == null:
		return

	# DOWNSTREAM: the flow under vertex 0 is the smallest and under the last the largest. Measured on the
	# field rather than on x, so a trace that happened to run +x for another reason cannot pass.
	var f0: float = _sample(field, out.points[0])
	var f1: float = _sample(field, out.points[out.points.size() - 1])
	_check("E", f1 > f0 + 5.0,
			"it runs downstream after the reversal: flow %.2f at the head, %.2f at the mouth" % [f0, f1])

	# MAIN STEM: every vertex sits on the straight channel at z = mid, not on the diagonal tributary.
	var mid_z: float = _centre(0, GH / 2).y
	var off := 0
	var worst_off := 0.0
	for p in out.points:
		var d: float = absf(p.y - mid_z)
		worst_off = maxf(worst_off, d)
		if d > RECT.size.y / float(GH) * 1.5:
			off += 1
	_check("E", off == 0,
			"every vertex is on the main stem, not the tributary: %d off-channel, worst %.2f m from it"
			% [off, worst_off])

	var c := Pasture3DGraphNodePathFromFlow.new()
	# Above the field's own maximum of 10: there is no river here to find.
	c.min_flow = 50.0
	var g2 := _flow_chain(c)
	g2.evaluate(GW, GH, RECT, null, field)
	var none: Pasture3DGraphPath = c.derived_path()
	_check("E", none == null,
			"CONTROL Min Flow above the field's maximum traces nothing: %s"
			% ["null" if none == null else "%d vertex(es)" % none.points.size()])


## [F] the memo re-derives when the field moves and not otherwise. See the header: this is the criterion
## `path_eval_salt` exists for, and the failure it prevents is invisible in the terrain of the FIRST bake.
func _f_the_memo_re_derives_only_when_the_field_moves() -> void:
	var line := _line()
	var d := _drape(false)
	var g := _chain(d, line)
	var surf := _falling_surface()

	g.evaluate(GW, GH, RECT, null, surf)
	var after_first: int = d.eval_path_count
	var first_path: Pasture3DGraphPath = d.derived_path()
	var h_first: float = first_path.heights[0]
	var baseline: int = d.eval_path_count

	# Same surface again. The whole point of the memo: nothing upstream moved, so nothing re-derives.
	g.evaluate(GW, GH, RECT, null, surf)
	_check("F", d.eval_path_count == baseline,
			"an unchanged field re-derives nothing: eval_path stayed at %d (first bake used %d)"
			% [d.eval_path_count, after_first])

	# A DIFFERENT surface. Neither the input path's digest nor the node's revision has moved — only the
	# grid — so this is the case the salt is the only thing carrying.
	var moved := _falling_surface()
	for i in moved.size():
		moved[i] += 25.0
	g.evaluate(GW, GH, RECT, null, moved)
	var h_second: float = d.derived_path().heights[0]
	_check("F", d.eval_path_count > baseline,
			"a changed field re-derives: eval_path %d -> %d" % [baseline, d.eval_path_count])
	_check("F", absf((h_second - h_first) - 25.0) < 1.0e-3,
			"and the new heights are the NEW ground: %.3f m -> %.3f m (want +25.000)"
			% [h_first, h_second])
