# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphExportGate — V6 of PASTURE3D_GRAPH_VISUALIZATION_SPEC.md: the B2 export sinks and `Export All`
# (§9.2).
#
# ---- WHAT EACH CRITERION IS ACTUALLY MEASURING ----
#
# [A]  TERMINALITY, not emptiness. Adding an export sink leaves the compiled op count AND the output
#      field bit-identical. The control is the same subtree wired into a NON-terminal node, which does
#      change the op count — without it the criterion would pass on a compiler that ignored the whole
#      graph. `has_output()` is asserted false for all five, since that one override is the mechanism.
# [A2] The registry survives five more no-output nodes (§10): every entry constructs, every op tag is
#      unique, and none of the five appears in `op_ids()` — registering one WOULD be the bug, because it
#      would name a tag no kernel serves. See "WHAT THIS GATE CANNOT SAY".
# [B]  No file is written by evaluation. Asserted on the file's ABSENCE across a parameter sweep — nine
#      compiles and nine taps with the sinks present — and on `write_count` staying zero. Control: the
#      explicit export writes it, so "no file" is not this fixture's permanent state.
# [C]  A png16 round-trip reproduces the field within quantisation, decoded through the SIDECAR's range
#      rather than through the numbers this gate happens to know (`calibration-constants-must-be-stored-
#      not-printed`). Control: png8 does NOT — same node, same writer, same field, one integer different,
#      so the criterion measures BIT DEPTH and not the writer.
# [D]  `Export All` writes one file per sink and names them. Control: cancelling after the first leaves
#      the remaining two UNWRITTEN and the report says `cancelled`.
# [F]  A wired `normal` port on Export Normal Map is REFUSED by name (§9.2's Q3 ruling), never quietly
#      ignored in favour of deriving. Control: with the port unwired the same sink exports.
# [G]  An index map is written UNSCALED. Index 7 comes back as index 7 across the whole legal range.
#      Control: the same field through a quantised sink does NOT come back as itself, so the criterion
#      measures the carve-out and not "png8 happens to round-trip small integers".
# [E]  The tap reads the sink's INPUT slot. Muting the node upstream of the sink changes the file — while
#      the graph's OUTPUT is wired straight from Input and is unaffected by that mute, so a writer that
#      read the output instead would produce a byte-identical file and fail here.
#
# ---- WHAT THIS GATE CANNOT SAY ----
#
# **[A2] asserts the registry invariant rather than running the three sweeps.** Running another gate's
# scene from inside this one would report ITS result as this gate's. `GraphAllNodeSocketsGate`,
# `GraphNodeEditorUIGate` and `GraphPaletteAndConstantsGate` are re-run separately and their results
# recorded in the commit; [A2] here asserts what they would catch. This is V5 [B2]'s note, unchanged,
# because it is the same situation with five more nodes.
#
# **[B] cannot prove a negative over code it did not run.** What it measures is that every evaluation
# entry point this project HAS — `compile_graph_program`, `compile_graph_program_multi`,
# `graph_eval_grid_taps` — leaves the disk untouched. The stronger claim, that no such path can exist, is
# structural rather than measured: `Pasture3DGraphExportSinks` is not referenced from any evaluator, and
# a sink emits no op for an evaluator to reach. [B] is the empirical half of that.
#
# House discipline (bench/PlowReliefCheck.gd, `bench-gate-practices`): every criterion carries a control
# that must fail if the thing under test is removed, and `_checks` counts COMPLETIONS — a criterion that
# threw before asserting is a failure, not a silent skip (`gate-pass-can-mean-nothing-ran`).
extends Node

const RES: int = 64
const RECT := Rect2(0.0, 0.0, 64.0, 64.0)
## Where the fixture's exported files go. `user://` because a gate must never write into the project
## (`gate-data-directory-is-an-editor-risk`), and one subdirectory so the sweep in [B] can list it.
const OUT_DIR := "user://graph_export_gate"

var _fail: int = 0
var _checks: int = 0
var _terrain: Pasture3D = null


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
		print("    !! FAIL: %s" % p_msg)
	else:
		print("    ok: %s" % p_msg)


func _ready() -> void:
	print("=== GraphExportGate (V6: B2 export sinks + Export All, spec §9.2) ===")
	_reset_dir()
	_a_a_sink_costs_the_program_nothing()
	_a2_the_registry_survives_five_more_terminal_nodes()
	_b_evaluation_writes_no_file()
	_c_png16_round_trips_and_png8_does_not()
	_d_export_all_writes_one_file_per_sink_and_cancels()
	_e_the_tap_reads_the_sinks_input()
	_f_a_wired_normal_port_is_refused()
	_g_an_index_map_is_never_scaled()

	print("--- %d checks, %d failures" % [_checks, _fail])
	if _checks < 74:
		print("!! GATE INCOMPLETE: %d checks ran, expected at least 74 — a criterion threw before asserting" % _checks)
		_fail += 1
	print("=== GraphExportGate: %s ===" % ("PASS" if _fail == 0 else "FAIL"))
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------------

func _reset_dir() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var d := DirAccess.open(OUT_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


func _files() -> PackedStringArray:
	var d := DirAccess.open(OUT_DIR)
	return d.get_files() if d != null else PackedStringArray()


## A RAMP terrain, built once. A ramp and not a step because [C] measures quantisation, and a two-valued
## field quantises exactly at any depth — the png8 control would pass and the criterion would measure
## nothing.
##
## There is a real terrain here rather than a synthetic input array because that is where the exporter
## gets its input surface: `export_graph_outputs` takes a terrain and samples it, exactly as the editor's
## Export All does. A fixture that handed the exporter an array the production path cannot supply would
## be testing a function this project does not call.
func _make_terrain() -> Pasture3D:
	if _terrain != null:
		return _terrain
	var t := Pasture3D.new()
	t.name = "ExportGateTerrain"
	t.vertex_spacing = 1.0
	add_child(t)
	if t.data == null:
		return null
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in range(RES):
		for ix in range(RES):
			t.data.set_height(Vector3(float(ix) + 0.5, 0.0, float(iz) + 0.5),
					float(ix) / float(RES - 1) * 200.0)
	_terrain = t
	return t


## The same surface the exporter will read, sampled the same way it samples it — at cell centres, from
## the terrain. Read HERE by the gate rather than borrowed from the exporter, so [C]'s reference is not
## the code under test agreeing with itself (`check-derived-values-outside-the-chain`).
func _ramp_input() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(RES * RES)
	var t := _make_terrain()
	if t == null:
		return z
	for iz in range(RES):
		var wz: float = RECT.position.y + (float(iz) + 0.5) * RECT.size.y / float(RES)
		for ix in range(RES):
			var wx: float = RECT.position.x + (float(ix) + 0.5) * RECT.size.x / float(RES)
			var h: float = t.data.get_height(Vector3(wx, 0.0, wz))
			z[iz * RES + ix] = 0.0 if is_nan(h) else h
	return z


## Input -> Mask(ALTITUDE 0..200, full falloff) -> sink, plus Input -> Output.
##
## The Output is wired STRAIGHT from Input, not through the Mask. That is [E]'s control built into the
## fixture: muting the Mask changes what the sink sees and cannot change what the Output produces.
func _export_graph(p_sinks: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var mask := Pasture3DGraphNodeMask.new()
	mask.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	# A RAMP, via the fade-in below the band rather than the band itself. `falloff_lo` is the soft width
	# BELOW `band_min` (`pasture3d_graph_node_mask.gd:38`), so band 200..1e6 with a 200 m fade-in maps the
	# fixture's 0..200 m ground onto a full 0..1 gradient. A band that simply covered the ground would
	# return 1.0 everywhere — which is what the first run of this gate did, and [C]'s distinct-values
	# control is what caught it: a constant field quantises exactly at any depth, so the png8 control
	# passed and the criterion measured nothing.
	mask.band_min = 200.0
	mask.band_max = 1000000.0
	mask.falloff_lo = 200.0
	mask.falloff_hi = 0.0
	var outp := Pasture3DGraphNodeOutput.new()
	var nodes: Array[Pasture3DGraphNode] = [inp, mask, outp]
	for s in p_sinks:
		nodes.append(s)
	g.nodes = nodes
	g.connect_ports(0, 0, 1, 0) # Input -> Mask
	g.connect_ports(0, 0, 2, 0) # Input -> Output
	for i in range(p_sinks.size()):
		g.connect_ports(1, 0, 3 + i, 0) # Mask -> sink's first source port
	g.set_output(2)
	return g


func _configure(p_sink: Pasture3DGraphNodeExportSink, p_name: String,
		p_format: String) -> Pasture3DGraphNodeExportSink:
	p_sink.filename = p_name
	p_sink.format = p_format
	p_sink.resolution = RES
	p_sink.world_rect = RECT
	return p_sink


## The field the graph's OUTPUT produces, as a preview would read it. The comparison unit for [A]'s
## "bit-identical".
func _output_field(p_graph: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var compiled: Dictionary = p_graph.compile_graph_program_multi([2])
	if compiled.is_empty():
		return PackedFloat32Array()
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(2):
		return PackedFloat32Array()
	var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], RES, RES, RECT,
			_ramp_input(), PackedInt32Array([int(slot_of[2])]), PackedInt32Array([0]))
	var fields: Array = result.get("fields", [])
	if fields.size() != 1 or not (fields[0] is PackedFloat32Array):
		return PackedFloat32Array()
	return fields[0]


func _op_count(p_graph: Pasture3DTerrainGraph) -> int:
	var prog: Dictionary = p_graph.compile_graph_program()
	return PackedInt32Array(prog.get("ops", PackedInt32Array())).size()


func _all_sink_scripts() -> Array:
	return [Pasture3DGraphNodeExportHeightmap, Pasture3DGraphNodeExportMask,
			Pasture3DGraphNodeExportNormalMap, Pasture3DGraphNodeExportSplat,
			Pasture3DGraphNodeExportIndexMap]


func _read_sidecar(p_path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(p_path + Pasture3DGraphExportSinks.SIDECAR_SUFFIX)
	if txt.is_empty():
		return {}
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


# ---------------------------------------------------------------------------------------------------
# [A] A sink costs the compiled program nothing
# ---------------------------------------------------------------------------------------------------
func _a_a_sink_costs_the_program_nothing() -> void:
	print("[A] adding an export sink leaves the op count and the output field bit-identical (§9.2)")
	for script in _all_sink_scripts():
		var n = script.new()
		_check(not n.has_output(),
				"%s is terminal, so nothing can wire from it" % n.op())

	var plain := _export_graph([])
	var base_ops := _op_count(plain)
	var base_field := _output_field(plain)
	_check(base_ops > 0, "control: the sink-free graph compiled %d op words" % base_ops)
	_check(base_field.size() == RES * RES, "control: the sink-free graph produced a %d-cell output field"
			% base_field.size())
	# A flat field would let two different programs agree vacuously.
	var lo: float = base_field[0]
	var hi: float = base_field[0]
	for v in base_field:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check(hi - lo > 1.0, "control: the output field spans %.1f m, so agreement is not vacuous" % (hi - lo))

	var withs := _export_graph([_configure(Pasture3DGraphNodeExportHeightmap.new(), "a.r16", "r16"),
			_configure(Pasture3DGraphNodeExportMask.new(), "b.png", "png16")])
	var with_ops := _op_count(withs)
	var with_field := _output_field(withs)
	_check(with_ops == base_ops, "the op count is unchanged with two sinks present (%d vs %d)"
			% [with_ops, base_ops])
	_check(withs.native_supported(), "the graph with export sinks still lowers to native")
	var identical := with_field.size() == base_field.size()
	if identical:
		for i in range(base_field.size()):
			if with_field[i] != base_field[i]:
				identical = false
				break
	_check(identical, "the output field is bit-identical with the sinks present")

	# CONTROL: the SAME subtree wired into a NON-terminal node, which is an ancestor of the output. If
	# the compiler were simply ignoring everything, this would be unchanged too and [A] would measure
	# nothing at all.
	var nonterm := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var mask := Pasture3DGraphNodeMask.new()
	var blend := Pasture3DGraphNodeBlend.new()
	var outp := Pasture3DGraphNodeOutput.new()
	nonterm.nodes = [inp, mask, outp, blend] as Array[Pasture3DGraphNode]
	nonterm.connect_ports(0, 0, 1, 0) # Input -> Mask
	nonterm.connect_ports(0, 0, 3, 0) # Input -> Blend.a
	nonterm.connect_ports(1, 0, 3, 1) # Mask  -> Blend.b   (the same subtree, now CONSUMED)
	nonterm.connect_ports(3, 0, 2, 0) # Blend -> Output
	nonterm.set_output(2)
	var nonterm_ops := _op_count(nonterm)
	_check(nonterm_ops != base_ops,
			"control: the same subtree wired into a non-terminal node changes the op count (%d vs %d)"
					% [nonterm_ops, base_ops])


# ---------------------------------------------------------------------------------------------------
# [A2] The registry survives five more terminal nodes
# ---------------------------------------------------------------------------------------------------
func _a2_the_registry_survives_five_more_terminal_nodes() -> void:
	print("[A2] the registry invariants hold with five no-output nodes registered (§10)")
	var entries := Pasture3DGraphNodeRegistry.entries(true)
	var tags := {}
	var found := {}
	var want := {&"export_heightmap": true, &"export_mask": true, &"export_normal_map": true,
			&"export_splat": true, &"export_index_map": true}
	var dup := 0
	for e in entries:
		var tag: StringName = e["op"]
		if tags.has(tag):
			dup += 1
		tags[tag] = true
		if want.has(tag):
			found[tag] = e
	_check(dup == 0, "every palette op tag is unique across %d entries" % entries.size())
	_check(found.size() == 5, "all five export sinks are in the palette (%d)" % found.size())

	for tag in found.keys():
		var e: Dictionary = found[tag]
		var n = e["script"].new()
		_check(n != null and n.op() == tag,
				"%s constructs and reports its own op tag" % tag)
		_check(not n.has_output(), "%s is terminal in the palette entry too" % tag)

	# The op_ids() invariant, and the reason it reads the way it does: an op tag registered for a
	# terminal node would name a kernel that does not exist and cannot ever be asked for. Absence is
	# CORRECT here, which is the opposite of the S1 bug (`op-ids-omission-drops-graph-to-gdscript`) —
	# there the danger is an op a graph DOES reach with no kernel behind it.
	var ids: PackedStringArray = PackedStringArray()
	for id in Pasture3DUtil.graph_op_ids():
		ids.append(String(id))
	_check(ids.size() > 0, "control: graph_op_ids() reported %d ops, so absence is not vacuous" % ids.size())
	for tag in want.keys():
		_check(not ids.has(String(tag)),
				"%s is correctly ABSENT from graph_op_ids() — no kernel serves a terminal node" % tag)


# ---------------------------------------------------------------------------------------------------
# [B] Evaluation writes no file
# ---------------------------------------------------------------------------------------------------
func _b_evaluation_writes_no_file() -> void:
	print("[B] no file is written by evaluation or by a preview refresh (§9.2 / §12.7)")
	_reset_dir()
	var sink := _configure(Pasture3DGraphNodeExportMask.new(), "sweep.png", "png16")
	var g := _export_graph([sink])
	Pasture3DGraphExportSinks.write_count = 0
	Pasture3DGraphExportSinks.tap_count = 0

	# THE SWEEP. Nine different parameter settings, each compiled and each tapped — which is every
	# evaluation entry point this project has, run with a configured export sink sitting in the graph.
	var taps := 0
	for i in range(9):
		var m: Pasture3DGraphNodeMask = g.nodes[1]
		m.band_min = float(i) * 10.0
		sink.range_max = 1.0 + float(i)
		var compiled: Dictionary = g.compile_graph_program_multi([1, 2])
		if compiled.is_empty():
			continue
		var slot_of: Dictionary = compiled["slot_of"]
		var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], RES, RES, RECT,
				_ramp_input(), PackedInt32Array([int(slot_of[1])]), PackedInt32Array([0]))
		var fields: Array = result.get("fields", [])
		if fields.size() == 1 and (fields[0] is PackedFloat32Array) \
				and (fields[0] as PackedFloat32Array).size() == RES * RES:
			taps += 1
	_check(taps == 9, "control: the sweep actually evaluated %d of 9 times, so it is not a no-op" % taps)
	_check(_files().is_empty(), "the sweep wrote %d file(s) into the export directory (want 0)"
			% _files().size())
	_check(Pasture3DGraphExportSinks.write_count == 0,
			"the exporter's write counter is %d after nine evaluations (want 0)"
					% Pasture3DGraphExportSinks.write_count)
	_check(Pasture3DGraphExportSinks.tap_count == 0,
			"the exporter never even tapped (%d)" % Pasture3DGraphExportSinks.tap_count)

	# CONTROL: the explicit export writes. Without this the criterion would pass on a broken exporter.
	sink.range_max = 1.0
	var report := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(report["written"]) == 1,
			"control: the explicit export wrote %d file(s), skipped %s"
					% [report["written"], report["skipped"]])
	_check(_files().size() == 2,
			"control: the export directory now holds the image and its sidecar (%d entries)"
					% _files().size())
	_check(Pasture3DGraphExportSinks.write_count == 1,
			"control: the write counter moved to %d" % Pasture3DGraphExportSinks.write_count)


# ---------------------------------------------------------------------------------------------------
# [C] png16 round-trips; png8 does not
# ---------------------------------------------------------------------------------------------------
func _c_png16_round_trips_and_png8_does_not() -> void:
	print("[C] a png16 round-trip reproduces the field within quantisation; png8 does not (§9.2)")
	_reset_dir()
	# The reference: what the sink's INPUT slot actually carries, tapped here rather than taken from the
	# writer, so the comparison is not the exporter agreeing with itself.
	var sink := _configure(Pasture3DGraphNodeExportMask.new(), "m16.png", "png16")
	var g := _export_graph([sink])
	var compiled: Dictionary = g.compile_graph_program_multi([1])
	var slot_of: Dictionary = compiled.get("slot_of", {})
	var tapped: PackedFloat32Array = PackedFloat32Array()
	if slot_of.has(1):
		var res: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], RES, RES, RECT,
				_ramp_input(), PackedInt32Array([int(slot_of[1])]), PackedInt32Array([0]))
		var fields: Array = res.get("fields", [])
		if fields.size() == 1 and fields[0] is PackedFloat32Array:
			tapped = fields[0]
	_check(tapped.size() == RES * RES, "control: the reference tap returned %d cells" % tapped.size())
	if tapped.size() != RES * RES:
		return
	var distinct := {}
	for v in tapped:
		distinct[snappedf(v, 0.0001)] = true
	_check(distinct.size() > 32,
			"control: the fixture field takes %d distinct values, so 8 bits is a real constraint"
					% distinct.size())

	var err16 := _round_trip_error(g, sink, "m16.png", "png16", tapped)
	var err8 := _round_trip_error(g, sink, "m8.png", "png8", tapped)
	_check(err16 >= 0.0 and err8 >= 0.0, "both round-trips completed (%s / %s)" % [err16, err8])
	if err16 < 0.0 or err8 < 0.0:
		return
	# 1.5 LSB: half a step of rounding at write, plus slack for the float round-trip through the sidecar.
	var tol16: float = 1.5 / 65535.0
	var tol8: float = 1.5 / 255.0
	_check(err16 <= tol16, "png16 reproduces the field to %.8f (tolerance %.8f)" % [err16, tol16])
	_check(err8 <= tol8, "control: png8 reproduces it to %.6f, within ITS OWN 8-bit tolerance %.6f — so "
			% [err8, tol8] + "the writer is correct at both depths")
	_check(err8 > tol16,
			"control: png8's error %.6f exceeds the 16-bit tolerance %.8f, so the criterion measures bit "
					% [err8, tol16] + "depth and not the writer")
	_check(err8 > err16 * 50.0,
			"control: png8's error is %.1fx png16's, which is the ratio 8 fewer bits predicts"
					% (err8 / maxf(err16, 1e-9)))


## Export at one format, decode the file, reconstruct through the SIDECAR's range, and return the worst
## absolute error against `p_want`. -1.0 when something did not complete.
func _round_trip_error(p_graph, p_sink, p_name: String, p_format: String,
		p_want: PackedFloat32Array) -> float:
	p_sink.filename = p_name
	p_sink.format = p_format
	var report := Pasture3DGraphExportSinks.export_graph_outputs(p_graph, OUT_DIR, _make_terrain())
	if int(report["written"]) != 1:
		print("    (round-trip %s did not write: %s)" % [p_format, report["skipped"]])
		return -1.0
	var path: String = report["files"][0]
	var side := _read_sidecar(path)
	if side.is_empty():
		print("    (round-trip %s wrote no sidecar)" % p_format)
		return -1.0
	var lo: float = float(side["range_min"])
	var hi: float = float(side["range_max"])
	var decoded := Pasture3DGraphPng.decode(FileAccess.get_file_as_bytes(path))
	if decoded.has("error"):
		print("    (round-trip %s failed to decode: %s)" % [p_format, decoded["error"]])
		return -1.0
	var want_depth: int = 8 if p_format == "png8" else 16
	if int(decoded["depth"]) != want_depth or int(decoded["w"]) != RES:
		print("    (round-trip %s came back at %d bpc, %dpx)" % [p_format, decoded["depth"], decoded["w"]])
		return -1.0
	var got: PackedFloat32Array = decoded["samples"]
	var worst := 0.0
	for i in range(p_want.size()):
		worst = maxf(worst, absf((lo + got[i] * (hi - lo)) - p_want[i]))
	return worst


# ---------------------------------------------------------------------------------------------------
# [D] Export All writes one file per sink, and cancels
# ---------------------------------------------------------------------------------------------------
func _d_export_all_writes_one_file_per_sink_and_cancels() -> void:
	print("[D] Export All writes one file per sink, is cancellable, and the report names them (§9.2)")
	_reset_dir()
	var s1 := _configure(Pasture3DGraphNodeExportMask.new(), "one.png", "png8")
	var s2 := _configure(Pasture3DGraphNodeExportMask.new(), "two.png", "png16")
	var s3 := _configure(Pasture3DGraphNodeExportHeightmap.new(), "three.r16", "r16")
	var g := _export_graph([s1, s2, s3])

	var report := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(report["total"]) == 3, "the run planned %d sink(s)" % report["total"])
	_check(int(report["written"]) == 3, "it wrote %d file(s), skipped %s"
			% [report["written"], report["skipped"]])
	_check(not bool(report["cancelled"]), "an uninterrupted run does not report itself cancelled")
	var named: PackedStringArray = report["files"]
	_check(named.size() == 3, "the report names %d file(s)" % named.size())
	var all_there := named.size() == 3
	for p in named:
		if not FileAccess.file_exists(p):
			all_there = false
	_check(all_there, "every file the report names exists on disk")
	# A report that named files without writing them, or wrote files it did not name, would pass the two
	# checks above separately. This is the pair.
	var on_disk := _files()
	_check(on_disk.size() == 6, "the directory holds three images and three sidecars (%d)" % on_disk.size())

	# CANCELLATION. Driven a step at a time, which is what cancellation IS here (§9.2: a cancelled export
	# leaves the graph untouched — because no step ever touched it).
	_reset_dir()
	var ctx := Pasture3DGraphExportSinks.export_begin(g, OUT_DIR, _make_terrain())
	_check(bool(ctx["ok"]), "control: the cancellable run started (%s)" % ctx["report"]["reason"])
	Pasture3DGraphExportSinks.export_step(ctx, 0)
	Pasture3DGraphExportSinks.export_cancel(ctx)
	var cancelled := Pasture3DGraphExportSinks.export_finish(ctx)
	_check(bool(cancelled["cancelled"]), "the report says it was cancelled")
	_check(int(cancelled["written"]) == 1, "it wrote %d of 3 before stopping" % cancelled["written"])
	_check(FileAccess.file_exists(OUT_DIR + "/one.png"), "control: the sink it did reach wrote its file")
	_check(not FileAccess.file_exists(OUT_DIR + "/two.png"),
			"the second sink's file is absent, not stale or empty")
	_check(not FileAccess.file_exists(OUT_DIR + "/three.r16"), "the third sink's file is absent")
	_check(_files().size() == 2, "only the one image and its sidecar exist (%d)" % _files().size())

	# CONTROL: a misconfigured sink is NAMED and the run continues. A batch that aborted on the first bad
	# node would make the rest unreachable, and "wrote 2 of 3" with no explanation is the failure mode
	# `calibration-constants-must-be-stored-not-printed` is about in a different costume.
	_reset_dir()
	s2.format = "tga"
	var mixed := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(mixed["written"]) == 2, "control: the run wrote the %d good sinks" % mixed["written"])
	_check(mixed["skipped"].size() == 1 and String(mixed["skipped"][0]).contains("tga"),
			"control: the bad sink is named in the report (%s)" % mixed["skipped"])
	s2.format = "png16"


# ---------------------------------------------------------------------------------------------------
# [E] The tap reads the sink's input slot
# ---------------------------------------------------------------------------------------------------
func _e_the_tap_reads_the_sinks_input() -> void:
	print("[E] the tap reads the sink's INPUT slot, not the graph's output (§9.2)")
	_reset_dir()
	var sink := _configure(Pasture3DGraphNodeExportMask.new(), "e.png", "png16")
	var g := _export_graph([sink])
	var mask: Pasture3DGraphNodeMask = g.nodes[1]

	var out_before := _output_field(g)
	var r1 := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(r1["written"]) == 1, "control: the unmuted export wrote (%s)" % [r1["skipped"]])
	var bytes_before := FileAccess.get_file_as_bytes(OUT_DIR + "/e.png")
	_check(bytes_before.size() > 0, "control: the file has %d bytes" % bytes_before.size())

	# Mute the node UPSTREAM OF THE SINK. The graph's Output is wired straight from Input, so this cannot
	# change the output field — which is exactly what makes the file's change attributable.
	mask.muted = true
	var r2 := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(r2["written"]) == 1, "the muted export wrote (%s)" % [r2["skipped"]])
	var bytes_after := FileAccess.get_file_as_bytes(OUT_DIR + "/e.png")
	var out_after := _output_field(g)

	var out_same := out_before.size() == out_after.size() and out_before.size() > 0
	if out_same:
		for i in range(out_before.size()):
			if out_before[i] != out_after[i]:
				out_same = false
				break
	_check(out_same, "control: the graph's OUTPUT field is unchanged by the mute, so a writer reading "
			+ "the output would have produced an identical file")
	_check(bytes_after != bytes_before,
			"the exported file changed when the sink's upstream node was muted")
	mask.muted = false


# ---------------------------------------------------------------------------------------------------
# [F] A wired `normal` port is refused
# ---------------------------------------------------------------------------------------------------
func _f_a_wired_normal_port_is_refused() -> void:
	print("[F] a wired `normal` port is refused by name, never silently ignored (§9.2 Q3)")
	_reset_dir()
	var sink := _configure(Pasture3DGraphNodeExportNormalMap.new(), "n.png", "png8")
	var g := _export_graph([sink])

	# CONTROL FIRST: unwired, it exports. Without this the refusal below could be "this sink never works".
	var ok := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(ok["written"]) == 1, "control: with `normal` unwired the sink exports (%s)" % [ok["skipped"]])
	var derived := Pasture3DGraphPng.decode(FileAccess.get_file_as_bytes(OUT_DIR + "/n.png"))
	_check(not derived.has("error") and int(derived.get("channels", 0)) == 4,
			"control: the derived map is a 4-channel image (%s)" % [derived.get("error", "ok")])
	# A derived normal map of a ramp is not flat: the surface tilts, so X moves off 0.5.
	var varied := false
	if not derived.has("error"):
		var sm: PackedFloat32Array = derived["samples"]
		for i in range(0, sm.size(), 4):
			if absf(sm[i] - 0.5) > 0.01:
				varied = true
				break
	_check(varied, "control: the derived normals are not flat, so the export is not writing a blank")

	# THE REFUSAL. Wire ANY field into port 1 and the sink must decline by name rather than deriving one
	# from `height` and presenting it as the author's vector field (§4.4's zeros-impostor in a hat).
	_reset_dir()
	g.connect_ports(1, 0, 3, 1) # Mask -> normal
	var refused := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(refused["written"]) == 0, "the wired sink wrote %d file(s) (want 0)" % refused["written"])
	_check(_files().is_empty(), "no file and no sidecar were left behind (%d)" % _files().size())
	_check(refused["skipped"].size() == 1 and String(refused["skipped"][0]).contains("normal"),
			"the refusal names the port: %s" % [refused["skipped"]])


# ---------------------------------------------------------------------------------------------------
# [G] An index map is never scaled
# ---------------------------------------------------------------------------------------------------
func _g_an_index_map_is_never_scaled() -> void:
	print("[G] an index map is written unscaled — index 7 comes back as index 7 (§9.2)")
	_reset_dir()
	# A field of small integers, built from the ramp: floor(height / 200 * 31), so 0..31 — the range the
	# 5-bit control word actually has (`Pasture3DGraphNodeControlSink`).
	var sink := _configure(Pasture3DGraphNodeExportIndexMap.new(), "idx.png", "png8")
	var scaler := _configure(Pasture3DGraphNodeExportMask.new(), "scaled.png", "png8")
	var g := _export_graph([sink, scaler])
	# The mask's 0..1 output remapped onto 0..31 is the index field both sinks see — the range the
	# 5-bit control word actually has room for.
	var remap := Pasture3DGraphNodeRemap.new()
	remap.in_min = 0.0
	remap.in_max = 1.0
	remap.out_min = 0.0
	remap.out_max = 31.0
	g.nodes.append(remap)
	var mi: int = g.nodes.size() - 1
	g.connect_ports(1, 0, mi, 0)
	g.connect_ports(mi, 0, 3, 0) # Math -> index sink
	g.connect_ports(mi, 0, 4, 0) # Math -> the quantised control sink

	var report := Pasture3DGraphExportSinks.export_graph_outputs(g, OUT_DIR, _make_terrain())
	_check(int(report["written"]) == 2, "both sinks exported (%s)" % [report["skipped"]])

	# The reference, tapped independently.
	var compiled: Dictionary = g.compile_graph_program_multi([mi])
	var slot_of: Dictionary = compiled.get("slot_of", {})
	var want := PackedFloat32Array()
	if slot_of.has(mi):
		var res: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], RES, RES, RECT,
				_ramp_input(), PackedInt32Array([int(slot_of[mi])]), PackedInt32Array([0]))
		var fields: Array = res.get("fields", [])
		if fields.size() == 1 and fields[0] is PackedFloat32Array:
			want = fields[0]
	_check(want.size() == RES * RES, "control: the reference tap returned %d cells" % want.size())
	if want.size() != RES * RES:
		return
	var span := 0.0
	for v in want:
		span = maxf(span, v)
	_check(span > 20.0, "control: the index field reaches %.1f, so it spans real indices" % span)

	var got := Pasture3DGraphPng.decode(FileAccess.get_file_as_bytes(OUT_DIR + "/idx.png"))
	_check(not got.has("error"), "the index map decoded (%s)" % [got.get("error", "ok")])
	if got.has("error"):
		return
	var side := _read_sidecar(OUT_DIR + "/idx.png")
	_check(float(side.get("range_max", 0.0)) == 255.0 and float(side.get("range_min", -1.0)) == 0.0,
			"the sidecar records the 0..255 identity, not a divisor (%s..%s)"
					% [side.get("range_min"), side.get("range_max")])
	_check(String(side.get("nearest_only", "")).contains("NEAREST"),
			"the sidecar says in words that the file must be read with nearest sampling")

	var samples: PackedFloat32Array = got["samples"]
	var exact := 0
	for i in range(want.size()):
		if int(round(samples[i] * 255.0)) == int(round(want[i])):
			exact += 1
	_check(exact == want.size(), "%d of %d indices came back as themselves" % [exact, want.size()])

	# CONTROL: the same field through a QUANTISED sink does not. Its EXPLICIT 0..1 range maps every
	# index above 1 onto white, which is exactly the silent corruption the carve-out exists to prevent.
	var scaled := Pasture3DGraphPng.decode(FileAccess.get_file_as_bytes(OUT_DIR + "/scaled.png"))
	_check(not scaled.has("error"), "control: the quantised file decoded (%s)" % [scaled.get("error", "ok")])
	if scaled.has("error"):
		return
	var s2: PackedFloat32Array = scaled["samples"]
	var same := 0
	for i in range(want.size()):
		if int(round(s2[i] * 255.0)) == int(round(want[i])):
			same += 1
	_check(same < want.size() / 2,
			"control: only %d of %d survive a scaled write, so [G] measures the carve-out"
					% [same, want.size()])
