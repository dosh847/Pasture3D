# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphRangeSplinesGate — multi-part PATHs and Generate Range Splines (PASTURE3D_RANGES_SPEC.md step 3).
#
# RA  SPINE on an 8000 x 2000 m rectangle gives ONE crest on its long axis within one cell, spanning at least
#     80 % of the 6000 m medial segment; on an L shape the crests cover both arms' centrelines. Control: a
#     disc gives no spine longer than min_branch.
# RB  every vertex of every part (FOLDS and SCATTER, irregular outline) lies at least coast_inset inside the
#     outline, measured by the GDScript path query. Control: inset 0 lets a vertex reach within 50 m of shore.
# RC  parts do not join: Path Distance midway between two parallel FOLDS crests 1000 m apart reads 500 m, on
#     the native kernel and the GDScript query; Path Range there is lower than on the joined line. Control:
#     the same points as one part read near 0 across the joining segment.
# RD  each audited per-vertex node (Resample, Smooth, Decimate, Fractalize, Meanderize, Width, Drape, Width
#     Field) keeps both parts and puts no vertex in the gap. Control: Resample on the joined points does.
# RE  determinism: SCATTER with the same seed gives the same set (hash). Control: another seed differs.
# RF  Spline Source -> Generate Range Splines -> Path Distance -> Output is native_supported and the native
#     route equals the forced GDScript evaluator, reading the gap midway. Control: the joined points through
#     the same graph read near 0.
# RG  SCATTER fills a small outline (600 x 480 m, an island's hill outline from the demo): spacing 120,
#     length 250 places at least 3 ridges. Before the fix a ridge was accepted BEFORE the shore clip, so one
#     the clip then dropped still counted toward `count` and blocked its neighbours: this placed 1. Control:
#     Min Branch 2000 gives 0 parts, so candidates in this fixture really do reach the clip.
# RH  auto layout (Spacing 0, Length 0, the defaults) fits both scales: on the 600 m hill outline and on a
#     10 km island, FOLDS and SCATTER at Count 5 each give at least 3 crests, and the resolved spacing is
#     2 (max_depth - coast_inset) / count. Control: the old fixed-metre island layout (spacing 1500, length
#     3000) gives fewer than 3 on the hill outline in both modes.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphRangeSplinesGate.tscn
extends Node

const RangeSplines = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_range_splines.gd")

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphRangeSplinesGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "range_splines_solve"):
		_check(false, "range_splines_solve is not bound — rebuild the GDExtension")
	else:
		_ra()
		_rb()
		_rc()
		_rd()
		_re()
		_rf()
		_rg()
		_rh()
	_check(_ran == 8, "all 8 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["RANGE SPLINES PASS" if _fail == 0 else "RANGE SPLINES FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -------------------------------------------------------------------------------------

static func _closed(p_pts: PackedVector2Array) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = p_pts
	p.closed = true
	return p


static func _rect(p_w: float, p_h: float) -> Pasture3DGraphPath:
	return _closed(PackedVector2Array([Vector2(-p_w / 2, -p_h / 2), Vector2(p_w / 2, -p_h / 2),
			Vector2(p_w / 2, p_h / 2), Vector2(-p_w / 2, p_h / 2)]))


## Outer corner at the origin, arms 8000 m long and 2000 m wide along +X and +Z.
static func _ell() -> Pasture3DGraphPath:
	return _closed(PackedVector2Array([Vector2(0, 0), Vector2(8000, 0), Vector2(8000, 2000), Vector2(2000, 2000),
			Vector2(2000, 8000), Vector2(0, 8000)]))


static func _disc(p_r: float) -> Pasture3DGraphPath:
	var pts := PackedVector2Array()
	for i in 96:
		var a := TAU * i / 96.0
		pts.append(Vector2(cos(a), sin(a)) * p_r)
	return _closed(pts)


static func _blob() -> Pasture3DGraphPath:
	var pts := PackedVector2Array()
	for i in 160:
		var a := TAU * i / 160.0
		var r := 5000.0 * (1.0 + 0.25 * sin(3.0 * a) + 0.08 * sin(11.0 * a))
		pts.append(Vector2(cos(a), sin(a)) * r)
	return _closed(pts)


## The demo's NorthWestHillsSpline: about 600 x 480 m, 186 m deep at its deepest.
static func _hills() -> Pasture3DGraphPath:
	return _closed(PackedVector2Array([Vector2(58.82245, -1178.1616), Vector2(265.3446, -1221.5282),
			Vector2(146.76732, -1374.6617), Vector2(-86.3168, -1419.9147), Vector2(-328.31866, -1345.1998),
			Vector2(-297.6133, -1013.2457), Vector2(-63.543976, -938.4501), Vector2(136.95718, -980.10187),
			Vector2(58.82245, -1138.1616)]))


## The node, configured, and run on `p_outline`.
static func _gen(p_outline: Pasture3DGraphPath, p_cfg: Dictionary) -> Pasture3DGraphPath:
	var n := RangeSplines.new()
	for k in p_cfg:
		n.set(k, p_cfg[k])
	return n.eval_path([p_outline])


static func _depth(p_outline: Pasture3DGraphPath, p_at: Vector2) -> float:
	var d: float = p_outline.nearest(p_at)["distance"]
	return d if p_outline.inside(p_at) else -d


## Two parallel crests along X at z = -500 and +500, 13 vertices each, with widths and heights.
static func _pair(p_parts: bool) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for z in [-500.0, 500.0]:
		for i in 13:
			pts.append(Vector2(-3000.0 + 500.0 * i, z))
			w.append(40.0)
			h.append(300.0)
	p.points = pts
	p.half_widths = w
	p.heights = h
	if p_parts:
		p.part_starts = PackedInt32Array([13])
	return p


# ---- criteria -------------------------------------------------------------------------------------

func _ra() -> void:
	print("[RA] SPINE follows the medial axis")
	var cfg := {"mode": RangeSplines.Mode.SPINE, "coast_inset": 0.0, "min_branch": 500.0, "resolution": 256,
			"height_from_depth": false}
	var r := _gen(_rect(8000.0, 2000.0), cfg)
	var cell := 8000.0 / 256.0
	var worst_z := 0.0
	var x0 := INF
	var x1 := -INF
	for v in r.points:
		worst_z = maxf(worst_z, absf(v.y))
		x0 = minf(x0, v.x)
		x1 = maxf(x1, v.x)
	_check(r.part_count() == 1, "rectangle: one crest (%d)" % r.part_count())
	_check(worst_z <= cell, "rectangle: on the long axis, worst |z| %.2f m <= one cell %.2f m" % [worst_z, cell])
	_check(x1 - x0 >= 0.8 * 6000.0, "rectangle: spans %.0f m of the 6000 m medial segment" % (x1 - x0))

	var ell := _gen(_ell(), cfg)
	var cover := [0, 0]
	var samples := 0
	for s in range(3000, 7001, 500):
		samples += 1
		var hit_h := false
		var hit_v := false
		for v in ell.points:
			hit_h = hit_h or v.distance_to(Vector2(s, 1000.0)) <= 3.0 * cell
			hit_v = hit_v or v.distance_to(Vector2(1000.0, s)) <= 3.0 * cell
		cover[0] += int(hit_h)
		cover[1] += int(hit_v)
	_check(cover[0] == samples and cover[1] == samples,
			"L shape: crest along the X arm %d/%d, the Z arm %d/%d (%d parts)" % [cover[0], samples, cover[1], samples,
			ell.part_count()])

	var disc := _gen(_disc(3000.0), cfg)
	var total := 0.0
	for k in disc.part_count():
		total += disc.part(k).length()
	_check(total < 500.0, "control: a disc gives %.1f m of spine (< min_branch 500)" % total)
	_ran += 1


func _rb() -> void:
	print("[RB] every vertex keeps coast_inset from the shore")
	var outline := _blob()
	for m in [RangeSplines.Mode.FOLDS, RangeSplines.Mode.SCATTER, RangeSplines.Mode.SPINE]:
		var r := _gen(outline, {"mode": m, "coast_inset": 600.0, "count": 9, "spacing": 900.0, "length": 2500.0,
				"min_branch": 200.0, "seed": 3})
		var worst := INF
		for v in r.points:
			worst = minf(worst, _depth(outline, v))
		_check(r.points.size() > 0 and worst >= 600.0 - 0.05,
				"mode %d: %d vertices, %d parts, shallowest %.3f m (>= 600)" % [m, r.points.size(), r.part_count(), worst])
	var c := _gen(outline, {"mode": RangeSplines.Mode.FOLDS, "coast_inset": 0.0, "count": 9, "spacing": 900.0,
			"min_branch": 200.0, "seed": 3})
	var shallow := INF
	for v in c.points:
		shallow = minf(shallow, _depth(outline, v))
	_check(shallow < 50.0, "control: inset 0 reaches %.2f m from shore" % shallow)
	_ran += 1


func _mid_distance(p: Pasture3DGraphPath) -> float:
	# A 3 x 3 grid whose centre cell centre is the origin.
	var res: Dictionary = Pasture3DUtil.path_query_grid(p.points, p.half_widths, 3, 3, Rect2(-15, -15, 30, 30), 1e4, 0.0,
			p.heights, p.part_starts)
	return res["distance"][4]


func _mid_range(p: Pasture3DGraphPath) -> float:
	var prm := PackedFloat32Array()
	prm.resize(16)
	prm[0] = 600.0 # peak_height
	prm[1] = 600.0 # peak_spacing
	prm[2] = 0.0 # peak_variation
	prm[3] = 400.0 # end_taper
	prm[4] = 0.2
	prm[5] = 2.5 # width_ratio
	prm[6] = 250.0
	prm[7] = 500.0
	prm[11] = 0.0 # spur_levels
	prm[12] = 40.0
	var res: Dictionary = Pasture3DUtil.path_range_grid(p.points, p.heights, false, PackedFloat32Array(),
			PackedFloat32Array(), 3, 3, Rect2(-15, -15, 30, 30), prm, p.part_starts)
	return res["height"][4]


func _rc() -> void:
	print("[RC] parts do not join")
	var r := _gen(_rect(8000.0, 4000.0), {"mode": RangeSplines.Mode.FOLDS, "coast_inset": 100.0, "count": 2,
			"angle": 90.0, "spacing": 1000.0, "wander": 0.0, "min_branch": 200.0})
	_check(r.part_count() == 2, "two folds (%d)" % r.part_count())
	var nat := _mid_distance(r)
	var gd: float = r.nearest(Vector2.ZERO)["distance"]
	_check(absf(nat - 500.0) <= 0.5, "native Path Distance midway %.3f m (500)" % nat)
	_check(absf(gd - 500.0) <= 0.5, "GDScript query midway %.3f m (500)" % gd)
	var joined := Pasture3DGraphPath.new()
	joined.points = r.points
	joined.heights = r.heights
	var nj := _mid_distance(joined)
	var gj: float = joined.nearest(Vector2.ZERO)["distance"]
	_check(nj < 20.0 and gj < 20.0, "control: as one part the joining segment reads %.3f / %.3f m" % [nj, gj])
	var hp := _mid_range(r)
	var hj := _mid_range(joined)
	_check(hp < hj - 50.0, "Path Range midway: %.1f m with parts < %.1f m joined" % [hp, hj])
	_ran += 1


func _rd() -> void:
	print("[RD] per-vertex PATH nodes keep the parts")
	var grid := PackedFloat32Array()
	grid.resize(64 * 64)
	grid.fill(5.0)
	var rect := Rect2(-4000, -4000, 8000, 8000)
	for op in [&"path_resample", &"path_smooth", &"path_decimate", &"path_fractalize", &"path_meanderize",
			&"path_width", &"path_drape", &"path_width_field"]:
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n.needs_grid():
			n.eval_grid([grid], 64, 64, null, rect)
		var out: Pasture3DGraphPath = n.eval_path([_pair(true)])
		var in_gap := 0
		for v in out.points:
			if absf(v.y) < 250.0:
				in_gap += 1
		_check(out != null and out.part_count() == 2 and in_gap == 0,
				"%s: %d parts, %d vertices in the gap" % [op, out.part_count() if out else -1, in_gap])
	var c: Pasture3DGraphPath = Pasture3DGraphNodeRegistry.create(&"path_resample").eval_path([_pair(false)])
	var bridged := 0
	for v in c.points:
		if absf(v.y) < 250.0:
			bridged += 1
	_check(bridged > 0, "control: resampling the joined points puts %d vertices in the gap" % bridged)
	_ran += 1


static func _digest(p: Pasture3DGraphPath) -> int:
	return hash([p.points, p.heights, p.part_starts])


func _re() -> void:
	print("[RE] same seed, same set")
	var cfg := {"mode": RangeSplines.Mode.SCATTER, "coast_inset": 400.0, "count": 12, "spacing": 800.0, "seed": 7}
	var a := _digest(_gen(_blob(), cfg))
	var b := _digest(_gen(_blob(), cfg))
	cfg["seed"] = 8
	var c := _gen(_blob(), cfg)
	_check(a == b, "seed 7 twice: %d == %d" % [a, b])
	_check(_digest(c) != a and c.part_count() > 0, "control: seed 8 differs (%d parts)" % c.part_count())
	_ran += 1


func _graph(p_src: Pasture3DGraphPath, p_generate: bool) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = p_src
	var dist := Pasture3DGraphNodePathDistance.new()
	var g := Pasture3DTerrainGraph.create_empty()
	if p_generate:
		var n := RangeSplines.new()
		n.mode = RangeSplines.Mode.FOLDS
		n.coast_inset = 100.0
		n.count = 2
		n.angle = 90.0
		n.spacing = 1000.0
		n.wander = 0.0
		n.min_branch = 200.0
		var ns: Array[Pasture3DGraphNode] = [src, n, dist, Pasture3DGraphNodeOutput.new()]
		g.nodes = ns
		g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0]), PackedInt32Array([2, 0, 3, 0])]
	else:
		var ns: Array[Pasture3DGraphNode] = [src, dist, Pasture3DGraphNodeOutput.new()]
		g.nodes = ns
		g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	return g


func _rf() -> void:
	print("[RF] the compiled graph carries the parts")
	var rect := Rect2(-15, -15, 30, 30)
	var g := _graph(_rect(8000.0, 4000.0), true)
	var nat: PackedFloat32Array = g.evaluate(3, 3, rect, null, PackedFloat32Array())
	var g2 := _graph(_rect(8000.0, 4000.0), true)
	g2.force_gdscript_evaluation = true
	var ora: PackedFloat32Array = g2.evaluate(3, 3, rect, null, PackedFloat32Array())
	_check(g.native_supported(), "the graph is native_supported")
	_check(nat.size() == 9 and absf(nat[4] - 500.0) <= 0.5, "native midway %.3f m (500)" % (nat[4] if nat.size() == 9 else NAN))
	_check(ora.size() == 9 and absf(ora[4] - nat[4]) <= 1e-3, "GDScript evaluator agrees: %.3f" % (ora[4] if ora.size() == 9 else NAN))
	var joined := Pasture3DGraphPath.new()
	joined.points = _gen(_rect(8000.0, 4000.0), {"mode": RangeSplines.Mode.FOLDS, "coast_inset": 100.0, "count": 2,
			"angle": 90.0, "spacing": 1000.0, "wander": 0.0, "min_branch": 200.0}).points
	var j: PackedFloat32Array = _graph(joined, false).evaluate(3, 3, rect, null, PackedFloat32Array())
	_check(j.size() == 9 and j[4] < 20.0, "control: the joined points read %.3f m" % (j[4] if j.size() == 9 else NAN))
	_ran += 1


func _rg() -> void:
	print("[RG] SCATTER fills a small outline")
	var hills := _hills()
	var cfg := {"mode": RangeSplines.Mode.SCATTER, "spacing": 120.0, "length": 250.0, "wander": 0.25, "count": 5}
	var r := _gen(hills, cfg)
	_check(r.part_count() >= 3, "%d ridges placed (>= 3)" % r.part_count())
	cfg["min_branch"] = 2000.0
	var c := _gen(hills, cfg)
	_check(c.points.is_empty(), "control: Min Branch 2000 drops every candidate (%d parts)" % c.part_count())
	_ran += 1


func _rh() -> void:
	print("[RH] auto layout fits a hill outline and an island")
	for o in [["hills", _hills()], ["island", _blob()]]:
		for m in [RangeSplines.Mode.FOLDS, RangeSplines.Mode.SCATTER]:
			var n := RangeSplines.new()
			n.mode = m
			var r: Pasture3DGraphPath = n.eval_path([o[1]])
			var lay: Dictionary = n.resolved_layout()
			var want := 2.0 * (n._max_depth - n.coast_inset) / n.count
			_check(r.part_count() >= 3 and absf(float(lay.get("spacing", 0.0)) - want) <= 1e-3 * want,
					"%s mode %d: %d crests, spacing %.1f m (%.1f), length %.1f m" % [o[0], m, r.part_count(),
					float(lay.get("spacing", 0.0)), want, float(lay.get("length", 0.0))])
	for m in [RangeSplines.Mode.FOLDS, RangeSplines.Mode.SCATTER]:
		var c := _gen(_hills(), {"mode": m, "spacing": 1500.0, "length": 3000.0})
		_check(c.part_count() < 3, "control: fixed island metres, mode %d, give %d crests on the hills" % [m, c.part_count()])
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
