# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphSources — the one place that knows what a HOST owes a graph before it can be evaluated.
#
# ---- WHY THIS IS ONE FUNCTION AND NOT TWO ----
#
# A graph is a Resource: no position in the scene, no parent, no way to reach a brush. So every source node
# that names something in the scene — a road, and now a brush outline — has to be resolved from outside,
# and the three places that run a graph (the brush's graph step, the graph editor's preview, the graph
# editor's inspector hand-off) each have to do it.
#
# Roads were resolved directly through Pasture3DRoadNetwork.resolve_graph_paths at all three. Adding a
# second kind of source that way means six calls that must stay in step, and the failure when they do not
# is silent: a graph previews with its shapes resolved and BAKES with them empty, or the reverse, and
# either reads as a solver bug. A value defined in three places is fixed in none. So the sites call this,
# and this decides what resolution means.
@tool
class_name Pasture3DGraphSources
extends RefCounted


## Resolve every scene-naming source node in `p_graph` against `p_host`'s scene. Returns how many nodes
## were filled: roads, shapes and splines together.
##
## `p_host` may be null — a graph edited with no brush in hand — and then nothing resolves and nothing
## errors. That is the same state as a road whose brush was deleted, and \§4.3's empty-path rule is what
## keeps it from being a crash: queries answer `unreachable`, masks answer 0.
static func resolve(p_graph: Pasture3DTerrainGraph, p_host: Node = null) -> int:
	if p_graph == null:
		return 0
	var filled := 0
	if p_host != null:
		var net := Pasture3DRoadNetwork.find_for(p_host)
		if net != null:
			filled += net.resolve_graph_paths(p_graph, p_host)
	filled += resolve_shapes(p_graph, p_host)
	filled += resolve_splines(p_graph, p_host)
	return filled


## The shape half. Split out so it can be gated on its own, and called with an explicit terrain by hosts
## that have one but are not themselves under it.
##
## A key naming no brush leaves the node's path ALONE rather than clearing it, for the reason
## resolve_graph_paths gives at length: clearing would make a brush mid-rename flatten every terrain
## reading it for one bake, which reads as a solver bug rather than as a lookup that missed.
static func resolve_shapes(p_graph: Pasture3DTerrainGraph, p_host: Node = null) -> int:
	if p_graph == null:
		return 0
	var terrain := _terrain_of(p_host)
	var by_key := {}
	var keys := PackedStringArray()
	var collected := false
	var filled := 0
	for node in p_graph.nodes:
		if node == null or node.op() != &"shape_source":
			continue
		var src: Pasture3DGraphNodeShapeSource = node
		# Collected for EVERY shape source, including ones with an empty key: the dropdown's whole job is
		# to be there before you have chosen anything.
		if not collected:
			collected = true
			if terrain != null:
				for b in shape_brushes(terrain):
					var k: String = b.shape_key()
					by_key[k] = b
					keys.append(k)
				keys.sort()
		src.editor_shape_keys = keys
		if src.shape_key.is_empty():
			continue
		if by_key.has(src.shape_key):
			var brush: Pasture3DTerrainBrush = by_key[src.shape_key]
			_assign(src, brush.graph_shape_path(src.spline_index))
			filled += 1
	return filled


## The spline half. Fills every Spline Source node from the Pasture3DSpline it names — or, for the empty
## key, from the HOST brush's own first Pasture3DSpline child.
##
## ---- WHY THE EMPTY KEY FALLS BACK AND SHAPE SOURCE'S DOES NOT ----
##
## A key is an absolute scene path. A Ridge preset whose graph named "Ridge/Crest" would, duplicated,
## produce a second Ridge whose graph still named the FIRST one's spline — every copy carving the
## original's line. The fallback is relative to whoever is running the graph, so a duplicate resolves to
## its own child, and that is the property that makes a preset duplicable at all
## (PASTURE3D_SPLINE_GRAPH_SPEC.md §5.1). Shape Source has no equivalent case: a brush masking itself by
## its own outline is a step that can never change anything.
##
## A key naming no spline leaves the node's path ALONE rather than clearing it, for the reason
## `resolve_shapes` gives: clearing would make a spline mid-rename flatten every terrain reading it for
## one bake, which reads as a solver bug rather than as a lookup that missed.
static func resolve_splines(p_graph: Pasture3DTerrainGraph, p_host: Node = null) -> int:
	if p_graph == null:
		return 0
	var terrain := _terrain_of(p_host)
	var by_key := {}
	var keys := PackedStringArray()
	var collected := false
	var filled := 0
	# The host's own child, for the empty key. Resolved once rather than per node, and only when a host
	# was actually handed in — a graph edited on its own has no "own child" and must simply not resolve.
	var own: Pasture3DSpline = null
	if p_host is Pasture3DTerrainBrush:
		for c in (p_host as Node).get_children():
			if c is Pasture3DSpline:
				own = c as Pasture3DSpline
				break
	for node in p_graph.nodes:
		if node == null or node.op() != &"spline_source":
			continue
		var src: Pasture3DGraphNodeSplineSource = node
		# Collected for EVERY spline source, including ones with an empty key: the dropdown's whole job is
		# to be there before you have chosen anything.
		if not collected:
			collected = true
			if terrain != null:
				for b in spline_brushes(terrain):
					var k: String = b.spline_key()
					by_key[k] = b
					keys.append(k)
				keys.sort()
		src.editor_spline_keys = keys
		if src.spline_key.is_empty():
			if own != null:
				_assign(src, own.graph_spline_path(src.spline_index))
				filled += 1
			continue
		if by_key.has(src.spline_key):
			var sp: Pasture3DSpline = by_key[src.spline_key]
			_assign(src, sp.graph_spline_path(src.spline_index))
			filled += 1
	return filled


## Every Pasture3DSpline under `p_terrain`, in scene order.
static func spline_brushes(p_terrain: Node) -> Array[Pasture3DSpline]:
	var out: Array[Pasture3DSpline] = []
	if p_terrain != null:
		_collect_splines(p_terrain, out)
	return out


static func _collect_splines(p_at: Node, p_out: Array[Pasture3DSpline]) -> void:
	for c in p_at.get_children():
		if c is Pasture3DSpline and (c as Pasture3DSpline).graph_spline_count() > 0:
			p_out.append(c as Pasture3DSpline)
		_collect_splines(c, p_out)


## Every brush under `p_terrain` that can offer an outline, in scene order.
##
## Road brushes are EXCLUDED. Not because a road has no spline — it has one, and this would happily hand
## it over — but because a road's centreline through a node called Shape Source is a trap: it is open, so
## Path Mask gives a corridor, which is what Road Source plus Path Mask already does, correctly and with
## the road's real per-vertex widths instead of nothing. Two ways to do one thing, one of them worse.
##
## Pasture3DSpline is excluded for exactly that rule, one step further along. `graph_shape_path` drops the
## Y and the half-widths a Pasture3DSpline was authored to carry, so offering one here would give a second
## route to the same curve that silently discards most of it. Spline Source is the route, and it is the
## only one.
static func shape_brushes(p_terrain: Node) -> Array[Pasture3DTerrainBrush]:
	var out: Array[Pasture3DTerrainBrush] = []
	if p_terrain != null:
		_collect(p_terrain, out)
	return out


static func _collect(p_at: Node, p_out: Array[Pasture3DTerrainBrush]) -> void:
	for c in p_at.get_children():
		if c is Pasture3DTerrainBrush and not (c is Pasture3DRoadBrush) and not (c is Pasture3DSpline):
			var b := c as Pasture3DTerrainBrush
			if b.graph_shape_count() > 0:
				p_out.append(b)
		_collect(c, p_out)


static func _terrain_of(p_host: Node) -> Node:
	var n: Node = p_host
	while n != null:
		if n is Pasture3D:
			return n
		n = n.get_parent()
	return null


## Assign only when the outline actually CHANGED. Assigning unconditionally emits `changed`, which bumps
## the node's revision, which invalidates every downstream cache — so a graph with a shape in it would
## re-solve from scratch on every bake and the cache would look broken rather than bypassed. This is the
## same rule Pasture3DRoadNetwork._assign follows, and it has its own control in the gate.
##
## Through `content_digest()` for the same reason the road's does: comparing `closed` and `points` alone
## left the identical hole here — a shape whose half-widths or heights moved rebuilt its outline, matched
## on the two fields tested, and was thrown away.
## `p_src` is deliberately untyped: Shape Source and Spline Source both declare `path` and neither
## inherits it from Pasture3DGraphNode, so a typed parameter would need either a shared base that exists
## only to carry one property, or a second copy of this function. The digest rule is the thing worth
## having in one place.
static func _assign(p_src, p_path: Pasture3DGraphPath) -> void:
	if p_path == null:
		return
	# Explicitly typed, not inferred: `p_src` is untyped above, so `p_src.path` carries no static type
	# and `:=` cannot name one.
	var cur: Pasture3DGraphPath = p_src.path
	if cur != null and cur.content_digest() == p_path.content_digest():
		return
	p_src.path = p_path
