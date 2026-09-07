# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphChannelSinkGate — V5 of PASTURE3D_GRAPH_VISUALIZATION_SPEC.md: the B1 terrain channel sinks (§9.1)
# and the §9.1a stroke-routing prerequisite that has to land first.
#
# ---- WHAT EACH CRITERION IS ACTUALLY MEASURING ----
#
# [A]  The mask is a WRITE STENCIL. Outside it the pre-existing control word is byte-identical. The
#      fixture is pre-painted with base 7 / overlay 3 / blend 100 / nav set, because on default-zero
#      ground "unchanged" and "overwritten with zeros" are the same bytes and the criterion would pass
#      on a sink that painted the whole footprint. (`road-batter-overwrites-other-roads`.)
# [B]  The write goes through the sink's OWN reserved typed layer, and the §8.1 step-2 clear is what
#      makes a re-bake idempotent — so a footprint the sink has moved off leaves no stale paint.
# [B2] The registry survives a node that has no output port (§10): every entry constructs, every op tag
#      is unique, and the four sinks are absent from `op_ids()` — which is the property the three sweeps
#      would break on. See "WHAT THIS GATE CANNOT SAY" for why the sweeps are re-run separately.
# [C]  A negative index is REFUSED at the node, and the refusal is what is tested. Index 31 is accepted,
#      so the refusal is not a blanket rejection (`road-tier-far-paint-built`: -1 meant texture 31).
# [D]  §12.16 for control, which is the whole point of §9.1a: a hand stroke aimed at a sink's reserved
#      layer is refused with BLOCK_LOCKED and the sink's cells are byte-identical afterwards — with all
#      three controls, so the criterion cannot pass because control strokes are simply broken.
# [D2] No bit outside the documented layout is ever set: `control & 0x78` is zero everywhere (§12.15).
# [E]  `native_supported()` is true with every sink present, and the compiled op count is unchanged.
# [F]  A preview refresh performs zero sink writes; a bake writes. Counted at the write.
#
# ---- WHAT THIS GATE CANNOT SAY ----
#
# **Undo is measured by its precondition, not by an undo.** [B]'s "one undo restores it" needs
# `EditorUndoRedoManager`, which does not exist headless. What is asserted instead is the property that
# makes it one action: every cell the sink authored lives in exactly ONE layer, that layer is reserved
# and owned by the host brush, and clearing it returns those cells to the pre-existing word. An undo that
# restores that layer's tiles therefore restores the paint and nothing else. The editor-side half is
# covered by reading, and this note exists so nobody reads [B] as more than it is.
#
# **[B2] asserts the registry invariant rather than running the three sweeps.** Running another gate's
# scene from inside this one would report ITS result as this gate's, which is worse than not running it.
# `GraphAllNodeSocketsGate`, `GraphNodeEditorUIGate` and `GraphPaletteAndConstantsGate` are re-run
# separately and their results recorded in the commit; [B2] here asserts what they would catch.
#
# House discipline (bench/PlowReliefCheck.gd, `bench-gate-practices`): every criterion carries a control
# that must fail if the thing under test is removed, and `_checks` counts COMPLETIONS — a criterion that
# threw before asserting is a failure, not a silent skip (`gate-pass-can-mean-nothing-ran`).
extends Node

const GW: int = 64
const GH: int = 64
const RECT := Rect2(0.0, 0.0, 64.0, 64.0)
## The x at which the fixture ground steps up. Left of it the mask is off, right of it on.
const STEP_X: float = 32.0
## The pre-existing paint. Deliberately not the default word: see [A] above.
const PRE_BASE: int = 7
const PRE_OVERLAY: int = 3
const PRE_BLEND: int = 100

var _fail: int = 0
var _checks: int = 0
var _terrain: Pasture3D = null
var _brush: Pasture3DTerrainBrush = null


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
		print("    !! FAIL: %s" % p_msg)
	else:
		print("    ok: %s" % p_msg)


func _ready() -> void:
	print("=== GraphChannelSinkGate (V5: B1 terrain channel sinks, spec §9.1 / §9.1a) ===")
	_a_the_mask_is_a_write_stencil()
	_b_the_sink_owns_one_reserved_layer()
	_b2_the_registry_survives_a_node_with_no_output()
	_c_a_negative_index_is_refused()
	_d_a_reserved_control_layer_refuses_a_hand_stroke()
	_d2_no_undocumented_bit_is_ever_set()
	_e_the_sinks_cost_the_graph_nothing()
	_f_a_preview_writes_nothing()

	print("--- %d checks, %d failures" % [_checks, _fail])
	if _checks < 46:
		print("!! GATE INCOMPLETE: %d checks ran, expected at least 46 — a criterion threw before asserting" % _checks)
		_fail += 1
	print("=== GraphChannelSinkGate: %s ===" % ("PASS" if _fail == 0 else "FAIL"))
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------------

## The ground: a hard step at STEP_X. A ramp would give the ALTITUDE mask a feathered edge and "outside
## the mask" would stop being a set of cells anyone could name; the step makes the on/off split exact.
func _ground_at(p_x: float, _p_z: float) -> float:
	return 100.0 if p_x >= STEP_X else 0.0


## A terrain with one blank region, the step ground, and PRE-EXISTING non-default control paint over the
## whole footprint. Returns null on failure so a criterion reports rather than throwing.
func _make_terrain(p_name: String) -> Pasture3D:
	var t := Pasture3D.new()
	t.name = p_name
	t.vertex_spacing = 1.0
	add_child(t)
	if t.data == null:
		return null
	t.data.add_region_blankp(Vector3.ZERO)
	var pre: int = Pasture3DUtil.enc_base(PRE_BASE) | Pasture3DUtil.enc_overlay(PRE_OVERLAY) \
			| Pasture3DUtil.enc_blend(PRE_BLEND) | Pasture3DUtil.enc_nav(true)
	for iz in range(GH):
		for ix in range(GW):
			var pos := Vector3(float(ix) + 0.5, 0.0, float(iz) + 0.5)
			t.data.set_height(pos, _ground_at(float(ix) + 0.5, float(iz) + 0.5))
			t.data.set_control(pos, pre)
	return t


func _pre_word() -> int:
	return Pasture3DUtil.enc_base(PRE_BASE) | Pasture3DUtil.enc_overlay(PRE_OVERLAY) \
			| Pasture3DUtil.enc_blend(PRE_BLEND) | Pasture3DUtil.enc_nav(true)


## A brush to host the graph, so a sink's layer has an owner id the bake system already understands.
func _make_brush(p_terrain: Pasture3D, p_name: String) -> Pasture3DTerrainBrush:
	var b := Pasture3DMound.new()
	b.name = p_name
	add_child(b)
	b.terrain = p_terrain
	return b


## Input -> Mask(ALTITUDE, band 50..1e6, no falloff) -> sink.mask, plus an Output so the graph lowers.
## The mask is 1 right of STEP_X and 0 left of it, exactly, which is the whole fixture.
func _sink_graph(p_sink: Pasture3DGraphNodeChannelSink) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var mask := Pasture3DGraphNodeMask.new()
	mask.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	mask.band_min = 50.0
	mask.band_max = 1000000.0
	mask.falloff_lo = 0.0
	mask.falloff_hi = 0.0
	var outp := Pasture3DGraphNodeOutput.new()
	g.nodes = [inp, mask, outp, p_sink] as Array[Pasture3DGraphNode]
	g.connect_ports(0, 0, 1, 0) # Input -> Mask
	g.connect_ports(0, 0, 2, 0) # Input -> Output (the graph's height passes through untouched)
	g.connect_ports(1, 0, 3, p_sink.mask_port()) # Mask -> sink.mask
	g.set_output(2)
	return g


## The absolute surface the graph reads, as the bake hands it over.
##
## `p_step` is where the ground rises, and it is a PARAMETER because moving the footprint is what [B]
## measures. The graph's Input node reads THIS grid, not the terrain's heights: editing the terrain and
## expecting the mask to follow would have made [B] pass while re-painting the identical footprint.
func _input_grid(p_step: float = STEP_X) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var wx: float = RECT.position.x + (float(ix) + 0.5) * RECT.size.x / float(GW)
			z[iz * GW + ix] = 100.0 if wx >= p_step else 0.0
	return z


## Every control word in the footprint, in cell order. The comparison unit for "byte-identical".
func _control_snapshot(p_terrain: Pasture3D) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			out[iz * GW + ix] = p_terrain.data.get_control(Vector3(float(ix) + 0.5, 0.0, float(iz) + 0.5))
	return out


## True where the fixture's mask is on: the cell centre is right of the step.
func _mask_on(p_ix: int) -> bool:
	return float(p_ix) + 0.5 >= STEP_X


func _run_sinks(p_graph, p_terrain: Pasture3D, p_owner: String, p_step: float = STEP_X) -> Dictionary:
	return Pasture3DGraphChannelSinks.run(p_graph, p_terrain, p_owner, GW, GH, RECT, _input_grid(p_step))


func _drop(p_nodes: Array) -> void:
	for n in p_nodes:
		if n != null and is_instance_valid(n):
			n.queue_free()


# ---------------------------------------------------------------------------------------------------
# [A] The mask is a write stencil
# ---------------------------------------------------------------------------------------------------
func _a_the_mask_is_a_write_stencil() -> void:
	print("[A] a sink writes only where its mask is non-zero (§9.1 rule 1)")
	var t := _make_terrain("SinkGateA")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushA")
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.base_texture = 12
	sink.overlay_texture = 12
	var g := _sink_graph(sink)

	var before := _control_snapshot(t)
	# The fixture must not be default ground, or "unchanged" is indistinguishable from "zeroed".
	_check(before[0] == _pre_word() and _pre_word() != 0,
			"the fixture carries pre-existing non-default paint (word %d)" % before[0])

	var report := _run_sinks(g, t, "pasture3d_brush:SinkGateBrushA")
	_check(int(report["written"]) > 0,
			"the sink authored %d cells (skipped: %s)" % [report["written"], report["skipped"]])

	var after := _control_snapshot(t)
	var off_changed := 0
	var on_painted := 0
	var on_total := 0
	var off_total := 0
	for iz in range(GH):
		for ix in range(GW):
			var i := iz * GW + ix
			if _mask_on(ix):
				on_total += 1
				if Pasture3DUtil.get_base(after[i]) == 12:
					on_painted += 1
			else:
				off_total += 1
				if after[i] != before[i]:
					off_changed += 1
	_check(on_total > 0 and off_total > 0,
			"the fixture has both sides of the stencil (%d on, %d off)" % [on_total, off_total])
	_check(off_changed == 0,
			"outside the mask %d of %d words changed (want 0, byte-identical)" % [off_changed, off_total])
	_check(on_painted == on_total,
			"inside the mask %d of %d words carry the sink's texture" % [on_painted, on_total])

	# CONTROL: the criterion must be able to see a write outside the mask. Paint one off-mask cell by
	# hand through the same tool API and assert the comparison notices — otherwise [A] would pass on a
	# snapshot function that always returned equal arrays.
	var probe := Vector3(1.5, 0.0, 1.5)
	t.data.set_control(probe, Pasture3DUtil.enc_base(29))
	var after2 := _control_snapshot(t)
	_check(after2[1 * GW + 1] != before[1 * GW + 1],
			"control: a deliberate off-mask write IS seen by the comparison")

	_drop([t, brush])


# ---------------------------------------------------------------------------------------------------
# [B] One reserved layer per sink, cleared first
# ---------------------------------------------------------------------------------------------------
func _b_the_sink_owns_one_reserved_layer() -> void:
	print("[B] the write goes through the sink's own reserved typed layer, cleared first (§8.1 step 2)")
	var t := _make_terrain("SinkGateB")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushB")
	var owner := "pasture3d_brush:SinkGateBrushB"
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.base_texture = 12
	sink.overlay_texture = 12
	var g := _sink_graph(sink)

	var before := _control_snapshot(t)
	var report := _run_sinks(g, t, owner)
	var layers: PackedInt32Array = report["layers"]
	_check(layers.size() == 1, "the sink reserved exactly %d layer (want 1)" % layers.size())
	if layers.is_empty():
		_drop([t, brush])
		return
	var stack = t.data.get_layer_stack()
	var layer = stack.get_layer(layers[0])
	_check(layer != null and layer.is_reserved(), "the layer is reserved (a hand stroke cannot reach it)")
	_check(layer != null and layer.get_map_type() == Pasture3DGraphNodeChannelSink.MAPTYPE_CONTROL,
			"the layer's map type is CONTROL")
	_check(layer != null and layer.get_owner_id().begins_with(owner),
			"the layer's owner id '%s' is the HOST BRUSH's, so bake_all_brushes clears it"
					% (layer.get_owner_id() if layer != null else "<none>"))

	# Every authored cell is in this ONE layer — the precondition that makes an undo of it one action.
	# See "WHAT THIS GATE CANNOT SAY": the undo itself needs EditorUndoRedoManager.
	var covered := 0
	for iz in range(GH):
		for ix in range(GW):
			if layer.get_weight(Vector2i.ZERO, Vector2i(ix, iz)) > 0.0:
				covered += 1
	var expect := 0
	for ix in range(GW):
		if _mask_on(ix):
			expect += 1
	_check(covered == expect * GH,
			"the layer covers %d cells, exactly the %d the sink authored" % [covered, expect * GH])

	# THE STEP-2 PROPERTY. MOVE the footprint — the input surface's step goes from 32 to 56, so the mask
	# now covers only the last eight columns — and the cells the sink has moved off must be back to the
	# pre-existing word. Without the clear they keep the old paint forever and it reads as deliberate.
	var moved := _control_snapshot(t)
	var was_painted := 0
	for iz in range(GH):
		for ix in range(GW):
			if _mask_on(ix) and ix < 56 and Pasture3DUtil.get_base(moved[iz * GW + ix]) == 12:
				was_painted += 1
	_check(was_painted > 0,
			"control: %d cells ARE painted before the re-bake, so 'no stale paint' is not vacuous"
					% was_painted)

	_run_sinks(g, t, owner, 56.0)
	var after := _control_snapshot(t)
	var stale := 0
	for iz in range(GH):
		for ix in range(GW):
			var i := iz * GW + ix
			if _mask_on(ix) and ix < 56 and after[i] != before[i]:
				stale += 1
	_check(stale == 0, "after the re-bake %d cells of the old footprint still hold stale paint (want 0)"
			% stale)
	# ...and it did not simply stop writing altogether.
	var still := 0
	for iz in range(GH):
		for ix in range(GW):
			if ix >= 56 and Pasture3DUtil.get_base(after[iz * GW + ix]) == 12:
				still += 1
	_check(still > 0, "control: the re-bake still painted the NEW footprint (%d cells)" % still)

	_drop([t, brush])


# ---------------------------------------------------------------------------------------------------
# [B2] The registry survives a node with no output port
# ---------------------------------------------------------------------------------------------------
func _b2_the_registry_survives_a_node_with_no_output() -> void:
	print("[B2] the registry and the op table survive four terminal nodes (§10)")
	var entries: Array = Pasture3DGraphNodeRegistry.entries()
	var ops := {}
	var built := 0
	var dupes := 0
	var sinks := 0
	var sinks_with_output := 0
	for e in entries:
		var op: StringName = e["op"]
		if ops.has(op):
			dupes += 1
		ops[op] = true
		var n = e["script"].new()
		if n != null:
			built += 1
			if n is Pasture3DGraphNodeChannelSink:
				sinks += 1
				if n.has_output():
					sinks_with_output += 1
	_check(built == entries.size(), "every one of the %d registry entries constructs" % entries.size())
	_check(dupes == 0, "no op tag is registered twice (%d duplicates)" % dupes)
	_check(sinks == 4, "the four channel sinks are registered (found %d)" % sinks)
	_check(sinks_with_output == 0, "no sink exposes an output port (%d did)" % sinks_with_output)

	# The native half: a sink must be ABSENT from the op table, not present-and-unimplemented. A tag in
	# op_ids() that no kernel serves is `op-ids-omission-drops-graph-to-gdscript` in reverse.
	var ids: Dictionary = Pasture3DTerrainGraph.op_ids()
	var leaked: Array = []
	for tag in [&"control_sink", &"color_sink", &"hole_sink", &"nav_sink"]:
		if ids.has(tag):
			leaked.append(tag)
	_check(leaked.is_empty(), "no sink tag appears in op_ids() (leaked: %s)" % [leaked])
	# CONTROL: the same lookup DOES find a tag that is supposed to be there, so an empty table cannot
	# make the assertion above true by accident.
	_check(ids.has(&"output"), "control: op_ids() does carry &\"output\", so the table is not empty")


# ---------------------------------------------------------------------------------------------------
# [C] The negative index is refused, not clamped
# ---------------------------------------------------------------------------------------------------
func _c_a_negative_index_is_refused() -> void:
	print("[C] a negative texture index is refused at the node (`road-tier-far-paint-built`)")
	var t := _make_terrain("SinkGateC")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushC")
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.base_texture = -1
	sink.overlay_texture = 4
	var g := _sink_graph(sink)

	_check(sink.sink_warnings().size() > 0, "the node names the refusal: %s" % [sink.sink_warnings()])
	var before := _control_snapshot(t)
	var report := _run_sinks(g, t, "pasture3d_brush:SinkGateBrushC")
	_check(int(report["written"]) == 0, "a refused sink authored %d cells (want 0)" % report["written"])
	var after := _control_snapshot(t)
	var changed := 0
	for i in range(before.size()):
		if before[i] != after[i]:
			changed += 1
	_check(changed == 0, "a refused sink left %d words changed (want 0)" % changed)
	# The specific failure the memory records: -1 must NOT have become texture 31.
	var as31 := 0
	for i in range(after.size()):
		if Pasture3DUtil.get_base(after[i]) == 31:
			as31 += 1
	_check(as31 == 0, "no cell was painted texture 31 by the -1 (found %d)" % as31)

	# CONTROL: 31 is a legal index and IS accepted, so the refusal is about the sign, not a blanket no.
	# base 31 with overlay 5, NOT overlay 31: `enc_base(31) | enc_overlay(31)` is 0xFFC00000, whose float
	# bit-pattern is a quiet NaN, and a control layer stores the word AS float bits — so that one word
	# cannot survive the typed layer at all. That is a pre-existing limit of the layer storage, not of
	# this sink, and it is recorded rather than worked around here; [C] is about the sign of an index and
	# must not be measuring a NaN.
	sink.base_texture = 31
	sink.overlay_texture = 5
	_check(sink.sink_warnings().is_empty(), "control: index 31 raises no warning")
	var r2 := _run_sinks(g, t, "pasture3d_brush:SinkGateBrushC")
	_check(int(r2["written"]) > 0, "control: index 31 authored %d cells" % r2["written"])
	var after2 := _control_snapshot(t)
	var painted31 := 0
	for iz in range(GH):
		for ix in range(GW):
			if _mask_on(ix) and Pasture3DUtil.get_base(after2[iz * GW + ix]) == 31:
				painted31 += 1
	_check(painted31 > 0, "control: texture 31 reached the ground (%d cells)" % painted31)

	_drop([t, brush])


# ---------------------------------------------------------------------------------------------------
# [D] §12.16 holds for control — the §9.1a prerequisite
# ---------------------------------------------------------------------------------------------------
func _d_a_reserved_control_layer_refuses_a_hand_stroke() -> void:
	print("[D] a hand stroke on a sink's reserved CONTROL layer is refused (§12.16 / §9.1a)")
	var t := _make_terrain("SinkGateD")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushD")
	var owner := "pasture3d_brush:SinkGateBrushD"
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.base_texture = 12
	sink.overlay_texture = 12
	var g := _sink_graph(sink)
	var report := _run_sinks(g, t, owner)
	var layers: PackedInt32Array = report["layers"]
	if layers.is_empty():
		_check(false, "the fixture produced no sink layer, so [D] has nothing to aim at")
		_drop([t, brush])
		return
	var sink_layer_id: int = layers[0]

	var plugin := _StubPlugin.new()
	plugin.name = "SinkGatePlugin"
	add_child(plugin)
	t.set_plugin(plugin)

	# The real editor, driven through its real entry points. A re-implementation of the routing decision
	# would measure this gate's understanding of it, not the code the mouse reaches.
	var ed := Pasture3DEditor.new()
	ed.set_terrain(t)
	ed.set_brush_data(_brush_data(9))
	ed.set_tool(Pasture3DEditor.TEXTURE)
	ed.set_operation(Pasture3DEditor.REPLACE)
	# A stroke well inside the sink's footprint, so "byte-identical afterwards" is a claim about cells
	# the sink actually owns.
	var at := Vector3(48.5, 0.0, 32.5)

	_check(t.data.is_layer_routing(), "the terrain is layer-routing, so a stroke can be routed at all")

	# --- the refusal itself ---
	t.data.set_active_layer(sink_layer_id)
	plugin.blocked.clear()
	var before := _control_snapshot(t)
	_stroke(ed, at)
	var after := _control_snapshot(t)
	var changed := 0
	for i in range(before.size()):
		if before[i] != after[i]:
			changed += 1
	_check(plugin.blocked.size() == 1 and not bool(plugin.blocked[0]["hidden"]),
			"the stroke reported BLOCK_LOCKED (%s)" % [plugin.blocked])
	_check(changed == 0, "the sink's cells are byte-identical after the refused stroke (%d changed)"
			% changed)

	# --- control (i): the same stroke on an ORDINARY control layer above the sink SUCCEEDS ---
	var touch_id: int = t.data.create_owned_layer_typed(owner + "#touchup", "Touch Up",
			Pasture3DGraphNodeChannelSink.BLEND_REPLACE,
			Pasture3DGraphNodeChannelSink.MAPTYPE_CONTROL)
	var stack = t.data.get_layer_stack()
	var touch = stack.get_layer(touch_id) if touch_id >= 0 else null
	if touch != null:
		touch.set_reserved(false) # A hand layer; the tool API reserves by default.
	_check(touch_id > sink_layer_id, "the touch-up layer (%d) sits ABOVE the sink's (%d)"
			% [touch_id, sink_layer_id])
	t.data.set_active_layer(touch_id)
	plugin.blocked.clear()
	var before2 := _control_snapshot(t)
	_stroke(ed, at)
	var after2 := _control_snapshot(t)
	var changed2 := 0
	var painted9 := 0
	for i in range(before2.size()):
		if before2[i] != after2[i]:
			changed2 += 1
		if Pasture3DUtil.get_base(after2[i]) == 9:
			painted9 += 1
	_check(plugin.blocked.is_empty(), "control (i): the touch-up stroke was NOT blocked")
	_check(changed2 > 0 and painted9 > 0,
			"control (i): the touch-up stroke landed (%d cells changed, %d carry texture 9)"
					% [changed2, painted9])

	# --- control (ii): the touch-up survives a full graph re-bake, byte-identical ---
	var touched: PackedInt32Array = PackedInt32Array()
	for i in range(after2.size()):
		if Pasture3DUtil.get_base(after2[i]) == 9:
			touched.append(i)
	_run_sinks(g, t, owner)
	var after3 := _control_snapshot(t)
	var lost := 0
	for i in touched:
		if after3[i] != after2[i]:
			lost += 1
	_check(lost == 0,
			"control (ii): %d of %d touched-up cells changed across a re-bake (want 0 — topmost-covered-wins is running)"
					% [lost, touched.size()])

	# --- control (iii): with the sink's layer un-reserved the SAME stroke is accepted ---
	var sink_layer = stack.get_layer(sink_layer_id)
	sink_layer.set_reserved(false)
	t.data.set_active_layer(sink_layer_id)
	plugin.blocked.clear()
	var before4 := _control_snapshot(t)
	_stroke(ed, at)
	var after4 := _control_snapshot(t)
	var changed4 := 0
	for i in range(before4.size()):
		if before4[i] != after4[i]:
			changed4 += 1
	_check(plugin.blocked.is_empty(),
			"control (iii): un-reserved, the same stroke is NOT blocked")
	# Asserted on the SINK LAYER's own samples rather than on the composite: the touch-up layer from
	# control (i) sits above it and wins topmost-covered-wins, so the composited word is unchanged even
	# though the stroke landed. Reading the composite here would have made [D] pass whether the stroke
	# reached the layer or was silently dropped, which is the whole distinction being measured.
	var landed := 0
	for iz in range(GH):
		for ix in range(GW):
			var v: float = sink_layer.get_value(Vector2i.ZERO, Vector2i(ix, iz))
			if not is_nan(v) and Pasture3DUtil.get_base(Pasture3DUtil.as_uint(v)) == 9:
				landed += 1
	_check(landed > 0,
			"control (iii): the stroke reached the un-reserved layer (%d cells now carry texture 9); composite unchanged by %d"
					% [landed, changed4])
	sink_layer.set_reserved(true)

	_drop([t, brush, plugin])


## One click's worth of stroke, driven through the real editor entry points so the refusal measured is
## the one a user's mouse would hit, not a re-implementation of it.
func _stroke(p_editor, p_at: Vector3) -> void:
	p_editor.start_operation(p_at)
	p_editor.operate(p_at, 0.0)
	p_editor.stop_operation()


## The brush_data dictionary `operate()` reads. Every key it indexes with `[]` must be present — a
## missing one is a null Variant conversion, not a default.
func _brush_data(p_asset_id: int) -> Dictionary:
	var img := Image.create(16, 16, false, Image.FORMAT_RF)
	img.fill(Color(1.0, 0.0, 0.0, 1.0)) # Full alpha everywhere: a hard, deterministic footprint.
	var tex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	return {
		# `set_brush_data` indexes "brush" with [] and rebuilds brush_image/brush_image_size from it, so
		# supplying only the derived keys is not enough — it errors and leaves them unset.
		"brush": [img, tex],
		"brush_image": img, "brush_image_size": Vector2i(16, 16),
		# strength is scaled by .01 inside set_brush_data, so 100 is "full".
		"size": 8.0, "strength": 100.0, "gamma": 1.0,
		"height": 0.0, "color": Color.WHITE, "roughness": 0.5,
		"enable_texture": true, "texture_filter": false, "margin": 0, "asset_id": p_asset_id,
		"slope": Vector2(0.0, 90.0), "enable_angle": false, "dynamic_angle": false, "angle": 0.0,
		"enable_scale": false, "scale": 0.0,
		"modifier_alt": false, "modifier_ctrl": false, "modifier_shift": false,
		"mouse_pressure": 1.0, "brush_spin_speed": 0.0, "align_to_view": false,
		"gradient_points": PackedVector3Array(), "auto_regions": false,
	}


# ---------------------------------------------------------------------------------------------------
# [D2] No undocumented bit is ever set
# ---------------------------------------------------------------------------------------------------
func _d2_no_undocumented_bit_is_ever_set() -> void:
	print("[D2] bits 3-6 stay reserved and unset after every sink writes (§12.15)")
	var t := _make_terrain("SinkGateD2")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushD2")
	var owner := "pasture3d_brush:SinkGateBrushD2"
	var ran := 0
	for maker in [_new_control_sink, _new_color_sink, _new_hole_sink, _new_nav_sink]:
		var sink = maker.call()
		var g := _sink_graph(sink)
		var r := _run_sinks(g, t, owner)
		if int(r["written"]) > 0:
			ran += 1
	_check(ran == 4, "all four sinks wrote (%d of 4)" % ran)

	var after := _control_snapshot(t)
	var dirty := 0
	for w in after:
		if (int(w) & 0x78) != 0:
			dirty += 1
	_check(dirty == 0, "%d of %d words carry a bit in the free field 0x78 (want 0)" % [dirty, after.size()])

	# CONTROL: the assertion can SEE a set bit — so a pass means "nothing wrote there", not "the loop
	# never ran". Deliberately set bit 4 on one cell and re-measure.
	t.data.set_control(Vector3(2.5, 0.0, 2.5), _pre_word() | (1 << 4))
	var probe := _control_snapshot(t)
	var dirty2 := 0
	for w in probe:
		if (int(w) & 0x78) != 0:
			dirty2 += 1
	_check(dirty2 == 1, "control: a deliberately set free bit IS detected (%d)" % dirty2)

	_drop([t, brush])


func _new_control_sink() -> Pasture3DGraphNodeChannelSink:
	var s := Pasture3DGraphNodeControlSink.new()
	s.base_texture = 12
	s.overlay_texture = 5
	s.blend_amount = 0.5
	return s


func _new_color_sink() -> Pasture3DGraphNodeChannelSink:
	var s := Pasture3DGraphNodeColorSink.new()
	s.color = Color(0.2, 0.6, 0.9)
	return s


func _new_hole_sink() -> Pasture3DGraphNodeChannelSink:
	return Pasture3DGraphNodeHoleSink.new()


func _new_nav_sink() -> Pasture3DGraphNodeChannelSink:
	return Pasture3DGraphNodeNavSink.new()


# ---------------------------------------------------------------------------------------------------
# [E] The sinks cost the graph nothing
# ---------------------------------------------------------------------------------------------------
func _e_the_sinks_cost_the_graph_nothing() -> void:
	print("[E] a graph containing every sink still lowers, with the same op count (§9.1 / §10)")
	var plain := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var mask := Pasture3DGraphNodeMask.new()
	var outp := Pasture3DGraphNodeOutput.new()
	plain.nodes = [inp, mask, outp] as Array[Pasture3DGraphNode]
	plain.connect_ports(0, 0, 1, 0)
	plain.connect_ports(1, 0, 2, 0)
	plain.set_output(2)
	var base_prog: Dictionary = plain.compile_graph_program()
	var base_ops: int = PackedInt32Array(base_prog.get("ops", PackedInt32Array())).size()
	_check(plain.native_supported(), "control: the sink-free graph lowers")
	_check(base_ops > 0, "control: the sink-free graph compiled %d op words" % base_ops)

	var withs := Pasture3DTerrainGraph.new()
	var inp2 := Pasture3DGraphNodeInput.new()
	var mask2 := Pasture3DGraphNodeMask.new()
	var out2 := Pasture3DGraphNodeOutput.new()
	var s1 := Pasture3DGraphNodeControlSink.new()
	var s2 := Pasture3DGraphNodeColorSink.new()
	var s3 := Pasture3DGraphNodeHoleSink.new()
	var s4 := Pasture3DGraphNodeNavSink.new()
	withs.nodes = [inp2, mask2, out2, s1, s2, s3, s4] as Array[Pasture3DGraphNode]
	withs.connect_ports(0, 0, 1, 0)
	withs.connect_ports(1, 0, 2, 0)
	for ni in [3, 4, 5, 6]:
		withs.connect_ports(1, 0, ni, 0)
	withs.set_output(2)
	_check(withs.native_supported(), "the graph with all four sinks still lowers")
	var prog: Dictionary = withs.compile_graph_program()
	var ops: int = PackedInt32Array(prog.get("ops", PackedInt32Array())).size()
	_check(ops == base_ops, "the compiled op count is unchanged (%d vs %d)" % [ops, base_ops])

	# CONTROL: a graph with a KNOWN blocker returns false, so "true" is not this function's only answer.
	var blocked := Pasture3DTerrainGraph.new()
	var inp3 := Pasture3DGraphNodeInput.new()
	var out3 := Pasture3DGraphNodeOutput.new()
	blocked.nodes = [inp3, out3] as Array[Pasture3DGraphNode]
	blocked.connect_ports(0, 0, 1, 0)
	blocked.set_output(1)
	blocked.force_gdscript_evaluation = true
	_check(not blocked.native_supported(), "control: a graph forced onto GDScript reports false")


# ---------------------------------------------------------------------------------------------------
# [F] A preview writes nothing
# ---------------------------------------------------------------------------------------------------
func _f_a_preview_writes_nothing() -> void:
	print("[F] a preview refresh performs zero sink writes; a bake writes (§9.1 rule 3)")
	var t := _make_terrain("SinkGateF")
	if t == null:
		_check(false, "the fixture terrain has no data")
		return
	var brush := _make_brush(t, "SinkGateBrushF")
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.base_texture = 12
	sink.overlay_texture = 12
	var g := _sink_graph(sink)

	# THE PREVIEW. Exactly what the editor's thumbnail pass does: compile for the roots it wants and tap.
	# If a sink ever acquired an evaluation-time write, this is where it would fire.
	Pasture3DGraphChannelSinks.write_count = 0
	Pasture3DGraphChannelSinks.clear_count = 0
	var compiled: Dictionary = g.compile_graph_program_multi([1])
	_check(not compiled.is_empty(), "control: the preview compile produced a program to tap")
	var slot_of: Dictionary = compiled["slot_of"]
	var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], 128, 128, RECT,
			Pasture3DUtil.resample_grid(_input_grid(), GW, GH, 128, 128),
			PackedInt32Array([int(slot_of[1])]), PackedInt32Array([0]))
	var fields: Array = result.get("fields", [])
	_check(fields.size() == 1 and (fields[0] is PackedFloat32Array)
			and (fields[0] as PackedFloat32Array).size() == 128 * 128,
			"control: the preview tap actually returned a field, so it is not a no-op")
	_check(Pasture3DGraphChannelSinks.write_count == 0,
			"the preview performed %d sink writes (want 0)" % Pasture3DGraphChannelSinks.write_count)
	_check(Pasture3DGraphChannelSinks.clear_count == 0,
			"the preview cleared %d layers (want 0)" % Pasture3DGraphChannelSinks.clear_count)

	# THE BAKE. Same graph, same fixture — only the entry point differs.
	_run_sinks(g, t, "pasture3d_brush:SinkGateBrushF")
	_check(Pasture3DGraphChannelSinks.write_count > 0,
			"control: a bake performed %d sink writes" % Pasture3DGraphChannelSinks.write_count)
	_check(Pasture3DGraphChannelSinks.clear_count == 1,
			"control: the bake cleared the sink's footprint once (%d)"
					% Pasture3DGraphChannelSinks.clear_count)

	_drop([t, brush])


# ---------------------------------------------------------------------------------------------------
# A stand-in for the editor plugin. `Pasture3DEditor` reports a blocked stroke by calling
# `flash_layer_warning` on the terrain's plugin, and dereferences `plugin.ui` without a null check when
# a stroke proceeds — so this carries a `ui` Node as well, and [D] would crash without it.
# ---------------------------------------------------------------------------------------------------
class _StubPlugin extends Node:
	var ui: Node = Node.new()
	var blocked: Array = []

	func flash_layer_warning(p_name: String, p_hidden: bool) -> void:
		blocked.append({"layer": p_name, "hidden": p_hidden})
