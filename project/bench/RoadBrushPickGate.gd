# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadBrushPickGate — the three defects that made a ROAD brush's spline points unusable while the same
# points on a Mound or a Ridge worked. All three follow from the road being the only brush with a
# SURFACE you can click, and all three were found by probe rather than by reading.
#
# [RA] A control point must beat another road's ribbon. `Pasture3DRoadBrush.pick_brush_screen_distance`
#      delegated straight to `pick_road_screen_distance`, which measures the ribbon and never tests the
#      control points — throwing away the first thing the base class does. Since
#      `Pasture3DEditorPlugin._pick_brush_screen` compares that one number across every brush in the
#      scene and takes the smallest, a road answering 0.0 anywhere along itself tied with every control
#      point in the scene, and the tie went to whichever brush the group listed first. Clicking your own
#      point selected the road crossing underneath it.
#
# [RB] The `Chunks` host must not read as a structural edit. It is created lazily from the GIZMO's
#      `_redraw` and carried no INTERNAL_CHILD_META, so the first time a road's gizmo drew, the new child
#      fired `_on_child_changed` and scheduled a FULL-layer rebake.
#
# [RC] Removing or reshaping a point must not need a terrain. The plugin gated ALL point input on
#      `p_brush.terrain` being live, but only the Ctrl-click ADD raycasts a surface. `terrain` is
#      auto-assigned from the first Pasture3D ANCESTOR, so a road under a Pasture3DRoadNetwork that sits
#      beside the terrain rather than inside it never has one — points drawn, none of them editable.
#
# [RD] ...and once they WERE editable, DRAGGING one crashed. Lifting that gate let the drag reach
#      `brush_gizmo._set_subgizmo_transform`, which asks `_base_height_below` for the ground under the
#      new position whenever `snap_to_surface` is on — and that helper dereferenced `terrain.data` with
#      no guard, on a brush that by construction has no terrain. The caller was already written for a
#      non-finite answer; the helper simply never gave it one. A regression created by the [RC] fix.
#
# WHAT THIS GATE CANNOT SAY. [RC] measures the brush-side CAPABILITY the plugin was refusing to use, not
# the plugin branch itself: `_forward_brush_input` needs `EditorInterface` and a viewport camera, so the
# editor-only half of that fix is covered by reading and a parse-check, nothing more. Said here rather
# than left for someone to assume otherwise.
#
# House discipline (bench/PlowReliefCheck.gd): every criterion carries a CONTROL that must fail if the
# path is dead, and `_completed` counts criteria so a crash reports "measured nothing".
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RoadBrushPickGate.tscn
@tool
extends Node

const EXPECTED: int = 4

var _fail: int = 0
var _completed: int = 0
var _root: Node3D


func _ready() -> void:
	print("=== RoadBrushPickGate: a road's points, against its own surface ===\n")
	_root = Node3D.new()
	add_child(_root)
	_ra_point_beats_ribbon()
	_rb_chunk_host_is_not_a_structural_edit()
	_rc_point_edits_need_no_terrain()
	_rd_snap_query_survives_no_terrain()
	var ok := _fail == 0 and _completed == EXPECTED
	print("\n=== %s (%d failures, %d/%d criteria reported) ===\n" % [
		"ROAD BRUSH PICK PASS" if ok else "ROAD BRUSH PICK FAIL", _fail, _completed, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["    " if p_ok else "!!  ", p_name, p_detail])


## A road brush with one spline through `p_pts`.
func _road(p_name: String, p_pts: Array) -> Array:
	var r := Pasture3DRoadBrush.new()
	r.name = p_name
	_root.add_child(r)
	var path := Path3D.new()
	var c := Curve3D.new()
	for v in p_pts:
		c.add_point(v)
	path.curve = c
	r.add_child(path)
	return [r, path]


# ---- [RA] a control point beats another road's ribbon -------------------------------------------

func _ra_point_beats_ribbon() -> void:
	print("[RA] clicking a control point does not select the road crossing under it")
	# A runs along X; B crosses along Z, passing exactly under A's point 2. The overlap IS the fixture:
	# two roads that do not cross cannot reproduce the bug.
	var a := _road("RoadA", [Vector3(-75, 0, 0), Vector3(-45, 0, 0), Vector3(-15, 0, 0),
			Vector3(15, 0, 0), Vector3(45, 0, 0)])
	var b := _road("RoadB", [Vector3(-15, 0, -90), Vector3(-15, 0, 90)])
	var road_a: Node3D = a[0]
	var path_a: Path3D = a[1]
	var road_b: Node3D = b[0]

	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.global_position = Vector3(0, 140, 140)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.current = true
	get_viewport().size = Vector2i(1280, 720)

	var pt: Vector3 = road_a.to_global(path_a.curve.get_point_position(2))
	if cam.is_position_behind(pt):
		_fail += 1
		print("!!   the fixture is behind the camera; nothing was measured")
		_completed += 1
		return
	var at := cam.unproject_position(pt)

	var da: float = road_a.pick_brush_screen_distance(cam, at, 24.0)
	var db: float = road_b.pick_brush_screen_distance(cam, at, 24.0)
	print("    A (owns the point) %.2f px, B (ribbon underneath) %.2f px" % [da, db])
	_check("the point's own road wins", da < db, "%.2f < %.2f" % [da, db])
	_check("the point reports the point rung", is_equal_approx(da,
			Pasture3DTerrainBrush.POINT_PICK_DISTANCE), "%.2f" % da)

	# FIXTURE ASSERT: B's ribbon really is under the cursor. If it were not, A would win for the wrong
	# reason and [RA] would pass on a fixture that never reproduced anything.
	var b_ribbon: float = road_b.pick_road_screen_distance(cam, at, 24.0)
	_check("FIXTURE: B's ribbon is genuinely under the click", b_ribbon <= 1.0,
			"raw ribbon distance %.2f px" % b_ribbon)

	# THE CONTROL: the pre-fix answer, which is exactly what the override used to return. It must TIE
	# with B, because the tie is the bug.
	var old_a: float = road_a.pick_road_screen_distance(cam, at, 24.0)
	_check("CONTROL: the retired ribbon-only answer ties with the point",
			is_equal_approx(old_a, b_ribbon), "A %.2f vs B %.2f — indistinguishable" % [old_a, b_ribbon])
	_completed += 1


# ---- [RB] the chunk host is bookkeeping, not a structural edit -----------------------------------

func _rb_chunk_host_is_not_a_structural_edit() -> void:
	print("\n[RB] creating the Chunks host does not read as a spline change")
	var r := _road("RoadC", [Vector3(-30, 0, 0), Vector3(30, 0, 0)])
	var road: Node3D = r[0]
	var host: Node3D = road.ensure_chunk_host()
	_check("the host exists", host != null, str(host))
	_check("and is flagged internal",
			host.has_meta(Pasture3DTerrainBrush.INTERNAL_CHILD_META),
			"meta = %s" % host.has_meta(Pasture3DTerrainBrush.INTERNAL_CHILD_META))

	# CONTROL. An ORDINARY child carries no such flag, so `_on_child_changed` treats it as the structural
	# edit it is. Without this the criterion passes on a build where every child is exempt, which would
	# mean adding a spline no longer re-bakes.
	var plain := Node3D.new()
	road.add_child(plain)
	_check("CONTROL: an ordinary child is NOT exempt",
			not plain.has_meta(Pasture3DTerrainBrush.INTERNAL_CHILD_META), "meta = false")
	_completed += 1


# ---- [RC] point edits do not need a terrain ------------------------------------------------------

func _rc_point_edits_need_no_terrain() -> void:
	print("\n[RC] a road with no terrain can still have its points edited")
	var r := _road("RoadD", [Vector3(-40, 0, 0), Vector3(0, 0, 0), Vector3(40, 0, 0),
			Vector3(80, 0, 0)])
	var road: Node3D = r[0]
	var path: Path3D = r[1]

	# FIXTURE ASSERT: this really is the terrain-less case. A road parented outside the Pasture3D node
	# never gets one from `_terrain_ancestor`, which is how a network-owned road normally sits.
	_check("FIXTURE: the road has no terrain", not is_instance_valid(road.terrain),
			"terrain = %s" % road.terrain)

	var before := path.curve.point_count
	road.editor_remove_point(path, 1)
	_check("removing a point works", path.curve.point_count == before - 1,
			"%d -> %d points" % [before, path.curve.point_count])

	road.editor_smooth_point(path, 1)
	var smoothed: bool = path.curve.get_point_out(1).length() > 0.02
	_check("smoothing a point works", smoothed,
			"out tangent %.2f m" % path.curve.get_point_out(1).length())

	# CONTROL. The toggle must go back, or "it changed something" is being read as "it did the right
	# thing" — a one-way write would pass the line above.
	road.editor_smooth_point(path, 1)
	_check("CONTROL: and toggles back to a corner", path.curve.get_point_out(1).length() <= 0.02,
			"out tangent %.2f m" % path.curve.get_point_out(1).length())
	_completed += 1


# ---- [RD] the surface-snap query answers instead of crashing ------------------------------------

func _rd_snap_query_survives_no_terrain() -> void:
	print("
[RD] asking a terrain-less brush for the ground under a point answers NAN")
	var r := _road("RoadE", [Vector3(-20, 0, 0), Vector3(20, 0, 0)])
	var road: Node3D = r[0]
	road.snap_to_surface = true
	_check("FIXTURE: no terrain, snapping on", not is_instance_valid(road.terrain) and road.snap_to_surface,
			"terrain = %s, snap = %s" % [road.terrain, road.snap_to_surface])

	# This is the exact call brush_gizmo._set_subgizmo_transform makes on every drag frame. Before the
	# guard it raised on terrain.data; the criterion is that it RETURNS, and returns the one value the
	# caller tests for.
	var h: float = road._base_height_below(Vector3(0.0, 0.0, 0.0))
	_check("the query returns non-finite rather than raising", not is_finite(h), "h = %s" % h)
	var g: PackedFloat32Array = road._base_below_grid(-32.0, -32.0, 1.0, 8, 8)
	_check("and the grid form returns empty", g.is_empty(), "%d samples" % g.size())

	# THE CONTROL. Under a REAL terrain the same call must produce a real height — otherwise "answers
	# NAN" passes on a build where the helper is simply broken for everyone, and every snapping brush in
	# the project would silently stop snapping while this gate stayed green.
	var terr := Pasture3D.new()
	terr.name = "TerrainForRD"
	# data_directory AFTER add_child: Pasture3D::_initialize() is gated on being inside the tree. An
	# EMPTY scratch directory on purpose — pointing at res://demo/data made the run re-save nine region
	# files, and a gate that dirties the repo to measure something is not a gate. All this needs is for
	# `data` to exist, plus one blank region so there is a surface to sample at the origin.
	_root.add_child(terr)
	# Made first, or the region scan logs "Cannot open directory" before finding nothing.
	DirAccess.make_dir_recursive_absolute("user://rd_gate_scratch")
	terr.data_directory = "user://rd_gate_scratch"
	terr.data.add_region_blank(Vector2i.ZERO)
	var r2 := Pasture3DRoadBrush.new()
	r2.name = "RoadF"
	terr.add_child(r2)
	# Assigned by hand: `_auto_assign_terrain` is `Engine.is_editor_hint()`-gated, so parenting alone
	# binds nothing headless. That is a fixture detail, not the thing under test.
	r2.terrain = terr
	var h2: float = r2._base_height_below(Vector3(0.0, 0.0, 0.0))
	_check("CONTROL: with a terrain the same query is finite",
			is_instance_valid(r2.terrain) and is_finite(h2), "terrain = %s, h = %s" % [r2.terrain, h2])
	_completed += 1
