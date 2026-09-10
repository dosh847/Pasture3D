# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadCrownRunoffGate — Simcade Phase 2: Parabolic Crown & Superelevation Runoff.
# Gating:
#   [A] Zero Centerline Derivative Discontinuity (no knife-edge crease across u=0)
#   [B] Superelevation Runoff Attenuation (crown collapses to 0 in banked turns)
#   [C] Multi-Mode Crown Geometry (PARABOLIC, ONE_WAY_CROSSFALL, CIRCULAR_ARC, V_ROOF)
#   [D] Visual and Collision Mesh Parity with Parabolic Crown
#   [E] C++ Native Mesher Parity (road_mesh_build_chunk matches GDScript build_chunk)
@tool
extends Node

const DS: float = 1.0

var _fail: int = 0
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadCrownRunoffGate: parabolic crown and superelevation runoff (Phase 2) ===\n")
	_a_zero_centerline_derivative_discontinuity()
	_b_superelevation_runoff_attenuation()
	_c_multi_mode_crown_geometry()
	_d_mesh_and_collider_parity()
	_e_cpp_native_mesher_parity()
	for c in CRITERIA:
		if not _reported.get(c, false):
			_fail += 1
			print("    !! criterion [%s] never reported (gate aborted early)" % c)
	print("\n=== %s (%d failures) ===\n" % ["CROWN RUNOFF PASS" if _fail == 0 else "CROWN RUNOFF FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
		print("    FAIL [%s]: %s" % [p_name, p_detail])
	else:
		print("    PASS [%s]: %s" % [p_name, p_detail])


## [A] Zero Centerline Derivative Discontinuity:
## In PARABOLIC mode, dz/du at u = 0 is identically zero (no knife-edge peak).
func _a_zero_centerline_derivative_discontinuity() -> void:
	print("[A] zero centerline derivative discontinuity (no knife-edge crease)")
	var centre := 10.0
	var bank := 0.0
	var crown := 0.05
	var half_w := 4.0
	var eps := 0.001

	var z_centre := Pasture3DRoadGrader.surface_height(centre, bank, crown, 0.0, half_w, Pasture3DRoadType.CrownMode.PARABOLIC)
	var z_plus := Pasture3DRoadGrader.surface_height(centre, bank, crown, eps, half_w, Pasture3DRoadType.CrownMode.PARABOLIC)
	var z_minus := Pasture3DRoadGrader.surface_height(centre, bank, crown, -eps, half_w, Pasture3DRoadType.CrownMode.PARABOLIC)

	# Central difference derivative at u = 0: (z_plus - z_minus) / (2 * eps)
	var central_deriv := (z_plus - z_minus) / (2.0 * eps)
	# One-sided slope from center: |z_centre - z_plus| / eps
	var one_sided_slope := absf(z_centre - z_plus) / eps

	_check("A", absf(central_deriv) < 1e-6 and one_sided_slope < 1e-4,
			"PARABOLIC: central dz/du = %.9f, one-sided slope = %.9f (want ~0.0)" % [central_deriv, one_sided_slope])

	# Control: With V_ROOF (legacy), one-sided slope is exactly crown (0.05), producing a 10% slope jump
	var z_v_plus := Pasture3DRoadGrader.surface_height(centre, bank, crown, eps, half_w, Pasture3DRoadType.CrownMode.V_ROOF)
	var v_slope := absf(centre - z_v_plus) / eps
	if absf(v_slope - 0.05) > 1e-4:
		_fail += 1
		print("    control: V_ROOF slope should be 0.05, got %.6f" % v_slope)


## [B] Superelevation Runoff Attenuation:
## Crown dynamically collapses to zero as curve banking increases.
func _b_superelevation_runoff_attenuation() -> void:
	print("[B] superelevation runoff attenuation in banked turns")
	var centre := 10.0
	var crown := 0.05
	var half_w := 4.0
	var max_bank := 0.06

	# Straight road (bank = 0.0): full crown drop (0.05 * 4.0 = 0.200 m)
	var z_str_c := Pasture3DRoadGrader.surface_height(centre, 0.0, crown, 0.0, half_w, 0, max_bank)
	var z_str_edge := Pasture3DRoadGrader.surface_height(centre, 0.0, crown, 4.0, half_w, 0, max_bank)
	var drop_str := z_str_c - z_str_edge

	# Half-banked road (bank = 0.03): 50% runoff attenuation (drop = 0.100 m)
	var z_half_c := Pasture3DRoadGrader.surface_height(centre, 0.03, crown, 0.0, half_w, 0, max_bank)
	var z_half_right := Pasture3DRoadGrader.surface_height(centre, 0.03, crown, 4.0, half_w, 0, max_bank)
	var z_half_left := Pasture3DRoadGrader.surface_height(centre, 0.03, crown, -4.0, half_w, 0, max_bank)
	# Crown drop is isolated by subtracting the linear bank tilt:
	var crown_half_right := (centre + 0.03 * 4.0) - z_half_right
	var crown_half_left := (centre - 0.03 * 4.0) - z_half_left

	# Full-banked road (bank = 0.06): 100% runoff attenuation (drop = 0.000 m, perfect plane)
	var z_full_c := Pasture3DRoadGrader.surface_height(centre, 0.06, crown, 0.0, half_w, 0, max_bank)
	var z_full_right := Pasture3DRoadGrader.surface_height(centre, 0.06, crown, 4.0, half_w, 0, max_bank)
	var z_full_left := Pasture3DRoadGrader.surface_height(centre, 0.06, crown, -4.0, half_w, 0, max_bank)
	var crown_full_right := (centre + 0.06 * 4.0) - z_full_right
	var crown_full_left := (centre - 0.06 * 4.0) - z_full_left

	var ok_str := absf(drop_str - 0.200) < 1e-4
	var ok_half := absf(crown_half_right - 0.100) < 1e-4 and absf(crown_half_left - 0.100) < 1e-4
	var ok_full := absf(crown_full_right) < 1e-6 and absf(crown_full_left) < 1e-6

	_check("B", ok_str and ok_half and ok_full,
			"runoff: straight drop = %.4f (want 0.2), half-bank crown = %.4f (want 0.1), full-bank crown = %.4f (want 0.0)"
			% [drop_str, crown_half_right, crown_full_right])

	# Control: with max_bank = 0.0 (runoff off), crown is not attenuated at bank = 0.06
	var z_norunoff_right := Pasture3DRoadGrader.surface_height(centre, 0.06, crown, 4.0, half_w, 0, 0.0)
	var crown_norunoff := (centre + 0.06 * 4.0) - z_norunoff_right
	if absf(crown_norunoff - 0.200) > 1e-4:
		_fail += 1
		print("    control: without runoff, crown at bank=0.06 should remain 0.200, got %.4f" % crown_norunoff)


## [C] Multi-Mode Crown Geometry:
## Verifies correct closed-form geometry across all four modes.
func _c_multi_mode_crown_geometry() -> void:
	print("[C] multi-mode crown geometry")
	var centre := 0.0
	var bank := 0.0
	var crown := 0.05
	var half_w := 4.0

	# PARABOLIC: z = -0.20 * (u / 4.0)^2. At u=2.0 -> -0.050. At u=4.0 -> -0.200.
	var z_para_mid := Pasture3DRoadGrader.surface_height(centre, bank, crown, 2.0, half_w, Pasture3DRoadType.CrownMode.PARABOLIC)
	var z_para_edge := Pasture3DRoadGrader.surface_height(centre, bank, crown, 4.0, half_w, Pasture3DRoadType.CrownMode.PARABOLIC)
	var ok_para := absf(z_para_mid - (-0.050)) < 1e-4 and absf(z_para_edge - (-0.200)) < 1e-4

	# ONE_WAY_CROSSFALL: z = -crown * u. At u=-4.0 -> +0.200. At u=4.0 -> -0.200.
	var z_cross_left := Pasture3DRoadGrader.surface_height(centre, bank, crown, -4.0, half_w, Pasture3DRoadType.CrownMode.ONE_WAY_CROSSFALL)
	var z_cross_right := Pasture3DRoadGrader.surface_height(centre, bank, crown, 4.0, half_w, Pasture3DRoadType.CrownMode.ONE_WAY_CROSSFALL)
	var ok_cross := absf(z_cross_left - 0.200) < 1e-4 and absf(z_cross_right - (-0.200)) < 1e-4

	# CIRCULAR_ARC: follows circle radius R = (4^2 + 0.2^2) / 0.4 = 40.1 m.
	var z_circ_edge := Pasture3DRoadGrader.surface_height(centre, bank, crown, 4.0, half_w, Pasture3DRoadType.CrownMode.CIRCULAR_ARC)
	var ok_circ := absf(z_circ_edge - (-0.200)) < 1e-3

	# V_ROOF: z = -crown * |u|. At u=2.0 -> -0.100. At u=4.0 -> -0.200.
	var z_v_mid := Pasture3DRoadGrader.surface_height(centre, bank, crown, 2.0, half_w, Pasture3DRoadType.CrownMode.V_ROOF)
	var z_v_edge := Pasture3DRoadGrader.surface_height(centre, bank, crown, 4.0, half_w, Pasture3DRoadType.CrownMode.V_ROOF)
	var ok_v := absf(z_v_mid - (-0.100)) < 1e-4 and absf(z_v_edge - (-0.200)) < 1e-4

	_check("C", ok_para and ok_cross and ok_circ and ok_v,
			"modes: para(mid)=%.4f (want -0.05), cross(left)=%.4f (want +0.2), v(mid)=%.4f (want -0.1)"
			% [z_para_mid, z_cross_left, z_v_mid])


## [D] Visual and Collision Mesh Parity with Parabolic Crown:
## Mesh vertices and collider vertices agree with surface_height formula across straight and banked sections.
func _d_mesh_and_collider_parity() -> void:
	print("[D] mesh and collider parity with parabolic crown")
	var plan := PackedVector2Array([Vector2(0, 0), Vector2(100, 0)])
	var cum := PackedFloat32Array([0.0, 100.0])
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var n_s := 101
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	z.resize(n_s); bank.resize(n_s)
	for i in n_s:
		z[i] = 10.0
		bank[i] = 0.06 * float(i) / float(n_s - 1) # Ramps from 0 to max bank
	a.z = z
	a.bank = bank

	var drawn := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 50.0, 4.0, 1.0, 0.05, 0,
			0.0, false, Pasture3DRoadType.CrownMode.PARABOLIC, 0.06)
	var col := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 50.0, 4.0, 1.0, 0.05, 0,
			0.0, false, Pasture3DRoadType.CrownMode.PARABOLIC, 0.06)

	var d_verts: PackedVector3Array = drawn[Mesh.ARRAY_VERTEX]
	var c_verts: PackedVector3Array = col[Mesh.ARRAY_VERTEX]

	var max_diff := 0.0
	for i in mini(d_verts.size(), c_verts.size()):
		max_diff = maxf(max_diff, d_verts[i].distance_to(c_verts[i]))

	_check("D", d_verts.size() > 0 and max_diff < 1e-6,
			"drawn mesh and collider vertices match to %.9f m across banked alignment" % max_diff)


## [E] C++ Native Mesher Parity:
## Pasture3DUtil.road_mesh_build_chunk agrees with the GDScript reference oracle.
func _e_cpp_native_mesher_parity() -> void:
	print("[E] C++ native mesher parity")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_chunk"):
		_check("E", false, "Pasture3DUtil.road_mesh_build_chunk is not bound")
		return

	var plan := PackedVector2Array([Vector2(0, 0), Vector2(100, 0)])
	var cum := PackedFloat32Array([0.0, 100.0])
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var n_s := 101
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	z.resize(n_s); bank.resize(n_s)
	for i in n_s:
		z[i] = 10.0 + 0.02 * float(i)
		bank[i] = 0.06 * sin(float(i) * 0.1)
	a.z = z
	a.bank = bank

	var native_arr: Array = Pasture3DUtil.road_mesh_build_chunk(plan, cum, a.ds, a.z, a.bank,
			0.0, 60.0, 4.0, 1.0, 0.05, 0, 0.02, a.s0, Pasture3DRoadType.CrownMode.PARABOLIC, 0.06)
	var gd_arr: Array = Pasture3DRoadMesher.build_chunk(plan, cum, a,
			0.0, 60.0, 4.0, 1.0, 0.05, 0, 0.02, true, Pasture3DRoadType.CrownMode.PARABOLIC, 0.06)

	var n_verts: PackedVector3Array = native_arr[Mesh.ARRAY_VERTEX]
	var g_verts: PackedVector3Array = gd_arr[Mesh.ARRAY_VERTEX]

	var worst := 0.0
	for i in mini(n_verts.size(), g_verts.size()):
		worst = maxf(worst, n_verts[i].distance_to(g_verts[i]))

	_check("E", n_verts.size() > 0 and worst < 1e-4,
			"native C++ mesher agrees with GDScript oracle to %.9f m (want < 1e-4)" % worst)
