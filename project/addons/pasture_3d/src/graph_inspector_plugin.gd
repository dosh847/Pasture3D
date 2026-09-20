# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphInspectorPlugin — the shortcuts at the very top of the Inspector for anything that owns or
# is a terrain graph.
#
#   * a Pasture3DTerrainGraph, or a Pasture3DNodeGraph (the brush modifier that hosts one), gets a single
#     "Edit in Graph Editor" button — neither object has a modifier stack to describe.
#   * a Pasture3DTerrainBrush that runs a modifier stack gets a Pasture3DBrushGraphRow: Add/Open Graph,
#     Bake Graph (shown only once a graph modifier exists) and the stack's Evaluation. A brush that does NOT run a stack (`_supports_modifiers()` false — Ridge,
#     Trough, Splat, Sim) gets nothing, the same rule Pasture3DTerrainBrush._get_property_list applies to
#     the Modifiers group. Shipping a control that silently does nothing is worse than not shipping it.
#
# The row's own logic lives in Pasture3DBrushGraphRow because this class cannot be instantiated outside the
# editor and therefore cannot be tested; see that file's header.
#
# See PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md Phase 1.

@tool
class_name Pasture3DGraphInspectorPlugin
extends EditorInspectorPlugin

# Preloaded rather than referenced by class_name: the plugin script loads at editor startup, potentially
# before a newly added class_name has entered the global class cache.
const BrushGraphRow = preload("res://addons/pasture_3d/src/brush_graph_row.gd")

var editor: Pasture3DGraphEditor
var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DTerrainGraph or p_object is Pasture3DNodeGraph \
			or p_object is Pasture3DTerrainBrush or p_object is Pasture3D


func _parse_begin(p_object: Object) -> void:
	if p_object is Pasture3D:
		add_custom_control(_bake_trace_row())
		return

	if p_object is Pasture3DTerrainBrush:
		var brush := p_object as Pasture3DTerrainBrush
		if not brush._supports_modifiers():
			return
		add_custom_control(BrushGraphRow.new().setup(brush, _bind))
		return

	var btn := Button.new()
	btn.text = "Edit in Graph Editor"
	btn.tooltip_text = "Open the Terrain Graph visual editor in the bottom panel"
	btn.pressed.connect(_open.bind(p_object))
	add_custom_control(btn)


## Bake Trace toggle on the terrain: tick, reproduce, untick, read the report. Deliberately on the terrain
## rather than on a brush — the question it answers is "which brushes woke", which no single brush knows.
## State is read from the tracer on every rebuild, so the checkbox cannot disagree with what is recording.
func _bake_trace_row() -> Control:
	var row := HBoxContainer.new()
	var chk := CheckButton.new()
	chk.text = "Bake Trace"
	chk.tooltip_text = "Record what armed each brush bake (with call stack), bake costs, and graph cache " 			+ "hits/misses. Untick to write the report to %s." % Pasture3DBakeTrace.REPORT_PATH
	chk.button_pressed = Pasture3DBakeTrace.is_running()
	chk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(chk)
	var open := Button.new()
	open.text = "Open Report"
	open.tooltip_text = "Open the last written bake trace report"
	open.disabled = not FileAccess.file_exists(Pasture3DBakeTrace.REPORT_PATH)
	open.pressed.connect(func() -> void:
		OS.shell_open(ProjectSettings.globalize_path(Pasture3DBakeTrace.REPORT_PATH)))
	row.add_child(open)
	# The journal is written as events happen, so after a crash it is the only record. Opened by path rather
	# than disabled-when-missing, because the file appears on tick, after this row was built.
	var journal := Button.new()
	journal.text = "Open Journal"
	journal.tooltip_text = "Open the live journal (written as events happen, survives an editor crash). " 			+ "After a crash, relaunching and ticking Bake Trace moves it to %s." % Pasture3DBakeTrace.JOURNAL_PREV_PATH
	journal.pressed.connect(func() -> void:
		var p := Pasture3DBakeTrace.JOURNAL_PATH
		if not FileAccess.file_exists(p):
			push_warning("Pasture3DBakeTrace: no journal yet at %s — tick Bake Trace to start one" % p)
			return
		OS.shell_open(ProjectSettings.globalize_path(p)))
	row.add_child(journal)
	chk.toggled.connect(func(p_on: bool) -> void:
		var path := Pasture3DBakeTrace.set_session(p_on)
		if path != "":
			open.disabled = false)
	# Answers the question the trace alone cannot: did the dirty-rect bake land where a FULL bake would
	# have? A real drag changes the ground legitimately, so "this bake moved the ground a lot" is not a
	# defect; "this bake disagrees with a full bake" is. Costs a full layer bake per edit, and leaves the
	# full bake's (correct) result behind, so it repairs the terrain while it measures.
	var ver := CheckButton.new()
	ver.text = "Verify Rect"
	ver.tooltip_text = "Re-bake every dirty-rect edit down the full path and record where they disagree. " 			+ "Needs Bake Trace on. SLOW — a whole-layer bake per edit."
	ver.button_pressed = Pasture3DBakeTrace.verify_rect
	ver.toggled.connect(func(p_on: bool) -> void:
		Pasture3DBakeTrace.verify_rect = p_on)
	row.add_child(ver)
	return row


func _open(p_object: Object) -> void:
	if p_object is Pasture3DTerrainGraph:
		_bind(p_object as Pasture3DTerrainGraph, null, null)
		return

	if p_object is Pasture3DNodeGraph:
		var mod := p_object as Pasture3DNodeGraph
		if mod.graph == null:
			mod.graph = Pasture3DTerrainGraph.create_default()
		_bind(mod.graph, mod, null)
		return

	if p_object is Pasture3DTerrainBrush:
		var brush := p_object as Pasture3DTerrainBrush
		var mod := BrushGraphRow.ensure_graph_modifier(brush)
		if mod != null:
			_bind(mod.graph, mod, brush)


func _bind(p_graph: Pasture3DTerrainGraph, p_mod: Pasture3DNodeGraph,
		p_brush: Pasture3DTerrainBrush) -> void:
	if p_graph == null or editor == null:
		return
	editor.edit_graph(p_graph, p_mod, p_brush)
	if plugin != null:
		plugin.make_bottom_panel_item_visible(editor)
