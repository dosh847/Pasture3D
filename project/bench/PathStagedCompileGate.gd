# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathStagedCompileGate — the staged compile (S7b).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §8.4. S7a made the three GRID → PATH nodes correct by taking the whole
# graph off the native tier. S7b cuts the program at those nodes instead: each derive's grid inputs are
# evaluated first, that produces its path, and the remainder is then compiled with the path in the
# geometry table. The terrain must not move, and the kernel must be the thing that made it.
#
# ---- WHY "THE TERRAIN AGREES" IS NOT THE CRITERION ----
#
# Two routes agreeing is also what you get when the staged route silently fell through to the S7a one —
# which is the most likely way this ships broken, because it is a fall-through and not a fault. So [A]
# asserts the ROUTE (`staged_compile_count`) as well as the answer, and [C] asserts the derive node still
# contributes, because two routes that both ignore the drape also agree perfectly.
#
#   [A] a graph containing a derive node runs the staged route AND matches the S7a reference bit for bit.
#       Control: the S7a route is still reachable — `force_no_staged_compile` — and produces that
#       reference, so the comparison has two live routes and not one route measured twice.
#   [B] the path re-derives when the FIRST stage's input moves, and does NOT when only the remainder's
#       parameters do — with the terrain moving in both cases. A staged compile that re-derived on
#       everything would be correct and pointless; one that re-derived on nothing would be fast and
#       wrong, and only the pair separates them.
#   [C] the derive node still contributes: the staged terrain differs by metres from the same graph
#       carved off the undraped line.
#   [D] `native_supported()` still answers FALSE for these graphs. That is not a leftover — it is the
#       off-thread contract: a program compiled without staging carries a path that was never produced,
#       so "can this be handed to a worker" and "can evaluate() use the kernel for this" are genuinely
#       different questions and S7b answers only the second.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D"]

const GW := 64
const GH := 64
const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathStagedCompileGate: the staged compile (S7b) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §8.4")

	_a_a_staged_graph_takes_the_kernel_and_agrees()
	_b_each_stage_invalidates_what_it_owns()
	_c_the_derive_still_contributes()
	_d_native_supported_still_refuses()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH STAGED COMPILE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

func _centre(p_ix: int, p_iz: int) -> Vector2:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	return Vector2(RECT.position.x + (float(p_ix) + 0.5) * dx, RECT.position.y + (float(p_iz) + 0.5) * dz)


## A surface with relief in both axes. Flat ground would make a drape indistinguishable from a constant,
## and then [A]'s agreement would be a statement about two ways of writing the same number.
func _surface(p_lift: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _centre(ix, iz)
			g[iz * GW + ix] = p_lift + 80.0 - 0.12 * w.x + 0.05 * w.y + 12.0 * sin(w.x * 0.02)
	return g


func _line() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var h := PackedFloat32Array()
	var w := PackedFloat32Array()
	for i in 17:
		var f := float(i) / 16.0
		pts.append(Vector2(-150.0 + f * 300.0, 30.0 * sin(f * PI)))
		h.append(0.0)
		w.append(14.0)
	p.points = pts
	p.heights = h
	p.half_widths = w
	return p


## Input → Drape.surface, Source → Drape.path, Drape → Carve.path, Input → Carve.surface, Carve → Output.
##
## Two stages by construction: the drape is the cut, everything above it is stage one and the carve is
## the remainder. `p_drape = false` builds the same graph with the drape taken out, which is [C]'s
## control and the only way to tell a contributing derive from a decorative one.
## `p_offset` is POSITIVE and that is not a detail: the kernel negates it for a BED, so a negative offset
## raises the floor ABOVE the line, and MIN then keeps the ground. The first version of this fixture used
## -8.0 and carved nothing at all — [A] passed, comparing two routes that had both done nothing.
func _graph(p_drape: bool, p_offset: float = 6.0) -> Dictionary:
	var g := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = _line()
	var carve := Pasture3DGraphNodePathCarve.new()
	carve.cross_section = Pasture3DGraphNodePathCarve.CrossSection.BED
	carve.blend = Pasture3DGraphNodePathCarve.Blend.MIN
	carve.width_source = Pasture3DGraphNodePathCarve.WidthSource.PATH
	carve.follow_path_height = true
	carve.offset = p_offset
	if not p_drape:
		var ns0: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), src, carve, Pasture3DGraphNodeOutput.new()]
		g.nodes = ns0
		g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
		return {"graph": g, "carve": carve, "drape": null}
	var drape := Pasture3DGraphNodePathDrape.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, drape, carve, Pasture3DGraphNodeOutput.new()]
	g.nodes = ns
	g.connections = [[0, 0, 2, 1], [1, 0, 2, 0], [2, 0, 3, 1], [0, 0, 3, 0], [3, 0, 4, 0]]
	return {"graph": g, "carve": carve, "drape": drape}


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		var na := is_nan(p_a[i])
		var nb := is_nan(p_b[i])
		if na or nb:
			if na != nb:
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


# ---- criteria -----------------------------------------------------------------------------------

## [A] the staged route runs, uses the kernel, and agrees with the S7a route.
func _a_a_staged_graph_takes_the_kernel_and_agrees() -> void:
	var surf := _surface(0.0)

	var staged := _graph(true)
	var gs: Pasture3DTerrainGraph = staged["graph"]
	var a: PackedFloat32Array = gs.evaluate(GW, GH, RECT, null, surf)
	_check("A", gs.staged_compile_count == 1,
			"the staged route ran and reached the kernel: staged_compile_count = %d (want 1)"
			% gs.staged_compile_count)

	# The CONTROL first, and it is a real second route rather than a re-read: force_no_staged_compile
	# sends an identical graph down S7a's whole-graph GDScript bail.
	var ref := _graph(true)
	var gr: Pasture3DTerrainGraph = ref["graph"]
	gr.force_no_staged_compile = true
	var b: PackedFloat32Array = gr.evaluate(GW, GH, RECT, null, surf)
	_check("A", gr.staged_compile_count == 0 and not b.is_empty(),
			"CONTROL the S7a route is still reachable: staged_compile_count = %d, %d cell(s)"
			% [gr.staged_compile_count, b.size()])

	# 1 mm. The two routes rasterise the same carve from the same polyline through the same kernel entry
	# point, so this is float noise or a real disagreement, with very little in between.
	var w := _worst(a, b)
	_check("A", w < 1.0e-3, "staged and S7a carve the same terrain: worst %.6f m over %d cell(s)"
			% [w, a.size()])


## [B] the first stage's input invalidates the path; the remainder's parameters do not — and the terrain
## moves for both.
func _b_each_stage_invalidates_what_it_owns() -> void:
	var built := _graph(true)
	var g: Pasture3DTerrainGraph = built["graph"]
	var drape: Pasture3DGraphNodePathDrape = built["drape"]
	var carve: Pasture3DGraphNodePathCarve = built["carve"]
	var surf := _surface(0.0)

	var t0: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, surf)
	var base: int = drape.eval_path_count
	var h0: float = drape.derived_path().heights[0]

	# Nothing changes: the path must not re-derive, and the terrain must not move.
	var t_same: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, surf)
	_check("B", drape.eval_path_count == base and _worst(t0, t_same) == 0.0,
			"an unchanged graph re-derives nothing and moves nothing: eval_path %d, worst %.6f m"
			% [drape.eval_path_count, _worst(t0, t_same)])

	# Stage ONE moves: a different input surface. The path is draped onto it, so it must re-derive.
	var lifted := _surface(30.0)
	var t_lift: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, lifted)
	var h1: float = drape.derived_path().heights[0]
	_check("B", drape.eval_path_count > base and absf((h1 - h0) - 30.0) < 1.0e-3,
			"stage 1 moves -> the path re-derives onto the new ground: eval_path %d -> %d, head %.3f -> %.3f m"
			% [base, drape.eval_path_count, h0, h1])
	_check("B", _worst(t0, t_lift) > 1.0, "and the terrain moves with it: worst %.2f m" % _worst(t0, t_lift))

	# Only the REMAINDER moves: a carve parameter. The line is where it was, so re-deriving it would be
	# work with no possible effect — and the terrain must still change, or the criterion is measuring a
	# knob that does nothing.
	var after: int = drape.eval_path_count
	carve.offset = 24.0
	var t_off: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, lifted)
	_check("B", drape.eval_path_count == after,
			"only the remainder moves -> the path is NOT re-derived: eval_path stayed at %d"
			% drape.eval_path_count)
	_check("B", _worst(t_lift, t_off) > 1.0,
			"and the terrain still moves: worst %.2f m" % _worst(t_lift, t_off))


## [C] the derive contributes. Without it, [A]'s agreement is two routes both ignoring the drape.
func _c_the_derive_still_contributes() -> void:
	var surf := _surface(0.0)
	var with_drape := _graph(true)
	var without := _graph(false)
	var a: PackedFloat32Array = (with_drape["graph"] as Pasture3DTerrainGraph).evaluate(GW, GH, RECT, null, surf)
	var b: PackedFloat32Array = (without["graph"] as Pasture3DTerrainGraph).evaluate(GW, GH, RECT, null, surf)
	# The undraped line sits at y = 0 and the ground is 60-140 m up, so a carve following it digs to sea
	# level. Metres, not millimetres, is the only honest threshold here.
	_check("C", _worst(a, b) > 10.0,
			"the drape changes the carve: worst %.2f m against the same graph without it" % _worst(a, b))
	_check("C", (without["graph"] as Pasture3DTerrainGraph).staged_compile_count == 0,
			"CONTROL the drape-less graph stages nothing: staged_compile_count = %d"
			% (without["graph"] as Pasture3DTerrainGraph).staged_compile_count)


## [D] `native_supported()` still refuses. See the header: it is the off-thread contract, not a leftover.
func _d_native_supported_still_refuses() -> void:
	var built := _graph(true)
	var g: Pasture3DTerrainGraph = built["graph"]
	_check("D", not g.native_supported(),
			"a graph with a derive node still refuses a single-program compile: native_supported = %s"
			% g.native_supported())
	var bare := _graph(false)
	_check("D", (bare["graph"] as Pasture3DTerrainGraph).native_supported(),
			"CONTROL the same graph without it lowers: native_supported = %s"
			% (bare["graph"] as Pasture3DTerrainGraph).native_supported())
