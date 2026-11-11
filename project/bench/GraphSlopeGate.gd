# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSlopeGate — the Slope node (PASTURE3D_RANGES_SPEC.md step 2). Fixture: 2048 m square.
#
# SA  a plane tilted 20° dipping toward bearing 120° reads 20° ± 0.05 and aspect 120° ± 0.5 at 64² and 128².
#     Control: a per-cell rise (no metric division) reads differently at the two resolutions.
# SB  band mask on a bowl (slope rising with radius): 1 where degrees is inside min..max, 0 beyond falloff.
#     Control: widening the band raises the masked area.
# SC  scale smooths: a 20° plane with per-cell noise reads within 2° of 20 at scale 50 m. Control: scale 0
#     does not.
# SD  Recast Cliff output is bit-identical to the hashes pinned before slope_solve was factored out of it.
#     Control: a changed talus angle changes the hash.
# SE  Input -> Slope -> Output equals the forced GDScript evaluator on every output, is native_supported,
#     and the op is in graph_op_ids with no standard mask. Controls: degrees is not aspect; a bogus op is
#     not in graph_op_ids.
# SF  a NaN cell reads NaN degrees and mask 0. Control: a cell far from it is finite.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSlopeGate.tscn
extends Node

const Slope = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_slope.gd")
const RECT := Rect2(-1024.0, -1024.0, 2048.0, 2048.0)
const N := 128
# Pinned from the build BEFORE the refactor (2026-11-11), by _recast() below.
const RECAST_HASHES := [3463529423, 2145077711]

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphSlopeGate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "slope_grid"):
		_check(false, "slope_grid is not bound — rebuild the GDExtension")
	else:
		_sa()
		_sb()
		_sc()
		_sd()
		_se()
		_sf()
	_check(_ran == 6, "all 6 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["SLOPE PASS" if _fail == 0 else "SLOPE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


static func _cell(p_i: int, p_n: int) -> Vector2:
	var d := RECT.size.x / p_n
	return Vector2(RECT.position.x + (p_i % p_n + 0.5) * d, RECT.position.y + (p_i / p_n + 0.5) * d)


## A plane falling `p_deg` toward compass bearing `p_bearing` (0 north = -Z, 90 east = +X).
static func _plane(p_n: int, p_deg: float, p_bearing: float) -> PackedFloat32Array:
	var b := deg_to_rad(p_bearing)
	var down := Vector2(sin(b), -cos(b))
	var t := tan(deg_to_rad(p_deg))
	var h := PackedFloat32Array()
	h.resize(p_n * p_n)
	for i in p_n * p_n:
		h[i] = -t * _cell(i, p_n).dot(down)
	return h


func _run(p_node: Pasture3DGraphNode, p_h: PackedFloat32Array, p_n: int = N) -> Array:
	return p_node.eval_grid_channels([p_h], p_n, p_n, null, RECT)


func _sa() -> void:
	print("[SA] a tilted plane reads its angle and dip direction")
	var worst_d := 0.0
	var worst_a := 0.0
	var per_cell := []
	for n in [64, 128]:
		var h := _plane(n, 20.0, 120.0)
		var r := _run(Slope.new(), h, n)
		for i in n * n:
			worst_d = maxf(worst_d, absf(r[0][i] - 20.0))
			worst_a = maxf(worst_a, absf(r[2][i] - 120.0))
		# The wrong slope: rise per CELL, no division by the cell size.
		per_cell.append(rad_to_deg(atan(absf(h[n * (n / 2) + n / 2 + 1] - h[n * (n / 2) + n / 2 - 1]) * 0.5)))
	_check(worst_d <= 0.05, "degrees vs 20: worst %.5f" % worst_d)
	_check(worst_a <= 0.5, "aspect vs 120: worst %.5f" % worst_a)
	_check(absf(per_cell[0] - per_cell[1]) > 1.0, "control: a per-cell rise reads %.2f° vs %.2f°" % per_cell)
	_ran += 1


func _sb() -> void:
	print("[SB] the band mask")
	var k := 0.0006 # h = k·r², slope atan(2 k r): 0° at the centre to ~60° at the corners
	var h := PackedFloat32Array()
	h.resize(N * N)
	for i in N * N:
		h[i] = k * _cell(i, N).length_squared()
	var n := Slope.new()
	n.min_angle = 30.0
	n.max_angle = 50.0
	n.falloff = 5.0
	var r := _run(n, h)
	var inside := 0.0
	var outside := 0.0
	var area := 0.0
	for i in N * N:
		var d: float = r[0][i]
		if d >= 30.0 and d <= 50.0:
			inside = maxf(inside, absf(r[1][i] - 1.0))
		elif d < 25.0 or d > 55.0:
			outside = maxf(outside, r[1][i])
		area += r[1][i]
	_check(inside <= 1e-6, "inside the band reads 1: worst %.7f" % inside)
	_check(outside <= 1e-6, "beyond falloff reads 0: worst %.7f" % outside)
	n.min_angle = 20.0
	var wider := 0.0
	for v in _run(n, h)[1]:
		wider += v
	_check(wider > area * 1.05, "control: a wider band covers %.0f vs %.0f cells" % [wider, area])
	_ran += 1


func _sc() -> void:
	print("[SC] scale reads the hillside, not the cell")
	var h := _plane(N, 20.0, 45.0)
	for i in N * N:
		h[i] += 6.0 * (float((i * 7919) % 13) / 12.0 - 0.5)
	var n := Slope.new()
	n.scale = 50.0
	var smooth: PackedFloat32Array = _run(n, h)[0]
	n.scale = 0.0
	var raw: PackedFloat32Array = _run(n, h)[0]
	var ws := 0.0
	var wr := 0.0
	for iz in range(8, N - 8):
		for ix in range(8, N - 8):
			ws = maxf(ws, absf(smooth[iz * N + ix] - 20.0))
			wr = maxf(wr, absf(raw[iz * N + ix] - 20.0))
	_check(ws <= 2.0, "scale 50 m: worst %.3f° off the plane" % ws)
	_check(wr > 2.0, "control: scale 0 is %.3f° off" % wr)
	_ran += 1


## The fixture the hashes were pinned with. Do not change it without re-pinning from a known-good build.
static func _recast(p_talus: float) -> Array:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for iz in N:
		for ix in N:
			var x := float(ix)
			var z := float(iz)
			h[iz * N + ix] = 80.0 * sin(x * 0.11) * cos(z * 0.07) + 40.0 * sin((x + 2.0 * z) * 0.23) + 0.6 * x * x / N
	h[N * 40 + 50] = NAN
	var a := Pasture3DUtil.recast_cliff_grid(h, N, N, RECT, p_talus, 64.0, 12.0, 4.0, -1.0, 45.0, 1.0)
	var b := Pasture3DUtil.recast_cliff_grid(h, N, N, RECT, 22.0, 48.0, -9.0, 2.5, 135.0, 60.0, 0.7)
	return [hash(a), hash(b)]


func _sd() -> void:
	print("[SD] Recast Cliff unchanged by the refactor")
	var got := _recast(30.0)
	_check(got == RECAST_HASHES, "hashes %s == pinned %s" % [got, RECAST_HASHES])
	_check(_recast(31.0)[0] != RECAST_HASHES[0], "control: talus 31° changes the hash")
	_ran += 1


func _graph(p_port: int) -> Pasture3DTerrainGraph:
	var n := Slope.new()
	n.scale = 40.0
	n.min_angle = 15.0
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeRegistry.create(&"input"), n,
			Pasture3DGraphNodeRegistry.create(&"output")]
	var g := Pasture3DTerrainGraph.create_empty()
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, p_port, 2, 0])]
	return g


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _se() -> void:
	print("[SE] the compiled graph route equals the GDScript evaluator")
	var h := PackedFloat32Array()
	h.resize(N * N)
	for i in N * N:
		var c := _cell(i, N)
		h[i] = 150.0 * sin(c.x * 0.004) * cos(c.y * 0.006) + 0.1 * c.x
	var outs := []
	var native := true
	for port in 3:
		var g := _graph(port)
		native = native and g.native_supported()
		var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), N, N, RECT, h)
		var g2 := _graph(port)
		g2.force_gdscript_evaluation = true
		var ora: PackedFloat32Array = g2.evaluate(N, N, RECT, null, h)
		_check(_worst(nat, ora) <= 1e-4, "output %d: worst %.7f" % [port, _worst(nat, ora)])
		outs.append(nat)
	_check(native, "all three graphs are native_supported")
	_check(_worst(outs[0], outs[2]) > 1.0, "control: degrees is not aspect")
	var has_mask := false
	for p in Slope.new().input_ports():
		has_mask = has_mask or p.id == &"mask"
	_check(not has_mask, "no standard mask")
	var ids: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(ids.has("slope") or ids.has(&"slope"), "slope is a native op")
	_check(not (ids.has("slope_bogus") or ids.has(&"slope_bogus")), "control: a bogus op is not")
	_ran += 1


func _sf() -> void:
	print("[SF] no data reads no slope")
	var h := _plane(N, 20.0, 0.0)
	var hole := N * 60 + 60
	h[hole] = NAN
	var r := _run(Slope.new(), h)
	_check(is_nan(r[0][hole]) and r[1][hole] == 0.0, "NaN cell: degrees %s, mask %s" % [r[0][hole], r[1][hole]])
	_check(is_finite(r[0][N * 10 + 10]), "control: a far cell reads %.3f" % r[0][N * 10 + 10])
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
