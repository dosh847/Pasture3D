# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphStandardMaskGate — every FILTER and SOLVER that takes a height and returns a height has ONE mask
# port, last, and it means one thing: out = in + (node_out - in) * clamp(mask, 0, 1).
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §9 (P5, format 3).
#
#   [A] mask 0 returns the input and mask 1 the unmasked result, to the bit, on the native and the GDScript
#       route; a non-finite mask reads as 1. Control: mask 0.5 is neither.
#   [B] a hard two-level mask: cells at 0 carry the input's bits and cells at 1 the unmasked result's.
#       Control: the inverted mask swaps the two sets. The GPU route is checked when a rendering device
#       exists and reported as NOT RUN when it does not; it is never counted as a pass. Headless has no
#       device: run this scene WITHOUT --headless to get the GPU rows.
#   [C] an unwired mask compiles to the same program as before; a wired one adds exactly one Blend slot.
#       Control: a node that applies its own mask (Smooth Fill) adds none.
#   [D] a FROZEN solver whose mask is the graph's does not go stale when only the mask moves, and its
#       output still follows the mask. Controls: it does go stale when its input moves, and a solver that
#       applies its own mask (Particle) goes stale when the mask moves.
#   [E] the fourteen nodes that had a mask before the phase give what they gave then, against a recording
#       taken through GraphStandardMaskFixture before any of them was changed (96 x 128, so the thread pool
#       splits). Control: the inverted mask does not match the recording.
#   [F] every node the rule names has the port and no other node does.
#
# `_ran` counts checks that reached their assert; a GDScript error aborts the function it is in without
# failing anything, so a criterion that threw would otherwise read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphStandardMaskGate.tscn
extends Node

const Fx := preload("res://bench/GraphStandardMaskFixture.gd")

const GW := Fx.GW
const GH := Fx.GH
const RECT := Fx.RECT
## [E]: the recording was float32 on the old kernels; the mask now runs as a separate double blend.
const PARITY_TOL := 1.0e-4
## The least an inverted mask must miss the recording by for the control to count.
const INVERT_MIN := 0.02
const GPU_TOL := 1.0e-3
## [A] 6 x (2 x 5 + 1) = 66, [B] 1 + 2 x 2 x 2 = 9, [C] 6 x 2 + 1 = 13, [D] 2 x 5 = 10,
## [E] 14 x (1 + 2 x 2) = 70, [F] 4 + 6 + 6 + 6 + 5 + 2 = 29.
const EXPECTED_RAN := 197

## [A]/[B]/[C]: nodes whose mask the graph applies, one of each kind (cell, grid, pointwise, multi-octave).
const FRAMEWORK_OPS: Array[StringName] = [&"contrast", &"terrace", &"strata", &"ridge_sharpen", &"recast_canyon", &"recast_cliff"]
const OWN_OPS: Array[StringName] = [&"smooth_fill", &"hydraulic_saleve", &"displace", &"warp_downslope",
		&"hydraulic_particle", &"hydraulic_stream_log"]
## [F]: named in §9.3.1 as having no standard mask whatever their ports look like.
const EXCLUDED_OPS: Array[StringName] = [&"reroute", &"blend", &"color_blend", &"measure", &"input", &"output"]

var _fail := 0
var _ran := 0
var _gpu_ran := 0
var _surf: PackedFloat32Array


## A FILTER that takes a height and returns a MASK: the rule does not name it.
class MaskOutNode extends Pasture3DGraphNode:
	func op() -> StringName:
		return &"gate_mask_out"
	func role() -> Role:
		return Role.FILTER
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require()]
	func _outputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"out", PortType.MASK)]


## The same node returning a height: the rule names it. The control for MaskOutNode.
class HeightOutNode extends Pasture3DGraphNode:
	func op() -> StringName:
		return &"gate_height_out"
	func role() -> Role:
		return Role.FILTER
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require()]
	func _outputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"out", PortType.HEIGHT)]


func _ready() -> void:
	print("\n=== GraphStandardMaskGate: one mask port, one meaning (ports spec P5, format 3) ===\n")
	_surf = Fx.surface()
	_a_zero_and_one()
	_b_hard_mask()
	_c_op_count()
	_d_frozen()
	_e_recording()
	_f_who_has_it()
	print("\n    checks that reached their assert: %d (want %d); GPU checks run: %d" % [_ran, EXPECTED_RAN, _gpu_ran])
	if _ran != EXPECTED_RAN:
		_fail += 1; print("    !! a criterion stopped early — a script error aborted it, or the count is stale")
	if _gpu_ran == 0:
		print("    NOT RUN: the GPU route ([B]). No rendering device in this session.")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH STANDARD MASK PASS" if _fail == 0 else "GRAPH STANDARD MASK FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	if not p_ok:
		_fail += 1; print("    !! %s" % p_what)


# ---- fixtures --------------------------------------------------------------------------------------

## Input -> `p_op` -> Output. `p_mask` is a node wired into the node's `mask` port, or null for no wire.
## Returns `{"graph", "node": the op's node, "index": its index}`.
func _graph(p_op: StringName, p_mask: Pasture3DGraphNode = null) -> Dictionary:
	var g := Pasture3DTerrainGraph.create_empty()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var node := Pasture3DGraphNodeRegistry.create(p_op)
	Fx._configure(p_op, node)
	if p_op == &"erosion_thermal":
		node.set("talus_angle", 2.0)
	var i_node := g.add_node(node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_node, 0)
	g.connect_ports(i_node, 0, i_out, 0)
	g.set_output(i_out)
	if p_op == &"displace":
		var cdx := Pasture3DGraphNodeRegistry.create(&"const")
		cdx.set("value", 25.0)
		g.connect_ports(g.add_node(cdx), 0, i_node, node.input_index_of(&"dx"))
	if p_mask != null:
		var mp := node.input_index_of(&"mask")
		var i_mask := g.add_node(p_mask)
		if mp < 0 or not g.connect_ports(i_mask, 0, i_node, mp):
			return {}
	return {"graph": g, "node": node, "index": i_node}


func _const(p_value: float) -> Pasture3DGraphNode:
	var c := Pasture3DGraphNodeRegistry.create(&"const")
	c.set("value", p_value)
	return c


## A two-level field: 0 where the noise is negative, 1 where it is positive (amplitude 1e7, clamped by the
## rule itself). `p_invert` flips it.
func _hard(p_invert: bool) -> Pasture3DGraphNode:
	var nz := FastNoiseLite.new()
	nz.seed = 5
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.003
	nz.fractal_type = FastNoiseLite.FRACTAL_NONE
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	n.set("noise", nz)
	n.set("amplitude", -1.0e7 if p_invert else 1.0e7)
	return n


func _eval(p_g: Pasture3DTerrainGraph, p_gdscript: bool, p_surf: PackedFloat32Array = PackedFloat32Array()) -> PackedFloat32Array:
	p_g.force_gdscript_evaluation = p_gdscript
	return p_g.evaluate(GW, GH, RECT, null, _surf if p_surf.is_empty() else p_surf)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var d := 0.0
	for i in range(p_a.size()):
		if not is_finite(p_a[i]) or not is_finite(p_b[i]):
			return INF
		d = maxf(d, absf(p_a[i] - p_b[i]))
	return d


func _route(p_gdscript: bool) -> String:
	return "GDScript" if p_gdscript else "native"


# ---- [A] -------------------------------------------------------------------------------------------

func _a_zero_and_one() -> void:
	print("[A] mask 0 is the input, mask 1 the unmasked result, a non-finite mask is 1")
	for op in FRAMEWORK_OPS:
		for gd in [false, true]:
			var plain_b := _graph(op)
			var g_plain: Pasture3DTerrainGraph = plain_b["graph"]
			var plain := _eval(g_plain, gd)
			var effect := _max_abs_diff(plain, _surf)
			var d0 := _max_abs_diff(_eval(_graph(op, _const(0.0))["graph"], gd), _surf)
			var d1 := _max_abs_diff(_eval(_graph(op, _const(1.0))["graph"], gd), plain)
			var half := _eval(_graph(op, _const(0.5))["graph"], gd)
			var dh_in := _max_abs_diff(half, _surf)
			var dh_out := _max_abs_diff(half, plain)
			var dnan := _max_abs_diff(_eval(_graph(op, _const(NAN))["graph"], gd), plain)
			print("    %-14s %-8s node moves the input %.3f m | mask 0 vs input %.9f | mask 1 vs unmasked %.9f | NaN vs unmasked %.9f | 0.5 vs input %.3f, vs unmasked %.3f"
					% [op, _route(gd), effect, d0, d1, dnan, dh_in, dh_out])
			_check(effect > 0.5, "%s does nothing to this surface, so its mask cannot be seen" % op)
			_check(d0 == 0.0, "%s (%s): mask 0 is not the input" % [op, _route(gd)])
			_check(d1 == 0.0, "%s (%s): mask 1 is not the unmasked result" % [op, _route(gd)])
			_check(dnan == 0.0, "%s (%s): a non-finite mask did not read as 1" % [op, _route(gd)])
			# CONTROL: a half mask is neither end, so the two equalities above are not a graph that ignores it.
			_check(dh_in > 0.1 and dh_out > 0.1, "%s (%s): mask 0.5 equals the input or the unmasked result" % [op, _route(gd)])
		# The route claimed above is the route taken.
		_check((_graph(op, _const(0.5))["graph"] as Pasture3DTerrainGraph).native_supported(),
				"%s with a wired mask does not lower, so its 'native' rows ran in GDScript" % op)


# ---- [B] -------------------------------------------------------------------------------------------

func _b_hard_mask() -> void:
	print("[B] a hard mask: cells at 0 keep the input's bits, cells at 1 take the unmasked result's")
	# The mask as the graph sees it, read back through a graph of its own.
	var mg := Pasture3DTerrainGraph.create_empty()
	var i_m := mg.add_node(_hard(false))
	var i_o := mg.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	mg.connect_ports(i_m, 0, i_o, 0)
	mg.set_output(i_o)
	var mask := mg.evaluate(GW, GH, RECT, null, _surf)
	var n_off := 0
	var n_on := 0
	for v in mask:
		if v <= 0.0:
			n_off += 1
		elif v >= 1.0:
			n_on += 1
	print("    mask: %d cells at or below 0, %d at or above 1, %d between" % [n_off, n_on, mask.size() - n_off - n_on])
	_check(n_off > 500 and n_on > 500, "the hard mask is not two-sided, so one half of the claim is untested")

	for op in [&"ridge_sharpen", &"strata"] as Array[StringName]:
		var g_plain: Pasture3DTerrainGraph = _graph(op)["graph"]
		for gd in [false, true]:
			var plain := _eval(g_plain, gd)
			var got := _eval(_graph(op, _hard(false))["graph"], gd)
			var inv := _eval(_graph(op, _hard(true))["graph"], gd)
			var bad := _miscount(got, plain, mask)
			var bad_inv := _miscount(inv, plain, mask)
			print("    %-14s %-8s cells not carrying the expected bits: %d (want 0); with the mask inverted: %d (want many)"
					% [op, _route(gd), bad, bad_inv])
			_check(bad == 0, "%s (%s): a hard mask is not a bit-exact select" % [op, _route(gd)])
			# CONTROL: the inverted mask fails the same count, so `bad == 0` is the mask and not two equal fields.
			_check(bad_inv > 500, "%s (%s): the inverted mask passes the same test" % [op, _route(gd)])
	# GPU: the same program, the same cells. Contrast, Recast Cliff and Recast Canyon are here because their
	# kernels each lost a mask branch in this phase; the unmasked GPU field is held to the CPU's as well.
	for op in [&"strata", &"ridge_sharpen", &"contrast", &"recast_cliff", &"recast_canyon"] as Array[StringName]:
		var g_plain: Pasture3DTerrainGraph = _graph(op)["graph"]
		var gm: Pasture3DTerrainGraph = _graph(op, _hard(false))["graph"]
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(gm.compile_graph_program(), GW, GH, RECT, _surf)
		if gpu.size() != GW * GH:
			print("    %-14s GPU      NOT RUN (the GPU evaluator returned nothing)" % op)
			continue
		var gpu_plain: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g_plain.compile_graph_program(), GW, GH, RECT, _surf)
		var cpu_plain := _eval(g_plain, false)
		var worst := 0.0
		for i in range(mask.size()):
			if mask[i] <= 0.0:
				worst = maxf(worst, absf(gpu[i] - _surf[i]))
			elif mask[i] >= 1.0 and gpu_plain.size() == gpu.size():
				worst = maxf(worst, absf(gpu[i] - gpu_plain[i]))
		var vs_cpu := _max_abs_diff(gpu_plain, cpu_plain)
		_gpu_ran += 1
		print("    %-14s GPU      worst difference from the expected field = %.9f m; unmasked GPU vs CPU = %.9f m (want both < %s)"
				% [op, worst, vs_cpu, str(GPU_TOL)])
		if gpu_plain.size() != gpu.size() or worst >= GPU_TOL or vs_cpu >= GPU_TOL:
			_fail += 1; print("    !! %s (GPU): the mask slot disagrees with the CPU rule, or the kernel with the CPU" % op)


## Cells where `p_got` is not the input (mask <= 0) or not `p_plain` (mask >= 1).
func _miscount(p_got: PackedFloat32Array, p_plain: PackedFloat32Array, p_mask: PackedFloat32Array) -> int:
	if p_got.size() != p_mask.size() or p_plain.size() != p_mask.size():
		return p_mask.size()
	var bad := 0
	for i in range(p_mask.size()):
		if p_mask[i] <= 0.0 and p_got[i] != _surf[i]:
			bad += 1
		elif p_mask[i] >= 1.0 and p_got[i] != p_plain[i]:
			bad += 1
	return bad


# ---- [C] -------------------------------------------------------------------------------------------

func _c_op_count() -> void:
	print("[C] an unwired mask costs nothing; a wired one is exactly one Blend slot")
	var blend_op := int(Pasture3DTerrainGraph.op_ids().get(&"blend", -1))
	for op in FRAMEWORK_OPS:
		var plain: Dictionary = (_graph(op)["graph"] as Pasture3DTerrainGraph).compile_graph_program()
		var wired: Dictionary = (_graph(op, _const(0.5))["graph"] as Pasture3DTerrainGraph).compile_graph_program()
		var n_plain: int = (plain.get("ops", PackedInt32Array()) as PackedInt32Array).size()
		var ops_w: PackedInt32Array = wired.get("ops", PackedInt32Array())
		var blends := 0
		for o in ops_w:
			if o == blend_op:
				blends += 1
		# Input, the node, Output; wired adds the Const and the mask slot.
		print("    %-14s unwired: %d slots (want 3); wired: %d slots (want 5), %d of them Blend (want 1)"
				% [op, n_plain, ops_w.size(), blends])
		_check(n_plain == 3, "%s: an unwired mask changed the program" % op)
		_check(ops_w.size() == 5 and blends == 1, "%s: a wired mask is not exactly one extra Blend slot" % op)
	# CONTROL: a node that applies its own mask gets no slot, so the +1 above is the graph's mask.
	var own: Dictionary = (_graph(&"smooth_fill", _const(0.5))["graph"] as Pasture3DTerrainGraph).compile_graph_program()
	var n_own: int = (own.get("ops", PackedInt32Array()) as PackedInt32Array).size()
	print("    control: smooth_fill (applies its own mask) wired: %d slots (want 4)" % n_own)
	_check(n_own == 4, "a node that applies its own mask was given a Blend slot as well")


# ---- [D] -------------------------------------------------------------------------------------------

func _d_frozen() -> void:
	print("[D] a frozen solve is unmasked: moving the mask re-runs one blend, not the solver")
	var bumped := _surf.duplicate()
	for i in range(bumped.size()):
		bumped[i] += 3.0 * sin(float(i) * 0.37)
	for gd in [false, true]:
		var mask := _const(0.3)
		var b := _graph(&"erosion_thermal", mask)
		var g: Pasture3DTerrainGraph = b["graph"]
		var node: Pasture3DGraphSolverNode = b["node"]
		node.evaluation = Pasture3DGraphSolverNode.Evaluation.FROZEN
		var first := _eval(g, gd)
		var stale0 := node.is_stale()
		mask.set("value", 0.8)
		var second := _eval(g, gd)
		var stale_mask := node.is_stale()
		var moved := _max_abs_diff(first, second)
		# What the frozen solve should now be showing: the unmasked solve, 0.8 of the way from the input.
		var plain := _eval(_graph(&"erosion_thermal")["graph"], gd)
		var want := Pasture3DTerrainGraph.apply_standard_mask(_surf, plain, Pasture3DGraphOps.filled(GW * GH, 0.8))
		var off := _max_abs_diff(second, want)
		var third := _eval(g, gd, bumped)
		var stale_in := node.is_stale()
		print("    erosion_thermal %-8s stale after the first solve=%s; after the mask moved=%s (want false), output moved %.4f m, off the expected field by %.9f; after the INPUT moved=%s (want true)"
				% [_route(gd), stale0, stale_mask, moved, off, stale_in])
		_check(not stale0 and not stale_mask, "erosion_thermal (%s): moving only the mask staled the frozen solve" % _route(gd))
		_check(moved > 0.05, "erosion_thermal (%s): the output did not follow the mask" % _route(gd))
		_check(off <= 1.0e-5, "erosion_thermal (%s): the masked frozen result is not the unmasked solve blended over the input" % _route(gd))
		# CONTROL: the freeze does notice a real change.
		_check(stale_in and third.size() == GW * GH, "erosion_thermal (%s): a moved input did not stale the frozen solve" % _route(gd))

		# CONTROL: a solver that applies its own mask has it in its key, so there the mask does stale.
		var pmask := _const(0.3)
		var pb := _graph(&"hydraulic_particle", pmask)
		var pg: Pasture3DTerrainGraph = pb["graph"]
		var pnode: Pasture3DGraphSolverNode = pb["node"]
		pnode.evaluation = Pasture3DGraphSolverNode.Evaluation.FROZEN
		_eval(pg, gd)
		var p0 := pnode.is_stale()
		pmask.set("value", 0.8)
		_eval(pg, gd)
		print("    control: hydraulic_particle %-8s stale after the first solve=%s; after its own mask moved=%s (want true)"
				% [_route(gd), p0, pnode.is_stale()])
		_check(not p0 and pnode.is_stale(), "hydraulic_particle (%s): its own mask moving did not stale the frozen solve" % _route(gd))


# ---- [E] -------------------------------------------------------------------------------------------

func _e_recording() -> void:
	print("[E] the fourteen nodes that already had a mask match their pre-phase recording")
	for op in Fx.POST_PORT.keys():
		var gold := Fx.load_golden(op)
		_check(gold.size() == GW * GH, "%s: no recording at %s" % [op, Fx.golden_path(op)])
		for gd in [false, true]:
			var b := Fx.build(op, Fx.POST_PORT[op])
			var bi := Fx.build(op, Fx.POST_PORT[op], true)
			if b.is_empty() or bi.is_empty():
				_check(false, "%s has no '%s' port" % [op, Fx.POST_PORT[op]])
				continue
			var d := _max_abs_diff(_eval(b["graph"], gd), gold)
			var d_inv := _max_abs_diff(_eval(bi["graph"], gd), gold)
			print("    %-22s %-8s port '%s': max |now - recorded| = %.9f m (want <= %s); inverted mask: %.4f m (want > %s)"
					% [op, _route(gd), Fx.POST_PORT[op], d, str(PARITY_TOL), d_inv, str(INVERT_MIN)])
			_check(d <= PARITY_TOL, "%s (%s) no longer gives its pre-phase masked result" % [op, _route(gd)])
			# CONTROL: the recording is sensitive to the mask at all.
			_check(d_inv > INVERT_MIN, "%s (%s): the inverted mask also matches the recording" % [op, _route(gd)])


# ---- [F] -------------------------------------------------------------------------------------------

func _f_who_has_it() -> void:
	print("[F] every node the rule names has the port, and no other node does")
	var named := 0
	var wrong_missing: Array[String] = []
	var wrong_extra: Array[String] = []
	var wrong_shape: Array[String] = []
	for e in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = e["op"]
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		var ins: Array = n.input_ports()
		var outs: Array = n.output_ports()
		# The rule, written out here from §9.1 rather than asked of the node.
		var by_rule: bool = (n.role() == Pasture3DGraphNode.Role.FILTER or n.role() == Pasture3DGraphNode.Role.SOLVER) \
				and n.has_output() and not ins.is_empty() and not outs.is_empty() \
				and ins[0].type == Pasture3DGraphNode.PortType.HEIGHT and outs[0].type == Pasture3DGraphNode.PortType.HEIGHT \
				and not EXCLUDED_OPS.has(op)
		var count := 0
		for p in ins:
			if p.id == &"mask":
				count += 1
		var sp := n.standard_mask_port()
		if by_rule:
			named += 1
			if sp < 0 or count != 1:
				wrong_missing.append(String(op))
			elif sp != ins.size() - 1 or ins[sp].id != &"mask" or ins[sp].type != Pasture3DGraphNode.PortType.MASK \
					or ins[sp].required or n.input_unwired_default(sp) != 1.0:
				wrong_shape.append(String(op))
		elif sp >= 0:
			wrong_extra.append(String(op))
	print("    %d nodes named by the rule; missing the port: %s; port not last / not an optional MASK defaulting to 1: %s; has it without being named: %s"
			% [named, str(wrong_missing), str(wrong_shape), str(wrong_extra)])
	_check(named >= 40, "the rule names only %d nodes, so the registry walk is not seeing the node set" % named)
	_check(wrong_missing.is_empty(), "nodes the rule names have no single standard mask: %s" % str(wrong_missing))
	_check(wrong_shape.is_empty(), "standard mask ports of the wrong shape: %s" % str(wrong_shape))
	_check(wrong_extra.is_empty(), "nodes outside the rule have a standard mask: %s" % str(wrong_extra))

	for op in EXCLUDED_OPS:
		var n := Pasture3DGraphNodeRegistry.create(op)
		_check(n != null and n.standard_mask_port() < 0, "%s is excluded and has a standard mask" % op)
	for op in FRAMEWORK_OPS:
		var n := Pasture3DGraphNodeRegistry.create(op)
		_check(n.framework_mask_port() >= 0, "%s: the graph should apply its mask" % op)
	for op in OWN_OPS:
		var n := Pasture3DGraphNodeRegistry.create(op)
		_check(n.standard_mask_port() >= 0 and n.framework_mask_port() < 0 and n.aux_grid_port() == n.standard_mask_port(),
				"%s: should apply its own mask and receive it as its secondary grid" % op)

	# The renames and retypes of §9.3.1.
	var lev := Pasture3DGraphNodeRegistry.create(&"leveler")
	var mud := Pasture3DGraphNodeRegistry.create(&"mudslide")
	var ter := Pasture3DGraphNodeRegistry.create(&"terrace")
	var dep := Pasture3DGraphNodeRegistry.create(&"depression_filling")
	var lake := Pasture3DGraphNodeRegistry.create(&"lake_flooding")
	_check(lev.input_index_of(&"area") >= 0 and lev.framework_mask_port() > lev.input_index_of(&"area"),
			"Leveler: its region should be 'area', with the standard mask after it")
	_check(mud.input_index_of(&"source") >= 0 and mud.framework_mask_port() > mud.input_index_of(&"source"),
			"Mudslide: its material should be 'source', with the standard mask after it")
	var float_t := Pasture3DGraphNode.PortType.FLOAT
	_check(ter.input_ports()[ter.input_index_of(&"amount")].type == float_t, "Terrace: 'amount' should be a FLOAT")
	_check(dep.input_ports()[dep.input_index_of(&"amount")].type == float_t, "Depression Filling: 'amount' should be a FLOAT")
	_check(lake.input_ports()[lake.input_index_of(&"flood_percent")].type == float_t, "Lake Flooding: 'flood_percent' should be a FLOAT")

	# The fixture pair: same node, MASK out has none, HEIGHT out has one.
	var mo := MaskOutNode.new()
	var ho := HeightOutNode.new()
	print("    fixture FILTER returning a MASK: standard mask port %d (want -1); returning a HEIGHT: %d (want 1)"
			% [mo.standard_mask_port(), ho.standard_mask_port()])
	_check(mo.standard_mask_port() < 0, "a FILTER that returns a MASK was given a standard mask")
	# CONTROL: the same fixture with a height output gets one, so the -1 above is the output type.
	_check(ho.standard_mask_port() == 1, "the control fixture (HEIGHT out) has no standard mask")
