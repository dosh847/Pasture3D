# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# MemberJoinRectGate — a member joining or leaving a Layer brush, and a shape property edit, take a rect bake.
#
# A Ctrl+D'd member made its Layer full-bake stage 1 and every member (trace 2026-10-30: 16.6 s), and a
# slope-angle edit repainted all 9 tools on the layer (2.05 s) for one Mound's footprint. Both now arm the
# brush's own splines with `_stack_dirty` set, so the tick takes the rect path over previous ∪ current.
# Headless has no refresh tick (`headless-gates-cannot-see-scheduling`): A asserts the Layer's decision, and
# B/C run the rect bake those flags select and compare it with a full rebuild.
#
#   [A] a duplicated member, and a folder holding one, are handed to the member (no Layer full bake);
#       control: a nested Layer brush is not, so the Layer still full-bakes for it
#   [B] the duplicate's rect bake (all splines armed, stack flag set) is a rect and equals a full rebuild;
#       control: the ground before that bake differs from the rebuild, so the comparison can say no
#   [C] a slope-angle edit's rect bake is a rect and equals a full rebuild; control: without the stack flag
#       the rect path skips ("nothing changed") and the ground differs from the rebuild
#   [D] deleting a member lifts its painted boxes by a mate's rect bake, equal to a full rebuild; control:
#       `member_join_full_bake` rebuilds the Layer instead (no rect) and lands on the same ground
#   [E] undoing that delete restores by the member's rect bake, equal to the ground before the delete; control:
#       the ground before that bake differs from it
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/MemberJoinRectGate.tscn
extends Node

const CRITERIA := 5
const TOL := 1e-4
var RS := 64

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== MemberJoinRectGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	RS = _terrain.region_size
	var lb := _layer()
	var m1 := _mound(lb, "One", _square(20, 20, 6))
	await _settle()
	lb.rebuild_layer()
	for f in [_a, _b, _c, _d, _e]:
		await f.call(lb, m1)
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== MEMBER JOIN RECT %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


## A Layer over noise, so stage 1 has something to re-solve when a member widens the footprint extent.
func _layer() -> Pasture3DLayerBrush:
	var lb := Pasture3DLayerBrush.new()
	lb.name = "Layer"
	lb.terrain = _terrain
	lb.auto_refresh = false
	var fn := FastNoiseLite.new()
	fn.seed = 7
	fn.frequency = 0.08
	var nz := Pasture3DNodeNoise.new()
	nz.noise = fn
	nz.strength = 2.0
	var mods: Array[Pasture3DNode] = [nz]
	lb.modifiers = mods
	_terrain.add_child(lb)
	return lb


func _mound(p_parent: Node, p_name: String, p_pts: Array) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	m.height = 4.0
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in p_pts:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	p_parent.add_child(m)
	return m


func _square(cx: float, cz: float, h: float) -> Array:
	return [Vector3(cx - h, 0, cz - h), Vector3(cx + h, 0, cz - h), Vector3(cx + h, 0, cz + h), Vector3(cx - h, 0, cz + h)]


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(RS):
		for x in range(RS):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) != is_finite(p_b[i]):
			return INF
		if is_finite(p_a[i]):
			w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


## What the refresh tick bakes after `_schedule_shape_refresh` / `_schedule_join_refresh`: every spline armed,
## the stack flag as given. Returns the rect decision.
func _tick_rect(p_m: Pasture3DMound, p_stack_flag: bool) -> String:
	var ids := {}
	for s in p_m._get_splines():
		ids[s.get_instance_id()] = true
	p_m._refresh_owner_rect(p_m._layer_owner, ids, false, [], p_stack_flag)
	return p_m._last_rect_decision


## The reference: drop every row the Layer owns and bake it again from the tree.
func _full(p_lb: Pasture3DLayerBrush) -> PackedFloat32Array:
	p_lb.rebuild_layer()
	return _heights()


func _a(lb: Pasture3DLayerBrush, m1: Pasture3DMound) -> void:
	_ran += 1
	var dup: Pasture3DMound = m1.duplicate()
	var folder := Node3D.new()
	folder.name = "Folder"
	var inner := _mound(folder, "Inner", _square(44, 44, 4))
	lb.add_child(dup)
	lb.add_child(folder)
	var nested := Pasture3DLayerBrush.new()
	nested.name = "Nested"
	nested.auto_refresh = false
	lb.add_child(nested)
	await _settle()
	var got_dup := lb._joining_members(dup)
	var got_folder := lb._joining_members(folder)
	var got_nested := lb._joining_members(nested)
	_check("A members handed off", got_dup == [dup] and got_folder == [inner],
			"duplicate -> %s, folder -> %s" % [got_dup, got_folder])
	_check("A control", got_nested.is_empty(), "a nested Layer brush -> %s (want [], the full bake stands)" % [got_nested])
	for n: Node in [dup, folder, nested]:
		lb.remove_child(n)
		n.free()
	lb.rebuild_layer()


func _b(lb: Pasture3DLayerBrush, m1: Pasture3DMound) -> void:
	_ran += 1
	# Ctrl+D then a drag: the duplicate's own curve, somewhere new, partly over One.
	var dup: Pasture3DMound = m1.duplicate()
	dup.name = "Dup"
	var path: Path3D = dup.get_child(0)
	var c := Curve3D.new()
	for p in _square(30, 26, 6):
		c.add_point(p)
	c.closed = true
	path.curve = c
	lb.add_child(dup)
	await _settle()
	var before := _heights()
	var decision := _tick_rect(dup, true)
	var rect := _heights()
	var full := _full(lb)
	var w := _worst(rect, full)
	_check("B join rect equals full", decision == "rect" and w <= TOL,
			"decision %s (want rect); worst |rect - full| %.6f m (want <= %.4f)" % [decision, w, TOL])
	var wc := _worst(before, full)
	_check("B control", wc > TOL, "before the join bake, worst |ground - full| %.4f m (want > %.4f)" % [wc, TOL])
	lb.remove_child(dup)
	dup.free()
	lb.rebuild_layer()


func _c(lb: Pasture3DLayerBrush, m1: Pasture3DMound) -> void:
	_ran += 1
	m1.flank_mode = Pasture3DMound.FlankMode.SLOPE_ANGLE
	m1.slope_angle = 30.0
	lb.rebuild_layer()
	m1.slope_angle = 12.0
	var ctl_decision := _tick_rect(m1, false)
	var ctl := _heights()
	var decision := _tick_rect(m1, true)
	var rect := _heights()
	var full := _full(lb)
	var w := _worst(rect, full)
	_check("C shape rect equals full", decision == "rect" and w <= TOL,
			"decision %s (want rect); worst |rect - full| %.6f m (want <= %.4f)" % [decision, w, TOL])
	var wc := _worst(ctl, full)
	_check("C control", ctl_decision == "skip" and wc > TOL,
			"without the stack flag: decision %s (want skip), worst |ground - full| %.4f m (want > %.4f)" % [ctl_decision, wc, TOL])


## A second member partly over One, baked in, so a delete has a mate under its footprint to repaint.
func _second(lb: Pasture3DLayerBrush) -> Pasture3DMound:
	var m := _mound(lb, "Two", _square(30, 26, 6))
	await _settle()
	lb.rebuild_layer()
	return m


## Remove `p_m` from the Layer and let the deferred delete check run. Returns the mate's rect decision.
func _delete(lb: Pasture3DLayerBrush, p_m: Pasture3DMound, p_mate: Pasture3DMound) -> String:
	p_mate._last_rect_decision = ""
	lb.remove_child(p_m)
	await _settle()
	return p_mate._last_rect_decision


func _d(lb: Pasture3DLayerBrush, m1: Pasture3DMound) -> void:
	_ran += 1
	lb.detect_delete_headless = true
	var two := await _second(lb)
	var decision := await _delete(lb, two, m1)
	var lifted := _heights()
	var full := _full(lb)
	var w := _worst(lifted, full)
	_check("D delete lifts by rect", decision == "rect" and w <= TOL,
			"mate decision %s (want rect); worst |lifted - full| %.6f m (want <= %.4f)" % [decision, w, TOL])
	# Control: the Layer's full rebuild (the old path) lands on the same ground and takes no rect.
	lb.add_child(two)
	await _settle()
	lb.rebuild_layer()
	lb.member_join_full_bake = true
	var ctl_decision := await _delete(lb, two, m1)
	lb.member_join_full_bake = false
	var wc := _worst(_heights(), full)
	_check("D control", ctl_decision == "" and wc <= TOL,
			"with member_join_full_bake: mate decision '%s' (want none, the Layer rebuilt), worst |ground - full| %.6f m" % [ctl_decision, wc])
	two.free()
	lb.rebuild_layer()


func _e(lb: Pasture3DLayerBrush, m1: Pasture3DMound) -> void:
	_ran += 1
	lb.detect_delete_headless = true
	var two := await _second(lb)
	var original := _heights()
	await _delete(lb, two, m1)
	# Undo: back in the tree. Auto Refresh on takes the join path, whose tick headless cannot run; run the rect
	# bake it arms.
	two.auto_refresh = true
	lb.add_child(two)
	await _settle()
	var before := _heights()
	var decision := _tick_rect(two, true)
	var w := _worst(_heights(), original)
	_check("E undo restores by rect", decision == "rect" and w <= TOL,
			"decision %s (want rect); worst |restored - before delete| %.6f m (want <= %.4f)" % [decision, w, TOL])
	var wc := _worst(before, original)
	_check("E control", wc > TOL, "before the undo's bake, worst |ground - before delete| %.4f m (want > %.4f)" % [wc, TOL])
	lb.detect_delete_headless = false
	lb.remove_child(two)
	two.free()
	lb.rebuild_layer()
