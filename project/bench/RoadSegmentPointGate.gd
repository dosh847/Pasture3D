# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSegmentPointGate — a road segment's range picked by SPLINE POINT (2026-09-27; distance fields removed
# 2026-09-30).
#
# A picked end resolves to the point's arc length along the plan every time it is read, so it follows the
# point; inserting or removing a point before it renumbers the pick so it stays on the same point. The
# segment covers the road BETWEEN its points, in either order; an unpicked end is the road's start (from) or
# end (to), and a segment with neither picked covers nothing.
#
# The fixture is a straight five-point road along x (0, 40, 80, 120, 160), zero handles, so every point's arc
# length is its x and nothing about rounding or curvature can move a number.
#
#   [R] resolve: from_point 1 / to_point 3 cover 40..120 m; moving point 3 to x 140 moves the end to 140 and
#       the segment's signature with it, and the bridge the segment carries moves in `grading_profile`.
#       Control: a segment on points 0..1 ends at 40 m before and after, and keeps its signature
#   [O] order: picks 3 -> 1 cover the same 40..120 m as 1 -> 3, and carry the bridge in `grading_profile`.
#       An unpicked end is the road's start or end. Control: neither picked covers nothing
#   [I] insert: a point added before the picks renumbers them (1 -> 2, 3 -> 4) and the resolved range does
#       not move. Control: a pick on point 0, before the insertion, stays 0
#   [X] remove: removing a picked point moves the pick to its neighbour INSIDE the range: the next point for
#       the nearer end, the previous one for the further end; a later pick shifts down
#   [V] reverse: reversing the road keeps a picked range on the same stretch of road
#   [P] pick: "Start at Selected Point" takes the viewport's selected point; a selection taken before the
#       point count changed, or on another brush, is refused
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadSegmentPointGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["R", "O", "I", "X", "V", "P"]

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadSegmentPointGate ===")
	await get_tree().process_frame
	_r()
	_o()
	_i_x()
	_v()
	_p()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD SEGMENT POINT %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _road() -> Pasture3DRoadBrush:
	var t := Pasture3DRoadType.new()
	t.lane_width = 3.5
	t.shoulder_width = 1.0
	var b := Pasture3DRoadBrush.new()
	b.road_road_type = t
	b.snap_to_surface = false
	add_child(b)
	var path := Path3D.new()
	path.name = "Spline"
	var c := Curve3D.new()
	for i in 5:
		c.add_point(Vector3(40.0 * float(i), 0.0, 0.0))
	path.curve = c
	b.add_child(path)
	return b


func _curve(p_b: Pasture3DRoadBrush) -> Curve3D:
	return (p_b.get_node("Spline") as Path3D).curve


func _seg(p_from_pt: int, p_to_pt: int) -> Pasture3DRoadSegment:
	var s := Pasture3DRoadSegment.new()
	s.from_point = p_from_pt
	s.to_point = p_to_pt
	s.is_bridge = true
	return s


func _r() -> void:
	print("[R] a picked range follows its point")
	var b := _road()
	var picked := _seg(1, 3)
	var by_dist := _seg(0, 1) # the control: nothing it picks moves
	by_dist.is_bridge = false
	# The control FIRST: the last matching segment wins, and it must not override the bridge under test.
	b.segments = [by_dist, picked]
	var s0 := picked.start()
	var e0 := picked.end()
	# As strings: an unset speed_limit is NaN, and NaN != NaN makes two identical signature Arrays unequal.
	var sig0 := str(picked.signature())
	var dsig0 := str(by_dist.signature())
	var covers0 := picked.covers(100.0) and not picked.covers(130.0)
	var prof0 := b.grading_profile(null, 1.0, 161)
	var sup0: PackedByteArray = prof0["suppress"]
	_curve(b).set_point_position(3, Vector3(140.0, 0.0, 0.0))
	var e1 := picked.end()
	var prof1 := b.grading_profile(null, 1.0, 161)
	var sup1: PackedByteArray = prof1["suppress"]
	var moved_bridge := sup0[130] == 0 and sup1[130] == 1 and sup1[40] == 1 and sup1[39] == 0 and sup1[140] == 0
	_check("R", absf(s0 - 40.0) < 1e-3 and absf(e0 - 120.0) < 1e-3 and covers0 and absf(e1 - 140.0) < 1e-3
			and str(picked.signature()) != sig0 and moved_bridge
			and absf(by_dist.end() - 40.0) < 1e-3 and str(by_dist.signature()) == dsig0,
			"range %.1f..%.1f m -> end %.1f m after the move (want 40..120 -> 140), signature moved %s, bridge at 130 m %d -> %d; control: points 0..1 end %.1f m (want 40), signature kept %s"
			% [s0, e0, e1, str(picked.signature()) != sig0, sup0[130], sup1[130], by_dist.end(), str(by_dist.signature()) == dsig0])
	b.queue_free()


func _o() -> void:
	print("[O] either order, and unpicked ends")
	var b := _road()
	var backward := _seg(3, 1)
	var open_start := _seg(-1, 2)
	open_start.is_bridge = false
	var open_end := _seg(2, -1)
	open_end.is_bridge = false
	var none := _seg(-1, -1)
	b.segments = [open_start, open_end, none, backward]
	var sup: PackedByteArray = b.grading_profile(null, 1.0, 161)["suppress"]
	var bridged := sup[39] == 0 and sup[40] == 1 and sup[119] == 1 and sup[120] == 0
	var none_covers := none.covers(0.0) or none.covers(80.0) or none.length() > 0.0
	_check("O", absf(backward.start() - 40.0) < 1e-3 and absf(backward.end() - 120.0) < 1e-3 and bridged
			and absf(open_start.start()) < 1e-3 and absf(open_start.end() - 80.0) < 1e-3
			and absf(open_end.start() - 80.0) < 1e-3 and absf(open_end.end() - 160.0) < 1e-3
			and not none_covers and none.range_warnings().size() == 1,
			"points 3 -> 1 cover %.1f..%.1f m (want 40..120), bridged 40..119: %s; -1 -> 2 is %.1f..%.1f, 2 -> -1 is %.1f..%.1f (want 0..80, 80..160); control: neither picked covers nothing: %s, warned: %s"
			% [backward.start(), backward.end(), bridged, open_start.start(), open_start.end(),
			open_end.start(), open_end.end(), not none_covers, none.range_warnings()])
	b.queue_free()


func _i_x() -> void:
	print("[I][X] inserting and removing points renumbers the picks")
	var b := _road()
	var picked := _seg(1, 3)
	var before := _seg(0, 1)
	b.segments = [picked, before]
	b.editor_add_point(Vector3(20.0, 0.0, 0.0))
	var n := _curve(b).point_count
	_check("I", n == 6 and picked.from_point == 2 and picked.to_point == 4 and absf(picked.start() - 40.0) < 1e-3
			and absf(picked.end() - 120.0) < 1e-3 and before.from_point == 0 and before.to_point == 2,
			"%d points; picks %d/%d (want 2/4) at %.1f..%.1f m (want 40..120); control: the pick on point 0 is %d (want 0), its end %d (want 2)"
			% [n, picked.from_point, picked.to_point, picked.start(), picked.end(), before.from_point, before.to_point])
	# Remove point 2 (x 40): the NEARER end of `picked` and the FURTHER end of `before`. Points are now
	# x 0, 20, 80, 120, 160.
	b.editor_remove_point(b.get_node("Spline") as Path3D, 2)
	_check("X", picked.from_point == 2 and absf(picked.start() - 80.0) < 1e-3 and picked.to_point == 3
			and absf(picked.end() - 120.0) < 1e-3 and before.from_point == 0 and before.to_point == 1
			and absf(before.end() - 20.0) < 1e-3,
			"nearer end moved to pick %d at %.1f m (want 2 at 80), later pick %d at %.1f m (want 3 at 120); further end moved to pick %d at %.1f m (want 1 at 20)"
			% [picked.from_point, picked.start(), picked.to_point, picked.end(), before.to_point, before.end()])
	b.queue_free()


func _v() -> void:
	print("[V] reversing the road mirrors a picked range")
	var b := _road()
	var picked := _seg(1, 3) # 40..120 on a 160 m road -> 40..120 again, the other way round
	var half_pick := _seg(-1, 3) # road start..120 -> 40..road end
	b.segments = [picked, half_pick]
	b.reverse_splines()
	var ok := picked.from_point == 1 and picked.to_point == 3 and absf(picked.start() - 40.0) < 1e-3 \
			and absf(picked.end() - 120.0) < 1e-3 and half_pick.from_point == 1 and half_pick.to_point == -1 \
			and absf(half_pick.start() - 40.0) < 1e-3 and absf(half_pick.end() - 160.0) < 1e-3
	var first := _curve(b).get_point_position(0)
	_check("V", ok and absf(first.x - 160.0) < 1e-3,
			"first point now x %.0f; picked %d/%d at %.1f..%.1f (want 1/3 at 40..120), half %d/%d at %.1f..%.1f (want 1/-1 at 40..160)"
			% [first.x, picked.from_point, picked.to_point, picked.start(), picked.end(),
			half_pick.from_point, half_pick.to_point, half_pick.start(), half_pick.end()])
	b.queue_free()


func _p() -> void:
	print("[P] the Selected Point buttons")
	var b := _road()
	var other := _road()
	var seg := _seg(-1, -1)
	b.segments = [seg]
	var saved: Array = Pasture3DTerrainBrush._editor_selected_point
	Pasture3DTerrainBrush._editor_selected_point = [b.get_instance_id(), 2, 5]
	seg._pick_start()
	var took := seg.from_point
	Pasture3DTerrainBrush._editor_selected_point = [b.get_instance_id(), 3, 4] # stale count
	seg._pick_end()
	var stale := seg.to_point
	Pasture3DTerrainBrush._editor_selected_point = [other.get_instance_id(), 3, 5] # another road
	seg._pick_end()
	var foreign := seg.to_point
	Pasture3DTerrainBrush._editor_selected_point = [b.get_instance_id(), 4, 5]
	seg._pick_end()
	var took_end := seg.to_point
	Pasture3DTerrainBrush._editor_selected_point = saved
	_check("P", took == 2 and stale == -1 and foreign == -1 and took_end == 4 and absf(seg.start() - 80.0) < 1e-3
			and absf(seg.end() - 160.0) < 1e-3,
			"start took %d (want 2), end refused a stale selection (%d) and another road's (%d), then took %d; range %.1f..%.1f m"
			% [took, stale, foreign, took_end, seg.start(), seg.end()])
	b.queue_free()
	other.queue_free()
