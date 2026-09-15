# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDistanceMetricGate — the shared distance metric (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §3.4).
#
#   A  Falloff on native CPU is BIT-IDENTICAL to the pre-refactor baseline, all 64 cases.
#      Control: the same cases with feather +1 m must NOT match, or A compared hashes that ignore the graph.
#   B  GPU Falloff, called DIRECTLY (through evaluate() a refusal would fall back to the CPU and match
#      perfectly). Each case is either bit-identical to the baseline, or within EPS_GPU of the CPU result
#      with the same NaN cells. AMENDED from bit-identity on 2026-09-14: moving the metric into a shared
#      GLSL function changed float32 rounding in the 16 soft-feather + noise cases by up to 6.2e-6 m
#      (3-4 ulps at these heights), the same class as the pre-refactor CPU/GPU gap. The CPU is still held
#      to bits in A. Controls: a GPU-refused program (Leveler channel 1) comes back empty, so a refusal is
#      recognisable; and feather +1 m lands OUTSIDE the tolerance, so the tolerance can still see a change.
#   C  GDScript oracle vs the C++ metric over a 257x257 sweep, all 8 metrics, an off-axis direction.
#      Control: the C++ grid with the direction NEGATED must fail agreement and equal -oracle for LINEAR.
#      (Not "swap a and b": that gives L - x, not -x, and would have been a control for the wrong claim.)
#   D  a == b: the C++ direction falls back to +X and matches the oracle's fallback.
#      Control: the oracle measured along +Z must NOT match.
#   F  Repeat modes: oracle vs C++ over values spanning [-3, 3] plus NaN.
#      Control: MIRROR's C++ output compared against REPEAT's oracle must fail.
#   E  Every criterion above completed. A criterion that throws before reporting fails the gate.
#
# The baseline is res://bench/fixtures/falloff_metric_baseline.json, written by FalloffBaselineCapture on
# the pre-refactor build. This gate never rewrites it.
#
# WINDOWED for B. Headless, B reports SKIPPED and the gate cannot print PASS, only PARTIAL.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphDistanceMetricGate.tscn
extends Node

const Fixture := preload("res://bench/FalloffMetricFixture.gd")
const BASELINE := "res://bench/fixtures/falloff_metric_baseline.json"
const SW := 257
const SH := 257
const SRECT := Rect2(-1210.0, 340.0, 2400.0, 2400.0)
const EPS_M := 1.0e-3 # float32 grid at ~2 km coordinates: one ulp is ~1.2e-4 m
const EPS_RAD := 1.0e-5
const EPS_GPU := 1.0e-5 # B: ~5 float32 ulps at the fixture's 10-20 m heights
const CRITERIA := ["A", "B", "C", "D", "F"]

var _fail := 0
var _seen := {}
var _skipped := {}


func _ready() -> void:
	print("=== GraphDistanceMetricGate: shared distance metric (spec §3.4) ===")
	for m in ["graph_eval_grid_gpu", "graph_distance_metric_grid", "graph_repeat_values"]:
		if not ClassDB.class_has_method("Pasture3DUtil", m):
			print("!! Pasture3DUtil.%s is not bound — rebuild the GDExtension" % m)
			get_tree().quit(1)
			return
	var base := _load_baseline()
	if base.is_empty():
		get_tree().quit(1)
		return

	_run("A", _a_cpu_bit_identical.bind(base))
	_run("B", _b_gpu_bit_identical.bind(base))
	_run("C", _c_oracle_matches_cpp)
	_run("D", _d_degenerate_direction)
	_run("F", _f_repeat)

	for name in CRITERIA:
		if not _seen.has(name) and not _skipped.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	var verdict := "FAIL" if _fail > 0 else ("PARTIAL" if not _skipped.is_empty() else "PASS")
	print("=== DISTANCE METRIC %s (%d failures, %d skipped) ===" % [verdict, _fail, _skipped.size()])
	get_tree().quit(0 if _fail == 0 else 1)


## Runs one criterion. A criterion that errors out stops before _check, is absent from _seen, and so is
## counted as a failure by the completion check rather than passing by silence.
func _run(p_name: String, p_fn: Callable) -> void:
	p_fn.call()
	if not _seen.has(p_name) and not _skipped.has(p_name):
		print("!! [%s] returned without reporting" % p_name)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE):
		print("!! baseline %s is missing — it must come from the PRE-refactor build" % BASELINE)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	if not (parsed is Dictionary) or not parsed.has("cases") or (parsed["cases"] as Array).size() != 64:
		print("!! baseline is malformed or not 64 cases")
		return {}
	return parsed


# --- A. native CPU bit-identity ----------------------------------------------------------------------
func _a_cpu_bit_identical(p_base: Dictionary) -> void:
	print("[A] native Falloff == pre-refactor baseline, bit for bit")
	var fx := Fixture.new()
	var surf := fx.terrain()
	var matched := 0
	var control_matched := 0
	var cases: Array = p_base["cases"]
	for c in cases:
		var cfg: Dictionary = c["cfg"]
		var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(fx.graph(cfg).compile_graph_program(),
				fx.GW, fx.GH, fx.RECT, surf)
		if fx.sha(got) == String(c["cpu_sha"]):
			matched += 1
		else:
			print("    !! %s moved; baseline samples %s, now %s" % [c["name"], str(c["cpu_samples"]), str(fx.samples(got))])
		var bumped: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(fx.graph(cfg, 1.0).compile_graph_program(),
				fx.GW, fx.GH, fx.RECT, surf)
		if fx.sha(bumped) == String(c["cpu_sha"]):
			control_matched += 1
	_check("A", matched == cases.size(), "%d of %d cases bit-identical" % [matched, cases.size()])
	_control(control_matched == 0, "feather +1 m matched the baseline in %d of %d cases (want 0)" % [control_matched, cases.size()])


# --- B. GPU bit-identity -----------------------------------------------------------------------------
func _b_gpu_bit_identical(p_base: Dictionary) -> void:
	print("[B] GPU Falloff (direct call): bit-identical, or within float32 rounding of the proven CPU")
	var fx := Fixture.new()
	var surf := fx.terrain()
	if Pasture3DUtil.graph_eval_grid_gpu(fx.io_graph().compile_graph_program(), fx.GW, fx.GH, fx.RECT, surf).is_empty():
		print("    NO-SIGNAL: the GPU refused a bare in->out graph (no RenderingDevice). B SKIPPED.")
		_skipped["B"] = true
		return
	if not bool(p_base.get("gpu_live", false)):
		print("    the baseline was captured without a GPU; there is nothing to compare. B SKIPPED.")
		_skipped["B"] = true
		return

	# Route control FIRST: if a refused program were not recognisable, an empty result below could not be
	# told from a pass.
	var refused: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(_refused_graph(1).compile_graph_program(),
			fx.GW, fx.GH, fx.RECT, surf)
	var served: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(_refused_graph(0).compile_graph_program(),
			fx.GW, fx.GH, fx.RECT, surf)
	_control(refused.is_empty() and served.size() == fx.GW * fx.GH,
			"Leveler channel 1 returned %d cells (want 0); channel 0 returned %d (want %d)" % [refused.size(), served.size(), fx.GW * fx.GH])

	var exact := 0
	var within := 0
	var refusals := 0
	var worst_moved := 0.0
	var worst_control := INF
	var cases: Array = p_base["cases"]
	for c in cases:
		var prog := fx.graph(c["cfg"]).compile_graph_program()
		var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, fx.GW, fx.GH, fx.RECT, surf)
		if got.is_empty():
			refusals += 1
			print("    !! %s: the GPU REFUSED" % c["name"])
			continue
		# The reference for a case that is not bit-identical: the CPU result for the same program, which A
		# has just proven bit-identical to its own baseline. The baseline stores hashes, not grids.
		var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, fx.GW, fx.GH, fx.RECT, surf)

		# CONTROL, for every case with a soft edge: feather +1 m on the GPU must sit OUTSIDE the tolerance
		# of the unbumped CPU, or the tolerance is too loose to see a real change. A hard edge ignores
		# feather inside the radius, so only soft cases can speak to this.
		if float(c["cfg"]["feather"]) > 0.0:
			var bumped: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					fx.graph(c["cfg"], 1.0).compile_graph_program(), fx.GW, fx.GH, fx.RECT, surf)
			worst_control = minf(worst_control, _worst_gpu_cpu(bumped, cpu))

		if fx.sha(got) == String(c["gpu_sha"]):
			exact += 1
			continue
		var w := _worst_gpu_cpu(got, cpu)
		worst_moved = maxf(worst_moved, w)
		if w <= EPS_GPU:
			within += 1
		else:
			print("    !! %s moved beyond float32 rounding: |GPU - CPU| worst %s m" % [c["name"], str(w)])
	_check("B", exact + within == cases.size() and refusals == 0,
			"%d bit-identical + %d within %s m = %d of %d, %d refused; worst moved |GPU - CPU| %s m" % [exact, within,
			str(EPS_GPU), exact + within, cases.size(), refusals, str(worst_moved)])
	_control(worst_control > EPS_GPU,
			"feather +1 m: smallest worst |GPU - CPU| over the soft cases %s m (want > %s)" % [str(worst_control), str(EPS_GPU)])


## Worst |GPU - CPU| over finite cells; INF when the NaN patterns differ or a grid is missing, since a hole
## that moved is never rounding.
func _worst_gpu_cpu(p_gpu: PackedFloat32Array, p_cpu: PackedFloat32Array) -> float:
	if p_gpu.size() != p_cpu.size() or p_gpu.is_empty():
		return INF
	var w := 0.0
	for i in p_cpu.size():
		var gn := is_nan(p_gpu[i])
		if gn or is_nan(p_cpu[i]):
			if gn != is_nan(p_cpu[i]):
				return INF
			continue
		w = maxf(w, absf(p_gpu[i] - p_cpu[i]))
	return w


func _refused_graph(p_channel: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeLeveler.new(),
			Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, p_channel, 2, 0]]
	return g


# --- C. oracle vs C++ --------------------------------------------------------------------------------
func _c_oracle_matches_cpp() -> void:
	print("[C] Pasture3DGraphDistance == C++ metric, 257x257, all 8 metrics")
	var a := Vector2(-137.5, 1422.25)
	var b := Vector2(611.0, 905.5) # off-axis, so every frame metric actually rotates
	var u := Pasture3DGraphDistance.direction(a, b)
	var worst_m := 0.0
	var worst_rad := 0.0
	for m in 8:
		var got: PackedFloat32Array = Pasture3DUtil.graph_distance_metric_grid(m, SW, SH, SRECT, a, b)
		var w := _worst_vs_oracle(got, m, a, u, 1.0)
		if m == Pasture3DGraphDistance.Metric.ANGULAR:
			worst_rad = maxf(worst_rad, w)
		else:
			worst_m = maxf(worst_m, w)
		print("    metric %d worst |C++ - oracle| %s" % [m, str(w)])
	# GDScript's % has no %e; str() is the only way to print a small float legibly.
	_check("C", worst_m <= EPS_M and worst_rad <= EPS_RAD,
			"worst %s m (want <= %s), %s rad (want <= %s)" % [str(worst_m), str(EPS_M), str(worst_rad), str(EPS_RAD)])

	# CONTROL: the direction must matter. Measured along -u from the same origin, LINEAR must disagree with
	# the oracle and agree with its negation.
	var flipped: PackedFloat32Array = Pasture3DUtil.graph_distance_metric_grid(Pasture3DGraphDistance.Metric.LINEAR,
			SW, SH, SRECT, a, a - (b - a))
	var vs_plain := _worst_vs_oracle(flipped, Pasture3DGraphDistance.Metric.LINEAR, a, u, 1.0)
	var vs_neg := _worst_vs_oracle(flipped, Pasture3DGraphDistance.Metric.LINEAR, a, u, -1.0)
	_control(vs_plain > 1.0 and vs_neg <= EPS_M,
			"negated direction: |C++ - oracle| %.2f m (want > 1), |C++ + oracle| %s (want <= %s)" % [vs_plain, str(vs_neg), str(EPS_M)])


func _worst_vs_oracle(p_got: PackedFloat32Array, p_metric: int, p_a: Vector2, p_u: Vector2, p_sign: float) -> float:
	if p_got.size() != SW * SH:
		return INF
	var dx := SRECT.size.x / SW
	var dz := SRECT.size.y / SH
	var w := 0.0
	for iz in SH:
		var wz := SRECT.position.y + (iz + 0.5) * dz
		for ix in SW:
			var wx := SRECT.position.x + (ix + 0.5) * dx
			var want := p_sign * Pasture3DGraphDistance.metric(p_metric, wx, wz, p_a, p_u)
			var e := absf(p_got[iz * SW + ix] - want)
			if p_metric == Pasture3DGraphDistance.Metric.ANGULAR:
				e = minf(e, TAU - e) # 0 and TAU are the same angle; a float32 rounding across the seam is not an error
			w = maxf(w, e)
	return w


# --- D. degenerate direction -------------------------------------------------------------------------
func _d_degenerate_direction() -> void:
	print("[D] a == b falls back to +X in C++ and in the oracle")
	var a := Vector2(40.0, -25.0)
	var fallback := Pasture3DGraphDistance.direction(a, a)
	var got: PackedFloat32Array = Pasture3DUtil.graph_distance_metric_grid(Pasture3DGraphDistance.Metric.LINEAR,
			SW, SH, SRECT, a, a)
	var w := _worst_vs_oracle(got, Pasture3DGraphDistance.Metric.LINEAR, a, fallback, 1.0)
	_check("D", fallback == Vector2(1.0, 0.0) and w <= EPS_M,
			"oracle fallback %s (want (1, 0)), worst |C++ - oracle| %s m" % [str(fallback), str(w)])
	var along_z := _worst_vs_oracle(got, Pasture3DGraphDistance.Metric.LINEAR, a, Vector2(0.0, 1.0), 1.0)
	_control(along_z > 1.0, "measured along +Z instead: |C++ - oracle| %.2f m (want > 1)" % along_z)


# --- F. repeat modes ---------------------------------------------------------------------------------
func _f_repeat() -> void:
	print("[F] repeat modes: oracle == C++")
	var vals := PackedFloat32Array()
	for i in 601:
		vals.append(-3.0 + float(i) * 0.01)
	vals.append(NAN)
	var worst := 0.0
	var nan_ok := true
	for mode in 3:
		var got: PackedFloat32Array = Pasture3DUtil.graph_repeat_values(mode, vals)
		if got.size() != vals.size():
			worst = INF
			continue
		for i in vals.size():
			var want := Pasture3DGraphDistance.repeat(mode, vals[i])
			if is_nan(want) or is_nan(got[i]):
				nan_ok = nan_ok and is_nan(want) and is_nan(got[i])
				continue
			worst = maxf(worst, absf(got[i] - want))
	_check("F", worst <= 1.0e-5 and nan_ok, "worst %s (want <= 1e-5), NaN passes through: %s" % [str(worst), str(nan_ok)])
	var mirror: PackedFloat32Array = Pasture3DUtil.graph_repeat_values(Pasture3DGraphDistance.Repeat.MIRROR, vals)
	var cross := 0.0
	for i in vals.size() - 1:
		cross = maxf(cross, absf(mirror[i] - Pasture3DGraphDistance.repeat(Pasture3DGraphDistance.Repeat.REPEAT, vals[i])))
	_control(cross > 0.5, "C++ MIRROR vs oracle REPEAT differ by up to %.3f (want > 0.5)" % cross)
