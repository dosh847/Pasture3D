# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphGradientHandles — where a Gradient node's `start` and `end` sit in the viewport, and the
# inverse: what property value a dragged handle means (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §12).
#
# A plain RefCounted for the reason `brush_handles.gd` gives: `EditorNode3DGizmoPlugin` cannot be built
# headless, so a gate could only assert the drawing was CALLED. Here the gizmo asks for handle positions
# and the gate asks for the same positions and checks them against the kernel.
#
# ---- THE PLACEMENT IS READ FROM THE BRUSH, NOT FROM THE NODE ----
#
# A HOST-space Gradient measures `start` / `end` through `host_xform`, and that is only stamped when the
# graph is resolved (a bake, a preview). Mid-drag of the BRUSH it lags a frame behind; before the first
# resolve it is identity. Drawing through it would put the handles at the brush's old position, or at
# the world origin, and dragging one would write a value measured in the wrong frame. So both directions
# go through `Pasture3DGraphSources.host_placement(brush)`, the same function `resolve` stamps with.
#
# ---- A DRIVEN COORDINATE IS DRAWN, NOT PICKED ----
#
# When `start_x` (etc.) is wired, the kernel ignores the property for that axis. Dragging the handle would
# edit a value nothing reads, and the handle would snap back on release. It is drawn hollow so the author
# can still see where the property WOULD place it, and it is not a pick target.
@tool
extends RefCounted

## Subgizmo ids at and above this belong to gradient handles. Loop handles use `gpi * 3 + kind`, and no
## brush has sixteen million loop points.
const ID_BASE: int = 1 << 24
## Screen-space pick radius (px), the same as the loop handles so the two feel alike.
const PICK_RADIUS: float = 13.0
## Metres a handle floats above the ground, so it is not buried in the terrain it describes.
const LIFT: float = 0.5
## Segments in the radius ring drawn for the radial shapes.
const RING_SEGMENTS: int = 48

## Input ports carrying each handle's coordinates: [x port, z port] for start (0) and end (1).
const DRIVE_PORTS := [[1, 2], [3, 4]]


## Every gradient handle on `p_brush`'s graphs, in a stable order (the subgizmo id is ID_BASE + index).
## Each entry: node (the Gradient), graph, which (0 start, 1 end), world (Vector3), local (brush-local
## Vector3), driven (bool: either coordinate is wired).
static func handles(p_brush: Node3D) -> Array:
	var out: Array = []
	if p_brush == null or not is_instance_valid(p_brush) or not ("modifiers" in p_brush):
		return out
	for m in p_brush.modifiers:
		if not (m is Pasture3DNodeGraph):
			continue
		var g: Pasture3DTerrainGraph = (m as Pasture3DNodeGraph).graph
		if g == null:
			continue
		for ni in g.nodes.size():
			var n = g.nodes[ni]
			if not (n is Pasture3DGraphNodeGradient):
				continue
			var xf := placement_for(p_brush, n)
			for which in 2:
				var v: Vector2 = n.start if which == 0 else n.end
				var w2: Vector2 = xf * v
				var world := Vector3(w2.x, _ground_y(p_brush, w2) + LIFT, w2.y)
				out.append({
					"node": n, "graph": g, "node_index": ni, "which": which,
					"world": world, "local": p_brush.to_local(world) if p_brush.is_inside_tree() else world,
					"driven": _driven(g, ni, which),
				})
	return out


## The frame `start` / `end` of `p_node` are measured in, taken live from the brush (see the header).
static func placement_for(p_brush: Node3D, p_node: Pasture3DGraphNodeGradient) -> Transform2D:
	if p_node.space == Pasture3DGraphNodeGradient.Space.HOST and p_brush != null:
		return Pasture3DGraphSources.host_placement(p_brush)
	return Transform2D.IDENTITY


## The property value that puts handle `p_handle` at world position `p_world`. Height is ignored: a
## gradient is measured on the ground plane.
static func value_for_world(p_brush: Node3D, p_handle: Dictionary, p_world: Vector3) -> Vector2:
	return placement_for(p_brush, p_handle["node"]).affine_inverse() * Vector2(p_world.x, p_world.z)


## The property a handle edits.
static func property_of(p_handle: Dictionary) -> StringName:
	return &"start" if int(p_handle["which"]) == 0 else &"end"


## The handle for subgizmo id `p_id`, or {}.
static func resolve(p_brush: Node3D, p_id: int) -> Dictionary:
	var i := p_id - ID_BASE
	if i < 0:
		return {}
	var all := handles(p_brush)
	return all[i] if i < all.size() else {}


## The nearest undriven handle under the cursor, as a subgizmo id, or -1. Pure.
static func pick(p_brush: Node3D, p_camera: Camera3D, p_point: Vector2) -> int:
	var best := -1
	var best_d := PICK_RADIUS
	var all := handles(p_brush)
	for i in all.size():
		var h: Dictionary = all[i]
		if h["driven"]:
			continue
		var world: Vector3 = h["world"]
		if p_camera.is_position_behind(world):
			continue
		var d := p_camera.unproject_position(world).distance_to(p_point)
		if d < best_d:
			best_d = d
			best = ID_BASE + i
	return best


## Line pairs in brush-local space: start to end for every gradient, and the t = 0 ring for the radial
## shapes (RADIAL, SPHERICAL: the ring at |end - start| is where the field reaches its far value).
static func lines(p_brush: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var all := handles(p_brush)
	var i := 0
	while i + 1 < all.size():
		var a: Dictionary = all[i]
		var b: Dictionary = all[i + 1]
		i += 2
		out.append(a["local"])
		out.append(b["local"])
		var n: Pasture3DGraphNodeGradient = a["node"]
		if n.shape != Pasture3DGraphNodeGradient.Shape.RADIAL and n.shape != Pasture3DGraphNodeGradient.Shape.SPHERICAL:
			continue
		var c: Vector3 = a["world"]
		var r := Vector2(c.x, c.z).distance_to(Vector2(b["world"].x, b["world"].z))
		if r < 1.0e-3:
			continue
		var prev := Vector3.ZERO
		for s in RING_SEGMENTS + 1:
			var ang := TAU * float(s) / float(RING_SEGMENTS)
			var w2 := Vector2(c.x + cos(ang) * r, c.z + sin(ang) * r)
			var p := Vector3(w2.x, _ground_y(p_brush, w2) + LIFT, w2.y)
			var lp: Vector3 = p_brush.to_local(p) if p_brush.is_inside_tree() else p
			if s > 0:
				out.append(prev)
				out.append(lp)
			prev = lp
	return out


static func _driven(p_graph: Pasture3DTerrainGraph, p_node_index: int, p_which: int) -> bool:
	var ports: Array = DRIVE_PORTS[p_which]
	for c in p_graph.connections:
		if int(c[2]) == p_node_index and ports.has(int(c[3])):
			return true
	return false


## The terrain surface under a world XZ point, or the brush's own height with no terrain to read.
static func _ground_y(p_brush: Node3D, p_xz: Vector2) -> float:
	if "terrain" in p_brush and p_brush.terrain != null and p_brush.terrain.data != null:
		var h: float = p_brush.terrain.data.get_height(Vector3(p_xz.x, 0.0, p_xz.y))
		if is_finite(h):
			return h
	return p_brush.global_position.y if p_brush.is_inside_tree() else p_brush.position.y
