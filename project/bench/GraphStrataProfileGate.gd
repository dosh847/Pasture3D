# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphStrataProfileGate — PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md Phases T1, T2 and T3.
#
# The claims:
#   [A] The bench profile maps [0,1] onto [0,1] and rises monotonically, for a sweep of gamma, in both
#       SHARP and SMOOTH — on the native route (read back through strata_grid, dip 0, no noise, where the
#       output of one bed IS q + profile(u)), and the GDScript twin agrees with it.
#   [B] The SHARP knee lands at (a, b), from a formula written out in this file, not borrowed from the node.
#   [C] Hardness 0 is the identity even with dip, break noise and full hardness variation on — which also
#       proves the tilt comes back off. CONTROL: hardness 0.5 on the same input must move it.
#   [D] Hardness variation 0 gives one gamma everywhere; variation 1 does not. CONTROL is the second half.
#   [E] eval_cell == native == GPU on a 128-row grid (the thread pool runs serial below that), with break,
#       variation and each profile mode on. CONTROL: GPU SMOOTH must disagree with native SHARP, or the mode
#       never reached the shader. Runs at the node's default octaves (3), so it also proves T2's octave loop
#       agrees across routes.
#   [F] (T2) Octaves put beds inside beds: on a ramp spanning 10 base beds, 3 octaves at lacunarity 2 give at
#       least twice the risers of 1 octave. Not lacunarity^2: a finer boundary that lands inside a coarser
#       riser merges with it (at hardness 1, 0.25 and 0.5 of each bed do). CONTROL: lacunarity 1 re-bands the
#       same beds and must not.
#   [G] (T3) The elevation mask: on a ramp with the window 20..80 m, no change at or below 20 m and the full
#       unmasked change at or above 80 m. CONTROL: with the mask off, cells below 20 m do change.
#   [H] (T3) The outcrop mask scales the change by a factor in [1 - strength, 1] that genuinely varies across
#       the ground: at strength 1 some cells keep the full change and others lose a large part of it.
#       CONTROL: the ratio is against the same call at strength 0, so an outcrop mask that never reached the
#       profile reads [1, 1] and fails `lo < 0.6`.
#   [E] runs at the node's defaults (elevation mask 0..100 m, outcrop 0.4), so route parity covers both masks.
#
# Counts completed criteria; a criterion that throws before asserting cannot pass by silence.
extends Node

const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)
const EPS := 1.0e-5
const EPS_GPU := 2.0e-3 # float32 world coordinates and tilt at +-200 m, a pow() chain in the shader
const CRITERIA := 8

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphStrataProfileGate: Strata Phase T1 (profile, variable hardness, tilt) ===\n")
	_a_profile_range_and_monotonic()
	_b_sharp_knee()
	_c_hardness_zero_is_identity()
	_d_variation_varies_gamma()
	_e_route_parity()
	_f_octaves_nest_beds()
	_g_elevation_mask()
	_h_outcrop_mask()
	if _done != CRITERIA:
		_fail += 1; print("!! only %d of %d criteria completed" % [_done, CRITERIA])
	print("\n=== %s (%d failures, %d/%d criteria) ===\n" % ["STRATA PROFILE PASS" if _fail == 0 else "STRATA PROFILE FAIL", _fail, _done, CRITERIA])
	get_tree().quit(0 if _fail == 0 else 1)


## The native profile over one bed: bh 1, dip 0, no noise, so each input 3 + u comes back as 3 + profile(u).
func _native_profile(p_mode: int, p_hardness: float, p_us: PackedFloat32Array) -> PackedFloat32Array:
	var n := p_us.size()
	var surf := PackedFloat32Array()
	surf.resize(n)
	for i in n:
		surf[i] = 3.0 + p_us[i]
	var out := Pasture3DUtil.strata_grid(surf, n, 1, RECT, 1.0, p_hardness, 1.0, 0.0, 0.0, 0.0, 45.0, 0,
			PackedFloat32Array(), p_mode, 0.0)
	for i in n:
		out[i] -= 3.0
	return out


func _a_profile_range_and_monotonic() -> void:
	print("[A] profile endpoints and monotonicity, native and GDScript, SHARP and SMOOTH")
	var us := PackedFloat32Array()
	for k in 257:
		us.append(minf(float(k) / 256.0, 0.99999))
	var checked := 0
	for mode in [0, 1]:
		for h in [0.0, 0.2, 0.5, 0.75, 0.9, 1.0]:
			var nat := _native_profile(mode, h, us)
			var g: float = 1.0 - 0.85 * h
			var bad := ""
			if absf(nat[0]) > EPS:
				bad = "u=0 -> %f" % nat[0]
			elif absf(nat[256] - 1.0) > 2.0e-3:
				bad = "u->1 -> %f" % nat[256]
			else:
				for k in range(1, 257):
					if nat[k] < nat[k - 1] - EPS:
						bad = "falls at u=%f" % us[k]
						break
					var gd := Pasture3DGraphNodeStrata.profile_value(mode, us[k], g)
					if absf(gd - nat[k]) > 1.0e-4:
						bad = "GDScript %f != native %f at u=%f" % [gd, nat[k], us[k]]
						break
			checked += 1
			if bad != "":
				_fail += 1; print("    !! mode %d hardness %.2f: %s" % [mode, h, bad])
	print("    %d profiles checked (want 12)" % checked)
	if checked != 12:
		_fail += 1
	_done += 1


func _b_sharp_knee() -> void:
	print("[B] SHARP knee lands at (a, b)")
	var worst := 0.0
	for h in [0.3, 0.6, 0.9, 1.0]:
		var g: float = 1.0 - 0.85 * h
		var a: float = pow(1.0 / g, 1.0 / (g - 1.0))
		var b: float = pow(g, -g / (g - 1.0))
		var nat := _native_profile(0, h, PackedFloat32Array([a]))
		worst = maxf(worst, absf(nat[0] - b))
		print("    hardness %.1f: knee (%.4f, %.4f), native %.6f" % [h, a, b, nat[0]])
	if worst > 1.0e-4:
		_fail += 1; print("    !! the knee is off by %f" % worst)
	_done += 1


func _field(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_gw * p_gh)
	for iz in p_gh:
		for ix in p_gw:
			s[iz * p_gw + ix] = 60.0 * (float(ix) / p_gw) + 25.0 * sin(float(iz) * 0.11)
	return s


func _strata(p_hardness: float, p_variation: float, p_mode: int) -> Pasture3DGraphNodeStrata:
	var st := Pasture3DGraphNodeStrata.new()
	st.band_height = 7.0; st.hardness = p_hardness; st.amount = 1.0
	st.dip = 9.0; st.dip_direction_degrees = 30.0
	st.break_amount = 2.5; st.break_size = 40.0; st.seed = 11
	st.hardness_variation = p_variation; st.profile = p_mode
	return st


func _grid(st: Pasture3DGraphNodeStrata, p_surf: PackedFloat32Array, p_gw: int, p_gh: int) -> PackedFloat32Array:
	return st.eval_grid([p_surf], p_gw, p_gh, null, RECT)


func _c_hardness_zero_is_identity() -> void:
	print("[C] hardness 0 is the identity with dip, break and variation on (the tilt comes back off)")
	var surf := _field(64, 64)
	var id := _max_abs_diff(_grid(_strata(0.0, 1.0, 0), surf, 64, 64), surf)
	var moved := _max_abs_diff(_grid(_strata(0.5, 1.0, 0), surf, 64, 64), surf)
	print("    hardness 0: max |out - in| = %.7f (want < 1e-3) ; control hardness 0.5 moves it %.3f m (want > 0.5)" % [id, moved])
	if id > 1.0e-3:
		_fail += 1; print("    !! hardness 0 moved the ground — the tilt or the variation leaks into the height")
	if moved <= 0.5:
		_fail += 1; print("    !! control: hardness 0.5 did nothing, so the identity above proves nothing")
	_done += 1


## Every cell sits at u = 0.4 of its bed with dip 0 and break 0, so the bed boundaries stay put and only the
## variation noise can make two cells' outputs differ.
func _d_variation_varies_gamma() -> void:
	print("[D] variation 0 -> one gamma everywhere; variation 1 -> gamma varies")
	var n := 256
	var surf := PackedFloat32Array()
	surf.resize(n * n)
	surf.fill(3.4)
	var spread := []
	for v in [0.0, 1.0]:
		var out := Pasture3DUtil.strata_grid(surf, n, n, RECT, 1.0, 0.7, 1.0, 0.0, 0.0, 0.0, 30.0, 5,
				PackedFloat32Array(), 0, v)
		var lo := INF
		var hi := -INF
		for i in out.size():
			lo = minf(lo, out[i]); hi = maxf(hi, out[i])
		spread.append(hi - lo)
	print("    spread of profile(0.4): variation 0 = %.7f (want < %.7f) ; variation 1 = %.4f (want > 0.02)" % [spread[0], EPS, spread[1]])
	if spread[0] > EPS:
		_fail += 1; print("    !! variation 0 still varies gamma")
	if spread[1] <= 0.02:
		_fail += 1; print("    !! control: variation 1 left gamma constant — the variation never reached the profile")
	_done += 1


func _e_route_parity() -> void:
	print("[E] eval_cell == native == GPU, 128 rows, break + variation on")
	var gw := 128
	var gh := 128
	var surf := _field(gw, gh)
	for mode in [0, 1]:
		var st := _strata(0.8, 0.7, mode)
		var nat := _grid(st, surf, gw, gh)
		var cell := PackedFloat32Array()
		cell.resize(gw * gh)
		for iz in gh:
			for ix in gw:
				var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, gw, gh, RECT)
				cell[iz * gw + ix] = st.eval_cell(w.x, w.y, PackedFloat32Array([surf[iz * gw + ix]]))
		var d := _max_abs_diff(nat, cell)
		print("    mode %d: max |native - eval_cell| = %.6f (want < 1e-3)" % [mode, d])
		if d > 1.0e-3:
			_fail += 1; print("    !! native and eval_cell disagree")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("    GPU: SKIPPED (graph_eval_grid_gpu not bound)")
		_done += 1
		return
	var gpu_by_mode := []
	var nat_by_mode := []
	for mode in [0, 1]:
		var prog: Dictionary = _filter_graph(_strata(0.8, 0.7, mode)).compile_graph_program()
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, gw, gh, RECT, surf)
		if gpu.is_empty():
			print("    GPU: SKIPPED for mode %d (no RenderingDevice, or the GPU refused)" % mode)
			if DisplayServer.get_name() != "headless":
				_fail += 1; print("    !! windowed, yet the GPU refused a Strata graph")
			_done += 1
			return
		var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, gw, gh, RECT, surf)
		gpu_by_mode.append(gpu)
		nat_by_mode.append(nat)
		var g := _max_abs_diff(gpu, nat)
		print("    GPU mode %d: max |GPU - native| = %.6f (want < %.6f)" % [mode, g, EPS_GPU])
		if g > EPS_GPU:
			_fail += 1; print("    !! the GPU Strata diverged from native")
	var ctl := _max_abs_diff(gpu_by_mode[1], nat_by_mode[0])
	print("    control: GPU SMOOTH vs native SHARP differ by %.3f m (want > 0.1)" % ctl)
	if ctl <= 0.1:
		_fail += 1; print("    !! the profile mode never reached the shader")
	_done += 1


## Steep runs (steps more than twice the input's slope) along one 4096-cell row spanning 10 base beds.
func _riser_runs(p_octaves: int, p_lacunarity: float) -> int:
	var n := 4096
	var surf := PackedFloat32Array()
	surf.resize(n)
	for i in n:
		surf[i] = 10.0 * float(i) / float(n)
	var out := Pasture3DUtil.strata_grid(surf, n, 1, RECT, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 45.0, 0,
			PackedFloat32Array(), 0, 0.0, p_octaves, p_lacunarity)
	var runs := 0
	var in_run := false
	for i in range(1, n):
		var steep := (out[i] - out[i - 1]) > 2.0 * (surf[i] - surf[i - 1])
		if steep and not in_run:
			runs += 1
		in_run = steep
	return runs


func _f_octaves_nest_beds() -> void:
	print("[F] octaves nest beds inside beds (T2)")
	var one := _riser_runs(1, 2.0)
	var three := _riser_runs(3, 2.0)
	var flat_lac := _riser_runs(3, 1.0)
	print("    risers over 10 base beds: octaves 1 = %d ; octaves 3 = %d (want >= %d) ; control lacunarity 1 = %d (want < %d)" % [one, three, 2 * one, flat_lac, 2 * one])
	if three < 2 * one:
		_fail += 1; print("    !! 3 octaves did not nest finer beds")
	if flat_lac >= 2 * one:
		_fail += 1; print("    !! control: lacunarity 1 still nested beds, so the count cannot see the octaves")
	if one < 9 or one > 11:
		_fail += 1; print("    !! a single octave should give one riser per bed")
	_done += 1


func _ramp_field(p_n: int, p_top: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			s[iz * p_n + ix] = p_top * float(ix) / float(p_n - 1)
	return s


## strata_grid with the T2 defaults and hardness 1, dip 3, break 2, plus the given mask settings.
func _masked(p_surf: PackedFloat32Array, p_n: int, p_flags: int, p_lo: float, p_hi: float,
		p_outcrop: float) -> PackedFloat32Array:
	return Pasture3DUtil.strata_grid(p_surf, p_n, p_n, RECT, 7.0, 1.0, 1.0, 3.0, 30.0, 2.0, 40.0, 3,
			PackedFloat32Array(), p_flags, 0.5, 3, 2.0, p_lo, p_hi, p_outcrop, 120.0)


func _g_elevation_mask() -> void:
	print("[G] elevation mask: none below Mask Low, full above Mask High (T3)")
	var n := 128
	var surf := _ramp_field(n, 100.0)
	var full := _masked(surf, n, 0, 20.0, 80.0, 0.0)
	var masked := _masked(surf, n, 2, 20.0, 80.0, 0.0)
	var below := 0.0
	var below_ctl := 0.0
	var above := 0.0
	var checked := 0
	for i in surf.size():
		if surf[i] <= 20.0:
			below = maxf(below, absf(masked[i] - surf[i]))
			below_ctl = maxf(below_ctl, absf(full[i] - surf[i]))
			checked += 1
		elif surf[i] >= 80.0:
			above = maxf(above, absf(masked[i] - full[i]))
			checked += 1
	print("    %d cells checked ; below 20 m max change %.7f (want 0) ; above 80 m max |masked - full| %.7f (want 0) ; control mask off below 20 m %.3f (want > 0.5)" % [checked, below, above, below_ctl])
	if checked < n * n / 3:
		_fail += 1; print("    !! too few cells in the checked bands")
	if below > EPS or above > EPS:
		_fail += 1; print("    !! the elevation window is wrong")
	if below_ctl <= 0.5:
		_fail += 1; print("    !! control: without the mask nothing changed below 20 m either, so this saw nothing")
	_done += 1


func _h_outcrop_mask() -> void:
	print("[H] outcrop mask: a factor in [1 - strength, 1] that varies across the ground (T3)")
	var n := 256
	var surf := _field(n, n)
	var full := _masked(surf, n, 0, 0.0, 0.0, 0.0)
	var lo := INF
	var hi := -INF
	var one := _masked(surf, n, 0, 0.0, 0.0, 1.0)
	var counted := 0
	for i in surf.size():
		var dfull := full[i] - surf[i]
		if absf(dfull) < 0.5:
			continue # too little change to read a ratio from
		counted += 1
		var r := (one[i] - surf[i]) / dfull
		lo = minf(lo, r); hi = maxf(hi, r)
	print("    %d cells ; strength 1 factor range [%.3f, %.3f] (want lo < 0.6, hi > 0.95, within [0, 1])" % [counted, lo, hi])
	if counted < 1000:
		_fail += 1; print("    !! too few cells changed to read the factor")
	if lo >= 0.6 or hi <= 0.95 or lo < -1.0e-4 or hi > 1.0 + 1.0e-4:
		_fail += 1; print("    !! the outcrop factor does not span the range it should")
	_done += 1


func _filter_graph(p_filter: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_filter, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	return g


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
