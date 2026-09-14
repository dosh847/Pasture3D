# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RectBakeAlignmentGate — a rect (clipped) road bake must solve the SAME alignment a full bake of the same curve
# solves, over the whole road, not just inside the clip box.
#
# Trace 2026-09-13 (user's game project): after every LakeRoad rect bake the resolve saw junctions a kilometre
# from the edit move or vanish — LakeRoad1+LakeRoad2's elevation 11.63 -> 15.19 -> 11.63, and the end-to-end
# LakeRoad2+LakeRoad3 dropped then re-found — and each cost a 1.4-2.8 s full bake to undo. The clip shrinks
# `_paint_flat_footprint`'s grid to the clip box, and `grade_surface` sampled ground for the whole plan from that
# grid; `_sample_grid` clamps, so everything outside the box was solved against the box's edge heights.
#
#   [A] CONTROL  most of the road lies outside the clip box, so a match cannot come from the box covering it
#   [B]          every alignment sample (z and bank) matches the full bake within TOL
#   [C]          the resolve after the rect bake finds the same junctions, at the same elevations, as after
#                the full bake
#   [D]          a junction rebake regrades a box around the junctions that moved (each covered, smaller than
#                the road's footprint), not the layer; control: identical records give no box
#   [E]          `_spill_box` covers a height change outside the clip and little else; control: an unchanged
#                alignment gives no box
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RectBakeAlignmentGate.tscn
extends Node

const MOVER := "Road2"
const NUDGE := Vector3(0.5, 0.0, 0.5)
const TOL := 0.01

var _fail := 0
var _ran := 0
var _scene: Node
var _net: Pasture3DRoadNetwork
var _mover: Pasture3DRoadBrush
var _owner: String


func _ready() -> void:
	print("=== RectBakeAlignmentGate ===")
	if await _setup():
		_run()
	if _ran != 5:
		_check("completed", false, "%d of 5 criteria ran" % _ran)
	print("=== RECT BAKE ALIGNMENT %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _setup() -> bool:
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		_check("setup", false, "demo_road_network.tscn did not load")
		return false
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().process_frame
	_net = _scene.find_child("Pasture3DRoadNetwork", true, false)
	for b in _net.road_brushes() if _net != null else []:
		if b != null and b.name == MOVER:
			_mover = b
	if _mover == null or _mover._get_splines().is_empty():
		_check("setup", false, "%s with a spline not found" % MOVER)
		return false
	_owner = _mover._layer_owner
	_settle()
	return true


func _settle() -> void:
	_mover._refresh_owner(_owner, false, [])
	_net.resolve_junctions()
	_mover._refresh_owner(_owner, false, [])


func _junctions() -> Dictionary:
	var out := {}
	for j in _net.junctions_for(_mover.road_key()):
		out[String(j.id)] = j.elevation
	return out


func _run() -> void:
	var sp: Path3D = _mover._get_splines()[0]
	var i := 1
	var orig := sp.curve.get_point_position(i)
	sp.curve.set_point_position(i, orig + NUDGE)

	# Full bake first, as the reference. Both bakes start from the same settled pins: resolve is not run
	# between the edit and either bake.
	var pins_before := _mover.last_junction_digest
	_mover._refresh_owner(_owner, false, [])
	var full: Pasture3DRoadAlignment = _mover.road_modifier().last_alignment
	var full_z := full.z.duplicate()
	var full_bank := full.bank.duplicate()
	_net.resolve_junctions()
	var full_j := _junctions()

	# Return to the settled state, then make the same edit through the rect path.
	sp.curve.set_point_position(i, orig)
	_settle()
	sp.curve.set_point_position(i, orig + NUDGE)
	var settled_again := _mover.last_junction_digest == pins_before
	_mover._refresh_owner_rect(_owner, {sp.get_instance_id(): true}, false)
	var clip: AABB = _mover._last_rect_clip
	var rect: Pasture3DRoadAlignment = _mover.road_modifier().last_alignment
	var rect_z := rect.z.duplicate()
	var rect_bank := rect.bank.duplicate()
	_net.resolve_junctions()
	var rect_j := _junctions()

	# [A]
	var plan := _mover._plan_points()
	var cum := _mover._plan_cum()
	var outside := 0
	for k in full_z.size():
		var at := Pasture3DRoadGrader.plan_point_at(plan, cum, float(k) * full.ds)
		if at.x < clip.position.x or at.x > clip.end.x or at.y < clip.position.z or at.y > clip.end.z:
			outside += 1
	var frac := float(outside) / maxf(float(full_z.size()), 1.0)
	_ran += 1
	_check("[A] control: road mostly outside the clip", clip.size != Vector3.ZERO and frac > 0.5 and settled_again,
			"clip x[%.0f..%.0f] z[%.0f..%.0f]; %d of %d sample(s) outside (%.0f%%); same starting pins %s" % [
			clip.position.x, clip.end.x, clip.position.z, clip.end.z, outside, full_z.size(), frac * 100.0,
			settled_again])

	# [B]
	var worst := INF
	var worst_k := -1
	if rect_z.size() == full_z.size() and rect_bank.size() == full_bank.size():
		worst = 0.0
		for k in full_z.size():
			var d := maxf(absf(rect_z[k] - full_z[k]), absf(rect_bank[k] - full_bank[k]))
			if not (d <= worst):
				worst = d if is_finite(d) else INF
				worst_k = k
	_ran += 1
	_check("[B] rect alignment matches full", worst <= TOL, "%d vs %d sample(s); worst %s%s" % [rect_z.size(),
			full_z.size(), "n/a" if worst == INF and worst_k == -1 else "%.3f" % worst,
			"" if worst_k < 0 else " at s=%.0f m (rect z %.3f, full z %.3f)" % [worst_k * full.ds, rect_z[worst_k],
			full_z[worst_k]]])

	# [C]
	var bad := PackedStringArray()
	for id in full_j:
		if not rect_j.has(id):
			bad.append("%s missing" % id)
		elif absf(float(rect_j[id]) - float(full_j[id])) > TOL:
			bad.append("%s elev %.3f vs %.3f" % [id, rect_j[id], full_j[id]])
	for id in rect_j:
		if not full_j.has(id):
			bad.append("%s extra" % id)
	_ran += 1
	_check("[C] same junctions after rect bake", bad.is_empty() and not full_j.is_empty(),
			"%d junction(s)%s" % [full_j.size(), "" if bad.is_empty() else "; " + "; ".join(bad)])

	sp.curve.set_point_position(i, orig)
	_settle()
	_d_junction_box(sp, i, orig)
	_e_spill_box(sp, i, orig)


## [D] The rebake area is the junctions that moved, not the road. Computed against a baseline captured before
## the resolve: headless, `schedule_junction_rebake` still replaces the baseline, and its scheduler records nothing.
func _d_junction_box(p_sp: Path3D, p_i: int, p_orig: Vector3) -> void:
	var baseline := _mover._last_junction_values.duplicate(true)
	p_sp.curve.set_point_position(p_i, p_orig + NUDGE * 8.0)
	_mover._refresh_owner_rect(_owner, {p_sp.get_instance_id(): true}, false)
	_net.resolve_junctions()
	var now := _mover.junction_values()
	var box := _mover._junction_change_box(now, baseline)
	var same := _mover._junction_change_box(now, now)
	# Two kinds of change, told apart independently of the brush: arc length only (the junction did not move on
	# the ground) and anything else. Every junction of the second kind must be inside the box.
	var changed := 0
	var moved := PackedStringArray()
	var uncovered := PackedStringArray()
	for j in _net.junctions_for(_mover.road_key()):
		var id := String(j.id)
		if baseline.has(id) and not Pasture3DRoadBrush.junction_values_differ({id: now[id]}, {id: baseline[id]}):
			continue
		changed += 1
		if baseline.has(id):
			var tol_a: PackedFloat64Array = (now[id]["tol"] as PackedFloat64Array).duplicate()
			tol_a[0] = INF
			if not Pasture3DRoadBrush.junction_values_differ({id: {"v": now[id]["v"], "tol": tol_a}},
					{id: baseline[id]}):
				continue
		moved.append(id)
		if not (j.center.x >= box.position.x and j.center.x <= box.end.x and j.center.y >= box.position.z
				and j.center.y <= box.end.z):
			uncovered.append(id)
	var fp: AABB = _mover._spline_footprint_aabb(p_sp)
	var box_area := box.size.x * box.size.z
	var fp_area := fp.size.x * fp.size.z
	_ran += 1
	_check("[D] junction rebake box", changed > 0 and box.size != Vector3.ZERO and uncovered.is_empty()
			and box_area < fp_area and same.size == Vector3.ZERO,
			"%d changed junction(s), %d moved beyond arc length [%s], uncovered [%s]; box %.0f m2 vs road footprint %.0f m2; unchanged -> %s" % [
			changed, moved.size(), ", ".join(moved), ", ".join(uncovered), box_area, fp_area,
			"empty" if same.size == Vector3.ZERO else "NOT EMPTY"])
	p_sp.curve.set_point_position(p_i, p_orig)
	_settle()


## [E] A height change outside the clip is found, and only there. Driven through `_spill_box` on the trace the
## settle left, because which edit spills is terrain-dependent and the scheduler is editor-only.
func _e_spill_box(p_sp: Path3D, p_i: int, p_orig: Vector3) -> void:
	p_sp.curve.set_point_position(p_i, p_orig + NUDGE)
	_mover._refresh_owner_rect(_owner, {p_sp.get_instance_id(): true}, false)
	var clip: AABB = _mover._last_rect_clip
	p_sp.curve.set_point_position(p_i, p_orig)
	_settle()
	var pts: PackedVector2Array = _mover._trace_xz
	var z: PackedFloat32Array = _mover._trace_z.duplicate()
	var ds: float = _mover._trace_ds
	var k := -1
	for idx in pts.size():
		var at := pts[idx]
		if at.x < clip.position.x - 50.0 or at.x > clip.end.x + 50.0 or at.y < clip.position.z - 50.0 or at.y > clip.end.z + 50.0:
			k = idx
			break
	_mover._clip_aabb = clip
	var quiet := _mover._spill_box(pts, z, ds)
	var box := AABB()
	var far_in := 0
	if k >= 0:
		z[k] += 0.5
		box = _mover._spill_box(pts, z, ds)
		for idx in pts.size():
			var at := pts[idx]
			if at.distance_to(pts[k]) > _mover._padding() * 2.0 + ds and at.x >= box.position.x and at.x <= box.end.x \
					and at.y >= box.position.z and at.y <= box.end.z:
				far_in += 1
	_mover._clip_aabb = AABB()
	var covers := k >= 0 and pts[k].x >= box.position.x and pts[k].x <= box.end.x and pts[k].y >= box.position.z \
			and pts[k].y <= box.end.z
	_ran += 1
	_check("[E] spill box", k >= 0 and quiet.size == Vector3.ZERO and covers and far_in < pts.size() / 4,
			"unchanged -> %s; +0.5 m at sample %d -> box %.0f x %.0f m covering it %s; %d distant sample(s) inside" % [
			"empty" if quiet.size == Vector3.ZERO else "NOT EMPTY", k, box.size.x, box.size.z, covers, far_in])
