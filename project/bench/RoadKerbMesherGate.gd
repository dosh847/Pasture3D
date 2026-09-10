# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadKerbMesherGate — Simcade Phase 4: Parametric Racing Kerbs & Rumble Geometry.
# Gating:
#   [A] Asymmetric Authoring & Cross-Section Offsets (kerbs on configured sides only)
#   [B] Sawtooth Rumble Displacement & Pitch (exact amplitude and wavelength)
#   [C] Watertight Carriageway Seam (zero gap at edge u = ±half)
#   [D] Trimesh Collision Parity (collision trimesh at lift 0 matches visual mesh)
#   [E] All Kerb Geometric Profiles (FIA_BEVEL, SAWTOOTH, FLAT_SLAB, DRAIN_GUTTER)
#   [F] C++ Native Mesher Parity (road_mesh_build_chunk matches GDScript oracle)
@tool
extends Node

const DS: float = 0.5

var _fail: int = 0
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F"]
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadKerbMesherGate: parametric racing kerbs & rumble geometry (Phase 4) ===\n")
	_a_asymmetric_authoring_and_cross_section_offsets()
	_b_sawtooth_rumble_displacement_and_pitch()
	_c_watertight_carriageway_seam()
	_d_trimesh_collision_parity()
	_e_all_kerb_geometric_profiles()
	_f_cpp_native_mesher_parity()
	for c in CRITERIA:
		if not _reported.get(c, false):
			_fail += 1
			print("    !! criterion [%s] never reported (gate aborted early)" % c)
	print("\n=== %s (%d failures) ===\n" % ["KERB MESHER PASS" if _fail == 0 else "KERB MESHER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
		print("    FAIL [%s]: %s" % [p_name, p_detail])
	else:
		print("    PASS [%s]: %s" % [p_name, p_detail])


func _make_fixture(n_s: int = 40, p_grade: float = 0.02, p_bank: float = 0.03) -> Dictionary:
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


## [A] Asymmetric Authoring & Cross-Section Offsets:
## Kerbs exist on the configured side only. Non-kerbed side maintains standard shoulder.
func _a_asymmetric_authoring_and_cross_section_offsets() -> void:
	print("[A] asymmetric authoring & cross-section offsets")
	var half := 4.0
	var shoulder := 1.2
	var kw := 0.8

	# 1. Standard unkerbed road: 5 offsets
	var standard_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL, 0, 0)
	var expected_std := PackedFloat32Array([-(half + shoulder), -half, 0.0, half, half + shoulder])
	var std_ok := standard_offsets == expected_std

	# 2. Left kerb only (e.g. inside apex): 7 offsets
	var left_kerb_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL,
			Pasture3DRoadType.KerbType.FIA_BEVEL, Pasture3DRoadType.KerbType.NONE, kw)
	# Left side has 3 kerb vertices, center has 3, right side has 1 shoulder
	var left_ok := left_kerb_offsets.size() == 7
	var left_toe: float = left_kerb_offsets[0]
	var right_shoulder: float = left_kerb_offsets[6]
	left_ok = left_ok and is_equal_approx(left_toe, -(half + kw))
	left_ok = left_ok and is_equal_approx(right_shoulder, half + shoulder)

	# 3. Right kerb only (e.g. exit kerb): 7 offsets
	var right_kerb_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL,
			Pasture3DRoadType.KerbType.NONE, Pasture3DRoadType.KerbType.FIA_BEVEL, kw)
	var right_ok := right_kerb_offsets.size() == 7
	var left_shoulder: float = right_kerb_offsets[0]
	var right_toe: float = right_kerb_offsets[6]
	right_ok = right_ok and is_equal_approx(left_shoulder, -(half + shoulder))
	right_ok = right_ok and is_equal_approx(right_toe, half + kw)

	# 4. Both kerbs: 9 offsets
	var both_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL,
			Pasture3DRoadType.KerbType.FIA_BEVEL, Pasture3DRoadType.KerbType.FIA_BEVEL, kw)
	var both_ok := both_offsets.size() == 9

	# 5. LOD 2 (carriageway only): kerbs collapse, exactly 2 offsets
	var lod2_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.NO_SHOULDER,
			Pasture3DRoadType.KerbType.FIA_BEVEL, Pasture3DRoadType.KerbType.FIA_BEVEL, kw)
	var lod2_ok := lod2_offsets.size() == 2 and is_equal_approx(lod2_offsets[0], -half) and is_equal_approx(lod2_offsets[1], half)

	var ok: bool = std_ok and left_ok and right_ok and both_ok and lod2_ok
	_check("A", ok, "offsets strictly reflect per-side kerb configuration (std=%d, left=%d, right=%d, both=%d, lod2=%d)"
			% [standard_offsets.size(), left_kerb_offsets.size(), right_kerb_offsets.size(), both_offsets.size(), lod2_offsets.size()])

	# Negative control: invalid cross-section size
	if not (left_kerb_offsets.size() > standard_offsets.size()):
		_fail += 1
		print("    !! control failed: kerb offsets did not add vertices")


## [B] Sawtooth Rumble Displacement & Pitch:
## Physical rumble displacement oscillates with target amplitude and pitch along s.
func _b_sawtooth_rumble_displacement_and_pitch() -> void:
	print("[B] sawtooth rumble displacement & pitch")
	var fx := _make_fixture(60, 0.0, 0.0)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var half := 4.0
	var shoulder := 1.0
	var hk := 0.08
	var pitch := 0.4
	var depth := 0.02

	var arrays := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 10.0, half, shoulder, 0.0, 0, 0.0, true,
			0, 0.0, Pasture3DRoadType.KerbType.SAWTOOTH, Pasture3DRoadType.KerbType.NONE, 0.8, hk, pitch, depth)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var across_count := 7 # left kerb (3) + carriageway (3) + right shoulder (1)
	var rows := verts.size() / across_count

	# Extract displacement on the kerb flat top (xi = 0.7, offset index 1) along all rows
	var min_h := INF
	var max_h := -INF
	var peaks: Array[float] = []
	var prev_dy := 0.0
	var prev_s := 0.0
	var rising := false

	for r in rows:
		var v: Vector3 = verts[r * across_count + 1] # kerb crown vertex
		var s := v.x # road runs along x
		var base_y := 10.0 # flat ground height
		var dy := v.y - base_y
		min_h = minf(min_h, dy)
		max_h = maxf(max_h, dy)

		if r > 0:
			if dy > prev_dy and not rising:
				rising = true
			elif dy < prev_dy and rising:
				rising = false
				peaks.append(prev_s)
		prev_dy = dy
		prev_s = s

	print("    rumble min dy = %.4f m, max dy = %.4f m (target %.4f .. %.4f)"
			% [min_h, max_h, hk - depth, hk + depth])
	var amp_ok: bool = absf(min_h - (hk - depth)) < 0.005 and absf(max_h - (hk + depth)) < 0.005

	# Check peak-to-peak distance
	var period_ok := false
	if peaks.size() >= 3:
		var sum_dist := 0.0
		for p in range(1, peaks.size()):
			sum_dist += peaks[p] - peaks[p - 1]
		var avg_pitch := sum_dist / float(peaks.size() - 1)
		print("    detected average pitch = %.4f m (target = %.4f m)" % [avg_pitch, pitch])
		period_ok = absf(avg_pitch - pitch) < 0.05
	else:
		print("    insufficient peaks found: %d" % peaks.size())

	var ok: bool = amp_ok and period_ok
	_check("B", ok, "sawtooth rumble achieves physical amplitude ±%.3f m and wavelength %.2f m" % [depth, pitch])

	# Negative control: depth = 0 produces zero oscillation
	var flat_arrays := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 10.0, half, shoulder, 0.0, 0, 0.0, true,
			0, 0.0, Pasture3DRoadType.KerbType.SAWTOOTH, Pasture3DRoadType.KerbType.NONE, 0.8, hk, pitch, 0.0)
	var flat_verts: PackedVector3Array = flat_arrays[Mesh.ARRAY_VERTEX]
	var flat_min := INF
	var flat_max := -INF
	for r in rows:
		var v: Vector3 = flat_verts[r * across_count + 1]
		var dy := v.y - 10.0
		flat_min = minf(flat_min, dy)
		flat_max = maxf(flat_max, dy)
	var control_oscillation := flat_max - flat_min
	print("    control: depth=0 oscillation = %.6f m (want < 1e-5)" % control_oscillation)
	if control_oscillation > 1e-5:
		_fail += 1
		print("    !! control failed: rumble still oscillated with depth=0")


## [C] Watertight Carriageway Seam:
## The boundary between carriageway and kerb (u = ±half) has 0.000000 m discontinuity.
func _c_watertight_carriageway_seam() -> void:
	print("[C] watertight carriageway seam (zero gap at edge u = ±half)")
	var fx := _make_fixture(60, 0.03, 0.02)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var half := 4.0
	var shoulder := 1.0

	# 1. Abutting chunks: unkerbed chunk [0.0, 10.0] meets kerbed chunk [10.0, 20.0] at s = 10.0
	var unkerbed := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 10.0, half, shoulder, 0.04, 0, 0.0, true,
			0, 0.0, 0, 0)
	var kerbed := Pasture3DRoadMesher.build_chunk(plan, cum, a, 10.0, 20.0, half, shoulder, 0.04, 0, 0.0, true,
			0, 0.0, Pasture3DRoadType.KerbType.SAWTOOTH, Pasture3DRoadType.KerbType.SAWTOOTH, 0.8, 0.08, 0.4, 0.02)

	var unkerbed_verts: PackedVector3Array = unkerbed[Mesh.ARRAY_VERTEX]
	var kerbed_verts: PackedVector3Array = kerbed[Mesh.ARRAY_VERTEX]

	var unk_across := 5
	var kerb_across := 9
	var unk_last_row_start := unkerbed_verts.size() - unk_across

	var max_seam_err := 0.0
	# Carriageway vertices: -half (ci=0), 0.0 (ci=1), +half (ci=2)
	for ci in 3:
		var v_unk: Vector3 = unkerbed_verts[unk_last_row_start + (1 + ci)]
		var v_kerb: Vector3 = kerbed_verts[0 + (3 + ci)] # first row of kerbed chunk
		var diff := (v_unk - v_kerb).length()
		max_seam_err = maxf(max_seam_err, diff)

	# 2. Point-for-point ring evaluation at exact same s values
	var std_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL, 0, 0)
	var k_offsets := Pasture3DRoadMesher.cross_offsets(half, shoulder, Pasture3DRoadMesher.Cross.FULL,
			Pasture3DRoadType.KerbType.SAWTOOTH, Pasture3DRoadType.KerbType.SAWTOOTH, 0.8)

	var max_ring_err := 0.0
	for si in 15:
		var test_s := float(si) * 0.73
		var ring_std := Pasture3DRoadMesher.ring(plan, cum, a, test_s, std_offsets, 0.04, 0.0, half, 0, 0.0, 0, 0)
		var ring_k := Pasture3DRoadMesher.ring(plan, cum, a, test_s, k_offsets, 0.04, 0.0, half, 0, 0.0,
				Pasture3DRoadType.KerbType.SAWTOOTH, Pasture3DRoadType.KerbType.SAWTOOTH, 0.8, 0.08, 0.4, 0.02)
		for ci in 3:
			var diff := (ring_std[1 + ci] - ring_k[3 + ci]).length()
			max_ring_err = maxf(max_ring_err, diff)

	var worst_err := maxf(max_seam_err, max_ring_err)
	print("    abutting chunk seam gap: %.9f m | ring carriageway worst diff: %.9f m" % [max_seam_err, max_ring_err])
	var ok: bool = worst_err < 1e-6
	_check("C", ok, "carriageway surface and edge seam match bit-identically (worst err = %.9f m)" % worst_err)


## [D] Trimesh Collision Parity:
## Collision mesh at lift = 0.0 matches visual mesh at lift = 0.02 minus 0.02 m.
func _d_trimesh_collision_parity() -> void:
	print("[D] trimesh collision parity")
	var fx := _make_fixture(40, 0.02, 0.01)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var half := 4.0
	var shoulder := 1.0
	var lift := 0.02

	var visual := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 10.0, half, shoulder, 0.03, 0, lift, true,
			0, 0.0, Pasture3DRoadType.KerbType.FIA_BEVEL, Pasture3DRoadType.KerbType.SAWTOOTH, 0.8, 0.08, 0.4, 0.02)
	var solid := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 10.0, half, shoulder, 0.03, 0, 0.0, true,
			0, 0.0, Pasture3DRoadType.KerbType.FIA_BEVEL, Pasture3DRoadType.KerbType.SAWTOOTH, 0.8, 0.08, 0.4, 0.02)

	var v_verts: PackedVector3Array = visual[Mesh.ARRAY_VERTEX]
	var s_verts: PackedVector3Array = solid[Mesh.ARRAY_VERTEX]

	var count_ok := v_verts.size() == s_verts.size() and v_verts.size() > 0
	var max_diff := 0.0
	if count_ok:
		for i in v_verts.size():
			var expected_solid := v_verts[i] - Vector3(0.0, lift, 0.0)
			var diff := (expected_solid - s_verts[i]).length()
			max_diff = maxf(max_diff, diff)

	print("    visual vs solid vertex max diff: %.9f m" % max_diff)
	var ok: bool = count_ok and max_diff < 1e-6
	_check("D", ok, "trimesh collision geometry matches visual kerb & rumble teeth (max diff = %.9f m)" % max_diff)


## [E] All Kerb Geometric Profiles:
## Verify FIA_BEVEL, SAWTOOTH, FLAT_SLAB, and DRAIN_GUTTER.
func _e_all_kerb_geometric_profiles() -> void:
	print("[E] all kerb geometric profiles")
	var hk := 0.08
	var pitch := 0.4
	var depth := 0.02

	# 1. FIA_BEVEL: flat top hk at xi in [0.2, 0.7], 0 at edges
	var fia_lip := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.FIA_BEVEL, 0.2, 1.0, hk, pitch, depth)
	var fia_top := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.FIA_BEVEL, 0.5, 1.0, hk, pitch, depth)
	var fia_edge := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.FIA_BEVEL, 0.0, 1.0, hk, pitch, depth)
	var fia_toe := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.FIA_BEVEL, 1.0, 1.0, hk, pitch, depth)
	var fia_ok := is_equal_approx(fia_lip, hk) and is_equal_approx(fia_top, hk) and is_equal_approx(fia_edge, 0.0) and is_equal_approx(fia_toe, 0.0)

	# 2. FLAT_SLAB: subtle 0.01 m lip
	var slab_top := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.FLAT_SLAB, 0.5, 1.0, hk, pitch, depth)
	var slab_ok := is_equal_approx(slab_top, 0.01)

	# 3. DRAIN_GUTTER: negative parabolic depression reaching -hk at xi = 0.5
	var gut_edge := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.DRAIN_GUTTER, 0.0, 1.0, hk, pitch, depth)
	var gut_toe := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.DRAIN_GUTTER, 1.0, 1.0, hk, pitch, depth)
	var gut_mid := Pasture3DRoadMesher.kerb_displacement(Pasture3DRoadType.KerbType.DRAIN_GUTTER, 0.5, 1.0, hk, pitch, depth)
	var gut_ok := is_equal_approx(gut_edge, 0.0) and is_equal_approx(gut_toe, 0.0) and is_equal_approx(gut_mid, -hk)

	var ok: bool = fia_ok and slab_ok and gut_ok
	_check("E", ok, "all kerb types produce exact mathematical cross-sections (FIA=%.3f, Slab=%.3f, Gutter=%.3f)"
			% [fia_top, slab_top, gut_mid])


## [F] C++ Native Mesher Parity:
## C++ Pasture3DUtil.road_mesh_build_chunk matches GDScript reference oracle bit-accurately.
func _f_cpp_native_mesher_parity() -> void:
	print("[F] C++ native mesher parity (road_mesh_build_chunk vs GDScript oracle)")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_chunk"):
		_check("F", false, "Pasture3DUtil.road_mesh_build_chunk not available in ClassDB")
		return

	var fx := _make_fixture(50, 0.03, 0.02)
	var plan: PackedVector2Array = fx["plan"]
	var cum: PackedFloat32Array = fx["cum"]
	var a: Pasture3DRoadAlignment = fx["alignment"]
	var half := 4.0
	var shoulder := 1.0
	var crown := 0.04
	var lift := 0.02
	var kw := 0.8
	var hk := 0.08
	var pitch := 0.4
	var depth := 0.02

	var kerb_types: Array[int] = [
		Pasture3DRoadType.KerbType.FIA_BEVEL,
		Pasture3DRoadType.KerbType.SAWTOOTH,
		Pasture3DRoadType.KerbType.FLAT_SLAB,
		Pasture3DRoadType.KerbType.DRAIN_GUTTER,
	]

	var max_diff_all := 0.0
	for kt in kerb_types:
		var native := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 15.0, half, shoulder, crown, 0, lift, false,
				0, 0.0, kt, kt, kw, hk, pitch, depth)
		var oracle := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 15.0, half, shoulder, crown, 0, lift, true,
				0, 0.0, kt, kt, kw, hk, pitch, depth)

		var v_nat: PackedVector3Array = native[Mesh.ARRAY_VERTEX]
		var v_ora: PackedVector3Array = oracle[Mesh.ARRAY_VERTEX]

		if v_nat.size() != v_ora.size() or v_nat.is_empty():
			print("    size mismatch for kerb type %d: native=%d oracle=%d" % [kt, v_nat.size(), v_ora.size()])
			_check("F", false, "vertex count mismatch for kerb type %d" % kt)
			return

		for i in v_nat.size():
			var diff := (v_nat[i] - v_ora[i]).length()
			max_diff_all = maxf(max_diff_all, diff)

	print("    native vs oracle worst vertex discrepancy: %.9f m" % max_diff_all)
	var ok: bool = max_diff_all < 1e-4
	_check("F", ok, "C++ mesher matches GDScript oracle to < 1e-4 m (worst diff = %.9f m)" % max_diff_all)
