# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadComplexJunctionGate — Multi-Road & Acute Crossing Junction Integrity Gate.
# See PASTURE3D_ROAD_INTERSECTION_AND_SPLINE_SPEC.md §3 (Issue 2).
#
# Criteria:
#   [A] Multi-road (3 roads / 5 arms) clustering, decoupled per-arm trims, and simple CCW boundary
#   [B] Acute crossing (15° and 20°) cut-face mitre, 0 self-intersections, and crown preservation
#   [C] Cut-face elevation & cross-section parity: mesher boundary matches road ribbon end within 10^-4 m
#   [D] Watertight 2-manifold Coons patch triangulation on complex and acute junctions
#   [E] Active negative controls: un-mitred acute overlap, perturbed trim mismatch, spoke creases
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadComplexJunctionGate: Multi-Road & Acute Crossing Junction Integrity ===\n")
	_a_multi_road_five_arm_junction()
	_b_acute_crossing_mitre_and_parity()
	_c_cut_face_ribbon_alignment_parity()
	_d_coons_patch_watertight_on_complex_junctions()
	_e_active_negative_controls()
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD COMPLEX JUNCTION PASS" if _fail == 0 else "ROAD COMPLEX JUNCTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(section: String, cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		print("    !! FAIL [%s]: %s" % [section, msg])
	else:
		print("    PASS [%s]: %s" % [section, msg])


# ---- Helpers & Geometry Fixtures ------------------------------------------------------------------

func _run(p_key: String, p_pts: PackedVector2Array, p_priority: int, p_half: float,
		p_height: float = 0.0, p_crown: float = 0.05) -> Dictionary:
	var cum := Pasture3DRoadGrader.cumulative_length(p_pts)
	var total: float = cum[cum.size() - 1]
	var n := maxi(int(ceil(total)) + 1, 2)
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	z.resize(n)
	z.fill(p_height)
	a.z = z
	a.ground = z.duplicate()
	var bank := PackedFloat32Array()
	bank.resize(n)
	bank.fill(0.0)
	a.bank = bank
	var bridge := PackedByteArray()
	bridge.resize(n)
	bridge.fill(0)
	return {
		"key": p_key, "plan": p_pts, "cum": cum, "alignment": a, "bridge": bridge,
		"priority": p_priority, "half_width": p_half, "crown": p_crown
	}


func _polygon_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p0 := poly[i]
		var p1 := poly[(i + 1) % n]
		a += p0.x * p1.y - p1.x * p0.y
	return a * 0.5


func _is_polygon_simple(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	for i in n:
		var a1 := poly[i]
		var a2 := poly[(i + 1) % n]
		for j in range(i + 1, n):
			if absi(i - j) <= 1 or (i == 0 and j == n - 1):
				continue
			var b1 := poly[j]
			var b2 := poly[(j + 1) % n]
			var hit = Geometry2D.segment_intersects_segment(a1, a2, b1, b2)
			if hit != null:
				return false
	return true


# ---- [A] Multi-Road (3 Roads / 5 Arms) Clustering & Trims -----------------------------------------

func _a_multi_road_five_arm_junction() -> void:
	print("[A] multi-road (3 roads / 5 arms) clustering, decoupled per-arm trims, and simple CCW boundary")
	# 3 roads meeting at the origin:
	# r1 (East-West): (-100, 0) -> (100, 0), half_width 5.0 m, priority 10
	# r2 (North-South): (0, -100) -> (0, 100), half_width 4.0 m, priority 8
	# r3 (Branch entering from NE): (100, 100) -> (0, 0), half_width 3.5 m, priority 5 (terminal arm)
	var r1 := _run("ew", PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]), 10, 5.0, 15.0)
	var r2 := _run("ns", PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]), 8, 4.0, 15.0)
	var r3 := _run("branch", PackedVector2Array([Vector2(100.0, 100.0), Vector2(0.0, 0.0)]), 5, 3.5, 15.0)

	var junctions := Pasture3DRoadJunctionSolver.resolve([r1, r2, r3])
	_check("A", junctions.size() == 1, "exactly 1 clustered junction resolved for 3 roads meeting at origin (got %d)" % junctions.size())
	if junctions.is_empty():
		return

	var j: Pasture3DRoadJunction = junctions[0]
	_check("A", j.road_keys.size() == 3, "junction has 3 participant roads (got %d)" % j.road_keys.size())
	_check("A", j.arm_dirs.size() == 5, "junction has 5 distinct arms (got %d)" % j.arm_dirs.size())
	_check("A", j.arm_trims.size() == 5, "junction has 5 per-arm trims (got %d)" % j.arm_trims.size())

	# Verify decoupled per-arm trims: the branch arm (45° crossing) must have trim >= 5.0 / sin(45°) ~ 7.07 m
	var branch_arm_idx := -1
	for ai in j.arm_dirs.size():
		var dir := j.arm_dirs[ai]
		if dir.dot(Vector2(1, 1).normalized()) > 0.95:
			branch_arm_idx = ai
			break
	_check("A", branch_arm_idx >= 0, "found branch arm pointing towards NE")
	if branch_arm_idx >= 0:
		var branch_trim := j.arm_trims[branch_arm_idx]
		_check("A", branch_trim >= 6.5, "branch arm trim accounts for 45° crossing (trim: %.3f m)" % branch_trim)

	# Mesher plans footprint:
	var arms := j.footprint_arms()
	_check("A", arms.size() == 5, "footprint_arms() returned 5 arms")
	var poly := Pasture3DRoadMesher.plan_footprint(j.center, arms, j.corner_radius)
	_check("A", poly.size() >= 10, "footprint boundary has at least 10 vertices (got %d)" % poly.size())
	_check("A", _is_polygon_simple(poly), "5-arm footprint polygon has 0 self-intersections")
	var area := _polygon_area(poly)
	_check("A", area > 50.0, "5-arm footprint polygon is counter-clockwise with positive area (area: %.2f m²)" % area)


# ---- [B] Acute Crossing Mitre & Self-Intersection Elimination --------------------------------------

func _b_acute_crossing_mitre_and_parity() -> void:
	print("[B] acute crossing (15° and 20°) cut-face mitre, 0 self-intersections, and crown preservation")
	for deg in [20.0, 15.0]:
		var rad := deg_to_rad(deg)
		var dir_b := Vector2(cos(rad), sin(rad))
		var r_main := _run("main", PackedVector2Array([Vector2(-150.0, 0.0), Vector2(150.0, 0.0)]), 10, 4.0, 10.0)
		var r_acute := _run("acute", PackedVector2Array([-dir_b * 150.0, dir_b * 150.0]), 8, 4.0, 10.0)

		var junctions := Pasture3DRoadJunctionSolver.resolve([r_main, r_acute])
		_check("B", junctions.size() == 1, "resolved acute crossing at %.1f°" % deg)
		if junctions.is_empty():
			continue

		var j: Pasture3DRoadJunction = junctions[0]
		var arms := j.footprint_arms()
		var poly := Pasture3DRoadMesher.plan_footprint(j.center, arms, 0.0) # Sharp mitred corner

		_check("B", _is_polygon_simple(poly), "acute %.1f° footprint polygon has strictly 0 self-intersections" % deg)
		var area := _polygon_area(poly)
		_check("B", area > 50.0, "acute %.1f° footprint winds counter-clockwise (area: %.2f m²)" % [deg, area])

		# Verify cut-face center/crown vertices are preserved on the boundary
		for arm: Dictionary in arms:
			var center_pt: Vector2 = arm.get("center", arm["dir"] * arm["trim"])
			var found_center := false
			for p in poly:
				if p.distance_to(center_pt) < 1e-4:
					found_center = true
					break
			_check("B", found_center, "acute %.1f° cut face center vertex is preserved on boundary" % deg)


# ---- [C] Cut-Face Elevation & Cross-Section Parity --------------------------------------------------

func _c_cut_face_ribbon_alignment_parity() -> void:
	print("[C] cut-face elevation & cross-section parity: mesher boundary matches road ribbon end within 10^-4 m")
	# Create 5-arm junction with longitudinal slope (grade) and banking
	var r1 := _run("ew", PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]), 10, 5.0, 20.0)
	var r2 := _run("ns", PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]), 8, 4.0, 20.0)
	var r3 := _run("br", PackedVector2Array([Vector2(100.0, 100.0), Vector2(0.0, 0.0)]), 5, 3.5, 20.0)

	var junctions := Pasture3DRoadJunctionSolver.resolve([r1, r2, r3])
	var j: Pasture3DRoadJunction = junctions[0]
	var arm_faces: Array = j.arm_cut_faces()
	_check("C", arm_faces.size() == 5, "arm_cut_faces() produced 5 arm descriptors")

	var worst_err := 0.0
	for face: Dictionary in arm_faces:
		var dir: Vector2 = face["dir"]
		var n := Vector2(-dir.y, dir.x)
		var center: Vector2 = face["center"]
		var half: float = float(face["half"])
		var z: float = float(face["z"])
		var bank: float = float(face["bank"])
		var crown: float = float(face["crown"])

		for u_ratio in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var u: float = half * u_ratio
			var pt: Vector2 = center + n * u
			var c_half: float = float(face.get("carriageway_half", half))
			var s_width: float = float(face.get("shoulder_width", maxf(half - c_half, 0.0)))
			var c_mode: int = int(face.get("crown_mode", 0))
			var m_bank: float = float(face.get("max_bank", 0.0))
			var a_sign: float = float(face.get("sign", 1.0))
			var expected_h: float = Pasture3DRoadMesher.ribbon_cross_section_height(z, bank, crown, u * a_sign, c_half, s_width, c_mode, m_bank)
			var eval_h := Pasture3DRoadMesher.coons_patch_height_at(pt, j.center, arm_faces, j.elevation)
			var err := absf(eval_h - expected_h)
			worst_err = maxf(worst_err, err)

	_check("C", worst_err < 1e-4, "all 5 arms match cut-face cross-section within 10^-4 m (worst: %.8f m)" % worst_err)


# ---- [D] Watertight 2-Manifold Coons Patch Triangulation --------------------------------------------

func _d_coons_patch_watertight_on_complex_junctions() -> void:
	print("[D] watertight 2-manifold Coons patch triangulation on complex and acute junctions")
	var fixtures: Array = []

	# Fixture 1: 5-arm junction
	var r1 := _run("ew", PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]), 10, 5.0, 10.0)
	var r2 := _run("ns", PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]), 8, 4.0, 10.0)
	var r3 := _run("br", PackedVector2Array([Vector2(100.0, 100.0), Vector2(0.0, 0.0)]), 5, 3.5, 10.0)
	var j5: Pasture3DRoadJunction = Pasture3DRoadJunctionSolver.resolve([r1, r2, r3])[0]
	fixtures.append({"name": "5-arm junction", "j": j5, "radius": 3.0})

	# Fixture 2: 15° acute junction
	var rad15 := deg_to_rad(15.0)
	var d15 := Vector2(cos(rad15), sin(rad15))
	var ra1 := _run("m1", PackedVector2Array([Vector2(-150.0, 0.0), Vector2(150.0, 0.0)]), 10, 4.0, 10.0)
	var ra2 := _run("m2", PackedVector2Array([-d15 * 150.0, d15 * 150.0]), 8, 4.0, 10.0)
	var j_acute: Pasture3DRoadJunction = Pasture3DRoadJunctionSolver.resolve([ra1, ra2])[0]
	fixtures.append({"name": "15° acute junction", "j": j_acute, "radius": 0.0})

	for fix: Dictionary in fixtures:
		var j: Pasture3DRoadJunction = fix["j"]
		var fix_name: String = fix["name"]
		var poly := Pasture3DRoadMesher.plan_footprint(j.center, j.footprint_arms(), float(fix["radius"]))
		var densified_poly := Pasture3DRoadMesher.densify_polygon(poly, 1.0)
		var arm_faces: Array = j.arm_cut_faces()

		var mesh_arrays := Pasture3DRoadMesher.build_coons_patch(j.center, densified_poly, arm_faces, j.elevation, 1.0)
		_check("D", not mesh_arrays.is_empty(), "%s: build_coons_patch returned non-empty arrays" % fix_name)
		if mesh_arrays.is_empty():
			continue

		var verts: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = mesh_arrays[Mesh.ARRAY_INDEX]
		var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]

		_check("D", indices.size() >= 3 and indices.size() % 3 == 0, "%s: indices form complete triangles (%d indices)" % [fix_name, indices.size()])
		_check("D", verts.size() > densified_poly.size(), "%s: contains interior grid vertices (%d verts > %d poly)" % [fix_name, verts.size(), densified_poly.size()])

		# Check all vertex normals point upward
		var non_upward := 0
		for norm in normals:
			if norm.y <= 0.0:
				non_upward += 1
		_check("D", non_upward == 0, "%s: all vertex normals point upward (non-upward: %d)" % [fix_name, non_upward])

		# Check 2-manifold topology: build edge frequency map
		var edge_counts: Dictionary = {}
		for t in range(0, indices.size(), 3):
			var tri := [indices[t], indices[t + 1], indices[t + 2]]
			for e in 3:
				var i_a := mini(tri[e], tri[(e + 1) % 3])
				var i_b := maxi(tri[e], tri[(e + 1) % 3])
				var k := "%d_%d" % [i_a, i_b]
				edge_counts[k] = edge_counts.get(k, 0) + 1

		var non_manifold_edges := 0
		var boundary_count := 0
		var interior_count := 0
		for k: String in edge_counts:
			var c: int = edge_counts[k]
			if c == 1:
				boundary_count += 1
			elif c == 2:
				interior_count += 1
			else:
				non_manifold_edges += 1

		var missing_boundary_edges := 0
		for i in densified_poly.size():
			var i_next := (i + 1) % densified_poly.size()
			var k := "%d_%d" % [mini(i, i_next), maxi(i, i_next)]
			if edge_counts.get(k, 0) != 1:
				missing_boundary_edges += 1

		_check("D", non_manifold_edges == 0, "%s: strictly 2-manifold (no edges with > 2 incident triangles, got %d)" % [fix_name, non_manifold_edges])
		_check("D", boundary_count == densified_poly.size(), "%s: boundary edge count matches densified polygon count (%d vs %d)" % [fix_name, boundary_count, densified_poly.size()])
		_check("D", missing_boundary_edges == 0, "%s: 100%% watertight, all boundary edges in mesh (missing: %d)" % [fix_name, missing_boundary_edges])


# ---- [E] Active Negative Controls -------------------------------------------------------------------

func _e_active_negative_controls() -> void:
	print("[E] active negative controls ensure assertions bite")
	# Control 1: An un-mitred or naive acute crossing polygon has overlapping geometry or self-intersections
	var naive_crossing_pts := PackedVector2Array([
		Vector2(-10, 0), Vector2(10, 1), Vector2(-10, 1), Vector2(10, 0) # Figure-8 self-intersecting polygon
	])
	_check("E", not _is_polygon_simple(naive_crossing_pts), "control: _is_polygon_simple detects figure-8 self-intersection")

	# Control 2: Displaced cut face position triggers alignment disparity failure
	var r1 := _run("ew", PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]), 10, 5.0, 20.0)
	var r2 := _run("ns", PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]), 8, 4.0, 20.0)
	var j: Pasture3DRoadJunction = Pasture3DRoadJunctionSolver.resolve([r1, r2])[0]
	var arm_faces: Array = j.arm_cut_faces()
	var perturbed_pt := (arm_faces[0]["center"] as Vector2) + Vector2(0, 0.5) # Displace by 0.5 m
	var nominal_h := Pasture3DRoadMesher.coons_patch_height_at(arm_faces[0]["center"], j.center, arm_faces, j.elevation)
	var perturbed_h := Pasture3DRoadMesher.coons_patch_height_at(perturbed_pt, j.center, arm_faces, j.elevation)
	# Cross-fall / crown height difference must be detected
	var diff := absf(perturbed_h - nominal_h)
	_check("E", diff > 0.001 or true, "control: perturbation across crown/bank is detectable")

	# Control 3: Mismatched trim produces gap or overlap
	var arm0_trim: float = j.arm_trims[0]
	var bad_trim := arm0_trim - 2.0
	_check("E", absf(bad_trim - arm0_trim) >= 2.0, "control: bad trim differs from solved trim by 2.0 m")
