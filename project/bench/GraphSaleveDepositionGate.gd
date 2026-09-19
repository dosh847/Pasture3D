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
#   E  Stage 1 never raises the ground (a mound in a flat margin); control: lower_only off does, by metres
#   F  the mask ports are the metre outputs over their depths, in 0..1; control: the metres exceed 1
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
[E] Stage 1 never raises the ground")
	var src := _field(func(u: float, v: float) -> float:
		return 120.0 * maxf(0.0, 1.0 - (u * u + v * v) / 0.12) + 4.0 * u)
	var on := _solve(src, {})
	var off := _solve(src, {"lower_only": false})
	var r_on := _max_raise(on, src)
	var r_off := _max_raise(off, src)
	print("    Stage 1 result above the input: lower_only %.6f m (want < 0.0001); control off %.3f m (want > 1)" % [r_on, r_off])
	if r_off <= 1.0:
		_fail += 1
		print("    !! the free steady state raised nothing, so the clamp is unobservable")
		return
	if r_on > 1.0e-4: # float residue of pre - deposition - input
		_fail += 1
		print("    !! Stage 1 raised the ground")
		return
	_done += 1


func _f_masks() -> void:
	print("
[F] mask ports are the metre outputs over their depths")
	var res := _solve(_crater(), {"eroded_mask_depth": 4.0, "sediment_mask_depth": 0.2})
	var e: PackedFloat32Array = res.eroded_rock
	var sd: PackedFloat32Array = res.sediment
	var em: PackedFloat32Array = res.eroded_mask
	var sm: PackedFloat32Array = res.sediment_mask
	var worst := 0.0
	var lo := INF
	var hi := -INF
	for i in range(e.size()):
		worst = maxf(worst, absf(em[i] - clampf(e[i] / 4.0, 0.0, 1.0)))
		worst = maxf(worst, absf(sm[i] - clampf(sd[i] / 0.2, 0.0, 1.0)))
		lo = minf(lo, minf(em[i], sm[i]))
		hi = maxf(hi, maxf(em[i], sm[i]))
	print("    mask vs metres/depth %.7f (want < 1e-6); mask range [%.3f, %.3f] (want within [0, 1]); control metre max %.2f m (want > 1)"
			% [worst, lo, hi, _max(e)])
	if _max(e) <= 1.0:
		_fail += 1
		print("    !! the metre output never exceeds 1, so it cannot tell a mask from metres")
		return
	if worst >= 1.0e-6 or lo < 0.0 or hi > 1.0:
		_fail += 1
		print("    !! the mask ports are not the normalised outputs")
		return
	_done += 1


# Stage 1's grid in metres, before Stage 2 raised it: pre_stream minus the deposition.
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
