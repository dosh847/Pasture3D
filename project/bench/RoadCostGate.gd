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
	_cb_the_runtime_is_baked_on_purpose()
	_cc_only_changed_layers_repaint()
	_cd_the_alignment_digest_is_cheap_and_complete()
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


# ---- [CB] --------------------------------------------------------------------------------------

## Counts `build_runtime` so [CB] can say WHO baked it rather than whether one exists.
class CountingNetwork extends Pasture3DRoadNetwork:
	var runtime_builds: int = 0

	func build_runtime(p_brushes: Array = []) -> int:
		runtime_builds += 1
		return super(p_brushes)


## A control-point drag does not rebuild the game-facing runtime; pressing Bake Runtime does.
##
## ---- WHAT IT COST ----
##
## `build_runtime` sat at the end of `resolve_junctions`, and a resolve runs on every drag. It called
## `build_run()` on every road in the network — a fourth time per resolve — plus `surface_intervals()` and
## `corridor_half_width()` per road, and then assigned `runtime`, `run_ids` and `next_run_id`, all
## `@export`. Moving one control point rebuilt a deliverable for nineteen roads that had not moved AND
## marked the scene modified.
##
## ---- WHY THE COUNT ALONE IS NOT THE CRITERION ----
##
## Deleting the call passes "a drag does not bake the runtime" perfectly and ships a runtime that can
## never be rebuilt. So the same criterion asserts the button still works, that the runtime it produces
## has the roads in it, and that a network whose roads have changed since the bake SAYS SO — the
## configuration warning is the entire safety net now, because Bake All Brushes walks the erosion registry
## and has never seen a road.
func _cb_the_runtime_is_baked_on_purpose() -> void:
	print("\n[CB] the runtime is baked by an action, not by a drag")
	var fx := _network_fixture()
	var net: CountingNetwork = fx["net"]
	var roads: Array = fx["roads"]

	net.runtime_builds = 0
	net.resolve_junctions()
	_check("[CB]", net.runtime_builds == 0 and net.runtime == null,
			"a resolve built the runtime %d time(s)" % net.runtime_builds)

	# It is still buildable, and it still contains the roads. "Never baked" passes the half above.
	net.runtime_builds = 0
	var runs := net.bake_runtime()
	_check("[CB] action", net.runtime_builds == 1 and net.runtime != null and runs == 4,
			"Bake Runtime built %d run(s) from 4 road(s)" % runs)

	# Clean immediately after the bake...
	var clean_stale := _mentions_stale(net._get_configuration_warnings())
	# ...and stale once a road changes, which is the only thing standing between a user and a silently
	# out-of-date deliverable now that nothing rebuilds it for them.
	roads[0].road_lane_count = 5
	var dirty_stale := _mentions_stale(net._get_configuration_warnings())
	_check("[CB] staleness", not clean_stale and dirty_stale,
			"warned after the bake: %s; after a road changed: %s" % [str(clean_stale), str(dirty_stale)])

	# And a resolve does not quietly clear the warning by re-baking behind the user's back.
	net.runtime_builds = 0
	net.resolve_junctions()
	_check("[CB] control", net.runtime_builds == 0
			and _mentions_stale(net._get_configuration_warnings()),
			"a resolve after the edit built %d runtime(s) and left the warning up" % net.runtime_builds)
	fx["terrain"].queue_free()


func _mentions_stale(p_warnings: PackedStringArray) -> bool:
	for w in p_warnings:
		if w.contains("Bake Runtime"):
			return true
	return false


# ---- [CC] --------------------------------------------------------------------------------------

## Counts `paint_surface` so [CC] can say which roads repainted, not just that the paint is right.
class CountingRoadBrush extends Pasture3DRoadBrush:
	var paints: int = 0

	func paint_surface() -> int:
		paints += 1
		return super()


## A resolve repaints the roads whose paint would differ, and the roads sharing their layer — not all of
## them, and not fewer.
##
## ---- WHAT IT COST ----
##
## `paint_roads` cleared and repainted EVERY road on every resolve, and a resolve runs on every drag.
## `clear_layer_in_area` works at whole-tile granularity over the union of a layer's roads, so a
## twenty-road network re-wrote twenty corridors because one control point moved.
##
## ---- WHY THE UNIT IS THE LAYER AND NOT THE ROAD ----
##
## The clear must stay per layer over a union — clearing per road drops a neighbour's cells at a shared
## tile boundary, because whole tiles go. So scoping the repaint to "the road that moved" would clear its
## layer's whole box and leave every other road on that layer erased. The dirty set is therefore closed
## over shared layers, and `[CC] shared layer` is the assertion that it is: two roads in ONE group repaint
## together even when only one of them changed. Getting this wrong is not a slow road, it is a missing one.
func _cc_only_changed_layers_repaint() -> void:
	print("\n[CC] a resolve repaints the layers that changed, and no others")
	var fx := _network_fixture()
	var net: CountingNetwork = fx["net"]
	var roads: Array = fx["roads"]
	var shared: Array = fx["shared"]
	var all: Array = roads + shared

	net.resolve_junctions()  # first pass: nothing is painted yet, so everything paints
	_check("[CC] first pass", _paints(all) == 4,
			"%d of 4 road(s) painted on the first resolve" % _paints(all))

	# Nothing changed. This is the drag that used to cost a full repaint.
	_reset_paints(all)
	net.resolve_junctions()
	_check("[CC]", _paints(all) == 0,
			"an unchanged resolve repainted %d road(s)" % _paints(all))

	# One road on its own layer changes. Only it repaints.
	_reset_paints(all)
	_move_road(roads[0])
	net.resolve_junctions()
	_check("[CC] scoped", roads[0].paints == 1 and roads[1].paints == 0 and _paints(shared) == 0,
			"road 0 painted %d, road 1 painted %d, the shared-layer pair painted %d"
			% [roads[0].paints, roads[1].paints, _paints(shared)])

	# One road of a SHARED-layer pair changes. BOTH repaint, because the clear takes the whole layer.
	_reset_paints(all)
	_move_road(shared[0])
	net.resolve_junctions()
	_check("[CC] shared layer", shared[0].paints == 1 and shared[1].paints == 1,
			"the edited road painted %d and its layer-mate painted %d"
			% [shared[0].paints, shared[1].paints])

	# The case a content signature would have missed, and the reason `paint_signature` reads the mask.
	# The cover mask is produced by the grade, and the grade reads the ground: move a mound under a road
	# and its corridor changes shape while every property on the road stays exactly as it was. Mutating
	# the mask directly is that case, without the mound.
	_reset_paints(all)
	var mod: Pasture3DNodeRoad = roads[1].road_modifier()
	var cover: PackedFloat32Array = mod.last_masks["surface"]
	cover[int(cover.size() / 2)] = 1.0 - cover[int(cover.size() / 2)]
	mod.last_masks["surface"] = cover
	net.resolve_junctions()
	_check("[CC] mask", roads[1].paints == 1,
			"a road whose cover mask changed with no property edit painted %d time(s)"
			% roads[1].paints)
	fx["terrain"].queue_free()


func _paints(p_roads: Array) -> int:
	var n := 0
	for b in p_roads:
		n += b.paints
	return n


func _reset_paints(p_roads: Array) -> void:
	for b in p_roads:
		b.paints = 0


## Move a road and re-bake it, so its cover mask is genuinely different rather than merely re-declared.
func _move_road(p_brush) -> void:
	var path: Path3D = p_brush.get_child(0)
	path.curve.set_point_position(1, path.curve.get_point_position(1) + Vector3(0.0, 0.0, 6.0))
	p_brush._refresh_owner(p_brush._layer_owner, false, [])


## Four roads: two alone on their own group layers, two SHARING one. The share is what makes
## `[CC] shared layer` a real case — with every road on its own layer the closure over layers is the
## identity, and a scoping bug that ignored it would pass.
func _network_fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	terrain.data_directory = SCRATCH_DATA
	add_child(terrain)
	terrain.data.add_region_blank(Vector2i(0, 0))
	terrain.data.ensure_layer_stack()

	var net := CountingNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "cost"
	t.lane_count = 2
	t.lane_width = 3.5
	t.surface_layer_id = 1  # >= 0, or paint_surface returns before it writes anything (§4.4)
	net.road_types = [t]

	var groups: Array = []
	for i in 3:
		var grp := Pasture3DRoadGroup.new()
		grp.name = "G%d" % i
		net.add_child(grp)
		groups.append(grp)

	var roads: Array = []
	var shared: Array = []
	for i in 4:
		# Roads 2 and 3 both go in group 2, so they share one paint layer.
		var grp: Pasture3DRoadGroup = groups[mini(i, 2)]
		var b := CountingRoadBrush.new()
		b.name = "R%d" % i
		grp.add_child(b)
		b.terrain = terrain
		b.snap_to_surface = false
		b.road_road_type = t
		var path := Path3D.new()
		var c := Curve3D.new()
		var z := 40.0 + float(i) * 40.0
		c.add_point(Vector3(30.0, 0.0, z))
		c.add_point(Vector3(120.0, 0.0, z))
		c.add_point(Vector3(210.0, 0.0, z))
		path.curve = c
		b.add_child(path)
		var mod := Pasture3DNodeRoad.new()
		mod.alignment_step = 4.0
		b.modifiers = [mod]
		if i < 2:
			roads.append(b)
		else:
			shared.append(b)
	for b in roads + shared:
		b._refresh_owner(b._layer_owner, false, [])
	return {"terrain": terrain, "net": net, "type": t, "roads": roads, "shared": shared}


# ---- [CD] --------------------------------------------------------------------------------------

## The alignment digest sees everything it saw before, and one thing it could not.
##
## ---- WHAT IT COST ----
##
## `alignment_digest` formatted every tessellated plan point with `"%.3f,%.3f"`, joined the lot and hashed
## the resulting string. A 5 km road is ~25 000 points, so that is 25 000 `String` formats, a
## 25 000-element join and a hash of ~500 KB — per call. It is called from `_paint_flat_footprint`,
## `grade_surface`, `restorable_alignment` and `Pasture3DRoadChunkHost.rebuild`, and the last of those runs
## for EVERY road on EVERY resolve, purely to decide that nothing had changed.
##
## ---- WHY THIS CRITERION IS MOSTLY ABOUT CORRECTNESS ----
##
## The cost here is structural — a per-point loop replaced by one `hash()` over the packed array — and a
## structural change has no honest counter to report; the only measurement that would show it is a clock,
## and a clock on this machine measures whatever else is running. So what is asserted is the thing that
## could actually go wrong. `alignment_digest`'s own header states it: the digest must be computed the same
## way when STORING and when CHECKING, because a staleness test that passes when it should fail rebuilds a
## road confidently in the wrong place. So [CD] round-trips it, then names every input separately.
##
## ---- THE ONE BEHAVIOURAL CHANGE, ASSERTED RATHER THAN HOPED FOR ----
##
## `"%.3f"` quantised positions to a millimetre and the scalar terms to four or five places, so changes
## below those thresholds were invisible to the guard. Hashing the values does not quantise. That can only
## make the digest invalidate MORE often, never less, which is the safe direction for a guard and the only
## direction that is — and `[CD] unquantised` is what pins it, because it is a case the old derivation
## provably could not see.
func _cd_the_alignment_digest_is_cheap_and_complete() -> void:
	print("\n[CD] the alignment digest is derived numerically and still sees every input")
	var fx := _fixture()
	var brush: Pasture3DRoadBrush = fx["brush"]
	var path: Path3D = fx["path"]
	var mod: Pasture3DNodeRoad = brush.modifiers[0]
	var t: Pasture3DRoadType = brush.resolved_road_type()

	# Determinism first: everything below is meaningless if two calls on an untouched road disagree.
	var base := brush.alignment_digest()
	_check("[CD] stable", base == brush.alignment_digest() and not base.is_empty(),
			"two calls on an untouched road agree (%s)" % base)

	# The round trip. Store a profile stamped with the digest, then ask whether it is still an answer to
	# the road as it stands — this is the only path `restore_built_output` trusts on scene load.
	mod.last_alignment = _stamped_alignment(brush, mod)
	_check("[CD] round trip", brush.restorable_alignment() != null,
			"a profile stamped by this derivation is accepted by it")

	# Every input, named separately. A digest missing one of these is a road restored from a profile that
	# is no longer an answer to it, and nothing downstream can tell.
	var cases: Array = [
		["plan", func() -> void:
				path.curve.set_point_position(1, Vector3(210.0, 0.0, 75.0))],
		["road moved", func() -> void: path.position += Vector3(0.0, 0.0, 12.0)],
		["alignment_step", func() -> void: mod.alignment_step = 7.0],
		["smooth_radius", func() -> void: mod.smooth_radius = 25.0],
		["follow_terrain", func() -> void: brush.road_follow_terrain = 1],
		["max_grade", func() -> void: t.max_grade = 0.11],
		["design_speed", func() -> void: t.design_speed = 31.0],
	]
	for c in cases:
		var before := brush.alignment_digest()
		(c[1] as Callable).call()
		_check("[CD] %s" % c[0], brush.alignment_digest() != before,
				"the stored profile is rejected once this input moves")

	# ...and the stale profile from before all of that is now correctly refused.
	_check("[CD] rejects", brush.restorable_alignment() == null,
			"the profile stamped before those edits is no longer accepted")

	# The change the removed formatting makes. `"%.3f"` rounded to a millimetre, so a tenth of one was
	# invisible to the guard; hashing the values is not quantised. This case is here because it is the one
	# the old derivation provably could not see, which makes it the assertion that the loop is really gone.
	mod.last_alignment = _stamped_alignment(brush, mod)
	var sub_mm := brush.alignment_digest()
	path.curve.set_point_position(1, path.curve.get_point_position(1) + Vector3(0.0001, 0.0, 0.0))
	_check("[CD] unquantised", brush.alignment_digest() != sub_mm
			and brush.restorable_alignment() == null,
			"a 0.1 mm move invalidates the stored profile")

	# The control. A property the vertical profile is not a function of must NOT invalidate it, or [CD] is
	# passed by a digest that changes on everything — which restores nothing, ever, and turns every scene
	# open into "your roads need a bake".
	mod.last_alignment = _stamped_alignment(brush, mod)
	brush.name = "RenamedInTheInspector"
	brush.road_surface_id = &"gravel"
	_check("[CD] control", brush.restorable_alignment() != null,
			"a rename and a surface change leave the stored profile restorable")
	fx["terrain"].queue_free()


## A minimal solved profile carrying the digest of the road as it stands. `restorable_alignment` needs
## a non-empty alignment with a non-empty `input_digest`; the heights themselves are not read by [CD].
func _stamped_alignment(p_brush: Pasture3DRoadBrush, p_mod: Pasture3DNodeRoad) -> Pasture3DRoadAlignment:
	var a := Pasture3DRoadAlignment.new()
	a.ds = p_mod.alignment_step
	a.s0 = 0.0
	var n := 8
	a.z = _filled(n, 10.0)
	a.ground = _filled(n, 10.0)
	a.curvature = _filled(n, 0.0)
	a.bank = _filled(n, 0.0)
	a.pinned = PackedInt32Array()
	a.pinned.resize(n)
	a.input_digest = p_brush.alignment_digest(p_mod)
	return a


func _filled(p_n: int, p_v: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(p_v)
	return a
