# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SplineSourceGate — PASTURE3D_SPLINE_GRAPH_SPEC.md S1: an authored curve as graph geometry.
#
# ---- WHAT IS AT RISK ----
#
# S1 adds no mathematics. Every criterion here is about a JOIN, and each one is a place where the wrong
# behaviour still looks entirely plausible:
#
#   A  the path that arrives is the curve that was drawn, in WORLD space, with the widths and heights it
#      was authored to carry — a spline publishing LOCAL points lands at the origin and still looks like a
#      perfectly good curve;
#   B  an empty key resolves to the HOST's own child, so a duplicated preset carves its own line rather
#      than the original's — the property the Ridge/Trough presets are built on (§9);
#   C  a brush that paints nothing reserves no layer and joins no layer's sibling set;
#   D  editing a spline re-resolves the graphs that read it, and only those;
#   E  re-resolving an UNCHANGED spline changes nothing, or every bake invalidates every downstream cache;
#   F  a Pasture3DSpline appears in exactly one dropdown.
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== SplineSourceGate: an authored curve as graph geometry (S1) ===\n")
	_a_the_path_is_the_curve_that_was_drawn()
	_b_the_empty_key_is_the_hosts_own_child()
	_c_a_geometry_brush_owns_no_layer()
	_d_an_edit_reaches_its_consumers_and_no_one_else()
	_e_resolving_an_unchanged_spline_changes_nothing()
	_f_a_spline_is_offered_in_exactly_one_dropdown()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n"
			% ["SPLINE SOURCE PASS" if _fail == 0 else "SPLINE SOURCE FAIL", _fail])
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


# --- fixtures ---------------------------------------------------------------------------------------

## free(), not queue_free(). Every criterion runs synchronously inside one _ready, so a deferred free
## would leave the previous fixture in the tree — and in the brush GROUP that `_refresh_consumers` and
## `_tools_on_owner` both scan. Two fixtures whose splines are both called "River" under a terrain both
## called "Terrain" derive the SAME key, so the leak would make one criterion resolve against another's
## scene and still look entirely plausible. This is the PondScaleProbe trap in a different disguise.
func _drop(p_terrain: Node) -> void:
	remove_child(p_terrain)
	p_terrain.free()


func _terrain() -> Pasture3D:
	var t := Pasture3D.new()
	t.name = "Terrain"
	add_child(t)
	return t


## A Pasture3DSpline OFFSET from the origin, holding a curve whose LOCAL points are symmetric about it.
## The offset is the whole point of criterion A: local points published unchanged would put the line at
## the world origin and still read as a perfectly plausible curve.
func _spline_under(p_parent: Node, p_name: String, p_at: Vector3,
		p_ys: Array = [0.0, 6.0, 0.0]) -> Pasture3DSpline:
	var sp := Pasture3DSpline.new()
	sp.name = p_name
	p_parent.add_child(sp)
	sp.position = p_at
	sp.half_width = 4.0
	var path := Path3D.new()
	path.name = "Line"
	var c := Curve3D.new()
	c.add_point(Vector3(-10.0, p_ys[0], 0.0))
	c.add_point(Vector3(0.0, p_ys[1], 0.0))
	c.add_point(Vector3(10.0, p_ys[2], 0.0))
	path.curve = c
	sp.add_child(path)
	return sp


func _mound_under(p_terrain: Pasture3D, p_name: String, p_at: Vector3) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	p_terrain.add_child(m)
	m.position = p_at
	var path := Path3D.new()
	path.name = "Outline"
	var c := Curve3D.new()
	for p in [Vector3(-10, 0, -10), Vector3(10, 0, -10), Vector3(10, 0, 10), Vector3(-10, 0, 10)]:
		c.add_point(p)
	path.curve = c
	m.add_child(path)
	return m


## A brush's modifier stack holding one Node Graph whose only node is a Spline Source with `p_key`.
func _give_graph(p_brush: Pasture3DTerrainBrush,
		p_key: String) -> Pasture3DGraphNodeSplineSource:
	var src := Pasture3DGraphNodeSplineSource.new()
	src.spline_key = p_key
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [src]
	g.nodes = nodes
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	var stack: Array[Pasture3DNode] = [mod]
	p_brush.modifiers = stack
	return src


## Does this brush carry a tool-layer binding into a saved scene and into the inspector? True when
## `_get_property_list` appended BOTH the `tool_layer` dropdown and the STORAGE entry for `_layer_owner`.
func _has_layer_binding(p_brush: Pasture3DTerrainBrush) -> bool:
	var dropdown := false
	var stored := false
	for p in p_brush.get_property_list():
		if String(p["name"]) == "tool_layer":
			dropdown = true
		elif (String(p["name"]) == "_layer_owner"
				and (int(p["usage"]) & PROPERTY_USAGE_STORAGE) != 0):
			stored = true
	return dropdown and stored


func _bounds(p_pts: PackedVector2Array) -> Array:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for v in p_pts:
		mn = mn.min(v)
		mx = mx.max(v)
	return [mn, mx]


# --- A. The path is the curve that was drawn ---------------------------------------------------------
func _a_the_path_is_the_curve_that_was_drawn() -> void:
	var t := _terrain()
	var sp := _spline_under(t, "River", Vector3(40.0, 0.0, -25.0))
	var p := sp.graph_spline_path(0)
	var b := _bounds(p.points)
	var mn: Vector2 = b[0]
	var mx: Vector2 = b[1]
	print("    %d vertex/vertices, closed=%s, bounds %s..%s" % [p.points.size(), str(p.closed),
			str(mn), str(mx)])

	# The node sits at (40, -25), so the line must run x in [30,50] at z = -25 — NOT x in [-10,10] at 0.
	var placed := (absf(mn.x - 30.0) < 0.6 and absf(mx.x - 50.0) < 0.6
			and absf(mn.y + 25.0) < 0.6 and absf(mx.y + 25.0) < 0.6)
	# Widths: one per vertex, all at the authored half-width, because no taper is set.
	var widths_ok := p.half_widths.size() == p.points.size() and p.half_widths.size() > 0
	if widths_ok:
		for w in p.half_widths:
			if absf(w - 4.0) > 0.001:
				widths_ok = false
				break
	# Heights: one per vertex, and the drawn arch actually rises. `carry_heights` is on by default.
	var heights_ok := p.heights.size() == p.points.size()
	var hmax := -INF
	for h in p.heights:
		hmax = maxf(hmax, h)
	print("    widths: %d entries (want %d, all 4.0) | heights: %d entries, peak %.2f m (want ~6)"
			% [p.half_widths.size(), p.points.size(), p.heights.size(), hmax])
	_check("A", placed and widths_ok and heights_ok and hmax > 4.0,
			"world-placed=%s, per-vertex widths=%s, heights carried=%s (peak %.2f m)"
					% [str(placed), str(widths_ok), str(heights_ok), hmax])

	# CONTROL 1: heights OFF must publish an EMPTY array, not a zero-filled one. A zero-filled array reads
	# as "sea level" to every consumer, which is a plausible-looking wrong answer.
	sp.carry_heights = false
	var bare := sp.graph_spline_path(0)
	print("    control: carry_heights off gave %d height(s) (want 0) and height_at() = %s (want nan)"
			% [bare.heights.size(), str(bare.height_at(1.0))])
	if bare.heights.size() != 0 or not is_nan(bare.height_at(1.0)):
		_fail += 1
		print("    !! heights-off published a value instead of no data")

	# CONTROL 2: an index past the end resolves to EMPTY, never clamped to the last spline.
	var past := sp.graph_spline_path(4)
	print("    control: spline index 4 of %d gave %d point(s) (want 0, not a clamp)"
			% [sp.graph_spline_count(), past.points.size()])
	if past.points.size() != 0:
		_fail += 1
		print("    !! an out-of-range spline index clamped instead of resolving to nothing")
	_drop(t)


# --- B. The empty key is the host's own child --------------------------------------------------------
#
# The criterion the Ridge/Trough presets stand on. A key is an absolute scene path, so a preset that
# named one would carve the ORIGINAL's line from every duplicate of itself.
func _b_the_empty_key_is_the_hosts_own_child() -> void:
	var t := _terrain()
	var a := _mound_under(t, "RidgeA", Vector3(0.0, 0.0, 0.0))
	var sa := _spline_under(a, "Crest", Vector3.ZERO)
	var b := _mound_under(t, "RidgeB", Vector3(200.0, 0.0, 0.0))
	var sb := _spline_under(b, "Crest", Vector3.ZERO)

	var src_a := _give_graph(a, "")
	var src_b := _give_graph(b, "")
	Pasture3DGraphSources.resolve_splines((a.modifiers[0] as Pasture3DNodeGraph).graph, a)
	Pasture3DGraphSources.resolve_splines((b.modifiers[0] as Pasture3DNodeGraph).graph, b)

	var xa: float = src_a.path.points[0].x if src_a.path != null and src_a.path.points.size() > 0 else NAN
	var xb: float = src_b.path.points[0].x if src_b.path != null and src_b.path.points.size() > 0 else NAN
	print("    empty key on RidgeA resolved to x0 = %.1f (want ~-10)" % xa)
	print("    empty key on RidgeB resolved to x0 = %.1f (want ~190, its OWN child)" % xb)
	var own = absf(xa + 10.0) < 0.6 and absf(xb - 190.0) < 0.6
	_check("B", own, "each host resolved to its own child (A %.1f, B %.1f)" % [xa, xb])

	# CONTROL: a TYPED key does NOT follow the duplicate. Sharing a spline deliberately is the other half
	# of the design — an input spline reparented out of a preset and read from somewhere else — and if the
	# typed key behaved like the empty one there would be no way to express it.
	var src_typed := _give_graph(b, sa.spline_key())
	Pasture3DGraphSources.resolve_splines((b.modifiers[0] as Pasture3DNodeGraph).graph, b)
	var xt: float = (src_typed.path.points[0].x if src_typed.path != null
			and src_typed.path.points.size() > 0 else NAN)
	print("    control: RidgeB with a typed key naming \"%s\" resolved to x0 = %.1f (want ~-10, A's line)"
			% [sa.spline_key(), xt])
	if not (absf(xt + 10.0) < 0.6):
		_fail += 1
		print("    !! a typed key did not name the spline it typed")
	print("    (sb is %s, present so B has an own child to be tempted by)" % sb.name)
	_drop(t)


# --- C. A geometry brush owns no layer ----------------------------------------------------------------
func _c_a_geometry_brush_owns_no_layer() -> void:
	var t := _terrain()
	var mound := _mound_under(t, "Hill", Vector3.ZERO)
	var sp := _spline_under(t, "Line", Vector3.ZERO)

	# By USAGE, not by name. Every GDScript member variable appears in get_property_list() as a script
	# variable whatever `_get_property_list` does, so `_layer_owner` is present on both brushes and asking
	# whether the NAME is there answers a question nobody asked. What actually distinguishes them is the
	# extra STORAGE entry `_get_property_list` appends — that entry is what makes the binding persist into
	# a saved scene, and its absence is what this criterion is really about.
	var sp_has_layer := _has_layer_binding(sp)
	var mound_has_layer := _has_layer_binding(mound)
	var sibs: Array = mound._tools_on_owner(mound._layer_owner)
	print("    spline: paints=%s, _layer_owner=\"%s\", persisted layer binding=%s"
			% [str(sp._paints()), sp._layer_owner, str(sp_has_layer)])
	print("    mound:  paints=%s, _layer_owner=\"%s\", persisted layer binding=%s, %d sibling(s)"
			% [str(mound._paints()), mound._layer_owner, str(mound_has_layer), sibs.size()])
	_check("C", not sp_has_layer and sp._layer_owner == "" and not sibs.has(sp)
			and sp._ensure_layer_for(mound._layer_owner, false) == -1,
			"spline has no layer binding and is not a sibling of the mound's layer")

	# CONTROL: the SAME fixture with _paints() true — the mound — does all four of those things. Without
	# this the criterion above passes on a scene where nothing has a layer for unrelated reasons.
	print("    control: the mound (paints=true) does have the binding: props=%s, in its own sibling set=%s"
			% [str(mound_has_layer), str(sibs.has(mound))])
	if not mound_has_layer or not sibs.has(mound) or mound._layer_owner == "":
		_fail += 1
		print("    !! the painting control did not show the binding, so C measured nothing")
	_drop(t)


# --- D. An edit reaches its consumers, and no one else -------------------------------------------------
func _d_an_edit_reaches_its_consumers_and_no_one_else() -> void:
	var t := _terrain()
	var host := _mound_under(t, "Consumer", Vector3.ZERO)
	var bystander := _mound_under(t, "Bystander", Vector3(300.0, 0.0, 0.0))
	var sp := _spline_under(t, "River", Vector3(40.0, 0.0, 0.0))
	var src := _give_graph(host, sp.spline_key())

	# Nothing has resolved yet: the node holds no path at all.
	var before: int = src.path.points.size() if src.path != null else -1
	sp._refresh_consumers()
	var after: int = src.path.points.size() if src.path != null else -1
	var x_before: float = src.path.points[0].x if after > 0 else NAN

	# Now MOVE the line and refresh again. The consumer must see the new position without anyone baking.
	var line: Path3D = sp._get_splines()[0]
	line.curve.set_point_position(0, Vector3(-10.0, 0.0, 60.0))
	sp._refresh_consumers()
	var moved := false
	if src.path != null and src.path.points.size() > 0:
		for v in src.path.points:
			if absf(v.y - 60.0) < 0.6:
				moved = true
				break
	print("    consumer path: %d point(s) before resolve, %d after (first x %.1f)"
			% [before, after, x_before])
	print("    after moving a point to z = 60: the consumer's path contains it = %s" % str(moved))
	_check("D", before == -1 and after > 0 and moved,
			"the consumer resolved (%d point(s)) and followed the edit" % after)

	# CONTROL: a brush with no Spline Source naming this line is not a consumer and must not be touched.
	print("    control: the bystander reads this spline = %s (want false); the host reads it = %s"
			% [str(sp._brush_reads_spline(bystander, sp.spline_key())),
				str(sp._brush_reads_spline(host, sp.spline_key()))])
	if (sp._brush_reads_spline(bystander, sp.spline_key())
			or not sp._brush_reads_spline(host, sp.spline_key())):
		_fail += 1
		print("    !! consumer discovery matched the wrong set of brushes")
	_drop(t)


# --- E. Resolving an unchanged spline changes nothing ---------------------------------------------------
#
# `_assign` compares content_digest() before writing. Without that, a graph with a spline in it re-solves
# from scratch on every bake and the cache looks broken rather than bypassed.
func _e_resolving_an_unchanged_spline_changes_nothing() -> void:
	var t := _terrain()
	var host := _mound_under(t, "Consumer", Vector3.ZERO)
	var sp := _spline_under(t, "River", Vector3(40.0, 0.0, 0.0))
	var src := _give_graph(host, sp.spline_key())
	var g: Pasture3DTerrainGraph = (host.modifiers[0] as Pasture3DNodeGraph).graph

	var beats := [0]
	src.changed.connect(func() -> void: beats[0] += 1)
	Pasture3DGraphSources.resolve_splines(g, host)  # first: assigns, so it MUST emit
	var first: int = beats[0]
	Pasture3DGraphSources.resolve_splines(g, host)
	Pasture3DGraphSources.resolve_splines(g, host)
	var idle: int = beats[0] - first
	print("    first resolve emitted `changed` %d time(s); two more emitted %d" % [first, idle])
	_check("E", first >= 1 and idle == 0,
			"an unchanged spline re-resolved without touching the node (%d emission(s))" % idle)

	# CONTROL: moving a point MUST get through, or E is passing because resolution stopped working.
	sp._get_splines()[0].curve.set_point_position(1, Vector3(0.0, 30.0, 0.0))
	Pasture3DGraphSources.resolve_splines(g, host)
	var after_move: int = beats[0] - first - idle
	print("    control: after moving a point, resolve emitted %d time(s) (want >= 1)" % after_move)
	if after_move < 1:
		_fail += 1
		print("    !! a real edit did not get through, so the idle test proved nothing")
	_drop(t)


# --- F. Offered in exactly one dropdown -----------------------------------------------------------------
func _f_a_spline_is_offered_in_exactly_one_dropdown() -> void:
	var t := _terrain()
	var host := _mound_under(t, "Hill", Vector3.ZERO)
	var sp := _spline_under(t, "River", Vector3(40.0, 0.0, 0.0))

	var spline_keys := PackedStringArray()
	for b in Pasture3DGraphSources.spline_brushes(t):
		spline_keys.append(b.spline_key())
	var shape_keys := PackedStringArray()
	for b in Pasture3DGraphSources.shape_brushes(t):
		shape_keys.append(b.shape_key())

	# And through the resolver, which is what actually stamps the inspector lists.
	var ssrc := Pasture3DGraphNodeSplineSource.new()
	var told := [0]
	ssrc.property_list_changed.connect(func() -> void: told[0] += 1)
	var g1 := Pasture3DTerrainGraph.new()
	var n1: Array[Pasture3DGraphNode] = [ssrc]
	g1.nodes = n1
	Pasture3DGraphSources.resolve_splines(g1, host)

	var shsrc := Pasture3DGraphNodeShapeSource.new()
	var g2 := Pasture3DTerrainGraph.new()
	var n2: Array[Pasture3DGraphNode] = [shsrc]
	g2.nodes = n2
	Pasture3DGraphSources.resolve_shapes(g2, host)

	var hint := -1
	for prop in ssrc.get_property_list():
		if prop["name"] == &"spline_key":
			hint = int(prop["hint"])
			break
	print("    Spline Source offers %s" % str(Array(ssrc.editor_spline_keys)))
	print("    Shape Source  offers %s" % str(Array(shsrc.editor_shape_keys)))
	print("    spline_key hint %d (want %d, ENUM_SUGGESTION); inspector told %d time(s)"
			% [hint, PROPERTY_HINT_ENUM_SUGGESTION, told[0]])
	_check("F", Array(ssrc.editor_spline_keys).has(sp.spline_key())
			and not Array(shsrc.editor_shape_keys).has(sp.spline_key())
			and hint == PROPERTY_HINT_ENUM_SUGGESTION and told[0] >= 1,
			"listed by Spline Source only, as a suggestion, and the inspector was notified")

	# CONTROL: the Mound IS in the Shape Source list, so F is not passing because that list is empty.
	print("    control: shape_brushes = %s, spline_brushes = %s"
			% [str(Array(shape_keys)), str(Array(spline_keys))])
	if not shape_keys.has(host.shape_key()) or not spline_keys.has(sp.spline_key()):
		_fail += 1
		print("    !! one of the two collectors returned nothing, so the exclusion proved nothing")
	_drop(t)
