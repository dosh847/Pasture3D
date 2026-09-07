extends Node

# GraphPreviewChannelGate — CHANNEL-ADDRESSABLE TAPS (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §8, phase V2)
#
# Erosion publishes `flow`, `ero`, `dep` and `wet` on channels 1..4, and until this phase there was no way
# to look at any of them: `graph_eval_grid_taps` took slots, with channel 0 implied by construction. Those
# four are the fields most worth looking at in the whole palette, and the only way to see one was to wire it
# to the graph output, look, and wire it back.
#
# THE PHASE IS TWO HALVES AND IT IS BOTH OR NEITHER (spec §4.4). Half 1 widens the tap API. Half 2 makes a
# tap DEMAND its channel, in the same reference array a wire counts in. Without half 2, `want_aux` returns
# nullptr, the producing op skips writing the channel, and the tap comes back as a field of zeros — which
# for `flow` renders as a plausible, calm, entirely fictional map of still water. Erosion makes it worse
# than a skipped copy: `want_diagnostics` is set FROM want_aux's answer, so the flow field is never computed
# at all.
#
# This exact bug has been met twice before. `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §11 item 4 —
# "`native_out_count()` returning `output_count()` — a channel the kernel never writes is served as zeros,
# which looks like a real answer" — and item 9, "assuming an unwired port means something other than zeros".
# Zeros are this system's universal impostor, and every criterion below is written to refuse them.
#
#   [A] tapping channel 1 returns THE SAME FIELD the graph output returns when flow is wired to the output.
#       Compared against the wired graph rather than against a solve the gate performs, because a gate that
#       calls the solver measures its own call (`a-gate-that-calls-the-node-measures-nothing`).
#       Control: channel 0 and channel 1 DIFFER, so the criterion cannot pass by reading one buffer twice.
#   [B] the ALLOCATION half is what is measured. Asserted on the evaluator's own reservation record, which
#       is written at the point of the reservation — not re-derived from the rule here, and not inferred
#       from the field being non-zero, since an unreserved channel and a genuinely calm one are the same
#       bytes. That inference is the defect.
#   [C] adding a tap does not change what the graph computes. Erosion's diagnostics are gated on demand, so
#       a tap that asks for `flow` changes what the solver is asked to do — and the HEIGHT it returns must
#       not move by a bit. Control: the height is non-flat, so two flat fields cannot agree vacuously.
#   [D] a channel at or beyond the slot's out_count is reported `unserved`, not served as zeros — and is
#       absent from the reservation record, so "not asked for" and "asked for and refused" stay distinct.
#
# Every criterion runs through `Pasture3DUtil.graph_eval_grid_taps` on a program from
# `compile_graph_program_multi`. Headless, no terrain, no data directory — but it DOES need the freshly
# built DLL, and says so rather than passing.

const GW := 48
const GH := 48
const RECT := Rect2(0, 0, 96, 96)

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== GraphPreviewChannelGate: channel-addressable taps (spec V2 §8) ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		print("!! Pasture3DUtil.graph_eval_grid_taps is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return

	_a_a_tapped_channel_is_the_wired_channel()
	_b_the_channel_is_allocated_because_it_was_tapped()
	_c_a_tap_does_not_change_what_the_graph_computes()
	_d_a_channel_past_out_count_is_unserved()

	if _checks < 25:
		print("\n    VACUOUS: only %d checks completed; the gate did not measure what it claims to."
				% _checks)
		_fail += 1
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["GRAPH PREVIEW CHANNEL PASS" if _fail == 0 else "GRAPH PREVIEW CHANNEL FAIL",
			_fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


# ---- fixtures -----------------------------------------------------------------------------------------

## A varied surface for the solver to erode. A flat one would make every channel zero and every comparison
## below true for the wrong reason — a ramp with a bump drains somewhere, which is what `flow` measures.
func _surface() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var u := float(ix) / float(GW - 1)
			var v := float(iz) / float(GH - 1)
			a[iz * GW + ix] = 40.0 * (1.0 - v) + 12.0 * sin(u * 7.0) * sin(v * 5.0)
	return a


## Input -> Erosion -> Output, with the erosion node's `p_out_port` wired into the Output.
##
## The graph is built the same way for every criterion and only the WIRE moves, so a difference between two
## runs is the wire and not the fixture.
func _graph(p_out_port: int) -> Dictionary:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeRegistry.create(&"input")
	var er := Pasture3DGraphNodeRegistry.create(&"erosion")
	var out := Pasture3DGraphNodeRegistry.create(&"output")
	if inp == null or er == null or out == null:
		return {}
	g.add_node(inp, Vector2.ZERO)
	g.add_node(er, Vector2(200, 0))
	g.add_node(out, Vector2(400, 0))
	# LIVE, not the node's FROZEN default. A frozen solver serves its own cache, which only the GDScript
	# evaluator can do, so the whole graph answers native_supported() false — and the tap path this phase
	# changes is the NATIVE one. Left frozen, every criterion here would still pass while measuring an
	# evaluator the phase did not touch.
	er.evaluation = Pasture3DGraphSolverNode.Evaluation.LIVE
	g.output_node = 2
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, p_out_port, 2, 0)
	return {"graph": g, "erosion": 1}


## Compile one graph and tap it. `p_channels` is the V2 half: one channel per requested slot.
func _tap(p_g: Pasture3DTerrainGraph, p_node: int, p_channels: PackedInt32Array) -> Dictionary:
	var compiled: Dictionary = p_g.compile_graph_program_multi([p_node])
	if compiled.is_empty():
		return {}
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(p_node):
		return {}
	var slots := PackedInt32Array()
	for i in range(p_channels.size()):
		slots.append(int(slot_of[p_node]))
	return Pasture3DUtil.graph_eval_grid_taps(
			compiled["program"], GW, GH, RECT, _surface(), slots, p_channels)


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _spread(p_a: PackedFloat32Array) -> float:
	if p_a.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in p_a:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return hi - lo if hi >= lo else 0.0


# --- A -------------------------------------------------------------------------------------------------
#
# The parity claim, and the reason the phase is worth having: a tapped channel must be the SAME FIELD as
# the wired one. If it is not, the preview is a third evaluator nobody declared
# (`PASTURE3D_NODE_ACCELERATION_GUIDE.md` §3.4).
#
# The reference is the GRAPH's own output with flow wired to it — not `erosion_solve` called here. A gate
# that ran the solver itself would compare two live solves and pass whether or not the tap ever reached the
# channel, which is `a-gate-that-calls-the-node-measures-nothing` in its exact original form.
func _a_a_tapped_channel_is_the_wired_channel() -> void:
	print("[A] a tapped channel is the same field the graph publishes when that channel is WIRED (§8)")

	var wired := _graph(1) # Erosion.flow -> Output
	var plain := _graph(0) # Erosion.height -> Output
	if wired.is_empty() or plain.is_empty():
		_check(false, "the registry could not build the fixture; nothing was measured")
		return
	var gw_: Pasture3DTerrainGraph = wired["graph"]
	var gp: Pasture3DTerrainGraph = plain["graph"]

	_check(gw_.native_supported(),
			"control: the fixture LOWERS (block report: %s), so the tap path under test is the NATIVE one "
			% str(gw_.native_block_report()) + "— a graph on the GDScript evaluator would exercise none of "
			+ "this phase")

	var reference: PackedFloat32Array = gw_.evaluate(GW, GH, RECT, null, _surface())
	_check(reference.size() == GW * GH and _spread(reference) > 0.0,
			"control: the wired reference is a real, VARIED flow field (%d cells, spread %.4f), so [A] is "
			% [reference.size(), _spread(reference)] + "not comparing two constant maps")

	var taps: Dictionary = _tap(gp, 1, PackedInt32Array([0, 1]))
	var fields: Array = taps.get("fields", [])
	_check(fields.size() == 2,
			"control: the tap returned one field per request (%d for 2)" % fields.size())
	if fields.size() != 2:
		return
	var ch0: PackedFloat32Array = fields[0]
	var ch1: PackedFloat32Array = fields[1]
	_check(PackedInt32Array(taps.get("unserved", PackedInt32Array())).is_empty(),
			"control: neither request was reported unserved, so [A] is comparing served fields")

	_check(_max_abs_diff(ch1, reference) < 1.0e-5,
			"[A] channel 1 tapped out of a graph whose OUTPUT is height equals the flow field the wired "
			+ "graph publishes (max |diff| = %.7f)" % _max_abs_diff(ch1, reference))
	# Without this, [A] passes on an implementation that hands every channel the same buffer.
	_check(_max_abs_diff(ch0, ch1) > 1.0e-3,
			"control: channel 0 and channel 1 of the SAME slot differ (max |diff| = %.4f), so [A] cannot "
			% _max_abs_diff(ch0, ch1) + "pass by reading one buffer twice")
	_check(_spread(ch1) > 0.0,
			"control: the tapped channel is itself varied (spread %.4f) — the all-zeros failure this "
			% _spread(ch1) + "phase exists to prevent would have a spread of exactly 0")


# --- B -------------------------------------------------------------------------------------------------
#
# HALF 2, MEASURED DIRECTLY. Widening the tap API alone is not merely insufficient, it is actively
# dangerous: it produces an answer that looks right.
#
# Asserted on `reserved` — the request indices the evaluator's demand pass reserved an aux buffer for,
# pushed at the point of the reservation. Two things it deliberately is not:
#   * not re-derived here from the same rule, which would agree with a broken allocator for exactly the
#     reason it agrees with a working one (`check-derived-values-outside-the-chain`);
#   * not inferred from the field being non-zero, because an unreserved channel and a genuinely calm one
#     are the same bytes. That inference IS the defect.
#
# The two are then cross-checked against each other, which is the whole "both or neither": the record says
# the buffer was reserved AND the field says the op wrote it. Deleting either half of the C++ fails this.
func _b_the_channel_is_allocated_because_it_was_tapped() -> void:
	print("\n[B] a tapped channel is ALLOCATED BECAUSE IT WAS TAPPED — the half that makes §4.4 safe")

	var plain := _graph(0)
	if plain.is_empty():
		_check(false, "the registry could not build the fixture; nothing was measured")
		return
	var g: Pasture3DTerrainGraph = plain["graph"]

	# Nothing downstream reads flow: the Output takes height. So the only reason the channel can exist is
	# that the tap asked for it.
	var taps: Dictionary = _tap(g, 1, PackedInt32Array([1]))
	var reserved: PackedInt32Array = taps.get("reserved", PackedInt32Array())
	_check(taps.has("reserved"),
			"control: the evaluator reports a reservation record at all, so [B] reads a measurement "
			+ "rather than an absent key that defaults to empty")
	_check(reserved.has(0),
			"[B] the evaluator RESERVED an aux buffer for the tapped channel (reserved=%s) even though no "
			% str(reserved) + "wire reads it — a tap is counted where a wire is counted")

	var fields: Array = taps.get("fields", [])
	var flow: PackedFloat32Array = fields[0] if fields.size() > 0 else PackedFloat32Array()
	_check(_spread(flow) > 0.0,
			"[B] and the op actually WROTE it (spread %.4f). Reserved-but-unwritten and unreserved are "
			% _spread(flow) + "different failures and this asserts both are absent")

	# THE CONTROL, and the one that makes the two halves inseparable. Channel 0 is served with no
	# reservation at all, so `reserved` is not a list of "every request" and a criterion reading it cannot
	# pass by the record being unconditionally populated.
	var t0: Dictionary = _tap(g, 1, PackedInt32Array([0]))
	_check(PackedInt32Array(t0.get("reserved", PackedInt32Array())).is_empty(),
			"control: a channel-0 tap reserves NOTHING (reserved=%s) — channel 0 is the slot's own buffer, "
			% str(t0.get("reserved", PackedInt32Array()))
			+ "so the record distinguishes rather than listing every request")
	_check(PackedInt32Array(t0.get("unserved", PackedInt32Array())).is_empty(),
			"control: and it is served anyway, so 'reserved nothing' is not 'answered nothing'")

	# And a pre-V2 caller — no channels array at all — still works and still reserves nothing. This is the
	# compatibility promise V1's return-shape comment made when it chose request-index keys.
	var compiled: Dictionary = g.compile_graph_program_multi([1])
	var slot_of: Dictionary = compiled["slot_of"]
	var legacy: Dictionary = Pasture3DUtil.graph_eval_grid_taps(
			compiled["program"], GW, GH, RECT, _surface(),
			PackedInt32Array([int(slot_of[1])]))
	var legacy_fields: Array = legacy.get("fields", [])
	_check(legacy_fields.size() == 1 and _spread(legacy_fields[0]) > 0.0,
			"control: a caller passing NO channels array still gets its channel-0 field (spread %.4f), so "
			% (_spread(legacy_fields[0]) if legacy_fields.size() > 0 else 0.0)
			+ "the widening did not break every existing tap")


# --- C ---------------------------------------------------------------------------------------------
#
# THE COST OF LOOKING. Erosion's diagnostics are gated on demand — `want_diagnostics` is set from want_aux's
# answer — so tapping `flow` genuinely changes what the solver is asked to produce. The height it returns
# must not move by a bit, or opening a preview would quietly change the terrain being previewed, and the
# author would be tuning against a surface that only exists while they are looking at it.
func _c_a_tap_does_not_change_what_the_graph_computes() -> void:
	print("\n[C] asking for a channel does not change the field the graph was already computing")

	var plain := _graph(0)
	if plain.is_empty():
		_check(false, "the registry could not build the fixture; nothing was measured")
		return
	var g: Pasture3DTerrainGraph = plain["graph"]

	var alone: Dictionary = _tap(g, 1, PackedInt32Array([0]))
	var withch: Dictionary = _tap(g, 1, PackedInt32Array([0, 1]))
	var h_alone: PackedFloat32Array = alone.get("fields", [])[0]
	var h_with: PackedFloat32Array = withch.get("fields", [])[0]

	_check(h_alone == h_with,
			"[C] the height channel is BIT-IDENTICAL with and without a flow tap in the same request "
			+ "(max |diff| = %.9f)" % _max_abs_diff(h_alone, h_with))
	_check(_spread(h_alone) > 1.0,
			"control: and that height is non-flat (spread %.3f m), so two constant fields cannot agree "
			% _spread(h_alone) + "vacuously")
	# The tap must also leave the BAKE alone — the same claim one level up, against the route the terrain
	# actually takes.
	var bake_a: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, _surface())
	var _unused: Dictionary = _tap(g, 1, PackedInt32Array([1, 2, 3, 4]))
	var bake_b: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, _surface())
	_check(bake_a == bake_b,
			"[C] and a four-channel tap between two bakes leaves the bake bit-identical")
	_check(_spread(bake_a) > 1.0,
			"control: the bake is non-flat too (spread %.3f m)" % _spread(bake_a))


# --- D -------------------------------------------------------------------------------------------------
#
# §4.4's disguise, refused. A channel at or beyond the slot's out_count has no buffer and never will, and
# the honest answer is `unserved` — V1's mechanism, doing the job it was built for one layer down.
#
# The wire path in the evaluator REDIRECTS an out-of-range channel to channel 0, which is correct there
# because the compiler refuses to lower such a wire and the branch is unreachable. A tap can ask for
# anything, so the same redirect would answer "channel 4 of a one-output Noise" with its height — a
# confident wrong answer, which is worse than no answer.
func _d_a_channel_past_out_count_is_unserved() -> void:
	print("\n[D] a channel the slot does not produce is UNSERVED, never served as zeros or as channel 0")

	var plain := _graph(0)
	if plain.is_empty():
		_check(false, "the registry could not build the fixture; nothing was measured")
		return
	var g: Pasture3DTerrainGraph = plain["graph"]

	# Erosion declares five channels (0..4), so 5 and 9 are past the end of a node that HAS aux channels.
	var taps: Dictionary = _tap(g, 1, PackedInt32Array([0, 4, 5, 9]))
	var unserved: PackedInt32Array = taps.get("unserved", PackedInt32Array())
	var reserved: PackedInt32Array = taps.get("reserved", PackedInt32Array())
	_check(unserved.has(2) and unserved.has(3),
			"[D] channels 5 and 9 of a five-channel op are reported unserved (unserved=%s)" % str(unserved))
	_check(not unserved.has(0) and not unserved.has(1),
			"control: channels 0 and 4 of the same slot in the same request are SERVED, so [D] is not a "
			+ "tap pass that failed wholesale")
	_check(reserved.has(1) and not reserved.has(2) and not reserved.has(3),
			"[D] and the out-of-range channels reserved nothing while channel 4 did (reserved=%s), so "
			% str(reserved) + "'not asked for' and 'asked for and refused' stay distinct")

	var fields: Array = taps.get("fields", [])
	_check(fields.size() == 4,
			"control: an unserved request still yields a field, so callers keep one field per request "
			+ "(got %d for 4)" % fields.size())
	if fields.size() == 4:
		_check(_spread(fields[2]) == 0.0 and _spread(fields[3]) == 0.0,
				"[D] the unserved fields are zero-filled — which is fine ONLY because `unserved` says so")
		_check(_max_abs_diff(fields[2], fields[0]) > 1.0e-3,
				"[D] and they are NOT channel 0's field — an out-of-range tap is refused, not silently "
				+ "redirected to the slot's own output")

	# A node with exactly ONE output is the other half of the rule: channel 1 of a Noise is out of range in
	# a program where some OTHER slot legitimately has five channels, so the refusal has to be per-slot.
	var g2 := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	var fnl := FastNoiseLite.new()
	fnl.seed = 4242
	fnl.frequency = 0.05
	n.noise = fnl
	n.amplitude = 20.0
	g2.add_node(n, Vector2.ZERO)
	g2.output_node = 0
	var t2: Dictionary = _tap(g2, 0, PackedInt32Array([0, 1]))
	var u2: PackedInt32Array = t2.get("unserved", PackedInt32Array())
	_check(not u2.has(0) and u2.has(1),
			"[D] channel 1 of a ONE-output node is unserved while its channel 0 is served (unserved=%s), "
			% str(u2) + "so out_count is read per slot and not per program")
	var f2: Array = t2.get("fields", [])
	_check(f2.size() == 2 and _spread(f2[0]) > 0.0,
			"control: that node's channel 0 is a real varied field (spread %.3f), so [D]'s second half "
			% (_spread(f2[0]) if f2.size() > 0 else 0.0) + "measured a working tap")
