# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadJunctionSolver — finds where roads actually meet, and works out what that costs each of
# them. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6. Static and node-free, like the grader, so every claim
# below is measurable on fixtures whose answer is known by hand.
#
# ---- TRIM-BACK IS A CLOSED FORM, NOT A TUNED CONSTANT ----
#
# Two roads of half-width wA and wB crossing at angle θ overlap in a parallelogram. Road A must stop
# before it enters that overlap, and the distance from the crossing at which A's centreline is exactly
# wB away from B's centreline is:
#
#     trim_A = wB / sin θ
#
# That is not an approximation and it is not a fudge factor: at that distance A's end lands exactly on
# B's edge, so there is no gap to fill and no overlap to resolve. It falls out that an acute crossing
# trims back much further than a square one — 1/sin θ diverges — which is correct (a 20° slip road eats a
# long way into both roads) and is the criterion that tells this apart from a fixed-radius junction.
#
# ---- OVERLAPPING IS NOT INTERSECTING (§6, addition 1) ----
#
# Detection is XZ-planar, so an overpass crosses everything beneath it. Two exclusions, both of which
# have to be applied where the crossing is found rather than afterwards: a stretch marked `is_bridge`
# never participates, and neither does a crossing whose two roads are solved more than `clearance` apart
# vertically. Grade separation then falls out of data the design already carries.
@tool
class_name Pasture3DRoadJunctionSolver
extends RefCounted

## Crossings closer together than this are one junction, metres. A staggered crossroads authored as two
## T-junctions a few metres apart is one intersection to a driver and should be one to the solver.
const DEFAULT_CLUSTER_RADIUS: float = 12.0

## Vertical separation at which two roads are considered to pass rather than to meet, metres. Roughly a
## lorry plus deck; below it, two roads at different heights would still collide.
const DEFAULT_CLEARANCE: float = 5.5

## A stub shorter than this is not an arm: a road whose end lands all but exactly on the junction has
## nothing left to trim, and an arm of a few centimetres would give the footprint a cut face facing a
## direction the road never actually runs in.
const ARM_MIN_LENGTH: float = 0.5

## Angles shallower than this are treated as parallel — 1/sin θ has no useful value there, and two roads
## meeting at 2° are running alongside each other, not crossing.
const MIN_CROSSING_ANGLE: float = 0.12 # radians, about 7°


## Find every crossing between the given runs.
##
## Each run is a Dictionary:
##   key        String                — stable identity of the road (its content key)
##   plan       PackedVector2Array    — world XZ centreline
##   cum        PackedFloat32Array    — cumulative arc length, from Pasture3DRoadGrader
##   alignment  Pasture3DRoadAlignment or null — solved heights, for the clearance test
##   bridge     PackedByteArray       — per ALIGNMENT SAMPLE, 1 where this road is on a structure
##   priority   int                   — higher wins the junction (§5.2)
##   half_width float                 — half the formation, metres
##
## Returns raw crossings: `[{a, b, point, s_a, s_b, angle}, …]`, indices into `p_runs`.
static func find_crossings(p_runs: Array, p_opts: Dictionary = {}) -> Array:
	var clearance: float = float(p_opts.get("clearance", DEFAULT_CLEARANCE))
	var out: Array = []
	for ia in range(p_runs.size()):
		for ib in range(ia + 1, p_runs.size()):
			var ra: Dictionary = p_runs[ia]
			var rb: Dictionary = p_runs[ib]
			var pa: PackedVector2Array = ra["plan"]
			var pb: PackedVector2Array = rb["plan"]
			var ca: PackedFloat32Array = ra["cum"]
			var cb: PackedFloat32Array = rb["cum"]
			for i in range(pa.size() - 1):
				for j in range(pb.size() - 1):
					var hit := _segment_crossing(pa[i], pa[i + 1], pb[j], pb[j + 1])
					if hit.is_empty():
						continue
					var ta: float = hit[0]
					var tb: float = hit[1]
					var s_a: float = ca[i] + (ca[i + 1] - ca[i]) * ta
					var s_b: float = cb[j] + (cb[j + 1] - cb[j]) * tb
					# A bridged stretch is not a junction — it is an overpass. Tested at the crossing,
					# not filtered afterwards, so a road that is bridged HERE and level 200 m away still
					# forms junctions there.
					if _is_bridged(ra, s_a) or _is_bridged(rb, s_b):
						continue
					var za := _height_of(ra, s_a)
					var zb := _height_of(rb, s_b)
					if is_finite(za) and is_finite(zb) and absf(za - zb) > clearance:
						continue
					var da := (pa[i + 1] - pa[i]).normalized()
					var db := (pb[j + 1] - pb[j]).normalized()
					# The acute angle between the two LINES, in [0, π/2]: taking |dot| first folds
					# direction away, so a road crossing at 150° presents the same 30° geometry to the
					# trim-back as one crossing at 30°, which is what the overlap parallelogram sees.
					var cross_ang := acos(clampf(absf(da.dot(db)), 0.0, 1.0))
					if cross_ang < MIN_CROSSING_ANGLE:
						continue
					out.append({
						"a": ia, "b": ib, "point": pa[i].lerp(pa[i + 1], ta),
						"s_a": s_a, "s_b": s_b, "angle": cross_ang,
					})
	return out


## Group crossings that are close enough to be one intersection, and resolve each group into a
## Pasture3DRoadJunction. Existing junctions are matched by id so their overrides carry over.
static func resolve(p_runs: Array, p_existing: Array = [], p_opts: Dictionary = {}) -> Array:
	var cluster_r: float = float(p_opts.get("cluster_radius", DEFAULT_CLUSTER_RADIUS))
	var crossings := find_crossings(p_runs, p_opts)
	var groups := _cluster(crossings, cluster_r)

	# MATCHING IS POSITIONAL, NOT BY ID. An id embeds the centre rounded to a metre, so a junction whose
	# centre drifts across a rounding boundary — which a re-solve can do for free — would fail to match its
	# own prior record: the resolve would emit a NEW junction with the user's overrides missing and keep the
	# old one beside it, marked undetected. Two records where the author drew one crossing.
	#
	# So a prior is matched by WHO MEETS THERE and HOW NEAR, and the matched record keeps its original id.
	# The id stays an identity token, which is all it was ever meant to be; the centre it was minted from is
	# a naming detail and is allowed to move.
	var match_r: float = float(p_opts.get("match_radius", cluster_r))
	var priors: Array = []
	for j in p_existing:
		if j is Pasture3DRoadJunction:
			priors.append(j)
	var taken := {}

	var out: Array = []
	for g: Array in groups:
		var j := _resolve_group(p_runs, crossings, g, p_opts)
		if j == null:
			continue
		var prior := _match_prior(j, priors, taken, match_r)
		if prior != null:
			# RECONCILE, do not rebuild: the resolved fields are replaced wholesale and the user's
			# overrides are the ones already on `prior`, so an unrelated spline edit cannot silently
			# discard a choice made here. `id` is deliberately NOT among them.
			#
			# `major_override` IS remapped, and must be, because it is an INDEX into `road_keys` and this
			# match no longer guarantees the two lists agree. Once a prior can be matched on overlap, a
			# junction that gains or loses an arm arrives here with a different participant order, and an
			# index carried across unchanged would quietly come to mean a different road — "this road has
			# right of way" turning into "that one does", with no edit and nothing to see. Resolved by
			# key, which is what the author actually chose; an override naming a road that has left the
			# junction returns to -1, the value that means "no opinion".
			prior.major_override = _remap_major_override(prior, j.road_keys)
			prior.center = j.center
			prior.road_keys = j.road_keys
			prior.arc_lengths = j.arc_lengths
			prior.trim_backs = j.trim_backs
			prior.radius = j.radius
			prior.arm_dirs = j.arm_dirs
			prior.arm_roads = j.arm_roads
			prior.arm_halfs = j.arm_halfs
			prior.corner_radius = j.corner_radius
			prior.elevation = j.elevation
			prior.major_index = j.major_index
			prior.detected = true
			out.append(prior)
		else:
			out.append(j)

	# A junction that is no longer detected is kept and marked ONLY IF THE AUTHOR CHOSE SOMETHING HERE.
	#
	# The original rule kept every one of them: the roads may be dragged back together in a moment, and
	# throwing away the overrides in between would be a silent loss. That is right about the overrides
	# and wrong about the record. A stale junction with no override has nothing to restore — every field
	# on it is solver output the next detection recomputes identically — so keeping it preserves nothing
	# and costs a saved resource, a red gizmo ring and a block in the scene file, for ever.
	#
	# Nothing pruned them, so they accumulated: `demo_road_network.tscn` reached thirteen undetected
	# records, none carrying a single override, and the only way to clear them was to delete the road
	# network. See `Pasture3DRoadJunction.has_authored_override`.
	for i in priors.size():
		if taken.has(i):
			continue
		var stale: Pasture3DRoadJunction = priors[i]
		if not stale.has_authored_override():
			continue
		stale.detected = false
		out.append(stale)
	return out


## The prior record `p_j` is a re-detection of, or null. Overlapping participants, largest overlap first,
## nearest centre within `p_radius`, and not already claimed by another group this resolve.
##
## ---- WHY OVERLAP AND NOT AN EXACT PARTICIPANT SET ----
##
## Matching on the exact set is correct for a junction that MOVED and wrong for one that GAINED OR LOST
## AN ARM. Draw a T-junction, author "no left turn" on it, then run a fourth road through the same point:
## the detection now has four participants, the prior has three, the sets differ, and the match fails. So
## the resolve emits a brand new record with the override missing and keeps the old one beside it, marked
## undetected — two records where the author drew one crossing, which is the exact failure the positional
## match was introduced to prevent, reached by a different route.
##
## `demo_road_network.tscn` had this on disk: `Road+Road1+Road3@187,55` is the live four-arm junction at
## `@191,55` as it stood before `Road2` was added, orphaned half a metre away.
##
## An arm joining or leaving does not make it a different intersection, so the test is how much the
## participants overlap, not whether they are identical.
##
## MINIMUM OVERLAP IS TWO, and that is load-bearing rather than cautious. One shared road is not evidence
## of identity: a junction of A and B, and a separate junction of A and C further along A, share exactly
## one participant, and with a threshold of one the nearer of them could claim the other's record and
## with it the other's overrides. Two shared roads is the smallest overlap that can only mean the same
## crossing, because two roads cross each other at a given place exactly once.
static func _match_prior(p_j: Pasture3DRoadJunction, p_priors: Array, p_taken: Dictionary,
		p_radius: float) -> Pasture3DRoadJunction:
	var best := -1
	var best_overlap := 0
	var best_d := INF
	for i in p_priors.size():
		if p_taken.has(i):
			continue
		var prior: Pasture3DRoadJunction = p_priors[i]
		var d := prior.center.distance_to(p_j.center)
		if d > p_radius:
			continue
		var overlap := _overlap_count(prior.road_keys, p_j.road_keys)
		if overlap < 2:
			continue
		# THE TIE ORDER IS SPECIFIED, not incidental. More shared participants wins first, because an
		# exact re-detection must always beat a partial one; distance breaks a tie in overlap; and the
		# lower index breaks a tie in both, so two priors that are equally good resolve the same way on
		# every run instead of by array order that a reload is free to change.
		if overlap > best_overlap or (overlap == best_overlap and d < best_d):
			best_overlap = overlap
			best_d = d
			best = i
	if best < 0:
		return null
	p_taken[best] = true
	return p_priors[best]


## `p_prior`'s `major_override` expressed against `p_new_keys`, or -1 when it no longer names a
## participant. Reads the road's KEY out of the old list before looking it up in the new one, because
## the author chose a road, not a slot.
static func _remap_major_override(p_prior: Pasture3DRoadJunction,
		p_new_keys: PackedStringArray) -> int:
	var old := p_prior.major_override
	if old < 0 or old >= p_prior.road_keys.size():
		return -1
	var key: String = p_prior.road_keys[old]
	for i in p_new_keys.size():
		if p_new_keys[i] == key:
			return i
	return -1


## How many road keys two participant lists share.
static func _overlap_count(p_a: PackedStringArray, p_b: PackedStringArray) -> int:
	var seen := {}
	for k in p_a:
		seen[k] = true
	var n := 0
	for k in p_b:
		if seen.has(k):
			n += 1
	return n


## Resolve one cluster of crossings into a junction.
static func _resolve_group(p_runs: Array, p_crossings: Array, p_group: Array,
		p_opts: Dictionary = {}) -> Pasture3DRoadJunction:
	# Participants, and the arc length at which each enters. A road crossing the cluster twice keeps its
	# FIRST arc length here; the second crossing is a separate cluster unless they are within the cluster
	# radius, in which case they genuinely are one intersection.
	var arc := {}
	var center := Vector2.ZERO
	for ci: int in p_group:
		var c: Dictionary = p_crossings[ci]
		center += c["point"]
		if not arc.has(c["a"]):
			arc[c["a"]] = c["s_a"]
		if not arc.has(c["b"]):
			arc[c["b"]] = c["s_b"]
	center /= float(p_group.size())
	var idx: Array = arc.keys()
	idx.sort()
	if idx.size() < 2:
		return null

	var j := Pasture3DRoadJunction.new()
	j.center = center
	var keys := PackedStringArray()
	var arcs := PackedFloat32Array()
	for i: int in idx:
		keys.append(String((p_runs[i] as Dictionary)["key"]))
		arcs.append(float(arc[i]))
	j.road_keys = keys
	j.arc_lengths = arcs
	j.id = Pasture3DRoadJunction.make_id(keys, center)

	# TRIM-BACK. Each participant is pushed back far enough to clear EVERY other participant's edge, so
	# the binding constraint is the widest road at the sharpest angle — which is why this is a max over
	# pairs rather than a single computation.
	var trims := PackedFloat32Array()
	trims.resize(idx.size())
	trims.fill(0.0)
	for gi in range(idx.size()):
		for gj in range(idx.size()):
			if gi == gj:
				continue
			var ang := _angle_between(p_crossings, p_group, idx[gi], idx[gj])
			var other_w: float = float((p_runs[idx[gj]] as Dictionary).get("half_width", 4.0))
			var s: float = sin(maxf(ang, MIN_CROSSING_ANGLE))
			trims[gi] = maxf(trims[gi], other_w / s)
	# PRIORITY DECIDES ELEVATION (§5.2). The junction sits at the major road's own solved height, so the
	# road with right of way keeps the profile it solved and the minor roads bend to meet it. Averaging
	# would put a dip or a hump in the major road, which is the one road that must not have one.
	#
	# Resolved BEFORE the trim-backs are finished, because priority also picks the kerb return below, and
	# the kerb return is what the arms have to be trimmed back to make room for.
	var best := 0
	var best_priority := -2147483648
	for gi in range(idx.size()):
		var pr := int((p_runs[idx[gi]] as Dictionary).get("priority", 0))
		if pr > best_priority:
			best_priority = pr
			best = gi
	j.major_index = best
	var major_run: Dictionary = p_runs[idx[best]]
	var z := _height_of(major_run, arcs[best])
	j.elevation = z if is_finite(z) else 0.0

	# ---- THE ARMS (P9a-0) --------------------------------------------------------------------------
	#
	# An arm is not a participant. A road that CROSSES the junction leaves it in two directions and a road
	# that ENDS here leaves it in one, so a plain crossroads of two roads has FOUR arms. Whether the road
	# continues is read off the arc length against the run's own length rather than assumed, which is what
	# makes a T-junction produce three arms and not four with one facing into nothing.
	var dirs := PackedVector2Array()
	var arm_roads := PackedInt32Array()
	var halfs := PackedFloat32Array()
	for gi in range(idx.size()):
		var run: Dictionary = p_runs[idx[gi]]
		var tang := _tangent_at(run, arcs[gi])
		if tang.length_squared() < 0.5:
			continue
		var hw: float = float(run.get("half_width", 4.0))
		var total := _run_length(run)
		if total - arcs[gi] > ARM_MIN_LENGTH:
			dirs.append(tang)
			arm_roads.append(gi)
			halfs.append(hw)
		if arcs[gi] > ARM_MIN_LENGTH:
			dirs.append(-tang)
			arm_roads.append(gi)
			halfs.append(hw)
	j.arm_dirs = dirs
	j.arm_roads = arm_roads
	j.arm_halfs = halfs

	# ---- THE KERB RETURN COSTS TRIM-BACK -----------------------------------------------------------
	#
	# The corner between two arms is a corner of the GAP between them, not of the pavement, so rounding it
	# ADDS pavement and its tangent points sit `radius / tan(phi/2)` back along each road. A return can
	# therefore only be drawn if the arms were trimmed that much further back to leave room — which is why
	# a corner radius makes an intersection BIGGER rather than rounder in place, and why this is added to
	# the trim-back here rather than handled in the mesher.
	j.corner_radius = _corner_radius_for(p_runs, idx, best_priority, p_opts)
	var allow := _fillet_allowances(dirs, arm_roads, idx.size(), j.effective_corner_radius())
	for gi in range(idx.size()):
		trims[gi] += allow[gi]
	j.trim_backs = trims

	# The footprint has to contain every trimmed end, so it is the largest of them.
	var r := 0.0
	for t in trims:
		r = maxf(r, t)
	j.radius = r
	return j


## The kerb-return radius this junction uses: the `corner_radius` of its highest-priority participants,
## or the world default when they tie and disagree.
##
## THE TIE IS NOT RESOLVED BY `major_index`, deliberately. That falls to whichever road the solver walked
## first, which is scene order — tolerable for an elevation, where tied roads are at the same height and
## the choice is invisible, and not for a corner radius, where it would give the intersection a visibly
## different shape depending on node order and change it silently when an unrelated road is reparented.
## A tie is answered by a value the author set, or not at all.
static func _corner_radius_for(p_runs: Array, p_idx: Array, p_best_priority: int,
		p_opts: Dictionary) -> float:
	var fallback: float = float(p_opts.get("default_corner_radius", 6.0))
	var first := NAN
	for gi in range(p_idx.size()):
		var run: Dictionary = p_runs[p_idx[gi]]
		if int(run.get("priority", 0)) != p_best_priority:
			continue
		var v: float = float(run.get("corner_radius", fallback))
		if is_nan(first):
			first = v
		elif not is_equal_approx(first, v):
			return fallback # tied on priority and disagreeing: the author's default decides
	return fallback if is_nan(first) else first


## How much further back each ROAD must be trimmed for its kerb returns to fit, parallel to the group's
## participants.
##
## Per road rather than per arm because the grader takes ONE trim-back per road and applies it either
## side of the crossing. So a road takes the largest allowance any of its arms needs: trimming one side
## of a crossing further than the other would need a second number the grader has nowhere to put.
static func _fillet_allowances(p_dirs: PackedVector2Array, p_arm_roads: PackedInt32Array,
		p_road_count: int, p_radius: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_road_count)
	out.fill(0.0)
	if p_radius <= 0.0 or p_dirs.size() < 2:
		return out
	var order: Array = []
	for i in p_dirs.size():
		order.append(i)
	order.sort_custom(func(a, b): return p_dirs[a].angle() < p_dirs[b].angle())
	for k in order.size():
		var ia: int = order[k]
		var ib: int = order[(k + 1) % order.size()]
		if ia == ib:
			continue
		var phi := acos(clampf(p_dirs[ia].dot(p_dirs[ib]), -1.0, 1.0))
		var a := Pasture3DRoadMesher.fillet_allowance(p_radius, phi)
		out[p_arm_roads[ia]] = maxf(out[p_arm_roads[ia]], a)
		out[p_arm_roads[ib]] = maxf(out[p_arm_roads[ib]], a)
	return out


## Unit direction of `p_run` at arc length `p_s`, in the direction of increasing arc length.
static func _tangent_at(p_run: Dictionary, p_s: float) -> Vector2:
	var plan: PackedVector2Array = p_run.get("plan", PackedVector2Array())
	var cum: PackedFloat32Array = p_run.get("cum", PackedFloat32Array())
	if plan.size() < 2 or cum.size() < plan.size():
		return Vector2.ZERO
	for i in range(plan.size() - 1):
		if p_s <= cum[i + 1] or i == plan.size() - 2:
			var d := plan[i + 1] - plan[i]
			return d.normalized() if d.length_squared() > 1e-12 else Vector2.ZERO
	return Vector2.ZERO


## Total arc length of a run.
static func _run_length(p_run: Dictionary) -> float:
	var cum: PackedFloat32Array = p_run.get("cum", PackedFloat32Array())
	return cum[cum.size() - 1] if cum.size() > 0 else 0.0


## The crossing angle recorded between two participants, or a right angle when they never crossed each
## other directly (a three-way cluster where A meets B and B meets C, but A never meets C).
static func _angle_between(p_crossings: Array, p_group: Array, p_i: int, p_j: int) -> float:
	for ci: int in p_group:
		var c: Dictionary = p_crossings[ci]
		if (c["a"] == p_i and c["b"] == p_j) or (c["a"] == p_j and c["b"] == p_i):
			return float(c["angle"])
	return PI * 0.5


## Single-linkage clustering: crossings within `p_radius` of any member join that group. Single linkage
## rather than a fixed grid, because a staggered crossroads is a CHAIN of near crossings and a grid would
## split it on a cell boundary.
static func _cluster(p_crossings: Array, p_radius: float) -> Array:
	var n := p_crossings.size()
	var group_of := PackedInt32Array()
	group_of.resize(n)
	group_of.fill(-1)
	var groups: Array = []
	for i in range(n):
		if group_of[i] >= 0:
			continue
		var gi := groups.size()
		groups.append([])
		var queue: Array[int] = [i]
		group_of[i] = gi
		while not queue.is_empty():
			var at: int = queue.pop_back()
			(groups[gi] as Array).append(at)
			var pa: Vector2 = (p_crossings[at] as Dictionary)["point"]
			for k in range(n):
				if group_of[k] < 0 and pa.distance_to((p_crossings[k] as Dictionary)["point"]) <= p_radius:
					group_of[k] = gi
					queue.append(k)
	return groups


## Where two segments cross, as `[t_a, t_b]` in 0..1, or empty. Endpoint-inclusive, so two roads that
## meet exactly at a shared point (a T-junction authored by ending one spline on another) are found.
static func _segment_crossing(p_a0: Vector2, p_a1: Vector2, p_b0: Vector2, p_b1: Vector2) -> Array:
	var r := p_a1 - p_a0
	var s := p_b1 - p_b0
	var denom := r.cross(s)
	if absf(denom) < 1e-12:
		return [] # parallel or degenerate: not a crossing, and 1/sin θ would be meaningless anyway
	var qp := p_b0 - p_a0
	var t := qp.cross(s) / denom
	var u := qp.cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return []
	return [t, u]


static func _is_bridged(p_run: Dictionary, p_s: float) -> bool:
	var bridge: PackedByteArray = p_run.get("bridge", PackedByteArray())
	if bridge.is_empty():
		return false
	var a: Pasture3DRoadAlignment = p_run.get("alignment", null)
	var i := int(round(p_s / (a.ds if a != null and a.ds > 0.0 else 1.0)))
	return bridge[clampi(i, 0, bridge.size() - 1)] != 0


static func _height_of(p_run: Dictionary, p_s: float) -> float:
	var a: Pasture3DRoadAlignment = p_run.get("alignment", null)
	return a.height_at(p_s) if a != null and a.count() > 0 else NAN
