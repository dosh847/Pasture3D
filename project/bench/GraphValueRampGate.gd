# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphValueRampGate — the Value Ramp node (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §6.5).
#
#   A  Native vs Gradient.sample ([Dev/GD] eval_cell), 3 modes x 3 colour spaces x 3 repeats x 6 channels over
#      4097 inputs, within 1e-5 (CUBIC or OKLAB 1e-4). Control: a 256-entry LUT reading of the same CONSTANT
#      gradient must miss a band edge.
#   B  CONSTANT edge exact: a stop at 0.5; t = 0.5 - 1e-6 and 0.5 + 1e-6 land in different bands.
#   C  Equal-offset tie, both authoring orders: native, GPU and oracle all return the later sorted stop.
#      Control: the earlier-stop rule must disagree.
#   D  Colour space matters: red -> blue at t = 0.5, channel RED, SRGB and OKLAB differ by > 0.05 and each matches
#      the oracle. Control: a lowering that drops the colour space must fail the OKLAB half.
#   E  Native vs GPU through graph_eval_grid_gpu DIRECTLY, the A sweep, within 1e-4. Control: input_max + 1 on
#      the GPU.
#   F  HEIGHT drives the terrain: a baked brush matches a Const of lerp(height_min, height_max, v), read from
#      terrain data. Control: MASK mode on the same fixture differs.
#   G  Input -> Value Ramp -> Output folds (not materialised). Control: a needs_grid() = true copy materialises.
#   H  An in-place gradient.set_color bumps the revision and changes the native result.
#   I  amount = 0 in MASK returns the normalised input. Control: amount = 0.01 differs.
#   J  Every criterion that was not skipped completed.
#
# WINDOWED for C's GPU half and E. Headless those are SKIPPED and the verdict is PARTIAL, never PASS.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphValueRampGate.tscn
extends Node

const N := 4097
const X_LO := -30.0
const X_HI := 90.0
const IN_MIN := -20.0
const IN_MAX := 80.0
const EPS_A := 1.0e-5
const EPS_A_LOOSE := 1.0e-4
const EPS_E := 1.0e-4
const CRITERIA := ["A", "B", "C", "D", "E", "F", "G", "H", "I"]
const DEMO_DATA := "res://demo/data"
const SITE := Vector3(200.0, 0.0, 160.0)
const HALF := 50.0

var _fail := 0
var _seen := {}
var _skipped := {}
var _gpu_ok := false


func _ready() -> void:
	print("=== GraphValueRampGate: Value Ramp node (spec §6.5) ===")
	if not Pasture3DUtil.graph_op_ids().has(&"value_ramp"):
		print("!! value_ramp is not in graph_op_ids() — rebuild the GDExtension")
		get_tree().quit(1)
		return
	_gpu_ok = not _gpu(_graph(_ramp({})), _inputs()).is_empty()
	_run("A", _a_oracle)
	_run("B", _b_edge)
	_run("C", _c_tie)
	_run("D", _d_space)
	if _gpu_ok:
		_run("E", _e_gpu)
	else:
		print("    NO-SIGNAL: the GPU refused (no RenderingDevice). E SKIPPED.")
		_skipped["E"] = true
	_run("F", _f_terrain)
	_run("G", _g_fold)
	_run("H", _h_invalidation)
	_run("I", _i_amount)

	var required := 0
	var completed := 0
	for name in CRITERIA:
		if not _skipped.has(name):
			required += 1
		if _seen.has(name):
			completed += 1
		elif not _skipped.has(name):
			print("!! criterion %s never reported" % name)
	_check("J", completed == required, "%d of %d non-skipped criteria completed" % [completed, required])
	var verdict := "FAIL" if _fail > 0 else ("PARTIAL" if not _skipped.is_empty() else "PASS")
	print("=== VALUE RAMP %s (%d failures, %d skipped) ===" % [verdict, _fail, _skipped.size()])
	get_tree().quit(0 if _fail == 0 else 1)


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


# --- fixtures ----------------------------------------------------------------------------------------
## Five stops, authored out of offset order, with alpha varying, and tails before 0.1 and after 0.95.
func _gradient(p_mode := 0, p_space := 0) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.8, 0.1, 0.45, 0.62, 0.95])
	g.colors = PackedColorArray([Color(0.9, 0.2, 0.1, 1.0), Color(0.05, 0.4, 0.9, 0.3), Color(1.0, 1.0, 0.2, 0.8),
			Color(0.3, 0.0, 0.6, 0.5), Color(0.1, 0.9, 0.4, 0.0)])
	g.interpolation_mode = p_mode
	g.interpolation_color_space = p_space
	return g


func _ramp(p_cfg: Dictionary, p_dev := false) -> Pasture3DGraphNodeValueRamp:
	var n: Pasture3DGraphNodeValueRamp = Pasture3DGraphNodeDevValueRamp.new() if p_dev else Pasture3DGraphNodeValueRamp.new()
	n.gradient = _gradient()
	n.input_min = IN_MIN
	n.input_max = IN_MAX
	# HEIGHT over [0, 1] so the parity sweep sees a CUBIC overshoot instead of MASK's clamp hiding it.
	n.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.HEIGHT
	n.height_min = 0.0
	n.height_max = 1.0
	for k in p_cfg:
		n.set(k, p_cfg[k])
	return n


func _copy(p_n: Pasture3DGraphNodeValueRamp, p_dev: bool) -> Pasture3DGraphNodeValueRamp:
	var c := _ramp({}, p_dev)
	for k in ["gradient", "channel", "input_min", "input_max", "repeat", "output_mode", "height_min", "height_max", "amount"]:
		c.set(k, p_n.get(k))
	return c


## The input heights: N values from X_LO to X_HI, so t runs -0.1 .. 1.1 through the window.
func _inputs() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N)
	for i in N:
		h[i] = lerpf(X_LO, X_HI, float(i) / float(N - 1))
	return h


## Input -> node -> Output.
func _graph(p_n: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_n, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return g


func _native(p_g: Pasture3DTerrainGraph, p_in: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), p_in.size(), 1, Rect2(0.0, 0.0, p_in.size(), 1.0), p_in)


func _gpu(p_g: Pasture3DTerrainGraph, p_in: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_g.compile_graph_program(), p_in.size(), 1, Rect2(0.0, 0.0, p_in.size(), 1.0), p_in)


func _oracle(p_n: Pasture3DGraphNodeValueRamp, p_in: PackedFloat32Array) -> PackedFloat32Array:
	var o := _copy(p_n, true)
	var out := PackedFloat32Array()
	out.resize(p_in.size())
	var cell := PackedFloat32Array([0.0, NAN, NAN, NAN, NAN, NAN])
	for i in p_in.size():
		cell[0] = p_in[i]
		out[i] = o.eval_cell(i + 0.5, 0.5, cell)
	return out


## Worst |a - b|; INF on a size or NaN-pattern mismatch.
func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		if is_nan(p_a[i]) or is_nan(p_b[i]):
			if is_nan(p_a[i]) != is_nan(p_b[i]):
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _sweep() -> Array:
	var cases := []
	for mode in 3:
		for space in 3:
			for rp in 3:
				for ch in 6:
					cases.append({"mode": mode, "space": space, "repeat": rp, "channel": ch})
	return cases


func _case_node(p_c: Dictionary) -> Pasture3DGraphNodeValueRamp:
	var n := _ramp({"repeat": p_c["repeat"], "channel": p_c["channel"]})
	n.gradient = _gradient(p_c["mode"], p_c["space"])
	return n


# --- A. native vs Gradient.sample --------------------------------------------------------------------
func _a_oracle() -> void:
	print("[A] native == Gradient.sample, 162 cases x %d inputs" % N)
	var h := _inputs()
	var cases := _sweep()
	var passed := 0
	var worst := 0.0
	var worst_loose := 0.0
	for c in cases:
		var n := _case_node(c)
		var w := _worst(_native(_graph(n), h), _oracle(n, h))
		var loose: bool = int(c["mode"]) == Gradient.GRADIENT_INTERPOLATE_CUBIC or int(c["space"]) == Gradient.GRADIENT_COLOR_SPACE_OKLAB
		if loose:
			worst_loose = maxf(worst_loose, w)
		else:
			worst = maxf(worst, w)
		if w <= (EPS_A_LOOSE if loose else EPS_A):
			passed += 1
		else:
			print("    !! %s: worst |native - oracle| %s" % [str(c), str(w)])
	_check("A", passed == cases.size(), "%d of %d cases; worst %s (tight), %s (CUBIC/OKLAB)"
			% [passed, cases.size(), str(worst), str(worst_loose)])
	# The control: what a 256-entry table would give for the CONSTANT gradient, nearest entry per t.
	var g := _gradient(Gradient.GRADIENT_INTERPOLATE_CONSTANT)
	var ctl := 0.0
	for i in N:
		var t := clampf((h[i] - IN_MIN) / (IN_MAX - IN_MIN), 0.0, 1.0)
		var exact := Pasture3DGraphNodeValueRamp.reduce(g.sample(t), 0)
		var table := Pasture3DGraphNodeValueRamp.reduce(g.sample(roundf(t * 255.0) / 255.0), 0)
		ctl = maxf(ctl, absf(exact - table))
	_control(ctl > 1.0e-2, "256-entry LUT vs exact at CONSTANT band edges: worst %s (want > 1e-2)" % str(ctl))


# --- B. constant edge --------------------------------------------------------------------------------
func _two_stop(p_mode: int, p_a: Color, p_off: float, p_b: Color) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, p_off])
	g.colors = PackedColorArray([p_a, p_b])
	g.interpolation_mode = p_mode
	return g


func _b_edge() -> void:
	print("[B] CONSTANT: t = 0.5 -/+ 1e-6 fall in different bands")
	var n := _ramp({"input_min": 0.0, "input_max": 1.0, "repeat": 0})
	n.gradient = _two_stop(Gradient.GRADIENT_INTERPOLATE_CONSTANT, Color.BLACK, 0.5, Color.WHITE)
	var h := PackedFloat32Array([0.5 - 1.0e-6, 0.5 + 1.0e-6])
	var nat := _native(_graph(n), h)
	var ora := _oracle(n, h)
	var gpu := _gpu(_graph(n), h) if _gpu_ok else PackedFloat32Array()
	# A round-number window puts t exactly on a stop: -20 .. 80 at x = 60 is t = 0.8, the 0.8 stop.
	var r := _ramp({"channel": Pasture3DGraphNodeValueRamp.Channel.RED})
	r.gradient = _gradient(Gradient.GRADIENT_INTERPOLATE_CONSTANT)
	var hr := PackedFloat32Array([60.0])
	var rn := _native(_graph(r), hr)
	var ro := _oracle(r, hr)
	var rg := _gpu(_graph(r), hr) if _gpu_ok else PackedFloat32Array()
	var edge_ok := nat.size() == 2 and nat[0] == 0.0 and nat[1] == 1.0 and _worst(nat, ora) == 0.0
	var round_ok := rn.size() == 1 and _worst(rn, ro) <= EPS_A and absf(rn[0] - 0.9) <= EPS_A
	if _gpu_ok:
		edge_ok = edge_ok and _worst(gpu, nat) == 0.0
		round_ok = round_ok and _worst(rg, rn) <= EPS_A
	else:
		print("    NO-SIGNAL: B's GPU half SKIPPED")
	_check("B", edge_ok and round_ok, "0.5 -/+ 1e-6: native %s, oracle %s, gpu %s (want [0, 1]); x = 60 on the 0.8 stop: native %s, oracle %s, gpu %s (want 0.9)"
			% [str(nat), str(ora), str(gpu), str(rn), str(ro), str(rg)])


# --- C. equal-offset tie -----------------------------------------------------------------------------
func _c_tie() -> void:
	print("[C] equal-offset tie, both authoring orders: the later sorted stop wins everywhere")
	var red := Color(1.0, 0.0, 0.0)
	var blue := Color(0.0, 0.0, 1.0)
	var h := PackedFloat32Array([0.5, 0.6, 0.75])
	var ok := true
	var ctl_differs := false
	var lines := []
	for order in [[red, blue], [blue, red]]:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.5, 0.5, 1.0])
		g.colors = PackedColorArray([Color.BLACK, order[0], order[1], Color.WHITE])
		g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
		var n := _ramp({"input_min": 0.0, "input_max": 1.0, "channel": Pasture3DGraphNodeValueRamp.Channel.RED})
		n.gradient = g
		var stops := n.stop_table() # the engine's sorted order
		var later := stops[2 * 5 + 1]
		var earlier := stops[1 * 5 + 1]
		var nat := _native(_graph(n), h)
		var ora := _oracle(n, h)
		var gpu := _gpu(_graph(n), h) if _gpu_ok else PackedFloat32Array()
		# Past the tie (0.6, 0.75) CONSTANT holds the later stop; at exactly 0.5 the engine's exact-hit return
		# decides, and the kernels must reproduce whatever it is.
		var later_ok := nat.size() == 3 and nat[1] == later and nat[2] == later
		ok = ok and later_ok and _worst(nat, ora) == 0.0 and (not _gpu_ok or _worst(gpu, nat) == 0.0)
		ctl_differs = ctl_differs or (nat.size() == 3 and nat[1] != earlier)
		lines.append("authored %s: sorted red of stops 1/2 = %s/%s; native %s oracle %s gpu %s"
				% ["red,blue" if order[0] == red else "blue,red", str(earlier), str(later), str(nat), str(ora), str(gpu)])
	if not _gpu_ok:
		_skipped["C-gpu"] = true
		print("    NO-SIGNAL: C's GPU half SKIPPED")
	_check("C", ok, " | ".join(lines))
	_control(ctl_differs, "the earlier-stop rule disagrees with native past the tie")


# --- D. colour space ---------------------------------------------------------------------------------
func _d_space() -> void:
	print("[D] red -> blue at t = 0.5, channel RED: SRGB and OKLAB differ, each matches the oracle")
	var h := PackedFloat32Array([0.5])
	var vals := {}
	var ora_ok := true
	for space in [Gradient.GRADIENT_COLOR_SPACE_SRGB, Gradient.GRADIENT_COLOR_SPACE_OKLAB]:
		var n := _ramp({"input_min": 0.0, "input_max": 1.0, "channel": Pasture3DGraphNodeValueRamp.Channel.RED})
		n.gradient = _two_stop(Gradient.GRADIENT_INTERPOLATE_LINEAR, Color(1, 0, 0), 1.0, Color(0, 0, 1))
		n.gradient.interpolation_color_space = space
		var nat := _native(_graph(n), h)
		var ora := _oracle(n, h)
		vals[space] = nat[0] if nat.size() == 1 else NAN
		ora_ok = ora_ok and _worst(nat, ora) <= EPS_A_LOOSE
	var diff := absf(float(vals[Gradient.GRADIENT_COLOR_SPACE_SRGB]) - float(vals[Gradient.GRADIENT_COLOR_SPACE_OKLAB]))
	_check("D", ora_ok and diff > 0.05, "SRGB %s, OKLAB %s, |diff| %s; both match the oracle: %s"
			% [str(vals[0]), str(vals[2]), str(diff), str(ora_ok)])
	# The control: a lowering that forgets params[2].
	var s := GDScript.new()
	s.source_code = "extends Pasture3DGraphNodeValueRamp\nfunc native_lower() -> Dictionary:\n\tvar d := super()\n\tvar p: PackedFloat32Array = d[\"params\"]\n\tp[2] = 0.0\n\td[\"params\"] = p\n\treturn d\n"
	s.reload()
	var blind: Pasture3DGraphNodeValueRamp = s.new()
	var cfg := _ramp({"input_min": 0.0, "input_max": 1.0, "channel": Pasture3DGraphNodeValueRamp.Channel.RED})
	cfg.gradient = _two_stop(Gradient.GRADIENT_INTERPOLATE_LINEAR, Color(1, 0, 0), 1.0, Color(0, 0, 1))
	cfg.gradient.interpolation_color_space = Gradient.GRADIENT_COLOR_SPACE_OKLAB
	for k in ["gradient", "channel", "input_min", "input_max", "repeat", "output_mode", "height_min", "height_max", "amount"]:
		blind.set(k, cfg.get(k))
	var miss := _worst(_native(_graph(blind), h), _oracle(cfg, h))
	_control(miss > 1.0e-2, "colour-space-blind lowering vs the OKLAB oracle: %s (want > 1e-2)" % str(miss))


# --- E. native vs GPU --------------------------------------------------------------------------------
func _e_gpu() -> void:
	print("[E] native == GPU (direct) within %s, 162 cases" % str(EPS_E))
	var h := _inputs()
	var cases := _sweep()
	var passed := 0
	var served := 0
	var worst := 0.0
	var ctl := INF
	for c in cases:
		var n := _case_node(c)
		var g := _graph(n)
		var nat := _native(g, h)
		var gpu := _gpu(g, h)
		if gpu.size() == N:
			served += 1
		var w := _worst(gpu, nat)
		worst = maxf(worst, w)
		if w <= EPS_E:
			passed += 1
		else:
			var bad := []
			for i in N:
				if gpu.size() == N and absf(gpu[i] - nat[i]) > EPS_E and bad.size() < 4:
					bad.append("i %d x %s gpu %s native %s" % [i, str(h[i]), str(gpu[i]), str(nat[i])])
			print("    !! %s: worst |GPU - native| %s; %s" % [str(c), str(w), str(bad)])
		if int(c["channel"]) == 0:
			var moved := _copy(n, false)
			moved.input_max = n.input_max + 1.0
			ctl = minf(ctl, _worst(_gpu(_graph(moved), h), nat))
	_check("E", passed == cases.size() and served == cases.size(),
			"%d of %d cases, %d served by the GPU; worst %s" % [passed, cases.size(), served, str(worst)])
	_control(ctl > EPS_E, "input_max + 1 on the GPU: smallest worst %s (want > %s)" % [str(ctl), str(EPS_E)])


# --- F. terrain --------------------------------------------------------------------------------------
## Input + (Const -> [p_n]) -> Output. With p_n null the Const feeds the Blend directly.
func _brush_graph(p_n: Pasture3DGraphNode, p_const: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var k := Pasture3DGraphNodeConst.new()
	k.value = p_const
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), blend, Pasture3DGraphNodeOutput.new(), k]
	var conns := [[0, 0, 1, 0], [1, 0, 2, 0]]
	if p_n != null:
		nodes.append(p_n)
		conns.append_array([[3, 0, 4, 0], [4, 0, 1, 1]])
	else:
		conns.append([3, 0, 1, 1])
	g.nodes = nodes
	g.connections = conns
	return g


func _f_terrain() -> void:
	print("[F] a HEIGHT Value Ramp on a brush writes lerp(height_min, height_max, v) metres")
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var vs: float = terrain.vertex_spacing
	if not is_finite(terrain.data.get_height(SITE)):
		root.queue_free()
		_check("F", false, "no terrain at the fixture site")
		return
	var mound := Pasture3DMound.new()
	mound.name = "ValueRampHost"
	root.add_child(mound)
	mound.terrain = terrain
	mound.height = 20.0
	mound.global_position = SITE
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-HALF, 0, -HALF), Vector3(HALF, 0, -HALF), Vector3(HALF, 0, HALF), Vector3(-HALF, 0, HALF)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	mound.add_child(path)
	var pts: Array[Vector3] = []
	var reach := HALF * 0.5
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			pts.append(SITE + Vector3(snappedf(x, vs), 0.0, snappedf(z, vs)))
			z += vs * 5.0
		x += vs * 5.0

	# Ramp black -> white LINEAR, AVERAGE: v = 0.3 at input 0.3. HEIGHT 0 .. 8 gives 2.4 m; MASK gives 0.3.
	var ramp := Pasture3DGraphNodeValueRamp.new()
	ramp.gradient = _two_stop(Gradient.GRADIENT_INTERPOLATE_LINEAR, Color.BLACK, 1.0, Color.WHITE)
	ramp.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.HEIGHT
	ramp.height_min = 0.0
	ramp.height_max = 8.0
	var bare := _bake(mound, null, pts)
	var ramped := _bake(mound, _brush_graph(ramp, 0.3), pts)
	var reference := _bake(mound, _brush_graph(null, 2.4), pts)
	var masked := _copy(ramp, false)
	masked.output_mode = Pasture3DGraphNodeValueRamp.OutputMode.MASK
	var mask_baked := _bake(mound, _brush_graph(masked, 0.3), pts)
	root.queue_free()
	var w_ref := 0.0
	var moved := 0.0
	var ctl := 0.0
	for i in pts.size():
		if not (is_finite(bare[i]) and is_finite(ramped[i]) and is_finite(reference[i]) and is_finite(mask_baked[i])):
			_check("F", false, "a bake read no terrain at %s" % str(pts[i]))
			return
		w_ref = maxf(w_ref, absf(ramped[i] - reference[i]))
		moved = maxf(moved, absf(ramped[i] - bare[i]))
		ctl = maxf(ctl, absf(ramped[i] - mask_baked[i]))
	_check("F", w_ref <= 1.0e-2 and moved > 1.0,
			"worst |ramp bake - Const 2.4 bake| %s m over %d probes; the ramp moved the terrain up to %s m" % [str(w_ref), pts.size(), str(moved)])
	_control(ctl > 1.0, "MASK mode on the same fixture differs by up to %s m (want > 1)" % str(ctl))


func _bake(p_mound: Pasture3DMound, p_g: Pasture3DTerrainGraph, p_pts: Array[Vector3]) -> Array[float]:
	var mods: Array[Pasture3DNode] = []
	if p_g != null:
		var mod := Pasture3DNodeGraph.new()
		mod.graph = p_g
		mod.evaluation = Pasture3DNode.Evaluation.LIVE
		mods.append(mod)
	p_mound.modifiers = mods
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_pts:
		out.append(p_mound.terrain.data.get_height(p))
	return out


# --- G. fold -----------------------------------------------------------------------------------------
func _g_fold() -> void:
	print("[G] Input -> Value Ramp -> Output folds into one cell program")
	var plan: Dictionary = _graph(_ramp({}))._fold_plan()
	_check("G", not bool(plan["materialize"][1]), "value ramp materialize = %s (want false)" % str(plan["materialize"][1]))
	var s := GDScript.new()
	s.source_code = "extends Pasture3DGraphNodeValueRamp\nfunc needs_grid() -> bool:\n\treturn true\n"
	s.reload()
	var forced: Pasture3DGraphNode = s.new()
	var plan2: Dictionary = _graph(forced)._fold_plan()
	_control(bool(plan2["materialize"][1]), "needs_grid() = true copy materialize = %s" % str(plan2["materialize"][1]))


# --- H. in-place edit --------------------------------------------------------------------------------
func _h_invalidation() -> void:
	print("[H] an in-place gradient.set_color invalidates")
	var n := _ramp({})
	var g := _graph(n)
	var h := _inputs()
	var k0 := g.content_key()
	var before := _native(g, h)
	n.gradient.set_color(2, Color(0.0, 0.0, 0.0, 1.0))
	var k1 := g.content_key()
	var after := _native(g, h)
	var w := _worst(before, after)
	_check("H", k1 != k0 and w > 1.0e-2, "revision %d -> %d; the second evaluation moved by %s" % [k0, k1, str(w)])


# --- I. amount -------------------------------------------------------------------------------------
func _i_amount() -> void:
	print("[I] amount = 0 in MASK returns the normalised input")
	var h := _inputs()
	var n := _ramp({"output_mode": Pasture3DGraphNodeValueRamp.OutputMode.MASK, "amount": 0.0})
	n.gradient = _gradient(Gradient.GRADIENT_INTERPOLATE_CONSTANT)
	var want := PackedFloat32Array()
	want.resize(N)
	for i in N:
		want[i] = clampf((h[i] - IN_MIN) / (IN_MAX - IN_MIN), 0.0, 1.0)
	var w := _worst(_native(_graph(n), h), want)
	_check("I", w <= EPS_A, "worst |native - normalised input| %s" % str(w))
	var nudged := _copy(n, false)
	nudged.amount = 0.01
	var ctl := _worst(_native(_graph(nudged), h), want)
	_control(ctl > 1.0e-4, "amount = 0.01 differs by %s (want > 1e-4)" % str(ctl))
