# GraphSaleveJaggedGate — Salève Stage 1 cuts valleys without standing fins and spikes between them.
#
# Valley walls climbing at one slope meet in knife crests, and Stage 1 only bounded the edge from a vertex to its
# receiver, so the default erosion stood fins on steep faces. Every older gate passed: they measure routing, the rim
# and how much of the input survives, and a fin is input surviving. These criteria read the shape of the cut.
# Each control turns one mechanism off and must fail.
extends Node

const DevHydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")
const HydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_saleve.gd")

const GW := 512
const RECT := Rect2(0, 0, 1024, 1024)
const CELL := 2.0
const EXPECTED := 8
const STAGE1 := {"deposition_strength": 0.0, "stream_strength": 0.0, "erosion_strength": 1.0}
const OFF := {"valley_smoothing": -1.0, "limit_edges": false}
const CAP := 1.5

var _fail := 0
var _done := 0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	print("=== GraphSaleveJaggedGate: Salève cuts valleys, not fins ===")
	_noise.seed = 11
	_noise.frequency = 0.02
	_noise.fractal_octaves = 3
	var src := _ridge(GW, RECT.size.x)
	_a_no_spikes(src)
	_b_edges_at_the_cap(src)
	_c_grid_slope(src)
	_d_point_count(src)
	_e_valleys_survive(src)
	_f_input_detail(src)
	_g_native_route()
	_h_oracle()
	var ok := _fail == 0 and _done == EXPECTED
	print("=== SALEVE JAGGED %s (%d failures, %d/%d criteria completed) ===" % ["PASS" if ok else "FAIL", _fail, _done, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _a_no_spikes(p_src: PackedFloat32Array) -> void:
	print("\n[A] the default stands no spikes on steep faces")
	var on := _spikes(_solve(p_src, {"erosion_strength": 1.0}).height)
	var off := _spikes(_solve(p_src, OFF.merged({"erosion_strength": 1.0})).height)
	print("    spikes %d (want at most 1); both mechanisms off %d (want over 5); input %d" % [on, off, _spikes(p_src)])
	if off <= 5:
		_fail += 1
		print("    !! the control stands no spikes, so the metric is blind")
		return
	if on > 1:
		_fail += 1
		print("    !! spikes survive the fix")
		return
	_done += 1


func _b_edges_at_the_cap(p_src: PackedFloat32Array) -> void:
	print("\n[B] Max Slope holds on every mesh edge, not only the edge to a receiver")
	var on := _worst_edge(p_src, STAGE1)
	var off := _worst_edge(p_src, STAGE1.merged({"limit_edges": false}))
	print("    worst excess over the cap %.3f m/m (want under 0.02); limiter off %.3f m/m (want over 0.5)" % [on, off])
	if off <= 0.5:
		_fail += 1
		print("    !! the control keeps to the cap, so this edge audit sees nothing")
		return
	if on >= 0.02:
		_fail += 1
		print("    !! an edge stands over the cap")
		return
	_done += 1


func _c_grid_slope(p_src: PackedFloat32Array) -> void:
	print("\n[C] the grid keeps to the cap too: smoothing removes the crests and the triangle facets")
	var on := _p99_slope(_solve(p_src, STAGE1).height)
	var off := _p99_slope(_solve(p_src, STAGE1.merged({"valley_smoothing": -1.0})).height)
	print("    p99 slope %.2f (want under %.2f); smoothing off %.2f (want over %.2f)" % [on, CAP * 1.1, off, CAP * 1.1])
	if off <= CAP * 1.1:
		_fail += 1
		print("    !! the control keeps to the cap on the grid")
		return
	if on >= CAP * 1.1:
		_fail += 1
		print("    !! the grid stands over the cap")
		return
	_done += 1


# A mean can stay put while the field moves, so this compares the cut as a field at a scale the mesh does not reach.
func _d_point_count(p_src: PackedFloat32Array) -> void:
	print("\n[D] the point count does not change how much erodes where")
	var counts := [4000, 50000]
	var auto := []
	var old := []
	var means := PackedStringArray()
	for c in counts:
		var a := _cut(p_src, _solve(p_src, STAGE1.merged({"control_points": c})).height)
		means.append("%d points %.2f m" % [c, _mean(a)])
		auto.append(_box(a, 24))
		var v := 8.0 * RECT.size.x * RECT.size.y / float(c)
		old.append(_box(_cut(p_src, _solve(p_src, STAGE1.merged({"control_points": c, "channel_area": v})).height), 24))
	var d_auto := _rel_rms(auto[0], auto[1])
	var d_old := _rel_rms(old[0], old[1])
	print("    %s; field difference %.2f (want under 1.0); channel area of 8 vertices %.2f (want over 1.0)" % [", ".join(means), d_auto, d_old])
	if d_old <= 1.0:
		_fail += 1
		print("    !! the old vertex-sized channel area does not move the field, so this measures nothing")
		return
	if d_auto >= 1.0:
		_fail += 1
		print("    !! the erosion still follows the point count")
		return
	_done += 1


func _e_valleys_survive(p_src: PackedFloat32Array) -> void:
	print("\n[E] smoothing rounds the valleys without erasing them")
	var sharp := _cut(p_src, _solve(p_src, STAGE1.merged({"valley_smoothing": -1.0})).height)
	var round_cut := _cut(p_src, _solve(p_src, STAGE1).height)
	var wide := _cut(p_src, _solve(p_src, STAGE1.merged({"valley_smoothing": 200.0})).height)
	var deep_on := _max(round_cut) / _max(sharp)
	var deep_wide := _max(wide) / _max(sharp)
	var mean_on := _mean(round_cut) / _mean(sharp)
	print("    deepest cut %.2f of unsmoothed, mean %.2f (want over 0.6 and 0.85); 200 m smoothing deepest %.2f (want under 0.6)" % [deep_on, mean_on, deep_wide])
	if deep_wide >= 0.6:
		_fail += 1
		print("    !! the control keeps its valleys, so this cannot see them being erased")
		return
	if deep_on <= 0.6 or mean_on <= 0.85:
		_fail += 1
		print("    !! smoothing erased the valleys")
		return
	_done += 1


func _f_input_detail(p_src: PackedFloat32Array) -> void:
	print("\n[F] the cut is what is smoothed, so the input's own fine detail stays")
	var ripple := PackedFloat32Array()
	ripple.resize(GW * GW)
	var rippled := p_src.duplicate()
	for z in GW:
		for x in GW:
			ripple[z * GW + x] = sin(TAU * x / 5.0) * sin(TAU * z / 5.0)
			rippled[z * GW + x] += ripple[z * GW + x]
	var out: PackedFloat32Array = _solve(rippled, STAGE1).height
	var kept := _project(out, ripple)
	var surface_blur := _project(_box3(out, 3), ripple)
	print("    ripple kept %.3f (want over 0.9); the surface smoothed instead %.3f (want under 0.5)" % [kept, surface_blur])
	if surface_blur >= 0.5:
		_fail += 1
		print("    !! the control keeps the ripple, so this cannot see it go")
		return
	if kept <= 0.9:
		_fail += 1
		print("    !! the input's fine detail did not survive")
		return
	_done += 1


func _g_native_route() -> void:
	print("\n[G] Valley Smoothing reaches the native program")
	var graph := Pasture3DTerrainGraph.create_empty()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var node = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	node.control_points = 2500
	node.valley_smoothing = 30.0
	var id_cone: int = graph.add_node(cone)
	var id_sal: int = graph.add_node(node)
	graph.connect_ports(id_cone, 0, id_sal, 0)
	var rect := Rect2(0, 0, 256, 256)
	var n := 128
	var surface: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(id_cone), n, n, rect, PackedFloat32Array())
	var native: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(id_sal), n, n, rect, PackedFloat32Array())
	var dict_route: PackedFloat32Array = node._solve_dynamic(surface, n, n, rect, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array())[0]
	node.valley_smoothing = 0.0
	var auto_route: PackedFloat32Array = node._solve_dynamic(surface, n, n, rect, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array())[0]
	var d_route := _max_err(native, dict_route)
	var d_ctrl := _max_err(native, auto_route)
	print("    native vs dictionary route %.6f m (want under 0.0001); against auto smoothing %.4f m (want over 0.01)" % [d_route, d_ctrl])
	if native.size() != n * n or d_ctrl <= 0.01:
		_fail += 1
		print("    !! the setting never reached the native solve")
		return
	if d_route >= 1.0e-4:
		_fail += 1
		print("    !! the native program and the node's own solve disagree")
		return
	_done += 1


func _h_oracle() -> void:
	print("\n[H] the GDScript oracle does the same, both mechanisms on")
	var n := 128
	var rect := Rect2(0, 0, 512, 512)
	var src := _ridge(n, rect.size.x)
	var params := {"control_points": 1500, "erosion_strength": 1.0, "deposition_strength": 0.0, "stream_strength": 0.0}
	var native: PackedFloat32Array = Pasture3DUtil.hydraulic_saleve_solve_grid(src, n, n, rect, params).height
	var oracle: PackedFloat32Array = DevHydraulicSaleve.solve_gd(src, n, n, rect, params)[0]
	var no_smooth: PackedFloat32Array = DevHydraulicSaleve.solve_gd(src, n, n, rect, params.merged({"valley_smoothing": -1.0}))[0]
	var no_limit: PackedFloat32Array = DevHydraulicSaleve.solve_gd(src, n, n, rect, params.merged({"limit_edges": false}))[0]
	var d := _max_err(native, oracle)
	var d_smooth := _max_err(native, no_smooth)
	var d_limit := _max_err(native, no_limit)
	print("    native vs oracle %.5f m (want under 0.01); oracle without smoothing %.3f m, without the limiter %.3f m (want over 0.05)" % [d, d_smooth, d_limit])
	if d_smooth <= 0.05 or d_limit <= 0.05:
		_fail += 1
		print("    !! a mechanism changes nothing here, so parity says nothing about it")
		return
	if d >= 0.01:
		_fail += 1
		print("    !! the routes disagree")
		return
	_done += 1


# ---- Helpers ---------------------------------------------------------------------------------------

func _solve(p_src: PackedFloat32Array, p_extra: Dictionary) -> Dictionary:
	return Pasture3DUtil.hydraulic_saleve_solve_grid(p_src, GW, GW, RECT, p_extra)


# A long ridge with planar faces at 0.8 m/m over a plain, 190 m of relief. Small noise breaks the symmetry.
func _ridge(p_n: int, p_size: float) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(p_n * p_n)
	var cell := p_size / float(p_n)
	var half := p_size * 0.3
	for z in p_n:
		for x in p_n:
			var wx := (x + 0.5) * cell - p_size * 0.5
			var wz := (z + 0.5) * cell - p_size * 0.5
			var dx := maxf(absf(wx) - half, 0.0)
			var d := sqrt(dx * dx + wz * wz)
			o[z * p_n + x] = maxf(190.0 - 0.8 * d, 0.0) + 4.0 * _noise.get_noise_2d((x + 0.5) * cell, (z + 0.5) * cell)
	return o


# The tallest within 12 m, standing more than 8 m over the mean of a 12 m ring.
func _spikes(a: PackedFloat32Array) -> int:
	var count := 0
	var r := int(12.0 / CELL)
	for z in range(r + 1, GW - r - 1, 2):
		for x in range(r + 1, GW - r - 1, 2):
			var top := true
			var ring := 0.0
			for k in 16:
				var ang := TAU * k / 16.0
				var q := a[(z + int(r * sin(ang))) * GW + x + int(r * cos(ang))]
				ring += q
				if q >= a[z * GW + x]:
					top = false
					break
			if top and a[z * GW + x] - ring / 16.0 > 8.0:
				count += 1
	return count


# How far the steepest mesh edge stands over the cap, where the input's own slope along it is not steeper.
func _worst_edge(p_src: PackedFloat32Array, p_extra: Dictionary) -> float:
	var o := _solve(p_src, p_extra.merged({"debug_network": true}))
	var v: PackedVector2Array = o.vertices
	var h: PackedFloat32Array = o.vertex_height
	var pairs: PackedInt32Array = o.vertex_neighbors
	var rec: PackedInt32Array = o.receivers
	var inner := RECT.grow(-16.0)
	var worst := -INF
	var edges := 0
	for k in range(0, pairs.size(), 2):
		var a := pairs[k]
		var b := pairs[k + 1]
		if rec[a] == a or rec[b] == b or not inner.has_point(v[a]) or not inner.has_point(v[b]):
			continue # outlets stay at the input by contract
		var d := v[a].distance_to(v[b])
		var input_slope := absf(_sample(p_src, v[a]) - _sample(p_src, v[b])) / d
		worst = maxf(worst, absf(h[a] - h[b]) / d - maxf(CAP, input_slope + 0.05))
		edges += 1
	if edges == 0:
		return INF
	return worst


func _sample(a: PackedFloat32Array, p: Vector2) -> float:
	var fx := clampf(p.x / CELL - 0.5, 0.0, GW - 1.001)
	var fz := clampf(p.y / CELL - 0.5, 0.0, GW - 1.001)
	var x := int(fx)
	var z := int(fz)
	return lerpf(lerpf(a[z * GW + x], a[z * GW + x + 1], fx - x), lerpf(a[(z + 1) * GW + x], a[(z + 1) * GW + x + 1], fx - x), fz - z)


func _p99_slope(a: PackedFloat32Array) -> float:
	var s := PackedFloat32Array()
	for z in range(8, GW - 8):
		for x in range(8 + z % 3, GW - 8, 3):
			var gx := (a[z * GW + x + 1] - a[z * GW + x]) / CELL
			var gz := (a[(z + 1) * GW + x] - a[z * GW + x]) / CELL
			s.append(sqrt(gx * gx + gz * gz))
	s.sort()
	return s[int(s.size() * 0.99)]


func _cut(p_src: PackedFloat32Array, p_out: PackedFloat32Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(GW * GW)
	for i in GW * GW:
		o[i] = maxf(p_src[i] - p_out[i], 0.0)
	return o


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


func _box(a: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var t := a.duplicate()
	var o := a.duplicate()
	var inv := 1.0 / float(2 * r + 1)
	for z in GW:
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += a[z * GW + clampi(k, 0, GW - 1)]
		for x in GW:
			t[z * GW + x] = acc * inv
			acc += a[z * GW + mini(x + r + 1, GW - 1)] - a[z * GW + maxi(x - r, 0)]
	for x in GW:
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += t[clampi(k, 0, GW - 1) * GW + x]
		for z in GW:
			o[z * GW + x] = acc * inv
			acc += t[mini(z + r + 1, GW - 1) * GW + x] - t[maxi(z - r, 0) * GW + x]
	return o


func _box3(a: PackedFloat32Array, r: int) -> PackedFloat32Array:
	return _box(_box(_box(a, r), r), r)


func _rel_rms(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	var norm := 0.0
	for i in a.size():
		diff += (a[i] - b[i]) * (a[i] - b[i])
		norm += 0.5 * (a[i] * a[i] + b[i] * b[i])
	return sqrt(diff / maxf(norm, 1.0e-9))


# How much of the ripple is in the field, 1 = all of it. The ripple's own sum over the grid is near zero, so the
# large-scale terrain contributes nothing to this.
func _project(a: PackedFloat32Array, p_ripple: PackedFloat32Array) -> float:
	var num := 0.0
	var den := 0.0
	for i in a.size():
		num += a[i] * p_ripple[i]
		den += p_ripple[i] * p_ripple[i]
	return num / maxf(den, 1.0e-9)


func _max_err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var m := 0.0
	for i in a.size():
		m = maxf(m, absf(a[i] - b[i]))
	return m
