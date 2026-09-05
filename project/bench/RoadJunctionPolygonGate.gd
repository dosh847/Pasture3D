# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadJunctionPolygonGate — the junction footprint polygon (road P9a-0).
# See PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md §2.2.
#
# `Pasture3DRoadMesher.build_apron` lays a DISC over a junction. An arm's cut end is a flat, full-width
# face, a circle meets a chord at two points, and no radius fixes that — grow the disc to catch an arm's
# corners and it grows just as far where no road runs. `plan_footprint` lays the polygon the arms
# actually bound. It is pure planar geometry, so every claim below is decidable from numbers.
#
#   A  every arm's cut-face corners lie ON the boundary — and the disc it replaces misses them
#   B  the boundary is simple and counter-clockwise
#   C  a 3-arm junction with unequal widths works the same way, with no arm-count special case
#   D  a kerb return is tangent to both road edges and lies at its own radius from its own centre
#   E  a radius the trim cannot afford is clamped, never emitted as a reversed arc
#   F  an acute crossing stays simple, which is where a self-intersection would appear if anywhere
#   G  build_footprint fans the boundary with Godot's front face, visible from above
#   M  the kerb radius comes from the highest-priority arm, ties fall to the network default, and neither
#      answer depends on the order the roads appear in
#
# ---- A IS THE CRITERION THE FEATURE EXISTS FOR, AND IT CARRIES ITS OWN CONTROL ----
#
# "The corners lie on the boundary" is trivially true of any boundary that happens to pass near them, so
# A also computes what the DISC would have done with the same numbers. For the 4-arm fixture below the
# corners sit at sqrt(6.413^2 + 4^2) = 7.559 m and the disc has radius 6.413 m, so it misses by 1.146 m.
# A gate that cannot state that number in advance cannot tell the polygon from the disc, and would pass
# on the bug.
#
# ---- WHY D AND E ARE BOTH NEEDED ----
#
# The corner between two arms is REFLEX — a corner of the gap between the roads, not of the pavement —
# so rounding it is a kerb return that ADDS pavement, and its tangent points sit `r / tan(phi/2)` back
# along each road. That distance has to be bought by trimming the arms further back
# (`fillet_allowance`). D checks the arc when it was paid for; E checks the arc when it was not, where
# the only safe answer is a square corner. An implementation that skipped the clamp would pass D and
# emit an arc running back across its own boundary in E.
@tool
extends Node

## The 4-arm fixture's numbers, taken from the real junction in demo_road_network.tscn
## (`Road+Road1+Road2+Road3@191,55`) so the gate measures the shape the project actually resolves.
const HALF := 4.0
const TRIM := 6.413

var _fail: int = 0


func _ready() -> void:
	print("=== RoadJunctionPolygonGate: the junction footprint polygon (P9a-0) ===\n")
	_a_cut_faces_lie_on_the_boundary()
	_b_the_boundary_is_simple_and_ccw()
	_c_three_arms_with_unequal_widths()
	_d_a_kerb_return_is_tangent_and_round()
	_e_an_unaffordable_radius_is_clamped()
	_f_an_acute_crossing_stays_simple()
	_g_the_fan_faces_up()
	_m_the_kerb_radius_follows_priority()
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD JUNCTION POLYGON PASS" if _fail == 0 else "ROAD JUNCTION POLYGON FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

func _arm(p_angle: float, p_trim: float = TRIM, p_half: float = HALF) -> Dictionary:
	return {"dir": Vector2(cos(p_angle), sin(p_angle)), "trim": p_trim, "half": p_half}


## Two roads crossing squarely: FOUR arms, because each road contributes one either side.
func _crossroads(p_trim: float = TRIM) -> Array:
	return [_arm(0.0, p_trim), _arm(PI * 0.5, p_trim), _arm(PI, p_trim), _arm(-PI * 0.5, p_trim)]


# ---- A ------------------------------------------------------------------------------------------

func _a_cut_faces_lie_on_the_boundary() -> void:
	print("[A] every arm's cut-face corners lie on the boundary; the disc misses them")
	var arms := _crossroads()
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, 0.0)
	print("    4 arms, trim %.3f m, half-width %.3f m -> %d boundary vertices" % [TRIM, HALF, poly.size()])
	if poly.size() < 3:
		_fail += 1
		print("    !! no polygon was built, so [A] measured nothing")
		return
	var worst := 0.0
	var checked := 0
	for a: Dictionary in arms:
		var d: Vector2 = a["dir"]
		var n := Vector2(-d.y, d.x)
		for side in [-1.0, 1.0]:
			var corner: Vector2 = d * TRIM + n * (HALF * side)
			var best := INF
			for v in poly:
				best = minf(best, v.distance_to(corner))
			worst = maxf(worst, best)
			checked += 1
	_check("A", checked == 8, "a square crossroads has 8 cut-face corners (found %d)" % checked)
	_check("A", worst <= 1e-4,
			"every corner must be a boundary vertex (worst miss %.6f m)" % worst)

	# CONTROL: what the disc this replaces would have done with the same numbers.
	var corner_dist := sqrt(TRIM * TRIM + HALF * HALF)
	var miss := corner_dist - TRIM
	print("    control: corners sit at %.3f m; a disc of radius %.3f m misses each by %.3f m"
			% [corner_dist, TRIM, miss])
	_check("A", miss > 1e-3,
			"the disc must MISS, or this fixture cannot tell the polygon from it (%.3f m)" % miss)


# ---- B ------------------------------------------------------------------------------------------

func _b_the_boundary_is_simple_and_ccw() -> void:
	print("[B] the boundary is simple and counter-clockwise")
	for r in [0.0, 3.0]:
		var trim: float = TRIM + Pasture3DRoadMesher.fillet_allowance(r, PI * 0.5)
		var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(trim), r)
		var area := _signed_area(poly)
		var crossings := _self_intersections(poly)
		print("    corner_radius %.1f m -> %d vertices, signed area %.3f m2, %d self-intersection(s)"
				% [r, poly.size(), area, crossings])
		_check("B", crossings == 0, "radius %.1f: the boundary must not cross itself" % r)
		_check("B", area > 0.0, "radius %.1f: it must wind counter-clockwise (area %.3f)" % [r, area])


# ---- C ------------------------------------------------------------------------------------------

func _c_three_arms_with_unequal_widths() -> void:
	print("[C] three arms of unequal width need no special case")
	# A T: one road straight through (two arms) and one joining at 70 degrees, wider.
	var arms := [
		_arm(0.0, 6.0, 4.0),
		_arm(PI, 6.0, 4.0),
		_arm(deg_to_rad(70.0), 9.0, 6.0),
	]
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, 0.0)
	print("    3 arms -> %d boundary vertices, %d self-intersection(s)"
			% [poly.size(), _self_intersections(poly)])
	var worst := 0.0
	for a: Dictionary in arms:
		var d: Vector2 = a["dir"]
		var n := Vector2(-d.y, d.x)
		for side in [-1.0, 1.0]:
			var corner: Vector2 = d * float(a["trim"]) + n * (float(a["half"]) * side)
			var best := INF
			for v in poly:
				best = minf(best, v.distance_to(corner))
			worst = maxf(worst, best)
	_check("C", worst <= 1e-4, "all 6 corners must be on the boundary (worst miss %.6f m)" % worst)
	_check("C", _self_intersections(poly) == 0, "and the boundary must stay simple")
	_check("C", _signed_area(poly) > 0.0, "and counter-clockwise")


# ---- D ------------------------------------------------------------------------------------------

func _d_a_kerb_return_is_tangent_and_round() -> void:
	print("[D] a kerb return is tangent to both road edges and round about its own centre")
	var r := 3.0
	var phi := PI * 0.5
	var allow := Pasture3DRoadMesher.fillet_allowance(r, phi)
	# For a square corner the allowance is exactly the radius: r / tan(45 deg) = r.
	print("    fillet_allowance(%.1f m, 90 deg) = %.4f m" % [r, allow])
	_check("D", is_equal_approx(allow, r),
			"a square corner must cost exactly its radius (%.4f vs %.4f)" % [allow, r])

	var trim := TRIM + allow
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(trim), r)
	var plain := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(trim), 0.0)
	print("    trim %.3f m -> %d vertices with a %.1f m return, %d without"
			% [trim, poly.size(), r, plain.size()])
	# CONTROL: the arc has to ADD vertices. Equal counts mean no arc was emitted at all.
	_check("D", poly.size() > plain.size(),
			"the return must add vertices (%d vs %d)" % [poly.size(), plain.size()])

	# The corner between the +X and +Y arms crosses at (HALF, HALF); its kerb centre is r further out
	# on the bisector of the two OUTWARD directions, which for a square corner is (HALF + r, HALF + r).
	var o := Vector2(HALF + r, HALF + r)
	var on_arc := 0
	var worst := 0.0
	for v in poly:
		# Only the vertices in this quadrant's corner region belong to this arc.
		if v.x > HALF - 1e-3 and v.y > HALF - 1e-3 and v.x < trim - 1e-3 and v.y < trim - 1e-3:
			on_arc += 1
			worst = maxf(worst, absf(v.distance_to(o) - r))
	print("    %d vertices in the +X/+Y corner; worst deviation from radius %.1f m: %.6f m"
			% [on_arc, r, worst])
	_check("D", on_arc >= 3, "the arc must be sampled (found %d vertices)" % on_arc)
	_check("D", worst <= 1e-4, "every arc vertex must sit at the radius (worst %.6f m)" % worst)

	# TANGENCY. The arc must start on the +X arm's edge (y = HALF) and end on the +Y arm's (x = HALF).
	var touches_x := false
	var touches_y := false
	for v in poly:
		if absf(v.y - HALF) <= 1e-4 and absf(v.x - (HALF + r)) <= 1e-4:
			touches_x = true
		if absf(v.x - HALF) <= 1e-4 and absf(v.y - (HALF + r)) <= 1e-4:
			touches_y = true
	_check("D", touches_x, "the return must meet the +X arm's edge at (%.3f, %.3f)" % [HALF + r, HALF])
	_check("D", touches_y, "and the +Y arm's edge at (%.3f, %.3f)" % [HALF, HALF + r])


# ---- E ------------------------------------------------------------------------------------------

func _e_an_unaffordable_radius_is_clamped() -> void:
	print("[E] a radius the trim cannot afford is clamped, not emitted as a reversed arc")
	# The trim is EXACTLY the edge crossing, so there is no room at all: at a square crossroads of
	# half-width w, trimming to w puts every corner on the vertex and buys nothing.
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(HALF), 5.0)
	var plain := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(HALF), 0.0)
	print("    trim == half-width, 5.0 m requested -> %d vertices (%d with no radius), %d self-intersection(s)"
			% [poly.size(), plain.size(), _self_intersections(poly)])
	_check("E", _self_intersections(poly) == 0, "the boundary must stay simple")
	_check("E", _signed_area(poly) > 0.0, "and stay counter-clockwise (area %.3f)" % _signed_area(poly))
	_check("E", poly.size() == plain.size(),
			"an unaffordable radius must fall back to the square corner (%d vs %d)"
			% [poly.size(), plain.size()])

	# A partial allowance must give a partial arc — not all-or-nothing.
	var part := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(HALF + 1.0), 5.0)
	print("    1.0 m of allowance, 5.0 m requested -> %d vertices, %d self-intersection(s)"
			% [part.size(), _self_intersections(part)])
	_check("E", part.size() > plain.size(), "a partial allowance must still round the corner")
	_check("E", _self_intersections(part) == 0, "and stay simple")


# ---- F ------------------------------------------------------------------------------------------

func _f_an_acute_crossing_stays_simple() -> void:
	print("[F] an acute crossing stays simple")
	# 20 degrees. The trim-back is other_w / sin(theta), which diverges as the crossing sharpens, so the
	# arms here are trimmed a very long way back — the arrangement most likely to fold the boundary.
	var theta := deg_to_rad(20.0)
	var trim: float = HALF / sin(theta)
	var arms := [_arm(0.0, trim), _arm(theta, trim), _arm(PI, trim), _arm(PI + theta, trim)]
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, 0.0)
	var crossings := _self_intersections(poly)
	print("    20 deg crossing, trim %.3f m -> %d vertices, %d self-intersection(s), area %.3f m2"
			% [trim, poly.size(), crossings, _signed_area(poly)])
	_check("F", crossings == 0, "the boundary must not fold (%d crossing(s))" % crossings)
	_check("F", _signed_area(poly) > 0.0, "and must stay counter-clockwise")


# ---- G ------------------------------------------------------------------------------------------

func _g_the_fan_faces_up() -> void:
	print("[G] build_footprint fans the boundary, front face up")
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, _crossroads(), 0.0)
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	z.resize(400)
	z.fill(0.0)
	a.z = z
	a.ground = z.duplicate()
	var plan := PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var heights := PackedFloat32Array()
	heights.resize(poly.size())
	heights.fill(0.0)
	var arrays := Pasture3DRoadMesher.build_footprint(Vector2.ZERO, poly, heights, 0.0, 0.0)
	if arrays.is_empty():
		_fail += 1
		print("    !! build_footprint returned nothing, so [G] measured nothing")
		return
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	print("    %d boundary vertices -> %d verts, %d triangles"
			% [poly.size(), verts.size(), idx.size() / 3])
	_check("G", verts.size() == poly.size() + 1, "a fan is the boundary plus its centre")
	_check("G", idx.size() == poly.size() * 3, "one triangle per boundary edge")

	# Every triangle must be front-facing from above. Godot's front face is clockwise seen from the
	# front, so a surface seen from ABOVE has (b-a) x (c-a) pointing DOWN — the trap `build_apron`
	# documents, and the one that makes a road visible only from underneath.
	var wrong := 0
	var t := 0
	while t + 2 < idx.size():
		var p0 := verts[idx[t]]
		var p1 := verts[idx[t + 1]]
		var p2 := verts[idx[t + 2]]
		if (p1 - p0).cross(p2 - p0).y > 1e-9:
			wrong += 1
		t += 3
	_check("G", wrong == 0, "every triangle must face up (%d wound the wrong way)" % wrong)

	var up := 0
	for n in normals:
		if n.y > 0.5:
			up += 1
	_check("G", up == normals.size(), "and every shading normal must point up (%d of %d)"
			% [up, normals.size()])


# ---- geometry helpers ---------------------------------------------------------------------------

## Twice the signed area, positive when the ring winds counter-clockwise.
func _signed_area(p_poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in p_poly.size():
		var p := p_poly[i]
		var q := p_poly[(i + 1) % p_poly.size()]
		a += p.cross(q)
	return a * 0.5


## How many pairs of NON-ADJACENT edges cross. Adjacent edges share an endpoint by construction and are
## skipped; anything else meeting is the boundary folding over itself.
func _self_intersections(p_poly: PackedVector2Array) -> int:
	var n := p_poly.size()
	var hits := 0
	for i in n:
		for j in range(i + 1, n):
			if j == i or (j + 1) % n == i or (i + 1) % n == j:
				continue
			if _segments_cross(p_poly[i], p_poly[(i + 1) % n], p_poly[j], p_poly[(j + 1) % n]):
				hits += 1
	return hits


func _segments_cross(p_a0: Vector2, p_a1: Vector2, p_b0: Vector2, p_b1: Vector2) -> bool:
	var r := p_a1 - p_a0
	var s := p_b1 - p_b0
	var denom := r.cross(s)
	if absf(denom) < 1e-12:
		return false
	var qp := p_b0 - p_a0
	var t := qp.cross(s) / denom
	var u := qp.cross(r) / denom
	# Strictly inside both, so two edges merely touching at a shared vertex do not count.
	return t > 1e-6 and t < 1.0 - 1e-6 and u > 1e-6 and u < 1.0 - 1e-6


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- M ------------------------------------------------------------------------------------------

## [M] The kerb radius is the highest-priority arm's, ties fall to the network default, and NEITHER
## answer moves when the roads are reordered.
##
## The reorder half is the point. `major_index` is decided by walking the participants and keeping the
## first strict winner, which for tied roads is whichever the solver reached first — scene order. That is
## harmless for `elevation`, where tied roads sit at the same height, and not harmless here: a corner
## radius is visible geometry, and resolving a tie by scene order would silently reshape an intersection
## when an unrelated road was reparented. So the tie goes to the author's default instead, and this
## criterion runs each case twice with the runs reversed to prove it.
func _m_the_kerb_radius_follows_priority() -> void:
	print("[M] the kerb radius follows priority, and ties fall to the network default")
	var opts := {"default_corner_radius": 9.0}

	# Priority decides: the 3.0 m road outranks the 12.0 m one, so 3.0 m wins — NOT the larger, and not
	# the default.
	var sharp := [_run("Major", Vector2(-60, 0), Vector2(60, 0), 4, 5.0, 3.0),
			_run("Minor", Vector2(0, -60), Vector2(0, 60), 0, 4.0, 12.0)]
	_radius_is("M", sharp, opts, 3.0, "the higher-priority road's 3.0 m")

	# Tied and disagreeing: neither road's value, the default.
	var tied := [_run("A", Vector2(-60, 0), Vector2(60, 0), 2, 5.0, 3.0),
			_run("B", Vector2(0, -60), Vector2(0, 60), 2, 4.0, 12.0)]
	_radius_is("M", tied, opts, 9.0, "the network default")

	# Tied and AGREEING is not a tie to resolve: the roads have one answer between them and it stands,
	# even though it is not the default. Without this the criterion would pass on an implementation that
	# ignored corner_radius whenever two priorities matched.
	var agree := [_run("A", Vector2(-60, 0), Vector2(60, 0), 2, 5.0, 4.5),
			_run("B", Vector2(0, -60), Vector2(0, 60), 2, 4.0, 4.5)]
	_radius_is("M", agree, opts, 4.5, "the value both roads agree on")


## Resolves `p_runs` both ways round and asserts the junction's corner radius is `p_want` each time.
func _radius_is(p_name: String, p_runs: Array, p_opts: Dictionary, p_want: float,
		p_why: String) -> void:
	var seen := PackedFloat32Array()
	for order in [p_runs, [p_runs[1], p_runs[0]]]:
		var js: Array = Pasture3DRoadJunctionSolver.resolve(order, [], p_opts)
		if js.size() != 1:
			_check(p_name, false, "one crossing expected, got %d" % js.size())
			return
		seen.append((js[0] as Pasture3DRoadJunction).corner_radius)
	print("    %s -> %.3f m and %.3f m reversed (want %.3f m: %s)"
			% [p_why, seen[0], seen[1], p_want, p_why])
	_check(p_name, is_equal_approx(seen[0], p_want),
			"corner radius %.4f m, want %.4f m (%s)" % [seen[0], p_want, p_why])
	_check(p_name, is_equal_approx(seen[0], seen[1]),
			"reordering the roads changed the radius: %.4f m -> %.4f m" % [seen[0], seen[1]])


## A straight run for the solver: the minimum a `build_run` dictionary has to carry.
func _run(p_key: String, p_from: Vector2, p_to: Vector2, p_priority: int, p_half: float,
		p_corner: float) -> Dictionary:
	var plan := PackedVector2Array()
	var cum := PackedFloat32Array()
	var n := int(p_from.distance_to(p_to))
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	for i in n + 1:
		plan.append(p_from.lerp(p_to, float(i) / float(n)))
		cum.append(float(i))
		z.append(0.0)
	a.z = z
	a.ground = z
	return {
		"key": p_key, "plan": plan, "cum": cum, "alignment": a,
		"priority": p_priority, "half_width": p_half, "corner_radius": p_corner,
	}
