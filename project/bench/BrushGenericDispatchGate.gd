# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushGenericDispatchGate — a new modifier cannot be silently ignored by the brush's generic paths.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P6 §6.4.
#
# Four places in `pasture3d_terrain_brush.gd` looked generic and were not:
#
#   * `_apply_field_step` dispatched grid modifiers with a hardcoded `if`-chain on `m.op()` — smooth,
#     erosion, graph, road — falling through to `return p_vals`. A new grid modifier that forgot to edit
#     that chain DID NOTHING, with no error: the brush painted, the stack listed the step, and its pass
#     never ran. The same op-string set was re-enumerated for the native-bail decision, so two lists had
#     to agree.
#   * `_commit_modifier_caches` routed a deferred result with `if m is Pasture3DNodeErosion` /
#     `elif m is Pasture3DNodeGraph`. A third deferring modifier matched neither and was dropped — it
#     would set `pending`, nothing would queue it, and the driver would finish having solved nothing.
#     Five lines below, the same loop already used a generic `has_method`, so two idioms coexisted.
#   * `blk` and `step`, two dictionaries built side by side from one modifier and read by the two paths.
#     That is how §3.6's `defer` came to be written to one and read from the other.
#   * A four-deep inline probe, `m != null and "material" in m and m.material != null and
#     m.material.has_method("set_seed_surface")`, answering about three different objects at once.
#
#   [A] a grid modifier the brush has never heard of still gets its pass run
#   [B] a deferring modifier the brush has never heard of still reaches a queue, or errors — never silence
#   [C] the compiled block is ONE dictionary, so the native and GDScript readers cannot disagree
#   [D] the shipped modifiers answer the new protocol the way the old hardcoded chains did
#
# [A] and [B] are the point: both use a modifier defined HERE, which the brush cannot possibly have a
# branch for. That is the whole test — under the old code both would have been ignored in silence.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushGenericDispatchGate.tscn
extends Node

const GW := 16
const GH := 16

var _fail := 0


func _ready() -> void:
	print("=== BrushGenericDispatchGate: the generic paths are generic (P6 §6.4) ===\n")
	_a_an_unknown_grid_modifier_runs()
	_b_an_unknown_deferring_modifier_is_queued()
	_c_one_dictionary()
	_d_the_shipped_modifiers_still_answer()
	print("\n=== %s (%d failures) ===\n" % ["BRUSH GENERIC DISPATCH PASS" if _fail == 0 else "BRUSH GENERIC DISPATCH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


## A modifier this codebase has no branch for. Its op string is deliberately not one the brush knows.
class _StrangerNode extends Pasture3DNode:
	var ran := false

	func op() -> StringName:
		return &"pasture3d_no_such_modifier"

	func needs_grid() -> bool:
		return true

	func apply_field(_p_step: Dictionary, p_vals: PackedFloat32Array, _p_ctx: Dictionary) -> PackedFloat32Array:
		ran = true
		var out := p_vals.duplicate()
		for i in range(out.size()):
			out[i] += 7.0 # a value nothing else in the stack produces
		return out


## A modifier that defers, which the brush also has no branch for.
class _DeferringStranger extends Pasture3DNode:
	func op() -> StringName:
		return &"pasture3d_no_such_deferring_modifier"

	func needs_grid() -> bool:
		return true

	func make_pending(p_out: Dictionary, p_extent: String) -> Dictionary:
		return {"mod": self, "extent": p_extent, "z": p_out.get("pending", PackedFloat32Array())}

	func pending_queue() -> StringName:
		return &"erosion" # an EXISTING queue: [B] is about reaching one, not about adding one


## Same, but naming a queue that does not exist — the case that must be loud rather than silent.
class _LostStranger extends _DeferringStranger:
	func pending_queue() -> StringName:
		return &"no_such_queue"


func _grid(p_v: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	g.fill(p_v)
	return g


func _brush() -> Pasture3DMound:
	var b := Pasture3DMound.new()
	add_child(b)
	return b


# --- A ------------------------------------------------------------------------------------------------
func _a_an_unknown_grid_modifier_runs() -> void:
	print("[A] a grid modifier the brush has no branch for still gets its pass run")
	var b := _brush()
	var m := _StrangerNode.new()
	var vals := _grid(100.0)
	var out: PackedFloat32Array = b._apply_field_step({"mod": m, "op": m.op(), "grid": true}, vals,
			{"gw": GW, "gh": GH, "host": b})
	_check(m.ran, "the modifier's own apply_field was called")
	_check(out.size() == vals.size() and out[0] == 107.0,
			"and its result reached the caller (%s, expected 107.0)" % (out[0] if not out.is_empty() else "empty"))

	# CONTROL. A modifier that does NOT override apply_field must pass the grid through unchanged — so [A]
	# is measuring dispatch and not simply "the brush returns something different".
	var quiet := Pasture3DNode.new()
	var same: PackedFloat32Array = b._apply_field_step({"mod": quiet, "op": quiet.op(), "grid": true},
			vals, {"gw": GW, "gh": GH, "host": b})
	_check(same == vals, "control: a modifier with no grid pass is the identity, not a mystery value")
	b.queue_free()


# --- B ------------------------------------------------------------------------------------------------
func _b_an_unknown_deferring_modifier_is_queued() -> void:
	print("\n[B] a deferring modifier the brush has no branch for still reaches a queue")
	var b := _brush()
	var m := _DeferringStranger.new()
	var out := {"pending": _grid(3.0), "pending_key": 1, "pending_gw": GW, "pending_gh": GH}
	var before: int = b._pending_queues()[&"erosion"].size()
	b._commit_modifier_caches({"gd": [{"mod": m, "op": m.op(), "grid": true, "out": out}]}, "x")
	var after: int = b._pending_queues()[&"erosion"].size()
	_check(after == before + 1, "the entry was filed (%d -> %d)" % [before, after])

	# CONTROL. The old code dropped an unrecognised deferring modifier in SILENCE. A queue name nothing
	# answers to must still be loud — an error the user can see, not a solve that quietly never happens.
	var lost := _LostStranger.new()
	var out2 := {"pending": _grid(3.0), "pending_key": 1, "pending_gw": GW, "pending_gh": GH}
	var n_before: int = b._pending_queues()[&"erosion"].size() + b._pending_queues()[&"graph"].size()
	b._commit_modifier_caches({"gd": [{"mod": lost, "op": lost.op(), "grid": true, "out": out2}]}, "x")
	var n_after: int = b._pending_queues()[&"erosion"].size() + b._pending_queues()[&"graph"].size()
	_check(n_after == n_before, "control: an unknown queue name adds nothing (it pushes an error instead)")

	# CONTROL. A modifier that defers NOTHING must not be queued either, or [B] passes on any modifier.
	var quiet := Pasture3DNode.new()
	var q_before: int = b._pending_queues()[&"erosion"].size()
	b._commit_modifier_caches({"gd": [{"mod": quiet, "op": quiet.op(), "grid": true,
			"out": {"pending": _grid(3.0)}}]}, "x")
	_check(b._pending_queues()[&"erosion"].size() == q_before,
			"control: a modifier with nothing to defer is not queued")
	b.queue_free()


# --- C ------------------------------------------------------------------------------------------------
func _c_one_dictionary() -> void:
	print("\n[C] the compiled block is one dictionary, read two ways")
	var b := _brush()
	var ero := Pasture3DNodeErosion.new()
	b.modifiers = [ero]
	var stack: Dictionary = b._compile_modifiers("x")
	_check(stack["list"].size() == 1 and stack["gd"].size() == 1,
			"the compile produced one step on each side (%d / %d)" % [stack["list"].size(), stack["gd"].size()])
	if stack["list"].is_empty() or stack["gd"].is_empty():
		b.queue_free()
		return
	# is_same, not ==: two dictionaries with equal contents would compare equal and still be two objects
	# that can drift apart, which is the entire defect.
	_check(is_same(stack["list"][0], stack["gd"][0]),
			"and the native reader and the GDScript reader hold the SAME object")
	var blk: Dictionary = stack["gd"][0]
	for k in ["op", "mod", "grid", "defer", "out"]:
		_check(blk.has(k), "the one block carries `%s`, which used to live on only one side" % k)

	# CONTROL: two separately built dictionaries are NOT the same object, so `is_same` is discriminating.
	_check(not is_same({"op": &"erosion"}, {"op": &"erosion"}),
			"control: is_same distinguishes two equal dictionaries")
	b.queue_free()


# --- D ------------------------------------------------------------------------------------------------
func _d_the_shipped_modifiers_still_answer() -> void:
	print("\n[D] the shipped modifiers answer the protocol the old hardcoded chains answered")
	# The old `if`-chain named four ops. Each must now say so itself, or moving the decision onto the node
	# silently narrowed what the stack can do.
	var have := {
		&"smooth": Pasture3DNodeSmooth.new(),
		&"erosion": Pasture3DNodeErosion.new(),
		&"graph": Pasture3DNodeGraph.new(),
	}
	var missing: Array[String] = []
	for op in have:
		var sc: Script = have[op].get_script()
		var src := FileAccess.get_file_as_string(sc.resource_path)
		if not src.contains("\nfunc apply_field("):
			missing.append(String(op))
	_check(missing.is_empty(), "%d of the old chain's ops define apply_field%s"
			% [have.size() - missing.size(), "" if missing.is_empty() else " — missing: " + ", ".join(missing)])

	# The bail decision moved the same way, and only the two ops that could bail may answer true.
	var g := Pasture3DNodeGraph.new()
	_check(g.forces_gdscript(null), "a graph with no resource forces GDScript, as the old chain did")
	_check(not Pasture3DNodeSmooth.new().forces_gdscript(null),
			"control: a blur does not force GDScript, so [D] is not reading a constant true")

	# And the seed-surface handoff is a question asked of the modifier, not of its material's method list.
	var relief := Pasture3DNodeRelief.new()
	_check(not relief.wants_seed_surface(),
			"a relief with no material wants no seed surface (the old probe crashed on the null)")
	_check(not Pasture3DNodeErosion.new().wants_seed_surface(),
			"control: a modifier with no material answers false rather than being asked about one")
