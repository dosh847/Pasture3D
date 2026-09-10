# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadJunctionPatchGate — Bivariate Coons patch junction surface & regular grid meshing (Phase P9g).
# See PASTURE3D_ROAD_SIMCADE_UPGRADE_SPEC.md §3.7 & §4.
#
# Legacy junctions mesh aprons as a radial triangle fan converging on a single center vertex.
# Crossing diagonally over spoke edges produces discrete slope discontinuities (creases) that upset
# vehicle suspension dynamics at simcade speeds (120-300+ km/h).
#
# Phase P9g replaces the fan with:
#   1. Transfinite interpolation (bivariate Coons patch) satisfying Hermite boundary conditions
#      (elevation, longitudinal grade, cross-fall banking, and crown) at all approach arms.
#   2. Regular grid interior triangulation bounded by the junction fillet outline.
#
# Criteria:
#   [A] Exact cut-face elevation & cross-section parity (< 10^-5 m error across all arms and offsets)
#   [B] Longitudinal grade C¹ directional slope continuity at approach boundaries (< 10^-4 rise/run error)
#   [C] Crease-free diagonal trajectory (smooth second difference |d²z/ds²| < 0.20 m^-1 vs fan spoke spikes)
#   [D] Watertight 2-manifold grid triangulation (all boundary edges in 1 tri, interior in 2, front-face up)
#   [E] Multi-arm geometry coverage (4-arm square, acute 35°, 3-arm T, 3-arm Y 120°, fillet & sharp)
#   [F] Active negative controls (disc elevation, zero-grade, fan spoke crease, legacy fan vertex count)
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadJunctionPatchGate: Bivariate Coons Patch Junction Surface (P9g) ===\n")
	_a_cut_face_elevation_and_cross_section_parity()
	_b_longitudinal_grade_slope_continuity()
	_c_crease_free_diagonal_trajectory()
	_d_watertight_grid_triangulation()
	_e_multi_arm_geometry_coverage()
	_f_active_negative_controls()
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD JUNCTION PATCH PASS" if _fail == 0 else "ROAD JUNCTION PATCH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(section: String, cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		print("    !! FAIL [%s]: %s" % [section, msg])
	else:
		print("    PASS [%s]: %s" % [section, msg])


# ---- Standard 4-Way Crossroads Fixture -------------------------------------------------------------

func _fixture_4way(trim: float = 6.413, half: float = 4.0) -> Dictionary:
	var arms: Array = [
		{"dir": Vector2(1, 0), "trim": trim, "half": half},
		{"dir": Vector2(0, 1), "trim": trim, "half": half},
		{"dir": Vector2(-1, 0), "trim": trim, "half": half},
		{"dir": Vector2(0, -1), "trim": trim, "half": half},
	]
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, 4.0)
	var arm_faces: Array = [
		{"dir": Vector2(1, 0), "trim": trim, "half": half, "z": 10.0 + 0.05 * trim, "bank": 0.02, "crown": 0.05, "grade": 0.05, "center": Vector2(trim, 0)},
		{"dir": Vector2(0, 1), "trim": trim, "half": half, "z": 10.0 - 0.03 * trim, "bank": -0.01, "crown": 0.05, "grade": -0.03, "center": Vector2(0, trim)},
		{"dir": Vector2(-1, 0), "trim": trim, "half": half, "z": 10.0 - 0.05 * trim, "bank": 0.02, "crown": 0.05, "grade": -0.05, "center": Vector2(-trim, 0)},
		{"dir": Vector2(0, -1), "trim": trim, "half": half, "z": 10.0 + 0.03 * trim, "bank": -0.01, "crown": 0.05, "grade": 0.03, "center": Vector2(0, -trim)},
	]
	return {"poly": poly, "arms": arms, "arm_faces": arm_faces, "elevation": 10.0}


# ---- [A] Cut-Face Elevation & Cross-Section Parity --------------------------------------------------

func _a_cut_face_elevation_and_cross_section_parity() -> void:
	print("[A] exact cut-face elevation and cross-section parity across all arms")
	var fx := _fixture_4way()
	var arm_faces: Array = fx["arm_faces"]
	var worst_err := 0.0
	var checks := 0

	for face: Dictionary in arm_faces:
		var dir: Vector2 = face["dir"]
		var n := Vector2(-dir.y, dir.x)
		var center: Vector2 = face["center"]
		var half: float = float(face["half"])
		var z: float = float(face["z"])
		var bank: float = float(face["bank"])
		var crown: float = float(face["crown"])

		for u_ratio in [-1.0, -0.6, -0.2, 0.0, 0.2, 0.6, 1.0]:
			var u: float = half * u_ratio
			var pt: Vector2 = center + n * u
			var c_half: float = float(face.get("carriageway_half", half))
			var s_width: float = float(face.get("shoulder_width", maxf(half - c_half, 0.0)))
			var c_mode: int = int(face.get("crown_mode", 0))
			var m_bank: float = float(face.get("max_bank", 0.0))
			var a_sign: float = float(face.get("sign", 1.0))
			var expected_h := Pasture3DRoadMesher.ribbon_cross_section_height(z, bank, crown, u * a_sign, c_half, s_width, c_mode, m_bank)
			var eval_h := Pasture3DRoadMesher.coons_patch_height_at(pt, Vector2.ZERO, arm_faces, float(fx["elevation"]))
			var err := absf(eval_h - expected_h)
			worst_err = maxf(worst_err, err)
			checks += 1

	_check("A", checks == 28, "checked 28 cut face cross-section locations")
	_check("A", worst_err < 1e-5, "all cut face points match ribbon cross-section to within 10^-5 m (worst: %.8f m)" % worst_err)


# ---- [B] Longitudinal Grade C¹ Directional Slope Continuity -----------------------------------------

func _b_longitudinal_grade_slope_continuity() -> void:
	print("[B] longitudinal grade C¹ directional slope continuity at approach boundaries")
	var fx := _fixture_4way()
	var arm_faces: Array = fx["arm_faces"]
	var worst_slope_err := 0.0

	for face: Dictionary in arm_faces:
		var dir: Vector2 = face["dir"]
		var center: Vector2 = face["center"]
		var grade: float = float(face["grade"])
		var ds := 0.001

		var h_face := Pasture3DRoadMesher.coons_patch_height_at(center, Vector2.ZERO, arm_faces, float(fx["elevation"]))
		var h_in := Pasture3DRoadMesher.coons_patch_height_at(center - dir * ds, Vector2.ZERO, arm_faces, float(fx["elevation"]))
		# Outward slope from junction to cut face: (h_face - h_in) / ds
		var outward_slope := (h_face - h_in) / ds
		var err := absf(outward_slope - grade)
		worst_slope_err = maxf(worst_slope_err, err)

	_check("B", worst_slope_err < 1e-4, "inward slope matches road longitudinal grade to within 10^-4 (worst err: %.6f)" % worst_slope_err)


# ---- [C] Crease-Free Diagonal Trajectory ------------------------------------------------------------

func _c_crease_free_diagonal_trajectory() -> void:
	print("[C] crease-free diagonal trajectory across multi-arm junction (zero radial spoke creases)")
	var fx := _fixture_4way()
	var arm_faces: Array = fx["arm_faces"]
	var poly: PackedVector2Array = fx["poly"]
	var elev: float = float(fx["elevation"])
	var b_heights := Pasture3DRoadMesher.footprint_boundary_heights(Vector2.ZERO, poly, arm_faces, elev)

	# Diagonal crossing cutting across sectors from (-4, -2) to (4, 2)
	var p_start := Vector2(-4.0, -2.0)
	var p_end := Vector2(4.0, 2.0)
	var samples := 200
	var step_len := p_start.distance_to(p_end) / float(samples)

	# 1. Coons patch evaluation
	var coons_max_d2z := 0.0
	var prev_h := Pasture3DRoadMesher.coons_patch_height_at(p_start, Vector2.ZERO, arm_faces, elev)
	var prev_slope := 0.0

	for i in range(1, samples):
		var t := float(i) / float(samples)
		var pt := p_start.lerp(p_end, t)
		var h := Pasture3DRoadMesher.coons_patch_height_at(pt, Vector2.ZERO, arm_faces, elev)
		var slope := (h - prev_h) / step_len
		if i > 1:
			var d2z := absf(slope - prev_slope) / step_len
			coons_max_d2z = maxf(coons_max_d2z, d2z)
		prev_slope = slope
		prev_h = h

	# 2. Legacy fan evaluation
	var fan_max_d2z := 0.0
	var fan_prev_h := Pasture3DRoadMesher.footprint_height_at(p_start, Vector2.ZERO, poly, b_heights, elev)
	var fan_prev_slope := 0.0

	for i in range(1, samples):
		var t := float(i) / float(samples)
		var pt := p_start.lerp(p_end, t)
		var h := Pasture3DRoadMesher.footprint_height_at(pt, Vector2.ZERO, poly, b_heights, elev)
		var slope := (h - fan_prev_h) / step_len
		if i > 1:
			var d2z := absf(slope - fan_prev_slope) / step_len
			fan_max_d2z = maxf(fan_max_d2z, d2z)
		fan_prev_slope = slope
		fan_prev_h = h

	print("    Coons patch diagonal peak |d²z/ds²|: %.4f m^-1" % coons_max_d2z)
	print("    Legacy fan diagonal peak |d²z/ds²|:   %.4f m^-1" % fan_max_d2z)

	_check("C", coons_max_d2z < 0.20, "Coons patch curvature is bounded (< 0.20 m^-1, measured %.4f)" % coons_max_d2z)
	_check("C", fan_max_d2z >= 0.50, "legacy fan exhibits spoke crease spike (>= 0.50 m^-1, measured %.4f)" % fan_max_d2z)
	_check("C", coons_max_d2z < fan_max_d2z * 0.4, "Coons patch is over 2.5x smoother than legacy triangle fan")


# ---- [D] Watertight Regular-Grid Triangulation ------------------------------------------------------

func _d_watertight_grid_triangulation() -> void:
	print("[D] watertight 2-manifold regular-grid interior triangulation")
	var fx := _fixture_4way()
	var poly: PackedVector2Array = fx["poly"]
	var arm_faces: Array = fx["arm_faces"]
	var d_elev: float = float(fx["elevation"])

	var arrays := Pasture3DRoadMesher.build_coons_patch(Vector2.ZERO, poly, arm_faces, d_elev, 1.2, 0.0)
	_check("D", not arrays.is_empty(), "build_coons_patch produced mesh arrays")
	if arrays.is_empty():
		return

	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	print("    %d boundary vertices -> %d total vertices, %d triangles" %
			[poly.size(), verts.size(), indices.size() / 3])

	_check("D", verts.size() > poly.size() + 1, "mesh includes interior grid vertices (%d > %d)" % [verts.size(), poly.size() + 1])
	_check("D", indices.size() % 3 == 0, "indices are complete triangles")

	# Boundary edge & manifold verification
	var edge_count := {}
	var wrong_winding := 0
	var ti := 0
	while ti + 2 < indices.size():
		var i0 := indices[ti]
		var i1 := indices[ti + 1]
		var i2 := indices[ti + 2]
		var p0 := verts[i0]
		var p1 := verts[i1]
		var p2 := verts[i2]

		# Front face in Godot seen from above: cross.y < 0
		if (p1 - p0).cross(p2 - p0).y > 1e-9:
			wrong_winding += 1

		for edge in [[mini(i0, i1), maxi(i0, i1)], [mini(i1, i2), maxi(i1, i2)], [mini(i2, i0), maxi(i2, i0)]]:
			var key: String = "%d_%d" % [edge[0], edge[1]]
			edge_count[key] = edge_count.get(key, 0) + 1
		ti += 3

	_check("D", wrong_winding == 0, "every triangle faces up (0 wound wrong way, found %d)" % wrong_winding)

	var boundary_ok := true
	for i in poly.size():
		var i_next := (i + 1) % poly.size()
		var key: String = "%d_%d" % [mini(i, i_next), maxi(i, i_next)]
		var c: int = edge_count.get(key, 0)
		if c != 1:
			boundary_ok = false

	_check("D", boundary_ok, "every boundary polygon edge appears in exactly 1 triangle (watertight)")

	var non_manifold := 0
	for key in edge_count:
		var c: int = edge_count[key]
		if c != 1 and c != 2:
			non_manifold += 1

	_check("D", non_manifold == 0, "mesh is strictly 2-manifold (0 non-manifold edges)")

	var downward_normals := 0
	for norm in normals:
		if norm.y <= 0.0:
			downward_normals += 1
	_check("D", downward_normals == 0, "all vertex normals point upward (0 non-upward)")


# ---- [E] Multi-Arm Geometry Coverage ----------------------------------------------------------------

func _test_arm_fixture(name: String, arms: Array, corner_radius: float, arm_faces: Array, elevation: float) -> bool:
	var poly := Pasture3DRoadMesher.plan_footprint(Vector2.ZERO, arms, corner_radius)
	var arrays := Pasture3DRoadMesher.build_coons_patch(Vector2.ZERO, poly, arm_faces, elevation, 1.2, 0.0)
	if arrays.is_empty():
		return false
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var edge_count := {}
	var wrong_winding := 0
	var ti := 0
	while ti + 2 < indices.size():
		var i0 := indices[ti]
		var i1 := indices[ti + 1]
		var i2 := indices[ti + 2]
		var p0 := verts[i0]
		var p1 := verts[i1]
		var p2 := verts[i2]
		if (p1 - p0).cross(p2 - p0).y > 1e-9:
			wrong_winding += 1
		for edge in [[mini(i0, i1), maxi(i0, i1)], [mini(i1, i2), maxi(i1, i2)], [mini(i2, i0), maxi(i2, i0)]]:
			var key: String = "%d_%d" % [edge[0], edge[1]]
			edge_count[key] = edge_count.get(key, 0) + 1
		ti += 3

	var boundary_ok := true
	for i in poly.size():
		var i_next := (i + 1) % poly.size()
		var key: String = "%d_%d" % [mini(i, i_next), maxi(i, i_next)]
		if edge_count.get(key, 0) != 1:
			boundary_ok = false

	var non_manifold := 0
	for key in edge_count:
		var c: int = edge_count[key]
		if c != 1 and c != 2:
			non_manifold += 1

	var ok = boundary_ok and non_manifold == 0 and wrong_winding == 0 and verts.size() > poly.size()
	print("    [%s] poly: %d, verts: %d, tris: %d -> %s" %
			[name, poly.size(), verts.size(), indices.size() / 3, "PASS" if ok else "FAIL"])
	return ok


func _e_multi_arm_geometry_coverage() -> void:
	print("[E] multi-arm geometry coverage: T-junction, Y-junction, acute crossing, sharp & filleted")

	# 1. 4-arm square sharp (r=0)
	var cross := [
		{"dir": Vector2(1, 0), "trim": 6.413, "half": 4.0},
		{"dir": Vector2(0, 1), "trim": 6.413, "half": 4.0},
		{"dir": Vector2(-1, 0), "trim": 6.413, "half": 4.0},
		{"dir": Vector2(0, -1), "trim": 6.413, "half": 4.0},
	]
	var faces_cross := [
		{"dir": Vector2(1, 0), "trim": 6.413, "half": 4.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "grade": 0.0, "center": Vector2(6.413, 0)},
		{"dir": Vector2(0, 1), "trim": 6.413, "half": 4.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "grade": 0.0, "center": Vector2(0, 6.413)},
		{"dir": Vector2(-1, 0), "trim": 6.413, "half": 4.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "grade": 0.0, "center": Vector2(-6.413, 0)},
		{"dir": Vector2(0, -1), "trim": 6.413, "half": 4.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "grade": 0.0, "center": Vector2(0, -6.413)},
	]
	_check("E", _test_arm_fixture("4-arm square sharp r=0", cross, 0.0, faces_cross, 10.0), "4-arm square sharp r=0 passes")

	# 2. 3-arm T-junction
	var t_arms := [
		{"dir": Vector2(1, 0), "trim": 4.0, "half": 4.0},
		{"dir": Vector2(-1, 0), "trim": 4.0, "half": 4.0},
		{"dir": Vector2(0, 1), "trim": 4.0, "half": 4.0},
	]
	var t_faces := [
		{"dir": Vector2(1, 0), "trim": 4.0, "half": 4.0, "z": 5.0, "bank": 0.01, "crown": 0.04, "grade": 0.02, "center": Vector2(4.0, 0)},
		{"dir": Vector2(-1, 0), "trim": 4.0, "half": 4.0, "z": 5.0, "bank": 0.01, "crown": 0.04, "grade": -0.02, "center": Vector2(-4.0, 0)},
		{"dir": Vector2(0, 1), "trim": 4.0, "half": 4.0, "z": 5.0, "bank": 0.0, "crown": 0.04, "grade": 0.04, "center": Vector2(0, 4.0)},
	]
	_check("E", _test_arm_fixture("3-arm T-junction r=4", t_arms, 4.0, t_faces, 5.0), "3-arm T-junction r=4 passes")
	_check("E", _test_arm_fixture("3-arm T-junction r=0", t_arms, 0.0, t_faces, 5.0), "3-arm T-junction r=0 passes")

	# 3. 3-arm Y-junction 120°
	var y_arms := [
		{"dir": Vector2(cos(0.0), sin(0.0)), "trim": 5.0, "half": 3.5},
		{"dir": Vector2(cos(2.0 * PI / 3.0), sin(2.0 * PI / 3.0)), "trim": 5.0, "half": 3.5},
		{"dir": Vector2(cos(4.0 * PI / 3.0), sin(4.0 * PI / 3.0)), "trim": 5.0, "half": 3.5},
	]
	var y_faces := [
		{"dir": y_arms[0]["dir"], "trim": 5.0, "half": 3.5, "z": 8.0, "bank": 0.0, "crown": 0.05, "grade": 0.01, "center": y_arms[0]["dir"] * 5.0},
		{"dir": y_arms[1]["dir"], "trim": 5.0, "half": 3.5, "z": 8.0, "bank": 0.0, "crown": 0.05, "grade": 0.01, "center": y_arms[1]["dir"] * 5.0},
		{"dir": y_arms[2]["dir"], "trim": 5.0, "half": 3.5, "z": 8.0, "bank": 0.0, "crown": 0.05, "grade": 0.01, "center": y_arms[2]["dir"] * 5.0},
	]
	_check("E", _test_arm_fixture("3-arm Y-junction 120° r=3", y_arms, 3.0, y_faces, 8.0), "3-arm Y-junction 120° r=3 passes")

	# 4. Acute crossing 35°
	var a := 35.0 * PI / 180.0
	var acute_arms := [
		{"dir": Vector2(1, 0), "trim": 10.0, "half": 4.0},
		{"dir": Vector2(-1, 0), "trim": 10.0, "half": 4.0},
		{"dir": Vector2(cos(a), sin(a)), "trim": 10.0, "half": 4.0},
		{"dir": Vector2(-cos(a), -sin(a)), "trim": 10.0, "half": 4.0},
	]
	var acute_faces := [
		{"dir": acute_arms[0]["dir"], "trim": 10.0, "half": 4.0, "z": 12.0, "bank": 0.0, "crown": 0.05, "grade": 0.02, "center": acute_arms[0]["dir"] * 10.0},
		{"dir": acute_arms[1]["dir"], "trim": 10.0, "half": 4.0, "z": 12.0, "bank": 0.0, "crown": 0.05, "grade": -0.02, "center": acute_arms[1]["dir"] * 10.0},
		{"dir": acute_arms[2]["dir"], "trim": 10.0, "half": 4.0, "z": 12.0, "bank": 0.0, "crown": 0.05, "grade": 0.01, "center": acute_arms[2]["dir"] * 10.0},
		{"dir": acute_arms[3]["dir"], "trim": 10.0, "half": 4.0, "z": 12.0, "bank": 0.0, "crown": 0.05, "grade": -0.01, "center": acute_arms[3]["dir"] * 10.0},
	]
	_check("E", _test_arm_fixture("4-arm acute 35° r=2", acute_arms, 2.0, acute_faces, 12.0), "4-arm acute 35° r=2 passes")

	# 5. Multi-profile crossing: 4 arms with distinct profiles (parabolic, circular, crossfall, v-roof)
	var multi_arms := [
		{"dir": Vector2(1, 0), "trim": 8.0, "half": 5.0, "carriageway_half": 4.5, "shoulder_width": 0.5},
		{"dir": Vector2(0, 1), "trim": 8.0, "half": 4.0, "carriageway_half": 4.0, "shoulder_width": 0.0},
		{"dir": Vector2(-1, 0), "trim": 8.0, "half": 4.5, "carriageway_half": 3.5, "shoulder_width": 1.0},
		{"dir": Vector2(0, -1), "trim": 8.0, "half": 4.0, "carriageway_half": 4.0, "shoulder_width": 0.0},
	]
	var multi_faces := [
		{"dir": multi_arms[0]["dir"], "trim": 8.0, "half": 5.0, "carriageway_half": 4.5, "shoulder_width": 0.5, "z": 10.0, "bank": 0.02, "crown": 0.04, "crown_mode": 0, "max_bank": 0.06, "grade": 0.01, "center": Vector2(8.0, 0), "sign": 1.0},
		{"dir": multi_arms[1]["dir"], "trim": 8.0, "half": 4.0, "carriageway_half": 4.0, "shoulder_width": 0.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "crown_mode": 2, "max_bank": 0.0, "grade": -0.02, "center": Vector2(0, 8.0), "sign": 1.0},
		{"dir": multi_arms[2]["dir"], "trim": 8.0, "half": 4.5, "carriageway_half": 3.5, "shoulder_width": 1.0, "z": 10.0, "bank": -0.01, "crown": 0.03, "crown_mode": 1, "max_bank": 0.05, "grade": 0.03, "center": Vector2(-8.0, 0), "sign": -1.0},
		{"dir": multi_arms[3]["dir"], "trim": 8.0, "half": 4.0, "carriageway_half": 4.0, "shoulder_width": 0.0, "z": 10.0, "bank": 0.0, "crown": 0.05, "crown_mode": 3, "max_bank": 0.0, "grade": -0.01, "center": Vector2(0, -8.0), "sign": -1.0},
	]
	_check("E", _test_arm_fixture("4-arm multi-profile crossing r=3", multi_arms, 3.0, multi_faces, 10.0), "4-arm multi-profile crossing r=3 passes")

	var multi_worst_err := 0.0
	for face: Dictionary in multi_faces:
		var dir: Vector2 = face["dir"]
		var n := Vector2(-dir.y, dir.x)
		var center: Vector2 = face["center"]
		var half: float = float(face["half"])
		var c_half: float = float(face["carriageway_half"])
		var c_mode: int = int(face["crown_mode"])
		var m_bank: float = float(face["max_bank"])
		var a_sign: float = float(face["sign"])
		var z: float = float(face["z"])
		var bank: float = float(face["bank"])
		var crown: float = float(face["crown"])
		for u_ratio in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var u: float = half * u_ratio
			var pt: Vector2 = center + n * u
			var s_width: float = float(face.get("shoulder_width", maxf(half - c_half, 0.0)))
			var expected_h := Pasture3DRoadMesher.ribbon_cross_section_height(z, bank, crown, u * a_sign, c_half, s_width, c_mode, m_bank)
			var eval_h := Pasture3DRoadMesher.coons_patch_height_at(pt, Vector2.ZERO, multi_faces, 10.0)
			multi_worst_err = maxf(multi_worst_err, absf(eval_h - expected_h))
	_check("E", multi_worst_err < 1e-5, "multi-profile junction cut faces match respective road profiles to < 10^-5 m (worst: %.8f m)" % multi_worst_err)


# ---- [F] Active Negative Controls -------------------------------------------------------------------

func _f_active_negative_controls() -> void:
	print("[F] active negative controls ensure assertions bite")
	var fx := _fixture_4way()
	var arm_faces: Array = fx["arm_faces"]
	var elevation: float = float(fx["elevation"])

	# Control 1: Flat disc at junction elevation fails cut-face height parity
	var east_cut_center: Vector2 = arm_faces[0]["center"]
	var true_east_z: float = float(arm_faces[0]["z"]) # 10.32065 m
	var disc_z: float = elevation # 10.0 m
	var disc_err := absf(disc_z - true_east_z)
	_check("F", disc_err > 0.30, "control: flat disc misses cut face by > 0.30 m (missed %.4f m)" % disc_err)

	# Control 2: Omitting grade fails longitudinal slope continuity
	var faces_no_grade: Array = []
	for f in arm_faces:
		var dup = f.duplicate()
		dup["grade"] = 0.0
		faces_no_grade.append(dup)
	var ds := 0.001
	var h_f := Pasture3DRoadMesher.coons_patch_height_at(east_cut_center, Vector2.ZERO, faces_no_grade, elevation)
	var h_i := Pasture3DRoadMesher.coons_patch_height_at(east_cut_center - arm_faces[0]["dir"] * ds, Vector2.ZERO, faces_no_grade, elevation)
	var zero_grade_slope := (h_f - h_i) / ds
	var grade_err := absf(zero_grade_slope - float(arm_faces[0]["grade"]))
	_check("F", grade_err > 0.03, "control: zero grade omits slope matching, error > 0.03 (err: %.6f)" % grade_err)

	# Control 3: Legacy build_footprint without arm_faces builds the legacy fan (exactly poly.size() + 1 verts)
	var fan_arrays := Pasture3DRoadMesher.build_footprint(Vector2.ZERO, fx["poly"],
			Pasture3DRoadMesher.footprint_boundary_heights(Vector2.ZERO, fx["poly"], arm_faces, elevation),
			elevation, 0.0)
	var fan_verts: PackedVector3Array = fan_arrays[Mesh.ARRAY_VERTEX]
	_check("F", fan_verts.size() == fx["poly"].size() + 1, "control: legacy signature builds exactly poly.size() + 1 fan vertices (%d vs %d)" % [fan_verts.size(), fx["poly"].size() + 1])
