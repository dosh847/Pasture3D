# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSegmentInspectorGate — editing a road segment in the inspector must not rebuild it (2026-09-30).
#
# Typing a segment's Label collapsed the expanded array entry after every key. `label` writes
# `resource_name`, `Resource.set_name` emits `changed`, the brush took that as a road change and re-baked,
# and the bake's Brush Stats refresh called `notify_property_list_changed()` on the selected brush. A
# rebuild folds every expanded sub-resource and takes the focus from the field being typed into.
#
# Headless has no inspector, so this gate asserts the two DECISIONS that led to the rebuild:
#
#   [N] a segment rename is not a road change: typing "Mountain" one key at a time runs `_on_road_changed`
#       zero times. Control: a lane_count edit on the same segment runs it once
#   [S] a Brush Stats refresh asks for a rebuild only when the stat ROWS change: none after listing an open
#       road. Control: closing the road swaps Length for Perimeter, and it asks
#   [P] a segment's point pick never rebuilds its own sub-inspector (the distance fields it used to toggle
#       read-only are gone). Control: a direct notify is counted
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadSegmentInspectorGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["N", "S", "P"]

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadSegmentInspectorGate ===")
	_n()
	_s()
	_p()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD SEGMENT INSPECTOR %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _n() -> void:
	print("[N] a segment rename is not a road change")
	var road := Pasture3DRoadBrush.new()
	var seg := Pasture3DRoadSegment.new()
	road.segments = [seg]
	var before := road.road_change_count
	var typed := ""
	for ch in "Mountain":
		typed += ch
		seg.label = typed
	var renamed := road.road_change_count - before
	before = road.road_change_count
	seg.lane_count = 1
	var edited := road.road_change_count - before
	_check("N", renamed == 0 and seg.resource_name == "Mountain" and edited == 1,
			"8 keys ran the road change %d time(s) (want 0), label %s; control: a lane_count edit ran it %d time(s) (want 1)"
			% [renamed, seg.resource_name, edited])
	road.free()


func _s() -> void:
	print("[S] a stats refresh rebuilds only when the rows change")
	var road := Pasture3DRoadBrush.new()
	road.get_property_list() # lists the rows, as the inspector does on selection
	var open_rows := road._stats_rows_changed()
	road.closed = true
	var closed_rows := road._stats_rows_changed()
	road.get_property_list()
	var relisted := road._stats_rows_changed()
	_check("S", not open_rows and closed_rows and not relisted,
			"after listing an open road: %s (want false), after relisting a closed one: %s (want false); control: closing it before relisting: %s (want true)"
			% [open_rows, relisted, closed_rows])
	road.free()


func _p() -> void:
	print("[P] a point pick never rebuilds the segment")
	var seg := Pasture3DRoadSegment.new()
	var count := [0]
	seg.property_list_changed.connect(func() -> void: count[0] += 1)
	seg.from_point = 3
	seg.to_point = 7
	seg.from_point = 4
	seg.to_point = -1
	var picks: int = count[0]
	seg.notify_property_list_changed() # control: the counter sees a rebuild
	_check("P", picks == 0 and count[0] == 1,
			"4 picks emitted %d rebuild(s) (want 0); control: a direct notify counted %d (want 1)"
			% [picks, count[0] - picks])
