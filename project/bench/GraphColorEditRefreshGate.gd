# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphColorEditRefreshGate — a node edit refreshes only the previews that read the node.
#
# Every node edit used to schedule a FULL preview refresh (whole-graph compile, tap pass, the inspector's
# 512 px pass), so dragging the colour picker on an unwired Const Color re-solved a large graph per tick.
# `preview_refresh_for_edit` now answers NONE / COLOR / FULL. Each criterion has a control that must flip.
#
#   [A] An unwired Const Color edit with a scalar preview on -> NONE. Control: editing the previewed
#       scalar node itself -> FULL.
#   [B] A Const Color wired into a previewed Color Mix -> COLOR. Control: before any refresh has recorded
#       the Mix as a colour root -> FULL.
#   [C] A scalar node feeding a previewed Color Blend's mask -> FULL (its field moves); the Blend's own
#       colour edit -> COLOR.
#   [D] A COLOR redraw repaints the swatch with the new colour and dispatches nothing (token unchanged).
#       Control: the swatch before the redraw still shows the old colour.
#   [E] An open inspector on a scalar node downstream of the edit -> FULL; closed -> NONE.
#   [F] End to end through the real signal: an unwired colour edit leaves the debounce timer stopped;
#       the control (a previewed scalar edit) starts it.
extends Node

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")
const NONE := 0
const COLOR := 1
const FULL := 2

var _fail := 0
var _checks := 0


class FakeDock extends RefCounted:
	var dock_open := false
	var node_index := -1
	func refresh() -> bool:
		return false


func _ready() -> void:
	print("=== GraphColorEditRefreshGate ===\n")
	_a_unwired_colour()
	_b_wired_colour()
	_c_blend_mask()
	_d_redraw()
	_e_inspector()
	_f_end_to_end()
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["COLOR EDIT REFRESH PASS" if _fail == 0 else "COLOR EDIT REFRESH FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


func _panel():
	var ed = GraphEditorScript.new()
	add_child(ed)
	ed.initialize(null)
	return ed


func _connect(p_g: Pasture3DTerrainGraph, p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	p_g.connections.append(PackedInt32Array([p_from, p_from_port, p_to, p_to_port]))


## Input(0) -> Noise(1) -> Output(2), Noise previewed, plus an unwired Const Color(3).
func _scalar_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var nz := Pasture3DGraphNodeNoise.new()
	nz.noise = FastNoiseLite.new()
	nz.amplitude = 5.0
	nz.preview_on = true
	g.add_node(Pasture3DGraphNodeInput.new(), Vector2.ZERO)
	g.add_node(nz, Vector2(200, 0))
	g.add_node(Pasture3DGraphNodeOutput.new(), Vector2(400, 0))
	var c := Pasture3DGraphNodeConstColor.new()
	c.value = Color.RED
	g.add_node(c, Vector2(0, 200))
	_connect(g, 0, 0, 1, 0)
	_connect(g, 1, 0, 2, 0)
	return g


func _a_unwired_colour() -> void:
	print("[A] unwired Const Color edit costs no refresh")
	var g := _scalar_graph()
	var ed = _panel()
	ed.edit_graph(g, null, null)
	_check(ed._preview_rects.has(1), "[A0] the Noise preview rect exists (precondition)")
	var k: int = ed.preview_refresh_for_edit(3)
	_check(k == NONE, "[A1] unwired Const Color -> NONE (got %d)" % k)
	var kc: int = ed.preview_refresh_for_edit(1)
	_check(kc == FULL, "[A2] control: previewed Noise edit -> FULL (got %d)" % kc)
	ed.queue_free()


## Const(0), Const(1) -> Mix(2), Mix previewed.
func _mix_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var c1 := Pasture3DGraphNodeConstColor.new(); c1.value = Color.RED
	var c2 := Pasture3DGraphNodeConstColor.new(); c2.value = Color.BLUE
	var mix := Pasture3DGraphNodeColorMix.new()
	mix.factor = 0.5
	mix.preview_on = true
	g.add_node(c1, Vector2.ZERO)
	g.add_node(c2, Vector2(0, 100))
	g.add_node(mix, Vector2(200, 50))
	_connect(g, 0, 0, 2, 0)
	_connect(g, 1, 0, 2, 1)
	return g


func _b_wired_colour() -> void:
	print("\n[B] wired colour edit redraws swatches only")
	var g := _mix_graph()
	var ed = _panel()
	ed.edit_graph(g, null, null)
	var before: int = ed.preview_refresh_for_edit(0)
	_check(before == FULL, "[B1] control: Mix not yet a recorded colour root -> FULL (got %d)" % before)
	ed._refresh_previews()
	var k: int = ed.preview_refresh_for_edit(0)
	_check(k == COLOR, "[B2] Const Color into a previewed Mix -> COLOR (got %d)" % k)
	ed.queue_free()


func _c_blend_mask() -> void:
	print("\n[C] a mask source edit re-taps, the Blend's own edit does not")
	var g := Pasture3DTerrainGraph.create_empty()
	var nz := Pasture3DGraphNodeNoise.new()
	nz.noise = FastNoiseLite.new()
	var blend := Pasture3DGraphNodeColorBlend.new()
	blend.preview_on = true
	g.add_node(Pasture3DGraphNodeInput.new(), Vector2.ZERO) # 0
	g.add_node(nz, Vector2(200, 0))                          # 1
	g.add_node(blend, Vector2(400, 0))                       # 2
	_connect(g, 0, 0, 1, 0)
	_connect(g, 1, 0, 2, blend.color_field_port())
	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	var km: int = ed.preview_refresh_for_edit(1)
	_check(km == FULL, "[C1] Noise feeding the Blend mask -> FULL (got %d)" % km)
	var kb: int = ed.preview_refresh_for_edit(2)
	_check(kb == COLOR, "[C2] the Blend's own edit -> COLOR (got %d)" % kb)
	ed.queue_free()


func _d_redraw() -> void:
	print("\n[D] a COLOR redraw repaints without a dispatch")
	var g := _mix_graph()
	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	var tr: TextureRect = ed._preview_rects.get(2)
	var token: int = ed._preview_token
	g.nodes[0].value = Color.GREEN # red+blue -> green+blue
	var stale: Color = tr.texture.get_image().get_pixel(10, 10)
	_check(stale.r > 0.4 and stale.g < 0.1, "[D1] control: before the redraw the swatch is still purple (%s)" % stale)
	ed._redraw_color_previews()
	var col: Color = tr.texture.get_image().get_pixel(10, 10)
	_check(absf(col.g - 0.5) < 0.02 and absf(col.b - 0.5) < 0.02 and col.r < 0.02,
			"[D2] redraw shows the green/blue mix (%s)" % col)
	_check(ed._preview_token == token, "[D3] no tap pass dispatched (token %d -> %d)" % [token, ed._preview_token])
	ed.queue_free()


func _e_inspector() -> void:
	print("\n[E] the open inspector counts as a reader")
	var g := _scalar_graph()
	g.nodes[1].preview_on = false
	var ed = _panel()
	ed.edit_graph(g, null, null)
	var dock := FakeDock.new()
	dock.node_index = 2 # the Output, downstream of the Noise
	ed.inspect_dock = dock
	var closed: int = ed.preview_refresh_for_edit(1)
	_check(closed == NONE, "[E1] control: dock closed, nothing previewed -> NONE (got %d)" % closed)
	dock.dock_open = true
	var open: int = ed.preview_refresh_for_edit(1)
	_check(open == FULL, "[E2] dock open on a downstream node -> FULL (got %d)" % open)
	var col: int = ed.preview_refresh_for_edit(3)
	_check(col == NONE, "[E3] unwired colour edit with the dock open elsewhere -> NONE (got %d)" % col)
	ed.inspect_dock = null
	ed.queue_free()


func _f_end_to_end() -> void:
	print("\n[F] through the node's changed signal")
	var g := _scalar_graph()
	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()
	var timer: Timer = ed._preview_timer
	_check(timer != null, "[F0] the debounce timer exists (precondition)")
	if timer == null:
		ed.queue_free()
		return
	timer.stop()
	g.nodes[3].value = Color.BLUE
	_check(timer.is_stopped(), "[F1] unwired colour edit leaves the debounce stopped")
	g.nodes[1].amplitude = 6.0
	_check(not timer.is_stopped(), "[F2] control: previewed Noise edit starts the debounce")
	timer.stop()
	ed.queue_free()
