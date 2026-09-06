# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathPrePassGate — the S4 path pre-pass, and Path Width as its first customer.
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §8.2-8.3. Before S4 a PATH was read straight off the node that HELD one,
# so a PATH -> PATH filter could be wired, could look right in the editor, and could contribute nothing.
# The pre-pass resolves the PATH sub-DAG first and hands each consumer the path that was PRODUCED.
#
# ---- WHY "IT LOOKS RIGHT" IS THE WHOLE PROBLEM HERE ----
#
# Every failure this phase can have is silent. A filter that does not run still yields a carved ridge —
# just the width the spline was drawn at. A filter that runs but is not lowered still yields the right
# terrain — on the GDScript evaluator, at ten times the cost, which is exactly the bug that hid the
# missing `spline_source` op id for four phases. And a filter that re-runs on every evaluation yields the
# right answer too, while allocating a fresh path each time and costing the geometry table's fanout.
#
# So no criterion here is allowed to rest on the output being correct:
#
#   [A] asserts `native_supported()` DIRECTLY, not that the result looks right. That is the exact check
#       whose absence let a whole graph run unaccelerated (memory: op-ids-omission-drops-graph-to-gdscript
#       and graph-gpu-bail-is-graph-wide — only a direct call proves which route was taken).
#   [B] counts geometry-table ENTRIES, which is the thing fanout is about; the terrain is identical
#       either way.
#   [C] counts `eval_path` CALLS, because a memo that never hits and one that always hits return the
#       same path.
#
# and each carries a control that fails: the same fixture with the pre-pass switched off, with two
# filters instead of one, and with the width edited between evaluations.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C"]

const GW: int = 96
const GH: int = 96
const G_MIN: float = -48.0
const RECT := Rect2(G_MIN, G_MIN, 96.0, 96.0)
const EPS: float = 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathPrePassGate: the PATH pre-pass and Path Width (S4) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §8.2-8.3, §7.3")

	_a_a_filtered_chain_lowers_natively_and_agrees()
	_b_fanout_is_one_geometry_entry()
	_c_eval_path_is_memoised()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH PRE-PASS %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## Sloping, bumpy ground — the same shape PathCarveGate uses, and for its reasons: a flat fixture makes a
## two-reference drape indistinguishable from a one-reference one, so a carve over it proves less than it
## appears to.
func _terrain() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var wx := G_MIN + float(ix) + 0.5
			var wz := G_MIN + float(iz) + 0.5
			s[iz * GW + ix] = (0.12 * wx + 0.05 * wz
					+ 3.0 * sin(wx * 0.17) * cos(wz * 0.11)
					+ 1.2 * sin(wx * 0.53 + wz * 0.31))
	return s


## A NARROW drawn spline, on purpose. Path Width is going to set 14 m, and a fixture already near that
## would make a filter that silently did nothing agree with one that worked.
func _spline() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 9:
		var f := float(i) / 8.0
		pts.append(Vector2(-34.0 + f * 68.0, -18.0 + 26.0 * sin(f * PI)))
		w.append(2.0)
		h.append(4.0 + 9.0 * f)
	path.points = pts
	path.half_widths = w
	path.heights = h
	return path


func _source(p_path: Pasture3DGraphPath) -> Pasture3DGraphNodeSplineSource:
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = p_path
	return src


func _width(p_half: float) -> Pasture3DGraphNodePathWidth:
	var w := Pasture3DGraphNodePathWidth.new()
	w.mode = Pasture3DGraphNodePathWidth.Mode.SET
	w.half_width = p_half
	return w


func _carve() -> Pasture3DGraphNodePathCarve:
	var c := Pasture3DGraphNodePathCarve.new()
	c.cross_section = Pasture3DGraphNodePathCarve.CrossSection.CREST
	# WIDTH_PATH, not a constant: the whole point is that the carve takes its width from the path it is
	# handed, so a constant here would make the filter unobservable no matter what it did.
	c.width_source = Pasture3DGraphNodePathCarve.WidthSource.PATH
	c.flat_width = 0.0
	c.offset = 6.0
	c.blend = Pasture3DGraphNodePathCarve.Blend.REPLACE
	return c


## Input -> Carve.surface, Source -> [Width ->] Carve.path, Carve -> Output.
func _chain(p_path: Pasture3DGraphPath, p_half: float, p_filtered: bool) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	if p_filtered:
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _source(p_path), _width(p_half), _carve(),
			Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [[0, 0, 3, 0], [1, 0, 2, 0], [2, 0, 3, 1], [3, 0, 4, 0]]
	else:
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _source(p_path), _carve(),
			Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
	return g


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
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

## [A] Source -> Width -> Carve lowers NATIVELY, and the native and GDScript routes carve the same
## terrain. Both halves are needed: agreement alone is also what two routes that both ignore the filter
## produce, and lowering alone says nothing about the answer.
##
## Two controls, because there are two ways for this to be vacuous:
##
##   1. the filter contributing NOTHING — measured against the same chain with the filter removed, which
##      must differ by metres, not by rounding;
##   2. the PRE-PASS not being the reason it contributed — measured by switching it off, which makes
##      every node answer with the path it holds (a filter holds none) and must change the terrain.
##
## The direct `native_supported()` assertion is the one this project has paid for twice: a graph that
## silently fell to the GDScript evaluator produced correct output the whole time.
func _a_a_filtered_chain_lowers_natively_and_agrees() -> void:
	print("[A] Source -> Path Width -> Path Carve lowers natively and agrees with the GDScript route")
	var surf := _terrain()
	var g := _chain(_spline(), 14.0, true)
	var lowers: bool = g.native_supported()
	var prog := g.compile_graph_program()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surf)

	var g2 := _chain(_spline(), 14.0, true)
	g2.force_gdscript_evaluation = true
	var ora: PackedFloat32Array = g2.evaluate(GW, GH, RECT, null, surf)
	var agree := _worst(nat, ora)

	# CONTROL 1: the same chain without the filter at all.
	var g3 := _chain(_spline(), 14.0, false)
	var bare: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g3.compile_graph_program(), GW, GH,
			RECT, surf)
	var d_bare := _worst(nat, bare)

	# CONTROL 2: the filter present, the pre-pass off. The carve then sees the filter's `path_output()`,
	# which is null, so it has no path at all and passes the surface through.
	var g4 := _chain(_spline(), 14.0, true)
	g4.force_no_path_prepass = true
	var off: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g4.compile_graph_program(), GW, GH,
			RECT, surf)
	var d_off := _worst(nat, off)

	print("    native_supported = %s, program = %s, %d cell(s)"
			% [str(lowers), "compiled" if not prog.is_empty() else "EMPTY", nat.size()])
	print("    worst |native - gdscript| = %.7f m; vs no filter = %.3f m; vs pre-pass off = %.3f m"
			% [agree, d_bare, d_off])
	_check("A", lowers and not prog.is_empty() and nat.size() == GW * GH and agree < EPS
			and d_bare > 1.0 and d_off > 1.0,
			"lowered, agreed to %.7f m, and the filter moved the ground by %.3f m" % [agree, d_bare])


## [B] Two carves reading ONE Path Width name ONE geometry entry.
##
## Fanout is the reason the table is deduplicated by instance at all, and S4 is where it becomes possible
## to lose: a filter that allocated a fresh path per call would give each consumer its own entry, and the
## terrain would be identical, so nothing but a count can see it.
##
## The control is two SEPARATE filters on one source, which must give TWO entries — otherwise the dedup
## is not deduplicating by instance, it is collapsing everything.
func _b_fanout_is_one_geometry_entry() -> void:
	print("[B] two consumers of one produced path share one geometry-table entry")
	var path := _spline()

	# Input, Source, Width, CarveA, CarveB, Add, Output.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(path), _width(14.0), _carve(), _carve(),
		Pasture3DGraphNodeBlend.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		[0, 0, 3, 0], [0, 0, 4, 0], [1, 0, 2, 0], [2, 0, 3, 1], [2, 0, 4, 1],
		[3, 0, 5, 0], [4, 0, 5, 1], [5, 0, 6, 0]]
	var prog := g.compile_graph_program()
	var geom: Array = prog.get("geom", [])
	var in_g: PackedInt32Array = prog.get("in_g", PackedInt32Array())
	var named := {}
	for i in in_g.size():
		if in_g[i] >= 0:
			named[in_g[i]] = true

	# CONTROL: a second Path Width, so the two carves read two produced paths.
	var g2 := Pasture3DTerrainGraph.new()
	var nodes2: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(path), _width(14.0), _width(9.0), _carve(), _carve(),
		Pasture3DGraphNodeBlend.new(), Pasture3DGraphNodeOutput.new()]
	g2.nodes = nodes2
	g2.connections = [
		[0, 0, 4, 0], [0, 0, 5, 0], [1, 0, 2, 0], [1, 0, 3, 0], [2, 0, 4, 1], [3, 0, 5, 1],
		[4, 0, 6, 0], [5, 0, 6, 1], [6, 0, 7, 0]]
	var geom2: Array = g2.compile_graph_program().get("geom", [])

	print("    one filter, two carves: %d table entry/entries, %d distinct index/indices named"
			% [geom.size(), named.size()])
	print("    control (two filters): %d table entries" % geom2.size())
	_check("B", geom.size() == 1 and named.size() == 1 and geom2.size() == 2,
			"one produced path is one entry however many read it, and two are two")


## [C] `eval_path` is not re-run when nothing changed.
##
## Counted on the node itself, because the memo lives in the graph and returns the same answer either
## way. The control edits the width between evaluations: a key that folded only the node's identity, or
## only its inputs, would hit there too and the wrong terrain would come back.
func _c_eval_path_is_memoised() -> void:
	print("[C] eval_path is memoised across evaluations, and re-runs when the width changes")
	var surf := _terrain()
	var g := _chain(_spline(), 14.0, true)
	var w: Pasture3DGraphNodePathWidth = g.nodes[2]

	g.evaluate(GW, GH, RECT, null, surf)
	var after_first := w.eval_path_count
	for _i in 4:
		g.evaluate(GW, GH, RECT, null, surf)
	var after_repeats := w.eval_path_count

	# CONTROL: the width changes, so the memo must miss.
	w.half_width = 21.0
	g.evaluate(GW, GH, RECT, null, surf)
	var after_edit := w.eval_path_count

	print("    calls: %d after the first evaluation, %d after four more, %d after editing the width"
			% [after_first, after_repeats, after_edit])
	_check("C", after_first >= 1 and after_repeats == after_first and after_edit > after_repeats,
			"%d call(s) for five evaluations, and the edit cost exactly %d more"
					% [after_repeats, after_edit - after_repeats])
