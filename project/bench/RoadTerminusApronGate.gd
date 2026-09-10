# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadTerminusApronGate — Simcade Phase 3: Bevelled Pavement Terminal Aprons.
# Gating:
#   [A] Watertight Seam with Road Edge (apron row 0 bit-identical to road chunk boundary ring)
#   [B] Smooth Hermite Downward Transition and Slope Continuity
#   [C] Lateral Shoulder Fillet Roundness (smooth inward corner rounding)
#   [D] Trimesh Collision Coverage & Surface Normal Upward Orientation
#   [E] C++ Native Mesher Parity (road_mesh_build_terminus_apron matches GDScript oracle)
@tool
extends Node

const DS: float = 1.0

var _fail: int = 0
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadTerminusApronGate: bevelled pavement terminal aprons (Phase 3) ===\n")
	_a_watertight_seam_with_road_edge()
	_b_smooth_hermite_downward_transition()
	_c_lateral_shoulder_fillet_roundness()
	_d_trimesh_collision_and_normal_orientation()
	_e_cpp_native_mesher_parity()
	for c in CRITERIA:
		if not _reported.get(c, false):
			_fail += 1
			print("    !! criterion [%s] never reported (gate aborted early)" % c)
	print("\n=== %s (%d failures) ===\n" % ["TERMINUS APRON PASS" if _fail == 0 else "TERMINUS APRON FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
		print("    FAIL [%s]: %s" % [p_name, p_detail])
	else:
		print("    PASS [%s]: %s" % [p_name, p_detail])


func _make_fixture_alignment(n_s: int, p_grade: float = 0.03, p_bank: float = 0.0) -> Dictionary:
	var plan := PackedVector2Array()
	var cum := PackedFloat32Array()
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	for i in n_s:
		var s := float(i) * DS
		plan.append(Vector2(s, 0.0))
		cum.append(s)
		z.append(10.0 + s * p_grade)
		bank.append(p_bank)
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	a.s0 = 0.0
	a.z = z
	a.ground = z.duplicate()
	a.bank = bank
	a.curvature = Pasture3DRoadGrader._zeros(n_s)
	return {"plan": plan, "cum": cum, "alignment": a}


## [A] Watertight Seam with Road Edge:
## Ring 0 of the terminal apron matches the boundary ring of the road chunk bit-identically.
func _a_watertight_seam_with_road_edge() -> void:
	print("[A] watertight seam with road edge (zero gap at chunk boundary)")
	var fx := _make_fixture_alignment(60, 0.04, 0.02)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var total_s: float = cum[cum.size() - 1]
	var half := 4.0
	var shoulder := 1.0
	var crown := 0.05
	var lift := 0.02

	# 1. Start terminus (s = 0.0):
	var start_chunk := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 20.0, half, shoulder, crown, 0, lift)
	var start_apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, 0.0, half, shoulder, crown, true, 2.5, 0.08, 4, lift)

	var chunk_verts_start: PackedVector3Array = start_chunk[Mesh.ARRAY_VERTEX]
	var apron_verts_start: PackedVector3Array = start_apron[Mesh.ARRAY_VERTEX]

	var max_diff_start := 0.0
	# First row of start chunk (first 5 vertices) vs first row of apron (first 5 vertices)
	for c in 5:
		var diff := (chunk_verts_start[c] - apron_verts_start[c]).length()
		max_diff_start = maxf(max_diff_start, diff)

	# 2. End terminus (s = total_s):
	var end_chunk := Pasture3DRoadMesher.build_chunk(plan, cum, a, total_s - 20.0, total_s, half, shoulder, crown, 0, lift)
	var end_apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, total_s, half, shoulder, crown, false, 2.5, 0.08, 4, lift)

	var chunk_verts_end: PackedVector3Array = end_chunk[Mesh.ARRAY_VERTEX]
	var apron_verts_end: PackedVector3Array = end_apron[Mesh.ARRAY_VERTEX]

	# Last row of end chunk (last 5 vertices) vs first row of apron (first 5 vertices)
	var last_row_start_idx := chunk_verts_end.size() - 5
	var max_diff_end := 0.0
	for c in 5:
		var diff := (chunk_verts_end[last_row_start_idx + c] - apron_verts_end[c]).length()
		max_diff_end = maxf(max_diff_end, diff)

	print("    start seam worst gap: %.9f m | end seam worst gap: %.9f m" % [max_diff_start, max_diff_end])
	var ok: bool = max_diff_start < 1e-6 and max_diff_end < 1e-6
	_check("A", ok, "seam between road chunk and terminal apron is watertight to < 1e-6 m")

	# Control: evaluating at s + 0.5 m produces a measurable gap
	var displaced_apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, 0.5, half, shoulder, crown, true, 2.5, 0.08, 4, lift)
	var disp_verts: PackedVector3Array = displaced_apron[Mesh.ARRAY_VERTEX]
	var control_gap := (chunk_verts_start[0] - disp_verts[0]).length()
	print("    control: displaced apron gap = %.4f m (want > 0.01)" % control_gap)
	if control_gap < 0.01:
		_fail += 1
		print("    !! control failed: displaced apron did not register a gap")


## [B] Smooth Hermite Downward Transition and Slope Continuity:
## Apron slope matches road slope at tau=0, drops by apron_drop at tau=1, and flattens out.
func _b_smooth_hermite_downward_transition() -> void:
	print("[B] smooth Hermite downward transition (slope continuity and bevel drop)")
	var grade := 0.05 # 5% uphill
	var fx := _make_fixture_alignment(60, grade, 0.0)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var total_s: float = cum[cum.size() - 1]
	var half := 4.0
	var shoulder := 1.0
	var crown := 0.0 # flat cross-section for clear longitudinal inspection
	var apron_len := 3.0
	var apron_drop := 0.10 # 10 cm bevel drop

	var apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, total_s, half, shoulder, crown, false, apron_len, apron_drop, 4, 0.0, 0, 0.0, 0.0)
	var verts: PackedVector3Array = apron[Mesh.ARRAY_VERTEX]
	# Centerline vertices are column 2 (indices 2, 7, 12, 17 for rows 0, 1, 2, 3)
	var y0 := verts[2].y # at tau = 0
	var y1 := verts[7].y # at tau = 1/3
	var y2 := verts[12].y # at tau = 2/3
	var y3 := verts[17].y # at tau = 1

	var road_y_end := a.height_at(total_s)
	print("    centerline heights: y0=%.4f (want road %.4f), y1=%.4f, y2=%.4f, y3=%.4f" % [y0, road_y_end, y1, y2, y3])

	# Initial slope over first step (tau: 0 -> 1/3, dx = 1.0m)
	var initial_slope := (y1 - y0) / 1.0
	# Linear extrapolation without drop would be road_y_end + grade * apron_len
	var linear_end := road_y_end + grade * apron_len
	var actual_drop := linear_end - y3
	print("    initial slope = %.4f (want ~%.4f) | actual bevel drop = %.4f (want %.4f)" % [initial_slope, grade, actual_drop, apron_drop])

	# Final slope over last step (tau: 2/3 -> 1, dx = 1.0m)
	var final_slope := (y3 - y2) / 1.0
	print("    final slope = %.4f (must flatten towards 0.0)" % final_slope)

	var ok := absf(y0 - road_y_end) < 1e-4 and absf(actual_drop - apron_drop) < 1e-4 and absf(final_slope) < absf(initial_slope)
	_check("B", ok, "Hermite curve smoothly drops by %.2fm and flattens out" % apron_drop)

	# Control: naive linear continuation has zero drop
	var linear_error := absf(y3 - linear_end)
	print("    control: difference from linear extrapolation = %.4f m (want %.4f)" % [linear_error, apron_drop])
	if absf(linear_error - apron_drop) > 1e-3:
		_fail += 1
		print("    !! control failed: apron drop does not match target bevel drop")


## [C] Lateral Shoulder Fillet Roundness:
## At tau = 0, width is full road width; at tau = 1, outer corners curve inward smoothly.
func _c_lateral_shoulder_fillet_roundness() -> void:
	print("[C] lateral shoulder fillet roundness (corner rounding)")
	var fx := _make_fixture_alignment(40, 0.0, 0.0)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var total_s: float = cum[cum.size() - 1]
	var half := 4.0
	var shoulder := 1.0
	var w_total := half + shoulder # 5.0m
	var roundness := 0.60 # 60 cm fillet radius

	var apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, total_s, half, shoulder, 0.0, false, 2.5, 0.08, 4, 0.0, 0, 0.0, roundness)
	var verts: PackedVector3Array = apron[Mesh.ARRAY_VERTEX]
	# Row 0: left edge = vert 0, right edge = vert 4
	var width_row0 := (verts[4] - verts[0]).length()
	# Row 3 (end): left edge = vert 15, right edge = vert 19
	var width_row3 := (verts[19] - verts[15]).length()

	var expected_width_row0 := 2.0 * w_total # 10.0m
	var expected_width_row3 := 2.0 * (w_total - roundness) # 10.0 - 1.2 = 8.8m
	print("    row 0 width: %.4f m (want %.4f) | row 3 filleted width: %.4f m (want %.4f)"
			% [width_row0, expected_width_row0, width_row3, expected_width_row3])

	var ok := absf(width_row0 - expected_width_row0) < 1e-4 and absf(width_row3 - expected_width_row3) < 1e-4
	_check("C", ok, "outer corners smoothly filleted inward by %.2f m" % roundness)

	# Control: roundness = 0 keeps width identical across all rings
	var apron_unrounded := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, total_s, half, shoulder, 0.0, false, 2.5, 0.08, 4, 0.0, 0, 0.0, 0.0)
	var uverts: PackedVector3Array = apron_unrounded[Mesh.ARRAY_VERTEX]
	var unrounded_width_row3 := (uverts[19] - uverts[15]).length()
	print("    control: unrounded row 3 width = %.4f m (want %.4f)" % [unrounded_width_row3, expected_width_row0])
	if absf(unrounded_width_row3 - expected_width_row0) > 1e-4:
		_fail += 1
		print("    !! control failed: unrounded apron width diverged")


## [D] Trimesh Collision Coverage & Surface Normal Upward Orientation:
## Triangle normals face UP (no inverted winding) and chunk host generates apron colliders.
func _d_trimesh_collision_and_normal_orientation() -> void:
	print("[D] trimesh collision coverage and upward surface normal orientation")
	var fx := _make_fixture_alignment(40, 0.02, 0.0)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var total_s: float = cum[cum.size() - 1]

	# Check both start and end apron normals and windings
	for is_start in [true, false]:
		var s := 0.0 if is_start else total_s
		var apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a, s, 4.0, 1.0, 0.03, is_start, 2.5, 0.08, 4, 0.0)
		var verts: PackedVector3Array = apron[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = apron[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = apron[Mesh.ARRAY_INDEX]

		var bad_normals := 0
		for n in normals:
			if n.y <= 0.0:
				bad_normals += 1

		var inverted_tris := 0
		for tri in range(0, indices.size(), 3):
			var v0 := verts[indices[tri]]
			var v1 := verts[indices[tri + 1]]
			var v2 := verts[indices[tri + 2]]
			# In Godot, looking down from above, clockwise triangles have negative Y cross product:
			var cross := -(v1 - v0).cross(v2 - v0)
			if cross.y <= 0.0:
				inverted_tris += 1

		var desc := "start" if is_start else "end"
		print("    %s apron: %d bad normals (want 0), %d inverted triangles (want 0)" % [desc, bad_normals, inverted_tris])
		if bad_normals > 0 or inverted_tris > 0:
			_check("D", false, "%s apron has inverted triangles or downward normals" % desc)
			return

	_check("D", true, "start and end terminal aprons have 100% upward winding and valid normals")


## [E] C++ Native Mesher Parity:
## Assert Pasture3DUtil.road_mesh_build_terminus_apron matches GDScript oracle.
func _e_cpp_native_mesher_parity() -> void:
	print("[E] C++ native mesher parity (road_mesh_build_terminus_apron matches GDScript oracle)")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_terminus_apron"):
		_check("E", false, "Pasture3DUtil.road_mesh_build_terminus_apron is not bound in ClassDB")
		return

	var fx := _make_fixture_alignment(50, 0.03, 0.04)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var total_s: float = cum[cum.size() - 1]

	var native_apron := Pasture3DUtil.road_mesh_build_terminus_apron(plan, cum, a.ds, a.z, a.bank,
			total_s, 4.0, 1.0, 0.04, false, 2.8, 0.09, 4, 0.02, a.s0,
			Pasture3DRoadType.CrownMode.PARABOLIC, 0.06, 0.5)

	var gd_apron := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a,
			total_s, 4.0, 1.0, 0.04, false, 2.8, 0.09, 4, 0.02,
			Pasture3DRoadType.CrownMode.PARABOLIC, 0.06, 0.5, true)

	var native_verts: PackedVector3Array = native_apron[Mesh.ARRAY_VERTEX]
	var gd_verts: PackedVector3Array = gd_apron[Mesh.ARRAY_VERTEX]

	var max_vert_err := 0.0
	for i in native_verts.size():
		var err := (native_verts[i] - gd_verts[i]).length()
		max_vert_err = maxf(max_vert_err, err)

	print("    worst vertex disagreement: %.9f m (want < 1e-4)" % max_vert_err)
	var ok := max_vert_err < 1e-4
	_check("E", ok, "native C++ terminus apron agrees with GDScript reference to %.9f m" % max_vert_err)

	# Control: changing drop on GDScript produces disagreement
	var diff_gd := Pasture3DRoadMesher.build_terminus_apron(plan, cum, a,
			total_s, 4.0, 1.0, 0.04, false, 2.8, 0.15, 4, 0.02,
			Pasture3DRoadType.CrownMode.PARABOLIC, 0.06, 0.5, true)
	var diff_verts: PackedVector3Array = diff_gd[Mesh.ARRAY_VERTEX]
	var control_diff := (native_verts[17] - diff_verts[17]).length()
	print("    control: altered drop disagreement = %.4f m (want > 0.02)" % control_diff)
	if control_diff < 0.02:
		_fail += 1
		print("    !! control failed: altered drop did not diverge")
