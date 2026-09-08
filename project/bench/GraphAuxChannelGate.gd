# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphAuxChannelGate — the twelve solvers whose secondary outputs the native kernel used to discard.
#
# ---- WHAT WAS WRONG ----
#
# Sixteen non-dev nodes declare more than one output port; twelve of them had solvers that ALREADY
# computed the extra fields — the talus, the shore band, the channel mask, the sediment, the deposition —
# and the graph op wrote only `height`. The node then answered `native_out_count() == 1`, which was the
# honest declaration of that state: the compiler refuses to lower a graph reading a channel the op does
# not write, rather than lowering it and serving zeros (§4.4, the impostor rule).
#
# The refusal is graph-wide. Wiring `flow` out of a Stream Log took the WHOLE graph — its Erosion, its
# every generator — onto the GDScript evaluator, silently and with no error (§10). Reading a solver's
# diagnostic channel is the ordinary way to use one, so most interesting graphs paid it.
#
# ---- THE CLAIMS ----
#
#   [A] Every declared channel now LOWERS: a graph reading channel k is `native_supported()`.
#   [B] Every declared channel is SERVED, not unserved-and-silently-zero.
#   [C] The served field is the RIGHT field: cell for cell against the GDScript node's own
#       `eval_grid_channels()[k]`, which is the same oracle every other graph parity gate uses.
#   [D] The channels are DISTINCT — a kernel that copied height into every aux buffer would satisfy
#       [A]–[C] for every node whose channel 1 happens to correlate with its height.
#   [E] An undeclared channel is still refused. `native_out_count()` is a promise about the kernel, and
#       the value of the refusal is that it is still there for a channel nobody implemented.
#
# ---- WHAT THIS GATE CANNOT SAY ----
#
# It does not measure that an UNDEMANDED channel costs nothing. `want_aux` returning nullptr is what
# makes an unread diagnostic free, and the only honest measurement of that is a timing — which this
# house does not take without being asked. The allocation contract is asserted structurally instead, by
# [E]: a channel that was never demanded is one the tap reports unserved.
extends Node

const GW := 48
const GH := 40
const RECT := Rect2(0.0, 0.0, 240.0, 200.0)
const EPS := 2.0e-3 # both routes materialise float32; the solvers accumulate over many iterations

var _fail := 0
var _checks := 0

# op -> the channel count the native kernel now writes. Kept as a literal table rather than read from
# `native_out_count()`: a gate that asks the unit what it promises and then checks it kept THAT promise
# cannot notice a promise quietly withdrawn.
const EXPECTED := {
	"erosion_thermal": 2,
	"stream_extraction": 3,
	"lake_flooding": 3,
	"flooding_uniform_level": 3,
	"hydraulic_stream_log": 3,
	"hydraulic_saleve": 3,
	"hydraulic_particle": 4,
	"erosion_hydraulic": 3,
	"scree": 2,
	"water_mask": 2,
	"mudslide": 2,
	"smooth_fill": 2,
	"erosion": 5, # already correct before this phase; here so a regression in it is visible
	# path_distance is NOT here. Its four channels are all zero without a PATH wired, and a fixture that
	# cannot make a field move measures nothing: every comparison would pass against a zero oracle, and
	# so would a kernel that wrote nothing at all. It belongs to a gate that builds a path.
}


func _ready() -> void:
	print("=== GraphAuxChannelGate: the solvers' secondary channels ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		print("!! Pasture3DUtil.graph_eval_grid_taps is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return
	var surf := _ramp()
	for op in EXPECTED:
		_one_node(String(op), int(EXPECTED[op]), surf)
	_authored_vs_program_gap(surf)
	_e_an_undeclared_channel_is_still_refused(surf)
	print("\n    completed checks: %d" % _checks)
	if _checks < 55:
		print("    !! FEWER CHECKS COMPLETED THAN EXPECTED — a node threw before it asserted.")
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["GRAPH AUX CHANNEL PASS" if _fail == 0 else "GRAPH AUX CHANNEL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _ok(p_cond: bool, p_msg: String) -> void:
	_checks += 1
	if not p_cond:
		_fail += 1
		print("    !! %s" % p_msg)


func _one_node(p_op: String, p_count: int, p_surf: PackedFloat32Array) -> void:
	print("[%s] %d channels" % [p_op, p_count])
	var node := Pasture3DGraphNodeRegistry.create(StringName(p_op))
	if node == null:
		_ok(false, "the registry does not know `%s`" % p_op)
		return
	_ok(node.native_out_count() == p_count,
			"%s declares native_out_count() == %d, not the %d channels its kernel writes"
					% [p_op, node.native_out_count(), p_count])

	# The GDScript oracle, taken once. `eval_grid_channels` is what the GDScript evaluator itself calls.
	if not node.has_method("eval_grid_channels"):
		_ok(false, "%s has no eval_grid_channels — there is no oracle to compare against" % p_op)
		return
	_round_params_to_program_precision(node)
	var oracle: Array = node.eval_grid_channels([p_surf], GW, GH, null, RECT)

	var g := _graph_of(node)
	var seen := []
	var flat := 0
	for ch in range(p_count):
		var served := _tap(g, ch)
		if served.is_empty():
			_ok(false, "%s channel %d came back unserved — the graph did not lower or the op skipped it"
					% [p_op, ch])
			continue
		_checks += 1 # served
		var d := INF
		if ch < oracle.size() and oracle[ch] is PackedFloat32Array:
			d = _max_abs_diff(served, oracle[ch])
		print("    ch%d  vs oracle = %s   spread = %.4f" % [ch, String.num(d, 6), _spread(served)])
		_ok(d < EPS, "%s channel %d diverges from the GDScript node by %s" % [p_op, ch, String.num(d, 6)])
		# A FLAT channel is not evidence. It agrees with a flat oracle for free, and it agrees with
		# every other flat channel — so it is excluded from the distinctness control below and COUNTED,
		# rather than quietly making the control easier to satisfy. Erosion's `deposition` and `wetness`
		# are flat on this ramp: the two routes agree exactly, and the gate says only that.
		if _spread(served) > 1.0e-6:
			seen.append(_signature(served))
		else:
			flat += 1
	# [D] CONTROL: the channels that carry a field carry DIFFERENT fields. A kernel that wrote height
	# into every aux buffer, or a tap that redirected every channel to 0, would satisfy every comparison
	# above on any node whose oracle happens to be flat.
	var distinct := {}
	for sig in seen:
		distinct[sig] = true
	print("    control: %d channels carry a field, %d distinct; %d flat (unmeasured)"
			% [seen.size(), distinct.size(), flat])
	_ok(seen.size() > 0 and distinct.size() == seen.size(),
			"%s served %d non-flat channels but only %d distinct fields — a channel is an alias, not an answer"
					% [p_op, seen.size(), distinct.size()])


## Round every float property to what the PROGRAM can carry, so the oracle reads the same numbers the
## kernel does.
##
## ---- THIS IS NOT A LOOSENED TOLERANCE ----
##
## A lowered node's params travel in a PackedFloat32Array. The node itself passes GDScript doubles, so
## authored 0.05 reaches the kernel as float32 0.05 and the oracle as the exact double -- about 1e-9
## apart. `ErosionHydraulicParams`' own header records what that costs: the solver computes in double,
## and its `sed_c < cap` test turns a ULP into a whole erode-or-deposit decision, which compounds. One
## iteration still agreed bit for bit; at 25 the two routes were 0.060 m apart on this fixture, and
## rounding the oracle's params brings them to 0.000000.
##
## So this makes the comparison honest about WHICH question it asks. It asks "does the kernel compute the
## right thing from the numbers it was given", which is the claim this gate owns. The other question --
## whether a float32 program should be carrying a double-precision solver's parameters at all -- is a
## real defect, is older than this phase, and is measured separately in `_authored_vs_program_gap`.
func _round_params_to_program_precision(p_node) -> void:
	for prop in p_node.get_property_list():
		if int(prop.get("type", 0)) != TYPE_FLOAT:
			continue
		if not (int(prop.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = String(prop["name"])
		var v = p_node.get(name)
		if v is float and is_finite(v):
			p_node.set(name, PackedFloat32Array([v])[0])


## The size of the float32 param truncation on the node it bites hardest, printed and BOUNDED.
##
## Not a failure: the kernel is right about the numbers it was handed, and widening the program's param
## storage is a change with a blast radius far beyond this phase. Bounded so that if it ever stops being
## a rounding artefact and becomes a divergence, this says so -- and so that if the program is one day
## widened to doubles, the gap goes to zero and the `_round_params_to_program_precision` call above can
## be deleted rather than left as folklore.
func _authored_vs_program_gap(p_surf: PackedFloat32Array) -> void:
	print("[gap] the float32 param truncation, measured (KNOWN, older than this phase, NOT fixed here)")
	var authored = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
	var oracle: Array = authored.eval_grid_channels([p_surf], GW, GH, null, RECT)
	var served := _tap(_graph_of(Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")), 0)
	var d := _max_abs_diff(served, oracle[0]) if not served.is_empty() else INF
	print("    erosion_hydraulic height, authored doubles vs float32 program = %s m" % String.num(d, 6))
	_ok(d < 1.0, "the authored-vs-program gap is %s m — that is no longer a rounding artefact" % String.num(d, 6))


# --- E. An undeclared channel is still refused ---------------------------------------------------------
func _e_an_undeclared_channel_is_still_refused(p_surf: PackedFloat32Array) -> void:
	print("[E] a channel above native_out_count() is refused, not served as zeros")
	# DLA offers two output ports and has NO kernel op at all, so it declares 1 and must keep declaring
	# it. This is the control for the whole gate: if the tap served any channel of anything, every
	# comparison above would be measuring a machine that cannot say no.
	var node := Pasture3DGraphNodeRegistry.create(&"dla")
	if node == null:
		_ok(false, "the registry does not know `dla`")
		return
	print("    dla native_out_count = %d (want 1 — it has no kernel op)" % node.native_out_count())
	_ok(node.native_out_count() == 1, "dla claims native channels it has no kernel to write")
	var g := _graph_of(node)
	var served := _tap(g, 1)
	print("    dla channel 1 served = %s (want false)" % str(not served.is_empty()))
	_ok(served.is_empty(), "an undeclared channel came back served — that field is zeros wearing a hat")


# --- fixtures ------------------------------------------------------------------------------------------
## Input -> node -> Output. The solver reads the host surface, which is how every one of them is used.
func _graph_of(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_node,
			Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	g.output_node = 2
	return g


## Tap channel `p_chan` of node 1. Empty when the graph refused to lower or the channel was unserved —
## the two states this gate has to tell apart from "served zeros".
func _tap(p_g: Pasture3DTerrainGraph, p_chan: int) -> PackedFloat32Array:
	var compiled: Dictionary = p_g.compile_graph_program_multi([1])
	if compiled.is_empty():
		return PackedFloat32Array()
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(1):
		return PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], GW, GH, RECT, _ramp(),
			PackedInt32Array([int(slot_of[1])]), PackedInt32Array([p_chan]))
	var unserved: PackedInt32Array = res.get("unserved", PackedInt32Array())
	if unserved.has(0):
		return PackedFloat32Array()
	var fields: Array = res.get("fields", [])
	if fields.is_empty() or not (fields[0] is PackedFloat32Array):
		return PackedFloat32Array()
	return fields[0]


## A tilted, bumpy surface. Flat ground makes half these solvers no-ops, and a no-op's diagnostic
## channels are all zero — which is exactly the reading a broken kernel gives.
func _ramp() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for z in range(GH):
		for x in range(GW):
			var fx := float(x) / float(GW)
			var fz := float(z) / float(GH)
			out[z * GW + x] = 120.0 * fz + 40.0 * sin(fx * 9.0) * cos(fz * 7.0)
	return out


func _spread(p: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p:
		if not is_finite(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return (hi - lo) if hi >= lo else 0.0


func _signature(p: PackedFloat32Array) -> String:
	var s := 0.0
	for i in range(p.size()):
		if is_finite(p[i]):
			s += p[i] * float(i + 1)
	return String.num(s, 4)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.size() == 0:
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if not is_finite(p_a[i]) and not is_finite(p_b[i]):
			continue
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
