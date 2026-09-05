# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Junction markings — tier NEAR (P9a). A PURE KERNEL, like Pasture3DRoadMarkings, and split the same
# way and for the same reason:
#
#   plan_junction() — WHERE is the paint? Answers in WORLD space, as numbers a gate can assert.
#   build_junction() — what triangles? Extrudes the plan onto a surface and nothing more.
#
# ---- WHY THIS IS A SECOND KERNEL AND NOT A GENERALISED `Pasture3DRoadMarkings.plan` ----
#
# See the spec §2.3. `plan()` works because a road has ONE across-axis: every marking on it is a `u`, a
# signed distance from the centreline, and the builder turns `u` into a position by asking the road.
# A junction has three or more across-axes and no cross-section at all, so there is no `u` to answer in.
# Generalising `plan()` would mean giving it a road argument it currently does not need, on every call,
# to serve the one caller that has no single road — which is how a kernel that fits its job stops
# fitting it.
#
# So this one answers in world XZ and pays for it by having to be told the ground. That is the whole
# trade, and it is why the two kernels stay simple in different ways.
@tool
class_name Pasture3DRoadJunctionMarkings
extends RefCounted

## What a primitive is. CONNECTOR_GUIDE is still to come and shares this plan/build split.
##
## ---- ARM_CONTINUATION IS NOT HERE, AND IS NOT COMING ----
##
## The spec (2.3) specified it as the arm's edge lines and divider "extended from the trim-back boundary
## to the footprint edge, so the carriageway does not visually stop short". That gap was the DISC's. A
## disc was sized by the widest arm's trim, so every narrower arm's ribbon -- and its markings with it --
## stopped short of the surface by the difference. P9a-0 replaced the disc with a polygon THROUGH the
## arms' cut faces, so the ribbon now ends exactly on the boundary and there is nothing between them to
## continue. Measured on a crossroads of a 4-lane and a 1-lane road, whose trims differ by 5.25 m: the
## gap is 0.0000 m at the centreline and at the edge line, on all four arms.
##
## An intersection's interior is unmarked on a real road too, apart from the kinds below. Adding lines
## across it would not be completing that feature, it would be inventing a different one.
enum Kind { STOP_BAR, CROSSWALK, GIVE_WAY }

## How far a stop bar reaches ALONG the road, metres. A stop bar is a bar, not a line: it is wider than
## a lane line so that it reads as an instruction rather than as part of the lane structure, which is
## the same reason it is painted that way on a real road.
const STOP_BAR_LENGTH: float = 0.5

## The crossing, in metres. Continental ("zebra") bars: stripes running ALONG the direction of traffic
## and spread ACROSS the carriageway, which is the pattern that stays readable when it is worn and when
## a car is standing on half of it.
##
## `CROSSWALK_SETBACK` is the gap between the stop bar and the crossing -- the space a vehicle held at
## the bar leaves clear for someone crossing. Without it the two markings touch and the bar reads as the
## first stripe of the crossing.
const CROSSWALK_SETBACK: float = 0.6
const CROSSWALK_DEPTH: float = 2.5
const CROSSWALK_BAR_WIDTH: float = 0.5
const CROSSWALK_BAR_PITCH: float = 1.0

## The give-way triangles, in metres. A row across the carriageway of an arm that must yield, apex
## pointing back at the approaching driver.
const GIVE_WAY_BASE: float = 0.5
const GIVE_WAY_HEIGHT: float = 0.7
const GIVE_WAY_PITCH: float = 1.2
## Clear of the crossing, the way the crossing is clear of the stop bar.
const GIVE_WAY_SETBACK: float = 0.6

## How far junction paint floats above the surface it is painted on. The road markings' own constant,
## reused rather than redeclared: a junction's paint and its approach's paint meet at the trim-back
## boundary, and two lifts that drifted apart would make the pair visibly step at exactly the join they
## are supposed to hide.
const MARKING_LIFT: float = Pasture3DRoadMarkings.MARKING_LIFT


## The junction's markings, world space.
##
## One `STOP_BAR` per incoming lane, taken from `p_junction.stop_lines` with no derivation at all —
## `endpoints()` already gives the two ends of the painted bar and `heading` gives which way is into the
## junction. That is the whole reason stop bars come first in the build order: the data was published
## in P4a, and anything this kernel computed for itself would be a second opinion about a number the
## lane solver already knows.
##
## A primitive is `{kind, quad, y, road_key, lane}`. `quad` is four world-XZ corners wound so the bar
## reads front-face-up (see `build_junction`), `y` is the road's own solved elevation there, and the
## road/lane are carried so a consumer can say WHICH bar it is looking at without matching positions.
##
## ---- A DISABLED JUNCTION PAINTS NOTHING ----
##
## Not "paints bars that mean nothing". `disabled` means the author has said this crossing is not a
## junction — an overpass, a road passing under another — and a stop bar there instructs a driver to
## halt on a road with nothing crossing it. The same rule the lane graph already follows.
## `p_arms` is the junction's arms as `Pasture3DRoadNetwork._arms_for` builds them --
## `{key, end, point, y, distance, tangent, lanes}` -- the same input the lane solver takes. Reused
## rather than re-derived: an arm's centreline point and its cross-section are exactly what a crossing
## and a give-way row need, and computing them here would be a second opinion about where the arm is.
##
## Omitting it plans stop bars alone, which is what a caller with no lane data can honestly draw.
static func plan_junction(p_junction: Pasture3DRoadJunction, p_arms: Array = [],
		p_opts: Dictionary = {}) -> Array:
	var out: Array = []
	if p_junction == null or not p_junction.detected or p_junction.disabled:
		return out
	for sl: Pasture3DRoadStopLine in p_junction.stop_lines:
		if sl == null or sl.width <= 0.0:
			continue
		var ends: Array = sl.endpoints()
		var a := Vector2(ends[0].x, ends[0].z)
		var b := Vector2(ends[1].x, ends[1].z)
		# The bar sits BEHIND the hold point, on the approach side, so a vehicle whose nose reaches
		# `point` has the whole bar in front of it. Painting it centred on the hold point would put half
		# the paint inside the junction, which is the half a driver cannot see once they are on it.
		var back := -sl.heading.normalized() * STOP_BAR_LENGTH
		out.append({
			"kind": Kind.STOP_BAR,
			"quad": PackedVector2Array([a, b, b + back, a + back]),
			"y": ends[0].y,
			"road_key": sl.road_key,
			"lane": sl.lane,
		})
	out.append_array(_plan_arm_paint(p_junction, p_arms, p_opts))
	return out


## The per-arm markings: the crossing every arm gets, and the give-way row only a yielding arm gets.
##
## ---- WHY THESE TWO ARE PLANNED TOGETHER ----
##
## They are laid out one after another along the same approach -- stop bar, then crossing, then
## triangles -- and each is positioned relative to the one before it. Planned separately, each would
## have to re-derive where the previous ended, and the first change to a setback would move one of them
## through another. Here the offset simply accumulates.
static func _plan_arm_paint(p_junction: Pasture3DRoadJunction, p_arms: Array,
		p_opts: Dictionary) -> Array:
	var out: Array = []
	if p_arms.is_empty():
		return out
	var default_control: int = int(p_opts.get("default_control",
			Pasture3DRoadJunction.ControlType.PRIORITY))
	var signals: bool = p_junction.effective_control(default_control) \
			== Pasture3DRoadJunction.ControlType.SIGNALS
	var top := -2147483648
	for pr in p_junction.priorities:
		top = maxi(top, pr)

	for arm: Dictionary in p_arms:
		var lanes: Array = arm.get("lanes", [])
		if lanes.size() < 1:
			continue
		var tangent: Vector2 = (arm.get("tangent", Vector2.RIGHT) as Vector2).normalized()
		if tangent.length_squared() < 0.5:
			continue
		# INTO the junction: an arm at `s - trim` is approached with INCREASING arc length, one at
		# `s + trim` with decreasing. Read off `end` rather than from the junction centre, which would be
		# wrong the moment a road curves through the crossing.
		var into := tangent if int(arm.get("end", 0)) \
				== Pasture3DRoadLaneConnector.End.BEFORE else -tangent
		var outward := -into
		var across := Vector2(-into.y, into.x)
		var origin: Vector2 = arm.get("point", Vector2.ZERO)
		var y := float(arm.get("y", 0.0))
		var key := String(arm.get("key", ""))

		# THE CARRIAGEWAY, NOT THE FORMATION. A crossing spans the surface people walk over, which is the
		# sealed lanes -- not the shoulders, which are not a lane and are not walked to. `half_width()`
		# would include them, and a crossing that grew when a shoulder was widened would be measuring the
		# wrong thing (spec gate H).
		var right_edge := float(lanes[0]["right_edge"])
		var left_edge := float(lanes[lanes.size() - 1]["left_edge"])
		var span := absf(left_edge - right_edge)
		if span <= 0.0:
			continue
		var mid_u := (left_edge + right_edge) * 0.5

		# Walking OUTWARD from the boundary: stop bar, gap, crossing, gap, triangles.
		var at := STOP_BAR_LENGTH + CROSSWALK_SETBACK
		out.append_array(_crosswalk(origin, outward, across, mid_u, span, at, y, key))
		at += CROSSWALK_DEPTH + GIVE_WAY_SETBACK

		# GIVE WAY IS FOR ARMS THAT LOSE, AND ONLY WHERE PRIORITY IS WHAT DECIDES. Under signals nobody
		# gives way by geometry -- the lights say who goes, and a painted triangle contradicting a green
		# light is worse than no marking. An arm at the top priority is not yielding to anyone, so it gets
		# none either.
		if signals:
			continue
		if _priority_of(p_junction, key) >= top:
			continue
		out.append_array(_give_way(origin, outward, across, mid_u, span, at, y, key))
	return out


## One continental crossing: bars along the traffic direction, spread across the carriageway.
##
## The bars are CENTRED on the carriageway and the count is whatever fits at the pitch, so a wide road
## gets more bars rather than wider ones. Spacing a fixed count across any width would make a one-lane
## crossing read as a few fat blocks and a four-lane one as pinstripes.
static func _crosswalk(p_origin: Vector2, p_outward: Vector2, p_across: Vector2, p_mid_u: float,
		p_span: float, p_at: float, p_y: float, p_key: String) -> Array:
	var out: Array = []
	var n := int(floor(p_span / CROSSWALK_BAR_PITCH))
	if n < 1:
		return out
	var used := float(n - 1) * CROSSWALK_BAR_PITCH
	var first := p_mid_u - used * 0.5
	for i in n:
		var u := first + float(i) * CROSSWALK_BAR_PITCH
		var c := p_origin + p_across * u + p_outward * p_at
		var a := p_across * (CROSSWALK_BAR_WIDTH * 0.5)
		var b := p_outward * CROSSWALK_DEPTH
		out.append({
			"kind": Kind.CROSSWALK,
			"quad": PackedVector2Array([c - a, c + a, c + a + b, c - a + b]),
			"y": p_y, "road_key": p_key, "lane": i,
		})
	return out


## One row of give-way triangles, apex pointing back at the approaching driver.
##
## Apex OUTWARD, deliberately: the row is an instruction to the traffic facing it, and a triangle read
## point-first is the shape that says "yield". Turned round it would aim the instruction at the traffic
## already leaving the junction.
static func _give_way(p_origin: Vector2, p_outward: Vector2, p_across: Vector2, p_mid_u: float,
		p_span: float, p_at: float, p_y: float, p_key: String) -> Array:
	var out: Array = []
	var n := int(floor(p_span / GIVE_WAY_PITCH))
	if n < 1:
		return out
	var used := float(n - 1) * GIVE_WAY_PITCH
	var first := p_mid_u - used * 0.5
	for i in n:
		var u := first + float(i) * GIVE_WAY_PITCH
		var base := p_origin + p_across * u + p_outward * p_at
		var a := p_across * (GIVE_WAY_BASE * 0.5)
		out.append({
			"kind": Kind.GIVE_WAY,
			# Wound like the stop bar's quad, so the fan in `build_junction` walks the same way round for
			# a triangle as for a rectangle and neither needs a special case.
			"quad": PackedVector2Array([base - a, base + a, base + p_outward * GIVE_WAY_HEIGHT]),
			"y": p_y, "road_key": p_key, "lane": i,
		})
	return out


## The resolved priority of one participant, or the lowest possible when the junction has not recorded
## one -- an unknown priority must not silently read as the top one and suppress a give-way row.
static func _priority_of(p_junction: Pasture3DRoadJunction, p_key: String) -> int:
	for i in p_junction.road_keys.size():
		if String(p_junction.road_keys[i]) == p_key:
			return p_junction.priorities[i] if i < p_junction.priorities.size() else -2147483648
	return -2147483648


## The primitives as triangles.
##
## `p_height` is an optional `Callable(Vector2) -> float` giving the surface height at a world XZ point.
## When it is null — or answers a non-finite height — a corner falls back to the primitive's own `y`,
## the road's solved elevation at the hold point.
##
## THE FALLBACK IS FLAT ACROSS THE BAR, and that is a real limitation rather than an oversight: a
## crowned road drops a couple of centimetres across one lane, so a bar built flat sinks into the crown
## at its middle. It is the honest answer when nothing has offered a surface, and it is why the host
## passes a sampler rather than relying on it.
##
## Winding follows Godot's front face — clockwise seen from the front — so an up-facing quad's
## `(b-a) x (c-a)` points DOWN. `plan_junction` emits its corners in that order already; this only
## fans them.
static func build_junction(p_prims: Array, p_height: Callable = Callable(),
		p_lift: float = 0.0) -> Array:
	var lift := p_lift + MARKING_LIFT
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for prim: Dictionary in p_prims:
		var quad: PackedVector2Array = prim.get("quad", PackedVector2Array())
		if quad.size() < 3:
			continue
		var base := verts.size()
		var y0 := float(prim.get("y", 0.0))
		for i in quad.size():
			var p := quad[i]
			var y := y0
			if p_height.is_valid():
				var h: float = p_height.call(p)
				if is_finite(h):
					y = h
			verts.append(Vector3(p.x, y + lift, p.y))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(i & 1), float((i >> 1) & 1)))
		for i in range(1, quad.size() - 1):
			indices.append_array(PackedInt32Array([base, base + i, base + i + 1]))
	if indices.is_empty():
		return []
	Pasture3DRoadMesher._recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out
