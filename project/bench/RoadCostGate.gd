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

## Every criterion this gate is supposed to report. A run that ends without one of these did not pass it,
## it never reached it — a script error inside a criterion aborts that function and `_ready` carries on to
## print a verdict. Registering them up front is what turns that silence into a failure.
const CRITERIA: PackedStringArray = [
	"[CA]", "[CA] curve edit", "[CA] child transform", "[CA] curve swap", "[CA] edit after swap",
	"[CA] closed", "[CA] new spline", "[CA] correct", "[CA] arc lengths",
	"[CB]", "[CB] action", "[CB] staleness", "[CB] control",
	"[CC] first pass", "[CC]", "[CC] scoped", "[CC] shared layer", "[CC] mask",
	"[CD] stable", "[CD] round trip", "[CD] plan", "[CD] road moved", "[CD] alignment_step",
	"[CD] smooth_radius", "[CD] follow_terrain", "[CD] max_grade", "[CD] design_speed",
	"[CD] rejects", "[CD] unquantised", "[CD] control",
	"[CE] no segments", "[CE] flat in samples", "[CE] graph_path", "[CE] oracle",
	"[CE] last wins", "[CE] half open",
	"[CF] covers", "[CF] parity", "[CF] clipped", "[CF] clip respected",
	"[CG]", "[CG] stamp key", "[CG] correct", "[CG] replaced", "[CG] edited in place",
	"[CG] resettles",
]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadCostGate: redundant work, counted (spec §4) ===\n")
	_ca_the_plan_is_tessellated_once()
	_cb_the_runtime_is_baked_on_purpose()
	_cc_only_changed_layers_repaint()
	_cd_the_alignment_digest_is_cheap_and_complete()
	_ce_the_cross_section_resolves_per_segment()
	_cf_the_corridor_prepass_is_native()
	_cg_the_corridor_allowance_is_scanned_once()
	print("\n=== %s (%d failures) ===\n" % [
		"ROAD COST PASS" if _fail == 0 else "ROAD COST FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
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


# ---- [CE] --------------------------------------------------------------------------------------

## Counts the two ancestor walks, which are what the per-sample resolve actually cost.
class WalkCountingBrush extends Pasture3DRoadBrush:
	var walks: int = 0

	func road_group() -> Pasture3DRoadGroup:
		walks += 1
		return super()

	func road_network() -> Pasture3DRoadNetwork:
		walks += 1
		return super()


## The cross-section is resolved once per segment, not once per sample — and answers the same numbers.
##
## ---- WHAT IT COST ----
##
## `_init` creates a `Pasture3DRoadOverrides` unconditionally, so `road_defaults != null` was ALWAYS true
## and the `not segments.is_empty() or road_defaults != null` guard never once took the fast path. Every
## road ran the loop, and every iteration called `resolved_road_type(s)`, `resolved_lane_count(s)` — which
## calls `resolved_road_type` again — and `is_bridge_at(s)`. Each of those allocated a chain `Array` and
## walked the parent list to the scene root twice, through `Pasture3DRoadGroup.find_for` and
## `Pasture3DRoadNetwork.find_for`. That is roughly six ancestor walks and three allocations per sample,
## five thousand times on a 5 km road, from three callers.
##
## ---- WHY THE ORACLE IS THE CRITERION AND THE COUNT IS THE HEADLINE ----
##
## A profile resolved once per segment is only worth having if it is the same profile. Everything about
## this fix is a rearrangement of WHERE a value is computed, so the way it fails is silently different
## numbers — a road a few centimetres wider along one segment, which looks like a road. So `[CE] oracle`
## computes the whole profile the old way, sample by sample through the public `resolved_*` API, and
## demands equality across every element of all four arrays. The counts are what make it a cost fix; the
## oracle is what makes it a safe one.
func _ce_the_cross_section_resolves_per_segment() -> void:
	print("\n[CE] the cross-section resolves once per segment, not once per sample")
	var fx := _profile_fixture()
	var brush: WalkCountingBrush = fx["brush"]
	var mod: Pasture3DNodeRoad = brush.modifiers[0]
	var n := 2000
	var ds := 0.25

	# A road with no segments: nothing in the chain varies along it, so the uniform fill IS the answer.
	brush.segments = [] as Array[Pasture3DRoadSegment]
	brush.walks = 0
	var plain := brush.grading_profile(mod, ds, n)
	var plain_walks := brush.walks
	_check("[CE] no segments", plain_walks < 20,
			"%d ancestor walk(s) for %d samples" % [plain_walks, n])

	# ...and with segments, the walks are a function of the SEGMENT count, not the sample count.
	var back: Array[Pasture3DRoadSegment] = fx["segments"]
	brush.segments = back
	brush.walks = 0
	var shaped := brush.grading_profile(mod, ds, n)
	var few := brush.walks
	brush.walks = 0
	brush.grading_profile(mod, ds, n * 4)
	var many := brush.walks
	_check("[CE] flat in samples", few == many and few < 40,
			"%d walk(s) at %d samples, %d at %d" % [few, n, many, n * 4])

	# `graph_path` had the same loop over up to 25 000 plan vertices. Fixing the grader and leaving this
	# one walking the tree per vertex is the asymmetry `grading_profile` exists to prevent.
	brush.walks = 0
	var gp := brush.graph_path()
	var small_walks := brush.walks
	var small := gp.points.size()
	# Lengthen the spline so the plan carries several times the vertices, and demand the SAME walk count.
	# An absolute bound would be satisfied by a loop that walks the tree twice per vertex on a fixture
	# whose curve happens to tessellate to thirty points; only holding it flat as the plan grows says
	# anything about the loop.
	var curve: Curve3D = (brush.get_child(0) as Path3D).curve
	for k in 6:
		curve.add_point(Vector3(230.0 + float(k + 1) * 60.0, 0.0, 70.0 + float(k % 2) * 50.0),
				Vector3(-25.0, 0.0, 0.0), Vector3(25.0, 0.0, 0.0))
	brush._refresh_owner(brush._layer_owner, false, [])
	brush.walks = 0
	var gp_big := brush.graph_path()
	_check("[CE] graph_path", small_walks == brush.walks and gp_big.points.size() > small * 2
			and gp_big.half_widths.size() == gp_big.points.size(),
			"%d walk(s) for %d plan vertices, %d for %d"
			% [small_walks, small, brush.walks, gp_big.points.size()])

	# The oracle. The whole profile, recomputed sample by sample through the public API the loop used to
	# call, and compared element for element.
	var want := _profile_oracle(brush, mod, ds, n)
	var same := _same_profile(shaped, want)
	_check("[CE] oracle", same == "",
			"the per-segment profile matches a per-sample one over %d samples%s"
			% [n, "" if same == "" else " — " + same])

	# The rule the fill order carries. Segments may overlap and the LAST one in the array wins, which is
	# what lets a short bridge sit inside a long gravel stretch. Filling per segment instead of testing per
	# sample preserves that only because the fill runs in array order, and nothing else says so.
	var inner: Pasture3DRoadSegment = fx["inner"]
	var at_inner := int(((inner.from_distance + inner.to_distance) * 0.5) / ds)
	_check("[CE] last wins", shaped["suppress"][at_inner] == 1,
			"the later, overlapping bridge segment governs its own range")

	# `covers` is half-open [from, to), so two abutting segments must not both claim the boundary. A
	# range fill is exactly where an off-by-one would land, and it would be invisible: one sample wide.
	var outer: Pasture3DRoadSegment = fx["outer"]
	var past := int(outer.to_distance / ds)
	_check("[CE] half open", shaped["half"][past] == plain["half"][past],
			"the sample exactly at a segment's to_distance is outside it")
	fx["terrain"].queue_free()


## The profile as the old loop derived it: once per sample, through the public resolvers.
func _profile_oracle(p_brush: Pasture3DRoadBrush, p_mod: Pasture3DNodeRoad, p_ds: float,
		p_n: int) -> Dictionary:
	var t := p_brush.resolved_road_type()
	var half := PackedFloat32Array()
	var shoulder := PackedFloat32Array()
	var verge := PackedFloat32Array()
	var suppress := PackedByteArray()
	half.resize(p_n)
	shoulder.resize(p_n)
	verge.resize(p_n)
	suppress.resize(p_n)
	for i in p_n:
		var s := float(i) * p_ds
		var ti := p_brush.resolved_road_type(s)
		var tt: Pasture3DRoadType = ti if ti != null else t
		half[i] = tt.half_width(p_brush.resolved_lane_count(s)) if tt != null else 3.5
		shoulder[i] = tt.shoulder_width if tt != null else 0.5
		if p_mod != null and p_mod.verge_override >= 0.0:
			verge[i] = p_mod.verge_override
		else:
			verge[i] = tt.verge_width if tt != null else 4.0
		suppress[i] = 1 if p_brush.is_bridge_at(s) else 0
	return {"half": half, "shoulder": shoulder, "verge": verge, "suppress": suppress}


## "" when the four arrays agree everywhere, else the first disagreement — named, because "the profiles
## differ" over two thousand samples is not something anyone can act on.
func _same_profile(p_got: Dictionary, p_want: Dictionary) -> String:
	for key in ["half", "shoulder", "verge", "suppress"]:
		var a = p_got[key]
		var b = p_want[key]
		if a.size() != b.size():
			return "%s: %d vs %d elements" % [key, a.size(), b.size()]
		for i in a.size():
			if absf(float(a[i]) - float(b[i])) > 0.0001:
				return "%s[%d]: %s vs %s" % [key, i, str(a[i]), str(b[i])]
	return ""


## A road with two OVERLAPPING segments: a long one that widens the road, and a short bridge inside it.
## The overlap is what makes `[CE] last wins` a real case, and the long one's `to_distance` is what
## `[CE] half open` lands on.
func _profile_fixture() -> Dictionary:
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
	t.type_name = "profile"
	t.lane_count = 2
	t.lane_width = 3.5
	t.shoulder_width = 0.5
	t.verge_width = 4.0
	net.road_types = [t]

	var grp := Pasture3DRoadGroup.new()
	net.add_child(grp)

	var brush := WalkCountingBrush.new()
	brush.name = "Profile"
	grp.add_child(brush)
	brush.terrain = terrain
	brush.snap_to_surface = false
	brush.road_road_type = t

	var path := Path3D.new()
	# CURVED, with real tangents. A straight polyline tessellates to its three control points, and
	# `[CE] graph_path` — a loop over plan VERTICES — would then be asserted over three of them, which is
	# a criterion that passes whatever the loop does.
	var c := Curve3D.new()
	c.add_point(Vector3(20.0, 0.0, 60.0), Vector3.ZERO, Vector3(40.0, 0.0, 0.0))
	c.add_point(Vector3(120.0, 0.0, 150.0), Vector3(-40.0, 0.0, -30.0), Vector3(40.0, 0.0, 30.0))
	c.add_point(Vector3(230.0, 0.0, 70.0), Vector3(-40.0, 0.0, 30.0), Vector3.ZERO)
	path.curve = c
	brush.add_child(path)

	var outer := Pasture3DRoadSegment.new()
	outer.from_distance = 40.0
	outer.to_distance = 160.0
	outer.lane_count = 6            # a different cross-section over its range
	var inner := Pasture3DRoadSegment.new()
	inner.from_distance = 80.0      # INSIDE outer, and later in the array, so it wins there
	inner.to_distance = 110.0
	inner.is_bridge = true
	var typed: Array[Pasture3DRoadSegment] = [outer, inner]
	brush.segments = typed

	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 0.25
	brush.modifiers = [mod]
	brush._refresh_owner(brush._layer_owner, false, [])
	return {"terrain": terrain, "net": net, "brush": brush, "type": t,
			"segments": typed, "outer": outer, "inner": inner}


# ---- [CF] --------------------------------------------------------------------------------------

## The corridor pre-pass is answered natively, and answers the same cells.
##
## ---- WHAT IT COST ----
##
## The GDScript footprint branch runs whenever `_road_native_is_complete()` is false — whenever the stack
## is anything but exactly one road modifier, which is precisely the §8 workflow the road-in-a-graph design
## exists for (Road + Graph, Road + Erosion). A 5 km road with a 50 m corridor at `vs = 1` is ~250 000
## cells, and every cell ran an interpreted `nearest_on_plan` over ~25 000 plan segments. The result set
## `amp = 0` / `profile = 1`, and the road step then called the native grader, which recomputed the same
## nearest-point query in C++ against a spatial index.
##
## ---- WHY PARITY IS THE CRITERION AND A COUNT WOULD NOT DO ----
##
## `Pasture3DUtil.path_query_grid` samples CELL CENTRES over the rect it is handed, and this grid is
## vertex-centred at `min_x + ix * vs`. The rect therefore has to be offset by half a cell in each axis.
## Get that wrong and every road shifts by half a vertex — the same number of cells marked, all of them in
## the wrong place, which reads as "the corridor looks slightly off" and survives any criterion that counts
## rather than compares. So `[CF] parity` compares the two implementations CELL FOR CELL, and it drives
## both through the production function rather than reimplementing the fallback here.
func _cf_the_corridor_prepass_is_native() -> void:
	print("\n[CF] the corridor pre-pass is native, and marks the same cells")
	var fx := _profile_fixture()
	var brush: Pasture3DRoadBrush = fx["brush"]
	var plan := brush._plan_points()
	var cum := brush._plan_cum()
	if plan.size() < 8:
		_check("[CF] parity", false, "the fixture produced only %d plan vertices" % plan.size())
		fx["terrain"].queue_free()
		return

	var vs := 1.0
	var min_x := 0.0
	var min_z := 0.0
	var gw := 260
	var gh := 200
	var reach := brush.corridor_half_width()

	var native := _corridor(brush, plan, cum, reach, min_x, min_z, vs, gw, gh, 0, gw - 1, 0, gh - 1, true)
	var script_ := _corridor(brush, plan, cum, reach, min_x, min_z, vs, gw, gh, 0, gw - 1, 0, gh - 1, false)

	var marked := 0
	for v in native["profile"]:
		if v > 0.5:
			marked += 1
	# A corridor that marked nothing, or the whole grid, would make every comparison below vacuous.
	_check("[CF] covers", marked > 200 and marked < gw * gh / 2,
			"%d of %d cells are inside the corridor (reach %.2f m)" % [marked, gw * gh, reach])

	var diff := _first_difference(native, script_)
	_check("[CF] parity", diff == "",
			"the native and GDScript pre-passes agree over %d cells%s"
			% [gw * gh, "" if diff == "" else " — " + diff])

	# The clip. A dirty-rect bake asks for a sub-grid, and the native call is handed that sub-rect rather
	# than the whole grid — so the index arithmetic mapping the query's rows back into the full grid is new
	# code, and an off-by-one there writes the corridor into the wrong rows.
	var ix0 := 60
	var ix1 := 190
	var iz0 := 40
	var iz1 := 150
	var n_clip := _corridor(brush, plan, cum, reach, min_x, min_z, vs, gw, gh, ix0, ix1, iz0, iz1, true)
	var s_clip := _corridor(brush, plan, cum, reach, min_x, min_z, vs, gw, gh, ix0, ix1, iz0, iz1, false)
	var cdiff := _first_difference(n_clip, s_clip)
	_check("[CF] clipped", cdiff == "",
			"a clipped sub-grid agrees too%s" % ["" if cdiff == "" else " — " + cdiff])

	# ...and the clip really clipped, or [CF] clipped is two full grids agreeing with each other.
	var outside := 0
	for iz in gh:
		for ix in gw:
			if (ix < ix0 or ix > ix1 or iz < iz0 or iz > iz1) \
					and n_clip["profile"][iz * gw + ix] > 0.5:
				outside += 1
	var inside_marked := 0
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			if n_clip["profile"][iz * gw + ix] > 0.5:
				inside_marked += 1
	_check("[CF] clip respected", outside == 0 and inside_marked > 100 and inside_marked < marked,
			"%d cell(s) marked outside the clip, %d inside it, %d unclipped"
			% [outside, inside_marked, marked])
	fx["terrain"].queue_free()


## One run of the production pre-pass over a fresh pair of buffers.
func _corridor(p_brush: Pasture3DRoadBrush, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_reach: float, p_min_x: float, p_min_z: float, p_vs: float, p_gw: int, p_gh: int,
		p_ix0: int, p_ix1: int, p_iz0: int, p_iz1: int, p_native: bool) -> Dictionary:
	var amp := PackedFloat64Array()
	var profile := PackedFloat64Array()
	amp.resize(p_gw * p_gh)
	amp.fill(NAN)
	profile.resize(p_gw * p_gh)
	profile.fill(0.0)
	p_brush._mark_corridor(amp, profile, p_plan, p_cum, p_reach, p_min_x, p_min_z, p_vs, p_gw,
			p_ix0, p_ix1, p_iz0, p_iz1, p_native)
	return {"amp": amp, "profile": profile}


## "" when both buffers agree everywhere, else the first cell that differs — named, because "they differ"
## over fifty thousand cells is not something anyone can act on. A half-cell offset shows up here as a
## single column index, which is what makes the misalignment legible rather than merely detected.
func _first_difference(p_a: Dictionary, p_b: Dictionary) -> String:
	var pa: PackedFloat64Array = p_a["profile"]
	var pb: PackedFloat64Array = p_b["profile"]
	var aa: PackedFloat64Array = p_a["amp"]
	var ab: PackedFloat64Array = p_b["amp"]
	for i in pa.size():
		if pa[i] != pb[i]:
			return "profile[%d]: %s vs %s" % [i, str(pa[i]), str(pb[i])]
		if is_nan(aa[i]) != is_nan(ab[i]):
			return "amp[%d]: %s vs %s" % [i, str(aa[i]), str(ab[i])]
	return ""


# ---- [CG] --------------------------------------------------------------------------------------

## Counts the alignment scan by counting the thing the scan is made of.
##
## `deepest_structure` is still expressed through `offset_at` — that is the definition of the quantity —
## which is exactly what makes a per-sample counter possible. A memo that read `z[i] - ground[i]` directly
## would be invisible to this and the criterion would be measuring nothing.
class CountingAlignment extends Pasture3DRoadAlignment:
	var samples: int = 0

	func offset_at(p_i: int) -> float:
		samples += 1
		return super(p_i)


## The corridor allowance is scanned once per profile, not once per caller.
##
## ---- WHAT IT COST ----
##
## `_deepest_structure` looped the whole alignment — 10 000 iterations on a 10 km road — with no memo
## against the profile it had just scanned. `corridor_half_width` calls it once per active road modifier,
## and is itself called from `_padding`, `paint_bounds` (per road inside `_clear_paint_layers` on every
## resolve), `build_runtime`, `_paint_flat_footprint` twice, `grade_surface`, and
## `pick_road_screen_distance` — the last once per road brush on every editor click.
##
## ---- WHY THIS ONE STOPPED BEING OPTIONAL ----
##
## S1 put `snappedf(_padding(), PAD_QUANTUM)` into the stamp key. The key is computed to decide whether a
## bake can be replayed from cache, so the cheap path through the cache was paying a full alignment scan
## to find out that it was the cheap path. `[CG] stamp key` is that specific case.
##
## ---- WHAT A MEMO HERE COULD GET WRONG ----
##
## The corridor exists to be wide enough for the earthworks; too narrow and the batters are cut off at a
## sheer wall. A stale allowance is therefore not a slow road, it is a road with a cliff beside it. So the
## invalidation is asserted twice over — a replaced profile and a profile EDITED IN PLACE, which is the
## case a memo keyed on the alignment's `input_digest` would have missed, since editing `z` does not
## change what the profile was solved from.
func _cg_the_corridor_allowance_is_scanned_once() -> void:
	print("\n[CG] the corridor allowance is scanned once per profile")
	var fx := _profile_fixture()
	var brush: Pasture3DRoadBrush = fx["brush"]
	var mod: Pasture3DNodeRoad = brush.modifiers[0]
	var align := _counting_alignment(400, 20.0)
	mod.last_alignment = align

	align.samples = 0
	var first := brush.corridor_half_width()
	var one := align.samples
	for i in 20:
		brush.corridor_half_width()
		brush._padding()
	_check("[CG]", align.samples == one and one >= 400,
			"%d sample(s) for the first call, %d after 41 more" % [one, align.samples])

	# The stamp key reads `_padding()`, so before the memo the cache-hit path paid a full alignment scan
	# to discover it was the cache-hit path.
	align.samples = 0
	for i in 10:
		brush._compute_stamp_key(brush.get_child(0) as Path3D)
	_check("[CG] stamp key", align.samples == 0,
			"ten stamp-key computations scanned %d sample(s)" % align.samples)

	# The value is right, which every count above would be equally happy without.
	var want := 0.0
	for i in align.count():
		want = maxf(want, absf(align.z[i] - align.ground[i]))
	_check("[CG] correct", absf(align.deepest_structure() - want) < 0.0001,
			"the memoised allowance is %.3f m, the profile's worst offset is %.3f m"
			% [align.deepest_structure(), want])

	# A REPLACED profile. The obvious invalidation, and the one a memo on the modifier would also get.
	# Past `structure_threshold` AND past the 12 m floor, or `corridor_half_width` returns the same
	# allowance for both profiles and `[CG] replaced` compares a constant with itself.
	var deeper := _counting_alignment(400, 60.0)
	mod.last_alignment = deeper
	var replaced := brush.corridor_half_width()
	_check("[CG] replaced", replaced > first,
			"a deeper profile widens the corridor: %.2f m -> %.2f m" % [first, replaced])

	# A profile EDITED IN PLACE. This is the one that separates a memo hanging off `changed` from a memo
	# keyed on `input_digest`: editing the solved heights does not change what the profile was solved
	# FROM, so a digest-keyed memo would answer with the old allowance and the batters would be cut off.
	var before_edit := deeper.deepest_structure()
	var z := deeper.z
	z[10] = deeper.ground[10] + 140.0
	deeper.samples = 0
	deeper.z = z
	var after_edit := deeper.deepest_structure()
	var rescan := deeper.samples
	_check("[CG] edited in place", after_edit > before_edit + 50.0 and rescan >= deeper.count(),
			"editing the solved heights re-scanned %d sample(s): %.2f m -> %.2f m"
			% [rescan, before_edit, after_edit])

	# ...and having re-scanned ONCE, it settles again rather than scanning per call forever. Counted from
	# after that scan, so this cannot be passed by the memo the previous assertion just repopulated.
	deeper.samples = 0
	for i in 10:
		brush.corridor_half_width()
	_check("[CG] resettles", deeper.samples == 0,
			"%d sample(s) for ten calls after the re-scan" % deeper.samples)
	fx["terrain"].queue_free()


## A profile whose worst offset is `p_depth` metres, deep enough to move `corridor_half_width` off its
## 12 m floor — otherwise every criterion above compares two identical numbers.
func _counting_alignment(p_n: int, p_depth: float) -> CountingAlignment:
	var a := CountingAlignment.new()
	a.ds = 1.0
	a.s0 = 0.0
	var z := PackedFloat32Array()
	var ground := PackedFloat32Array()
	z.resize(p_n)
	ground.resize(p_n)
	for i in p_n:
		ground[i] = 10.0
		# One deep sample, the rest shallow: the quantity is a MAXIMUM, so a uniformly deep profile would
		# pass a memo that returned the first sample instead of the worst.
		z[i] = 10.0 + (p_depth if i == p_n / 3 else 0.25)
	a.z = z
	a.ground = ground
	a.curvature = _filled(p_n, 0.0)
	a.bank = _filled(p_n, 0.0)
	a.pinned = PackedInt32Array()
	a.input_digest = "fixed"  # deliberately CONSTANT across every profile this gate builds
	return a
