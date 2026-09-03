# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadCostGate — the road system's redundant work, counted.
# PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md §4, criterion [CA] (S6). [CB]–[CG] arrive with S7–S11.
#
# ---- COUNTERS, NOT CLOCKS ----
#
# Every criterion here is a call count, an allocation count or a work-unit count — how many times the
# plan was tessellated, how many `build_run()` calls one resolve made, how many cells a loop visited.
# Counts are deterministic, they fail loudly on a regression, and they do not depend on what else is
# running on the machine. A wall-clock number taken under an unrelated load is worse than no number, and
# this machine shares its load; any timed measurement is opt-in and asked for first.
#
# ---- WHY A COST GATE STILL HAS TO ASSERT CORRECTNESS ----
#
# A cache that never invalidates passes every "did it do less work" criterion perfectly. So each
# criterion below is paired with the question the optimisation could get wrong: [CA] asserts the count
# stays at one across repeated calls AND that it rises again on each thing that should invalidate, and
# separately that the cached answer still equals a freshly computed one. The first half alone is passed
# by returning a constant.
@tool
extends Node

## Outside the repo. A Pasture3D with no `data_directory` writes into the demo's, and the on-quit save
## then rewrites the demo's real region files. See RoadStaleGate for the same note.
const SCRATCH_DATA := "user://road_cost_gate"

var _fail: int = 0


func _ready() -> void:
	print("=== RoadCostGate: redundant work, counted (spec §4) ===\n")
	_ca_the_plan_is_tessellated_once()
	print("\n=== %s (%d failures) ===\n" % [
		"ROAD COST PASS" if _fail == 0 else "ROAD COST FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["    " if p_ok else "!!  ", p_name, p_detail])


# ---- [CA] --------------------------------------------------------------------------------------

## The plan is tessellated once per change, not once per caller.
##
## ---- WHAT IT COST ----
##
## `_plan_points` allocated a fresh PackedVector2Array from `path.curve.tessellate()` on every call, with
## no memoisation, and its callers are `_paint_flat_footprint`, `grade_surface`, `alignment_digest`,
## `build_run`, `graph_path`, `paint_bounds`, `point_at_arc`, `tangent_at_arc` and
## `pick_road_screen_distance`. `Pasture3DRoadNetwork._arms_for` alone calls `point_at_arc` and
## `tangent_at_arc` twice per junction end per participant, and each of those re-tessellated the whole
## road AND recomputed its cumulative lengths from scratch. On a 5 km road that is ~25 000 points per
## call.
##
## ---- WHAT THE CACHE MUST NOT GET WRONG ----
##
## The plan is GLOBAL-space, so it depends on each spline's `global_transform` — and a child Path3D
## dragged on its own sends the brush no notification at all. `[CA] child transform` is that case, and it
## is the one a signals-only cache would fail. A road graded along a centreline it no longer has is
## strictly worse than the cost this removes.
func _ca_the_plan_is_tessellated_once() -> void:
	print("[CA] the plan is tessellated once per change")
	var fx := _fixture()
	var brush: Pasture3DRoadBrush = fx["brush"]
	var path: Path3D = fx["path"]

	# Nine calls standing in for the nine call sites, plus the arc lengths every one of them wanted.
	brush.plan_builds = 0
	for i in 9:
		brush._plan_points()
		brush._plan_cum()
	_check("[CA]", brush.plan_builds == 1,
			"18 calls across 9 callers tessellated %d time(s)" % brush.plan_builds)

	# Each half below is a thing that must still invalidate. A cache that never invalidates passes the
	# criterion above perfectly, so without these [CA] would be satisfied by returning a constant.
	var cases: Array = [
		["curve edit", func() -> void: path.curve.set_point_position(1, Vector3(220.0, 0.0, 60.0))],
		# No signal reaches the brush for this one: NOTIFICATION_TRANSFORM_CHANGED fires on the node that
		# moved. The token reads the transforms rather than subscribing to them, which is why it holds.
		["child transform", func() -> void: path.position += Vector3(0.0, 0.0, 25.0)],
		["curve swap", func() -> void: path.curve = _straight_curve()],
		# ...and the swapped-in curve must be the one being listened to now. `changed` belongs to the
		# resource, so a memo that connected once at mount keeps hearing the discarded Curve3D and hears
		# nothing from the live one. The token's point count would mask this if the edit changed the size,
		# so this case MOVES a point instead of adding one.
		["edit after swap", func() -> void: path.curve.set_point_position(0, Vector3(55.0, 0.0, 140.0))],
		["closed", func() -> void: brush.closed = true],
		["new spline", func() -> void:
				var extra := Path3D.new()
				extra.curve = _straight_curve()
				brush.add_child(extra)],
	]
	for c in cases:
		brush._plan_points()
		brush.plan_builds = 0
		(c[1] as Callable).call()
		brush._plan_points()
		_check("[CA] %s" % c[0], brush.plan_builds == 1,
				"rebuilt %d time(s) after the change" % brush.plan_builds)

	# And the answer is still right. A cache that invalidates on all the right signals and then returns
	# a stale array would pass every count above.
	var cached := brush._plan_points()
	var fresh := _tessellate_reference(brush)
	var same := cached.size() == fresh.size()
	if same:
		for i in cached.size():
			if not cached[i].is_equal_approx(fresh[i]):
				same = false
				break
	_check("[CA] correct", same,
			"the cached plan matches an uncached tessellation (%d vertices)" % cached.size())

	# The arc lengths travel with it: they are derived from the plan and were recomputed just as often.
	var cum := brush._plan_cum()
	_check("[CA] arc lengths", cum.size() == cached.size()
			and absf(cum[cum.size() - 1] - _polyline_length(cached)) < 0.01,
			"cached cumulative lengths agree with the cached plan (%.2f m)" % cum[cum.size() - 1])
	fx["terrain"].queue_free()


## The plan as `_plan_points` would build it with no cache at all. The oracle for [CA] correct — written
## out rather than calling the brush, because calling the brush is what is under test.
func _tessellate_reference(p_brush: Pasture3DRoadBrush) -> PackedVector2Array:
	var out := PackedVector2Array()
	for child in p_brush.get_children():
		if not (child is Path3D):
			continue
		var path: Path3D = child
		if path.curve == null or path.curve.point_count < 2:
			continue
		var xf := path.global_transform
		for p in path.curve.tessellate():
			var w: Vector3 = xf * p
			out.append(Vector2(w.x, w.z))
	return out


func _polyline_length(p_pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, p_pts.size()):
		total += p_pts[i].distance_to(p_pts[i - 1])
	return total


func _straight_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(40.0, 0.0, 100.0))
	c.add_point(Vector3(200.0, 0.0, 100.0))
	return c


func _fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	terrain.data_directory = SCRATCH_DATA
	add_child(terrain)
	terrain.data.add_region_blank(Vector2i(0, 0))
	terrain.data.ensure_layer_stack()

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "cost"
	t.lane_count = 2
	t.lane_width = 3.5
	net.road_types = [t]

	var brush := Pasture3DRoadBrush.new()
	brush.name = "Cost"
	net.add_child(brush)
	brush.terrain = terrain
	brush.snap_to_surface = false
	brush.road_road_type = t

	var path := Path3D.new()
	var curve := Curve3D.new()
	curve.add_point(Vector3(40.0, 0.0, 60.0))
	curve.add_point(Vector3(200.0, 0.0, 60.0))
	curve.add_point(Vector3(200.0, 0.0, 180.0))
	path.curve = curve
	brush.add_child(path)

	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 4.0
	brush.modifiers = [road_mod]
	return {"terrain": terrain, "net": net, "brush": brush, "path": path}
