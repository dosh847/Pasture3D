# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGpuParityGate — the GPU whole-graph evaluator vs the CPU oracle (terrain-graph RenderingDevice path).
#
# The claim: Pasture3DUtil.graph_eval_grid_gpu (C++ Pasture3DGraphGPU, a local RenderingDevice) runs the
# graph's GRID passes — Blend, Smooth, Output — over resident buffers and produces the SAME field as the CPU
# whole-graph evaluator (graph_eval_grid) within a small epsilon. The generators (Input/Noise/Const) are
# CPU-computed and uploaded on both paths, so the noise is identical; only the grid arithmetic differs
# (GPU float vs CPU float/double intermediates), which is where the epsilon comes from.
#
# RUN NON-HEADLESS: the dummy headless driver has no local RenderingDevice. When none is available (CI /
# --headless) the GPU call returns empty and this gate SKIPS with a clear message rather than failing — the
# same way the SDF GPU raster is verified in the editor, not in headless CI. House discipline otherwise:
# measure a field delta, carry a control.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/GraphGpuParityGate.tscn   (no --headless)
extends Node

const GW := 48
const GH := 32
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const TOL := 1.0e-3 # GPU float vs CPU float/double intermediates

const HYD_TOL := 3.0e-3 # the hydraulic solver accumulates over iterations, so looser than TOL
const MUD_TOL := 5.0e-3 # a mudslide is many sweeps of float accumulation, likewise

var _fail := 0


func _ready() -> void:
	print("=== GraphGpuParityGate: GPU whole-graph evaluator vs CPU oracle ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale; rebuild the extension.")
		_finish(1); return
	# Availability probe: an empty return means no local RenderingDevice (headless / no driver).
	var probe := _gpu(_io([]), _ramp(1.0))
	if probe.is_empty():
		print("GPU unavailable (no local RenderingDevice — running --headless?). SKIPPING.")
		print("Run WITHOUT --headless on a machine with a GPU to actually verify GPU/CPU parity.")
		_finish(0); return

	_a_identity()
	_b_smooth()
	_c_add_noise()
	_d_generator_with_grid_barrier()
	_e_blend_modes()
	_f_the_mask_port_and_mix()
	_g_mudslide_reaches_its_own_kernel()
	_h_driven_parameter_ports()
	_i_hydraulic_is_deterministic()
	_j_hydraulic_matches_the_cpu()
	_k_a_non_finite_mask_is_no_opinion()
	_finish(_fail)


func _finish(p_code: int) -> void:
	print("\n=== %s (%d failures) ===\n" % ["GRAPH GPU PARITY PASS" if _fail == 0 else "GRAPH GPU PARITY FAIL", _fail])
	get_tree().quit(0 if p_code == 0 and _fail == 0 else 1)


# --- A. Input -> Output identity ----------------------------------------------------------------------
func _a_identity() -> void:
	print("[A] Input -> Output identity: GPU == surface == CPU")
	var g := _io([])
	var surf := _ramp(3.0)
	_check(g, surf, "identity")
	var moved := _maxdiff(_gpu(g, surf), _gpu(g, _ramp(8.0)))
	print("    control: a different surface moves the GPU output by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the GPU is not reading the input")


# --- B. Input -> Smooth -> Output == the NaN-aware blur ------------------------------------------------
func _b_smooth() -> void:
	print("[B] Input -> Smooth -> Output: GPU == blur_nan == CPU")
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 3
	var g := _io([sm])
	var surf := _ramp(5.0)
	_check(g, surf, "smooth")
	var gpu := _gpu(g, surf)
	var changed := _maxdiff(gpu, surf)
	print("    control: the GPU smooth moved the surface by %.3f (want > 0.01)" % changed)
	if changed <= 0.01:
		_fail += 1; print("    !! the GPU Smooth passed the surface straight through")


# --- C. Input -> Blend(ADD) <- Noise -> Output --------------------------------------------------------
func _c_add_noise() -> void:
	print("[C] Input -> Blend(ADD) <- Noise -> Output: GPU == CPU")
	var noise := _make_noise(7, 0.05)
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _noise(noise, 6.0),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	_check(g, _ramp(4.0), "add-noise")


# --- D. A generator with a grid barrier (Noise -> Smooth -> Output) ------------------------------------
func _d_generator_with_grid_barrier() -> void:
	print("[D] Noise -> Smooth -> Output (no Input): GPU == CPU")
	var g := Pasture3DTerrainGraph.new()
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [_noise(_make_noise(3, 0.06), 9.0), sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	_check(g, _ramp(5.0), "gen-barrier")


# --- E. Every blend mode matches on the GPU -----------------------------------------------------------
func _e_blend_modes() -> void:
	print("[E] each blend mode: GPU == CPU (diamond A op B, A=Input surface, B=Noise)")
	var modes := {
		"ADD": Pasture3DGraphNodeBlend.Mode.ADD, "SUB": Pasture3DGraphNodeBlend.Mode.SUB,
		"MUL": Pasture3DGraphNodeBlend.Mode.MUL, "MAX": Pasture3DGraphNodeBlend.Mode.MAX,
		"MIN": Pasture3DGraphNodeBlend.Mode.MIN,
	}
	var surf := _ramp(4.0)
	for name in modes:
		var g := Pasture3DTerrainGraph.new()
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _noise(_make_noise(9, 0.06), 5.0),
			_blend(modes[name]), Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
		var d := _maxdiff(_gpu(g, surf), _cpu(g, surf))
		print("    %-4s GPU vs CPU = %.7f (want < %.6f)" % [name, d, TOL])
		if d > TOL:
			_fail += 1; print("    !! GPU diverged from CPU on blend mode %s" % name)


# --- F. The mask port, and MIX --------------------------------------------------------------------------
#
# [E] above wires two inputs and no mask, which is why this shader ignored its MASK port for as long as it
# did: every mode was checked and none of them was checked WITH a mask. A Blend with a mask wired ran on
# the GPU and dropped it silently, for all five modes.
#
# MIX (P2c) is the mode that makes that fatal rather than merely wrong: MIX is `b`, and the mask fold is
# what turns it into lerp(a, b, mask), so a dropped mask is not a blend applied too strongly — it is B
# everywhere, the road graded across the whole terrain. The controls are what separate a mask that is
# read from one that is ignored: an ignored mask gives a result identical to the unmasked blend.
func _f_the_mask_port_and_mix() -> void:
	print("[F] the mask port is read, and MIX matches (P2c)")
	var surf := _ramp(4.0)
	var modes := {
		"ADD": Pasture3DGraphNodeBlend.Mode.ADD, "MUL": Pasture3DGraphNodeBlend.Mode.MUL,
		"MIX": Pasture3DGraphNodeBlend.Mode.MIX,
	}
	for name in modes:
		# A, B and a MASK, all three wired: Input into a, noise into b, and a second noise as the mask.
		var g := Pasture3DTerrainGraph.new()
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _noise(_make_noise(9, 0.06), 5.0),
			_noise(_make_noise(3, 0.04), 0.5), _blend(modes[name]),
			Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [_c4(0, 0, 3, 0), _c4(1, 0, 3, 1), _c4(2, 0, 3, 2), _c4(3, 0, 4, 0)]
		var masked_gpu := _gpu(g, surf)
		var d := _maxdiff(masked_gpu, _cpu(g, surf))
		print("    %-4s + mask   GPU vs CPU = %.7f (want < %.6f)" % [name, d, TOL])
		if d > TOL:
			_fail += 1
			print("    !! GPU diverged from CPU on a masked %s" % name)

		# CONTROL: the mask CHANGED the answer. Without this the criterion passes on a shader that
		# ignores the mask and a CPU op that ignores it too — and the old shader did ignore it, for
		# years, while every unmasked mode above agreed perfectly.
		var g2 := Pasture3DTerrainGraph.new()
		var nodes2: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _noise(_make_noise(9, 0.06), 5.0),
			_blend(modes[name]), Pasture3DGraphNodeOutput.new()]
		g2.nodes = nodes2
		g2.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
		var unmasked := _gpu(g2, surf)
		var moved := _maxdiff(masked_gpu, unmasked)
		print("        control: the mask moves the GPU result by %.4f (want > 0.01)" % moved)
		if moved <= 0.01:
			_fail += 1
			print("        !! the mask port changed nothing, so the GPU is ignoring it")


# --- G. Mudslide: the mobile-pool pass has its own kernel mode ------------------------------------------
#
# Mode 22 was claimed TWICE in the shader: by Contrast's partial min/max reduction (which runs before the
# bounds guard and returns) and by the mudslide mobile-pool advance. The pool dispatch set mode = 22, landed
# in the reduction, and wrote per-workgroup height pairs into the pool buffer at arbitrary indices; every
# sweep after the first then read a corrupted pool. The pool pass is GKM_MUDSLIDE_POOL (28) now.
#
# CONTROL: renumber GKM_MUDSLIDE_POOL back to 22 in src/pasture_3d_graph_gpu.cpp and this must fail
# grossly -- a kernel collision is not a small numeric drift.
func _g_mudslide_reaches_its_own_kernel() -> void:
	print("[G] Mudslide (no mask wired -> the GPU kernel): GPU == CPU")
	var ms := Pasture3DGraphNodeMudslide.new()
	# The talus angle has to sit BELOW the fixture's slope or nothing is above the angle of repose and the
	# solver correctly does nothing -- which is how the first version of this criterion measured nothing.
	# _slope(40) over a 90 m rect is about 24 degrees.
	ms.talus_angle_deg = 8.0
	ms.depth = 3.0
	ms.travel_distance = 12.0
	ms.evaluation = Pasture3DGraphNodeMudslide.Evaluation.LIVE
	var g := _io([ms])
	var surf := _slope(40.0)
	var gpu := _gpu(g, surf)
	if gpu.is_empty():
		_fail += 1
		print("    !! the mudslide graph did not run on the GPU at all (it fell back), so this proves nothing")
		return
	var cpu := _cpu(g, surf)
	var d := _maxdiff(gpu, cpu)
	print("    mudslide     GPU vs CPU = %.7f (want < %.6f)" % [d, MUD_TOL])
	if d > MUD_TOL:
		_fail += 1
		print("    !! GPU diverged from the CPU mudslide -- the pool pass is landing in another kernel")

	# CONTROL: the slide actually moved material. A kernel that returned its input unchanged would pass the
	# comparison above whenever the CPU also did nothing, and it would pass it silently.
	var moved := _maxdiff(gpu, surf)
	print("    control: the slide moved the surface by %.4f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1
		print("    !! the mudslide changed nothing, so the criterion above measured nothing")


# --- H. A wired parameter port drives the GPU too -------------------------------------------------------
#
# The GPU read p_prog.params*[s] straight through and never applied pmap0..3 / pdrv_*, so a Const wired into
# FloodingUniformLevel's water_level port flooded to the INSPECTOR value on the GPU and to the Const on the
# CPU. Both evaluators resolve through graph_resolve_op_params now.
#
# CONTROL: the second half. Driving the port to a different level must move the GPU field -- otherwise this
# passes on a GPU that ignores the wire and a CPU that happens to agree with it.
func _h_driven_parameter_ports() -> void:
	print("[H] A Const wired into a parameter port: GPU == CPU")
	var surf := _slope(30.0)
	var lo := _gpu(_flood_graph(6.0), surf)
	if lo.is_empty():
		_fail += 1
		print("    !! the flooding graph did not run on the GPU at all, so this proves nothing")
		return
	var d := _maxdiff(lo, _cpu(_flood_graph(6.0), surf))
	print("    driven param GPU vs CPU = %.7f (want < %.6f)" % [d, TOL])
	if d > TOL:
		_fail += 1
		print("    !! the GPU ignored the wire into water_level and used the inspector value")

	var hi := _gpu(_flood_graph(22.0), surf)
	var moved := _maxdiff(lo, hi)
	print("    control: driving the port to a different level moves the GPU field by %.4f (want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1
		print("    !! the driving Const changed nothing on the GPU, so the criterion above measured nothing")


# --- I. The GPU hydraulic solver is deterministic -------------------------------------------------------
#
# Phase 0 used to mutate water/height/sediment IN PLACE in the same dispatch whose neighbour reads consume
# them, with no barrier. Whether a neighbour's rain and outflow had landed was undefined, so two runs of the
# same input returned different heightfields. It stages into next_* now and phase 1 folds them back.
#
# This is the ONLY criterion here that fails without a CPU comparison: it is a property of one path.
# CONTROL: revert the staging and two runs diverge.
func _i_hydraulic_is_deterministic() -> void:
	print("[I] Two GPU hydraulic solves of the same input are bit-identical")
	var surf := _slope(60.0)
	var a := _hyd_gpu(surf)
	if a.is_empty():
		_fail += 1
		print("    !! the GPU hydraulic solver did not run, so this proves nothing")
		return
	var worst := 0.0
	for _k in range(4):
		worst = maxf(worst, _maxdiff(a, _hyd_gpu(surf)))
	print("    run-to-run height delta = %.9f (want == 0)" % worst)
	if worst != 0.0:
		_fail += 1
		print("    !! the GPU hydraulic solver is not deterministic -- phase 0 is racing itself")

	# CONTROL: the solver did something. A no-op solver is trivially deterministic.
	var eroded := _maxdiff(a, surf)
	print("    control: the solve moved the surface by %.4f (want > 0.01)" % eroded)
	if eroded <= 0.01:
		_fail += 1
		print("    !! the hydraulic solve changed nothing, so determinism measured nothing")


# --- J. GPU hydraulic deposition matches the CPU on a multi-neighbour slope ------------------------------
#
# The GPU hoisted the sediment share (`s_scale = sed_c / w_c`) out of the four-direction loop, so the pool
# depletion never fed back into it and any cell with two or more downhill neighbours exported strictly more
# sediment than the CPU. A DIAGONAL slope is the fixture: every interior cell has two downhill neighbours,
# which an axis-aligned ramp does not.
#
# CONTROL: revert the hoist and the sediment channel diverges while the axis-aligned case still agrees.
func _j_hydraulic_matches_the_cpu() -> void:
	print("[J] GPU vs CPU hydraulic on a slope with two downhill neighbours per cell")
	var surf := _diagonal(50.0)
	var gpu := _hyd_gpu_full(surf)
	if gpu.is_empty():
		_fail += 1
		print("    !! the GPU hydraulic solver did not run, so this proves nothing")
		return
	var cpu := _hyd_cpu_full(surf)
	# SEDIMENT is compared. It used to be excluded: the CPU routing loop ended with an ASSIGNMENT
	# `next_sediment[i] = sed_c`, clobbering whatever earlier-processed neighbours had scattered into this
	# cell, so the amount lost depended on raster order and the GPU's gather could never reproduce it. Both
	# reference paths now += the delta instead, which is what the GPU always did. This comparison is the
	# thing that proves that fix: it fails on the assignment and passes on the accumulation.
	for ch in ["height", "flow", "sediment"]:
		var d := _maxdiff(gpu.get(ch, PackedFloat32Array()), cpu.get(ch, PackedFloat32Array()))
		print("    %-9s GPU vs CPU = %.7f (want < %.6f)" % [ch, d, HYD_TOL])
		if d > HYD_TOL:
			_fail += 1
			print("    !! GPU diverged from the CPU hydraulic solver on '%s'" % ch)

	# CONTROL: the fixture really does route to more than one neighbour. On an axis-aligned ramp the hoist
	# is invisible, so a gate built on one would have passed with the bug in place.
	var axis := _hyd_gpu_full(_slope(50.0))
	var differs := _maxdiff(gpu.get("height", PackedFloat32Array()), axis.get("height", PackedFloat32Array()))
	print("    control: the diagonal fixture differs from the axis-aligned one by %.4f (want > 0.001)" % differs)
	if differs <= 0.001:
		_fail += 1
		print("    !! the two fixtures are the same field, so the multi-neighbour case was never exercised")


# --- K. A non-finite mask cell is "no opinion", not a hole ----------------------------------------------
#
# std::clamp and clampf both use a three-way comparison, so clamp(NaN, 0, 1) is NaN: the CPU kernel and the
# GDScript Blend node punched a HOLE where the GPU left the cell fully blended. NaN is the brush-loop mask
# value and survives Smooth, Terrace and the morphology ops, so this was reachable from ordinary graphs.
# PASTURE3D_NODE_VOCABULARY.md ratifies the 1.0 reading.
#
# The mask arrives through the Input port, which is the only way to get a chosen NaN into a grid without a
# literal-grid node: A and B come from generators and stay finite, so a hole in the output can only have
# come from the mask.
func _k_a_non_finite_mask_is_no_opinion() -> void:
	print("[K] A NaN mask cell reads as 1.0 on every path")
	var mask_surf := _ramp(1.0)
	var nan_cells := 0
	for i in range(mask_surf.size()):
		if (i % 3) == 0:
			mask_surf[i] = NAN
			nan_cells += 1
	print("    control: the mask carries %d NaN cells of %d (want > 0)" % [nan_cells, mask_surf.size()])
	if nan_cells == 0:
		_fail += 1
		print("    !! the fixture has no NaN in it, so this criterion measured nothing")
		return

	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(_make_noise(11, 0.05), 6.0), _const(3.0), Pasture3DGraphNodeInput.new(),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 3, 0), _c4(1, 0, 3, 1), _c4(2, 0, 3, 2), _c4(3, 0, 4, 0)]
	var gpu := _gpu(g, mask_surf)
	var cpu := _cpu(g, mask_surf)
	var d := _maxdiff(gpu, cpu)
	print("    NaN mask     GPU vs CPU = %.7f (want < %.6f)" % [d, TOL])
	if d > TOL:
		_fail += 1
		print("    !! the two paths still disagree about a non-finite mask cell")
	var holes := 0
	for v in cpu:
		if not is_finite(v):
			holes += 1
	print("    CPU output holes = %d (want 0)" % holes)
	if holes > 0:
		_fail += 1
		print("    !! the CPU Blend punched a hole where the mask had no opinion")


# ---- helpers ----------------------------------------------------------------------------------------

func _check(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array, p_name: String) -> void:
	var gpu := _gpu(p_g, p_surf)
	var cpu := _cpu(p_g, p_surf)
	var d := _maxdiff(gpu, cpu)
	print("    %-12s GPU vs CPU = %.7f (want < %.6f)" % [p_name, d, TOL])
	if d > TOL:
		_fail += 1; print("    !! GPU diverged from the CPU oracle on '%s'" % p_name)


func _gpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _cpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _io(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(_c4(i, 0, i + 1, 0))
	g.connections = conns
	return g


func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _noise(p_noise: FastNoiseLite, p_a: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_a
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = p_seed; n.frequency = p_freq
	return n


func _ramp(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW + float(iz) / GH)
	return s


func _maxdiff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _const(p_value: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_value
	return n


func _flood_graph(p_level: float) -> Pasture3DTerrainGraph:
	# The Const drives water_level through port 1 (PARAM_PORT_MAP flooding_uniform_level -> [-1, 0]). The
	# node's own inspector value is parked far away on purpose: if the wire is ignored, the field floods to
	# THAT and the criterion fails loudly rather than by a plausible amount.
	var fl := Pasture3DGraphNodeFloodingUniformLevel.new()
	fl.water_level = -999.0
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _const(p_level), fl, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	return g


func _hyd_params() -> Dictionary:
	return {
		"iterations": 6,
		"rain_rate": 0.02,
		"evaporation_rate": 0.05,
		"sediment_capacity": 0.4,
		"erosion_speed": 0.3,
		"deposition_speed": 0.3,
		"min_slope": 0.001,
	}


func _hyd_gpu(p_surf: PackedFloat32Array) -> PackedFloat32Array:
	var d := _hyd_gpu_full(p_surf)
	return d.get("height", PackedFloat32Array()) if not d.is_empty() else PackedFloat32Array()


func _hyd_gpu_full(p_surf: PackedFloat32Array) -> Dictionary:
	var d: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_gpu(p_surf, GW, GH, RECT, _hyd_params())
	return d if bool(d.get("ok", false)) else {}


func _hyd_cpu_full(p_surf: PackedFloat32Array) -> Dictionary:
	var d: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(p_surf, GW, GH, RECT, _hyd_params())
	return d if bool(d.get("ok", false)) else {}


func _slope(p_drop: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_drop * (1.0 - float(ix) / float(GW))
	return s


func _diagonal(p_drop: float) -> PackedFloat32Array:
	# Every interior cell has TWO downhill neighbours, which is what the hoisted sediment share got wrong.
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_drop * (1.0 - 0.5 * (float(ix) / float(GW) + float(iz) / float(GH)))
	return s
