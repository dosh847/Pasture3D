# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphPathOverlay — the geometry of the viewport PATH overlay
# (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §6.2, phase V3).
#
# THE REQUIREMENT. See the points of a Path Resample or a Path Drape in the 3D viewport, on the actual
# terrain, to confirm they did what they claim. A 128 px thumbnail cannot answer "did the drape work" —
# that needs the ground the path is supposed to be lying on.
#
# ---- THE TRAP THIS WHOLE FILE IS BUILT AROUND (§6.3) ----
#
# The overlay reads `derived_path()`. It NEVER calls `eval_path()`.
#
# `Pasture3DGraphNodePathDerive.derive_without_grid` returns the input path UNCHANGED, which is the right
# answer for an evaluation that has no grid yet. So an overlay that asked a Path Drape for its path outside
# an evaluation would get back the UNDRAPED line — and draw it, confidently, as the answer. An undraped
# line drawn on terrain does not look broken. It looks like a path. The feature would ship, pass a naive
# test, and be wrong exactly when the author most needs it: when the drape is not working.
#
# `a-gate-that-calls-the-node-measures-nothing`, one layer up from where that lesson was written. This time
# the thing that would measure nothing is the author's own eyes.
#
# NEVER RESOLVED MEANS DRAW NOTHING. Not the input, not a guess. Absence is the honest render, and
# `unresolved` below carries the node indices so the caller can say "not yet evaluated" instead.
#
# ---- WHY IT IS A PLAIN RefCounted ----
#
# Same reason `brush_handles.gd` is, and its header states the case: an `EditorNode3DGizmoPlugin` cannot be
# driven headless, so a gate could not assert on what was drawn. It could only assert that the drawing code
# was called — which is exactly the class of test §6.3 is warning about. Here the gizmo asks for a
# Dictionary of vertex arrays and adds them; the gate asks for the same Dictionary and measures it.
#
# Everything returned is in the BRUSH'S LOCAL SPACE, because that is what `EditorNode3DGizmo.add_lines`
# takes. The paths themselves are world XZ.
@tool
extends RefCounted


## Metres below which a drop line is not emitted at all.
##
## A correctly draped path has zero-length drops, and drawing a few thousand degenerate segments to say so
## is both slow and unreadable. The ABSENCE of drops is the signal — see `drops` in the returned dict.
const DROP_EPSILON: float = 0.05

## Metres a drawn vertex is lifted along +Y, so the line reads against the terrain instead of z-fighting
## with it. Applied to the DRAWING only and never to a measurement: `drops` is computed from the path's
## own height, so the lift cannot make an undraped path look draped.
const DRAW_LIFT: float = 0.15

## Half-width used where a path declares none. Matches `Pasture3DGraphPath.half_widths`'s own documented
## default, so the envelope drawn is the envelope every consumer of that path sees.
const DEFAULT_HALF_WIDTH: float = 1.0


## Every PATH-typed, preview-on node on `p_brush`'s graphs, as viewport geometry.
##
## Returns, all in `p_brush`-local space:
##   centreline : PackedVector3Array of LINE PAIRS through the resolved vertices
##   vertices   : PackedVector3Array, one point per resolved vertex (drawn as dots)
##   envelope   : PackedVector3Array of LINE PAIRS, the left and right offsets at ±half_width_at(s)
##   drops      : PackedVector3Array of LINE PAIRS, each vertex down to the terrain under it
##   drawn      : Array of node indices that contributed geometry
##   unresolved : Array of node indices that are previewed PATH nodes with no resolved path yet
##   vertex_count : int, the number of vertices drawn — the resample check, countable
##
## Reads no terrain when the brush has none: `drops` is simply empty, which is honest (no ground to
## measure against) rather than a set of zero-length segments claiming a perfect drape.
static func build(p_brush) -> Dictionary:
	var out := {
		"centreline": PackedVector3Array(), "vertices": PackedVector3Array(),
		"envelope": PackedVector3Array(), "drops": PackedVector3Array(),
		"drawn": [], "unresolved": [], "vertex_count": 0,
	}
	if p_brush == null or not is_instance_valid(p_brush):
		return out
	var data = null
	if p_brush.terrain != null and p_brush.terrain.data != null:
		data = p_brush.terrain.data
	if p_brush is Pasture3DSpline:
		var sp: Pasture3DSpline = p_brush as Pasture3DSpline
		var path: Pasture3DGraphPath = sp.graph_spline_path(0)
		if path != null and path.points.size() >= 2:
			_append_path(out, p_brush, path, data)
			out["drawn"].append(0)
		return out
	for m in p_brush.modifiers:
		if not (m is Pasture3DNodeGraph):
			continue
		var g: Pasture3DTerrainGraph = (m as Pasture3DNodeGraph).graph
		if g == null:
			continue
		var active_ni := _pick_active_path_node(g)
		if active_ni >= 0 and active_ni < g.nodes.size():
			var node: Pasture3DGraphNode = g.nodes[active_ni]
			if node != null:
				# THE ONE READ. `derived_path()`, never `eval_path()` — see the header.
				var path: Pasture3DGraphPath = node.derived_path()
				if path == null or path.points.size() < 2:
					out["unresolved"].append(active_ni)
				else:
					_append_path(out, p_brush, path, data)
					out["drawn"].append(active_ni)
					# Strictly one version of the path at a time.
					break
	return out


## Select exactly ONE active PATH node to preview for this graph.
## Priority:
##   1. Explicit Solo override (g.output_override)
##   2. Selected node in Graph Editor (_editor_selected_node metadata)
##   3. Explicit preview_on toggle (most downstream / last previewed node)
##   4. Fallback to output node if it is a PATH node
static func _pick_active_path_node(g: Pasture3DTerrainGraph) -> int:
	if g == null or g.nodes.is_empty():
		return -1

	# 1. Solo override (highest priority)
	if g.output_override >= 0 and g.output_override < g.nodes.size():
		var sn: Pasture3DGraphNode = g.nodes[g.output_override]
		if sn != null:
			if sn.output_port_type() == Pasture3DGraphNode.PortType.PATH:
				return g.output_override
			var up_solo := _find_upstream_path_node(g, g.output_override)
			if up_solo >= 0:
				return up_solo

	# 2. Selected node in Graph Editor
	var sel: int = int(g.get_meta(&"_editor_selected_node", -1))
	if sel >= 0 and sel < g.nodes.size():
		var sel_node: Pasture3DGraphNode = g.nodes[sel]
		if sel_node != null:
			if sel_node.output_port_type() == Pasture3DGraphNode.PortType.PATH:
				return sel
			var up_sel := _find_upstream_path_node(g, sel)
			if up_sel >= 0:
				return up_sel

	# 3. Explicit preview_on toggle (most downstream PATH node with preview_on)
	var last_preview := -1
	for ni in range(g.nodes.size()):
		var node: Pasture3DGraphNode = g.nodes[ni]
		if node != null and node.preview_on and node.output_port_type() == Pasture3DGraphNode.PortType.PATH:
			last_preview = ni
	if last_preview >= 0:
		return last_preview

	return -1


## Trace incoming connections to find the upstream PATH-output node feeding p_target.
static func _find_upstream_path_node(g: Pasture3DTerrainGraph, p_target: int) -> int:
	if g == null or p_target < 0:
		return -1
	for c in g.connections:
		if int(c[2]) == p_target:
			var from_idx := int(c[0])
			if from_idx >= 0 and from_idx < g.nodes.size() and g.nodes[from_idx] != null:
				if g.nodes[from_idx].output_port_type() == Pasture3DGraphNode.PortType.PATH:
					return from_idx
	return -1


## One path's four contributions. Split out so the loop above reads as the SELECTION rule and this reads as
## the DRAWING rule; they change for different reasons.
static func _append_path(r_out: Dictionary, p_brush, p_path: Pasture3DGraphPath, p_data) -> void:
	var pts: PackedVector2Array = p_path.points
	var n := pts.size()
	var has_heights := p_path.heights.size() == n
	var centre: PackedVector3Array = r_out["centreline"]
	var verts: PackedVector3Array = r_out["vertices"]
	var env: PackedVector3Array = r_out["envelope"]
	var drops: PackedVector3Array = r_out["drops"]

	var world := PackedVector3Array()
	world.resize(n)
	for i in range(n):
		var wx: float = pts[i].x
		var wz: float = pts[i].y
		# The path's OWN height when it carries one, the terrain surface when it does not (§6.2 item 1).
		# The distinction matters: a path with no heights drawn ON the ground is a statement that it has
		# none, whereas the same path drawn at y=0 would be a statement that it is at sea level.
		var y := 0.0
		if has_heights:
			y = p_path.heights[i]
		elif p_data != null:
			var gy: float = p_data.get_height(Vector3(wx, 0.0, wz))
			y = gy if is_finite(gy) else 0.0
		world[i] = Vector3(wx, y, wz)

	for i in range(n):
		var v: Vector3 = p_brush.to_local(world[i] + Vector3(0.0, DRAW_LIFT, 0.0))
		verts.append(v)
		if i > 0:
			centre.append(p_brush.to_local(world[i - 1] + Vector3(0.0, DRAW_LIFT, 0.0)))
			centre.append(v)
	if p_path.closed and n > 2:
		centre.append(p_brush.to_local(world[n - 1] + Vector3(0.0, DRAW_LIFT, 0.0)))
		centre.append(p_brush.to_local(world[0] + Vector3(0.0, DRAW_LIFT, 0.0)))
	r_out["vertex_count"] = int(r_out["vertex_count"]) + n

	# ---- the width envelope (§6.2 item 3) ----
	# Per-vertex offsets along the segment normal, not a mitred offset: at a tight corner a mitre folds and
	# draws a false spike, and a spike in the envelope reads as a width the author did not author.
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	left.resize(n)
	right.resize(n)
	for i in range(n):
		var a: int = maxi(i - 1, 0)
		var b: int = mini(i + 1, n - 1)
		var t := Vector2(pts[b].x - pts[a].x, pts[b].y - pts[a].y)
		if t.length() > 1.0e-6:
			t = t.normalized()
		else:
			t = Vector2(1.0, 0.0)
		var nrm := Vector2(-t.y, t.x)
		var hw := DEFAULT_HALF_WIDTH
		if p_path.half_widths.size() > 0:
			hw = p_path.half_widths[mini(i, p_path.half_widths.size() - 1)]
		var y: float = world[i].y + DRAW_LIFT
		left[i] = p_brush.to_local(Vector3(pts[i].x + nrm.x * hw, y, pts[i].y + nrm.y * hw))
		right[i] = p_brush.to_local(Vector3(pts[i].x - nrm.x * hw, y, pts[i].y - nrm.y * hw))
	for i in range(1, n):
		env.append(left[i - 1]); env.append(left[i])
		env.append(right[i - 1]); env.append(right[i])
	if p_path.closed and n > 2:
		env.append(left[n - 1]); env.append(left[0])
		env.append(right[n - 1]); env.append(right[0])

	# ---- the drop lines (§6.2 item 4) ----
	#
	# THE ONE THAT ACTUALLY MATTERS. A correctly draped path has zero-length drops and shows none; an
	# undraped one is a straight line floating over a valley with visible verticals down to the ground. It
	# reads at a glance and no other view says it.
	#
	# Only for a path that CARRIES heights. A path with none was drawn ON the surface above, so a drop line
	# would be zero-length by construction and would say "perfectly draped" about a path that was never
	# draped at all — the same confident-wrong-answer this file exists to avoid.
	if p_data == null or not has_heights:
		return
	for i in range(n):
		var gy: float = p_data.get_height(Vector3(pts[i].x, 0.0, pts[i].y))
		if not is_finite(gy):
			continue
		if absf(world[i].y - gy) < DROP_EPSILON:
			continue
		drops.append(p_brush.to_local(Vector3(pts[i].x, world[i].y, pts[i].y)))
		drops.append(p_brush.to_local(Vector3(pts[i].x, gy, pts[i].y)))
