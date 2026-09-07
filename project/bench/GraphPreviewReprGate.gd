# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPreviewReprGate — PASTURE3D_GRAPH_VISUALIZATION_SPEC.md V1: the representation & range contract.
#
# Criteria [A]-[H] are the V1 row of §11. They are being brought up one at a time, RED FIRST where the
# spec says a criterion must fail on the pre-change build.
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
	_h_host_binding_follows_the_gesture()

	if _checks < 10:
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
