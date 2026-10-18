# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SplinePointToggleGate — what a double-click on a spline point does to its tangents (2026-10-01).
#
# The bug: the toggle sharpened any point whose tangents were not both zero, BROKEN points included. A
# sharpened point's zero tangents draw as stubs pointing at the neighbours, which on a straight run look
# aligned, but the gizmo mirrors a drag only on a point that `tangents_mirrored` calls smooth, so moving
# one stub left the other behind. Now only a smooth point sharpens; anything else becomes smooth.
#
# Each criterion is judged by `Pasture3DTerrainBrush.tangents_mirrored`, the predicate the gizmo's drag
# uses, not by a re-statement of it.
#   [S] a smooth point sharpens to a corner. Control: it was mirrored before
#   [C] a corner smooths, along the previous-to-next direction. Control: it was not mirrored before
#   [B] a broken point (sides at 40 degrees, 3 m and 7 m) smooths, keeping its heading and mean length;
#       a second toggle sharpens it. Control: the old rule (smooth only when both sides are zero) would
#       have sharpened it, and it was not mirrored before
#   [O] a one-sided point (in zeroed) smooths along its live side, at that side's length. Control: the
#       old rule would have sharpened it
#
# Headless `_editor_undo()` is null, so the toggle applies directly; the undo path records the same pair.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/SplinePointToggleGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["S", "C", "B", "O"]
const IDX := 2

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== SplinePointToggleGate ===")
	_run()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== SPLINE POINT TOGGLE %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


## Five points along +x, 20 m apart, with a kink at IDX so previous-to-next is not the x axis.
func _fixture(p_in: Vector3, p_out: Vector3) -> Array:
	var brush := Pasture3DSpline.new()
	add_child(brush)
	var path := Path3D.new()
	var c := Curve3D.new()
	for i in 5:
		c.add_point(Vector3(20.0 * float(i), 0.0, 0.0))
	c.set_point_position(IDX + 1, Vector3(60.0, 0.0, 10.0))
	c.set_point_in(IDX, p_in)
	c.set_point_out(IDX, p_out)
	path.curve = c
	brush.add_child(path)
	return [brush, path]


func _tangents(p_path: Path3D) -> Array:
	return [p_path.curve.get_point_in(IDX), p_path.curve.get_point_out(IDX)]


## What the toggle did before the fix: smooth only when both sides were already zero.
func _old_rule_smooths(p_in: Vector3, p_out: Vector3) -> bool:
	return p_in.length() <= 0.02 and p_out.length() <= 0.02


func _done(p_fx: Array) -> void:
	(p_fx[0] as Node).queue_free()


func _run() -> void:
	var M := Pasture3DTerrainBrush.tangents_mirrored

	# [S]
	print("[S] a smooth point sharpens")
	var fx := _fixture(Vector3(-4, 0, 0), Vector3(4, 0, 0))
	var before: Array = _tangents(fx[1])
	fx[0].editor_smooth_point(fx[1], IDX)
	var after: Array = _tangents(fx[1])
	print("    before in %s out %s; after in %s out %s" % [before[0], before[1], after[0], after[1]])
	_check("S", M.call(before[0], before[1]) and after[0] == Vector3.ZERO and after[1] == Vector3.ZERO,
			"both tangents zeroed; control: the point was mirrored")
	_done(fx)

	# [C]
	print("[C] a corner smooths along previous-to-next")
	fx = _fixture(Vector3.ZERO, Vector3.ZERO)
	fx[0].editor_smooth_point(fx[1], IDX)
	after = _tangents(fx[1])
	var c: Curve3D = fx[1].curve
	var want := (c.get_point_position(IDX + 1) - c.get_point_position(IDX - 1)).normalized()
	var dot := (after[1] as Vector3).normalized().dot(want)
	print("    after in %s out %s; heading . previous-to-next %.4f" % [after[0], after[1], dot])
	_check("C", not M.call(Vector3.ZERO, Vector3.ZERO) and M.call(after[0], after[1]) and dot > 0.999,
			"mirrored along the neighbours; control: the corner was not mirrored")
	_done(fx)

	# [B]
	print("[B] a broken point smooths, keeping its heading; a second toggle sharpens")
	var b_in := Vector3(-3, 0, 0).rotated(Vector3.UP, deg_to_rad(20.0))
	var b_out := Vector3(7, 0, 0).rotated(Vector3.UP, deg_to_rad(-20.0))
	fx = _fixture(b_in, b_out)
	var old_sharpens := not _old_rule_smooths(b_in, b_out)
	fx[0].editor_smooth_point(fx[1], IDX)
	after = _tangents(fx[1])
	var heading := (b_out - b_in).normalized()
	dot = (after[1] as Vector3).normalized().dot(heading)
	var length := (after[1] as Vector3).length()
	fx[0].editor_smooth_point(fx[1], IDX)
	var again: Array = _tangents(fx[1])
	print("    after in %s out %s; heading dot %.4f, length %.3f (mean 5.0); second toggle in %s out %s"
			% [after[0], after[1], dot, length, again[0], again[1]])
	_check("B", old_sharpens and not M.call(b_in, b_out) and M.call(after[0], after[1]) and dot > 0.999
			and absf(length - 5.0) < 1e-3 and again[0] == Vector3.ZERO and again[1] == Vector3.ZERO,
			"mirrored on its own heading at the mean length, then sharpened; control: the old rule sharpened it")
	_done(fx)

	# [O]
	print("[O] a one-sided point smooths along its live side")
	var o_out := Vector3(5, 0, 3)
	fx = _fixture(Vector3.ZERO, o_out)
	old_sharpens = not _old_rule_smooths(Vector3.ZERO, o_out)
	fx[0].editor_smooth_point(fx[1], IDX)
	after = _tangents(fx[1])
	print("    after in %s out %s" % [after[0], after[1]])
	_check("O", old_sharpens and M.call(after[0], after[1]) and (after[1] as Vector3).is_equal_approx(o_out),
			"the live side kept, the other mirrored to it; control: the old rule sharpened it")
	_done(fx)
