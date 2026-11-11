# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphCoastProfileGate — the Coast Profile node. Fixture: a closed 256-gon of radius 400 m centred on the
# origin, so the signed distance at any cell is R - |p| to within the polygon's sag (~0.03 m).
#
# CA  the height along the +x row matches the closed-form profile. Control: the same formula fed UNSIGNED
#     distance (sea mirrored onto land) misses by more than 20 m, so the metric sees a lost sign.
# CB  signed_distance is R - |p|. Control: it is negative outside and positive inside (both exist).
# CC  cliff weight 0 vs 1: the inland plateau differs by exactly cliff_height, the beach mask is empty at
#     weight 1 and present at 0. Control: the two heights fields differ somewhere.
# CD  an open outline reads as open sea at -floor_depth everywhere. Control: the closed one does not.
# CE  the op is in graph_op_ids, so a graph holding it stays native. Control: a bogus op is not.
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
	_check(_ran == 5, "all 5 criteria ran (%d)" % _ran)
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
		var x: float = d - bw - n.cliff_width
		var inland := 0.0 if x <= 0.0 else pow(_ramp(x, n.inland_width), n.inland_curve)
		return n.sea_level + n.beach_height * _ramp(d, bw) + n.cliff_height * c * _ramp(d - bw, n.cliff_width) \
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
	print("[CC] the cliff weight")
	var n := _node(_circle())
	# A short inland ramp, so the centre sits on the saturated plateau. With the default 600 m ramp the
	# narrower beach under a cliff also moves the centre further up the ramp, and the difference is not
	# cliff_height alone.
	n.inland_width = 100.0
	var a := _eval(n, 0.0)
	var b := _eval(n, 1.0)
	var centre := (N / 2) * N + N / 2
	var diff: float = b[0][centre] - a[0][centre]
	_check(absf(diff - n.cliff_height) <= 0.01, "plateau rises by %.3f m (cliff_height %.1f)" % [diff, n.cliff_height])
	var beach_a := 0.0
	var beach_b := 0.0
	var cliff_b := 0.0
	for i in N * N:
		beach_a = maxf(beach_a, a[3][i])
		beach_b = maxf(beach_b, b[3][i])
		cliff_b = maxf(cliff_b, b[4][i])
	_check(beach_b == 0.0 and beach_a > 0.99, "beach mask: %.2f at weight 0, %.2f at weight 1" % [beach_a, beach_b])
	_check(cliff_b > 0.99, "cliff mask reaches %.2f at weight 1" % cliff_b)
	_check(absf(diff) > 1.0, "control: the two fields differ")
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


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
