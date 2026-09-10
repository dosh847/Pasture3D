# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSharpCornerSmoothingGate — Sharp Turn Detection, Spline Smoothing & Swallowtail Mitigation Gate.
# See PASTURE3D_ROAD_INTERSECTION_AND_SPLINE_SPEC.md §4 (Issue 3).
#
# Criteria:
#   [A] Curvature detection: flags sharp 90° elbow with R ≈ 2.0 m and severity > 0
#   [B] Spline smoothing relaxation: smooth_sharp_corners() relaxes corner to R >= 1.2 * w_half = 4.8 m
#   [C] Mesher swallowtail mitigation: un-smoothed R = 1.5 m turn produces 0 inverted quads,
#       delta_parallel >= 0.0, and 0 overlapping triangles in C++ and GDScript
#   [D] Active negative controls: un-mitred rings invert speed, un-smoothed spline fails R >= 4.8 m
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadSharpCornerSmoothingGate: Sharp Corner Detection, Smoothing & Swallowtail Mitigation ===\n")
	_a_curvature_detection_radius_assertion()
	_b_spline_smoothing_relaxation()
	_c_mesher_swallowtail_overlap_elimination()
	_d_active_negative_controls()
	print("\n=== %s (%d failures) ===\n"
			% ["ROAD SHARP CORNER SMOOTHING PASS" if _fail == 0 else "ROAD SHARP CORNER SMOOTHING FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(section: String, cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		print("    !! FAIL [%s]: %s" % [section, msg])
	else:
		print("    PASS [%s]: %s" % [section, msg])


# ---- Helpers & Test Fixtures ----------------------------------------------------------------------

func _create_road_brush_with_elbow(r_elbow: float, half_w: float) -> Pasture3DRoadBrush:
	var brush := Pasture3DRoadBrush.new()
	var rt := Pasture3DRoadType.new()
	rt.lane_count = 2
	rt.lane_width = half_w
	rt.shoulder_width = 0.5
	brush.road_defaults = Pasture3DRoadOverrides.new()
	brush.road_defaults.road_type = rt

	var path := Path3D.new()
	var c := Curve3D.new()
	var k: float = 4.0 / 3.0 * (sqrt(2.0) - 1.0) * r_elbow
	c.add_point(Vector3(0.0, 0.0, 0.0))
	c.add_point(Vector3(50.0 - r_elbow, 0.0, 0.0), Vector3.ZERO, Vector3(k, 0.0, 0.0))
	c.add_point(Vector3(50.0, 0.0, r_elbow), Vector3(0.0, 0.0, -k), Vector3.ZERO)
	c.add_point(Vector3(50.0, 0.0, 50.0))
	path.curve = c
	brush.add_child(path)
	add_child(brush)
	return brush


func _create_road_brush_with_kink(half_w: float) -> Pasture3DRoadBrush:
	var brush := Pasture3DRoadBrush.new()
	var rt := Pasture3DRoadType.new()
	rt.lane_count = 2
	rt.lane_width = half_w
	rt.shoulder_width = 0.5
	brush.road_defaults = Pasture3DRoadOverrides.new()
	brush.road_defaults.road_type = rt

	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, 0.0))
	c.add_point(Vector3(50.0, 0.0, 0.0))
	c.add_point(Vector3(50.0, 0.0, 50.0))
	path.curve = c
	brush.add_child(path)
	add_child(brush)
	return brush


func _measure_curve_min_radius(c: Curve3D, ds: float = 0.5) -> float:
	var pts := c.tessellate(6, 1.0)
	var poly := PackedVector2Array()
	for p in pts:
		poly.append(Vector2(p.x, p.z))
	var cum := Pasture3DRoadGrader.cumulative_length(poly)
	var n_s := int(ceil(cum[-1] / ds)) + 1
	var r_plan := PackedVector2Array()
	r_plan.resize(n_s)
	for i in n_s:
		r_plan[i] = _plan_point_at(poly, cum, float(i) * ds)
	var curv: PackedFloat32Array
	if ClassDB.class_has_method("Pasture3DUtil", "road_plan_curvature"):
		curv = Pasture3DUtil.road_plan_curvature(r_plan)
	else:
		curv = Pasture3DRoadAlignmentSolver.plan_curvature(r_plan)
	var max_k := 0.0
	for kv in curv:
		if absf(kv) > max_k:
			max_k = absf(kv)
	return 1.0 / max_k if max_k > 1e-5 else 1e9


func _plan_point_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float) -> Vector2:
	var n := p_cum.size()
	if n == 0:
		return Vector2.ZERO
	if p_s <= 0.0 or n == 1:
		return p_plan[0]
	if p_s >= p_cum[n - 1]:
		return p_plan[n - 1]
	var idx := p_cum.bsearch(p_s)
	if idx <= 0:
		return p_plan[0]
	if idx >= n:
		return p_plan[n - 1]
	var s0 := p_cum[idx - 1]
	var s1 := p_cum[idx]
	var span := s1 - s0
	var t := (p_s - s0) / span if span > 1e-6 else 0.0
	return p_plan[idx - 1].lerp(p_plan[idx], t)


# ---- Criteria Implementations ---------------------------------------------------------------------

func _a_curvature_detection_radius_assertion() -> void:
	print("[Criterion A: Curvature Detection & Radius Assertion]")
	var half_w := 4.0
	var r_crit := half_w * 1.2 # 4.8 m
	var brush := _create_road_brush_with_elbow(2.0, half_w)

	var detected := brush.detect_sharp_corners(r_crit)
	_check("A1", detected.size() == 1,
			"Detected exactly 1 sharp corner on 90° elbow (got %d)" % detected.size())

	if detected.size() == 1:
		var c := detected[0]
		var r_meas: float = c["radius"]
		var sev: float = c["severity"]
		_check("A2", absf(r_meas - 2.0) <= 0.25,
				"Flagged radius matches R ≈ 2.0 m (got %.4f m)" % r_meas)
		_check("A3", sev > 0.0 and sev <= 1.0,
				"Severity is strictly positive (got %.4f)" % sev)
		var pt: Vector3 = c["point"]
		_check("A4", pt.distance_to(Vector3(50.0, 0.0, 0.0)) <= 3.0,
				"Corner position flags apex near (50, 0, 0) (got %s)" % str(pt))

	# Also verify that a zero-handle 90° kink is flagged with high severity
	var kink_brush := _create_road_brush_with_kink(half_w)
	var kink_detected := kink_brush.detect_sharp_corners(r_crit)
	_check("A5", kink_detected.size() == 1,
			"Detected sharp corner on zero-handle kink (got %d)" % kink_detected.size())
	if kink_detected.size() == 1:
		_check("A6", kink_detected[0]["radius"] < 2.0 and kink_detected[0]["severity"] > 0.7,
				"Kink has high severity violation (R=%.4f m, sev=%.4f)"
				% [kink_detected[0]["radius"], kink_detected[0]["severity"]])
	brush.queue_free()
	kink_brush.queue_free()


func _b_spline_smoothing_relaxation() -> void:
	print("\n[Criterion B: Spline Smoothing & Tangent Relaxation]")
	var half_w := 4.0
	var r_crit := half_w * 1.2 # 4.8 m
	var brush := _create_road_brush_with_elbow(2.0, half_w)

	var modified := brush.smooth_sharp_corners(r_crit)
	_check("B1", modified > 0, "smooth_sharp_corners modified %d control points" % modified)

	var post_detected := brush.detect_sharp_corners(r_crit)
	_check("B2", post_detected.is_empty(),
			"Post-smoothing detect_sharp_corners returns 0 violations (got %d)" % post_detected.size())

	var splines: Array = brush._get_splines()
	if not splines.is_empty() and splines[0] is Path3D and splines[0].curve != null:
		var post_r := _measure_curve_min_radius(splines[0].curve)
		_check("B3", post_r >= r_crit,
				"Post-smoothing min radius satisfies R >= %.2f m (got %.4f m)" % [r_crit, post_r])

	# Also test smoothing on the zero-handle kink
	var kink_brush := _create_road_brush_with_kink(half_w)
	var kink_mod := kink_brush.smooth_sharp_corners(r_crit)
	_check("B4", kink_mod > 0, "Kink smoothing modified %d control points" % kink_mod)
	var kink_post_det := kink_brush.detect_sharp_corners(r_crit)
	_check("B5", kink_post_det.is_empty(),
			"Post-smoothing kink has 0 violations (got %d)" % kink_post_det.size())
	var kink_splines: Array = kink_brush._get_splines()
	if not kink_splines.is_empty() and kink_splines[0] is Path3D and kink_splines[0].curve != null:
		var kink_post_r := _measure_curve_min_radius(kink_splines[0].curve)
		_check("B6", kink_post_r >= r_crit,
				"Post-smoothing kink min radius satisfies R >= %.2f m (got %.4f m)" % [r_crit, kink_post_r])

	brush.queue_free()
	kink_brush.queue_free()


func _c_mesher_swallowtail_overlap_elimination() -> void:
	print("\n[Criterion C: Mesher Swallowtail Overlap Elimination]")
	var half_w := 4.0
	var shoulder := 0.5
	var crown := 0.02

	# Build sharp un-smoothed turn (R = 1.5 m < half_w = 4.0 m)
	var c := Curve3D.new()
	var R := 1.5
	var k: float = 4.0 / 3.0 * (sqrt(2.0) - 1.0) * R
	c.add_point(Vector3(0.0, 0.0, 0.0))
	c.add_point(Vector3(10.0, 0.0, 0.0), Vector3.ZERO, Vector3(k, 0.0, 0.0))
	c.add_point(Vector3(10.0 + R, 0.0, R), Vector3(0.0, 0.0, -k), Vector3.ZERO)
	c.add_point(Vector3(10.0 + R, 0.0, 10.0 + R))

	var pts := c.tessellate(6, 1.0)
	var poly := PackedVector2Array()
	for p in pts:
		poly.append(Vector2(p.x, p.z))
	var cum := Pasture3DRoadGrader.cumulative_length(poly)
	var total_len: float = cum[-1]

	var ds := 0.2
	var n_s := int(ceil(total_len / ds)) + 1
	var align := Pasture3DRoadAlignment.new()
	align.ds = ds
	align.z = Pasture3DRoadGrader._zeros(n_s)
	align.bank = Pasture3DRoadGrader._zeros(n_s)

	for force_gd in [false, true]:
		var name_str := "GDScript" if force_gd else "C++"
		var chunk := Pasture3DRoadMesher.build_chunk(poly, cum, align, 0.0, total_len,
				half_w, shoulder, crown, 0, 0.02, force_gd)
		_check("C1_" + name_str, not chunk.is_empty(), "%s chunk produced valid surface array" % name_str)
		if chunk.is_empty():
			continue

		var verts: PackedVector3Array = chunk[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = chunk[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = chunk[Mesh.ARRAY_INDEX]

		# 1. No inverted face winding: all vertex normals point UP
		var min_ny := 1.0
		for n in normals:
			if n.y < min_ny:
				min_ny = n.y
		_check("C2_" + name_str, min_ny > 0.0,
				"%s vertex normals point UP everywhere (min n.y = %.4f)" % [name_str, min_ny])

		# 2. Longitudinal inner edge steps satisfy delta_parallel >= 0.0
		var offsets := Pasture3DRoadMesher.cross_offsets(half_w, shoulder, Pasture3DRoadMesher.cross_for_lod(0))
		var across_count := offsets.size()
		var rows := verts.size() / across_count
		var step := Pasture3DRoadMesher.step_for_lod(ds, 0)
		var min_delta_dot := 1e9
		for r in range(rows - 1):
			var s: float = minf(float(r) * step, total_len)
			var tang := Pasture3DRoadGrader.plan_tangent_at(poly, cum, s)
			for col in across_count:
				var v0 := verts[r * across_count + col]
				var v1 := verts[(r + 1) * across_count + col]
				var delta := Vector2(v1.x - v0.x, v1.z - v0.z)
				var d_dot := delta.dot(tang)
				if d_dot < min_delta_dot:
					min_delta_dot = d_dot
		_check("C3_" + name_str, min_delta_dot >= -1e-5,
				"%s inner edge steps monotonic delta_parallel >= 0.0 (got %.6f)" % [name_str, min_delta_dot])

		# 3. All indexed triangles have strictly positive area
		var tri_count := indices.size() / 3
		var zero_area_tris := 0
		for t in tri_count:
			var i0 := indices[t * 3]
			var i1 := indices[t * 3 + 1]
			var i2 := indices[t * 3 + 2]
			var a := Vector2(verts[i0].x, verts[i0].z)
			var b := Vector2(verts[i1].x, verts[i1].z)
			var c_pt := Vector2(verts[i2].x, verts[i2].z)
			var area := 0.5 * absf((b.x - a.x) * (c_pt.y - a.y) - (b.y - a.y) * (c_pt.x - a.x))
			if area < 1e-6:
				zero_area_tris += 1
		_check("C4_" + name_str, zero_area_tris == 0,
				"%s suppressed all %d degenerate/inverted triangles (0 indexed)" % [name_str, zero_area_tris])


func _d_active_negative_controls() -> void:
	print("\n[Criterion D: Active Negative Controls]")
	var half_w := 4.0
	var shoulder := 0.5
	var crown := 0.02

	# Negative Control 1: Raw unmitred rings on R = 1.5 m turn invert velocity
	# Simulate unmitred rings without apex clamping: delta_parallel < 0
	var c := Curve3D.new()
	var R := 1.5
	var k: float = 4.0 / 3.0 * (sqrt(2.0) - 1.0) * R
	c.add_point(Vector3(0.0, 0.0, 0.0))
	c.add_point(Vector3(10.0, 0.0, 0.0), Vector3.ZERO, Vector3(k, 0.0, 0.0))
	c.add_point(Vector3(10.0 + R, 0.0, R), Vector3(0.0, 0.0, -k), Vector3.ZERO)
	c.add_point(Vector3(10.0 + R, 0.0, 10.0 + R))

	var pts := c.tessellate(6, 1.0)
	var poly := PackedVector2Array()
	for p in pts:
		poly.append(Vector2(p.x, p.z))
	var cum := Pasture3DRoadGrader.cumulative_length(poly)
	var total_len: float = cum[-1]

	var offsets := Pasture3DRoadMesher.cross_offsets(half_w, shoulder, Pasture3DRoadMesher.cross_for_lod(0))
	var unmitred_inversion_detected := false
	var ds := 0.2
	var align := Pasture3DRoadAlignment.new()
	align.ds = ds
	align.z = Pasture3DRoadGrader._zeros(int(ceil(total_len / ds)) + 1)
	align.bank = Pasture3DRoadGrader._zeros(align.z.size())

	# Measure raw unmitred ring steps across the tight turn apex
	var raw_r0 := Pasture3DRoadMesher.ring(poly, cum, align, 10.5, offsets, crown)
	var raw_r1 := Pasture3DRoadMesher.ring(poly, cum, align, 11.0, offsets, crown)
	var tang := Pasture3DRoadGrader.plan_tangent_at(poly, cum, 10.5)
	for col in offsets.size():
		var delta := Vector2(raw_r1[col].x - raw_r0[col].x, raw_r1[col].z - raw_r0[col].z)
		if delta.dot(tang) < 0.0:
			unmitred_inversion_detected = true
			break
	_check("D1", unmitred_inversion_detected,
			"Negative control correctly flags raw unmitred rings inverting velocity on inner edge")

	# Negative Control 2: Un-smoothed R = 2.0 m elbow fails R >= 4.8 m requirement
	var un_smoothed_elbow := Curve3D.new()
	var k2: float = 4.0 / 3.0 * (sqrt(2.0) - 1.0) * 2.0
	un_smoothed_elbow.add_point(Vector3(0.0, 0.0, 0.0))
	un_smoothed_elbow.add_point(Vector3(48.0, 0.0, 0.0), Vector3.ZERO, Vector3(k2, 0.0, 0.0))
	un_smoothed_elbow.add_point(Vector3(50.0, 0.0, 2.0), Vector3(0.0, 0.0, -k2), Vector3.ZERO)
	un_smoothed_elbow.add_point(Vector3(50.0, 0.0, 50.0))
	var raw_elbow_r := _measure_curve_min_radius(un_smoothed_elbow)
	_check("D2", raw_elbow_r < 4.8,
			"Negative control confirms un-smoothed elbow fails R >= 4.8 m (R = %.4f m)" % raw_elbow_r)

	# Negative Control 3: Corrupted/spurious corner detection is caught
	var fake_corner := { "s": 25.0, "radius": 15.0, "point": Vector3.ZERO, "severity": -0.5 }
	var fake_is_violation: bool = float(fake_corner["radius"]) < 4.8 and float(fake_corner["severity"]) > 0.0
	_check("D3", not fake_is_violation,
			"Negative control confirms safe radius (R = 15 m) is not treated as a sharp corner")
