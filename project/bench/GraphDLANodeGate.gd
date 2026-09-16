# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDLANodeGate — the graph-native DLA mountain SOLVER (PASTURE3D_TERRAIN_GRAPH_SPEC.md, Solvers).
#
# Pure GDScript on the graph model + the Pasture3DReliefDLA growth engine (no DLL, no terrain). The node
# COMPOSES the relief DLA and drives its `grow_into` hook, so this gate does NOT re-derive the growth (which
# has its own long-standing DLAGate); it tests the graph adapter around it and the structural invariants a
# DLA massif must keep — the failure modes the growth's history records (empty, hollow/crater, cut off at
# the loop edge):
#   [A] DLA declares two outputs (height HEIGHT + footprint MASK), role SOLVER, one seed input.
#   [B] It grows a real massif: peak > 0 and INTERIOR (not a hollow ring), zero at the rect corners (outside
#       the coverage envelope — not cut off at the edge), height == amplitude·mask, and the growth is
#       deterministic (same seed → identical field). Control: amplitude scales the height and leaves the mask.
#   [C] Ridge Seeding uses the wired input: a ridged input with seeding ON grows a DIFFERENT field than the
#       central-seed one. Control: seeding ON with a FLAT (unwired) input falls back to the central seed, so
#       its field equals the seeding-OFF field.
#   [D] Per-solver freeze (FROZEN is the default): serves the cached mountain after a param change and
#       reports stale; Bake regrows. Control: LIVE regrows immediately and never goes stale.
#   [E] Multi-output routing: the footprint MASK (port 1) drives a Blend's mask input through the evaluator.
#       Control: unwiring the mask leaves the plain blend (mask == 1).
#   [G] A wired input is FILTERED, not replaced: fed a plateau mound, the flat plain around it comes out
#       exactly as it went in (no step at the loop), the flat summit is raised by the full amplitude, and the
#       slopes carry the massif's detail. Control: `amplitude * mask`, what the node output before, does not
#       keep the mound's shape (its correlation with the input is measured against the filter's).
#   [H] Stacked fading keeps fine levels off coarse ridge tops and creases: where the coarsest level's surface
#       is flat, the finished massif stays close to it. Control: the same cluster combined by plain max over
#       every level (no marks) moves those cells by clearly more.
#   [I] Ridge Width widens the flanks without resizing the mountain: 0.10 -> 0.40 lowers the massif's mean
#       slope, while the support (cells above 1% of peak) moves under 8%. Control: the same growth at one width
#       twice is identical, so a difference is the width and not noise.
#
# Every criterion measures a concrete delta and carries a control that must fail if the path is dead.
extends Node

const DLAScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dla.gd")

const GW := 48
const GH := 48
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0) # square so the massif and the seed frame are isotropic
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphDLANodeGate: graph-native DLA mountain solver ===\n")
	_a_declares_two_outputs()
	_b_grows_a_massif()
	_c_ridge_seeding_uses_input()
	_d_per_solver_freeze()
	_e_multi_output_mask_routing()
	_f_wired_amplitude_frozen()
	_g_wired_input_is_filtered()
	_h_stacked_fading()
	_i_ridge_width()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH DLA NODE PASS" if _fail == 0 else "GRAPH DLA NODE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# A small, fast massif: 64² working grid, 3 hierarchy rounds — grows in well under a second.
func _new_dla(p_eval) -> Pasture3DGraphNodeDLA:
	var d := Pasture3DGraphNodeDLA.new()
	d.resolution = 64
	d.hierarchy_levels = 3
	d.coverage = 0.9
	d.amplitude = 100.0
	d.evaluation = p_eval
	return d


# A ridged input surface: three sinusoidal crest lines, so ridge seeding has something to find.
func _ridged_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array(); g.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var u := float(ix) / float(GW - 1)
			g[iz * GW + ix] = 20.0 * absf(sin(u * TAU * 1.5))
	return g


# ---- [A] --------------------------------------------------------------------------------------------

func _a_declares_two_outputs() -> void:
	print("[A] DLA declares two outputs (height + footprint mask), role SOLVER, one seed input")
	var d := _new_dla(DLAScript.Evaluation.LIVE)
	var types: PackedInt32Array = d.output_port_types()
	var in_types: PackedInt32Array = d.input_port_types()
	var ok: bool = d.output_count() == 2 and d.output_names().size() == 2 and types.size() == 2 \
			and types[0] == Pasture3DGraphNode.PortType.HEIGHT and types[1] == Pasture3DGraphNode.PortType.MASK \
			and d.role() == Pasture3DGraphNode.Role.SOLVER and d.needs_grid() \
			and in_types.size() == d.input_count() and d.input_names().size() == d.input_count() \
			and in_types.size() > 0 and in_types[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and _param_ports(in_types) == d.input_count() - 1
	# One SEED input, at port 0. The node later grew FLOAT parameter sockets, so `input_count() == 1` stopped
	# being the way to say that; every port after the seed must be a scalar parameter, and the three port
	# arrays must agree on how many ports there are.
	print("    output_count=%d names=%s types=%s role=%d needs_grid=%s input_count=%d in_types=%s" % [
		d.output_count(), d.output_names(), types, d.role(), d.needs_grid(), d.input_count(), in_types])
	if not ok:
		_fail += 1; print("    !! DLA did not declare [HEIGHT, MASK] outputs as a grid SOLVER with one input")


# ---- [B] --------------------------------------------------------------------------------------------

func _b_grows_a_massif() -> void:
	print("[B] Grows a real massif: interior peak, zero at the corners, height == amplitude*mask, deterministic")
	var d := _new_dla(DLAScript.Evaluation.LIVE)
	var flat := PackedFloat32Array(); flat.resize(GW * GH) # unwired -> central seed
	var ch: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var height: PackedFloat32Array = ch[0]
	var mask: PackedFloat32Array = ch[1]

	# peak and its location
	var peak := 0.0
	var peak_i := 0
	var max_amp_err := 0.0
	for i in range(GW * GH):
		if height[i] > peak:
			peak = height[i]; peak_i = i
		max_amp_err = maxf(max_amp_err, absf(height[i] - 100.0 * mask[i]))
	var px := peak_i % GW
	var pz := peak_i / GW
	# distance of the peak from the rect centre, as a fraction of the half-extent
	var peak_r := sqrt(pow((float(px) + 0.5) / float(GW) * 2.0 - 1.0, 2.0) + pow((float(pz) + 0.5) / float(GH) * 2.0 - 1.0, 2.0))
	# corners of the rect are outside the coverage envelope -> must be zero
	var corner_max := maxf(maxf(height[0], height[GW - 1]), maxf(height[(GH - 1) * GW], height[GH * GW - 1]))
	print("    peak=%.3f m at fractional radius %.2f (want interior <0.6), max corner=%.4f (want ~0)" % [peak, peak_r, corner_max])
	print("    max |height - amplitude*mask| = %.6f" % max_amp_err)
	if peak <= EPS:
		_fail += 1; print("    !! DLA grew nothing (empty field)")
	if peak_r > 0.6:
		_fail += 1; print("    !! the peak sits near the rim — a hollow/ring massif, not a mountain")
	if corner_max > EPS:
		_fail += 1; print("    !! the massif is non-zero at the corners — cut off at the loop edge")
	if max_amp_err > EPS:
		_fail += 1; print("    !! height is not amplitude*mask (plumbing broken)")

	# determinism: same seed -> identical field
	var d2 := _new_dla(DLAScript.Evaluation.LIVE)
	var ch2: Array = d2.eval_grid_channels([flat], GW, GH, null, RECT)
	var det := _max_abs_diff(height, ch2[0])
	print("    determinism: two grows of the same seed differ by %.6f (want 0)" % det)
	if det > 0.0:
		_fail += 1; print("    !! DLA growth is not deterministic for a fixed seed")

	# CONTROL: doubling amplitude scales the height x2 and leaves the mask.
	d.amplitude = 200.0
	var ch3: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var h3: PackedFloat32Array = ch3[0]
	var m3: PackedFloat32Array = ch3[1]
	var mask_moved := _max_abs_diff(mask, m3)
	var scaled := true
	for i in range(GW * GH):
		if absf(h3[i] - 2.0 * height[i]) > 1.0e-3:
			scaled = false; break
	print("    control: amplitude 100->200 scaled height x2=%s, mask unchanged (dev %.6f)" % [scaled, mask_moved])
	if not scaled:
		_fail += 1; print("    !! amplitude did not scale the height linearly")
	if mask_moved > EPS:
		_fail += 1; print("    !! amplitude moved the mask (it must be amplitude-independent)")


# ---- [C] --------------------------------------------------------------------------------------------

func _c_ridge_seeding_uses_input() -> void:
	print("[C] Ridge Seeding grows out of the wired input's ridges")
	var surface := _ridged_surface()

	var off := _new_dla(DLAScript.Evaluation.LIVE)
	off.ridge_seeding = false
	var field_off: PackedFloat32Array = off.eval_grid_channels([surface], GW, GH, null, RECT)[1]

	var on := _new_dla(DLAScript.Evaluation.LIVE)
	on.ridge_seeding = true
	on.ridge_amount = 0.1
	var field_on: PackedFloat32Array = on.eval_grid_channels([surface], GW, GH, null, RECT)[1]

	var seeded_delta := _max_abs_diff(field_off, field_on)
	print("    seeding OFF vs ON over a ridged input differ by %.4f (want > 0)" % seeded_delta)
	if seeded_delta <= EPS:
		_fail += 1; print("    !! ridge seeding did not change the grown field (input ignored)")

	# CONTROL: seeding ON but a FLAT (unwired) input -> falls back to the central seed -> equals OFF.
	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var on_flat := _new_dla(DLAScript.Evaluation.LIVE)
	on_flat.ridge_seeding = true
	var field_on_flat: PackedFloat32Array = on_flat.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var off_flat := _new_dla(DLAScript.Evaluation.LIVE)
	var field_off_flat: PackedFloat32Array = off_flat.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var fallback_delta := _max_abs_diff(field_on_flat, field_off_flat)
	print("    control: seeding ON with a flat input falls back to central seed (delta %.6f, want 0)" % fallback_delta)
	if fallback_delta > EPS:
		_fail += 1; print("    !! a flat input did not fall back to the central seed")


# ---- [D] --------------------------------------------------------------------------------------------

func _d_per_solver_freeze() -> void:
	print("[D] Per-solver freeze: FROZEN serves the cached mountain and reports stale; Bake regrows")
	var d := _new_dla(DLAScript.Evaluation.FROZEN)
	print("    default evaluation is FROZEN=%s" % (Pasture3DGraphNodeDLA.new().evaluation == DLAScript.Evaluation.FROZEN))
	if Pasture3DGraphNodeDLA.new().evaluation != DLAScript.Evaluation.FROZEN:
		_fail += 1; print("    !! DLA did not default to FROZEN")

	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var ch1: Array = d.eval_grid_channels([flat], GW, GH, null, RECT) # solve -> caches
	var stale_after_first: bool = d._stale
	# Change a growth param while FROZEN: must serve the cache and go stale WITHOUT regrowing.
	d.seed = 999
	var ch2: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var served := _max_abs_diff(ch1[0], ch2[0]) < 1.0e-6
	print("    frozen: stale after fresh solve=%s, after seed change served cache=%s, stale=%s" % [stale_after_first, served, d._stale])
	if stale_after_first:
		_fail += 1; print("    !! FROZEN reported stale on its own fresh solve")
	if not served:
		_fail += 1; print("    !! FROZEN regrew instead of serving the cache after a param change")
	if not d._stale:
		_fail += 1; print("    !! FROZEN did not report itself stale after a param change")

	# Bake -> regrow with the new seed -> differs from the cached mountain.
	d.clear_cache()
	var ch3: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var regrew := _max_abs_diff(ch1[0], ch3[0]) > EPS
	print("    after Bake with the new seed: differs from cache=%s, stale cleared=%s" % [regrew, not d._stale])
	if not regrew:
		_fail += 1; print("    !! Bake did not regrow for the new seed")
	if d._stale:
		_fail += 1; print("    !! Bake did not clear the stale flag")

	# CONTROL: LIVE regrows immediately on a seed change and never goes stale.
	var live := _new_dla(DLAScript.Evaluation.LIVE)
	var la: Array = live.eval_grid_channels([flat], GW, GH, null, RECT)
	live.seed = 111
	var lb: Array = live.eval_grid_channels([flat], GW, GH, null, RECT)
	var live_ok := _max_abs_diff(la[0], lb[0]) > EPS and not live._stale
	print("    control: LIVE seed 0 vs 111 differ=%s, no stale=%s" % [_max_abs_diff(la[0], lb[0]) > EPS, not live._stale])
	if not live_ok:
		_fail += 1; print("    !! LIVE did not regrow on a param change / falsely went stale")


# ---- [E] --------------------------------------------------------------------------------------------

func _e_multi_output_mask_routing() -> void:
	print("[E] The footprint MASK (port 1) drives a Blend's mask input")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var dla_node := _new_dla(DLAScript.Evaluation.LIVE)
	var dn := g.add_node(dla_node, Vector2(200, 0))
	var ca = Pasture3DGraphNodeRegistry.create(&"const"); ca.set("value", 0.0)
	var cb = Pasture3DGraphNodeRegistry.create(&"const"); cb.set("value", 1.0)
	var na := g.add_node(ca, Vector2(0, 200))
	var nb := g.add_node(cb, Vector2(0, 300))
	var blend = Pasture3DGraphNodeRegistry.create(&"blend"); blend.set("mode", 0) # ADD
	var nbl := g.add_node(blend, Vector2(400, 100))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(600, 100))
	g.connect_ports(inp, 0, dn, 0)
	g.connect_ports(na, 0, nbl, 0)         # a = 0
	g.connect_ports(nb, 0, nbl, 1)         # b = 1
	g.connect_ports(dn, 1, nbl, 2)         # mask = DLA.mask (port 1) -> Blend mask (port 2)
	g.connect_ports(nbl, 0, out, 0)

	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var got := g.evaluate(GW, GH, RECT, null, flat)
	# Independent mask from an identical LIVE solve (deterministic): output = 0 + 1*clamp(mask,0,1) = mask.
	var solo := _new_dla(DLAScript.Evaluation.LIVE)
	var mask: PackedFloat32Array = solo.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var max_d := 0.0
	var gated := false
	for i in range(GW * GH):
		max_d = maxf(max_d, absf(got[i] - clampf(mask[i], 0.0, 1.0)))
		if mask[i] > 0.01 and mask[i] < 0.99:
			gated = true
	print("    max |blend - clamp(mask)| = %.6f (want ~0), mask spans partial values=%s" % [max_d, gated])
	if max_d > EPS:
		_fail += 1; print("    !! the DLA mask channel did not gate the blend correctly")
	if not gated:
		_fail += 1; print("    !! mask never took a partial value (gate not exercised)")

	# CONTROL: unwire the mask -> unwired default 1.0 -> plain blend = 1 everywhere.
	g.disconnect_ports(dn, 1, nbl, 2)
	var got2 := g.evaluate(GW, GH, RECT, null, flat)
	var cmax := 0.0
	for i in range(GW * GH):
		cmax = maxf(cmax, absf(got2[i] - 1.0))
	print("    control: mask unwired -> blend max dev from 1.0 = %.6f" % cmax)
	if cmax > EPS:
		_fail += 1; print("    !! unwired mask was not treated as full strength (1.0)")


# ---- [F] --------------------------------------------------------------------------------------------

## FROZEN amplitude is exact on both sides of the cache. A miss used to multiply by the EXPORT and ignore a
## wired amplitude; a hit rescaled the cached height by wired/export, which assumed the cache had been grown
## at the current export, so an Amplitude edit after a bake served the old height.
func _f_wired_amplitude_frozen() -> void:
	print("[F] FROZEN amplitude: a wired value is used on a miss; a hit is amplitude*mask whatever the history")
	var d := _new_dla(DLAScript.Evaluation.FROZEN) # export amplitude 100
	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var miss: Array = d.eval_grid_channels([flat, PackedFloat32Array([50.0])], GW, GH, null, RECT)
	var mask: PackedFloat32Array = miss[1]
	var miss_err := _amp_err(miss[0], mask, 50.0)
	var miss_ctrl := _amp_err(miss[0], mask, 100.0) # the export, which the miss used to apply
	d.amplitude = 300.0
	var hit: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var hit_err := _amp_err(hit[0], mask, 300.0)
	var hit_ctrl := _amp_err(hit[0], mask, 50.0) # the cached height, which the old ratio (300/300) served
	var wired_hit: Array = d.eval_grid_channels([flat, PackedFloat32Array([25.0])], GW, GH, null, RECT)
	var wired_err := _amp_err(wired_hit[0], mask, 25.0)
	var served := _max_abs_diff(mask, hit[1]) < 1.0e-6 and _max_abs_diff(mask, wired_hit[1]) < 1.0e-6
	print("    miss: |h-50m|=%.6f (control |h-100m|=%.3f) | export 300 hit: |h-300m|=%.6f (control |h-50m|=%.3f) | wired 25 hit: |h-25m|=%.6f | mask served=%s"
		% [miss_err, miss_ctrl, hit_err, hit_ctrl, wired_err, served])
	if miss_err > EPS or miss_ctrl <= 1.0:
		_fail += 1; print("    !! a cache miss did not apply the wired amplitude")
	if hit_err > 1.0e-3 or hit_ctrl <= 1.0 or wired_err > 1.0e-3:
		_fail += 1; print("    !! a cache hit did not rebuild height as amplitude*mask")
	if not served:
		_fail += 1; print("    !! the frozen mask was regrown instead of served")


# ---- [G] --------------------------------------------------------------------------------------------

func _g_wired_input_is_filtered() -> void:
	print("[G] A wired input is filtered, not replaced: plain unchanged, summit raised by amplitude, slopes carry detail")
	var d := _new_dla(DLAScript.Evaluation.LIVE)
	var amp := 100.0
	# A plateau mound: flat top inside r 0.2, flat plain outside r 0.7, a smooth flank between.
	var g := PackedFloat32Array(); g.resize(GW * GH)
	var radius := PackedFloat32Array(); radius.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var u := (float(ix) + 0.5) / float(GW) * 2.0 - 1.0
			var v := (float(iz) + 0.5) / float(GH) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var t := clampf((0.7 - r) / 0.5, 0.0, 1.0)
			g[iz * GW + ix] = 60.0 * t * t * (3.0 - 2.0 * t)
			radius[iz * GW + ix] = r
	var ch: Array = d.eval_grid_channels([g], GW, GH, null, RECT)
	var out: PackedFloat32Array = ch[0]
	var mask: PackedFloat32Array = ch[1]
	var plain_err := 0.0
	var summit_err := 0.0
	var old := PackedFloat32Array(); old.resize(GW * GH)
	var resid := PackedFloat32Array()
	for i in range(GW * GH):
		old[i] = amp * mask[i]
		var r := radius[i]
		if r > 0.75:
			plain_err = maxf(plain_err, absf(out[i] - g[i]))
		elif r < 0.15:
			summit_err = maxf(summit_err, absf(out[i] - (g[i] + amp)))
		elif r > 0.35 and r < 0.55:
			resid.append(out[i] - g[i] - amp * (g[i] / 60.0)) # what the massif changed on the flank
	var spread := 0.0
	var mean := 0.0
	for v in resid:
		mean += v
	mean /= maxf(float(resid.size()), 1.0)
	for v in resid:
		spread += (v - mean) * (v - mean)
	spread = sqrt(spread / maxf(float(resid.size()), 1.0))
	var c_new := _corr(out, g)
	var c_old := _corr(old, g)
	print("    plain max |out - in| = %.6f m   summit max |out - (in + amp)| = %.4f m   flank detail spread = %.3f m"
			% [plain_err, summit_err, spread])
	print("    correlation with the input: filtered %.3f   CONTROL amplitude*mask %.3f" % [c_new, c_old])
	if plain_err > 1.0e-3:
		_fail += 1; print("    !! the plain around the mound moved; the filter steps at the loop")
	if summit_err > 0.01 * amp:
		_fail += 1; print("    !! the flat summit was not raised by the amplitude; the peak is not preserved")
	if spread < 0.02 * amp:
		_fail += 1; print("    !! the flank carries no massif detail; the filter faded everything out")
	if c_new < 0.9 or c_new <= c_old:
		_fail += 1; print("    !! the filtered output does not keep the input's shape better than the massif alone")


# ---- [H] --------------------------------------------------------------------------------------------

func _h_stacked_fading() -> void:
	print("[H] Stacked fading: fine levels stay off the coarse level's ridge tops and creases")
	var m := Pasture3DReliefDLA.new()
	m.resolution = 128
	m.hierarchy_levels = 4
	m.coverage = 0.9
	m.detail_size = 0.12
	m.profile_power = 1.0
	var n := 128
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var cl: Array = m._grow(rng, 16, n)
	var marks: PackedInt32Array = cl[3]
	var parents: PackedInt32Array = cl[2]
	var xs := Pasture3DReliefDLA._unstair(cl[0], parents)
	var ys := Pasture3DReliefDLA._unstair(cl[1], parents)
	var depth := Pasture3DReliefDLA._depths(parents)
	var deepest := 1
	for dv in depth:
		deepest = maxi(deepest, dv)
	var coarse := m._cone_field(xs, ys, parents, depth, float(deepest + 1), marks[0], n, false,
			PackedFloat32Array(), m._outer(n), float(m._slope_run(n)))
	var cpk := 0.0
	for v in coarse:
		cpk = maxf(cpk, v)
	var flatmask := Pasture3DReliefDLA._slope_mask(coarse, n)
	var stacked := m._massif(cl, n)
	var plain := m._massif([cl[0], cl[1], cl[2], PackedInt32Array(), cl[4]], n)
	var spk := 0.0
	var ppk := 0.0
	for i in range(n * n):
		spk = maxf(spk, stacked[i])
		ppk = maxf(ppk, plain[i])
	var ds := 0.0
	var dp := 0.0
	var k := 0
	for i in range(n * n):
		if coarse[i] <= 0.0 or flatmask[i] >= 0.2:
			continue
		ds += absf(stacked[i] / spk - coarse[i] / cpk)
		dp += absf(plain[i] / ppk - coarse[i] / cpk)
		k += 1
	ds /= maxf(float(k), 1.0)
	dp /= maxf(float(k), 1.0)
	print("    levels=%d  flat coarse cells=%d  mean move off the coarse surface: stacked %.4f   CONTROL plain max %.4f"
			% [marks.size(), k, ds, dp])
	if marks.size() < 2 or k < 20:
		_fail += 1; print("    !! nothing to measure: one level, or no flat coarse cells")
	elif ds >= 0.8 * dp:
		_fail += 1; print("    !! stacking did not keep fine detail off the coarse ridge tops")


# ---- [I] --------------------------------------------------------------------------------------------

func _i_ridge_width() -> void:
	print("[I] Ridge Width widens the flanks without resizing the mountain")
	var narrow := _i_stats(0.10)
	var wide := _i_stats(0.40)
	var again := _i_stats(0.10)
	var drift := absf(wide[1] - narrow[1]) / maxf(narrow[1], 1.0)
	print("    width 0.10: mean slope %.4f  support %d cells | width 0.40: mean slope %.4f  support %d cells | support moved %.1f%%"
			% [narrow[0], narrow[1], wide[0], wide[1], 100.0 * drift])
	print("    CONTROL width 0.10 twice: mean slope %.4f vs %.4f" % [narrow[0], again[0]])
	if narrow[0] != again[0]:
		_fail += 1; print("    !! the same width grew two different massifs; the comparison is noise")
	if wide[0] >= 0.8 * narrow[0]:
		_fail += 1; print("    !! a wider ridge did not make gentler flanks; the control is inert")
	if drift > 0.08:
		_fail += 1; print("    !! Ridge Width resized the mountain; Coverage is not the size control it claims")


## [mean |grad| over the support, support cells] of the unit massif at one ridge width.
func _i_stats(p_width: float) -> Array:
	var m := Pasture3DReliefDLA.new()
	m.resolution = 128
	m.hierarchy_levels = 3
	m.coverage = 0.9
	m.detail_size = 0.12
	m.ridge_width = p_width
	var n := 128
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var f := m._massif(m._grow(rng, 32, n), n)
	var pk := 0.0
	for v in f:
		pk = maxf(pk, v)
	var sum := 0.0
	var k := 0
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			if f[i] <= 0.01 * pk:
				continue
			var gx := (f[i + 1] - f[i - 1]) * 0.5
			var gy := (f[i + n] - f[i - n]) * 0.5
			sum += sqrt(gx * gx + gy * gy)
			k += 1
	return [sum / maxf(float(k), 1.0), k]


func _corr(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var n := float(p_a.size())
	var ma := 0.0
	var mb := 0.0
	for i in range(p_a.size()):
		ma += p_a[i]
		mb += p_b[i]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(p_a.size()):
		sab += (p_a[i] - ma) * (p_b[i] - mb)
		saa += (p_a[i] - ma) * (p_a[i] - ma)
		sbb += (p_b[i] - mb) * (p_b[i] - mb)
	return sab / sqrt(maxf(saa * sbb, 1.0e-30))


func _amp_err(p_h: PackedFloat32Array, p_mask: PackedFloat32Array, p_amp: float) -> float:
	var e := 0.0
	for i in range(p_h.size()):
		if not is_nan(p_h[i]):
			e = maxf(e, absf(p_h[i] - p_amp * p_mask[i]))
	return e


# ---- helpers ----------------------------------------------------------------------------------------

func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var d := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		var av := p_a[i]; var bv := p_b[i]
		if is_nan(av) or is_nan(bv):
			continue
		d = maxf(d, absf(av - bv))
	return d


## How many of these ports are scalar parameter sockets rather than field inputs.
func _param_ports(p_types: PackedInt32Array) -> int:
	var c := 0
	for t in p_types:
		if t == Pasture3DGraphNode.PortType.FLOAT or t == Pasture3DGraphNode.PortType.INT:
			c += 1
	return c
