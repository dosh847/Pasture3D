# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadDrivingSurfaceGate — Simcade Phase 1: Hybrid 3D Ribbon Driving Surface & Physics Telemetry.
# Gating:
#   [A] Coplanar Driving Surface (visual mesh and collision at lift = 0.0)
#   [B] Unconditional Bridge Collision (bridges carry 3D collision even if collision is globally disabled)
#   [C] Terrain Draped Mode (TERRAIN_DRAPED produces 0 ribbon meshes and 0 colliders)
#   [D] PhysicsMaterial and SurfaceInfo Metadata on Road Colliders
#   [E] Junction Apron Physics Telemetry (aprons carry PhysicsMaterial and pasture3d_surface metadata)
@tool
extends Node

const DS: float = 1.0

var _fail: int = 0
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadDrivingSurfaceGate: simcade driving surface and telemetry (Phase 1) ===\n")
	_a_coplanar_driving_surface()
	_b_unconditional_bridge_collision()
	_c_terrain_draped_mode()
	_d_physics_material_and_surface_metadata()
	_e_junction_apron_physics_telemetry()
	for c in CRITERIA:
		if not _reported.get(c, false):
			_fail += 1
			print("    !! criterion [%s] never reported (gate aborted early)" % c)
	print("\n=== %s (%d failures) ===\n" % ["DRIVING SURFACE PASS" if _fail == 0 else "DRIVING SURFACE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
		print("    FAIL [%s]: %s" % [p_name, p_detail])
	else:
		print("    PASS [%s]: %s" % [p_name, p_detail])


## [A] Coplanar Driving Surface: when depth_lift = 0.0, the rendered mesh vertices and
## collision vertices agree to within floating-point tolerance (0.0000 m).
func _a_coplanar_driving_surface() -> void:
	print("[A] coplanar driving surface (visual mesh matches collision at lift 0.0)")
	var plan := PackedVector2Array([Vector2(0, 0), Vector2(100, 0)])
	var cum := PackedFloat32Array([0.0, 100.0])
	var ground := PackedFloat32Array()
	ground.resize(101)
	ground.fill(10.0)
	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08)

	var drawn := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 50.0, 4.0, 1.0, 0.05, 0, 0.0)
	var col := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 50.0, 4.0, 1.0, 0.05, 0, 0.0)
	var d_verts: PackedVector3Array = drawn[Mesh.ARRAY_VERTEX]
	var c_verts: PackedVector3Array = col[Mesh.ARRAY_VERTEX]

	var max_diff := 0.0
	for i in mini(d_verts.size(), c_verts.size()):
		max_diff = maxf(max_diff, d_verts[i].distance_to(c_verts[i]))

	_check("A", d_verts.size() > 0 and max_diff < 1e-6,
			"visual mesh and collider match to %.9f m at lift 0.0" % max_diff)

	# Control: with non-zero lift (e.g. 0.02m), the visual mesh and collider differ.
	var lifted := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 50.0, 4.0, 1.0, 0.05, 0, 0.02)
	var l_verts: PackedVector3Array = lifted[Mesh.ARRAY_VERTEX]
	var lift_diff := 0.0
	for i in mini(l_verts.size(), c_verts.size()):
		lift_diff = maxf(lift_diff, absf(l_verts[i].y - c_verts[i].y))
	if absf(lift_diff - 0.02) > 1e-5:
		_fail += 1
		print("    control: lift_diff should be 0.02, got %.5f" % lift_diff)


func _make_brush_fixture(p_type: Pasture3DRoadType, p_bridge: bool = false) -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	add_child(terrain)

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	net.road_types = [p_type]

	var brush := Pasture3DRoadBrush.new()
	brush.name = "TestRoad"
	net.add_child(brush)
	brush.terrain = terrain
	brush.road_road_type = p_type

	if p_bridge:
		var seg := Pasture3DRoadSegment.new()
		seg.from_distance = 0.0
		seg.to_distance = 250.0
		seg.is_bridge = true
		brush.segments = [seg]

	var path := Path3D.new()
	var curve := Curve3D.new()
	for i in 6:
		curve.add_point(Vector3(float(i) * 40.0, 0.0, 0.0))
	path.curve = curve
	brush.add_child(path)

	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 2.0
	brush.modifiers = [road_mod]

	var plan := brush._plan_points()
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var total: float = cum[cum.size() - 1]
	var ds := 2.0
	var n_s := int(ceil(total / ds)) + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = ds
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	z.resize(n_s)
	bank.resize(n_s)
	for i in n_s:
		z[i] = 10.0
		bank[i] = 0.0
	a.z = z
	a.ground = z.duplicate()
	a.bank = bank
	a.curvature = Pasture3DRoadGrader._zeros(n_s)
	road_mod.last_alignment = a

	var host := Pasture3DRoadChunkHost.new()
	brush.add_child(host)
	return {"terrain": terrain, "net": net, "type": p_type, "brush": brush, "host": host, "mod": road_mod}


## [B] Unconditional Bridge Collision: A span with is_bridge = true generates solid collision
## even when collision_enabled is false globally on the host.
func _b_unconditional_bridge_collision() -> void:
	print("[B] unconditional bridge collision")
	var type := Pasture3DRoadType.new()
	type.surface_mode = Pasture3DRoadType.SurfaceMode.RIBBON_PHYSICS

	var fx := _make_brush_fixture(type, true)
	var host: Pasture3DRoadChunkHost = fx["host"]
	var brush: Pasture3DRoadBrush = fx["brush"]
	host.collision_enabled = false # Globally OFF

	var count := host.rebuild(brush)
	# Check that colliders were generated despite collision_enabled = false
	var found_bodies := 0
	for child in host.get_children():
		if child is MeshInstance3D:
			for sub in child.get_children():
				if sub is StaticBody3D:
					found_bodies += 1

	_check("B", count > 0 and found_bodies > 0,
			"bridge interval generated %d colliders with collision_enabled=false" % found_bodies)

	# Control: without is_bridge and collision_enabled = false, 0 colliders are built
	brush.segments = []
	host.rebuild(brush)
	var found_unbridged := 0
	for child in host.get_children():
		if child is MeshInstance3D:
			for sub in child.get_children():
				if sub is StaticBody3D:
					found_unbridged += 1
	if found_unbridged != 0:
		_fail += 1
		print("    control: unbridged road with collision_enabled=false should have 0 colliders, got %d" % found_unbridged)

	fx["terrain"].queue_free()


## [C] Terrain Draped Mode: RoadType with surface_mode = TERRAIN_DRAPED produces zero ribbon meshes
## and zero ribbon colliders.
func _c_terrain_draped_mode() -> void:
	print("[C] terrain draped mode produces zero ribbon meshes and colliders")
	var type := Pasture3DRoadType.new()
	type.surface_mode = Pasture3DRoadType.SurfaceMode.TERRAIN_DRAPED

	var fx := _make_brush_fixture(type, false)
	var host: Pasture3DRoadChunkHost = fx["host"]
	var brush: Pasture3DRoadBrush = fx["brush"]
	host.collision_enabled = true

	var count := host.rebuild(brush)
	var mesh_count := 0
	for child in host.get_children():
		if child is MeshInstance3D:
			mesh_count += 1

	_check("C", count == 0 and mesh_count == 0,
			"TERRAIN_DRAPED mode generated %d chunks / %d mesh instances (want 0)" % [count, mesh_count])

	# Control: switching back to RIBBON_PHYSICS generates chunks
	type.surface_mode = Pasture3DRoadType.SurfaceMode.RIBBON_PHYSICS
	var ribbon_count := host.rebuild(brush)
	if ribbon_count == 0:
		_fail += 1
		print("    control: RIBBON_PHYSICS should generate > 0 chunks, got 0")

	fx["terrain"].queue_free()


## [D] PhysicsMaterial and SurfaceInfo Metadata on Road Colliders.
func _d_physics_material_and_surface_metadata() -> void:
	print("[D] PhysicsMaterial and surface telemetry metadata on colliders")
	var info := Pasture3DSurfaceInfo.new()
	info.surface_id = &"racing_asphalt"
	info.friction_longitudinal = 1.25
	info.friction_lateral = 1.20
	info.rolling_resistance = 0.012
	info.audio_surface_type = &"race_tarmac"

	var type := Pasture3DRoadType.new()
	type.surface_mode = Pasture3DRoadType.SurfaceMode.RIBBON_PHYSICS
	type.surface_info = info

	var fx := _make_brush_fixture(type, false)
	var host: Pasture3DRoadChunkHost = fx["host"]
	var brush: Pasture3DRoadBrush = fx["brush"]
	host.collision_enabled = true

	host.rebuild(brush)

	var verified := false
	for child in host.get_children():
		if child is MeshInstance3D:
			for sub in child.get_children():
				if sub is StaticBody3D:
					var sb: StaticBody3D = sub
					var pm: PhysicsMaterial = sb.physics_material_override
					var has_meta := sb.has_meta(&"pasture3d_surface")
					var meta_info: Pasture3DSurfaceInfo = sb.get_meta(&"pasture3d_surface") if has_meta else null
					if pm != null and absf(pm.friction - 1.25) < 1e-4 and meta_info != null and meta_info.surface_id == &"racing_asphalt":
						verified = true
						break

	_check("D", verified, "collider has PhysicsMaterial (friction=1.25) and pasture3d_surface metadata")
	fx["terrain"].queue_free()


## [E] Junction Apron Physics Telemetry.
func _e_junction_apron_physics_telemetry() -> void:
	print("[E] junction apron physics telemetry")
	var host := Pasture3DRoadChunkHost.new()
	host.collision_enabled = true

	var info := Pasture3DSurfaceInfo.new()
	info.surface_id = &"junction_tarmac"
	info.friction_longitudinal = 1.10

	var spec := {
		"id": "J1",
		"center": Vector2(0, 0),
		"boundary": PackedVector2Array([Vector2(-10, -10), Vector2(10, -10), Vector2(10, 10), Vector2(-10, 10)]),
		"heights": PackedFloat32Array([5.0, 5.0, 5.0, 5.0]),
		"center_h": 5.0,
		"surface_info": info,
		"material": null,
	}

	host.rebuild_aprons([spec], 0.0)

	var verified_apron := false
	for child in host.get_children():
		if child is MeshInstance3D:
			for sub in child.get_children():
				if sub is StaticBody3D:
					var sb: StaticBody3D = sub
					var pm: PhysicsMaterial = sb.physics_material_override
					var meta_info: Pasture3DSurfaceInfo = sb.get_meta(&"pasture3d_surface") if sb.has_meta(&"pasture3d_surface") else null
					if pm != null and absf(pm.friction - 1.10) < 1e-4 and meta_info != null and meta_info.surface_id == &"junction_tarmac":
						verified_apron = true
						break

	_check("E", verified_apron, "apron collider carries PhysicsMaterial and surface_info metadata")
	host.queue_free()
