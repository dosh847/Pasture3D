# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadInteractivePerfGate — Interactive Editor Point Move & Cascade Suppression Performance Gate (P11).
# Gating Criteria A through D from PASTURE3D_ROAD_INTERACTIVE_PERF_SPEC.md §5.
@tool
extends Node

const CRITERIA: Array[String] = ["[A]", "[B]", "[C]", "[D]"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadInteractivePerfGate: interactive point move & cascade suppression (P11) ===\n")
	await _run_gate()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["ROAD INTERACTIVE PERF PASS" if _fail == 0 else "ROAD INTERACTIVE PERF FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


func _run_gate() -> void:
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		_check("[A]", false, "Failed to load demo_road_network.tscn")
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	await get_tree().process_frame

	var net: Pasture3DRoadNetwork = scene.find_child("Pasture3DRoadNetwork", true, false)
	if net == null:
		_check("[A]", false, "Pasture3DRoadNetwork not found in demo scene")
		scene.queue_free()
		return

	var terrain: Pasture3D = scene.find_child("Pasture3D", true, false)
	if terrain != null:
		terrain.data_directory = "user://road_interactive_perf_gate"

	var brushes: Array = net.road_brushes()

	# 1. Warm-up: Cold build of junction surfaces
	var t_warm0: int = Time.get_ticks_usec()
	var initial_aprons: int = net.build_junction_surfaces(brushes)
	var t_warm1: int = Time.get_ticks_usec()
	var cold_apron_ms: float = (t_warm1 - t_warm0) / 1000.0

	for b: Pasture3DRoadBrush in brushes:
		b.last_junction_digest = b.junction_digest()

	# ---- [B] Apron Rebuild Caching -----------------------------------------------------------------
	# A second build on unchanged network must be served from cache in under 10.0 ms (target < 1.0 ms)
	# rather than re-evaluating footprints and rebuilding ArrayMeshes / colliders.
	var t_cache0: int = Time.get_ticks_usec()
	var cached_aprons: int = net.build_junction_surfaces(brushes)
	var t_cache1: int = Time.get_ticks_usec()
	var warm_apron_ms: float = (t_cache1 - t_cache0) / 1000.0

	var host: Pasture3DRoadChunkHost = net.ensure_junction_host()
	var host_apron_count: int = host._apron_chunks.size() if host != null else 0
	_check("[B]", warm_apron_ms < 10.0 and cached_aprons == initial_aprons and host_apron_count > 0,
			"apron caching: %.2f ms for %d aprons (cold was %.2f ms, host has %d active chunks, want < 10 ms)" % [
				warm_apron_ms, cached_aprons, cold_apron_ms, host_apron_count
			])

	# ---- [A] Synchronous Point-Move Execution Time ------------------------------------------------
	# Locate Road3 and move a control point by 0.5m in X and Z
	var road3: Pasture3DRoadBrush = null
	for b: Pasture3DRoadBrush in brushes:
		if b.name == "Road3":
			road3 = b
			break

	if road3 == null or road3._get_splines().is_empty():
		_check("[A]", false, "Road3 spline not found in demo network")
		scene.queue_free()
		return

	var r3_spline: Path3D = road3._get_splines()[0]
	var pt_pos: Vector3 = r3_spline.curve.get_point_position(1)
	r3_spline.curve.set_point_position(1, pt_pos + Vector3(0.5, 0.0, 0.5))

	var t_sync_0: int = Time.get_ticks_usec()

	# Stage 1: Owner rect refresh (layer clearing + road painting)
	var t_ref0: int = Time.get_ticks_usec()
	road3._refresh_owner_rect("roads", { r3_spline.get_instance_id(): true })
	var t_ref1: int = Time.get_ticks_usec()

	# Stage 2: Junction solver resolve
	var t_sol0: int = Time.get_ticks_usec()
	var runs: Array = []
	for b in brushes:
		if b != null and b.has_method("build_run"):
			var run: Dictionary = b.build_run()
			if not run.is_empty():
				runs.append(run)
	var _juncs := Pasture3DRoadJunctionSolver.resolve(runs, net.junctions,
			{"default_corner_radius": net.default_corner_radius})
	var t_sol1: int = Time.get_ticks_usec()

	# Stage 3: Lane graph resolve
	var t_lane0: int = Time.get_ticks_usec()
	net._resolve_lane_graphs(brushes)
	var t_lane1: int = Time.get_ticks_usec()

	# Stage 4: Surface paint
	var t_paint0: int = Time.get_ticks_usec()
	net.paint_roads(brushes)
	var t_paint1: int = Time.get_ticks_usec()

	# Stage 5: Mesh chunk rebuild & apron rebuild
	var t_mesh0: int = Time.get_ticks_usec()
	for b: Pasture3DRoadBrush in brushes:
		b.rebuild_chunks(net.ribbon_lift)
	net.build_junction_surfaces(brushes)
	var t_mesh1: int = Time.get_ticks_usec()

	var t_sync_1: int = Time.get_ticks_usec()
	var total_sync_ms: float = (t_sync_1 - t_sync_0) / 1000.0

	_check("[A]", total_sync_ms < 200.0,
			"total synchronous edit latency %.2f ms (want < 200 ms, baseline was 1013 ms) [refresh: %.1f ms, solver: %.1f ms, lane: %.1f ms, paint: %.1f ms, mesh: %.1f ms]" % [
				total_sync_ms,
				(t_ref1 - t_ref0) / 1000.0,
				(t_sol1 - t_sol0) / 1000.0,
				(t_lane1 - t_lane0) / 1000.0,
				(t_paint1 - t_paint0) / 1000.0,
				(t_mesh1 - t_mesh0) / 1000.0,
			])

	# ---- [C] Follow-Up Cascade Rebake Suppression -------------------------------------------------
	# Untouched partner roads (Road, Road1, Road2) must NOT change their junction digest,
	# preventing secondary frame freeze ping-pong.
	var partner_mismatches: Array[String] = []
	for b: Pasture3DRoadBrush in brushes:
		if b.name == "Road3":
			continue # Road3 was edited, so its digest changes expectedly
		var curr_d: String = b.junction_digest()
		var prev_d: String = b.last_junction_digest
		if curr_d != prev_d:
			partner_mismatches.append(b.name)

	_check("[C]", partner_mismatches.is_empty(),
			"partner roads with cascading digest changes: %d (%s) (want 0, baseline was 3 cascading roads)" % [
				partner_mismatches.size(),
				", ".join(partner_mismatches) if not partner_mismatches.is_empty() else "none"
			])

	# ---- [D] Apron Geometry & Collision Integrity -------------------------------------------------
	# Verify that apron meshes, markings, and colliders were retained / generated correctly
	var valid_nodes: int = 0
	var valid_colliders: int = 0
	if host != null:
		for jid in host._apron_chunks.keys():
			var ch: Dictionary = host._apron_chunks[jid]
			var mi: Node = ch.get("node")
			if is_instance_valid(mi) and mi is MeshInstance3D:
				var m: Mesh = (mi as MeshInstance3D).mesh
				if m != null and m.get_surface_count() > 0:
					valid_nodes += 1
				if mi.has_node("Collision"):
					valid_colliders += 1

	var geom_ok: bool = (valid_nodes == host_apron_count and valid_nodes > 0)
	_check("[D]", geom_ok,
			"apron integrity: %d/%d valid mesh instances, %d colliders (all non-empty)" % [
				valid_nodes, host_apron_count, valid_colliders
			])

	# Clean up demo instance
	if is_instance_valid(r3_spline) and r3_spline.curve != null:
		r3_spline.curve.set_point_position(1, pt_pos)
	scene.queue_free()
