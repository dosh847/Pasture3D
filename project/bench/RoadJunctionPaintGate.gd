# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadJunctionPaintGate — markings INSIDE a junction (road P9a).
# See PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md §2.3, §2.6.
#
# Built so far: stop bars, crossings and give-way rows. Connector guides come next and will add their
# criteria to this file. ARM_CONTINUATION is not coming -- see the note on
# `Pasture3DRoadJunctionMarkings.Kind`; the gap it was for was the disc's, and P9a-0 closed it.
#
#   A  a 4-arm crossroads emits exactly one STOP_BAR per incoming lane, on both roads
#   B  each bar's midpoint is its stop line's point, its edge is across the heading, and it moves when
#      the trim-back moves
#   H  a crossing spans the arm's CARRIAGEWAY, not its formation, and sits outside the stop bar
#   I  give-way triangles appear only on arms that lose priority, and never under signals
#   N  a disabled or undetected junction paints nothing
#   O  build_junction puts the paint ON the surface it is given, not at the road's centreline height
#
# ---- WHY A COUNTS RATHER THAN LOOKS ----
#
# "There are stop bars" is true of any implementation that emits some. The claim worth making is that
# there is exactly one per INCOMING lane: an outgoing lane has nothing to hold for, and a bar painted
# across one instructs traffic leaving the junction to stop in it. So A states the number in advance
# from the fixture's own lane counts, and checks that both roads are represented — four bars all on one
# road satisfies the count and means the kernel is painting one road's two arms twice.
@tool
extends Node

var _fail: int = 0

## Criteria that reached their end. A criterion that throws part way through -- a fixture that failed to
## build, a null the guards did not expect -- prints an engine error and returns, incrementing nothing,
## and the gate then reports PASS having measured nothing. That happened during this gate's own build:
## a typed-array assignment threw inside the fixture and three criteria silently did not run.
##
## So each one records that it FINISHED, and `_ready` fails if any did not.
var _ran := {}


func _ready() -> void:
	print("=== RoadJunctionPaintGate: markings inside a junction (P9a) ===\n")
	await _a_one_stop_bar_per_incoming_lane()
	await _b_a_bar_sits_on_its_stop_line()
	await _h_a_crossing_spans_the_carriageway()
	await _i_give_way_goes_to_the_arm_that_loses()
	await _n_a_disabled_junction_paints_nothing()
	_o_the_paint_sits_on_the_surface()
	for want in ["A", "B", "H", "I", "N", "O"]:
		if not _ran.has(want):
			_fail += 1
			print("    !! criterion %s did not run to completion, so it measured nothing" % want)
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD JUNCTION PAINT PASS" if _fail == 0 else "ROAD JUNCTION PAINT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A ------------------------------------------------------------------------------------------

func _a_one_stop_bar_per_incoming_lane() -> void:
	print("[A] one stop bar per incoming lane, on both roads")
	var fx := await _fixture()
	var net: Pasture3DRoadNetwork = fx["net"]
	var j := _the_junction(net)
	if j == null:
		_fail += 1
		print("    !! the fixture produced no junction, so [A] measured nothing")
		(fx["terrain"] as Node).queue_free()
		return

	# Two two-lane roads crossing: each road has two ARMS at the junction and one lane of each arm runs
	# INTO it, so four incoming lanes and four bars. Stated from the fixture, not read off the code.
	var incoming := j.stop_lines.size()
	var bars := Pasture3DRoadJunctionMarkings.plan_junction(j)
	print("    %d stop line(s) published -> %d STOP_BAR primitive(s) (want equal, and 4)"
			% [incoming, bars.size()])
	_check("A", bars.size() == incoming,
			"one bar per stop line, got %d for %d" % [bars.size(), incoming])
	_check("A", incoming == 4, "a 2x2-lane crossroads has 4 incoming lanes, got %d" % incoming)
	for b: Dictionary in bars:
		_check("A", int(b["kind"]) == Pasture3DRoadJunctionMarkings.Kind.STOP_BAR,
				"every primitive so far is a stop bar")

	# CONTROL: the bars must belong to BOTH roads. Four bars all on one road would satisfy the count
	# above and would mean the kernel is painting one road's two arms twice.
	var by_road := {}
	for b: Dictionary in bars:
		var k := String(b["road_key"])
		by_road[k] = int(by_road.get(k, 0)) + 1
	print("    control: bars per road %s (want both roads present)" % [by_road])
	if by_road.size() < 2:
		_fail += 1
		print("    !! every bar is on one road, so [A] is not counting arms")

	_ran["A"] = true
	(fx["terrain"] as Node).queue_free()


# ---- B ------------------------------------------------------------------------------------------

## [B] A bar's midpoint is its stop line's point, and its edge runs across the heading.
##
## The spec's control is `radius_override`: widening the footprint pushes the trim-back out and every bar
## must move with it. That is what makes this a claim about the BOUNDARY rather than about a formula — a
## bar computed from the road's centre agrees at the default radius and then stays put when the junction
## grows around it.
func _b_a_bar_sits_on_its_stop_line() -> void:
	print("[B] a bar's midpoint is its stop line's point, and it moves when the trim-back moves")
	var fx := await _fixture()
	var net: Pasture3DRoadNetwork = fx["net"]
	var j := _the_junction(net)
	if j == null:
		_fail += 1
		print("    !! no junction, so [B] measured nothing")
		(fx["terrain"] as Node).queue_free()
		return

	var bars := Pasture3DRoadJunctionMarkings.plan_junction(j)
	var worst_mid := 0.0
	var worst_dot := 0.0
	for i in bars.size():
		var b: Dictionary = bars[i]
		var sl: Pasture3DRoadStopLine = j.stop_lines[i]
		var q: PackedVector2Array = b["quad"]
		# Corners 0 and 1 are the LEADING edge — the painted line itself. Its midpoint is the hold point.
		var mid: Vector2 = (q[0] + q[1]) * 0.5
		var want := Vector2(sl.point.x, sl.point.z)
		worst_mid = maxf(worst_mid, mid.distance_to(want))
		# And that edge runs ACROSS the road, so it is perpendicular to the direction of travel.
		var along := (q[1] - q[0]).normalized()
		worst_dot = maxf(worst_dot, absf(along.dot(sl.heading.normalized())))
		# The bar reaches BACK along the approach, never forward into the junction: a driver whose nose
		# is on the hold point has the whole bar behind them, where they can no longer see it, and the
		# half that mattered was the half they read on the way in.
		var back := ((q[3] + q[2]) * 0.5) - mid
		_check("B", back.dot(sl.heading) < 0.0,
				"the bar must sit behind the hold point, not across it")
		_check("B", absf(back.length() - Pasture3DRoadJunctionMarkings.STOP_BAR_LENGTH) < 1e-4,
				"the bar must be %.3f m long, got %.4f m"
						% [Pasture3DRoadJunctionMarkings.STOP_BAR_LENGTH, back.length()])
		_check("B", absf(q[0].distance_to(q[1]) - sl.width) < 1e-4,
				"the bar must span its lane's %.3f m, got %.4f m" % [sl.width, q[0].distance_to(q[1])])
	print("    worst midpoint error %.6f m, worst |edge . heading| %.6f (want 0 and 0)"
			% [worst_mid, worst_dot])
	_check("B", worst_mid < 1e-4, "a bar's midpoint is not its stop line's point (%.6f m)" % worst_mid)
	_check("B", worst_dot < 1e-4, "a bar is not perpendicular to its heading (%.6f)" % worst_dot)

	# CONTROL: widen the footprint. The trim-back moves out, the stop lines move, and the bars with them.
	# A bar that stayed put is reading the road, not the boundary.
	var before: Array = []
	for b: Dictionary in bars:
		before.append((b["quad"] as PackedVector2Array)[0])
	j.radius_override = j.radius + 12.0
	net.resolve_junctions()
	await get_tree().process_frame
	var after := Pasture3DRoadJunctionMarkings.plan_junction(_the_junction(net))
	var moved := 0.0
	for i in mini(after.size(), before.size()):
		var q: PackedVector2Array = after[i]["quad"]
		moved = maxf(moved, (before[i] as Vector2).distance_to(q[0]))
	print("    control: footprint widened by 12 m -> a bar moved %.3f m (want > 1)" % moved)
	if moved <= 1.0:
		_fail += 1
		print("    !! the bars did not follow the trim-back, so [B] would pass on a bar drawn from the road")

	_ran["B"] = true
	(fx["terrain"] as Node).queue_free()


# ---- H ------------------------------------------------------------------------------------------

## [H] A crossing spans the arm's CARRIAGEWAY, and sits outside the stop bar.
##
## The spec's control is the one that matters and it is not obvious: widen `shoulder_width` ALONE and
## the crossing must NOT change width. A shoulder is not a lane and is not walked to, so a crossing that
## grew with it is measuring `half_width()` -- the sealed formation -- instead of the lanes. The two
## agree on every road with no shoulder, which is most fixtures, so without this control the criterion
## would pass on the wrong measurement.
##
## "Outside the stop bar" is asserted as an ORDER along the approach rather than as a distance: every
## crossing bar is further from the junction than that arm's stop bar, and clear of it. A crossing
## overlapping the bar reads as its first stripe.
func _h_a_crossing_spans_the_carriageway() -> void:
	print("[H] a crossing spans the carriageway, not the formation, and sits outside the stop bar")
	var fx := await _fixture()
	var net: Pasture3DRoadNetwork = fx["net"]
	var j := _the_junction(net)
	if j == null:
		_fail += 1
		print("    !! no junction, so [H] measured nothing")
		(fx["terrain"] as Node).queue_free()
		return

	var prims := _plan(net, j)
	var walks := _of_kind(prims, Pasture3DRoadJunctionMarkings.Kind.CROSSWALK)
	_check("H", not walks.is_empty(), "a crossroads must emit a crossing")
	if walks.is_empty():
		(fx["terrain"] as Node).queue_free()
		return

	# One crossing per arm: four arms, so four groups of bars, on both roads.
	var by_arm := {}
	for w: Dictionary in walks:
		var k := "%s" % String(w["road_key"])
		by_arm[k] = int(by_arm.get(k, 0)) + 1
	print("    %d crossing bar(s) over %d road(s): %s" % [walks.size(), by_arm.size(), by_arm])
	_check("H", by_arm.size() == 2, "both roads must get a crossing, got %d" % by_arm.size())

	# The carriageway: 2 lanes at 3.5 m is 7.0 m. The bars are centred in it at a 1.0 m pitch, so no bar
	# may lie outside it, and the outermost pair must be within one pitch of its edges.
	var t: Pasture3DRoadType = (net.road_types[0] as Pasture3DRoadType)
	var carriageway := float(t.lane_count) * t.lane_width
	var widest := _widest_span(walks, j)
	print("    carriageway %.3f m -> crossing spans %.3f m (must not exceed it)"
			% [carriageway, widest])
	_check("H", widest <= carriageway + 1e-3,
			"the crossing spans %.3f m of a %.3f m carriageway" % [widest, carriageway])
	_check("H", widest > carriageway - Pasture3DRoadJunctionMarkings.CROSSWALK_BAR_PITCH,
			"the crossing only spans %.3f m of a %.3f m carriageway" % [widest, carriageway])

	# Outside the stop bar, and clear of it.
	var bars := _of_kind(prims, Pasture3DRoadJunctionMarkings.Kind.STOP_BAR)
	var nearest := INF
	for w: Dictionary in walks:
		for c in (w["quad"] as PackedVector2Array):
			nearest = minf(nearest, j.center.distance_to(c))
	var furthest_bar := 0.0
	for b: Dictionary in bars:
		for c in (b["quad"] as PackedVector2Array):
			furthest_bar = maxf(furthest_bar, j.center.distance_to(c))
	print("    stop bars reach %.3f m from the centre; the crossing starts at %.3f m"
			% [furthest_bar, nearest])
	_check("H", nearest > furthest_bar,
			"the crossing must sit outside the stop bar (%.3f vs %.3f m)" % [nearest, furthest_bar])

	# CONTROL: widen the SHOULDER only. The formation grows; the carriageway does not; the crossing must
	# not move at all.
	t.shoulder_width += 2.0
	for b in net.road_brushes():
		(b as Pasture3DRoadBrush)._paint_into(fx["layer"], 0)
	await get_tree().process_frame
	await get_tree().process_frame
	var j2 := _the_junction(net)
	var after := _widest_span(_of_kind(_plan(net, j2), Pasture3DRoadJunctionMarkings.Kind.CROSSWALK), j2)
	print("    control: shoulder +2.0 m -> crossing spans %.3f m (want %.3f, unchanged)"
			% [after, widest])
	if absf(after - widest) > 1e-3:
		_fail += 1
		print("    !! the crossing followed the shoulder, so it is measuring the formation not the lanes")

	_ran["H"] = true
	(fx["terrain"] as Node).queue_free()


# ---- I ------------------------------------------------------------------------------------------

## [I] Give-way triangles go to the arms that LOSE priority, and vanish under signals.
##
## Three claims, and each has a control the spec names. Under `SIGNALS` nobody yields by geometry -- the
## lights say who goes -- so every triangle must disappear; a painted triangle contradicting a green
## light is worse than no marking. And raising the losing road's priority above the other must MOVE the
## triangles to the other road rather than removing them: a junction always has someone giving way, and
## a criterion that only checked "the loser has them" would pass on a kernel that painted them on
## whichever road it walked first.
func _i_give_way_goes_to_the_arm_that_loses() -> void:
	print("[I] give-way triangles go to the arm that loses priority, and vanish under signals")
	var fx := await _fixture(true)
	var net: Pasture3DRoadNetwork = fx["net"]
	var j := _the_junction(net)
	if j == null:
		_fail += 1
		print("    !! no junction, so [I] measured nothing")
		(fx["terrain"] as Node).queue_free()
		return

	var roads := _give_way_roads(_plan(net, j))
	print("    major is %s -> triangles on %s (want the minor road only)" % [j.major_key(), roads])
	_check("I", roads.size() == 1, "exactly one road yields, got %d" % roads.size())
	_check("I", not roads.has(j.major_key()), "the major road must not be told to give way")

	# THE APEX POINTS BACK AT THE APPROACHING DRIVER, which is the half of "give way" that the road/no-road
	# assertions above cannot see: a row on the correct arm, turned round, aims the instruction at the
	# traffic already leaving the junction. Asserted as "the apex is further from the centre than the
	# base", which is the same claim without needing the arm's tangent again.
	#
	# And the row sits OUTSIDE the crossing, the way the crossing sits outside the stop bar — the three
	# are laid out in one order along the approach and a row that had drifted inside would be painted on
	# the crossing.
	var tris := _of_kind(_plan(net, j), Pasture3DRoadJunctionMarkings.Kind.GIVE_WAY)
	_check("I", not tris.is_empty(), "the yielding arm must actually emit triangles")
	var walks := _of_kind(_plan(net, j), Pasture3DRoadJunctionMarkings.Kind.CROSSWALK)
	var walk_far := 0.0
	for w: Dictionary in walks:
		if String(w["road_key"]) != _give_way_roads(_plan(net, j)).keys()[0]:
			continue
		for c in (w["quad"] as PackedVector2Array):
			walk_far = maxf(walk_far, j.center.distance_to(c))
	var worst_apex := INF
	var nearest_tri := INF
	for t3: Dictionary in tris:
		var q: PackedVector2Array = t3["quad"]
		var base_mid: Vector2 = (q[0] + q[1]) * 0.5
		worst_apex = minf(worst_apex, j.center.distance_to(q[2]) - j.center.distance_to(base_mid))
		for c in q:
			nearest_tri = minf(nearest_tri, j.center.distance_to(c))
	print("    apex sits %.4f m further out than its base (want > 0); row starts at %.3f m, the crossing ends at %.3f m"
			% [worst_apex, nearest_tri, walk_far])
	_check("I", worst_apex > 0.0,
			"the apex must point away from the junction, back at the driver (%.4f m)" % worst_apex)
	_check("I", nearest_tri > walk_far,
			"the give-way row must sit outside the crossing (%.3f vs %.3f m)" % [nearest_tri, walk_far])

	# CONTROL 1: signals. Every triangle goes.
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	var under_signals := _give_way_roads(_plan(net, j))
	print("    control: under SIGNALS -> triangles on %s (want none)" % [under_signals])
	_check("I", under_signals.is_empty(), "signals must remove every give-way row")
	j.control = Pasture3DRoadJunction.ControlType.INHERIT

	# CONTROL 2: invert the priorities. The triangles must MOVE, not vanish.
	var was: String = roads.keys()[0]
	for b in net.road_brushes():
		var brush := b as Pasture3DRoadBrush
		var t: Pasture3DRoadType = brush.resolved_road_type()
		# `was` is the road that WAS yielding, so it is the one that must now win.
		t.priority = 5 if brush.road_key() == was else 0
	net.resolve_junctions()
	await get_tree().process_frame
	var j3 := _the_junction(net)
	var moved := _give_way_roads(_plan(net, j3))
	print("    control: priorities inverted -> triangles on %s (want the other road, not none)" % [moved])
	_check("I", moved.size() == 1, "exactly one road must still yield, got %d" % moved.size())
	if moved.has(was) or moved.is_empty():
		_fail += 1
		print("    !! the triangles did not move with priority, so [I] is not reading priority")

	_ran["I"] = true
	(fx["terrain"] as Node).queue_free()


# ---- N ------------------------------------------------------------------------------------------

## [N] A disabled junction paints nothing.
##
## `disabled` means the author has said this crossing is NOT a junction — an overpass, a road passing
## under another. A stop bar there tells a driver to halt on a road with nothing crossing it, which is
## worse than no marking at all. The same rule the lane graph already follows.
func _n_a_disabled_junction_paints_nothing() -> void:
	print("[N] a disabled or undetected junction paints nothing")
	var fx := await _fixture()
	var net: Pasture3DRoadNetwork = fx["net"]
	var j := _the_junction(net)
	if j == null:
		_fail += 1
		print("    !! no junction, so [N] measured nothing")
		(fx["terrain"] as Node).queue_free()
		return

	# CONTROL FIRST: it has to paint something while enabled, or "nothing when disabled" is vacuous.
	var live := Pasture3DRoadJunctionMarkings.plan_junction(j).size()
	print("    control: enabled -> %d primitive(s) (want > 0)" % live)
	if live == 0:
		_fail += 1
		print("    !! the junction paints nothing even enabled, so [N] asserts nothing")

	j.disabled = true
	_check("N", Pasture3DRoadJunctionMarkings.plan_junction(j).is_empty(),
			"a disabled junction must paint nothing")
	j.disabled = false
	j.detected = false
	_check("N", Pasture3DRoadJunctionMarkings.plan_junction(j).is_empty(),
			"an undetected junction must paint nothing")
	_ran["N"] = true
	(fx["terrain"] as Node).queue_free()


# ---- O ------------------------------------------------------------------------------------------

## [O] The paint sits on the SURFACE, not at the road's centreline height.
##
## `Pasture3DRoadStopLine.point` carries the road's solved elevation, which is a CROWN above the lane the
## bar is painted across. Build the bar at that height and it floats at its middle and sinks at its ends
## by roughly the crown — 0.05 m by default, ten times MARKING_LIFT, so it is a visible defect and not a
## rounding one. The builder therefore takes a sampler, and the host passes the same one
## `build_footprint` uses for the surface itself.
##
## The CONTROL is the fallback: build the same primitive with NO sampler, and the vertices must come out
## at the flat published height instead. Without that comparison this criterion cannot tell "the sampler
## was used" from "the sampler happened to agree", and would pass on a builder that ignored its argument.
##
## The sampler is a RAMP rather than a constant on purpose: a builder that sampled once and reused the
## answer for every corner would satisfy a constant sampler and fails this one.
func _o_the_paint_sits_on_the_surface() -> void:
	print("[O] build_junction puts the paint on the surface it is given, not at the published height")
	var flat := 10.0
	var slope := 3.0
	var prim := {
		"kind": Pasture3DRoadJunctionMarkings.Kind.STOP_BAR,
		"quad": PackedVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(4, 1), Vector2(0, 1)]),
		"y": flat, "road_key": "R", "lane": 0,
	}
	var lift := Pasture3DRoadJunctionMarkings.MARKING_LIFT

	var ramp := func(at: Vector2) -> float: return slope * at.x
	var arrays := Pasture3DRoadJunctionMarkings.build_junction([prim], ramp, 0.0)
	_check("O", not arrays.is_empty(), "the builder must emit geometry")
	if arrays.is_empty():
		return
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for v in verts:
		worst = maxf(worst, absf(v.y - (slope * v.x + lift)))
	print("    ramped sampler -> worst height error %.6f m (want 0)" % worst)
	_check("O", worst < 1e-5, "a vertex is not on the sampled surface (%.6f m)" % worst)

	var fallback: PackedVector3Array = Pasture3DRoadJunctionMarkings.build_junction([prim],
			Callable(), 0.0)[Mesh.ARRAY_VERTEX]
	var spread := 0.0
	for v in fallback:
		spread = maxf(spread, absf(v.y - (flat + lift)))
	var differ := 0.0
	for i in verts.size():
		differ = maxf(differ, absf(verts[i].y - fallback[i].y))
	print("    control: no sampler -> flat at %.3f m (spread %.6f), differing from the ramp by %.3f m"
			% [flat + lift, spread, differ])
	_check("O", spread < 1e-5, "the fallback must be flat at the published height (%.6f m)" % spread)
	if differ < 1e-3:
		_fail += 1
		print("    !! the sampler and the fallback agree, so [O] cannot tell them apart")
	_ran["O"] = true


## The junction's full plan, arms included — the same call the network makes when it builds the surface.
func _plan(p_net: Pasture3DRoadNetwork, p_j: Pasture3DRoadJunction) -> Array:
	if p_j == null:
		return []
	var by_key := {}
	for b in p_net.road_brushes():
		by_key[(b as Pasture3DRoadBrush).road_key()] = b
	return Pasture3DRoadJunctionMarkings.plan_junction(p_j, p_net._arms_for(p_j, by_key),
			{"default_control": p_net.default_control})


func _of_kind(p_prims: Array, p_kind: int) -> Array:
	var out: Array = []
	for prim: Dictionary in p_prims:
		if int(prim["kind"]) == p_kind:
			out.append(prim)
	return out


## The set of roads carrying a give-way row.
func _give_way_roads(p_prims: Array) -> Dictionary:
	var out := {}
	for prim: Dictionary in _of_kind(p_prims, Pasture3DRoadJunctionMarkings.Kind.GIVE_WAY):
		out[String(prim["road_key"])] = true
	return out


## The widest ACROSS-road extent of one arm's crossing, plus one bar width — the span the ladder covers.
##
## Measured per arm and maxed, not over all of them at once: two arms of a crossroads are perpendicular,
## so a single bounding box over both would measure the junction rather than a carriageway.
func _widest_span(p_walks: Array, p_j: Pasture3DRoadJunction) -> float:
	var by_arm := {}
	for w: Dictionary in p_walks:
		var q: PackedVector2Array = w["quad"]
		var c: Vector2 = (q[0] + q[1]) * 0.5
		var k := "%s" % String(w["road_key"])
		# Arms of the same road are opposite each other, so split them by which side of the centre they
		# are on as well.
		var side := "+" if (c - p_j.center).dot(Vector2(1, 1)) > 0.0 else "-"
		var key := k + side
		if not by_arm.has(key):
			by_arm[key] = []
		(by_arm[key] as Array).append(c)
	var widest := 0.0
	for k in by_arm:
		var pts: Array = by_arm[k]
		for a: Vector2 in pts:
			for b: Vector2 in pts:
				widest = maxf(widest, a.distance_to(b))
	return widest + Pasture3DRoadJunctionMarkings.CROSSWALK_BAR_WIDTH


# ---- fixture ------------------------------------------------------------------------------------

## Two two-lane roads crossing at right angles, baked, so the junction has a real lane graph and real
## published stop lines. Deliberately the same shape as RoadJunctionGate's fixture: the paint has to be
## measured on the geometry the rest of the junction work is measured on.
func _fixture(p_split_priority: bool = false) -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	var data: Pasture3DData = terrain.data
	data.add_region_blank(Vector2i(0, 0))
	data.ensure_layer_stack()
	var stack := data.get_layer_stack()
	var layer_id: int = stack.add_layer("junction_paint")
	var lay: Pasture3DLayer = stack.get_layer(layer_id)
	lay.set_map_type(0)
	lay.set_base(false)
	lay.set_visible(true)

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	# ONE type shared by both roads unless the caller wants a priority split, in which case they need
	# two: priority lives on the type, so two roads sharing one resource can never disagree about it.
	var types: Array[Pasture3DRoadType] = []
	for i in (2 if p_split_priority else 1):
		var t := Pasture3DRoadType.new()
		t.type_name = "cross%d" % i
		t.lane_count = 2
		t.lane_width = 3.5
		t.priority = (5 - i * 5) if p_split_priority else 0
		types.append(t)
	net.road_types = types

	var n := 0
	for spec in [[Vector3(40.0, 0.0, 128.0), Vector3(200.0, 0.0, 128.0), "EW"],
			[Vector3(128.0, 0.0, 40.0), Vector3(128.0, 0.0, 200.0), "NS"]]:
		var brush := Pasture3DRoadBrush.new()
		brush.name = String(spec[2])
		net.add_child(brush)
		brush.terrain = terrain
		brush.road_road_type = types[n % types.size()]
		n += 1
		var path := Path3D.new()
		var curve := Curve3D.new()
		curve.add_point(spec[0])
		curve.add_point(spec[1])
		path.curve = curve
		brush.add_child(path)
		var road_mod := Pasture3DNodeRoad.new()
		road_mod.alignment_step = 2.0
		brush.modifiers = [road_mod]
		brush._paint_into(layer_id, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	return {"terrain": terrain, "net": net, "layer": layer_id}


func _the_junction(p_net: Pasture3DRoadNetwork) -> Pasture3DRoadJunction:
	for j in p_net.junctions:
		if j.detected:
			return j
	return null


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])
