# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSpline — a curve you author for the GRAPH to read. It paints nothing.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §4. Pair it with a Spline Source node
# (pasture3d_graph_node_spline_source.gd), which is the graph end of the same wire.
#
# ---- WHY THIS IS A BRUSH ----
#
# Until now the only ways to get a curve into a terrain graph were Road Source, which needs a road, and
# Shape Source, which offers a shaping brush's OUTLINE — a by-product of a Mound rather than something
# anyone draws on purpose. There was no way to draw a line and hand it over. Rivers, ridges, canyons,
# cliff lines, hedgerows and treelines were all blocked on that.
#
# A bare Path3D would have been the smaller-looking answer and is the more expensive one. It has no gizmo
# that seats points on the terrain, no click-to-add, no tangent handles, no surface snap, no nameplate,
# no Brush Stats, no shared-curve warning, no placement tool and no undo integration. Every one of those
# already exists on Pasture3DTerrainBrush and is keyed on that class in src/brush_gizmo.gd and
# src/editor_plugin.gd, so a geometry node that is not a brush grows a second copy of all of it.
#
# What it does NOT want is the other half of the base: a reserved tool layer, a place in that layer's
# sibling repaint, a blend mode, an Add Water button. Those are all consequences of PAINTING, and
# `_paints()` is the one hook they hang off — see Pasture3DTerrainBrush._paints for the site list.
#
# Pasture3DSimPass's header argues the opposite case, and it is right where it was written: a Sim Pass
# draws no spline, so the base buys it nothing. This draws nothing BUT a spline.
#
# ---- IT PUBLISHES, IT DOES NOT PUSH ----
#
# Editing this spline cannot change the terrain by itself, because nothing here bakes. What it does is
# re-resolve and re-bake the brushes whose graphs READ it (`_refresh_consumers` on the base). A consumer
# whose graph modifier is FROZEN will not re-solve on its own — it raises its "press Bake Graph" warning
# instead, and the Spline Source node says so too. That is correct, and it is the first thing that reads
# as a bug, which is why it is written down in three places.
@tool
@icon("res://addons/pasture_3d/icons/brush_spline.svg")
class_name Pasture3DSpline
extends Pasture3DTerrainBrush


@export_group("Shape")
## Connect the last point back to the first.
##
## A closed spline is a REGION boundary: Path Mask fills its interior by even-odd winding and `inside()`
## becomes answerable. An open one is a route, and Path Mask gives a corridor along it instead. Both are
## useful and they are not interchangeable, which is why this is a toggle rather than something inferred
## from whether the ends happen to meet.
@export var closed: bool = false:
	set(v):
		closed = v
		_schedule_refresh()
		if is_inside_tree():
			update_gizmos() # redraw the loop wrap segment + its tangents

@export_group("Width")
## Half-width in metres at every vertex, before `width_along`.
##
## This is what makes `t` normalised on the consuming side: t = ±1 is the spline's own edge whatever the
## width does along its length. Published per VERTEX rather than as a scalar even when it is constant,
## because per-vertex is what the geometry table carries and what a future Path Width node edits — a
## scalar fast path would be a second representation of one thing.
@export_range(0.1, 200.0, 0.1, "or_greater", "suffix:m") var half_width: float = 5.0:
	set(v):
		half_width = maxf(v, 0.01)
		_schedule_refresh()

## Optional taper: sampled start (x=0) to end (x=1), multiplying `half_width` per vertex. Null = constant.
##
## This is Ridge's `width_curve`, moved onto the geometry where it belongs. A width is a property of the
## LINE, not of whoever happens to be carving it: put here, one taper is read by the carve, by Path Mask
## and by Path Distance's `t` normalisation, and all three agree. Put on a carve, the other two silently
## disagree with it.
@export var width_along: Curve:
	set(v):
		if width_along != null and width_along.changed.is_connected(_schedule_refresh):
			width_along.changed.disconnect(_schedule_refresh)
		width_along = v
		if width_along != null and not width_along.changed.is_connected(_schedule_refresh):
			width_along.changed.connect(_schedule_refresh)
		_schedule_refresh()

@export_group("Elevation")
## Publish the control points' own Y as the path's `heights`, so a consumer can grade TO the drawn line
## rather than only measure against it.
##
## OFF publishes an EMPTY height array, not a zero-filled one. `Pasture3DGraphPath.height_at` answers NAN
## for an empty array, and NAN in a HEIGHT grid means "no data" (PASTURE3D_NODE_VOCABULARY.md §1). A
## zero-filled array would mean "sea level", which is a plausible-looking wrong answer and the harder kind
## to notice.
@export var carry_heights: bool = true:
	set(v):
		carry_heights = v
		_schedule_refresh()


# ---- What makes this a geometry node rather than a tool ---------------------------------------------

## The whole difference. See Pasture3DTerrainBrush._paints.
func _paints() -> bool:
	return false


## Never called — `_refresh_owner` returns before the paint loop on a brush that does not paint. Present
## so the base's "must be overridden" push_error cannot fire if a future path reaches it, and so that
# reading this file does not leave the question open.
func _paint_spline(_path: Path3D) -> void:
	pass


func _default_snap_to_surface() -> bool:
	# A spline authored as a crest, a bed line or a river carries a deliberate vertical shape, and
	# re-seating it on the surface every bake destroys exactly that. Matches Ridge and Trough.
	return false


func _min_points() -> int:
	return 2


func _is_closed() -> bool:
	return closed


func _spline_basename() -> String:
	return "Line"


func _padding() -> float:
	# Only the footprint AABB and the Brush Stats readout use this — nothing is stamped. The half-width
	# is still the honest reach, because that is the band a consumer will carve.
	return half_width + 2.0


## Straight line in local space, along -Z/+Z like Ridge's, so a fresh spline is immediately draggable.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, -20.0))
	c.add_point(Vector3(0.0, 0.0, 20.0))
	return c


# ---- Publishing -------------------------------------------------------------------------------------

## This brush's key, for a Spline Source node to hold.
##
## Delegates rather than being derived a second time. `shape_key()` already answers "my path relative to
## my terrain", derived and never stored, and a second derivation of one string is a pair that can drift.
## The name exists because a resolver asking a spline for its `shape_key` reads like a mistake.
func spline_key() -> String:
	return shape_key()


## How many paths this node can offer, one per child Path3D.
func graph_spline_count() -> int:
	return _get_splines().size()


## Spline `p_index` as a PATH in world XZ, with per-vertex half-widths and (when `carry_heights`) the
## drawn elevation.
##
## Deliberately NOT `graph_shape_path`, which is the base's "my outline" answer and DROPS the Y and the
## widths by design (PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §8.1). A Mound's outline is a by-product, so
## it hands over only where it is; a Pasture3DSpline is authored FOR the graph, so it hands over
## everything it knows. That difference is also why Pasture3DSpline is excluded from Shape Source's
## dropdown — see Pasture3DGraphSources._collect.
##
## WORLD space, from the BAKED points. World because a spline that published local positions would land
## at the origin when reparented and still look like a perfectly plausible curve. Baked rather than the
## control polygon because the tangent handles are part of what was authored, and the rasterisers already
## read the curve this way — publishing the control points would hand the graph a different shape from
## the one the gizmo draws.
##
## The ring is left OPEN even when `closed` is true. `Pasture3DGraphPath.closed` carries the flag and the
## resource repeats the first vertex itself, in exactly one place, so the CPU query, the mask and the
## oracle cannot each decide differently whether the last vertex repeats the first.
##
## An index past the end resolves to an EMPTY path, never clamped: a deleted spline must not leave a
## graph quietly pointing at a line nobody chose.
func graph_spline_path(p_index: int = 0) -> Pasture3DGraphPath:
	var out := Pasture3DGraphPath.new()
	out.source_label = spline_key()
	var splines := _get_splines()
	if p_index < 0 or p_index >= splines.size():
		return out
	var sp: Path3D = splines[p_index]
	if not is_instance_valid(sp):
		return out
	var wpts := _baked_world_points(sp)
	if wpts.size() < 2:
		return out
	# Decimated to about one vertex per terrain cell, exactly as every rasteriser does before stamping.
	# Curve3D bakes at a fixed 0.2 m interval, so a 40 m straight line arrives as two hundred collinear
	# points — an index the query builds, walks and caches for no gain. Decimating HERE rather than in each
	# consumer also means the graph and the brushes see the SAME polyline: two decimations of one curve
	# would disagree in the corners, and the disagreement would read as a solver bug.
	if terrain != null and terrain.vertex_spacing > 0.0:
		wpts = _decimate3(wpts, terrain.vertex_spacing)
	if wpts.size() < 2:
		return out

	var n := wpts.size()
	var pts := PackedVector2Array()
	var hts := PackedFloat32Array()
	pts.resize(n)
	if carry_heights:
		hts.resize(n)
	# Arc length as we go, so `width_along` is sampled by DISTANCE along the line rather than by vertex
	# index. Baked points are not evenly spaced — a tight curve gets many and a straight run gets few —
	# so an index-parameterised taper would bunch up in the corners.
	var cum := PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for i in range(n):
		var w := wpts[i]
		pts[i] = Vector2(w.x, w.z)
		if carry_heights:
			hts[i] = w.y
		if i > 0:
			cum[i] = cum[i - 1] + Vector2(wpts[i - 1].x, wpts[i - 1].z).distance_to(pts[i])
	var total: float = maxf(cum[n - 1], 0.001)

	var hw := PackedFloat32Array()
	hw.resize(n)
	for i in range(n):
		var scale := 1.0
		if width_along != null:
			scale = maxf(width_along.sample_baked(clampf(cum[i] / total, 0.0, 1.0)), 0.0)
		hw[i] = half_width * scale

	out.points = pts
	out.half_widths = hw
	out.heights = hts
	out.closed = closed
	return out


func _get_configuration_warnings() -> PackedStringArray:
	var w := super()
	# Not an error, and said as information rather than as a fix: an unwired spline is a spline you have
	# not connected YET, and nothing here should push. It is worth saying at all because a spline that
	# paints nothing and is read by nobody looks identical to one that is broken.
	if not _get_splines().is_empty() and is_inside_tree() and _consumer_count() == 0:
		w.append(("Nothing reads this spline yet. Add a Spline Source node to a brush's Node Graph "
			+ "modifier and pick \"%s\" (or drop this node under that brush and leave the key empty).")
			% spline_key())
	return w


## How many brushes in the scene have a graph that names this spline. Warning-only; the refresh path
## walks the same ground in `_refresh_consumers` and does the work while it is there.
func _consumer_count() -> int:
	var key := spline_key()
	var count := 0
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n == self or not (n is Pasture3DTerrainBrush) or not is_instance_valid(n):
			continue
		var b := n as Pasture3DTerrainBrush
		if b.terrain == terrain and _brush_reads_spline(b, key):
			count += 1
	return count
