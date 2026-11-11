# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphCoastProfileGate — the Coast Profile node. Fixture: a closed 256-gon of radius 400 m centred on the
# origin, so the signed distance at any cell is R - |p| to within the polygon's sag (~0.03 m).
#
# CA  the height along the +x row matches the closed-form profile. Control: the same formula fed UNSIGNED
#     distance (sea mirrored onto land) misses by more than 20 m, so the metric sees a lost sign.
# CB  signed_distance is R - |p|. Control: it is negative outside and positive inside (both exist).
# CC  cliff weight sets steepness, not height: weight 0 and 1 reach the same plateau, the beach mask is
#     empty at weight 1 and present at 0. Controls: the old formula (cliff height dropped at weight 0)
#     misses the weight-0 plateau by cliff_height, and the two fields differ near the shore.
# CD  an open outline reads as open sea at -floor_depth everywhere. Control: the closed one does not.
# CE  the op is in graph_op_ids, so a graph holding it stays native. Control: a bogus op is not.
# CF  Spline Source -> Coast Profile -> Output: native_supported, and the COMPILED program (geometry table,
#     aux cliff port, output channels) equals the forced GDScript evaluator, for height and for the cliff
#     mask channel, with the cliff port unwired and wired to a Const. Controls: wiring cliff = 0 moves the
#     height by metres (so the aux port reaches the kernel), and the channel output differs from height.
# CG  at weight 0 the steepest slope across the rise stays under 1.5 cliff_height / slope_width. Control: at
#     weight 1 it exceeds half of cliff_height / cliff_width.
# CH  an unwired cliff port is bit-identical to an explicit all-1 mask. Control: an all-0.5 mask differs.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphCoastProfileGate.tscn
extends Node

const RECT := Rect2(-1024.0, -1024.0, 2048.0, 2048.0)
const CoastProfile = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_coast_profile.gd")
const N := 256
const R := 400.0

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphCoastProfileGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "coast_profile_grid"):
		_check(false, "coast_profile_grid is not bound — rebuild the GDExtension")
	else:
		_ca()
		_cb()
		_cc()
		_cd()
		_ce()
		_cf()
		_cg()
		_ch()
	_check(_ran == 8, "all 8 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["COAST PROFILE PASS" if _fail == 0 else "COAST PROFILE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _circle(p_closed := true) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	for i in 256:
		var a := TAU * float(i) / 256.0
		pts.append(Vector2(cos(a), sin(a)) * R)
		w.append(1.0)
	p.points = pts
	p.half_widths = w
	p.closed = p_closed
	return p


func _node(p_path: Pasture3DGraphPath) -> Pasture3DGraphNode:
	var n := CoastProfile.new()
	n.set_path_inputs([p_path])
	return n


func _eval(p_node: Pasture3DGraphNode, p_cliff: float = -1.0) -> Array:
	var ins: Array = [null]
	if p_cliff >= 0.0:
		var c := PackedFloat32Array()
		c.resize(N * N)
		c.fill(p_cliff)
		ins.append(c)
	return p_node.eval_grid_channels(ins, N, N, null, RECT)


static func _ss(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _ramp(x: float, w: float) -> float:
	return _ss(x / w) if w > 1e-6 else (1.0 if x >= 0.0 else 0.0)


## The profile written out independently of the kernel, from the header's formula.
static func _expect(n, d: float, c: float) -> float:
	var bw: float = n.beach_width * (1.0 - c)
	if d >= 0.0:
		var wc: float = n.cliff_width * c + maxf(n.slope_width, n.cliff_width) * (1.0 - c)
		var x: float = d - bw - wc
		var inland := 0.0 if x <= 0.0 else pow(_ramp(x, n.inland_width), n.inland_curve)
		return n.sea_level + n.beach_height * _ramp(d, bw) + n.cliff_height * _ramp(d - bw, wc) \
				+ n.inland_height * inland
	var e: float = -d
	var fl: float = maxf(n.floor_depth, n.shelf_depth)
	return n.sea_level - n.shelf_depth * _ramp(e, n.shelf_width) - (fl - n.shelf_depth) * _ramp(e - n.shelf_width, n.drop_width)


func _ca() -> void:
	print("[CA] height matches the closed-form profile along +x")
	var n := _node(_circle())
	n.sea_level = 2.0
	var h: PackedFloat32Array = _eval(n)[0]
	var row := N / 2
	var worst := 0.0
	var worst_unsigned := 0.0
	for ix in N:
		var w := Pasture3DTerrainGraph.cell_to_world(ix, row, N, N, RECT)
		var d := R - w.length()
		worst = maxf(worst, absf(h[row * N + ix] - _expect(n, d, 1.0)))
		worst_unsigned = maxf(worst_unsigned, absf(h[row * N + ix] - _expect(n, absf(d), 1.0)))
	_check(worst <= 0.5, "worst %.4f m against the formula" % worst)
	_check(worst_unsigned > 20.0, "control: unsigned distance misses by %.1f m" % worst_unsigned)
	_ran += 1


func _cb() -> void:
	print("[CB] signed_distance is R - |p|")
	var sd: PackedFloat32Array = _eval(_node(_circle()))[1]
	var worst := 0.0
	var pos := 0
	var neg := 0
	for iz in N:
		for ix in N:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, N, N, RECT)
			var v := sd[iz * N + ix]
			worst = maxf(worst, absf(v - (R - w.length())))
			if v > 1.0: pos += 1
			elif v < -1.0: neg += 1
	_check(worst <= 0.2, "worst %.4f m" % worst)
	_check(pos > 1000 and neg > 1000, "control: %d cells inside, %d outside" % [pos, neg])
	_ran += 1


func _cc() -> void:
	print("[CC] the cliff weight sets steepness, not height")
	var n := _node(_circle())
	# A short inland ramp, so the centre sits on the saturated plateau whatever the rise width.
	n.inland_width = 100.0
	var a := _eval(n, 0.0)
	var b := _eval(n, 1.0)
	var centre := (N / 2) * N + N / 2
	var diff: float = b[0][centre] - a[0][centre]
	_check(absf(diff) <= 0.01, "plateau differs by %.4f m between weight 0 and 1" % diff)
	# The pre-change profile at weight 0, on the plateau: no cliff term at all.
	var old_plateau: float = n.sea_level + n.beach_height + n.inland_height
	var miss: float = absf(a[0][centre] - old_plateau)
	_check(absf(miss - n.cliff_height) <= 0.01, "control: the old formula misses by %.2f m" % miss)
	var beach_a := 0.0
	var beach_b := 0.0
	var cliff_b := 0.0
	var near := 0.0
	for i in N * N:
		beach_a = maxf(beach_a, a[3][i])
		beach_b = maxf(beach_b, b[3][i])
		cliff_b = maxf(cliff_b, b[4][i])
		near = maxf(near, absf(a[0][i] - b[0][i]))
	_check(beach_b == 0.0 and beach_a > 0.99, "beach mask: %.2f at weight 0, %.2f at weight 1" % [beach_a, beach_b])
	_check(cliff_b > 0.99, "cliff mask reaches %.2f at weight 1" % cliff_b)
	_check(near > 1.0, "control: the fields differ near the shore by %.1f m" % near)
	_ran += 1


## Steepest slope along the +x row over land, metres per metre.
func _max_slope(p_h: PackedFloat32Array) -> float:
	var row := N / 2
	var dx := RECT.size.x / N
	var m := 0.0
	for ix in N - 1:
		var w := Pasture3DTerrainGraph.cell_to_world(ix, row, N, N, RECT)
		if R - w.length() < 0.0:
			continue
		m = maxf(m, absf(p_h[row * N + ix + 1] - p_h[row * N + ix]) / dx)
	return m


func _cg() -> void:
	print("[CG] weight 0 is a gentle slope, weight 1 a cliff")
	var n := _node(_circle())
	n.inland_height = 0.0
	n.beach_height = 0.0
	var gentle := _max_slope(_eval(n, 0.0)[0])
	var steep := _max_slope(_eval(n, 1.0)[0])
	var limit: float = 1.5 * n.cliff_height / n.slope_width * 1.02 # smoothstep peak slope, plus 2% for the row sampling
	_check(gentle <= limit, "weight 0: steepest %.3f (limit %.3f)" % [gentle, limit])
	_check(steep > 0.5 * n.cliff_height / n.cliff_width, "control: weight 1 reaches %.3f" % steep)
	_ran += 1


func _ch() -> void:
	print("[CH] unwired is the all-1 mask")
	var n := _node(_circle())
	var un: PackedFloat32Array = _eval(n)[0]
	var one: PackedFloat32Array = _eval(n, 1.0)[0]
	var half: PackedFloat32Array = _eval(n, 0.5)[0]
	_check(un == one, "unwired equals an explicit all-1 mask, bit for bit")
	_check(un != half, "control: an all-0.5 mask differs")
	_ran += 1


func _cd() -> void:
	print("[CD] an open outline is open sea")
	var n := _node(_circle(false))
	var h: PackedFloat32Array = _eval(n)[0]
	var worst := 0.0
	for v in h:
		worst = maxf(worst, absf(v + n.floor_depth))
	_check(worst == 0.0, "every cell at -floor_depth (worst %.4f)" % worst)
	_check(not n.node_warnings().is_empty(), "the node warns about the open outline")
	var closed: PackedFloat32Array = _eval(_node(_circle()))[0]
	_check(closed[(N / 2) * N + N / 2] > 0.0, "control: the closed outline has land at its centre")
	_ran += 1


func _ce() -> void:
	print("[CE] stays native")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("coast_profile") or ids.has(&"coast_profile"), "coast_profile is a native op")
	_check(not (ids.has("coast_profile_bogus") or ids.has(&"coast_profile_bogus")), "control: a bogus op is not")
	_ran += 1


func _graph(p_port: int, p_cliff: float) -> Pasture3DTerrainGraph:
	var src: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"spline_source")
	src.set("path", _circle())
	var nodes: Array[Pasture3DGraphNode] = [src, CoastProfile.new(), Pasture3DGraphNodeRegistry.create(&"output")]
	var conns: Array = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, p_port, 2, 0])]
	if p_cliff >= 0.0:
		var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_cliff)
		nodes.append(c)
		conns.append(PackedInt32Array([3, 0, 1, 1]))
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = conns
	return g


func _routes(p_port: int, p_cliff: float) -> Array:
	var g := _graph(p_port, p_cliff)
	var native_ok := g.native_supported()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), 128, 128, RECT, PackedFloat32Array())
	var g2 := _graph(p_port, p_cliff)
	g2.force_gdscript_evaluation = true
	var ora: PackedFloat32Array = g2.evaluate(128, 128, RECT, null, PackedFloat32Array())
	return [native_ok, nat, ora]


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _cf() -> void:
	print("[CF] the compiled graph route equals the GDScript evaluator")
	var unwired := _routes(0, -1.0)
	var flat := _routes(0, 0.0)
	var mask := _routes(4, -1.0)
	_check(unwired[0] and flat[0] and mask[0], "all three graphs are native_supported")
	for pair in [["height, cliff unwired", unwired], ["height, cliff = 0", flat], ["cliff channel", mask]]:
		var w := _worst(pair[1][1], pair[1][2])
		_check(w <= 1.0e-3, "%s: worst %.6f m" % [pair[0], w])
	var moved := _worst(unwired[1], flat[1])
	_check(moved > 10.0 and moved < INF, "control: wiring cliff = 0 moves the height by %.1f m" % moved)
	var chan := _worst(unwired[1], mask[1])
	_check(chan > 10.0 and chan < INF, "control: the cliff channel is not the height (%.1f)" % chan)
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
