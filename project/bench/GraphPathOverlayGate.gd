extends Node

# GraphPathOverlayGate — THE VIEWPORT PATH OVERLAY (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §6.2, phase V3)
#
# The requirement: see the points of a Path Resample or a Path Drape in the 3D viewport, on the actual
# terrain, to confirm they did what they claim. A 128 px thumbnail cannot answer "did the drape work".
#
# ---- WHAT THIS GATE IS ACTUALLY ABOUT (§6.3) ----
#
# `Pasture3DGraphNodePathDerive.derive_without_grid` returns the input path UNCHANGED. So an overlay that
# asked a Path Drape for its path outside an evaluation gets back the UNDRAPED line — and draws it,
# confidently, as the answer. An undraped line drawn on terrain does not look broken. It looks like a path.
#
# So [A]'s CONTROL is the criterion: with the drape never evaluated, the overlay must draw NOTHING, while a
# line that a naive implementation would happily have drawn is demonstrably available. Asserting only that
# a resolved path is drawn correctly would pass on the naive implementation too, because when the drape HAS
# run the two answers agree. They differ exactly when the drape is broken, which is when the author is
# looking.
#
#   [A] the overlay draws the path the graph RESOLVED — through `derived_path()` and the drawn vertex
#       array, both — control: before any evaluation the overlay draws nothing, and the undraped line it
#       refused to draw is asserted to exist.
#   [B] a redraw increments no evaluation counter — counted on the node itself — control: a bake does move
#       it, so [B] is not reading a counter that never moves.
#   [C] a draped path's DRAWN heights are the terrain surface at its vertices — control: the undraped path
#       drawn on the same ground is not, and the ground is asserted non-flat. Plus the drop lines, which
#       are the signal an author actually reads: none for a draped path, many for an undraped one.
#   [D] the width envelope tracks per-vertex half-widths — control: a constant-width path draws parallel
#       offsets and a tapered one does not.
#   [E] a 1 m resample draws vertices 1 m apart, and the overlay's vertex count equals the RESOLVED path's
#       — control: the pre-resample count differs, so "drew the input" cannot pass.
#   [F] toggling `preview_on` changes what is drawn and does NOT bump the graph revision (§12.6) — control:
#       a real content edit does bump it.
#
# Headless. It builds a real Pasture3D with a real region so `drops` has ground to measure against, and
# writes only in memory — no `data_directory` is ever set, so nothing can reach the demo tiles.

const GraphPathOverlay: Script = preload("res://addons/pasture_3d/src/graph_path_overlay.gd")

const GW := 64
const GH := 64
const RECT := Rect2(0.0, 0.0, 200.0, 200.0)

var _fail := 0
var _checks := 0
var _terrain: Pasture3D = null


func _ready() -> void:
	print("=== GraphPathOverlayGate: the viewport PATH overlay (spec V3 §6.2) ===\n")
	if not _make_terrain():
		print("!! the fixture terrain could not be built; nothing was measured")
		get_tree().quit(1)
		return

	_a_the_overlay_draws_what_the_graph_resolved()
	_b_a_redraw_evaluates_nothing()
	_c_a_draped_path_sits_on_the_ground()
	_d_the_envelope_tracks_the_half_widths()
	_e_a_resample_is_visible_as_spacing()
	_f_the_toggle_is_view_state()

	if _checks < 34:
		print("\n    VACUOUS: only %d checks completed; the gate did not measure what it claims to."
				% _checks)
		_fail += 1
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["GRAPH PATH OVERLAY PASS" if _fail == 0 else "GRAPH PATH OVERLAY FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


# ---- fixtures -----------------------------------------------------------------------------------------

## The ground, and the single source of truth for it.
##
## A RAMP, not a plane at a constant height: on flat ground a draped path and an undraped one drawn at the
## same Y are the same picture, and every claim in [C] would be true of an overlay that ignored heights
## entirely. The one fixture property every criterion here depends on is that the ground GOES SOMEWHERE.
func _ground_at(p_x: float, p_z: float) -> float:
	return 20.0 + 0.25 * p_x + 0.05 * p_z


func _make_terrain() -> bool:
	_terrain = Pasture3D.new()
	_terrain.name = "OverlayGateTerrain"
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	if _terrain.data == null:
		return false
	_terrain.data.add_region_blankp(Vector3.ZERO)
	for iz in range(0, 220):
		for ix in range(0, 220):
			_terrain.data.set_height(Vector3(float(ix), 0.0, float(iz)),
					_ground_at(float(ix), float(iz)))
	return true


## The same ground as a grid, so the drape's INPUT and the overlay's drop-line reference are one surface.
## If they were two, [C] would be measuring the gap between two fixtures rather than the drape.
func _ground_grid() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	for iz in range(GH):
		for ix in range(GW):
			g[iz * GW + ix] = _ground_at(
					RECT.position.x + (float(ix) + 0.5) * dx,
					RECT.position.y + (float(iz) + 0.5) * dz)
	return g


## A straight run across the fixture, at height 0 — which is nowhere near the ground, so an undraped path
## is unmistakable rather than nearly right.
func _line(p_n: int = 9, p_half_width: float = 5.0) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var h := PackedFloat32Array()
	var w := PackedFloat32Array()
	for i in range(p_n):
		var f := float(i) / float(p_n - 1)
		pts.append(Vector2(20.0 + f * 160.0, 100.0))
		h.append(0.0)
		w.append(p_half_width)
	p.points = pts
	p.heights = h
	p.half_widths = w
	return p


## Brush -> one graph modifier -> the graph. The overlay walks exactly this, so the fixture is the shape it
## walks rather than a hand-built input to it.
func _host(p_graph: Pasture3DTerrainGraph) -> Pasture3DTerrainBrush:
	var brush := Pasture3DTerrainBrush.new()
	brush.name = "OverlayHost%d" % _checks
	brush.terrain = _terrain
	var mod := Pasture3DNodeGraph.new()
	mod.graph = p_graph
	brush.modifiers = [mod]
	add_child(brush)
	return brush


## Input -> Source -> <the PATH node under test> -> Carve -> Output, with the node previewed.
func _graph_with(p_node: Pasture3DGraphNode, p_path: Pasture3DGraphPath) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = p_path
	var carve := Pasture3DGraphNodePathCarve.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, p_node, carve, Pasture3DGraphNodeOutput.new()]
	g.nodes = ns
	g.connections = [
		[0, 0, 2, 1],  # Input  -> node port 1 (surface / field)
		[1, 0, 2, 0],  # Source -> node port 0 (path)
		[2, 0, 3, 1],  # node   -> Carve.path
		[0, 0, 3, 0],  # Input  -> Carve.surface
		[3, 0, 4, 0],  # Carve  -> Output
	]
	g.output_node = 4
	p_node.preview_on = true
	return g


func _drape() -> Pasture3DGraphNodePathDrape:
	return Pasture3DGraphNodePathDrape.new()


func _xz(p_v: Vector3) -> Vector2:
	return Vector2(p_v.x, p_v.z)


# --- A -------------------------------------------------------------------------------------------------
#
# THE CONTROL IS THE CRITERION (§6.3).
#
# Before any evaluation the drape has resolved nothing, and the overlay must draw NOTHING. The naive
# implementation — ask the node for its path — would at that moment be handed the UNDRAPED source line by
# `derive_without_grid` and would draw it as the answer. So the criterion asserts both halves: the overlay
# is empty, AND the line it declined to draw demonstrably existed. Without the second half, "drew nothing"
# would be satisfied by an overlay that draws nothing ever.
func _a_the_overlay_draws_what_the_graph_resolved() -> void:
	print("[A] the overlay draws the path the graph RESOLVED, and NOTHING before it has resolved one (§6.3)")

	var line := _line()
	var d := _drape()
	var g := _graph_with(d, line)
	var brush := _host(g)

	# ---- before evaluation ----
	var before: Dictionary = GraphPathOverlay.build(brush)
	_check(d.derived_path() == null,
			"control: the drape has resolved nothing yet (derived_path() is null), which is the state "
			+ "[A] is about")
	_check(PackedVector3Array(before["vertices"]).is_empty()
			and PackedVector3Array(before["centreline"]).is_empty(),
			"[A] with nothing resolved the overlay draws NOTHING — %d vertices, %d centreline points"
			% [PackedVector3Array(before["vertices"]).size(),
			PackedVector3Array(before["centreline"]).size()])
	_check((before["unresolved"] as Array).has(2),
			"[A] and it SAYS the node is unresolved (unresolved=%s) rather than silently omitting it"
			% str(before["unresolved"]))
	# THE HALF THAT MAKES THE ABOVE MEAN SOMETHING. A naive overlay had a perfectly plausible line to draw.
	var naive: Pasture3DGraphPath = d.derive_without_grid(line)
	_check(naive != null and naive.points.size() >= 2,
			"control: an overlay that asked the NODE instead of the graph would have been handed a "
			+ "%d-vertex line to draw (derive_without_grid returns the input UNCHANGED), so 'drew nothing' "
			% (0 if naive == null else naive.points.size())
			+ "is a refusal and not an empty fixture")
	var naive_flat := true
	if naive != null and naive.heights.size() > 0:
		for h in naive.heights:
			if absf(h) > 1.0e-6:
				naive_flat = false
	_check(naive_flat,
			"control: and that line is UNDRAPED (every height 0) while the ground under it is %.1f..%.1f m "
			% [_ground_at(20.0, 100.0), _ground_at(180.0, 100.0)]
			+ "— drawing it would have been a confident wrong answer, not a near miss")

	# ---- after evaluation ----
	g.evaluate(GW, GH, RECT, null, _ground_grid())
	var after: Dictionary = GraphPathOverlay.build(brush)
	var resolved: Pasture3DGraphPath = d.derived_path()
	_check(resolved != null and resolved.points.size() == line.points.size(),
			"control: the graph resolved a %d-vertex path, so [A]'s second half has something to draw"
			% (0 if resolved == null else resolved.points.size()))
	var verts: PackedVector3Array = after["vertices"]
	_check(verts.size() == line.points.size(),
			"[A] and the overlay now draws one vertex per resolved vertex (%d for %d)"
			% [verts.size(), line.points.size()])
	if resolved != null and verts.size() == resolved.points.size():
		var worst := 0.0
		for i in range(verts.size()):
			worst = maxf(worst, (_xz(brush.to_global(verts[i])) - resolved.points[i]).length())
		_check(worst < 1.0e-3,
				"[A] and every drawn vertex is AT a resolved vertex (worst XZ error %.6f m) — asserted on "
				% worst + "the drawn array, not on the fact that a draw happened")
	_check((after["drawn"] as Array).has(2) and (after["unresolved"] as Array).is_empty(),
			"[A] the node moved from unresolved to drawn (drawn=%s, unresolved=%s)"
			% [str(after["drawn"]), str(after["unresolved"])])

	brush.queue_free()


# --- B -------------------------------------------------------------------------------------------------
#
# §6.4: the overlay costs nothing at evaluation time, by construction — it reads a value the evaluation
# already stored. A redraw runs on selection, on camera moves and on every transform change, so an overlay
# that evaluated would present as "the editor got slower", which nobody bisects.
#
# COUNTED on `eval_path_count`, which the node itself increments. A gate that reasoned about it from the
# call graph would pass on any refactor that added a second route.
func _b_a_redraw_evaluates_nothing() -> void:
	print("\n[B] a redraw performs NO path evaluation — counted on the node (§6.4)")

	var d := _drape()
	var g := _graph_with(d, _line())
	var brush := _host(g)
	g.evaluate(GW, GH, RECT, null, _ground_grid())

	var before: int = d.eval_path_count
	for i in range(8):
		GraphPathOverlay.build(brush)
	_check(d.eval_path_count == before,
			"[B] eight redraws ran %d path evaluations (expected 0)" % [d.eval_path_count - before])
	# ...and they drew something, or [B] measured a redraw that returned early.
	var ov: Dictionary = GraphPathOverlay.build(brush)
	_check(PackedVector3Array(ov["vertices"]).size() > 0,
			"control: those redraws really did draw (%d vertices), so [B] measured a working overlay "
			% PackedVector3Array(ov["vertices"]).size() + "rather than one that bailed")

	# THE COUNTER CONTROL. Without it every zero above passes on a dead counter.
	var mid: int = d.eval_path_count
	d.set_meta(&"_force", true) # touch nothing the graph reads; the bake below is what must move it
	g.content_changed_bump() if g.has_method("content_changed_bump") else null
	d.min_drop = d.min_drop + 0.001 # a real parameter edit, so the memo cannot serve the old answer
	g.evaluate(GW, GH, RECT, null, _ground_grid())
	_check(d.eval_path_count > mid,
			"control: a real bake DOES increment the counter (%d -> %d), so the zeros above are "
			% [mid, d.eval_path_count] + "measurements and not a counter nobody moves")

	brush.queue_free()


# --- C -------------------------------------------------------------------------------------------------
#
# The drape check, which is the one that actually matters. Two ways of saying it, because they fail
# differently: the drawn HEIGHTS, and the DROP LINES an author reads at a glance.
#
# A correctly draped path has zero-length drops and shows none. An undraped one is a straight line floating
# over the ground with a visible vertical at every vertex. That absence-as-signal only works if the overlay
# refuses to emit degenerate drops, which is what DROP_EPSILON is for — so this asserts the count both ways.
func _c_a_draped_path_sits_on_the_ground() -> void:
	print("\n[C] a DRAPED path is drawn on the ground and shows no drop lines; an undraped one shows them")

	var d := _drape()
	var g := _graph_with(d, _line())
	var brush := _host(g)
	g.evaluate(GW, GH, RECT, null, _ground_grid())
	var ov: Dictionary = GraphPathOverlay.build(brush)
	var verts: PackedVector3Array = ov["vertices"]

	_check(absf(_ground_at(20.0, 100.0) - _ground_at(180.0, 100.0)) > 20.0,
			"control: the ground under the path FALLS %.1f m end to end, so a drape and a non-drape are "
			% absf(_ground_at(20.0, 100.0) - _ground_at(180.0, 100.0))
			+ "different pictures rather than the same one")

	var worst := 0.0
	for v in verts:
		var w: Vector3 = brush.to_global(v)
		worst = maxf(worst, absf((w.y - GraphPathOverlay.DRAW_LIFT) - _ground_at(w.x, w.z)))
	# One cell, per §11 [C]. The drape reads a 64x64 grid over 200 m, so a vertex between samples is
	# bilinear where the reference is exact — a tighter bound would be measuring the resolution.
	_check(worst < RECT.size.x / float(GW),
			"[C] every DRAWN height is the terrain surface at that vertex (worst %.3f m, one cell = "
			% worst + "%.3f m)" % (RECT.size.x / float(GW)))
	_check(PackedVector3Array(ov["drops"]).is_empty(),
			"[C] and the draped path shows NO drop lines (%d) — absence is the signal"
			% (PackedVector3Array(ov["drops"]).size() / 2))

	# ---- the control: the same overlay on a path that was never draped ----
	# A Path Resample instead of a Drape: it is a real, previewable PATH node that resolves normally and
	# carries the source's heights through unchanged, so the overlay HAS a resolved path to draw and the
	# difference is the drape and nothing else.
	var r := Pasture3DGraphNodePathResample.new()
	var g2 := _graph_with(r, _line())
	var brush2 := _host(g2)
	g2.evaluate(GW, GH, RECT, null, _ground_grid())
	var ov2: Dictionary = GraphPathOverlay.build(brush2)
	_check(PackedVector3Array(ov2["vertices"]).size() > 0,
			"control: the undraped fixture resolved and drew (%d vertices), so the comparison below is "
			% PackedVector3Array(ov2["vertices"]).size() + "between two drawn paths")
	var drops2: int = PackedVector3Array(ov2["drops"]).size() / 2
	_check(drops2 > 0,
			"[C] control: the UNDRAPED path shows %d drop line(s) on the same ground — the failed drape "
			% drops2 + "is visible, which is the affordance §6.2 item 4 exists for")

	var worst2 := 0.0
	for v in PackedVector3Array(ov2["vertices"]):
		var w: Vector3 = brush2.to_global(v)
		worst2 = maxf(worst2, absf((w.y - GraphPathOverlay.DRAW_LIFT) - _ground_at(w.x, w.z)))
	_check(worst2 > 20.0,
			"[C] control: and its drawn heights are NOT the surface (worst %.1f m), so [C]'s first half "
			% worst2 + "measured the drape rather than an overlay that snaps everything to the ground")

	# ---- [C3] the third case, which is neither of the two above ----
	#
	# A path that carries NO heights at all was drawn ON the surface (§6.2 item 1), so every drop would be
	# zero-length by construction. Emitting them would paint "perfectly draped" over a path that was never
	# draped — the same confident-wrong-answer [A]'s control is about, arriving by a different door. The
	# check is on the DRAWING rule, so it is driven at `_append_path` and asserted on the arrays produced.
	var bare := Pasture3DGraphPath.new()
	bare.points = _line().points
	bare.heights = PackedFloat32Array() # the whole point of the case
	var out_bare := {"centreline": PackedVector3Array(), "vertices": PackedVector3Array(),
			"envelope": PackedVector3Array(), "drops": PackedVector3Array(),
			"drawn": [], "unresolved": [], "vertex_count": 0}
	GraphPathOverlay._append_path(out_bare, brush, bare, brush.terrain.data)
	_check(PackedVector3Array(out_bare["drops"]).is_empty(),
			"[C3] a path carrying no heights emits NO drop lines (%d) — it was drawn on the surface, so a "
			% (PackedVector3Array(out_bare["drops"]).size() / 2)
			+ "drop would say \"perfectly draped\" about a path that was never draped")
	_check(PackedVector3Array(out_bare["vertices"]).size() == bare.points.size(),
			"control: and it DID draw (%d vertices), so the empty drops above are a rule and not a path "
			% PackedVector3Array(out_bare["vertices"]).size() + "that produced nothing")
	# The control that makes [C3] a measurement: the SAME points, given flat heights, do emit drops. So the
	# emptiness above is the heightless case being handled, not a drop path that never fires on this ground.
	var flat := Pasture3DGraphPath.new()
	flat.points = bare.points
	var hs := PackedFloat32Array()
	hs.resize(bare.points.size())
	hs.fill(0.0)
	flat.heights = hs
	var out_flat := {"centreline": PackedVector3Array(), "vertices": PackedVector3Array(),
			"envelope": PackedVector3Array(), "drops": PackedVector3Array(),
			"drawn": [], "unresolved": [], "vertex_count": 0}
	GraphPathOverlay._append_path(out_flat, brush, flat, brush.terrain.data)
	_check(PackedVector3Array(out_flat["drops"]).size() > 0,
			"control: the same points WITH heights emit %d drop line(s) on the same ground"
			% (PackedVector3Array(out_flat["drops"]).size() / 2))

	brush.queue_free()
	brush2.queue_free()


# --- D -------------------------------------------------------------------------------------------------
#
# §6.2 item 3, the affordance §2.3 found no prior art for. The envelope has to follow the PER-VERTEX
# half-widths or it is decoration: a tapered road drawn with parallel edges says the taper did not happen.
func _d_the_envelope_tracks_the_half_widths() -> void:
	print("\n[D] the width envelope is drawn at the path's own per-vertex half-widths (§6.2 item 3)")

	var const_line := _line(9, 5.0)
	var r := Pasture3DGraphNodePathResample.new()
	var g := _graph_with(r, const_line)
	var brush := _host(g)
	g.evaluate(GW, GH, RECT, null, _ground_grid())
	var ov: Dictionary = GraphPathOverlay.build(brush)
	var widths := _envelope_widths(ov, brush)
	_check(widths.size() > 2,
			"control: the envelope was drawn at all (%d measurable offsets)" % widths.size())
	var lo := INF
	var hi := -INF
	for w in widths:
		lo = minf(lo, w)
		hi = maxf(hi, w)
	_check(absf(lo - 5.0) < 0.05 and absf(hi - 5.0) < 0.05,
			"[D] a constant 5.0 m half-width draws parallel offsets (%.3f..%.3f m)" % [lo, hi])

	# ---- the tapered control ----
	var tapered := _line(9, 5.0)
	var hw := PackedFloat32Array()
	for i in range(tapered.points.size()):
		hw.append(1.0 + 4.0 * float(i) / float(tapered.points.size() - 1))
	tapered.half_widths = hw
	var r2 := Pasture3DGraphNodePathResample.new()
	var g2 := _graph_with(r2, tapered)
	var brush2 := _host(g2)
	g2.evaluate(GW, GH, RECT, null, _ground_grid())
	var w2 := _envelope_widths(GraphPathOverlay.build(brush2), brush2)
	var lo2 := INF
	var hi2 := -INF
	for w in w2:
		lo2 = minf(lo2, w)
		hi2 = maxf(hi2, w)
	_check(hi2 - lo2 > 2.0,
			"[D] control: a TAPERED path does not draw parallel offsets (%.2f..%.2f m), so [D]'s first "
			% [lo2, hi2] + "half measured the widths and not a fixed inset")
	_check(absf(hi2 - 5.0) < 0.6 and absf(lo2 - 1.0) < 0.6,
			"[D] and the offsets are the declared 1..5 m rather than some other varying number "
			+ "(%.2f..%.2f m)" % [lo2, hi2])

	brush.queue_free()
	brush2.queue_free()


## Distance in XZ from each drawn vertex to its own LEFT envelope point.
##
## Read out of the drawn arrays rather than recomputed from the path, so what is measured is what a viewer
## sees. The envelope is emitted as line PAIRS, four per segment: left[i-1], left[i], right[i-1], right[i].
func _envelope_widths(p_ov: Dictionary, p_brush) -> PackedFloat32Array:
	var verts: PackedVector3Array = p_ov["vertices"]
	var env: PackedVector3Array = p_ov["envelope"]
	var out := PackedFloat32Array()
	for i in range(1, verts.size()):
		var base := 4 * (i - 1)
		if base + 1 >= env.size():
			break
		out.append((_xz(p_brush.to_global(env[base + 1]))
				- _xz(p_brush.to_global(verts[i]))).length())
	return out


# --- E -------------------------------------------------------------------------------------------------
#
# The resample check, and the reason the vertices are drawn as DOTS rather than implied by the line: a 1 m
# resample shows 1 m spacing or it did not run. Two halves, because they fail apart — the SPACING says the
# resample did its job, and the COUNT says the overlay is showing its output rather than its input.
func _e_a_resample_is_visible_as_spacing() -> void:
	print("\n[E] a 1 m resample is visible as 1 m spacing, and the count is the RESOLVED path's (§6.2 item 2)")

	var src := _line(3, 5.0) # three vertices across 160 m: nothing like 1 m apart
	var r := Pasture3DGraphNodePathResample.new()
	r.step = 1.0
	var g := _graph_with(r, src)
	var brush := _host(g)
	g.evaluate(GW, GH, RECT, null, _ground_grid())

	var resolved: Pasture3DGraphPath = r.derived_path()
	var ov: Dictionary = GraphPathOverlay.build(brush)
	var verts: PackedVector3Array = ov["vertices"]
	_check(resolved != null and resolved.points.size() > 100,
			"control: the resample really ran (%d vertices from %d), so [E] is about a path that changed"
			% [0 if resolved == null else resolved.points.size(), src.points.size()])
	_check(verts.size() == (0 if resolved == null else resolved.points.size()),
			"[E] the overlay draws one dot per RESOLVED vertex (%d for %d)"
			% [verts.size(), 0 if resolved == null else resolved.points.size()])
	# THE CONTROL THAT MAKES THAT MEAN SOMETHING: the input had three. An overlay drawing the input would
	# draw three, and would look perfectly reasonable.
	_check(verts.size() != src.points.size(),
			"[E] control: the pre-resample path had %d vertices, so 'drew the input' cannot pass"
			% src.points.size())

	var lo := INF
	var hi := -INF
	for i in range(1, verts.size()):
		var d: float = (_xz(brush.to_global(verts[i])) - _xz(brush.to_global(verts[i - 1]))).length()
		lo = minf(lo, d)
		hi = maxf(hi, d)
	_check(hi <= 1.05,
			"[E] and consecutive drawn vertices are 1 m apart (%.4f..%.4f m)" % [lo, hi])

	brush.queue_free()


# --- F -------------------------------------------------------------------------------------------------
#
# §12.6, the same exemption `preview_on` has everywhere: a view flag must not participate in invalidation.
# The overlay is opt-in per node, so the toggle has to actually change what is drawn AND cost no bake.
func _f_the_toggle_is_view_state() -> void:
	print("\n[F] toggling preview_on changes the overlay and does NOT bump the graph revision (§12.6)")

	var r := Pasture3DGraphNodePathResample.new()
	var g := _graph_with(r, _line())
	var brush := _host(g)
	g.evaluate(GW, GH, RECT, null, _ground_grid())

	var on: Dictionary = GraphPathOverlay.build(brush)
	_check(PackedVector3Array(on["vertices"]).size() > 0,
			"control: with preview_on the node is drawn (%d vertices)"
			% PackedVector3Array(on["vertices"]).size())
	var rev_before: int = g.content_key()
	r.preview_on = false
	var off: Dictionary = GraphPathOverlay.build(brush)
	_check(PackedVector3Array(off["vertices"]).is_empty()
			and (off["drawn"] as Array).is_empty(),
			"[F] with it off the node is not drawn (%d vertices) — the overlay is opt-in per node, not "
			% PackedVector3Array(off["vertices"]).size() + "per brush")
	_check(g.content_key() == rev_before,
			"[F] and the toggle did not bump the content revision (%d -> %d), so it cannot invalidate a "
			% [rev_before, g.content_key()] + "host's frozen bake")
	r.preview_on = true
	_check(PackedVector3Array(GraphPathOverlay.build(brush)["vertices"]).size() > 0,
			"control: turning it back on redraws it, so [F] measured a toggle and not a one-way switch")
	# The revision control: a real content edit DOES move it.
	r.step = r.step + 1.0
	_check(g.content_key() != rev_before,
			"control: a real parameter edit DOES bump the revision (%d -> %d), so [F] measured the "
			% [rev_before, g.content_key()] + "exemption and not a revision that never moves")

	brush.queue_free()
