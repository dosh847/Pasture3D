# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadEarthworksShapeGate — the batter's toe and hinge rounding (2026-09-27). The retaining walls moved to
# RoadWallGate with Pasture3DRoadWall (2026-09-29).
#
# The batter is defined once (`road_batter_height` in C++, `Pasture3DRoadGrader.batter_height` in GDScript,
# line for line). Every option defaults to the unshaped batter, so a road that sets none of them must grade
# exactly as it did before they existed.
#
#   [P] parity: the native grader and `grade_reference` agree with every option on. Control: the options
#       actually MOVE the grade -- agreement on a fixture where they change nothing compares nothing new
#   [Z] zero: options set explicitly to 0 grade bit-identically to options absent, on the native route.
#       Control: non-zero options differ from absent
#   [T] toe: a fill batter meeting flat ground has a crease (large second difference) without rounding and a
#       fillet with it; the toe blend never lifts the formation edge. Control: the crease is there at toe 0
#   [H] hinge: leaves the edge at the surface's own cross-slope, never sits below the unrounded batter on a
#       fill (so the ribbon's edge is never undercut). Control: at hinge 0 the edge leaves at the batter slope
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadEarthworksShapeGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["P", "Z", "T", "H"]
const EPS := 1.0e-4

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadEarthworksShapeGate ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_grade_grid"):
		_check("P", false, "road_grade_grid is not bound -- rebuild the GDExtension")
	else:
		_p()
		_z()
	_t()
	_h()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD EARTHWORKS SHAPE %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not _seen.has(p_name):
		_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


# ---- A grid fixture shared by [P] [Z] ---------------------------------------------------------

func _fixture() -> Dictionary:
	var plan := PackedVector2Array()
	for i in 41:
		var t := float(i)
		plan.append(Vector2(-40.0 + t * 2.0, -20.0 + 0.012 * t * t))
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var n_s := int(cum[cum.size() - 1]) + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	a.s0 = 0.0
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	var half := PackedFloat32Array()
	var shoulder := PackedFloat32Array()
	var verge := PackedFloat32Array()
	var suppress := PackedByteArray()
	for i in n_s:
		var f := float(i) / float(maxi(n_s - 1, 1))
		z.append(6.0 - 12.0 * f) # deep fill into deep cut, so both walls stand somewhere
		bank.append(0.05 * sin(f * TAU))
		half.append(3.5)
		shoulder.append(0.8)
		verge.append(3.0)
		suppress.append(0)
	a.z = z
	a.bank = bank
	var gw := 120
	var gh := 100
	var ground := PackedFloat32Array()
	ground.resize(gw * gh)
	for iz in gh:
		for ix in gw:
			ground[iz * gw + ix] = 0.05 * float(ix - 60) + 1.5 * sin(float(iz) * 0.07)
	return {"plan": plan, "align": a, "half": half, "shoulder": shoulder, "verge": verge,
			"suppress": suppress, "ground": ground, "gw": gw, "gh": gh, "min_x": -60.0, "min_z": -45.0}


func _grade(p_fx: Dictionary, p_opts: Dictionary, p_reference: bool = false) -> PackedFloat32Array:
	var opts := {"crown": 0.03, "cut_batter": 1.0, "fill_batter": 0.6}
	opts.merge(p_opts, true)
	var r: Dictionary
	if p_reference:
		r = Pasture3DRoadGrader.grade_reference(p_fx["ground"], p_fx["gw"], p_fx["gh"], p_fx["min_x"],
				p_fx["min_z"], 1.0, p_fx["plan"], p_fx["align"], p_fx["half"], p_fx["shoulder"],
				p_fx["verge"], p_fx["suppress"], opts)
	else:
		r = Pasture3DRoadGrader.grade(p_fx["ground"], p_fx["gw"], p_fx["gh"], p_fx["min_x"], p_fx["min_z"],
				1.0, p_fx["plan"], p_fx["align"], p_fx["half"], p_fx["shoulder"], p_fx["verge"],
				p_fx["suppress"], opts)
	return r["height"]


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var w := 0.0
	for i in mini(p_a.size(), p_b.size()):
		if is_nan(p_a[i]) or is_nan(p_b[i]):
			if is_nan(p_a[i]) != is_nan(p_b[i]):
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


const SHAPED := {"toe_rounding": 2.5, "hinge_rounding": 1.5}


func _p() -> void:
	print("[P] native grader vs grade_reference, every option on")
	var fx := _fixture()
	var nat := _grade(fx, SHAPED)
	var orc := _grade(fx, SHAPED, true)
	var plain := _grade(fx, {})
	var w := _worst(nat, orc)
	var moved := _worst(nat, plain)
	_check("P", w < EPS and moved > 0.5,
			"worst %.7f m (want < %.4f); control: the options move the grade by up to %.2f m (want > 0.5)"
			% [w, EPS, moved])


func _z() -> void:
	print("[Z] options at zero grade exactly as options absent")
	var fx := _fixture()
	var absent := _grade(fx, {})
	var zero := _grade(fx, {"toe_rounding": 0.0, "hinge_rounding": 0.0})
	var shaped := _grade(fx, SHAPED)
	var same := absent == zero
	var d := _worst(absent, shaped)
	_check("Z", same and d > 0.5, "zero == absent bit for bit: %s; control: shaped differs by %.2f m" % [same, d])


# ---- [T] [H] on the one-dimensional batter ------------------------------------------------------------

func _profile(p_ground: Callable, p_z_edge: float, p_g1: float, p_toe: float, p_hinge: float,
		p_step: float, p_n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in p_n:
		var x := float(i) * p_step
		out.append(Pasture3DRoadGrader.batter_height(p_ground.call(x), p_z_edge, p_g1, x, 1.0, 0.5, p_toe,
				p_hinge))
	return out


func _max_second_diff(p_h: PackedFloat32Array, p_step: float) -> float:
	var m := 0.0
	for i in range(1, p_h.size() - 1):
		m = maxf(m, absf(p_h[i + 1] - 2.0 * p_h[i] + p_h[i - 1]) / (p_step * p_step))
	return m


func _t() -> void:
	print("[T] the toe is a fillet, and never lifts the formation edge")
	var flat := func(_x: float) -> float: return 0.0
	var step := 0.05
	# A 4 m fill at 1:2 (fill batter 0.5) meets flat ground 8 m out.
	var hard := _profile(flat, 4.0, 0.0, 0.0, 0.0, step, 400)
	var soft := _profile(flat, 4.0, 0.0, 2.0, 0.0, step, 400)
	var k_hard := _max_second_diff(hard, step)
	var k_soft := _max_second_diff(soft, step)
	var edge_same := absf(soft[0] - 4.0) < 1e-6
	# The fillet is spread over the toe, not piled on the batter: far from the toe both agree.
	var far_same := absf(soft[40] - hard[40]) < 1e-4 and absf(soft[399] - hard[399]) < 1e-4
	_check("T", k_soft < 0.25 * k_hard and edge_same and far_same,
			"peak curvature %.2f -> %.2f /m (want < 25%%); edge %.4f m (want 4.0000); unchanged away from the toe: %s; control: the unrounded crease is %.1f /m"
			% [k_hard, k_soft, soft[0], far_same, k_hard])


func _h() -> void:
	print("[H] the hinge leaves the edge at the surface's slope and never undercuts it")
	var far := func(_x: float) -> float: return -100.0
	var g1 := -0.03
	var step := 0.01
	var hinged := _profile(far, 0.0, g1, 0.0, 1.5, step, 800)
	var plain := _profile(far, 0.0, g1, 0.0, 0.0, step, 800)
	var slope_h := (hinged[1] - hinged[0]) / step
	var slope_p := (plain[1] - plain[0]) / step
	var below := 0
	for i in hinged.size():
		if hinged[i] < plain[i] - 1e-6:
			below += 1
	# And past the curve it is the batter again: same slope.
	var tail_slope := (hinged[799] - hinged[700]) / (99.0 * step)
	_check("H", absf(slope_h - g1) < 0.02 and below == 0 and absf(tail_slope + 0.5) < 1e-3
			and absf(slope_p + 0.5) < 1e-3,
			"leaves at %.3f (want %.3f), %d sample(s) below the unrounded batter (want 0), tail slope %.3f (want -0.5); control: unrounded leaves at %.3f"
			% [slope_h, g1, below, tail_slope, slope_p])
