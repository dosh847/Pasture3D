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

## What a primitive is.
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
enum Kind { STOP_BAR, CROSSWALK, GIVE_WAY, CONNECTOR_GUIDE, CONNECTOR_RIBBON }

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

## The guide dash, metres wide. `Pasture3DRoadMarkings.STRIPE_WIDTH` reused rather than redeclared: a
## guide is the same painted line as a lane line and reads as one only if it is the same width.
const GUIDE_WIDTH: float = Pasture3DRoadMarkings.STRIPE_WIDTH

## How finely a connector curve is sampled, metres. Short enough that a dash across a tight turn does
## not visibly chord, long enough that a junction does not cost hundreds of quads per movement.
const CURVE_STEP: float = 0.5

## How far a connector RIBBON floats above the junction surface. Between the surface and the markings,
## deliberately and by construction: the ribbon covers the surface and the guides are painted on the
## ribbon, so their lifts have to be ordered the way the three are stacked. Deriving it from
## MARKING_LIFT rather than writing a second constant is what keeps that ordering true if either moves.
const RIBBON_LIFT: float = MARKING_LIFT * 0.5

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
	out.append_array(_plan_connectors(p_junction, p_arms, p_opts))
	return out


## The connector overlay: a ribbon along each legal movement, and a dashed guide along the ones that
## have to cross traffic to make it.
##
## ---- WHY NOT A GUIDE ON EVERY CONNECTOR ----
##
## A four-arm crossroads of two-lane roads has a dozen legal movements. Painting a guide along each one
## fills the junction with white and none of them can be followed, which is the opposite of what a guide
## is for. The set has to be small enough to read, and the fact that makes it small is already
## published: a movement that must YIELD is one whose path a driver has to trace across traffic, and
## `yields_to()` says which those are. A straight-ahead movement with priority needs no line -- the
## driver is going where the road already points.
##
## ---- A FORBIDDEN MOVEMENT PAINTS NOTHING ----
##
## Neither ribbon nor guide. `allowed_override = OFF` is the author saying "no left turn here", and a
## painted path is an invitation to make exactly the turn they forbade -- worse than an unmarked
## junction, because it contradicts the sign that presumably stands beside it.
static func _plan_connectors(p_junction: Pasture3DRoadJunction, p_arms: Array,
		p_opts: Dictionary) -> Array:
	var out: Array = []
	if not bool(p_opts.get("connector_overlay", true)):
		return out
	# A ribbon is ONE LANE WIDE, and which lane is a fact the arms already carry. Taken from there
	# rather than from an option, because a junction of a motorway and a lane would otherwise draw both
	# movements at the same width and the narrow road's ribbon would spill over its own carriageway.
	var widths := _lane_widths(p_arms)
	for c in p_junction.connectors:
		if c == null or not c.allowed():
			continue
		var lane_width: float = float(widths.get("%s:%d" % [c.from_key, c.from_lane],
				p_opts.get("connector_width", 3.5)))
		var pts := _sample_curve(c.curve)
		if pts.size() < 2:
			continue
		var cum := _cumulative(pts)
		var total: float = cum[cum.size() - 1]
		if total <= 0.0:
			continue
		# The CONNECTOR ID, not just the road and lane. One lane feeds several movements, so a consumer
		# — the gate included — cannot tell a left turn's paint from the straight-ahead's without it.
		out.append_array(_strip(pts, cum, 0.0, total, lane_width * 0.5,
				Kind.CONNECTOR_RIBBON, c.from_key, c.from_lane, c.id))
		# A guide only where the movement is a TURN and has to give way to something. Both conditions come
		# from published data -- `turn` is geometry the solver bucketed, `yields_to` is the conflict list --
		# so neither is re-derived here.
		if c.turn != Pasture3DRoadLaneConnector.Turn.LEFT \
				and c.turn != Pasture3DRoadLaneConnector.Turn.RIGHT:
			continue
		if p_junction.yields_to(c.id).is_empty():
			continue
		for run: Array in Pasture3DRoadMarkings.runs(Pasture3DRoadMarkings.Style.DASHED, 0.0, total):
			out.append_array(_strip(pts, cum, float(run[0]), float(run[1]), GUIDE_WIDTH * 0.5,
					Kind.CONNECTOR_GUIDE, c.from_key, c.from_lane, c.id))
	return out


## Every arm's lane widths, keyed `road:lane` — the index a connector's `from_lane` is.
static func _lane_widths(p_arms: Array) -> Dictionary:
	var out := {}
	for arm: Dictionary in p_arms:
		var key := String(arm.get("key", ""))
		for lane: Dictionary in arm.get("lanes", []):
			out["%s:%d" % [key, int(lane["index"])]] = float(lane["width"])
	return out


## A connector curve as a world-XZ polyline with its own heights kept.
##
## `tessellate_even_length` rather than `tessellate`: the adaptive one puts its samples where the
## CURVATURE is, which is exactly where a dashed guide needs even spacing to keep its dashes the same
## length. A dash measured along an unevenly sampled polyline is longer through the straight part of a
## turn than through its apex.
static func _sample_curve(p_curve: Curve3D) -> PackedVector3Array:
	if p_curve == null or p_curve.point_count < 2:
		return PackedVector3Array()
	return p_curve.tessellate_even_length(5, CURVE_STEP)


## Cumulative length along a polyline, measured in PLAN.
##
## In plan and not in 3D, because everything else about a junction's paint is: the dash pitch, the
## setbacks and the trim-backs are all plan distances, and a guide whose dashes shortened on a graded
## approach would be the only marking in the system that did.
static func _cumulative(p_pts: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_pts.size())
	out[0] = 0.0
	for i in range(1, p_pts.size()):
		var a := Vector2(p_pts[i - 1].x, p_pts[i - 1].z)
		var b := Vector2(p_pts[i].x, p_pts[i].z)
		out[i] = out[i - 1] + a.distance_to(b)
	return out


## One span of a polyline as a chain of quads, `p_half` either side.
##
## A quad PER SEGMENT rather than one quad for the whole span: a span across a turn is curved, and a
## single quad across it would cut the corner by the sagitta -- several centimetres on a tight
## connector, which on a 0.12 m line is most of its width.
##
## The ends are the span's own, not the nearest sample. A dash that started at whichever sample came
## first would be a different length depending on where the tessellation happened to land, which is the
## same rule `Pasture3DRoadMarkings._emit_run` follows and for the same reason.
static func _strip(p_pts: PackedVector3Array, p_cum: PackedFloat32Array, p_from: float, p_to: float,
		p_half: float, p_kind: Kind, p_key: String, p_lane: int,
		p_connector: StringName = &"") -> Array:
	var out: Array = []
	if p_to - p_from <= 1e-4:
		return out
	var prev := _at(p_pts, p_cum, p_from)
	var s := p_from
	for i in p_pts.size():
		if p_cum[i] <= p_from + 1e-6:
			continue
		var next_s: float = minf(p_cum[i], p_to)
		var next := _at(p_pts, p_cum, next_s)
		var quad := _segment_quad(prev, next, p_half)
		if not quad.is_empty():
			out.append({
				"kind": p_kind,
				"quad": quad,
				"y": (prev.y + next.y) * 0.5,
				"road_key": p_key, "lane": p_lane, "connector": p_connector,
			})
		prev = next
		s = next_s
		if s >= p_to - 1e-6:
			break
	return out


## The point at plan-distance `p_s` along the polyline, interpolated.
static func _at(p_pts: PackedVector3Array, p_cum: PackedFloat32Array, p_s: float) -> Vector3:
	var n := p_pts.size()
	if p_s <= p_cum[0]:
		return p_pts[0]
	if p_s >= p_cum[n - 1]:
		return p_pts[n - 1]
	for i in range(1, n):
		if p_cum[i] >= p_s:
			var span: float = p_cum[i] - p_cum[i - 1]
			var t: float = 0.0 if span <= 0.0 else (p_s - p_cum[i - 1]) / span
			return p_pts[i - 1].lerp(p_pts[i], t)
	return p_pts[n - 1]


## One segment widened into a quad, wound like every other primitive here.
static func _segment_quad(p_a: Vector3, p_b: Vector3, p_half: float) -> PackedVector2Array:
	var a := Vector2(p_a.x, p_a.z)
	var b := Vector2(p_b.x, p_b.z)
	var d := b - a
	if d.length_squared() < 1e-10:
		return PackedVector2Array()
	var n := Vector2(-d.y, d.x).normalized() * p_half
	return PackedVector2Array([a - n, a + n, b + n, b - n])


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
## THE LIFT IS PER KIND, because the three things this kernel emits are STACKED, not side by side: the
## junction surface, a connector ribbon covering part of it, and the paint on top. A single lift would
## put a guide inside the ribbon it is painted on, and coplanar geometry is decided by float precision
## rather than by draw order.
static func build_junction(p_prims: Array, p_height: Callable = Callable(),
		p_lift: float = 0.0) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for prim: Dictionary in p_prims:
		var quad: PackedVector2Array = prim.get("quad", PackedVector2Array())
		if quad.size() < 3:
			continue
		var base := verts.size()
		var lift := p_lift + (RIBBON_LIFT if int(prim.get("kind", Kind.STOP_BAR)) \
				== Kind.CONNECTOR_RIBBON else MARKING_LIFT)
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
