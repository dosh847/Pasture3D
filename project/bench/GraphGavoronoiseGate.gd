# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGavoronoiseGate — spec §7.2, the GENERATOR form (base unwired). GraphGavoronoiseBaseGate covers the
# base-input form.
#
# GB and GC are the criteria that say this is eroded terrain, and each runs the failure it exists to catch
# as a live control. GB's control IS the bug the node was rewritten for: a 1 - F1 Voronoi field, built in
# this gate, whose cones have one slope everywhere. GC's control is the same
# erosion detail measured against an unrelated landform's downhill, which a slope-blind detail would match.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphGavoronoiseGate.tscn
extends Node

const GW := 128
const GH := 128
const RECT := Rect2(-1000.0, -1000.0, 2000.0, 2000.0)
## The oracle is GDScript running ~200k statements a cell, so parity runs on a small grid.
const ORACLE_N := 20
## One float32 ulp at 100 m is 7.6e-6; the oracle is double and the kernel writes float32.
const PARITY_EPS := 5.0e-5
## The GPU runs in float32 and the CPU in double, and the erosion stage feeds its own slope back, so a
## last-bit difference is amplified a little per octave. Stated as a fraction of relief so it cannot
## quietly become slack when someone raises the amplitude in a fixture.
const GPU_TOL_FRACTION := 0.01

var _fail := 0


func _ready() -> void:
	print("=== GraphGavoronoiseGate: eroded-terrain noise, generator form (§7.2) ===\n")
	_ga_determinism()
	_gb_smooth_landform_not_facets()
	_gc_gullies_run_downhill()
	_gd_amplitude_scales_linearly()
	_ge_strike_orients_the_base()
	_gf_parity_and_route()
	_gg_resolution_invariance()
	_gh_gpu()
	print("\n=== %s (%d failures) ===\n" % ["GAVORONOISE PASS" if _fail == 0 else "GAVORONOISE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- GA. the field is a pure function of the seed -----------------------------------------------------
func _ga_determinism() -> void:
	print("[GA] the field is a pure function of the seed")
	var a := _gen({"seed": 7})
	var b := _gen({"seed": 7})
	var d := _max_abs_diff(a, b)
	print("    two evaluations at seed 7 differ by %.9f (want 0 exactly)" % d)
	if d > 0.0:
		_fail += 1; print("    !! the generator is not deterministic")
	# CONTROL: a different seed must give a different field, or GA passes for a constant.
	var cd := _max_abs_diff(a, _gen({"seed": 8}))
	print("    control: seed 8 differs from seed 7 by %.4f m (want > 1.0)" % cd)
	if cd <= 1.0:
		_fail += 1; print("    !! control dead — the seed does not change the field")


# --- GB. a smooth landform, not facets ----------------------------------------------------------------
## The old node was 1 - F1 Voronoi: a cone on every feature point. A cone has the SAME slope everywhere on
## it, so its slope magnitudes bunch around one value, and only the creases between cones break that up. A
## landform has summits, saddles and valley floors where the slope runs down to zero, so its slopes spread
## wide. The coefficient of variation of |gradient| measures exactly that spread.
func _gb_smooth_landform_not_facets() -> void:
	print("[GB] the base is a landform, not cones (coefficient of variation of |gradient|)")
	var base := _gen({"erosion_strength": 0.0})
	var cb := _slope_cv(base)
	var cf := _slope_cv(_gen({}))
	var cv := _slope_cv(_voronoi_cones())
	print("    base %.3f, with erosion %.3f (want both > 0.4)" % [cb, cf])
	if cb <= 0.4 or cf <= 0.4:
		_fail += 1; print("    !! the slopes bunch around one value — the field is cones, not mountains")
	# CONTROL: the faceted field this node used to draw must fail the same test.
	print("    control: the old 1-F1 Voronoi %.3f (want <= 0.4)" % cv)
	if cv > 0.4:
		_fail += 1; print("    !! control dead — 1-F1 Voronoi passed, so GB cannot tell cones from mountains")
	if _relief(base) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the base is flat, so its slopes compared nothing")


# --- GC. the gullies run downhill ---------------------------------------------------------------------
## The erosion detail (full - base) varies ACROSS the base's downhill, because its crests run down it.
## Measured as the gradient energy of the detail across the base's slope over the energy along it, on
## cells where the base is in the erosion window and has a slope worth reading.
func _gc_gullies_run_downhill() -> void:
	print("[GC] the erosion detail's crests run down the base's slope")
	# Half the default frequency, so the erosion octaves this fixture keeps are resolved on a 15.6 m grid.
	var base := _gen({"erosion_strength": 0.0, "frequency": 0.001})
	var detail := _sub(_gen({"frequency": 0.001}), base)
	var r := _across_over_along(detail, base)
	print("    detail across/along the base's downhill = %.2f (want > 1.8)" % r)
	if r <= 1.8:
		_fail += 1; print("    !! the gullies do not follow the slope")
	# CONTROL: the same detail against an unrelated landform's downhill. Slope-blind detail scores the same
	# against either; detail that follows ITS base does not follow another.
	var other := _gen({"erosion_strength": 0.0, "frequency": 0.001, "seed": 4321})
	var c := _across_over_along(detail, other)
	print("    control: against an unrelated landform = %.2f (want < 1.3)" % c)
	if c >= 1.3:
		_fail += 1; print("    !! control dead — the measure scores any detail high")


# --- GD. amplitude scales linearly --------------------------------------------------------------------
func _gd_amplitude_scales_linearly() -> void:
	print("[GD] amplitude scales the field linearly")
	var a := _gen({"amplitude": 50.0})
	var b := _gen({"amplitude": 150.0})
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(b[i] - a[i] * 3.0))
	print("    max |f(150) - 3*f(50)| = %.6f m (want < 1e-3)" % worst)
	if worst > 1.0e-3:
		_fail += 1; print("    !! amplitude is not a pure output scale — it is feeding back into the shape")
	if _relief(a) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the field is flat, so linearity was checked against nothing")


# --- GE. strike orientation ---------------------------------------------------------------------------
func _ge_strike_orients_the_base() -> void:
	print("[GE] angle_deg rotates the base's ridges; angle_spread = 0 makes them parallel")
	# Erosion off: its gullies run across the ridges by design, which is GC's business, not this one's.
	var at0 := _anisotropy(_gen({"angle_deg": 0.0, "angle_spread": 0.0, "erosion_strength": 0.0}), 0.0)
	var at90 := _anisotropy(_gen({"angle_deg": 90.0, "angle_spread": 0.0, "erosion_strength": 0.0}), 90.0)
	print("    anisotropy in the strike frame: 0deg %.2f, 90deg %.2f (want both > 2.0)" % [at0, at90])
	if at0 <= 2.0 or at90 <= 2.0:
		_fail += 1; print("    !! spread 0 did not produce parallel ridges")
	var wrong := _anisotropy(_gen({"angle_deg": 90.0, "angle_spread": 0.0, "erosion_strength": 0.0}), 0.0)
	print("    the 90deg field measured in the 0deg frame gives %.2f (want < 1.0 — it rotated)" % wrong)
	if wrong >= 1.0:
		_fail += 1; print("    !! angle_deg did not rotate the structure")
	# CONTROL: full spread must destroy the banding, or GE passes for a node that is always banded.
	var full := _anisotropy(_gen({"angle_deg": 0.0, "angle_spread": 1.0, "erosion_strength": 0.0}), 0.0)
	print("    control: spread 1.0 gives %.2f (want < 2.0 — the banding is gone)" % full)
	if full >= 2.0:
		_fail += 1; print("    !! control dead — angle_spread has no effect on the banding")


# --- GF. parity + the native route --------------------------------------------------------------------
func _gf_parity_and_route() -> void:
	print("[GF] kernel == oracle, and the graph takes the native route to that kernel")
	var g := _build_graph(_node({}))
	if not g.native_supported():
		_fail += 1
		print("    !! native_supported() = FALSE — this drops the WHOLE graph onto the GDScript evaluator.")
		return
	for over in [{}, {"angle_spread": 0.3, "branch_strength": 0.5, "octaves": 3, "seed": -9}]:
		var n := _node(over)
		var kp: Dictionary = n.kernel_params(n.amplitude, n.angle_deg, n.frequency)
		var direct: PackedFloat32Array = Pasture3DUtil.gavoronoise_grid(ORACLE_N, ORACLE_N, RECT, kp)
		var dev := Pasture3DGraphNodeDevGavoronoise.new()
		for k in kp:
			dev.set(k, kp[k])
		var oracle := dev.solve(ORACLE_N, ORACLE_N, RECT)
		var dk := _max_abs_diff(direct, oracle)
		print("    %s  kernel vs oracle %.9f (want < %s)" % [str(over), dk, str(PARITY_EPS)])
		if dk > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree")
		if _relief(direct) <= 1.0:
			_fail += 1; print("      !! NO-SIGNAL — flat field, parity compared nothing")
	# The route: the graph program carries params as float32, so the direct call gets the same rounding,
	# and then nothing is allowed to differ.
	var n2 := _node({})
	var kp2: Dictionary = n2.kernel_params(_f32(n2.amplitude), _f32(n2.angle_deg), _f32(n2.frequency))
	for k in ["angle_spread", "slope_strength", "branch_strength", "z_cut_min", "z_cut_max", "erosion_strength",
			"erosion_frequency"]:
		kp2[k] = _f32(kp2[k])
	var dr := _max_abs_diff(_build_graph(n2).evaluate(GW, GH, RECT, null, PackedFloat32Array()),
			Pasture3DUtil.gavoronoise_grid(GW, GH, RECT, kp2))
	print("    graph route vs kernel with float32 params: %.9f (want 0)" % dr)
	if dr > 0.0:
		_fail += 1; print("    !! the graph route does not reach the kernel with the node's parameters")


# --- GG. resolution invariance ------------------------------------------------------------------------
func _gg_resolution_invariance() -> void:
	print("[GG] frequency is cycles per METRE — the same rect gives the same field at any resolution")
	var lo_n := 96
	var hi_n := 192
	# A low frequency and few erosion octaves, so the finest wave the fixture keeps is above Nyquist at
	# 96^2. Above it, two resolutions sample genuinely different detail: aliasing, not a units error.
	var cfg := {"frequency": 0.0005, "octaves": 2, "erosion_frequency": 2.0}
	var lo := _gen_at(cfg, lo_n)
	var hi := _gen_at(cfg, hi_n)
	var relief := _relief(lo)
	var diffs := _resolution_diffs(lo, lo_n, hi, hi_n)
	var p99 := _percentile(diffs, 0.99)
	print("    |f(96^2) - f(192^2)|: p99 %.3f m, max %.3f m, over %.1f m relief (want p99 < 3%%)"
			% [p99, _percentile(diffs, 1.0), relief])
	if p99 > 0.03 * relief:
		_fail += 1; print("    !! the field changed with the grid — frequency is per cell, not per metre")
	# CONTROL: half the frequency must move it by more than the tolerance, measured the same way.
	var cfg2 := cfg.duplicate()
	cfg2["frequency"] = 0.00025
	var cw := _percentile(_resolution_diffs(lo, lo_n, _gen_at(cfg2, hi_n), hi_n), 0.99)
	print("    control: half the frequency moves p99 to %.3f m (want > %.3f)" % [cw, 0.03 * relief])
	if cw <= 0.03 * relief:
		_fail += 1; print("    !! control dead — this fixture cannot tell two frequencies apart")


# --- GH. GPU route ------------------------------------------------------------------------------------
func _gh_gpu() -> void:
	print("[GH] the generator takes the GPU path and agrees with the CPU")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	for over in [{}, {"angle_spread": 0.0, "octaves": 12, "erosion_strength": 0.2}]:
		var g := _build_graph(_node(over))
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				g.compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
		if gpu.is_empty():
			var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_io_graph().compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
			if ctrl.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    !! the GPU bailed on Gavoronoise but not on a bare in->out graph; the bail is graph-wide.")
			return
		var cpu := g.evaluate(GW, GH, RECT, null, PackedFloat32Array())
		var d := _max_abs_diff(gpu, cpu)
		var budget := GPU_TOL_FRACTION * maxf(_relief(cpu), 1.0)
		print("    %s  max |gpu - cpu| = %.5f m (budget %.5f m)" % [str(over), d, budget])
		if d > budget:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel beyond float32 divergence")
		if _relief(gpu) <= 1.0:
			_fail += 1; print("      !! NO-SIGNAL — the GPU returned a flat field")


# --- construction --------------------------------------------------------------------------------------
func _defaults() -> Dictionary:
	return {
		"amplitude": 100.0,
		"frequency": 0.002,
		"octaves": 8,
		"seed": 1234,
		"angle_deg": 0.0,
		"angle_spread": 1.0,
		"slope_strength": 1.0,
		"branch_strength": 2.0,
		"z_cut_min": 0.0,
		"z_cut_max": 1.0,
		"erosion_strength": 0.1,
		"erosion_frequency": 4.0,
	}


func _node(p_over: Dictionary) -> Pasture3DGraphNodeGavoronoise:
	var n := Pasture3DGraphNodeGavoronoise.new()
	var cfg := _defaults()
	for k in p_over:
		cfg[k] = p_over[k]
	for k in cfg:
		n.set(k, cfg[k])
	return n


func _gen(p_over: Dictionary) -> PackedFloat32Array:
	return _gen_at(p_over, GW)


func _gen_at(p_over: Dictionary, p_n: int) -> PackedFloat32Array:
	return _build_graph(_node(p_over)).evaluate(p_n, p_n, RECT, null, PackedFloat32Array())


func _build_graph(p_gen: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_gen, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	return g


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	return g


## The bug, as a fixture: 1 - F1 Voronoi at one feature per 125 m, scaled to 100 m.
func _voronoi_cones() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var cell := 125.0
	var nc := int(RECT.size.x / cell) + 2
	var pts := PackedVector2Array()
	for j in nc:
		for i in nc:
			pts.append(RECT.position + Vector2((i - 1 + rng.randf()) * cell, (j - 1 + rng.randf()) * cell))
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var ci := int((w.x - RECT.position.x) / cell) + 1
			var cj := int((w.y - RECT.position.y) / cell) + 1
			var best := INF
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var a := clampi(ci + di, 0, nc - 1)
					var b := clampi(cj + dj, 0, nc - 1)
					best = minf(best, w.distance_to(pts[b * nc + a]))
			out[iz * GW + ix] = clampf(1.0 - best / cell, 0.0, 1.0) * 100.0
	return out


# --- measurement --------------------------------------------------------------------------------------
## Standard deviation of |gradient| over its mean, on the interior.
func _slope_cv(p_g: PackedFloat32Array) -> float:
	var s := PackedFloat64Array()
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			s.append(Vector2(p_g[i + 1] - p_g[i - 1], p_g[i + GW] - p_g[i - GW]).length())
	var mean := 0.0
	for v in s:
		mean += v
	mean /= s.size()
	var var_sum := 0.0
	for v in s:
		var_sum += (v - mean) * (v - mean)
	return sqrt(var_sum / s.size()) / maxf(mean, 1.0e-12)


## Summed squared gradient of p_detail ACROSS p_base's downhill over the sum ALONG it, on cells where the
## base has a slope worth reading. High means p_detail's crests run down p_base.
func _across_over_along(p_detail: PackedFloat32Array, p_base: PackedFloat32Array) -> float:
	var s_across := 0.0
	var s_along := 0.0
	var dx := RECT.size.x / GW
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			var bg := Vector2(p_base[i + 1] - p_base[i - 1], p_base[i + GW] - p_base[i - GW]) / (2.0 * dx)
			if bg.length() < 0.02:
				continue
			var down := bg.normalized()
			var across := Vector2(-down.y, down.x)
			var dg := Vector2(p_detail[i + 1] - p_detail[i - 1], p_detail[i + GW] - p_detail[i - GW])
			s_across += pow(dg.dot(across), 2.0)
			s_along += pow(dg.dot(down), 2.0)
	return s_across / maxf(s_along, 1.0e-12)


## Mean |gradient| ACROSS the strike divided by mean |gradient| ALONG it, in the frame rotated by
## p_angle_deg. Parallel bands vary strongly across and hardly at all along, so this is large.
func _anisotropy(p_g: PackedFloat32Array, p_angle_deg: float) -> float:
	var th := deg_to_rad(p_angle_deg)
	var cs := cos(th)
	var sn := sin(th)
	var along := 0.0
	var across := 0.0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			var gx := (p_g[i + 1] - p_g[i - 1]) * 0.5
			var gz := (p_g[i + GW] - p_g[i - GW]) * 0.5
			along += absf(gx * cs + gz * sn)
			across += absf(-gx * sn + gz * cs)
	return across / along if along > 1.0e-9 else 0.0


## Per-cell |difference| between a coarse grid and a fine one, at the coarse grid's world points, reading
## the fine grid bilinearly: cell centres never coincide across resolutions.
func _resolution_diffs(p_a: PackedFloat32Array, p_an: int, p_b: PackedFloat32Array,
		p_bn: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var dx := RECT.size.x / float(p_bn)
	var dz := RECT.size.y / float(p_bn)
	for iz in range(4, p_an - 4):
		for ix in range(4, p_an - 4):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_an, p_an, RECT)
			var fx := (w.x - RECT.position.x) / dx - 0.5
			var fz := (w.y - RECT.position.y) / dz - 0.5
			var x0 := clampi(int(floor(fx)), 0, p_bn - 1)
			var z0 := clampi(int(floor(fz)), 0, p_bn - 1)
			var x1 := clampi(x0 + 1, 0, p_bn - 1)
			var z1 := clampi(z0 + 1, 0, p_bn - 1)
			var tx := clampf(fx - float(x0), 0.0, 1.0)
			var tz := clampf(fz - float(z0), 0.0, 1.0)
			var top: float = lerpf(p_b[z0 * p_bn + x0], p_b[z0 * p_bn + x1], tx)
			var bot: float = lerpf(p_b[z1 * p_bn + x0], p_b[z1 * p_bn + x1], tx)
			out.append(absf(p_a[iz * p_an + ix] - lerpf(top, bot, tz)))
	return out


func _sub(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var out := p_a.duplicate()
	for i in out.size():
		out[i] -= p_b[i]
	return out


func _f32(p_v: float) -> float:
	return PackedFloat32Array([p_v])[0]


func _percentile(p_g: PackedFloat32Array, p_q: float) -> float:
	var arr := Array(p_g)
	arr.sort()
	return arr[clampi(int(arr.size() * p_q), 0, arr.size() - 1)]


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_g:
		if is_nan(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return maxf(hi - lo, 0.0)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) and is_nan(y):
			continue
		if is_nan(x) or is_nan(y):
			return INF
		m = maxf(m, absf(x - y))
	return m
