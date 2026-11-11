# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPathRangeGate — the Path Range node (PASTURE3D_RANGES_SPEC.md step 1). Fixture: 2048 m square of 16 m
# cells, a straight crest along x from -800 to 800 m on the cell-centre row z = 8 m.
#
# PA  an even crest (variation 0, spurs off) reads peak_height on the crest, and an open end
#     reads the upper envelope: between end_height + (1 - end_height)·ss(e / end_taper) and peak_height,
#     never falling toward the middle. Control: with variation 0.5 another seed
#     moves crest heights by > 10 %.
# PB  spurs leave the crest on alternating sides: along rows 160 m either side, the side carrying the spur
#     bump changes >= 3 times. Control: spur_spacing past the crest length leaves the bare crest.
# PC  blend_k rounds where ridges meet: over the cells blend_k changes, the summed squared second difference
#     (a kink concentrates it) is below 0.9x that with blend_k 0.
#     Control: the two fields differ by > 0.5 m somewhere.
# PD  world metres: the 64² field matches the 2×2 means of the 128² field within 2 % of peak_height.
#     Control: halving spur_spacing at 64² moves it by more than that.
# PE  amount scales: a uniform 0.5 halves the field. Control: unwired equals a uniform 1 exactly.
# PF  an empty path passes the base through exactly. Control: with the crest it differs.
# PG  Spline Source -> Path Range -> Output is native_supported and equals the forced GDScript evaluator
#     on every output. Control: height and crest channels differ.
# PH  no standard mask (port 0 is a PATH), and the op is in graph_op_ids. Control: a bogus op is not.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphPathRangeGate.tscn
extends Node

const PathRange = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_path_range.gd")
const RECT := Rect2(-1024.0, -1024.0, 2048.0, 2048.0)
const N := 128
const DX := 16.0
const CZ := 8.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphPathRangeGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "path_range_grid"):
		_check(false, "path_range_grid is not bound — rebuild the GDExtension")
	else:
		_pa()
		_pb()
		_pc()
		_pd()
		_pe()
		_pf()
		_pg()
		_ph()
	_check(_ran == 8, "all 8 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["PATH RANGE PASS" if _fail == 0 else "PATH RANGE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _crest() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(-800.0, CZ), Vector2(0.0, CZ), Vector2(800.0, CZ)])
	return p


func _node() -> Pasture3DGraphNode:
	var n := PathRange.new()
	n.width_ratio = 1.0
	return n


func _even() -> Pasture3DGraphNode:
	var n := _node()
	n.peak_variation = 0.0
	n.spur_levels = 0
	return n


func _run(p_node: Pasture3DGraphNode, p_n: int = N, p_path: Pasture3DGraphPath = null, p_inputs: Array = []) -> Array:
	p_node.set_path_inputs([p_path if p_path != null else _crest()])
	var ins: Array = p_inputs if not p_inputs.is_empty() else [null]
	return p_node.eval_grid_channels(ins, p_n, p_n, null, RECT)


func _idx(p_x: float, p_z: float, p_n: int = N) -> int:
	var d := RECT.size.x / p_n
	return int(floor((p_z - RECT.position.y) / d)) * p_n + int(floor((p_x - RECT.position.x) / d))


static func _ss(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _pa() -> void:
	print("[PA] crest height and end taper")
	var n := _even()
	var h: PackedFloat32Array = _run(n)[0]
	# Flat middle (taper 1): exactly peak_height. Taper: a line is the max over its segments' profiles,
	# so a higher point a step along lifts its neighbour — the end reads the upper envelope, between the
	# formula and peak_height, and never falls toward the middle.
	var mid := 0.0
	var below := 0.0
	var above := 0.0
	var falls := 0
	var prev := -INF
	var x := -792.0
	while x < 800.0:
		var s := x + 800.0
		var want: float = n.peak_height * (n.end_height + (1.0 - n.end_height) * _ss(minf(s, 1600.0 - s) / n.end_taper))
		var v: float = h[_idx(x, CZ)]
		if s >= n.end_taper and 1600.0 - s >= n.end_taper:
			mid = maxf(mid, absf(v - n.peak_height))
		below = maxf(below, want - v)
		above = maxf(above, v - n.peak_height)
		if x < 0.0:
			if v < prev - 1e-3:
				falls += 1
			prev = v
		x += DX
	_check(mid <= 1e-3, "middle reads peak_height: worst %.5f m" % mid)
	# Below: the crest's linear 31 m resampling chords the smoothstep (step² · max|h''| / 8 ≈ 1.1 m).
	_check(below <= 1.5 and above <= 1e-3, "taper between formula and peak: below %.4f, above %.4f" % [below, above])
	_check(falls == 0, "west half never falls toward the middle (%d falls)" % falls)
	var a := _node()
	a.spur_levels = 0
	var b := _node()
	b.spur_levels = 0
	b.seed = 7
	var ha: PackedFloat32Array = _run(a)[0]
	var hb: PackedFloat32Array = _run(b)[0]
	var moved := 0.0
	x = -400.0
	while x < 400.0:
		moved = maxf(moved, absf(ha[_idx(x, CZ)] - hb[_idx(x, CZ)]))
		x += DX
	_check(moved > 0.1 * a.peak_height, "control: another seed moves the crest by %.1f m" % moved)
	_ran += 1


## Per x: +1 where the north row carries more spur bump, -1 the south; columns with no bump are skipped.
func _sides(p_spur: PackedFloat32Array, p_bare: PackedFloat32Array, p_off: float) -> Array:
	var out := []
	var x := -760.0
	while x < 760.0:
		var north := p_spur[_idx(x, CZ - p_off)] - p_bare[_idx(x, CZ - p_off)]
		var south := p_spur[_idx(x, CZ + p_off)] - p_bare[_idx(x, CZ + p_off)]
		if maxf(north, south) > 1.0:
			out.append(1 if north > south else -1)
		x += DX
	return out


func _pb() -> void:
	print("[PB] spurs alternate sides")
	var bare: PackedFloat32Array = _run(_even())[0]
	var n := _even()
	n.spur_levels = 1
	n.spur_angle_jitter = 0.0
	var sides := _sides(_run(n)[0], bare, 160.0)
	var flips := 0
	for i in range(1, sides.size()):
		if sides[i] != sides[i - 1]:
			flips += 1
	_check(flips >= 3, "%d side changes over %d bumped columns" % [flips, sides.size()])
	n.spur_spacing = 5000.0
	var none: PackedFloat32Array = _run(n)[0]
	var nsides := _sides(none, bare, 160.0)
	_check(nsides.size() <= 1, "control: spacing past the crest leaves %d bumped columns" % nsides.size())
	_ran += 1


static func _crease(p_h: PackedFloat32Array, p_zone: PackedByteArray) -> float:
	var m := 0.0
	for iz in range(1, N - 1):
		for ix in range(1, N - 1):
			var i := iz * N + ix
			if p_zone[i] == 0:
				continue
			m += pow(p_h[i - 1] - 2.0 * p_h[i] + p_h[i + 1], 2.0) + pow(p_h[i - N] - 2.0 * p_h[i] + p_h[i + N], 2.0)
	return m


func _pc() -> void:
	print("[PC] ridges meet without a crease")
	var n := _node()
	n.peak_variation = 0.0
	n.spur_levels = 2
	var soft: PackedFloat32Array = _run(n)[0]
	n.blend_k = 0.0
	var hard: PackedFloat32Array = _run(n)[0]
	# Only where lines meet (blend_k changes the field). Within one line the merge is a hard max by design.
	var zone := PackedByteArray()
	zone.resize(N * N)
	for i in N * N:
		zone[i] = 1 if absf(soft[i] - hard[i]) > 0.1 else 0
	var cs := _crease(soft, zone)
	var ch := _crease(hard, zone)
	_check(cs < 0.9 * ch, "curvature energy where lines meet %.0f soft vs %.0f hard" % [cs, ch])
	var diff := 0.0
	for i in soft.size():
		diff = maxf(diff, absf(soft[i] - hard[i]))
	_check(diff > 0.5, "control: blend_k changes the field by %.3f m" % diff)
	_ran += 1


func _pd() -> void:
	print("[PD] the range does not move with resolution")
	var n := _node()
	n.width_ratio = 2.5 # the default: flanks a 32 m cell can resolve
	var fine: PackedFloat32Array = _run(n, 128)[0]
	var coarse: PackedFloat32Array = _run(n, 64)[0]
	var m := _node()
	m.width_ratio = 2.5
	m.spur_spacing = n.spur_spacing * 0.5
	var other: PackedFloat32Array = _run(m, 64)[0]
	var worst := 0.0
	var wat := Vector3.ZERO
	var moved := 0.0
	for iz in 64:
		for ix in 64:
			var f := 0.25 * (fine[(2 * iz) * 128 + 2 * ix] + fine[(2 * iz) * 128 + 2 * ix + 1]
					+ fine[(2 * iz + 1) * 128 + 2 * ix] + fine[(2 * iz + 1) * 128 + 2 * ix + 1])
			if absf(coarse[iz * 64 + ix] - f) > worst:
				worst = absf(coarse[iz * 64 + ix] - f)
				wat = Vector3(-1024.0 + (ix + 0.5) * 32.0, coarse[iz * 64 + ix], -1024.0 + (iz + 0.5) * 32.0)
			moved = maxf(moved, absf(other[iz * 64 + ix] - coarse[iz * 64 + ix]))
	var tol: float = 0.02 * n.peak_height
	_check(worst <= tol, "64² vs 128²: worst %.2f m at %s (tolerance %.1f)" % [worst, wat, tol])
	_check(moved > tol, "control: half the spur spacing moves it %.2f m" % moved)
	_ran += 1


static func _uniform(p_v: float, p_n: int = N) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	a.fill(p_v)
	return a


func _pe() -> void:
	print("[PE] amount scales the range")
	var n := _node()
	var full: PackedFloat32Array = _run(n)[0]
	var half: PackedFloat32Array = _run(n, N, null, [null, null, _uniform(0.5)])[0]
	var one: PackedFloat32Array = _run(n, N, null, [null, null, _uniform(1.0)])[0]
	var worst := 0.0
	var same := 0.0
	for i in full.size():
		worst = maxf(worst, absf(half[i] - 0.5 * full[i]))
		same = maxf(same, absf(one[i] - full[i]))
	_check(worst <= 1e-3, "amount 0.5 halves the field: worst %.5f" % worst)
	_check(same == 0.0, "control: unwired equals a uniform 1 (max %.6f)" % same)
	_ran += 1


func _pf() -> void:
	print("[PF] no crest passes the base through")
	var base := PackedFloat32Array()
	base.resize(N * N)
	for i in N * N:
		base[i] = float(i % 37) - 10.0
	var n := _node()
	var out: PackedFloat32Array = _run(n, N, Pasture3DGraphPath.new(), [null, base])[0]
	_check(out == base, "empty path: height == base")
	var with: PackedFloat32Array = _run(n, N, null, [null, base])[0]
	_check(with != base, "control: with the crest it differs")
	_ran += 1


func _graph(p_port: int) -> Pasture3DTerrainGraph:
	var src: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"spline_source")
	src.set("path", _crest())
	var pr := _node()
	pr.spur_levels = 2
	var nodes: Array[Pasture3DGraphNode] = [src, pr, Pasture3DGraphNodeRegistry.create(&"output"),
			Pasture3DGraphNodeRegistry.create(&"input")]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([3, 0, 1, 1]),
			PackedInt32Array([1, p_port, 2, 0])]
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _pg() -> void:
	print("[PG] the compiled graph route equals the GDScript evaluator")
	var base := PackedFloat32Array()
	base.resize(N * N)
	for i in N * N:
		base[i] = 5.0 * sin(float(i % N) * 0.1)
	var outs := []
	var all_native := true
	for port in 4:
		var g := _graph(port)
		all_native = all_native and g.native_supported()
		var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, base)
		var g2 := _graph(port)
		g2.force_gdscript_evaluation = true
		var ora: PackedFloat32Array = g2.evaluate(N, N, RECT, null, base)
		var w := _worst(nat, ora)
		_check(w <= 1.0e-4, "output %d: worst %.7f" % [port, w])
		outs.append(nat)
	_check(all_native, "all four graphs are native_supported")
	var chan := _worst(outs[0], outs[1])
	_check(chan > 1.0 and chan < INF, "control: height is not crest (%.2f)" % chan)
	_ran += 1


func _ph() -> void:
	print("[PH] no standard mask, stays native")
	var has := false
	for p in _node().input_ports():
		has = has or p.id == &"mask"
	_check(not has, "Path Range has no standard mask")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("path_range") or ids.has(&"path_range"), "path_range is a native op")
	_check(not (ids.has("path_range_bogus") or ids.has(&"path_range_bogus")), "control: a bogus op is not")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
