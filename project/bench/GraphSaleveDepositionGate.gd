# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSaleveDepositionGate: phase S3 of PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md — Stage 2 deposition and
# Stage 3 fine incision.
#
#   A  on the input itself (Stage 1 skipped), deposition never lowers a cell and does fill the crater;
#      control: a plane gets none
#   B  Stage 3 IS the stream-log solver: a direct call on the grid entering Stage 3 reproduces the grid
#      leaving it; control: the same call at another incision rate does not
#   C  stream_strength 0 skips Stage 3 (pre == post); control: the default does not
#   D  mass balance, reported: eroded vs deposited volume
#   E  the rim cap: Stage 1 does not raise the outermost ring above the input; control: lower_only off does
#   F  beyond the rim band Stage 1 equals the free solve; control: the old whole-grid cap does not
#
# Asserts on the solver's own debug_stages grids, not on anything this gate computes for it.

extends Node

const GW := 128
const GH := 128
const RECT := Rect2(0, 0, 256, 256)
const EXPECTED := 6

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphSaleveDepositionGate: Salève S3 deposition and fine incision ===\n")
	_a_deposition()
	_b_stream_log()
	_c_skip()
	_d_mass()
	_e_lower_only()
	_f_masks()
	var ok := _fail == 0 and _done == EXPECTED
	print("\n=== %s (%d failures, %d/%d criteria completed) ===" % [
		"SALEVE DEPOSITION PASS" if ok else "SALEVE DEPOSITION FAIL", _fail, _done, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _a_deposition() -> void:
	print("[A] deposition only raises, and only on concave ground")
	# Stage 1 and the warp skipped: Stage 2 sees the fixtures themselves, so the plane really is a plane.
	var crater := _solve(_crater(), {"skip_stage1": true, "default_warp": false})
	var plane := _solve(_plane(), {"skip_stage1": true, "default_warp": false})
	var full := _max(_solve(_crater(), {}).deposition)
	var dmin := _min(crater.deposition)
	var dmax := _max(crater.deposition)
	var pmax := _max(plane.deposition)
	print("    crater: min %.6f m (want >= 0), max %.4f m (want > 0.01); control plane: max %.6f m (want < 0.0001)"
			% [dmin, dmax, pmax] + "; after Stage 1 max %.4f m (reported)" % full)
	if dmax <= 0.01:
		_fail += 1
		print("    !! the crater deposited nothing, so 'never lowers' is vacuous")
		return
	if dmin < 0.0 or pmax >= 1.0e-4:
		_fail += 1
		print("    !! deposition lowered a cell, or filled ground that holds no water")
		return
	_done += 1


func _b_stream_log() -> void:
	print("\n[B] Stage 3 is the stream-log solver")
	var res := _solve(_crater(), {})
	var pre: PackedFloat32Array = res.pre_stream
	var post: PackedFloat32Array = res.post_stream
	var direct: PackedFloat32Array = Pasture3DUtil.hydraulic_stream_log_solve_grid(pre, GW, GH, RECT,
			{"incision_rate": 0.15, "area_exponent": 0.5}).height
	var other: PackedFloat32Array = Pasture3DUtil.hydraulic_stream_log_solve_grid(pre, GW, GH, RECT,
			{"incision_rate": 0.3, "area_exponent": 0.5}).height
	var d := _max_diff(post, direct)
	var c := _max_diff(post, other)
	var cut := _max_diff(pre, post)
	print("    post vs direct %.7f m (want < 0.00001); control incision 0.3 %.4f m (want > 0.001); stage cut %.4f m"
			% [d, c, cut])
	if c <= 1.0e-3 or cut <= 1.0e-3:
		_fail += 1
		print("    !! the control matched or Stage 3 cut nothing, so agreement measures nothing")
		return
	if d >= 1.0e-5:
		_fail += 1
		print("    !! Stage 3 is not the stream-log solver")
		return
	_done += 1


func _c_skip() -> void:
	print("\n[C] stream_strength 0 skips Stage 3")
	var off := _solve(_crater(), {"stream_strength": 0.0})
	var on := _solve(_crater(), {})
	var d_off := _max_diff(off.pre_stream, off.post_stream)
	var d_on := _max_diff(on.pre_stream, on.post_stream)
	print("    pre vs post: strength 0 %.7f m (want 0); control default %.4f m (want > 0.001)" % [d_off, d_on])
	if d_on <= 1.0e-3:
		_fail += 1
		print("    !! the default cut nothing, so the skip is unobservable")
		return
	if d_off != 0.0:
		_fail += 1
		print("    !! strength 0 still ran Stage 3")
		return
	_done += 1


func _d_mass() -> void:
	print("\n[D] mass balance (reported)")
	var res := _solve(_crater(), {})
	var cell := (RECT.size.x / GW) * (RECT.size.y / GH)
	var eroded := _sum(res.eroded_rock) * cell
	var deposited := _sum(res.sediment) * cell
	print("    eroded %.1f m3, deposited %.1f m3, ratio %.3f" % [eroded, deposited, deposited / maxf(eroded, 1.0e-6)])
	if eroded <= 0.0:
		_fail += 1
		print("    !! nothing eroded")
		return
	_done += 1


func _e_lower_only() -> void:
	print("
[E] the rim meets the input: Stage 1 does not raise the outermost ring")
	var src := _mound()
	var on := _solve(src, {})
	var off := _solve(src, {"lower_only": false})
	var r_on := _ring_raise(on, src)
	var r_off := _ring_raise(off, src)
	print("    outer-ring raise: rim cap %.4f m; control free %.3f m (want > 1, and the cap under 5%% of it)" % [r_on, r_off])
	if r_off <= 1.0:
		_fail += 1
		print("    !! the free steady state raised nothing at the rim, so the cap is unobservable")
		return
	if r_on > 0.05 * r_off:
		_fail += 1
		print("    !! the rim still steps up from the surrounding ground")
		return
	_done += 1


func _f_masks() -> void:
	print("
[F] beyond the rim the solve is free (the cap no longer flattens the texture)")
	var src := _mound()
	var on := _stage1(_solve(src, {}))
	var free := _stage1(_solve(src, {"lower_only": false}))
	var flat := _stage1(_solve(src, {"cap_everywhere": true}))
	var rim := 0.1 * minf(RECT.size.x, RECT.size.y)
	var d_on := 0.0
	var d_flat := 0.0
	for iz in range(GH):
		for ix in range(GW):
			if _edge_dist(ix, iz) <= rim:
				continue
			var i := iz * GW + ix
			d_on = maxf(d_on, absf(on[i] - free[i]))
			d_flat = maxf(d_flat, absf(flat[i] - free[i]))
	print("    interior vs the free solve: rim cap %.6f m (want < 1e-4); control whole-grid cap %.3f m (want > 1)" % [d_on, d_flat])
	if d_flat <= 1.0:
		_fail += 1
		print("    !! the whole-grid cap changed nothing inside, so the comparison is blind")
		return
	if d_on >= 1.0e-4:
		_fail += 1
		print("    !! the rim cap reaches into the interior")
		return
	_done += 1


func _mound() -> PackedFloat32Array:
	return _field(func(u: float, v: float) -> float:
		return 120.0 * maxf(0.0, 1.0 - (u * u + v * v) / 0.12) + 4.0 * u)


## The Stage 1 grid as capped: what enters Stage 2, i.e. pre_stream minus the deposition.
func _stage1(p_res: Dictionary) -> PackedFloat32Array:
	var pre: PackedFloat32Array = p_res.pre_stream
	var dep: PackedFloat32Array = p_res.deposition
	var out := PackedFloat32Array()
	out.resize(pre.size())
	for i in range(pre.size()):
		out[i] = pre[i] - dep[i]
	return out


func _edge_dist(p_ix: int, p_iz: int) -> float:
	var cx := RECT.size.x / GW
	var cz := RECT.size.y / GH
	return minf(minf((p_ix + 0.5) * cx, (GW - 0.5 - p_ix) * cx), minf((p_iz + 0.5) * cz, (GH - 0.5 - p_iz) * cz))


func _ring_raise(p_res: Dictionary, p_src: PackedFloat32Array) -> float:
	var s1 := _stage1(p_res)
	var m := 0.0
	for iz in range(GH):
		for ix in range(GW):
			if ix == 0 or iz == 0 or ix == GW - 1 or iz == GH - 1:
				var i := iz * GW + ix
				m = maxf(m, s1[i] - p_src[i])
	return m


func _max_raise(p_res: Dictionary, p_src: PackedFloat32Array) -> float:
	var pre: PackedFloat32Array = p_res.pre_stream
	var dep: PackedFloat32Array = p_res.deposition
	var m := 0.0
	for i in range(p_src.size()):
		m = maxf(m, pre[i] - dep[i] - p_src[i])
	return m


# ---- helpers ------------------------------------------------------------------------------------

func _solve(p_surface: PackedFloat32Array, p_extra: Dictionary) -> Dictionary:
	var params := {"seed": 7, "debug_stages": true, "control_points": 4000}
	params.merge(p_extra, true)
	return Pasture3DUtil.hydraulic_saleve_solve_grid(p_surface, GW, GH, RECT, params)


func _field(p_f: Callable) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			a[iz * GW + ix] = p_f.call((ix + 0.5) / GW - 0.5, (iz + 0.5) / GH - 0.5)
	return a


# A dome with a crater: the pit Stage 1 routes out of but the reconstruction still holds.
func _crater() -> PackedFloat32Array:
	return _field(func(u: float, v: float) -> float:
		var r := sqrt(u * u + v * v)
		return 60.0 * cos(minf(r / 0.5, 1.0) * PI * 0.5) - 40.0 * exp(-(r * r) / (0.08 * 0.08)))


func _plane() -> PackedFloat32Array:
	return _field(func(u: float, v: float) -> float: return 30.0 * u + 10.0 * v + 50.0)


func _min(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m


func _max(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return m


func _sum(p_a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in p_a:
		s += v
	return s


func _max_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
