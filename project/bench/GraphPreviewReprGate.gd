# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPreviewReprGate — PASTURE3D_GRAPH_VISUALIZATION_SPEC.md V1: the representation & range contract.
#
# Criteria [A]-[H] are the V1 row of §11. They are being brought up one at a time, RED FIRST where the
# spec says a criterion must fail on the pre-change build.
#
#   [C] an unserved tap renders NO_DATA and a genuinely-zero field renders black, and THE TWO IMAGES
#       DIFFER — control: the same slot, served, renders neither.
#
#   [I] with a host bound but NO cached bake, the preview reads the host's real ground rather than the
#       canonical dome — controls on both neighbouring tiers, so it measures an ORDER, not a removal.
#
#   [H] with TWO BRUSHES HOSTING THE SAME GRAPH RESOURCE, the preview looks through the brush the gesture
#       named, and where the gesture named none it says so instead of picking one (§4.6, §5.6).
#       Asserted on the rect and grid size the tap ACTUALLY ran with.
#
# WHY [H] IS FIRST. It is the only V1 criterion the spec requires to be observed failing, and a criterion
# written after the fix is a criterion nobody has seen measure anything.
#
# WHAT THE PRE-CHANGE BUILD ACTUALLY DOES — measured before this was written, because §4.6 names the
# mechanism but not which gestures reach it. There are three, and only one of them is broken:
#
#   * select the BRUSH          -> `_bind(graph, mod, brush)`. The brush is named. Correct.
#   * select the MODIFIER       -> `_bind(mod.graph, mod, null)`. No brush, but each brush owns a DISTINCT
#                                  modifier instance, so `_find_brush_for_modifier` resolves it. Correct,
#                                  and asserted below as the control that the mechanism is not simply dead.
#   * select the GRAPH RESOURCE -> `_bind(graph, null, null)`. Now the only tier left is a scan of the
#                                  brush group by GRAPH identity, which returns the first match in SCENE
#                                  ORDER. With two hosts there is no right answer and it silently invents
#                                  one. This is §4.6, and it is what [H4] asserts.
#
# And one the spec does not name, found by driving the panel rather than reading it: `host_brush` is
# STICKY. `edit_graph` clears it only when the graph is null, so after opening from a brush, selecting an
# unrelated standalone graph leaves that brush bound — and `Pasture3DGraphSources.resolve(graph,
# host_brush)` then resolves the new graph's scene-naming sources through a brush that never hosted it.
# [H6].
#
# The fix these are written against (§5.6): a gesture that names no host and finds MORE THAN ONE candidate
# reports the ambiguity and falls back to the canonical domain rather than choosing; exactly one candidate
# is still bound, because that is unambiguous and is the standalone case §5.6 keeps; and a graph the bound
# brush does not host releases the binding.
#
# The assertions read `Pasture3DGraphEditor.last_preview_dispatch`, which the editor writes where it forms
# the tap arguments. Calling `_get_preview_input_data()` from here instead would measure a FRESH lookup
# rather than the one the preview used, and would pass whether or not the dispatch ever consulted the
# binding — the trap `a-gate-that-calls-the-node-measures-nothing` records.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphPreviewReprGate.tscn
extends Node

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== GraphPreviewReprGate: the representation & range contract (spec V1) ===\n")
	_a_a_mask_does_not_rescale()
	_a2_the_rest_of_the_taxonomy()
	_b_the_range_is_reported_and_lockable()
	_c_unserved_is_visible()
	_d_a_non_lowering_graph_says_so()
	_e_a_path_output_taps_no_grid()
	await _f_the_downscale_is_opt_in_and_badged()
	_g_previews_are_not_paid_for_by_evaluate()
	_h_host_binding_follows_the_gesture()
	_i_the_input_preview_reads_the_hosts_ground()

	if _checks < 114:
		print("\n    VACUOUS: only %d checks completed; the gate did not measure what it claims to." % _checks)
		_fail += 1
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["GRAPH PREVIEW REPR PASS" if _fail == 0 else "GRAPH PREVIEW REPR FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


# --- C -------------------------------------------------------------------------------------------------
#
# Spec 4.3: a black thumbnail had FOUR indistinguishable causes, and two of them were "the tap was not
# served". `graph_eval_grid_taps` zero-fills an unservable slot — callers rely on one field per request —
# so a zero-filled tap and a genuinely flat field were the same bytes. The fix is not to stop zero-filling
# but to REPORT it: `unserved` carries the request indices, and the worker renders those NO_DATA.
#
# This asserts on the tap's own report, not on a size check the gate performs itself. A gate that decided
# "unserved" by its own rule would pass whether or not the C++ ever said anything.
func _c_unserved_is_visible() -> void:
	print("[C] an unserved tap is visibly different from a field that is genuinely zero (4.3)")

	if not ClassDB.class_has_method("Pasture3DUtil", "preview_image_grid"):
		_check(false, "preview_image_grid is not bound — the DLL is stale; nothing was measured")
		return

	# Built explicitly rather than through the registry: a registry-default Noise node carries no
	# FastNoiseLite and evaluates FLAT, which makes every "differs from an all-zero field" comparison
	# below vacuous. The non-flat control caught exactly that.
	var g := Pasture3DTerrainGraph.new()
	var fnl := FastNoiseLite.new()
	fnl.seed = 11
	fnl.frequency = 0.05
	var src := Pasture3DGraphNodeNoise.new()
	src.noise = fnl
	src.amplitude = 7.0
	g.nodes = [src] as Array[Pasture3DGraphNode]
	g.output_node = 0

	var compiled: Dictionary = g.compile_graph_program_multi([0])
	if compiled.is_empty() or not compiled.get("slot_of", {}).has(0):
		_check(false, "the one-node graph did not compile; nothing was measured")
		return
	var live_slot: int = int(compiled["slot_of"][0])
	# A slot the program does not have. The evaluator cannot serve it, which is exactly the case that used
	# to arrive as an indistinguishable black square.
	var dead_slot: int = 9999

	var size := 32
	# A RAMP, not zeros. The first version of this fixture fed a flat input, and the served tap came back
	# flat too — at which point "the served tap differs from an all-zero field" is comparing zero with
	# zero. The control below is what caught it.
	var input := PackedFloat32Array()
	input.resize(size * size)
	for i in range(size * size):
		input[i] = float(i % size) / float(size) * 20.0
	var taps: Dictionary = Pasture3DUtil.graph_eval_grid_taps(
			compiled["program"], size, size, Rect2(0, 0, 100, 100), input,
			PackedInt32Array([live_slot, dead_slot]))

	var fields: Array = taps.get("fields", [])
	var unserved: PackedInt32Array = taps.get("unserved", PackedInt32Array())
	_check(fields.size() == 2, "the tap returned one field per request (got %d for 2)" % fields.size())
	if fields.size() != 2:
		return

	# The report itself, by REQUEST INDEX: request 1 is the dead slot, request 0 is live.
	_check(unserved.has(1), "[C] the unservable slot is reported unserved (unserved=%s)" % [unserved])
	_check(not unserved.has(0), "control: the LIVE slot is not reported unserved, so the report "
			+ "distinguishes rather than flagging everything")

	# Now the images. A genuinely-zero field is rendered by the same representation the live tap would use.
	var zero_field := PackedFloat32Array()
	zero_field.resize(size * size)
	zero_field.fill(0.0)
	var img_zero: PackedByteArray = Pasture3DUtil.preview_image_grid(
			zero_field, size, size, Pasture3DUtil.PREVIEW_MASK_ALPHA, 0.0, 1.0, false)
	var img_nodata: PackedByteArray = Pasture3DUtil.preview_image_grid(
			PackedFloat32Array(), size, size, Pasture3DUtil.PREVIEW_NO_DATA, 0.0, 0.0, false)
	var img_live: PackedByteArray = Pasture3DUtil.preview_image_grid(
			fields[0], size, size, Pasture3DUtil.PREVIEW_MASK_ALPHA, 0.0, 1.0, false)

	_check(img_zero.size() == size * size * 4 and img_nodata.size() == size * size * 4,
			"both images are full RGBA8 thumbnails (%d, %d bytes)" % [img_zero.size(), img_nodata.size()])
	_check(img_nodata != img_zero,
			"[C] NO_DATA and a genuinely-zero field are DIFFERENT images")

	# CONTROL. Without this, [C] would pass on a renderer that returned a different image for every call —
	# including one that never rendered the served tap correctly at all.
	_check(img_live != img_nodata and img_live != img_zero,
			"control: the SERVED tap renders as neither NO_DATA nor an all-zero field")
	# And the served field must actually carry something, or "differs from zero" is measuring noise.
	var mag := 0.0
	for v in (fields[0] as PackedFloat32Array):
		mag = maxf(mag, absf(v))
	_check(mag > 0.0, "control: the served tap is non-flat (|max| = %.4f), so the comparison is real" % mag)

# --- H -------------------------------------------------------------------------------------------------

## A brush whose graph modifier has already baked, so `last_input_surface` carries a real footprint.
##
## The rect is the identity. Two brushes with DIFFERENT rects is what makes the criterion decidable at
## all, and neither may equal `PREVIEW_RECT` — the canonical fallback dome is (-50,-50,100,100), so a
## fixture that reuses it cannot tell "picked this brush" from "gave up and used the dome". That is not
## hypothetical: the first version of this fixture did exactly that and read as a pass.
func _make_host(p_name: String, p_graph: Pasture3DTerrainGraph, p_rect: Rect2, p_size: int) -> Array:
	var brush := Pasture3DTerrainBrush.new()
	brush.name = p_name
	var mod := Pasture3DNodeGraph.new()
	mod.graph = p_graph
	# `_get_preview_input_data` prefers the modifier's cached bake over the canonical dome, and these four
	# are plain writable vars — so the fixture states a footprint rather than baking one.
	var grid := PackedFloat32Array()
	grid.resize(p_size * p_size)
	grid.fill(1.0)
	mod.last_input_surface = grid
	mod.last_gw = p_size
	mod.last_gh = p_size
	mod.last_rect = p_rect
	brush.modifiers = [mod]
	add_child(brush)
	return [brush, mod]


func _one_previewable_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	if n == null:
		return null
	g.add_node(n, Vector2.ZERO)
	g.output_node = 0
	n.preview_on = true
	return g


func _panel():
	var ed = GraphEditorScript.new()
	add_child(ed)
	# `_build_ui` hangs off `initialize`, not `_ready`, and `_rebuild` returns early without a GraphEdit —
	# so without this the panel silently builds no TextureRects and `_refresh_previews` dispatches nothing,
	# which the "recorded a dispatch" control below exists to catch.
	ed.initialize(null)
	return ed


## Drive a panel through one open gesture to a completed dispatch, and report the domain the tap ran over.
func _dispatch(p_editor, p_graph, p_mod, p_brush) -> Dictionary:
	p_editor.last_preview_dispatch = {}
	p_editor.edit_graph(p_graph, p_mod, p_brush)
	p_editor._refresh_previews()
	return p_editor.last_preview_dispatch


func _h_host_binding_follows_the_gesture() -> void:
	print("[H] the preview looks through the brush the gesture named (§4.6, §5.6)")

	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		_check(false, "graph_eval_grid_taps is not bound — rebuild the GDExtension; nothing was measured")
		return

	var graph := _one_previewable_graph()
	if graph == null:
		_check(false, "the registry could not create a `noise` node; nothing was measured")
		return

	var canonical: Rect2 = GraphEditorScript.PREVIEW_RECT
	var rect_a := Rect2(100.0, 100.0, 120.0, 120.0)
	var rect_b := Rect2(400.0, 900.0, 250.0, 250.0)
	var a := _make_host("BrushA", graph, rect_a, 64)
	var b := _make_host("BrushB", graph, rect_b, 96)

	_check(rect_a != rect_b and rect_a != canonical and rect_b != canonical,
			"control: the two footprints differ and neither is the canonical dome %s" % canonical)

	var ed = _panel()
	var from_a := _dispatch(ed, graph, a[1], null)
	var from_b := _dispatch(ed, graph, b[1], null)

	_check(not from_a.is_empty() and not from_b.is_empty(),
			"control: both gestures produced a recorded dispatch (A=%s, B=%s)"
			% [not from_a.is_empty(), not from_b.is_empty()])
	if from_a.is_empty() or from_b.is_empty():
		return

	# [H3] The working gesture, asserted so the criteria below cannot pass on a dead mechanism. Selecting
	# a modifier names no brush, but each brush owns its own modifier instance, so this resolves.
	print("        select A's modifier -> %s at %dx%d"
			% [from_a.get("rect"), int(from_a.get("gw", 0)), int(from_a.get("gh", 0))])
	print("        select B's modifier -> %s at %dx%d"
			% [from_b.get("rect"), int(from_b.get("gw", 0)), int(from_b.get("gh", 0))])
	_check(from_a.get("rect") == rect_a and int(from_a.get("gw", 0)) == 64
			and from_b.get("rect") == rect_b and int(from_b.get("gw", 0)) == 96,
			"[H3] selecting a modifier previews over ITS brush's footprint")

	# [H4] The §4.6 defect. A fresh panel, the graph resource selected, two hosts, no gesture naming one.
	var ed2 = _panel()
	var ambiguous := _dispatch(ed2, graph, null, null)
	print("        select the shared graph resource -> %s (host=%s)"
			% [ambiguous.get("rect"), ambiguous.get("brush")])
	_check(ambiguous.get("rect") == canonical,
			"[H4] a graph with TWO hosts and none named falls back to the canonical domain instead of "
			+ "picking by scene order (got %s)" % ambiguous.get("rect"))
	_check(ed2.has_method("host_ambiguous") and ed2.host_ambiguous(),
			"[H4] and the panel reports the binding as ambiguous")

	# [H5] §5.6's other half: the panel SAYS which terrain it is looking through. "your brush's ground"
	# and "a synthetic dome" are different pictures that used to look identical.
	var lbl_amb: String = ed2._host_label.text if ed2._host_label != null else ""
	var lbl_bound: String = ed._host_label.text if ed._host_label != null else ""
	print("        label when bound = %s | label when ambiguous = %s" % [lbl_bound, lbl_amb])
	_check(lbl_amb.contains("ambiguous"), "[H5] the ambiguous panel names the ambiguity (got '%s')" % lbl_amb)
	# `ed` is bound through BrushA's modifier at this point in the sequence, not BrushB — the rebinding to
	# B happens in [H6] below. Naming the brush the panel is actually on is the point of the control.
	_check(lbl_bound.contains("BrushA"), "control: a bound panel names its brush instead (got '%s')" % lbl_bound)

	# CONTROL for [H4]. If a single-host graph also refused to bind, [H4] would be measuring a blanket
	# refusal rather than the ambiguity rule, and it would break the standalone case §5.6 keeps.
	var solo := _one_previewable_graph()
	var rect_c := Rect2(-800.0, -800.0, 60.0, 60.0)
	var _c := _make_host("BrushC", solo, rect_c, 48)
	var ed3 = _panel()
	var single := _dispatch(ed3, solo, null, null)
	_check(single.get("rect") == rect_c
			and ed3.has_method("host_ambiguous") and not ed3.host_ambiguous(),
			"control: a graph with exactly ONE host still binds it (got %s)" % single.get("rect"))

	# [H6] The sticky binding. Bind to B, then open an unrelated standalone graph.
	var unrelated := _one_previewable_graph()
	_dispatch(ed, graph, b[1], b[0])
	_check(ed.host_brush == b[0], "control: the panel is bound to BrushB before the switch")
	_dispatch(ed, unrelated, null, null)
	_check(ed.host_brush == null,
			"[H6] switching to a graph the bound brush does not host releases the binding (host=%s)"
			% ed.host_brush)

	# The panels connect to each graph's `changed` and hold TextureRects; the brushes are Node3Ds added to
	# this scene. Free everything the criterion made, so a shutdown crash cannot be blamed on the fixture.
	for n in [ed, ed2, ed3, a[0], b[0], _c]:
		if is_instance_valid(n):
			n.queue_free()


# --- I -------------------------------------------------------------------------------------------------
#
# The Input node's thumbnail showed the canonical dome under a CORRECTLY BOUND host. Not a binding bug —
# [H] covers those and the toolbar said "through: Mound" the whole time. `last_input_surface` is a plain
# runtime var, never serialised, so it is empty after every project load until the host bakes again, and a
# brush whose stamp cache is warm need not bake at all. The preview then fell straight through to the
# brush-independent dome, which looks like a working thumbnail of the wrong terrain.
#
# The fix inserts a middle tier: read the finished ground under the host's footprint. So this criterion is
# about TIER ORDER, and it is asserted on the domain the tap ACTUALLY dispatched over — the same
# `last_preview_dispatch` [H] reads — not on a fresh `_get_preview_input_data()` call of the gate's own.
#
# The three tiers, and why each control is here:
#   I1  cached bake present   -> tier 1. Control: proves the new tier did not DISPLACE the exact surface.
#   I2  cache empty, host has terrain -> tier 2, at the FOOTPRINT rect, carrying the terrain's heights.
#   I3  no host at all        -> tier 3, the canonical dome. Control: the fallback still exists, so I2 is
#                               measuring a choice rather than the removal of an alternative.
#
# The rects are deliberately three DIFFERENT values. Sharing any two would make one tier indistinguishable
# from another — the trap that made an earlier [H] fixture read as a pass while measuring nothing.
func _i_the_input_preview_reads_the_hosts_ground() -> void:
	print("\n[I] the preview input falls to the host's real ground before the canonical dome")

	var terrain := Pasture3D.new()
	terrain.name = "GateTerrain"
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	if terrain.data == null:
		_check(false, "the fixture terrain has no data; nothing was measured")
		terrain.queue_free()
		return
	terrain.data.add_region_blankp(Vector3.ZERO)

	# A ramp in X, so "the grid carries the terrain" is a real measurement. A blank region is all zeros,
	# which is exactly what an unserved / fallback read also looks like.
	var lo := 4.0
	var hi := 40.0
	for iz in range(0, 64):
		for ix in range(0, 64):
			terrain.data.set_height(Vector3(float(ix), 0.0, float(iz)),
					lo + (hi - lo) * float(ix) / 63.0)

	var graph := _one_previewable_graph()
	# Tier 1's rect. Distinct from the footprint rect below and from PREVIEW_RECT.
	var bake_rect := Rect2(500.0, 500.0, 60.0, 60.0)
	var h := _make_host("GroundHost", graph, bake_rect, 16)
	var brush: Pasture3DTerrainBrush = h[0]
	var mod: Pasture3DNodeGraph = h[1]
	brush.terrain = terrain
	# `_own_footprints` reads the brush's SPLINES, so without one there is no footprint and the ground tier
	# declines — which would make [I2] fail for a reason that has nothing to do with the tier order. A
	# square well inside the region written above.
	var path := Path3D.new()
	var curve := Curve3D.new()
	for corner in [Vector3(8, 0, 8), Vector3(52, 0, 8), Vector3(52, 0, 52), Vector3(8, 0, 52)]:
		curve.add_point(corner)
	path.curve = curve
	brush.add_child(path)

	var ed = _panel()
	_dispatch(ed, graph, mod, brush)
	var d1: Dictionary = ed.last_preview_dispatch
	_check(not d1.is_empty(), "control: the bound gesture produced a recorded dispatch")
	if d1.is_empty():
		for n in [ed, brush, terrain]:
			if is_instance_valid(n):
				n.queue_free()
		return
	_check(d1.get("rect", Rect2()) == bake_rect,
			"[I1] control: with a cached bake, tier 1 still wins — the new tier did not displace the "
			+ "exact surface (rect=%s)" % [d1.get("rect")])

	# Now empty the cache, which is the state every project load starts in.
	mod.last_input_surface = PackedFloat32Array()
	ed._ground_cache.clear()
	_dispatch(ed, graph, mod, brush)
	var d2: Dictionary = ed.last_preview_dispatch
	var r2: Rect2 = d2.get("rect", Rect2())
	_check(r2 != ed.PREVIEW_RECT,
			"[I2] with no cached bake the preview is NOT the canonical dome (rect=%s)" % [r2])
	_check(r2 != bake_rect, "[I2] and it is not the stale bake rect either (rect=%s)" % [r2])

	# The tier must have read the ground, not merely chosen a rect. These next checks call
	# `_sample_host_ground` DIRECTLY, so on their own they would pass on a build where the tier exists and
	# the preview never consults it — the `a-gate-that-calls-the-node-measures-nothing` trap. Watched red
	# with the tier unwired from `_get_preview_input_data`: exactly ONE check went red, the dispatch-derived
	# rect above, and these stayed green. They are here to say WHAT the tier read, not THAT it was used.
	# and check the ramp survives: min and max must bracket what was written, and differ from each other.
	var g2: Dictionary = ed._sample_host_ground()
	var grid: PackedFloat32Array = g2.get("grid", PackedFloat32Array())
	_check(not grid.is_empty(), "[I2] the ground tier produced a grid (%d cells)" % grid.size())
	if not grid.is_empty():
		var gmin := INF
		var gmax := -INF
		for v in grid:
			gmin = minf(gmin, v)
			gmax = maxf(gmax, v)
		_check(gmax - gmin > 1.0,
				"[I2] the grid carries the terrain's RAMP, not a flat fill (min=%.2f max=%.2f)"
				% [gmin, gmax])
		_check(gmax <= hi + 0.5 and gmin >= 0.0,
				"[I2] and the values are the heights that were written, not something rescaled "
				+ "(min=%.2f max=%.2f, wrote %.1f..%.1f)" % [gmin, gmax, lo, hi])
		# The memo. Comparing two calls for EQUALITY would pass on a tier that re-read the terrain every
		# time, so change the ground underneath and require the second call to be STALE — that can only
		# happen if it never went back to `get_height`. 4096 calls on every debounced refresh is the cost
		# the tier's doc comment forbids.
		for iz in range(0, 64):
			for ix in range(0, 64):
				terrain.data.set_height(Vector3(float(ix), 0.0, float(iz)), 900.0)
		_check(ed._sample_host_ground().get("grid") == grid,
				"control: a second call is served from the memo — it did NOT re-read the changed ground")
		ed._ground_cache.clear()
		var fresh: PackedFloat32Array = ed._sample_host_ground().get("grid", PackedFloat32Array())
		_check(not fresh.is_empty() and fresh != grid,
				"control: and clearing the memo DOES re-read, so the staleness above is the memo and "
				+ "not a tier that reads nothing")

	# [I3] No host, no terrain: the canonical dome is still what a standalone graph gets.
	var solo := _one_previewable_graph()
	var ed3 = _panel()
	_dispatch(ed3, solo, null, null)
	var d3: Dictionary = ed3.last_preview_dispatch
	_check(not d3.is_empty(), "control: the standalone gesture dispatched at all")
	_check(d3.get("rect", Rect2()) == ed.PREVIEW_RECT,
			"[I3] control: with NO host the canonical dome is still served, so [I2] measured a choice "
			+ "between live alternatives (rect=%s)" % [d3.get("rect")])

	for n in [ed, ed3, brush, terrain]:
		if is_instance_valid(n):
			n.queue_free()


# --- A -------------------------------------------------------------------------------------------------
#
# §5.2 Rule 1, the load-bearing rule of V1: THE RANGE IS CHOSEN BY THE PORT TYPE, NOT BY THE DATA.
#
# A MASK renders on an absolute 0..1 scale, always. The bug this closes (§4.2) is that min/max
# normalisation makes a mask spanning 0.28..0.32 look identical to one spanning 0..1 — full black to full
# white either way — so the author cannot see that a threshold is barely doing anything, and the parameter
# that would fix it appears to have no effect.
#
# Asserted on the RENDERED BYTES, because that is the artifact the author reads. Two controls, and both
# are load-bearing:
#
#   * a HEIGHT output given the same two fields must render IDENTICALLY under its auto range. Without it
#     the criterion passes on a renderer that returns a different image for every call — "these two
#     differ" is trivially true of a renderer that never repeats itself.
#   * the mask fixture is asserted NON-UNIFORM. Two all-black squares are also identical.
func _a_a_mask_does_not_rescale() -> void:
	print("\n[A] a MASK renders on its absolute range; a HEIGHT rescales to its own (§5.2 Rule 1)")

	if not ClassDB.class_has_method("Pasture3DUtil", "preview_image_grid"):
		_check(false, "preview_image_grid is not bound — the DLL is stale; nothing was measured")
		return

	var n := 32
	# The SAME SHAPE at two different scales. Same pattern, so any difference in the rendered bytes is the
	# range rule and not a different picture: `narrow` is `wide` squeezed into 0.28..0.32.
	var wide := PackedFloat32Array()
	var narrow := PackedFloat32Array()
	wide.resize(n * n)
	narrow.resize(n * n)
	for iz in range(n):
		for ix in range(n):
			var t: float = float(ix) / float(n - 1)
			wide[iz * n + ix] = t
			narrow[iz * n + ix] = 0.28 + 0.04 * t

	# The fixture must vary, or "identical" and "both blank" are the same answer.
	var wmin := INF
	var wmax := -INF
	for v in wide:
		wmin = minf(wmin, v)
		wmax = maxf(wmax, v)
	_check(wmax - wmin > 0.5, "control: the fixture is non-uniform (%.2f..%.2f), so two identical images "
			% [wmin, wmax] + "cannot pass by both being blank")

	# The types drive everything. Nothing below names a representation directly.
	var mask_repr: int = GraphEditorScript.preview_repr_for_type(Pasture3DGraphNode.PortType.MASK)
	var height_repr: int = GraphEditorScript.preview_repr_for_type(Pasture3DGraphNode.PortType.HEIGHT)
	_check(mask_repr == Pasture3DUtil.PREVIEW_MASK_ALPHA and height_repr == Pasture3DUtil.PREVIEW_HILLSHADE,
			"the representation comes from the declared type (MASK->%d, HEIGHT->%d)"
			% [mask_repr, height_repr])

	var img_mask_wide := _render(mask_repr, wide)
	var img_mask_narrow := _render(mask_repr, narrow)
	_check(img_mask_wide != img_mask_narrow,
			"[A] the two MASK fields are NOT rendered identically — 0.28..0.32 stays dim against an "
			+ "absolute scale, which is the whole point of one")

	# And the ranges themselves: a mask's range must not move with its data.
	var r_wide: Dictionary = GraphEditorScript.resolve_preview_range(mask_repr, wide, false, 0.0, 1.0)
	var r_narrow: Dictionary = GraphEditorScript.resolve_preview_range(mask_repr, narrow, false, 0.0, 1.0)
	_check(r_wide["min"] == 0.0 and r_wide["max"] == 1.0
			and r_narrow["min"] == 0.0 and r_narrow["max"] == 1.0,
			"[A] a MASK's range is 0..1 for BOTH fields (wide=%.2f..%.2f narrow=%.2f..%.2f)"
			% [r_wide["min"], r_wide["max"], r_narrow["min"], r_narrow["max"]])

	# THE CONTROL. A HEIGHT output on the same two fields rescales, so its two ranges differ — and once
	# rescaled its two IMAGES agree. That agreement is the normalisation bug, reproduced deliberately, on
	# the type where it is correct behaviour. Without it the criterion cannot tell the type rule from a
	# renderer that ignores its range argument.
	var h_wide: Dictionary = GraphEditorScript.resolve_preview_range(height_repr, wide, false, 0.0, 1.0)
	var h_narrow: Dictionary = GraphEditorScript.resolve_preview_range(height_repr, narrow, false, 0.0, 1.0)
	_check(absf(h_narrow["min"] - 0.28) < 0.001 and absf(h_narrow["max"] - 0.32) < 0.001,
			"control: a HEIGHT output DOES take its range from the data (%.3f..%.3f)"
			% [h_narrow["min"], h_narrow["max"]])
	_check(h_wide["min"] != h_narrow["min"],
			"control: and the two HEIGHT ranges differ, so the type rule is what makes the mask's equal")

	# The rendered half of the same control, and TWO corrections worth recording, because each was a wrong
	# assumption about the renderer rather than about the rule:
	#
	#   1. HILLSHADE is relief-LIT. Its pixels depend on the field's GRADIENT in real units as well as on
	#      the normalised value, so two auto-ranged hillshades of differently-scaled data differ even
	#      though the normalisation collapsed them.
	#   2. RAW_GRAY does not normalise AT ALL — by design, it is the "show me the actual numbers as
	#      brightness" escape hatch and ignores the measured range. Reaching for it here made this control
	#      pass in [B] for a while by saturating both fields to white: two identical images, measuring
	#      nothing. That is the third vacuous fixture this session and the reason the guard below is here.
	#
	# RAMP_SEQ is the representation that is unlit AND normalises, so it isolates the rescale.
	var img_g_wide := _render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, wide, h_wide)
	var img_g_narrow := _render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, narrow, h_narrow)
	var d_rescaled := _max_byte_diff(img_g_wide, img_g_narrow)
	var d_mask := _max_byte_diff(img_mask_wide, img_mask_narrow)
	_check(d_rescaled <= 2,
			"control: rescaled to their own extremes the two fields render to the SAME image under an "
			+ "unlit normalising representation (max channel difference %d) — the same rescale, on a "
			% d_rescaled + "type where it is correct")
	_check(d_mask > 20 * maxi(d_rescaled, 1),
			"control: and the MASK difference (%d) is orders larger than that float-precision residue "
			% d_mask + "(%d), so [A] is measuring the type rule and not rounding" % d_rescaled)
	_check(_is_varied(img_g_wide),
			"control: and that shared image is NOT uniform, so the two did not agree by both saturating")


## True when a rendered thumbnail actually varies. Two IDENTICAL images prove a rescale only if the image
## is not a single flat colour — "both all-white" is also identical, and it is how a control that means to
## measure normalisation ends up measuring saturation instead.
func _is_varied(p_bytes: PackedByteArray) -> bool:
	if p_bytes.size() < 8:
		return false
	for i in range(4, p_bytes.size(), 4):
		if p_bytes[i] != p_bytes[0] or p_bytes[i + 1] != p_bytes[1] or p_bytes[i + 2] != p_bytes[2]:
			return true
	return false


## Largest per-channel difference between two rendered thumbnails, or 256 if they are not comparable.
##
## Byte equality is the wrong test for "the rescale collapsed these two". Normalising 0.28 + 0.04t back to
## t in float32 does not reproduce t bit-for-bit — subtracting an offset and dividing by a small span
## loses the low bits — so two images that agree about everything the rule governs still differ by an LSB
## here and there. This reports the magnitude instead, and the callers assert against it with the
## comparison that makes the tolerance meaningful: the difference the RULE produces is two orders larger
## than the difference the arithmetic produces, and a threshold is only honest when both are printed.
func _max_byte_diff(p_a: PackedByteArray, p_b: PackedByteArray) -> int:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return 256
	var worst := 0
	for i in range(p_a.size()):
		if (i & 3) == 3:
			continue # alpha is a constant 255 in every representation
		worst = maxi(worst, absi(int(p_a[i]) - int(p_b[i])))
	return worst


func _render(p_repr: int, p_field: PackedFloat32Array) -> PackedByteArray:
	var rng: Dictionary = GraphEditorScript.resolve_preview_range(p_repr, p_field, false, 0.0, 1.0)
	return _render_ranged(p_repr, p_field, rng)


func _render_ranged(p_repr: int, p_field: PackedFloat32Array, p_rng: Dictionary) -> PackedByteArray:
	var n := int(round(sqrt(float(p_field.size()))))
	return Pasture3DUtil.preview_image_grid(p_field, n, n, p_repr,
			p_rng["min"], p_rng["max"], bool(p_rng["mark"]))


# --- A2 ------------------------------------------------------------------------------------------------
#
# The rest of §5.3's table, and the reason the 2026-09-06 port audit had to come first: FIELD and SIGNED
# did not exist, so RAMP_SEQ and RAMP_DIV had no type to be the default for and could only ever have been
# manual choices. A signed field's ramp must be SYMMETRIC about zero, or the neutral hue lands somewhere
# other than 0 and the ramp reports a convexity as a concavity.
func _a2_the_rest_of_the_taxonomy() -> void:
	print("\n[A2] every field type maps to its representation, and SIGNED is symmetric about zero (§5.3)")

	var want := {
		Pasture3DGraphNode.PortType.HEIGHT: Pasture3DUtil.PREVIEW_HILLSHADE,
		Pasture3DGraphNode.PortType.MASK: Pasture3DUtil.PREVIEW_MASK_ALPHA,
		Pasture3DGraphNode.PortType.FIELD: Pasture3DUtil.PREVIEW_RAMP_SEQ,
		Pasture3DGraphNode.PortType.SIGNED: Pasture3DUtil.PREVIEW_RAMP_DIV,
	}
	var all_ok := true
	var distinct := {}
	for t in want:
		var got: int = GraphEditorScript.preview_repr_for_type(t)
		distinct[got] = true
		if got != want[t]:
			all_ok = false
			print("        type %d -> %d, expected %d" % [t, got, want[t]])
	_check(all_ok, "[A2] the four field types map to their §5.3 representations")
	_check(distinct.size() == 4, "control: the four map to four DISTINCT representations (%d), so a "
			% distinct.size() + "function returning one constant cannot pass")

	# A value type has no grid, so it must decline rather than render one. "A grid render of a non-grid
	# is a lie shaped like data."
	var declined := true
	for t in [Pasture3DGraphNode.PortType.VECTOR, Pasture3DGraphNode.PortType.CURVE,
			Pasture3DGraphNode.PortType.BOOL, Pasture3DGraphNode.PortType.FLOAT,
			Pasture3DGraphNode.PortType.INT, Pasture3DGraphNode.PortType.COLOR]:
		if GraphEditorScript.preview_repr_for_type(t) >= 0:
			declined = false
			print("        value type %d was given representation %d"
					% [t, GraphEditorScript.preview_repr_for_type(t)])
	_check(declined, "[A2] the VALUE types get no thumbnail representation at all")

	# The symmetric range. A field running -2..+8 must render against -8..+8, not -2..+8.
	var n := 16
	var signed_field := PackedFloat32Array()
	signed_field.resize(n * n)
	for i in range(n * n):
		signed_field[i] = -2.0 + 10.0 * (float(i) / float(n * n - 1))
	var sr: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_RAMP_DIV, signed_field, false, 0.0, 1.0)
	_check(absf(sr["min"] + 8.0) < 0.001 and absf(sr["max"] - 8.0) < 0.001,
			"[A2] a SIGNED field's range is symmetric about zero (%.2f..%.2f for data -2..+8)"
			% [sr["min"], sr["max"]])
	# Control: the same data on an unsigned FIELD is NOT symmetrised, or "symmetric" is just what this
	# function always returns.
	var ur: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_RAMP_SEQ, signed_field, false, 0.0, 1.0)
	_check(absf(ur["min"] + 2.0) < 0.001,
			"control: an unsigned FIELD keeps its own minimum (%.2f), so the symmetry is the SIGNED "
			% ur["min"] + "rule and not a blanket transform")


# --- B -------------------------------------------------------------------------------------------------
#
# §5.2 Rules 2, 3 and 4: the range is on screen, it is lockable, and a locked range marks its overflow.
#
# The chip is a READOUT, not a second source. `check-derived-values-outside-the-chain` says comparing a
# derived value against the number it came from proves only that the derivation is a function — so [B1]
# computes min and max HERE, independently, and compares them against the numbers the chip shows.
#
# [B2] is the criterion that matters for the bug. Locking is the fix for "the slider does nothing": with
# the range pinned, moving the data must MOVE THE PICTURE. So it asserts the opposite of [A]'s control —
# under AUTO the two fields render the same, under LOCK they must not.
func _b_the_range_is_reported_and_lockable() -> void:
	print("\n[B] the range chip reads the data, and locking makes the picture move (§5.2 Rules 2-4)")

	var n := 32
	var lo_field := PackedFloat32Array()
	var hi_field := PackedFloat32Array()
	lo_field.resize(n * n)
	hi_field.resize(n * n)
	for iz in range(n):
		for ix in range(n):
			var t: float = float(ix) / float(n - 1)
			lo_field[iz * n + ix] = 10.0 + 5.0 * t      # 10 .. 15
			hi_field[iz * n + ix] = 10.0 + 40.0 * t     # 10 .. 50

	var height_repr: int = GraphEditorScript.preview_repr_for_type(Pasture3DGraphNode.PortType.HEIGHT)

	# [B1] the chip's numbers, against a min/max this gate computed for itself.
	var indep_min := INF
	var indep_max := -INF
	for v in lo_field:
		indep_min = minf(indep_min, v)
		indep_max = maxf(indep_max, v)
	var auto_rng: Dictionary = GraphEditorScript.resolve_preview_range(height_repr, lo_field, false, 0.0, 1.0)
	var chip: String = GraphEditorScript.range_chip_text(auto_rng)
	_check(absf(auto_rng["min"] - indep_min) < 0.0001 and absf(auto_rng["max"] - indep_max) < 0.0001,
			"[B1] the reported range equals a min/max computed OUTSIDE the preview path "
			+ "(%.3f..%.3f vs %.3f..%.3f)" % [auto_rng["min"], auto_rng["max"], indep_min, indep_max])
	_check(chip.begins_with("AUTO") and chip.contains("10.00") and chip.contains("15.00"),
			"[B1] and the chip TEXT carries those numbers and says which rule made them (got '%s')" % chip)

	# Control: the chip is not a constant string. A different field must produce a different chip.
	var chip2: String = GraphEditorScript.range_chip_text(
			GraphEditorScript.resolve_preview_range(height_repr, hi_field, false, 0.0, 1.0))
	_check(chip != chip2, "control: a different field gives a different chip, so [B1] is not comparing "
			+ "against a fixed string (got '%s')" % chip2)

	# A mask says MASK, not AUTO — its 0.00 - 1.00 is not a measurement of this grid and labelling it
	# AUTO would claim it was.
	var mask_chip: String = GraphEditorScript.range_chip_text(GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_MASK_ALPHA, lo_field, false, 0.0, 1.0))
	_check(mask_chip.begins_with("MASK"),
			"[B1] a mask's chip names the rule rather than claiming a measurement (got '%s')" % mask_chip)

	# [B2] AUTO hides the change; LOCK shows it. This pair IS the §4.2 bug and its fix.
	# Under AUTO the parameter change is invisible. RAMP_SEQ for the reasons recorded in [A]: HILLSHADE
	# carries gradient as well as range, and RAW_GRAY does not normalise at all.
	var img_auto_lo := _render(Pasture3DUtil.PREVIEW_RAMP_SEQ, lo_field)
	var img_auto_hi := _render(Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field)
	var d_auto := _max_byte_diff(img_auto_lo, img_auto_hi)
	_check(d_auto <= 2,
			"control: under AUTO the two fields render to the SAME image (max channel difference %d) — "
			% d_auto + "the parameter change is invisible, which is the defect §4.2 opens with")
	_check(_is_varied(img_auto_lo),
			"control: and that image is NOT uniform, so the agreement is a rescale and not two "
			+ "saturated squares")

	# The lock must come OUT of `resolve_preview_range`, not be written here. Handing the renderer a
	# dictionary this gate composed would test the renderer's range argument — which [B3] already does —
	# and would pass with the lock mechanism deleted entirely. Watched exactly that way: with the lock
	# branch removed, a hand-built dictionary kept every [B] check green.
	var lock: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, true, 10.0, 15.0)
	_check(bool(lock.get("locked", false)) and lock["min"] == 10.0 and lock["max"] == 15.0,
			"[B2] a locked node resolves to ITS pinned range, not the data's (%s %.2f..%.2f over a "
			% ["LOCK" if lock.get("locked") else "AUTO", lock["min"], lock["max"]]
			+ "field spanning 10..50)")
	_check(bool(lock.get("mark", false)),
			"[B2] and a locked range asks for out-of-range marking (Rule 4), which an auto range does not")
	_check(not bool(GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, false, 10.0, 15.0).get("locked", true)),
			"control: the same call UNLOCKED does not report a lock, so the flag is what decides")
	var img_lock_lo := _render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, lo_field, lock)
	var img_lock_hi := _render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, lock)
	var d_lock := _max_byte_diff(img_lock_lo, img_lock_hi)
	_check(d_lock > 20 * maxi(d_auto, 1),
			"[B2] under LOCK the SAME two fields render DIFFERENTLY (max channel difference %d vs %d "
			% [d_lock, d_auto] + "under AUTO) — the parameter change is now visible")

	# And the lock's RANGE must be what did it, not the mark flag alone.
	var lock_wide: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, true, 10.0, 50.0)
	_check(_render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, lock_wide) != img_lock_hi,
			"control: moving the LOCKED range also moves the image, so [B2] is measuring the range and "
			+ "not merely that two fields differ")

	# [B3] Rule 4: a value outside a LOCKED range is marked, not clamped to the endpoint. `hi_field` runs
	# to 50 against a 10..15 lock, so most of it is over.
	var marked := _render_ranged(Pasture3DUtil.PREVIEW_RAMP_SEQ, hi_field, lock)
	var unmarked := Pasture3DUtil.preview_image_grid(
			hi_field, n, n, Pasture3DUtil.PREVIEW_RAMP_SEQ, 10.0, 15.0, false)
	_check(marked != unmarked,
			"[B3] out-of-range pixels under a LOCK are MARKED rather than clamped to the endpoint")
	# Control: with everything inside the range there is nothing to mark, so the flag changes nothing.
	var inside := Pasture3DUtil.preview_image_grid(
			lo_field, n, n, Pasture3DUtil.PREVIEW_RAMP_SEQ, 0.0, 100.0, true)
	var inside_nomark := Pasture3DUtil.preview_image_grid(
			lo_field, n, n, Pasture3DUtil.PREVIEW_RAMP_SEQ, 0.0, 100.0, false)
	_check(inside == inside_nomark,
			"control: with no value outside the range the mark flag changes NOTHING, so [B3] measured "
			+ "overflow and not the flag's mere presence")

	# [B4] the lock must not touch invalidation (§12.6). The three properties have no setters, so an
	# assignment must leave the graph's revision where it was — otherwise choosing how to LOOK at a field
	# would cost a bake, and `preview_on` would stop being the instant show/hide it is documented to be.
	var g := _one_previewable_graph()
	var node: Pasture3DGraphNode = g.nodes[0]
	var rev_before: int = g.content_key()
	node.preview_range_locked = true
	node.preview_range_min = 3.0
	node.preview_range_max = 9.0
	node.preview_repr = Pasture3DUtil.PREVIEW_RAW_GRAY
	_check(g.content_key() == rev_before,
			"[B4] pinning a range and choosing a representation do NOT bump the graph revision "
			+ "(%d -> %d) — view state stays out of invalidation (§12.6)" % [rev_before, g.content_key()])
	# Control: something that IS content must bump it, or [B4] passes on a revision that never moves.
	node.muted = not node.muted
	_check(g.content_key() != rev_before,
			("control: a real content edit DOES bump the revision (%d -> %d), so [B4] measured the "
			+ "view-state exemption and not a dead counter") % [rev_before, g.content_key()])


# --- D -------------------------------------------------------------------------------------------------
#
# §5.5, second half: "a frozen thumbnail must never be indistinguishable from a live one".
#
# A graph that does not lower makes `compile_graph_program_multi` return empty, and `_refresh_previews`
# used to `return` on that with the comment "leave the last thumbnails in place this tick". Which is what
# it did — forever, silently, showing whatever the graph last managed to render. Per
# `op-ids-omission-drops-graph-to-gdscript` the usual cause is ONE node, and until now nothing said which.
#
# What is asserted, and why in this order:
#
#   [D1] the graph's own report names the blocking node and its op. Asserted through `native_supported()`
#        as the spec asks, so the report is checked to AGREE with the decision rather than to be
#        plausible — the two read one scan, and a report that disagreed with the answer would be the
#        worst possible outcome.
#   [D2] the EDITOR marked its thumbnails. Read off `last_preview_block`, which the editor writes at the
#        early return — not off a fresh `native_block_report()` call, which would pass whether or not the
#        editor ever consulted it (`a-gate-that-calls-the-node-measures-nothing`).
#   [D3] the visible mark: the chips say STALE and the images are tinted out of the live range.
#
# Control: a LOWERING graph marks nothing, reports nothing, and leaves its thumbnails untinted. Without it
# every check here passes on an editor that marks everything stale unconditionally.
func _d_a_non_lowering_graph_says_so() -> void:
	print("\n[D] a graph that does not lower marks its thumbnails stale and names the blocker (§5.5)")

	# ---- the blocking graph. `dla` is the fixture on purpose: its op is genuinely absent from
	# `graph_op_ids()`, which is the historical case `op-ids-omission-drops-graph-to-gdscript` records —
	# DLA ran unlowered for as long as it did precisely because nothing said so. A fabricated blocker
	# would test the report; this tests it against the failure it was written for.
	#
	# A FROZEN solver was the first fixture here and does NOT work, which is worth recording: 
	# `compile_graph_program_multi` does not bail on `blocks_native()`, only on an unimplemented op, the
	# channel rule and an empty order. So a frozen solver compiles and previews through a live re-solve.
	# That is a real disagreement between `native_supported()` and the multi-root compile, it is out of
	# V1's scope, and changing lowering to fix it is exactly what standing constraint 1 warns against.
	var g := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeRegistry.create(&"noise")
	var blocker := Pasture3DGraphNodeRegistry.create(&"dla")
	if src == null or blocker == null:
		_check(false, "the registry could not create the fixture nodes; nothing was measured")
		return
	g.add_node(src, Vector2.ZERO)
	g.add_node(blocker, Vector2(200, 0))
	g.connect_ports(0, 0, 1, 0)
	g.output_node = 1
	src.preview_on = true
	blocker.preview_on = true

	# The fixture must actually block, or [D] measures a graph that was never in trouble.
	var native_ops: Dictionary = Pasture3DUtil.graph_op_ids()
	_check(not native_ops.has(blocker.op()),
			"control: the fixture's op '%s' really is absent from graph_op_ids(), so [D] is not "
			% blocker.op() + "asserting about a healthy graph")
	_check(native_ops.has(src.op()),
			"control: and the OTHER node in the same graph IS native, so one node is dropping the whole "
			+ "graph — which is the defect being surfaced")
	_check(not g.native_supported(),
			"control: and the graph as a whole does not lower, which is the state §5.5 is about")

	# [D1] the report, checked against the decision it must agree with.
	var report: Dictionary = g.native_block_report()
	_check(not report.is_empty(),
			"[D1] the graph reports a reason rather than merely answering false")
	_check(int(report.get("node", -1)) == 1,
			"[D1] and it names the responsible NODE (got %d, expected 1)" % int(report.get("node", -1)))
	_check(String(report.get("op", "")) == String(blocker.op()),
			"[D1] and its op (got '%s', expected '%s')" % [report.get("op", ""), blocker.op()])
	_check(not String(report.get("reason", "")).is_empty(),
			"[D1] and gives a reason in words: '%s'" % report.get("reason", ""))

	# The editor's early return is the one at `compile_graph_program_multi`, so that call must actually be
	# returning empty. Without this control [D2] cannot tell "the editor did not mark" from "the editor
	# was never in the state that marks".
	var compiled: Dictionary = g.compile_graph_program_multi([0, 1])
	_check(compiled.is_empty(),
			"control: the multi-root compile really does return empty for this graph (keys=%s), which is "
			% [compiled.keys()] + "the branch §5.5 is about")

	# [D2] the EDITOR's record, written where it gave up — not a fresh call of the gate's own.
	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	var blocked: Dictionary = ed.last_preview_block
	_check(not blocked.is_empty(),
			"[D2] the editor recorded WHY its refresh produced nothing (%s)" % [blocked.get("reason", "")])
	_check(int(blocked.get("node", -1)) == 1,
			"[D2] and the editor's record names the same node the graph does (got %d)"
			% int(blocked.get("node", -1)))

	# [D3] the visible mark. A record nobody can see is not what §5.5 asked for.
	var tinted := 0
	var stale_chips := 0
	for idx in ed._preview_rects:
		if is_instance_valid(ed._preview_rects[idx]) and ed._preview_rects[idx].modulate != Color(1, 1, 1, 1):
			tinted += 1
		if ed._preview_chips.has(idx) and is_instance_valid(ed._preview_chips[idx]) 				and ed._preview_chips[idx].text == "STALE":
			stale_chips += 1
	_check(ed._preview_rects.size() >= 2,
			"control: the panel built %d thumbnails, so there is something to mark" % ed._preview_rects.size())
	_check(tinted == ed._preview_rects.size() and tinted > 0,
			"[D3] every visible thumbnail is tinted out of the live range (%d of %d)"
			% [tinted, ed._preview_rects.size()])
	_check(stale_chips == ed._preview_rects.size() and stale_chips > 0,
			"[D3] and every chip says STALE instead of reporting a range it did not measure (%d of %d)"
			% [stale_chips, ed._preview_rects.size()])

	# ---- THE CONTROL. A lowering graph must mark NOTHING. Without this, an editor that tinted every
	# thumbnail unconditionally would pass every check above.
	var ok_graph := _one_previewable_graph()
	_check(ok_graph.native_supported(),
			"control: the healthy fixture DOES lower, so the comparison below is between two live states")
	_check(ok_graph.native_block_report().is_empty(),
			"control: and it reports NO block, so the report distinguishes rather than always answering")

	var ed2 = _panel()
	ed2.edit_graph(ok_graph, null, null)
	ed2._refresh_previews()
	_check(ed2.last_preview_block.is_empty(),
			"control: the editor records no block for a lowering graph (got %s)" % [ed2.last_preview_block])
	var ok_tinted := 0
	for idx in ed2._preview_rects:
		if is_instance_valid(ed2._preview_rects[idx]) and ed2._preview_rects[idx].modulate != Color(1, 1, 1, 1):
			ok_tinted += 1
	_check(ed2._preview_rects.size() > 0 and ok_tinted == 0,
			"control: and none of its %d thumbnails is tinted, so [D3] measured the block and not a "
			% ed2._preview_rects.size() + "panel that dims everything")

	# [D4] the mark must LIFT. A graph that starts lowering again has to stop looking frozen, or the badge
	# becomes the new permanent lie. Unblocking by MUTING the offending node — the remedy the report's own
	# `detail` suggests — so this also checks that the advice works.
	blocker.muted = true
	ed.edit_graph(null, null, null)
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	_check(ed.last_preview_block.is_empty(),
			"[D4] muting the blocking node clears the editor's stale record — the remedy the report "
			+ "names actually works (got %s)" % [ed.last_preview_block])
	var still := 0
	for idx in ed._preview_rects:
		if is_instance_valid(ed._preview_rects[idx]) 				and ed._preview_rects[idx].modulate != Color(1, 1, 1, 1):
			still += 1
	_check(still == 0, "[D4] and un-tints the thumbnails (%d still tinted)" % still)

	for n in [ed, ed2]:
		if is_instance_valid(n):
			n.queue_free()


# --- E -------------------------------------------------------------------------------------------------
#
# §6.1 and standing constraint 3: A PATH-TYPED OUTPUT REQUESTS ZERO GRID TAPS.
#
# A PATH producer still occupies a grid slot, and that slot is filled with zeros — that is what a sideband
# IS, and it is exactly why `PathDrape`'s thumbnail was black. So the fix is not a better renderer for
# those zeros; it is not to ask for them. `PATH_GEOM` rasterises the resolved path into the thumbnail's
# own bitmap and requests nothing from the evaluator.
#
# COUNTED AT THE TAP CALL, not inferred from the picture. The spec is explicit about this and it matters:
# a criterion that looked at the rendered image would pass on an editor that tapped the zeros, threw them
# away, and then drew the path anyway — which is the whole cost the rule exists to avoid, invisible.
#
# `last_preview_taps` is written by `_refresh_previews` where it forms the argument, for the same reason
# `last_preview_dispatch` is.
func _e_a_path_output_taps_no_grid() -> void:
	print("\n[E] a PATH output requests ZERO grid taps, counted at the tap call (§6.1)")

	if not ClassDB.class_has_method("Pasture3DUtil", "preview_image_path"):
		_check(false, "preview_image_path is not bound — the DLL is stale; nothing was measured")
		return

	# `shape_source` is a registered PATH GENERATOR. Headless and unbound it resolves to an EMPTY path,
	# and that is fine for what [E] measures: the tap exclusion is driven by the declared output TYPE, not
	# by whether the path has vertices yet — a Road Source that has not baked must not start tapping a
	# grid just because it is empty. [E3] below exercises the drawing with explicit geometry.
	var g := Pasture3DTerrainGraph.new()
	var pathnode := Pasture3DGraphNodeRegistry.create(&"shape_source")
	if pathnode == null:
		_check(false, "the registry could not create a `shape_source` node; nothing was measured")
		return
	g.add_node(pathnode, Vector2.ZERO)
	g.output_node = 0
	pathnode.preview_on = true

	_check(pathnode.output_port_type() == Pasture3DGraphNode.PortType.PATH,
			"control: the fixture really does declare a PATH output (got %d), so [E] is about the type "
			% pathnode.output_port_type() + "rule and not about this one node")
	_check(GraphEditorScript.preview_repr_for_type(Pasture3DGraphNode.PortType.PATH)
			== Pasture3DUtil.PREVIEW_PATH_GEOM,
			"control: and PATH maps to PATH_GEOM in the §5.3 table")

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	_check(ed.last_preview_taps.has("count"),
			"control: the refresh recorded a tap count at all, so [E] is reading a measurement rather "
			+ "than an absent key that defaults to zero")
	_check(int(ed.last_preview_taps.get("count", -1)) == 0,
			"[E] the PATH-only refresh requested %d grid taps"
			% int(ed.last_preview_taps.get("count", -1)))
	_check(int(ed.last_preview_taps.get("path_count", 0)) == 1,
			"[E] and it drew %d path preview(s), so the node was previewed rather than skipped"
			% int(ed.last_preview_taps.get("path_count", 0)))

	# THE CONTROL. A HEIGHT output in the same panel requests one. Without it, "zero taps" passes on a
	# refresh that never ran, on a panel with no thumbnails, or on a tap counter wired to a constant.
	var gh_ := _one_previewable_graph()
	var ed2 = _panel()
	ed2.edit_graph(gh_, null, null)
	ed2._refresh_previews()
	_check(int(ed2.last_preview_taps.get("count", -1)) == 1,
			"control: a HEIGHT output in the same panel requests exactly one tap (got %d)"
			% int(ed2.last_preview_taps.get("count", -1)))
	_check(int(ed2.last_preview_taps.get("path_count", -1)) == 0,
			"control: and draws no path preview, so the two counters are not the same number")

	# [E2] a MIXED graph: the PATH node is excluded and the grid node is not. This is the case that would
	# quietly regress into "taps everything" or "taps nothing", and neither pure fixture above can see it.
	var gm := Pasture3DTerrainGraph.new()
	var noise := Pasture3DGraphNodeRegistry.create(&"noise")
	var p2 := Pasture3DGraphNodeRegistry.create(&"shape_source")
	gm.add_node(noise, Vector2.ZERO)
	gm.add_node(p2, Vector2(200, 0))
	gm.output_node = 0
	noise.preview_on = true
	p2.preview_on = true
	var ed3 = _panel()
	ed3.edit_graph(gm, null, null)
	ed3._refresh_previews()
	_check(int(ed3.last_preview_taps.get("count", -1)) == 1,
			"[E2] with one PATH and one HEIGHT previewed, exactly ONE tap is requested (got %d)"
			% int(ed3.last_preview_taps.get("count", -1)))
	_check(int(ed3.last_preview_taps.get("path_count", -1)) == 1,
			"[E2] and exactly one path is drawn (got %d), so the split is per-node and not per-graph"
			% int(ed3.last_preview_taps.get("path_count", -1)))

	# [E3] the drawing itself, and the reason `resolved_path_of` exists rather than `path_output()`: the
	# thumbnail must show the path the graph RESOLVED. Asserted on the bytes differing between a path with
	# geometry and one without — an empty path is a normal state and draws the bare checkerboard.
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	var drawn: PackedByteArray = Pasture3DUtil.preview_image_path(
			pts, PackedFloat32Array(), 32, 32)
	var empty: PackedByteArray = Pasture3DUtil.preview_image_path(
			PackedVector2Array(), PackedFloat32Array(), 32, 32)
	_check(drawn.size() == 32 * 32 * 4 and empty.size() == 32 * 32 * 4,
			"[E3] PATH_GEOM returns a full RGBA8 thumbnail with no grid input at all (%d, %d bytes)"
			% [drawn.size(), empty.size()])
	_check(drawn != empty,
			"[E3] a path with geometry draws something an empty one does not")
	# Control: the drawing follows the GEOMETRY, not merely the vertex count. A different shape with the
	# same number of points must differ, or PATH_GEOM could be drawing a fixed glyph.
	var other := PackedVector2Array([Vector2(0, 0), Vector2(0, 10), Vector2(10, 10)])
	_check(Pasture3DUtil.preview_image_path(other, PackedFloat32Array(), 32, 32) != drawn,
			"control: a DIFFERENT path of the same vertex count draws differently, so PATH_GEOM follows "
			+ "the geometry rather than stamping a glyph")
	# And the width envelope is drawn, or "the centreline" would be the whole feature.
	var wide := PackedFloat32Array([4.0, 4.0, 4.0])
	_check(Pasture3DUtil.preview_image_path(pts, wide, 32, 32) != drawn,
			"[E3] the half-width envelope changes the drawing, so widths are rendered and not ignored")

	for n in [ed, ed2, ed3]:
		if is_instance_valid(n):
			n.queue_free()


# --- G -------------------------------------------------------------------------------------------------
#
# Standing constraint 2, and the line the whole preview design rests on: PREVIEWS ARE NEVER PAID FOR BY
# `evaluate()`. The thumbnail path taps a compiled program directly, and `preview_on` is an instant
# show/hide rather than a re-evaluate. If that ever stops being true it will present as "the editor got
# slower", which nobody bisects.
#
# COUNTED, not reasoned about. `evaluate_count` is bumped at the top of `evaluate()` itself, so it cannot
# be satisfied by a route that avoids one particular caller.
#
# Three separate claims, because they can regress independently:
#   [G1] toggling `preview_on` runs no evaluation.
#   [G2] a whole preview REFRESH — the tap pass, the render, the apply — runs none either. This is the
#        stronger one and the one a future change is likelier to break.
#   [G3] toggling does not bump the content revision, so it cannot invalidate a host's frozen bake.
#        A toggle that cost a cache would be "free" by [G1]'s measure and expensive in fact.
#
# Controls: a real `evaluate()` DOES increment the counter, and a real parameter edit DOES bump the
# revision. Without those, every check above passes on a dead counter and a frozen revision — which is
# `gate-pass-can-mean-nothing-ran` exactly.
func _g_previews_are_not_paid_for_by_evaluate() -> void:
	print("\n[G] toggling a preview, and refreshing one, perform NO evaluation (standing constraint 2)")

	var g := _one_previewable_graph()
	var node: Pasture3DGraphNode = g.nodes[0]
	var ed = _panel()
	ed.edit_graph(g, null, null)

	# [G1] the toggle. Driven through `_apply_preview_flag`, which is the toggle action's own body — not
	# by assigning `preview_on` here, which would bypass the very code path being measured.
	var before: int = g.evaluate_count
	ed._apply_preview_flag(0, false)
	ed._apply_preview_flag(0, true)
	ed._apply_preview_flag(0, false)
	ed._apply_preview_flag(0, true)
	_check(g.evaluate_count == before,
			"[G1] four preview_on toggles ran %d evaluations (expected 0)" % [g.evaluate_count - before])

	# [G2] a full refresh. The whole point of the tap architecture.
	var before_refresh: int = g.evaluate_count
	ed._refresh_previews()
	_check(g.evaluate_count == before_refresh,
			"[G2] a complete preview refresh ran %d evaluations (expected 0)"
			% [g.evaluate_count - before_refresh])
	# ...and it must have actually DONE something, or [G2] is measuring a refresh that returned early.
	_check(int(ed.last_preview_taps.get("count", 0)) > 0,
			"control: that refresh really did tap the evaluator (%d taps), so [G2] measured a working "
			% int(ed.last_preview_taps.get("count", 0)) + "preview rather than one that bailed")

	# THE COUNTER CONTROL. Without this every check above passes on a counter that never moves.
	var eval_before: int = g.evaluate_count
	var produced: PackedFloat32Array = g.evaluate(16, 16, Rect2(0, 0, 100, 100))
	_check(g.evaluate_count == eval_before + 1,
			"control: a real evaluate() DOES increment the counter (%d -> %d), so the zeros above are "
			% [eval_before, g.evaluate_count] + "measurements and not a dead counter")
	_check(produced.size() == 16 * 16,
			"control: and that evaluation produced a real field (%d cells), so the counter is not being "
			% produced.size() + "incremented by a call that failed immediately")

	# [G3] the toggle must not invalidate. `preview_on` has no emitting setter, which is what makes this
	# true — but "has no setter" is a fact about today's source and this is a fact about behaviour.
	var rev_before: int = g.content_key()
	ed._apply_preview_flag(0, false)
	ed._apply_preview_flag(0, true)
	_check(g.content_key() == rev_before,
			"[G3] toggling preview_on does not bump the content revision (%d -> %d), so it cannot "
			% [rev_before, g.content_key()] + "invalidate a host's frozen bake")
	# Control: a real content edit does bump it.
	node.muted = not node.muted
	_check(g.content_key() != rev_before,
			"control: a parameter/content edit DOES bump the revision (%d -> %d), so [G3] measured the "
			% [rev_before, g.content_key()] + "exemption and not a revision that never moves")

	if is_instance_valid(ed):
		ed.queue_free()


# --- F -------------------------------------------------------------------------------------------------
#
# §5.4: THE OPT-IN DOWNSCALE, AND THE BADGE THAT MAKES IT HONEST.
#
# The option exists because an erosion graph is slow to preview and an author tuning one wants the picture
# back sooner. It is dangerous for exactly the same reason: at 1:4 the channel network MERGES, ridges round
# off, and the author fixes a problem that only the preview has. So the option ships with a badge, and the
# badge is on the thumbnail rather than on the toolbar, because the picture is what is being misread.
#
# Four claims, all of which can regress apart:
#   [F1] the BAKE is bit-identical at 1:1 and at 1:4. This is the one that would be a disaster and the one
#        a plausible implementation gets wrong, by putting the scale somewhere `evaluate()` can see it.
#   [F2] the preview pass really did run at the reduced resolution — counted at the dispatch the editor
#        recorded, in the [E] style, not inferred from a picture that could have been resized afterwards.
#   [F3] the rendered thumbnail genuinely DIFFERS. This is [F1]'s indispensable control: without it the
#        whole criterion passes on an option wired to nothing at all.
#   [F4] choosing a scale does not bump the content revision, so it cannot invalidate a host's frozen bake.
#        A view setting that cost a rebake would be a performance option that costs performance.
func _f_the_downscale_is_opt_in_and_badged() -> void:
	print("\n[F] the preview downscale changes the PREVIEW and nothing else, and says so on the picture (§5.4)")

	# The resolver first, because everything below reads through it and a wrong table here would make the
	# rest of the criterion measure a resolution nobody asked for.
	_check(GraphEditorScript.preview_pixels_for_scale(1) == GraphEditorScript.PREVIEW_SIZE,
			"[F] 1:1 is full resolution (%d px)" % GraphEditorScript.preview_pixels_for_scale(1))
	_check(GraphEditorScript.preview_pixels_for_scale(2) == GraphEditorScript.PREVIEW_SIZE / 2,
			"[F] 1:2 halves it (%d px)" % GraphEditorScript.preview_pixels_for_scale(2))
	_check(GraphEditorScript.preview_pixels_for_scale(4) == GraphEditorScript.PREVIEW_SIZE / 4,
			"[F] 1:4 quarters it (%d px)" % GraphEditorScript.preview_pixels_for_scale(4))
	_check(GraphEditorScript.preview_pixels_for_scale(64) == GraphEditorScript.PREVIEW_SIZE,
			("control: an out-of-range scale falls back to FULL resolution (%d px) rather than to some "
			% GraphEditorScript.preview_pixels_for_scale(64)) + "guessed fraction — the safe direction is "
			+ "slower and correct")

	var rect := Rect2(0, 0, 100, 100)

	# ---- [F1] the bake ----
	# Evaluated at a resolution that is NOT any of the preview sizes, so a scale that leaked into the
	# evaluator could not coincidentally agree.
	var g := _f_graph()
	g.preview_scale = 1
	var bake_full: PackedFloat32Array = g.evaluate(48, 48, rect)
	g.preview_scale = 4
	var bake_quarter: PackedFloat32Array = g.evaluate(48, 48, rect)
	_check(bake_full == bake_quarter,
			"[F1] the bake is BIT-IDENTICAL with the preview at 1:1 and at 1:4 (%d vs %d cells)"
			% [bake_full.size(), bake_quarter.size()])
	# Without this, [F1] passes on two empty arrays — the exact `gate-pass-can-mean-nothing-ran` shape.
	_check(bake_full.size() == 48 * 48 and _f_varied(bake_full),
			("control: and that bake is a real, VARIED field (%d cells), so bit-identity is a measurement "
			% bake_full.size()) + "and not two empty arrays comparing equal")

	# ---- [F2] the preview pass, counted at the dispatch ----
	var ed = _panel()
	g.preview_scale = 1
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	var px_full: int = int(ed.last_preview_dispatch.get("px", -1))
	_check(px_full == GraphEditorScript.PREVIEW_SIZE,
			"[F2] at 1:1 the tap pass ran at %d px" % px_full)
	g.preview_scale = 4
	ed._refresh_previews()
	var px_quarter: int = int(ed.last_preview_dispatch.get("px", -1))
	_check(px_quarter == GraphEditorScript.PREVIEW_SIZE / 4,
			"[F2] at 1:4 the SAME panel and the SAME graph tapped at %d px" % px_quarter)
	_check(px_quarter > 0 and px_quarter < px_full,
			("[F2] so the option reached the evaluator's grid size (%d -> %d), which is where the time is "
			% [px_full, px_quarter]) + "actually spent — a downscale applied only to the image would save "
			+ "nothing, and this is what tells the two apart")

	# ---- [F3] the picture really changes ----
	# Rendered through the editor's own worker and read back off the TextureRect, so this is the thumbnail
	# the author sees rather than a render the gate performed for itself.
	var img_q: Image = await _f_thumbnail(ed, 0)
	g.preview_scale = 1
	ed._refresh_previews()
	var img_f: Image = await _f_thumbnail(ed, 0)
	if img_q == null or img_f == null:
		_check(false, "[F3] the panel produced no thumbnail to compare; nothing was measured")
	else:
		_check(img_q.get_width() == GraphEditorScript.PREVIEW_SIZE / 4
				and img_f.get_width() == GraphEditorScript.PREVIEW_SIZE,
				"[F3] the thumbnails carry their pass's resolution (%d px at 1:4, %d px at 1:1)"
				% [img_q.get_width(), img_f.get_width()])
		# Compared at a common size, nearest, so the difference measured is CONTENT and not the trivial
		# fact that two images of different dimensions have different byte counts.
		var up := Image.create_from_data(img_q.get_width(), img_q.get_height(), false,
				img_q.get_format(), img_q.get_data())
		up.resize(img_f.get_width(), img_f.get_height(), Image.INTERPOLATE_NEAREST)
		var diff: int = _max_byte_diff(up.get_data(), img_f.get_data())
		_check(diff > 8,
				("control: and the two thumbnails genuinely DIFFER (max byte delta %d), so [F1]'s "
				% diff) + "bit-identity is the bake being protected from a live option, not an option "
				+ "wired to nothing")
		_check(_is_varied(img_f.get_data()),
				"control: the full-resolution thumbnail is a varied picture, so the difference above is "
				+ "between two real renders rather than against a blank one")

	# ---- [F3b] the badge ----
	var badge = ed._preview_badges.get(0)
	_check(badge != null and is_instance_valid(badge),
			"[F3b] every thumbnail carries a downscale badge, so the check below is about its VISIBILITY "
			+ "and not about whether the control exists")
	if badge != null and is_instance_valid(badge):
		_check(not badge.visible,
				"[F3b] at 1:1 the badge is hidden — an always-on badge would be ignored within a day")
		g.preview_scale = 2
		ed._sync_preview_scale_ui()
		_check(badge.visible and badge.text == "1:2",
				("[F3b] below 1:1 the badge appears ON THE THUMBNAIL and names the ratio (visible=%s, "
				% badge.visible) + "text=\"%s\"), because the picture is what is being misread"
				% badge.text)
		g.preview_scale = 4
		ed._sync_preview_scale_ui()
		_check(badge.text == "1:4",
				"control: the badge follows the setting rather than printing a constant (got \"%s\")"
				% badge.text)

	# ---- [F4] view state, not content ----
	var rev_before: int = g.content_key()
	g.preview_scale = 1
	g.preview_scale = 4
	g.preview_scale = 2
	_check(g.content_key() == rev_before,
			("[F4] changing the preview scale does not bump the content revision (%d -> %d), so it cannot "
			% [rev_before, g.content_key()]) + "invalidate a host's frozen bake — §12.6")
	g.nodes[0].muted = not g.nodes[0].muted
	_check(g.content_key() != rev_before,
			("control: a real content edit DOES bump it (%d -> %d), so [F4] measured the exemption and not "
			% [rev_before, g.content_key()]) + "a revision that never moves")

	if is_instance_valid(ed):
		ed.queue_free()


## Read back the thumbnail the editor actually put on node `p_idx`, after letting the async tap pass land.
##
## The refresh dispatches to a WorkerThreadPool task and applies through `call_deferred`, so a synchronous
## read would see the PREVIOUS pass's texture — which would make [F3] compare 1:1 against 1:1 and pass by
## measuring nothing.
func _f_thumbnail(p_editor, p_idx: int) -> Image:
	for i in range(120):
		await get_tree().process_frame
	if not p_editor._preview_rects.has(p_idx):
		return null
	var tr: TextureRect = p_editor._preview_rects[p_idx]
	if not is_instance_valid(tr) or tr.texture == null:
		return null
	return tr.texture.get_image()


## [F]'s fixture, and NOT `_one_previewable_graph()`: that one leaves the Noise node's `noise` resource
## unassigned, which the node documents as a defined flat 0. A flat field makes every claim here vacuous —
## the bake compares equal because it is constant, and the two thumbnails match because both are one
## colour. The first run of this criterion failed on exactly that, which is why the fixture is explicit.
func _f_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	var fnl := FastNoiseLite.new()
	fnl.seed = 12345
	fnl.frequency = 0.05
	n.noise = fnl
	n.amplitude = 20.0
	g.add_node(n, Vector2.ZERO)
	g.output_node = 0
	n.preview_on = true
	return g


func _f_varied(p_field: PackedFloat32Array) -> bool:
	if p_field.is_empty():
		return false
	var lo := INF
	var hi := -INF
	for v in p_field:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo > 1e-6
