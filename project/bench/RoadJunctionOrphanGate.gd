# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadJunctionOrphanGate — stale junction records are pruned, and a junction that gains or loses an arm
# keeps its identity. See PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md §2.6.
#
# ---- WHAT WENT WRONG, SO THE CRITERIA READ AS SOMETHING RATHER THAN AS RULES ----
#
# `resolve()` kept EVERY undetected prior for ever, on the reasoning that the roads may be dragged back
# together and discarding the overrides in between would be a silent loss. Sound about the overrides;
# wrong about the record. Nothing pruned, so `demo_road_network.tscn` reached thirteen undetected
# records — NONE of which carried a single override — and `junction_gizmo.gd` draws undetected records
# in red by design, so they appeared as intersections that would not go away short of deleting the road
# network.
#
# The second half was `_match_prior` demanding an EXACT participant set. Run a fourth road through an
# authored three-way and the sets differ, the match fails, and the resolve emits a new record while
# orphaning the old one — losing the overrides and creating exactly the stale record above. On disk:
# `Road+Road1+Road3@187,55` is the live four-arm junction at `@191,55` from before `Road2` was added.
#
#   A  a stale record with NO override is deleted
#   B  a stale record WITH an override is kept and marked undetected
#   C  has_authored_override() sees every authored field, one at a time
#   D  a junction that GAINS an arm keeps its record, its id and its overrides
#   E  a junction that LOSES an arm does too
#   F  one shared road is NOT enough to claim a record
#   G  major_override survives a change of participants, and drops when its road leaves
#
# ---- WHY A AND B ARE ONE CRITERION IN TWO HALVES ----
#
# A prune that deleted everything would pass A. A prune that deleted nothing would pass B. Only the pair
# distinguishes "measured nothing" from "measured well", and each is the other's control — which is why
# they use the SAME fixture and differ only in whether an override was authored on it.
#
# ---- WHY C TESTS THE FIELDS SEPARATELY ----
#
# `has_authored_override()` is a five-way OR. A version that tested only `disabled` would pass any
# criterion that authored `disabled`, so each field is authored ALONE, on its own record, and the
# all-defaults record is the control that must come back false. The connector case is the one most
# easily forgotten — it is the only authored field that does not live on the junction itself.
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadJunctionOrphanGate: stale-record pruning and prior matching ===\n")
	_a_an_unoverridden_stale_record_is_deleted()
	_b_an_overridden_stale_record_is_kept()
	_c_every_authored_field_holds_a_record_open()
	_d_a_junction_that_gains_an_arm_keeps_its_identity()
	_e_a_junction_that_loses_an_arm_keeps_its_identity()
	_f_one_shared_road_is_not_a_match()
	_g_major_override_follows_the_road_not_the_slot()
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD JUNCTION ORPHAN PASS" if _fail == 0 else "ROAD JUNCTION ORPHAN FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## A run description for the solver. `p_pts` is the world XZ centreline, flat at z = 0.
func _run(p_key: String, p_pts: PackedVector2Array, p_priority: int = 0,
		p_half: float = 4.0) -> Dictionary:
	var cum := Pasture3DRoadGrader.cumulative_length(p_pts)
	var total: float = cum[cum.size() - 1]
	var n := maxi(int(ceil(total)) + 1, 2)
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	z.resize(n)
	z.fill(0.0)
	a.z = z
	a.ground = z.duplicate()
	var bridge := PackedByteArray()
	bridge.resize(n)
	bridge.fill(0)
	return {"key": p_key, "plan": p_pts, "cum": cum, "alignment": a, "bridge": bridge,
			"priority": p_priority, "half_width": p_half}


## East-west through the origin.
func _ew(p_key: String, p_priority: int = 0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]), p_priority)


## North-south through the origin — a square crossing with `_ew`.
func _ns(p_key: String, p_priority: int = 0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]), p_priority)


## Diagonal through the origin — a third arm on the same crossing.
func _diag(p_key: String, p_priority: int = 0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(-70.0, -70.0), Vector2(70.0, 70.0)]), p_priority)


## North-south far from the origin, so it crosses `_ew` nowhere near the others.
func _ns_far(p_key: String, p_priority: int = 0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(60.0, -100.0), Vector2(60.0, 100.0)]), p_priority)


# ---- A ------------------------------------------------------------------------------------------

func _a_an_unoverridden_stale_record_is_deleted() -> void:
	print("[A] a stale record with no authored override is deleted")
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one junction (got %d), so [A] measured nothing" % first.size())
		return
	print("    resolved a crossroads -> 1 record, id %s" % first[0].id)
	# The roads no longer cross: only one of them is offered this time.
	var second := Pasture3DRoadJunctionSolver.resolve([_ew("ew")], first)
	print("    the roads stop crossing -> %d record(s) kept" % second.size())
	_check("A", second.size() == 0, "an un-overridden stale record must be dropped, kept %d" % second.size())


# ---- B ------------------------------------------------------------------------------------------

func _b_an_overridden_stale_record_is_kept() -> void:
	print("[B] a stale record carrying an override is kept, and marked undetected")
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one junction, so [B] measured nothing")
		return
	var j: Pasture3DRoadJunction = first[0]
	var kept_id := j.id
	# THE ONLY DIFFERENCE FROM [A]. Same fixture, same removal, one authored decision.
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	var second := Pasture3DRoadJunctionSolver.resolve([_ew("ew")], first)
	print("    the roads stop crossing -> %d record(s) kept" % second.size())
	_check("B", second.size() == 1, "an overridden stale record must survive, kept %d" % second.size())
	if second.size() != 1:
		return
	var s: Pasture3DRoadJunction = second[0]
	_check("B", not s.detected, "the survivor must be marked undetected (detected = %s)" % s.detected)
	_check("B", s.id == kept_id, "it must keep its id (%s vs %s)" % [s.id, kept_id])
	_check("B", s.control == Pasture3DRoadJunction.ControlType.SIGNALS,
			"and its override (control = %d)" % s.control)


# ---- C ------------------------------------------------------------------------------------------

func _c_every_authored_field_holds_a_record_open() -> void:
	print("[C] has_authored_override() sees each authored field on its own")
	# CONTROL FIRST: a record straight out of the solver has authored nothing.
	var plain := Pasture3DRoadJunction.new()
	_check("C", not plain.has_authored_override(),
			"an untouched record must report no override (got %s)" % plain.has_authored_override())

	var cases := {
		"control": func(x: Pasture3DRoadJunction) -> void:
			x.control = Pasture3DRoadJunction.ControlType.STOP,
		"major_override": func(x: Pasture3DRoadJunction) -> void: x.major_override = 1,
		"radius_override": func(x: Pasture3DRoadJunction) -> void: x.radius_override = 20.0,
		"disabled": func(x: Pasture3DRoadJunction) -> void: x.disabled = true,
		"connector allowed_override": func(x: Pasture3DRoadJunction) -> void:
			var c := Pasture3DRoadLaneConnector.new()
			c.allowed_override = Pasture3DRoadLaneConnector.Tri.OFF
			x.connectors = [c],
	}
	for name: String in cases:
		var j := Pasture3DRoadJunction.new()
		(cases[name] as Callable).call(j)
		_check("C", j.has_authored_override(), "%s alone must hold the record open" % name)

	# A connector that was NOT overridden must not hold it open, or every junction with a lane graph —
	# which is every detected junction — would be immortal and the prune would do nothing at all.
	var with_graph := Pasture3DRoadJunction.new()
	with_graph.connectors = [Pasture3DRoadLaneConnector.new()]
	_check("C", not with_graph.has_authored_override(),
			"an un-overridden connector must NOT hold the record open (got %s)"
			% with_graph.has_authored_override())


# ---- D ------------------------------------------------------------------------------------------

func _d_a_junction_that_gains_an_arm_keeps_its_identity() -> void:
	print("[D] a junction that gains a third arm keeps its record, id and overrides")
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one junction, so [D] measured nothing")
		return
	var j: Pasture3DRoadJunction = first[0]
	var kept_id := j.id
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	j.radius_override = 25.0
	print("    authored control=SIGNALS radius_override=25.0 on %s" % kept_id)

	var second := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns"), _diag("dg")], first)
	# THE CONTROL FOR THE WHOLE CRITERION. Under exact-set matching this is 2: a fresh three-arm record
	# plus the orphaned two-arm one. Anything but 1 means the orphan is still being created.
	print("    a third road joins -> %d record(s)" % second.size())
	_check("D", second.size() == 1,
			"the junction must stay ONE record, not spawn an orphan beside it (got %d)" % second.size())
	if second.size() != 1:
		for r: Pasture3DRoadJunction in second:
			print("      %s participants=%s detected=%s" % [r.id, r.road_keys, r.detected])
		return
	var s: Pasture3DRoadJunction = second[0]
	_check("D", s.road_keys.size() == 3, "it must now have three arms (got %d)" % s.road_keys.size())
	_check("D", s.detected, "and still be detected")
	_check("D", s.id == kept_id, "it must keep its original id (%s vs %s)" % [s.id, kept_id])
	_check("D", s.control == Pasture3DRoadJunction.ControlType.SIGNALS,
			"and its control override (got %d)" % s.control)
	_check("D", is_equal_approx(s.radius_override, 25.0),
			"and its radius override (got %.3f)" % s.radius_override)


# ---- E ------------------------------------------------------------------------------------------

func _e_a_junction_that_loses_an_arm_keeps_its_identity() -> void:
	print("[E] a junction that loses an arm keeps its record, id and overrides")
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns"), _diag("dg")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one three-arm junction (got %d), so [E] measured nothing"
				% first.size())
		return
	var j: Pasture3DRoadJunction = first[0]
	var kept_id := j.id
	j.control = Pasture3DRoadJunction.ControlType.STOP
	var second := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")], first)
	print("    the diagonal is removed -> %d record(s)" % second.size())
	_check("E", second.size() == 1, "it must stay ONE record (got %d)" % second.size())
	if second.size() != 1:
		return
	var s: Pasture3DRoadJunction = second[0]
	_check("E", s.road_keys.size() == 2, "it must now have two arms (got %d)" % s.road_keys.size())
	_check("E", s.id == kept_id, "it must keep its original id (%s vs %s)" % [s.id, kept_id])
	_check("E", s.control == Pasture3DRoadJunction.ControlType.STOP,
			"and its override (got %d)" % s.control)


# ---- F ------------------------------------------------------------------------------------------

func _f_one_shared_road_is_not_a_match() -> void:
	print("[F] one shared participant is not enough to claim another junction's record")
	# `ew` crosses `ns` at the origin. `ns_far` crosses `ew` 60 m along it — inside no cluster, but the
	# two junctions share exactly one road. With a minimum overlap of one, the second could claim the
	# first's record and inherit an override the author never made there.
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one junction, so [F] measured nothing")
		return
	var j: Pasture3DRoadJunction = first[0]
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	var kept_id := j.id

	# `ns` leaves and `ns_far` arrives: the only shared road is `ew`.
	var second := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns_far("nf")], first, {
		"match_radius": 1000.0,  # deliberately huge, so ONLY the overlap rule can refuse the match
	})
	var matched := false
	var kept := 0
	for r: Pasture3DRoadJunction in second:
		if r.id == kept_id and r.detected:
			matched = true
		if r.id == kept_id:
			kept += 1
	print("    match_radius 1000 m, one road in common -> %d record(s), old id re-detected: %s"
			% [second.size(), matched])
	_check("F", not matched,
			"a junction sharing ONE road must not claim the other's record even at 1000 m")
	# The old record must still be here, as an undetected survivor: it carries an override. If it
	# vanished, [F] would pass for the wrong reason — the prune eating it rather than the match refusing.
	_check("F", kept == 1, "the overridden prior must survive as an undetected record (found %d)" % kept)


# ---- G ------------------------------------------------------------------------------------------

func _g_major_override_follows_the_road_not_the_slot() -> void:
	print("[G] major_override names a road, not a slot, across a change of participants")
	var first := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _ns("ns")])
	if first.size() != 1:
		_fail += 1
		print("    !! fixture did not produce one junction, so [G] measured nothing")
		return
	var j: Pasture3DRoadJunction = first[0]
	# Author "ns has right of way" by index, which is the only way the inspector can express it.
	var want_key := ""
	for i in j.road_keys.size():
		if String(j.road_keys[i]) == "ns":
			j.major_override = i
			want_key = "ns"
	if want_key == "":
		_fail += 1
		print("    !! 'ns' is not a participant, so [G] measured nothing")
		return
	# Captured BEFORE the resolve: `prior` is reconciled in place, so `j` and the record that comes back
	# are the same object and reading the slot afterwards would read the remapped value.
	var authored_slot := j.major_override
	print("    authored major_override -> slot %d, which is '%s'" % [authored_slot, want_key])

	# THE RUN ORDER IS REVERSED ON PURPOSE. `_resolve_group` builds `road_keys` in the order the runs
	# were handed to it, so passing them in the same order again leaves 'ns' in the slot it already
	# occupied and a stale index would still happen to be right — the assertion below would pass on the
	# bug. Reversing moves 'ns' to a different slot, which is the only arrangement that can tell an
	# index that was remapped from one that was merely lucky.
	var second := Pasture3DRoadJunctionSolver.resolve([_ns("ns"), _ew("ew"), _diag("dg")], first)
	if second.size() != 1:
		_fail += 1
		print("    !! expected one record after the third arm joined, got %d" % second.size())
		return
	var s: Pasture3DRoadJunction = second[0]
	if authored_slot < s.road_keys.size() and String(s.road_keys[authored_slot]) == want_key:
		_fail += 1
		print("    !! '%s' still sits in slot %d, so this case cannot tell a remap from luck"
				% [want_key, authored_slot])
	var now_key := String(s.road_keys[s.major_override]) if s.major_override >= 0 \
			and s.major_override < s.road_keys.size() else "<none>"
	print("    a third arm joins -> participants %s, major_override slot %d = '%s'"
			% [s.road_keys, s.major_override, now_key])
	_check("G", now_key == want_key,
			"the override must still name '%s' (names '%s')" % [want_key, now_key])

	# And when the chosen road LEAVES, the override must fall back to -1 rather than point at whoever
	# now occupies that slot — silently handing right of way to a different road.
	var third := Pasture3DRoadJunctionSolver.resolve([_ew("ew"), _diag("dg")], second)
	if third.size() != 1:
		_fail += 1
		print("    !! expected one record after 'ns' left, got %d" % third.size())
		return
	var t: Pasture3DRoadJunction = third[0]
	print("    '%s' leaves -> participants %s, major_override %d" % [want_key, t.road_keys, t.major_override])
	_check("G", t.major_override == -1,
			"an override naming a departed road must reset to -1 (got %d)" % t.major_override)


# ---- reporting ----------------------------------------------------------------------------------

func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])
