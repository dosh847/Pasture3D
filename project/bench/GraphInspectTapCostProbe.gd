# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphInspectTapCostProbe — what does PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §14.2 item 1 cost?
#
# V4's inspector dock re-taps the graph at its OWN resolution rather than upsampling the 128 px thumbnail
# field (spec §7). The thumbnail pass evaluates the whole compiled program once and copies out N tapped
# slots; the inspector adds a SECOND pass of the same program at a higher resolution, copying out ONE slot
# (the selected or pinned node). So the question is not "N taps vs 1 tap", it is "how much does the same
# program cost at 4x / 9x / 16x the cells".
#
# PROBE, not a gate: it measures and reports, it asserts nothing and cannot fail. Timing only, so per
# `ask-before-perf-tests` it is run on request and never unprompted.
#
# Reported per configuration: min / median over timed repeats after a discarded warm-up. Min is the honest
# floor (least interference); median is what an author would feel. The ratio column is against that
# fixture's own 128 px pass, so it is a scaling number rather than a machine number.
extends Node

const RECT := Rect2(-256.0, -256.0, 512.0, 512.0)
const SIZES: Array[int] = [128, 192, 256, 384, 512]
const WARMUP := 3
const REPEATS := 15

var _rows: Array = []


func _ready() -> void:
	print("=== GraphInspectTapCostProbe: cost of the inspector's second tap pass ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		print("!! Pasture3DUtil.graph_eval_grid_taps is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return

	print("Binary: %s" % ("debug (what the editor loads)" if OS.is_debug_build() else "release"))
	print("Repeats: %d timed after %d discarded warm-up. Rect %.0f m square.\n" % [REPEATS, WARMUP, RECT.size.x])

	_measure_fixture("LIGHT  (Input>Noise>Blend>Smooth)", _light(), [1, 2, 3])
	_measure_fixture("MEDIUM (+Warp, 2nd Noise, Remap, Terrace)", _medium(), [1, 2, 3, 4, 5, 6])
	_measure_fixture("HEAVY  (+Curvature, Smooth x6, Contrast)", _heavy(), [1, 2, 3, 4, 5, 6, 7, 8])

	_tap_count_independence()
	_summary()
	get_tree().quit(0)


# --- the measurement -----------------------------------------------------------------------------------
func _measure_fixture(p_label: String, p_graph: Pasture3DTerrainGraph, p_roots: Array) -> void:
	print("--- %s ---" % p_label)
	var compiled: Dictionary = p_graph.compile_graph_program_multi(p_roots)
	if compiled.is_empty():
		print("    !! did not lower natively — nothing to measure here (a non-native graph never reaches this path)\n")
		return
	var program: Dictionary = compiled["program"]
	var slot_of: Dictionary = compiled["slot_of"]
	var all_slots := PackedInt32Array()
	for r in p_roots:
		if slot_of.has(r):
			all_slots.append(int(slot_of[r]))
	var one_slot := PackedInt32Array([all_slots[all_slots.size() - 1]])

	var ops_arr: PackedInt32Array = program.get("ops", PackedInt32Array())
	print("    ops in program: %d   thumbnail taps: %d   inspector taps: 1 (last node)" % [ops_arr.size(), all_slots.size()])
	print("    %-6s %-9s %-10s %-10s %-9s %s" % ["size", "cells", "min ms", "median ms", "vs 128", "ms/Mcell"])
	var base_med := 0.0
	for size in SIZES:
		# The thumbnail pass taps every open preview; the inspector pass taps one. Both evaluate the whole
		# program, which is the point: tap count is a copy-out, resolution is the evaluation.
		var slots: PackedInt32Array = all_slots if size == 128 else one_slot
		var res := _time_taps(program, size, slots)
		if size == 128:
			base_med = res["median"]
		var cells := float(size) * float(size)
		print("    %-6d %-9d %-10.3f %-10.3f %-9s %.3f" % [
			size, int(cells), res["min"], res["median"],
			("1.00x" if size == 128 else "%.2fx" % (res["median"] / maxf(base_med, 0.0001))),
			res["median"] / (cells / 1000000.0)])
		_rows.append({"fixture": p_label, "size": size, "median": res["median"], "base": base_med})
	print("")


## One configuration: warm up, then time REPEATS calls and return min/median in milliseconds.
func _time_taps(p_program: Dictionary, p_size: int, p_slots: PackedInt32Array) -> Dictionary:
	var input := _ramp(p_size)
	for i in WARMUP:
		Pasture3DUtil.graph_eval_grid_taps(p_program, p_size, p_size, RECT, input, p_slots)
	var samples := PackedFloat64Array()
	for i in REPEATS:
		var t0 := Time.get_ticks_usec()
		Pasture3DUtil.graph_eval_grid_taps(p_program, p_size, p_size, RECT, input, p_slots)
		samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var sorted := Array(samples)
	sorted.sort()
	return {"min": sorted[0], "median": sorted[int(sorted.size() / 2)]}


# --- is the cost the program, or the copy-out? -----------------------------------------------------------
## The spec claims the inspector's marginal cost is RESOLUTION, not tap count — i.e. the thumbnail pass
## already pays for the whole program and adding taps to it is nearly free. If that is false, the design
## question changes: the inspector could ride the thumbnail's pass at a higher resolution instead.
func _tap_count_independence() -> void:
	print("--- tap count vs cost, at 256 px (is the copy-out the expense?) ---")
	var g := _heavy()
	var roots: Array = [1, 2, 3, 4, 5, 6, 7, 8]
	var compiled: Dictionary = g.compile_graph_program_multi(roots)
	if compiled.is_empty():
		print("    !! heavy fixture did not lower\n")
		return
	var program: Dictionary = compiled["program"]
	var slot_of: Dictionary = compiled["slot_of"]
	var slots := PackedInt32Array()
	for r in roots:
		if slot_of.has(r):
			slots.append(int(slot_of[r]))
	print("    %-6s %-10s %s" % ["taps", "median ms", "vs 1 tap"])
	var base := 0.0
	for n in [1, 2, 4, slots.size()]:
		if n > slots.size():
			continue
		var subset := PackedInt32Array()
		for i in n:
			subset.append(slots[i])
		var res := _time_taps(program, 256, subset)
		if base == 0.0:
			base = res["median"]
		print("    %-6d %-10.3f %.2fx" % [n, res["median"], res["median"] / maxf(base, 0.0001)])
	print("")


func _summary() -> void:
	print("--- what this means for the inspector ---")
	for label in ["LIGHT", "MEDIUM", "HEAVY"]:
		for r in _rows:
			if str(r["fixture"]).begins_with(label) and int(r["size"]) in [256, 384, 512]:
				print("    %s: a %d px inspector tap adds %.3f ms on top of the %.3f ms thumbnail pass (%.1fx)" % [
					label, int(r["size"]), float(r["median"]), float(r["base"]),
					float(r["median"]) / maxf(float(r["base"]), 0.0001)])
	print("\n    Debounce is PREVIEW_DEBOUNCE_SEC = 0.12 s (graph_editor.gd:66); both passes are off the")
	print("    main thread on WorkerThreadPool, so the budget is 'does it finish inside the debounce',")
	print("    not 'does it fit in a frame'.")


# --- fixtures ------------------------------------------------------------------------------------------
func _light() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var noise := FastNoiseLite.new(); noise.seed = 11; noise.frequency = 0.05
	var nz := Pasture3DGraphNodeNoise.new(); nz.noise = noise; nz.amplitude = 7.0
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), nz, bl, sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]),
		PackedInt32Array([2, 0, 3, 0]), PackedInt32Array([3, 0, 4, 0])]
	g.output_node = 4
	return g


## A chain closer to what someone actually authors: two noise sources, a domain warp, a remap and a
## terrace. All native, no solver — a solver would dominate and tell us nothing about the resolution
## question.
func _medium() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n1 := FastNoiseLite.new(); n1.seed = 11; n1.frequency = 0.05
	var n2 := FastNoiseLite.new(); n2.seed = 27; n2.frequency = 0.17
	var nz1 := Pasture3DGraphNodeNoise.new(); nz1.noise = n1; nz1.amplitude = 40.0
	var nz2 := Pasture3DGraphNodeNoise.new(); nz2.noise = n2; nz2.amplitude = 8.0
	var wp := Pasture3DGraphNodeWarp.new()
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var rm := Pasture3DGraphNodeRemap.new()
	var tr := Pasture3DGraphNodeTerrace.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), nz1, nz2, wp, bl, rm, tr, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([1, 0, 3, 0]),          # noise1 -> warp
		PackedInt32Array([3, 0, 4, 0]),          # warp   -> blend.a
		PackedInt32Array([2, 0, 4, 1]),          # noise2 -> blend.b
		PackedInt32Array([4, 0, 5, 0]),          # blend  -> remap
		PackedInt32Array([5, 0, 6, 0]),          # remap  -> terrace
		PackedInt32Array([6, 0, 7, 0])]          # terrace-> output
	g.output_node = 7
	return g


## Adds the things that actually cost: a multi-pass smooth (a stencil, so it re-reads neighbours) and a
## curvature (a derivative). This is the shape of a graph where the inspector's second pass would hurt.
func _heavy() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n1 := FastNoiseLite.new(); n1.seed = 11; n1.frequency = 0.05
	var n2 := FastNoiseLite.new(); n2.seed = 27; n2.frequency = 0.17
	var nz1 := Pasture3DGraphNodeNoise.new(); nz1.noise = n1; nz1.amplitude = 40.0
	var nz2 := Pasture3DGraphNodeNoise.new(); nz2.noise = n2; nz2.amplitude = 8.0
	var wp := Pasture3DGraphNodeWarp.new()
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 6
	var cv := Pasture3DGraphNodeCurvature.new()
	var ct := Pasture3DGraphNodeContrast.new()
	var rm := Pasture3DGraphNodeRemap.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), nz1, nz2, wp, bl, sm, cv, ct, rm,
		Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([1, 0, 3, 0]),          # noise1 -> warp
		PackedInt32Array([3, 0, 4, 0]),          # warp   -> blend.a
		PackedInt32Array([2, 0, 4, 1]),          # noise2 -> blend.b
		PackedInt32Array([4, 0, 5, 0]),          # blend  -> smooth x6
		PackedInt32Array([5, 0, 6, 0]),          # smooth -> curvature
		PackedInt32Array([6, 0, 7, 0]),          # curv   -> contrast
		PackedInt32Array([7, 0, 8, 0]),          # contr  -> remap
		PackedInt32Array([8, 0, 9, 0])]          # remap  -> output
	g.output_node = 9
	return g


func _ramp(p_size: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_size * p_size)
	for iz in range(p_size):
		for ix in range(p_size):
			s[iz * p_size + ix] = 4.0 * (float(ix) / p_size + float(iz) / p_size)
	return s
