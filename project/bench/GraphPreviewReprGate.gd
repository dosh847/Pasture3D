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
	_c_unserved_is_visible()
	_h_host_binding_follows_the_gesture()
	_i_the_input_preview_reads_the_hosts_ground()

	if _checks < 28:
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
