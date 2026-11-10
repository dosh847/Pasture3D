# GraphSaleveRetentionGate — Stage 1 keeps the input's shape and still erodes it.
#
# Stage 1 used to rebuild the terrain as a distance from the outlets, and no gate saw it: they tested the
# routing, the rim and the margin, and all of those passed. Every criterion here reads the output against the
# input. The controls that must fail are that old surface (a distance from the border), computed directly,
# since a metric that cannot reject it proves nothing.
extends Node

const DevHydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")
const HydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_saleve.gd")

const GW := 256
const RECT := Rect2(0, 0, 1024, 1024)
const CELL := 4.0
const EXPECTED := 7
const STAGE1 := {"default_warp": false, "deposition_strength": 0.0, "stream_strength": 0.0, "erosion_strength": 1.0}

var _fail := 0
var _done := 0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	print("=== GraphSaleveRetentionGate: Salève Stage 1 keeps the input's shape ===")
	_noise.seed = 7
	_noise.frequency = 0.008
	_noise.fractal_octaves = 4
	_a_moved_mountain()
	_b_fine_shape()
	_c_summit()
	_d_never_above_input()
	_e_valleys_not_blocks()
	_f_reference_relief()
	_g_point_cap()
	var ok := _fail == 0 and _done == EXPECTED
	print("=== SALEVE RETENTION %s (%d failures, %d/%d criteria completed) ===" % ["PASS" if ok else "FAIL", _fail, _done, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _a_moved_mountain() -> void:
	print("\n[A] move the mountain and the output moves with it")
	var west := _island("west")
	var east := _island("east")
	var land := _land(west)
	var r_in := _corr(west, east, land)
	var r_out := _corr(_stage1(west), _stage1(east), land)
	var dist := _border_distance()
	var r_control := _corr(_old_surface(west, dist), _old_surface(east, dist), land)
	print("    r(inputs) %.3f, r(outputs) %.3f (want within 0.2); control distance surface %.3f (want beyond 0.2)" % [r_in, r_out, r_control])
	if absf(r_control - r_in) <= 0.2:
		_fail += 1
		print("    !! the control is not rejected, so the metric is blind")
		return
	if absf(r_out - r_in) > 0.2:
		_fail += 1
		print("    !! the output does not follow the input")
		return
	_done += 1


func _b_fine_shape() -> void:
	print("\n[B] shapes finer than the control points survive")
	var dist := _border_distance()
	var worst := 1.0
	var control := -1.0
	for kind in ["rough", "canyon"]:
		var src := _island(kind)
		var land := _land(src)
		var r := _corr_detail(src, _stage1(src), land)
		var c := _corr_detail(src, _old_surface(src, dist), land)
		print("    %s: r_detail %.3f (want > 0.7); control distance surface %.3f (want < 0.7)" % [kind, r, c])
		worst = minf(worst, r)
		control = maxf(control, c)
	if control >= 0.7:
		_fail += 1
		print("    !! the control is not rejected, so the metric is blind")
		return
	if worst <= 0.7:
		_fail += 1
		print("    !! the input's detail is gone")
		return
	_done += 1


func _c_summit() -> void:
	print("\n[C] the summit stays where it was, at about its height")
	var src := _island("west")
	var out := _stage1(src)
	var at := _argmax(src)
	var moved := Vector2(at % GW - _argmax(out) % GW, at / GW - _argmax(out) / GW).length() * CELL
	var drop: float = src[at] - _max(out)
	var dist := _border_distance()
	var control := _old_surface(src, dist)
	var control_moved := Vector2(at % GW - _argmax(control) % GW, at / GW - _argmax(control) / GW).length() * CELL
	print("    peak moved %.0f m (want < 100), peak fell %.1f of %.1f m (want < 25%%); control peak moved %.0f m (want >= 100)" % [moved, drop, src[at], control_moved])
	if control_moved < 100.0:
		_fail += 1
		print("    !! the control is not rejected, so the metric is blind")
		return
	if moved >= 100.0 or drop >= 0.25 * src[at]:
		_fail += 1
		print("    !! the summit did not survive")
		return
	_done += 1


func _d_never_above_input() -> void:
	print("\n[D] nothing rises above the input except a flooded pit")
	var cone := _field(func(x: float, z: float) -> float:
		return maxf(0.0, 150.0 - 0.5 * Vector2(x - 512.0, z - 512.0).length()))
	var pit := cone.duplicate()
	for iz in range(GW):
		for ix in range(GW):
			var d := Vector2(ix * CELL - 400.0, iz * CELL - 512.0).length()
			pit[iz * GW + ix] -= 40.0 * exp(-pow(d / 30.0, 2.0))
	var plain := _max_raise(cone, _stage1(cone))
	# Barely any cut in the control arm, or a channel below the pit drains it and there is nothing to flood.
	var flooded := _max_raise(pit, _stage1(pit, {"drainage_exponent": 0.01}))
	print("    raise on a cone %.4f m (want < 0.1); control flooded pit %.2f m (want > 1)" % [plain, flooded])
	if flooded <= 1.0:
		_fail += 1
		print("    !! a closed pit did not flood, so the measure is blind")
		return
	if plain >= 0.1:
		_fail += 1
		print("    !! Stage 1 raised ground that has no pit")
		return
	_done += 1


func _e_valleys_not_blocks() -> void:
	print("\n[E] it cuts valleys, not whole catchments and not nothing")
	var src := _island("rough")
	var land := _land(src)
	var out := _stage1(src)
	var deepest := _deepest(src, out, land)
	var share := _cut_share(src, out, land, 0.25 * deepest)
	var weak := _deepest(src, _stage1(src, {"drainage_exponent": 0.01, "shape_preservation": 4.0}), land)
	var no_walls := _stage1(src, {"max_slope_center": 0.0, "max_slope_border": 0.0})
	var blocks := _cut_share(src, no_walls, land, 0.25 * _deepest(src, no_walls, land))
	print("    deepest %.1f m (want > 10); control no drainage response %.1f m (want under half of it)" % [deepest, weak])
	print("    land cut past a quarter of that: %.2f (want < 0.5); control no walls %.2f (want above it by 0.1)" % [share, blocks])
	if weak >= 0.5 * deepest or blocks < share + 0.1:
		_fail += 1
		print("    !! a control did not separate, so the check is blind")
		return
	if deepest <= 10.0 or share >= 0.5:
		_fail += 1
		print("    !! the cut is not a set of valleys")
		return
	_done += 1


func _f_reference_relief() -> void:
	print("\n[F] Reference Relief does not scale the output")
	var src := _island("west")
	var pinned := _stage1(src, {"reference_relief": 400.0})
	var peak := _max(src)
	var lo := _min(src)
	var scaled := src.duplicate()
	for i in range(scaled.size()):
		scaled[i] = lo + (src[i] - lo) * 400.0 / (peak - lo)
	print("    input peak %.1f m, pinned to 400 m output %.1f m (want no higher); control the old scaling %.1f m (want higher)" % [peak, _max(pinned), _max(scaled)])
	if _max(scaled) <= peak + 1.0:
		_fail += 1
		print("    !! the control did not rise, so the check is blind")
		return
	if _max(pinned) > peak + 0.01:
		_fail += 1
		print("    !! the pinned relief scaled the output")
		return
	_done += 1


# ---- fixtures --------------------------------------------------------------------------------------

# A spacing is a point count over the area, and 1 m over the demo's plows asked for up to 2.6 million points
# and froze the editor. The cap is lowered for this fixture, so no criterion here has to solve 100000 points:
# the shipped value is only read off the node's clamp. The capped solve must be bit-identical to asking for
# that many points directly, which is what "widens to fit" means; the control is the same spacing uncapped.
func _g_point_cap() -> void:
	print("\n[G] a Point Spacing past the cap widens to fit it")
	var src := _island("rough")
	var uncapped := _stage1(src, {"point_spacing": 5.0})
	var capped := _stage1(src, {"point_spacing": 5.0, "max_control_points": 2000})
	var asked := _stage1(src, {"control_points": 2000})
	var clear := _stage1(src, {"point_spacing": 5.0, "max_control_points": 50000})
	var differs := _max_abs_diff(capped, uncapped)
	print("    capped vs 2000 points %.6f m (want 0); capped vs uncapped %.3f m (control, want > 0.1); cap above the request vs uncapped %.6f m (want 0)" % [_max_abs_diff(capped, asked), differs, _max_abs_diff(clear, uncapped)])
	if differs <= 0.1:
		_fail += 1
		print("    !! the cap changed nothing, so the comparison is blind")
		return
	if capped != asked:
		_fail += 1
		print("    !! the capped solve is not the solve for that many points")
		return
	if clear != uncapped:
		_fail += 1
		print("    !! a cap the request never reached moved the lattice")
		return
	var params := STAGE1.merged({"point_spacing": 5.0, "max_control_points": 2000}, true)
	var oracle: PackedFloat32Array = DevHydraulicSaleve.solve_gd(src, GW, GW, RECT, params)[0]
	var oracle_gap := _max_abs_diff(oracle, capped)
	print("    capped native vs oracle %.6f m (want < 0.01)" % oracle_gap)
	if oracle_gap >= 0.01:
		_fail += 1
		print("    !! the oracle and native disagree at the cap")
		return
	var node := HydraulicSaleve.new()
	node.control_points = 5000000
	print("    node clamp %d (want 100000)" % node.control_points)
	if node.control_points != 100000:
		_fail += 1
		print("    !! the node still accepts more points than the solver cap")
		return
	_done += 1


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in p_a.size():
		worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _stage1(p_src: PackedFloat32Array, p_extra: Dictionary = {}) -> PackedFloat32Array:
	return Pasture3DUtil.hydraulic_saleve_solve_grid(p_src, GW, GW, RECT, STAGE1.merged(p_extra, true))["height"]


func _field(p_f: Callable) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GW)
	for iz in range(GW):
		for ix in range(GW):
			a[iz * GW + ix] = p_f.call((ix + 0.5) * CELL, (iz + 0.5) * CELL)
	return a


## An island: shore at about 430 m, sea floor -30, broad 60 m land, carrying one feature.
func _island(p_kind: String) -> PackedFloat32Array:
	return _field(func(x: float, z: float) -> float:
		var r := Vector2(x - 512.0, z - 512.0).length()
		var v := lerpf(60.0, -30.0, smoothstep(350.0, 470.0, r))
		match p_kind:
			"west":
				v += _gauss(x, z, 330.0, 512.0, 90.0, 220.0, 120.0)
			"east":
				v += _gauss(x, z, 700.0, 512.0, 90.0, 220.0, 120.0)
			"rough":
				v += _gauss(x, z, 450.0, 450.0, 180.0, 180.0, 100.0) + 35.0 * _noise.get_noise_2d(x, z) * smoothstep(470.0, 350.0, r)
			"canyon":
				var block := smoothstep(300.0, 220.0, r)
				v += 100.0 * block - 70.0 * exp(-pow((x - 512.0 + 0.3 * (z - 512.0)) / 30.0, 2.0)) * block
		return v)


func _gauss(p_x: float, p_z: float, p_cx: float, p_cz: float, p_sx: float, p_sz: float, p_a: float) -> float:
	return p_a * exp(-(pow((p_x - p_cx) / p_sx, 2.0) + pow((p_z - p_cz) / p_sz, 2.0)))


func _border_distance() -> PackedFloat32Array:
	return _field(func(x: float, z: float) -> float: return minf(minf(x, 1024.0 - x), minf(z, 1024.0 - z)))


## What Stage 1 used to return: height as a function of distance from the outlets, over the input's range.
func _old_surface(p_src: PackedFloat32Array, p_dist: PackedFloat32Array) -> PackedFloat32Array:
	var lo := _min(p_src)
	var span := _max(p_src) - lo
	var far := _max(p_dist)
	var out := PackedFloat32Array()
	out.resize(p_src.size())
	for i in range(out.size()):
		out[i] = lo + span * p_dist[i] / far
	return out


# ---- metrics ---------------------------------------------------------------------------------------

func _land(p_h: PackedFloat32Array) -> PackedByteArray:
	var s := PackedByteArray()
	s.resize(p_h.size())
	for i in range(p_h.size()):
		s[i] = 1 if p_h[i] > 5.0 else 0
	return s


func _corr(p_a: PackedFloat32Array, p_b: PackedFloat32Array, p_sel: PackedByteArray) -> float:
	var ma := 0.0
	var mb := 0.0
	var c := 0
	for i in range(p_a.size()):
		if p_sel[i] == 1:
			ma += p_a[i]
			mb += p_b[i]
			c += 1
	ma /= c
	mb /= c
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(p_a.size()):
		if p_sel[i] == 1:
			sab += (p_a[i] - ma) * (p_b[i] - mb)
			saa += (p_a[i] - ma) * (p_a[i] - ma)
			sbb += (p_b[i] - mb) * (p_b[i] - mb)
	return sab / maxf(sqrt(saa * sbb), 1.0e-9)


## Correlation of what a 15-cell box blur removes: the detail, without the large form that always correlates.
func _corr_detail(p_a: PackedFloat32Array, p_b: PackedFloat32Array, p_sel: PackedByteArray) -> float:
	return _corr(_detail(p_a), _detail(p_b), p_sel)


func _detail(p_a: PackedFloat32Array) -> PackedFloat32Array:
	const R := 15
	var t := p_a.duplicate()
	var o := p_a.duplicate()
	for iz in range(GW):
		var acc := 0.0
		for ix in range(-R, GW):
			if ix + R < GW:
				acc += p_a[iz * GW + ix + R]
			if ix - R - 1 >= 0:
				acc -= p_a[iz * GW + ix - R - 1]
			if ix >= 0:
				t[iz * GW + ix] = acc / (mini(ix + R, GW - 1) - maxi(ix - R, 0) + 1)
	for ix in range(GW):
		var acc := 0.0
		for iz in range(-R, GW):
			if iz + R < GW:
				acc += t[(iz + R) * GW + ix]
			if iz - R - 1 >= 0:
				acc -= t[(iz - R - 1) * GW + ix]
			if iz >= 0:
				o[iz * GW + ix] = p_a[iz * GW + ix] - acc / (mini(iz + R, GW - 1) - maxi(iz - R, 0) + 1)
	return o


func _deepest(p_src: PackedFloat32Array, p_out: PackedFloat32Array, p_sel: PackedByteArray) -> float:
	var m := 0.0
	for i in range(p_src.size()):
		if p_sel[i] == 1:
			m = maxf(m, p_src[i] - p_out[i])
	return m


func _cut_share(p_src: PackedFloat32Array, p_out: PackedFloat32Array, p_sel: PackedByteArray, p_depth: float) -> float:
	var hit := 0
	var all := 0
	for i in range(p_src.size()):
		if p_sel[i] == 1:
			all += 1
			if p_src[i] - p_out[i] > p_depth:
				hit += 1
	return float(hit) / maxf(float(all), 1.0)


func _max_raise(p_src: PackedFloat32Array, p_out: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(p_src.size()):
		m = maxf(m, p_out[i] - p_src[i])
	return m


func _argmax(p_a: PackedFloat32Array) -> int:
	var b := 0
	for i in range(p_a.size()):
		if p_a[i] > p_a[b]:
			b = i
	return b


func _max(p_a: PackedFloat32Array) -> float:
	return p_a[_argmax(p_a)]


func _min(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m
