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


## The Diagnostics section on the terrain: tick what you need, reproduce the problem, untick Bake Trace,
## read the report. Deliberately on the terrain rather than on a brush -- the question these answer is
## "which brushes woke and what did they write", which no single brush knows.
##
## Grouped rather than left as loose checkboxes because they are a kit, not independent settings: Bake Trace
## is the recorder and the rest write into its report, so every one of them is inert on its own. The
## dependants are disabled, not hidden, when the recorder is off -- a control that vanishes reads as a
## missing feature, and someone hunting a bug needs to see what is available before deciding what to turn on.
##
## State is read from the tracer on every rebuild, so a checkbox cannot disagree with what is recording.
func _bake_trace_row() -> Control:
	var box := VBoxContainer.new()
	var title := Label.new()
	title.text = "Diagnostics"
	title.add_theme_font_size_override("font_size", 14)
	box.add_child(title)
	var blurb := Label.new()
	blurb.text = "Tick, reproduce the problem, untick Bake Trace, then Open Report."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(blurb)

	var chk := CheckButton.new()
	chk.text = "Bake Trace"
	chk.tooltip_text = "THE RECORDER -- everything below writes into its report, so they do nothing without it. " 			+ "Records what armed each brush bake (with call stack), bake costs, and graph cache hits/misses. " 			+ "Untick to write the report to %s." % Pasture3DBakeTrace.REPORT_PATH
	chk.button_pressed = Pasture3DBakeTrace.is_running()
	box.add_child(chk)

	# Each entry: label, tooltip, getter, setter. Kept as data so adding the next diagnostic is one line
	# rather than another twelve-line copy of the same wiring.
	var deps: Array = []
	var specs := [
		["Wrote Outside Its Box",
			"A defect whenever it prints. A dirty-rect bake clears a box and repaints it, so anything it " 			+ "moves OUTSIDE that box was added to ground nothing cleared -- on an ADD layer that adds to " 			+ "the last one and the feature climbs every edit. Silent in the good case, so leave it on.",
			func() -> bool: return Pasture3DBakeTrace.probe_ring,
			func(v: bool) -> void: Pasture3DBakeTrace.probe_ring = v],
		["Ground Moved Per Bake",
			"How much each rect bake changed the ground inside its box, and where the worst cell was. NOT a " 			+ "defect on its own -- a real edit moves the ground -- so read it for scale, not for blame.",
			func() -> bool: return Pasture3DBakeTrace.probe_ground,
			func(v: bool) -> void: Pasture3DBakeTrace.probe_ground = v],
		["Verify Rect",
			"Re-bake every dirty-rect edit down the FULL path and record where the two disagree. The full " 			+ "bake is the definition of the right answer, and it is left in place, so this repairs the " 			+ "terrain while it measures. SLOW -- a whole-layer bake per edit.",
			func() -> bool: return Pasture3DBakeTrace.verify_rect,
			func(v: bool) -> void: Pasture3DBakeTrace.verify_rect = v],
		["Capture Call Stacks",
			"Record the GDScript stack at arm time -- the field that answers \"what woke this brush\". " 			+ "Costs a get_stack() per arm; turn it off only if the trace itself is too slow.",
			func() -> bool: return Pasture3DBakeTrace.capture_stacks,
			func(v: bool) -> void: Pasture3DBakeTrace.capture_stacks = v],
	]
	for spec: Array in specs:
		var b := CheckButton.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.button_pressed = (spec[2] as Callable).call()
		b.disabled = not Pasture3DBakeTrace.is_running()
		var setter: Callable = spec[3]
		b.toggled.connect(func(p_on: bool) -> void: setter.call(p_on))
		box.add_child(b)
		deps.append(b)

	var row := HBoxContainer.new()
	var open := Button.new()
	open.text = "Open Report"
	open.tooltip_text = "Open the last written bake trace report"
	open.disabled = not FileAccess.file_exists(Pasture3DBakeTrace.REPORT_PATH)
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open.pressed.connect(func() -> void:
		OS.shell_open(ProjectSettings.globalize_path(Pasture3DBakeTrace.REPORT_PATH)))
	row.add_child(open)
	# The journal is written as events happen, so after a crash it is the only record. Opened by path rather
	# than disabled-when-missing, because the file appears on tick, after this row was built.
	var journal := Button.new()
	journal.text = "Open Journal"
	journal.tooltip_text = "Open the live journal (written as events happen, survives an editor crash). " 			+ "After a crash, relaunching and ticking Bake Trace moves it to %s." % Pasture3DBakeTrace.JOURNAL_PREV_PATH
	journal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	journal.pressed.connect(func() -> void:
		var pth := Pasture3DBakeTrace.JOURNAL_PATH
		if not FileAccess.file_exists(pth):
			push_warning("Pasture3DBakeTrace: no journal yet at %s -- tick Bake Trace to start one" % pth)
			return
		OS.shell_open(ProjectSettings.globalize_path(pth)))
	row.add_child(journal)
	box.add_child(row)

	chk.toggled.connect(func(p_on: bool) -> void:
		var path := Pasture3DBakeTrace.set_session(p_on)
		if path != "":
			open.disabled = false
		for d: CheckButton in deps:
			d.disabled = not p_on)
	return box


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
