# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBrushGizmo — a tiny clickable origin marker for every Pasture3DTerrainBrush in the scene.
# Clicking a brush's spline selects the child Path3D, not the brush node you actually want to edit;
# with many overlapping brushes the parent is awkward to grab. This gizmo draws a small octahedron at
# each brush origin and gives it collision, so clicking the marker selects the brush itself. The marker
# is always drawn (a stable click target); the readable name is a separate Label3D on the brush whose
# visibility is toggled (see terrain_brush.gd). Editor-only; registered by editor_plugin.gd.
@tool
extends EditorNode3DGizmoPlugin

## World half-size of the origin marker (and its click box).
const MARKER_R: float = 4.0
## Metres the marker floats above the terrain surface so it sits clear of the ground, not buried in it.
const SURFACE_LIFT: float = 3.0
## Light neon purple — stands out against terrain greens / browns / yellows / ochres.
const MARKER_COLOR := Color(0.74, 0.42, 1.0)
## World half-size of the per-point marker drawn at each loop control point.
const POINT_R: float = 1.1
## Cyan-white point markers, distinct from the purple origin marker.
const POINT_COLOR := Color(0.55, 0.95, 1.0)
## Screen-space pick radius (px) for clicking a loop point.
const PICK_RADIUS: float = 13.0


func _init() -> void:
	# on_top so the marker shows through the terrain (a brush sunk below the surface stays findable).
	create_material("marker", MARKER_COLOR, false, true)
	create_material("points", POINT_COLOR, false, true)


func _get_gizmo_name() -> String:
	return "Pasture3D Brush"


func _has_gizmo(p_node: Node3D) -> bool:
	return p_node is Pasture3DTerrainBrush


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var node := p_gizmo.get_node_3d()
	# Float the marker above the terrain surface under the brush origin (not the node's own Y, which may
	# be buried after a height change). Computed in node-local space so transforms/scale are respected.
	var centre := _marker_centre(node)
	var mat := get_material("marker", p_gizmo)
	p_gizmo.add_lines(_marker_lines(centre), mat)
	# A solid box of collision triangles round the marker makes it pickable from any angle → clicking
	# selects the brush node. Built offset to the same floating centre as the visible marker
	# (add_collision_triangles has no transform arg, so move the vertices).
	var box := BoxMesh.new()
	box.size = Vector3.ONE * (MARKER_R * 2.0)
	var arrays := box.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += centre
	arrays[Mesh.ARRAY_VERTEX] = verts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tmesh := am.generate_triangle_mesh()
	if tmesh:
		p_gizmo.add_collision_triangles(tmesh)

	# Loop-point markers + transform-gizmo editing, shown only while the BRUSH itself is selected (not a
	# child loop), so they don't clutter every brush or duplicate Godot's native Path3D handles. The
	# points are SUBGIZMOS (below), so clicking one selects it and shows the standard move/rotate/scale
	# gizmo — the brush keeps its own selection the whole time.
	if _brush_selected(node):
		var pmat := get_material("points", p_gizmo)
		for path in _loop_paths(node):
			for i in path.curve.point_count:
				var c := node.to_local(path.to_global(path.curve.get_point_position(i)))
				p_gizmo.add_lines(_point_lines(c), pmat)


# ---- Loop points as subgizmos (Phase 1: select a point → transform gizmo → move it) ----


## Click test: the loop point nearest the cursor in screen space (or -1). Selecting it shows the gizmo.
func _subgizmos_intersect_ray(p_gizmo: EditorNode3DGizmo, p_camera: Camera3D, p_point: Vector2) -> int:
	var node := p_gizmo.get_node_3d()
	if not _brush_selected(node):
		return -1
	var best := -1
	var best_d := PICK_RADIUS
	var id := 0
	for path in _loop_paths(node):
		for i in path.curve.point_count:
			var world: Vector3 = path.to_global(path.curve.get_point_position(i))
			if not p_camera.is_position_behind(world):
				var d := p_camera.unproject_position(world).distance_to(p_point)
				if d < best_d:
					best_d = d
					best = id
			id += 1
	return best


## Box-select: every loop point inside the selection frustum (enables group move/rotate/scale).
func _subgizmos_intersect_frustum(p_gizmo: EditorNode3DGizmo, _camera: Camera3D, p_frustum: Array[Plane]) -> PackedInt32Array:
	var node := p_gizmo.get_node_3d()
	var out := PackedInt32Array()
	if not _brush_selected(node):
		return out
	var id := 0
	for path in _loop_paths(node):
		for i in path.curve.point_count:
			var world: Vector3 = path.to_global(path.curve.get_point_position(i))
			if _inside_frustum(p_frustum, world):
				out.append(id)
			id += 1
	return out


## The point's transform (translation only) in the gizmo node's local space — where the gizmo appears.
func _get_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int) -> Transform3D:
	var node := p_gizmo.get_node_3d()
	var res := _resolve_handle(node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return Transform3D()
	return Transform3D(Basis(), node.to_local(path.to_global(path.curve.get_point_position(res[1]))))


## Live drag from the transform gizmo. We take the new origin (rotation/scale of a lone point is a no-op
## for its position); Snap to Surface overrides Y onto the terrain beneath the brush's layer.
func _set_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int, p_transform: Transform3D) -> void:
	var node := p_gizmo.get_node_3d()
	var res := _resolve_handle(node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return
	var world := node.to_global(p_transform.origin)
	var brush := node as Pasture3DTerrainBrush
	if brush != null and brush.snap_to_surface:
		var h: float = brush._base_height_below(Vector3(world.x, 0.0, world.z))
		if is_finite(h):
			world.y = h + brush.surface_offset
	path.curve.set_point_position(res[1], path.to_local(world))


## Commit the move(s) as one undoable action. set_point_position fires curve.changed → the brush
## repaints (and repaints again on undo).
func _commit_subgizmos(p_gizmo: EditorNode3DGizmo, p_ids: PackedInt32Array, p_restores: Array[Transform3D], p_cancel: bool) -> void:
	var node := p_gizmo.get_node_3d()
	if p_cancel:
		for i in p_ids.size():
			var res := _resolve_handle(node, p_ids[i])
			var path: Path3D = res[0]
			if path != null:
				path.curve.set_point_position(res[1], path.to_local(node.to_global(p_restores[i].origin)))
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Move Loop Point" if p_ids.size() == 1 else "Move Loop Points")
	for i in p_ids.size():
		var res := _resolve_handle(node, p_ids[i])
		var path: Path3D = res[0]
		if path == null:
			continue
		var idx: int = res[1]
		var cur := path.curve.get_point_position(idx)
		var restore_local := path.to_local(node.to_global(p_restores[i].origin))
		ur.add_do_method(path.curve, "set_point_position", idx, cur)
		ur.add_undo_method(path.curve, "set_point_position", idx, restore_local)
	ur.commit_action()


## Map a flat subgizmo id back to (child Path3D, point index), in the same order _redraw drew them.
func _resolve_handle(p_node: Node3D, p_id: int) -> Array:
	var base := 0
	for path in _loop_paths(p_node):
		var n: int = path.curve.point_count
		if p_id < base + n:
			return [path, p_id - base]
		base += n
	return [null, -1]


## A point is inside the selection frustum when it is on the inner side of every plane.
func _inside_frustum(p_planes: Array[Plane], p_point: Vector3) -> bool:
	for pl in p_planes:
		if pl.is_point_over(p_point):
			return false
	return true


## Small octahedron wireframe at a loop point, centred on `c` (node-local).
func _point_lines(c: Vector3) -> PackedVector3Array:
	var r := POINT_R
	var a := c + Vector3(r, 0, 0)
	var b := c + Vector3(-r, 0, 0)
	var t := c + Vector3(0, r, 0)
	var d := c + Vector3(0, -r, 0)
	var e := c + Vector3(0, 0, r)
	var f := c + Vector3(0, 0, -r)
	return PackedVector3Array([a, e, e, b, b, f, f, a, t, a, t, e, t, b, t, f, d, a, d, e, d, b, d, f])


## This brush's child loops that have a curve (the editable splines), in child order.
func _loop_paths(p_node: Node3D) -> Array:
	var out: Array = []
	for c in p_node.get_children():
		if c is Path3D and c.curve != null:
			out.append(c)
	return out


## The brush node itself (not a child loop) is the current editor selection.
func _brush_selected(p_node: Node3D) -> bool:
	return p_node in EditorInterface.get_selection().get_selected_nodes()


## Marker centre in node-local space: the terrain surface height under the brush origin (+ lift), or the
## origin itself when there's no terrain/height to read.
func _marker_centre(node: Node3D) -> Vector3:
	var origin: Vector3 = node.global_transform.origin
	var surf_y := origin.y
	var brush := node as Pasture3DTerrainBrush
	if brush != null and brush.terrain != null and brush.terrain.data != null:
		var h: float = brush.terrain.data.get_height(Vector3(origin.x, 0.0, origin.z))
		if is_finite(h):
			surf_y = h
	var world_centre := Vector3(origin.x, surf_y + SURFACE_LIFT, origin.z)
	return node.to_local(world_centre)


## Octahedron wireframe (12 edges) centred on `c` — reads as a gizmo "point" from any view.
func _marker_lines(c: Vector3) -> PackedVector3Array:
	var r := MARKER_R
	var a := c + Vector3(r, 0, 0)
	var b := c + Vector3(-r, 0, 0)
	var t := c + Vector3(0, r, 0)
	var d := c + Vector3(0, -r, 0)
	var e := c + Vector3(0, 0, r)
	var f := c + Vector3(0, 0, -r)
	return PackedVector3Array([
		a, e, e, b, b, f, f, a,    # equator ring
		t, a, t, e, t, b, t, f,    # apex spokes
		d, a, d, e, d, b, d, f,    # nadir spokes
	])
