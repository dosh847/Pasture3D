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


func _init() -> void:
	# on_top so the marker shows through the terrain (a brush sunk below the surface stays findable).
	create_material("marker", MARKER_COLOR, false, true)


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
