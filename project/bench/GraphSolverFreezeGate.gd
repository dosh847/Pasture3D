# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSolverFreezeGate — the LIVE/FROZEN protocol is one mechanism, and it works on every solver.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P6 §6.3.
#
# Twenty solver nodes hand-rolled the same freeze: `enum Evaluation { LIVE, FROZEN }`, the `_cache` /
# `_cache_key` / `_dirty_since_bake` / `_stale` quartet, `blocks_native()`, `_clear_solver_cache()`,
# `_set_stale()`, and an eighteen-line hit-miss flow that differed between copies only in which grids fed
# the key and which arguments fed the solve. Twenty copies drifted: four incompatible key rules (§4.4 —
# Lake Flooding could not tell 512x128 from 128x512), three twins mutating `_stale` behind
# `_set_stale()`'s back, and nine with no `blocks_native()` at all.
#
#   [A] the protocol is declared once — no solver file re-declares any part of it
#   [B] FROZEN holds its solve across a change LIVE provably responds to, and Bake picks it up
#   [C] a frozen solve that has gone stale says so, and Bake clears it
#   [D] FROZEN takes the graph off the native path, LIVE leaves it on
#   [E] a node offering the freeze has a solve of its own to freeze
#
# [B] is the one that matters most: it is the only criterion that would notice the refactor changing what
# the freeze DOES rather than merely where it is written.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSolverFreezeGate.tscn
extends Node

## Below this many solvers swept, the gate is measuring its own skip conditions.
const MIN_SOLVERS := 18

## The parts of the protocol that must exist in exactly one file.
const PROTOCOL := ["enum Evaluation", "var _cache_key", "var _dirty_since_bake", "var _stale",
		"func blocks_native", "func _set_stale", "func _clear_solver_cache"]

const GW := 24
const GH := 24

var _fail := 0


func _ready() -> void:
	print("=== GraphSolverFreezeGate: one freeze protocol, twenty solvers (P6 §6.3) ===\n")
	var solvers := _solvers()
	_a_declared_once(solvers)
	_b_frozen_serves_live_resolves(solvers)
	_c_stale_is_reported(solvers)
	_d_frozen_blocks_native(solvers)
	_e_the_freeze_is_attached_to_a_solve(solvers)
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SOLVER FREEZE PASS" if _fail == 0 else "GRAPH SOLVER FREEZE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


## Every registered op whose node offers the freeze, as [op, node].
func _solvers() -> Array:
	var out := []
	for entry in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = entry.get("op", &"")
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op) if op != &"" else null
		if n == null:
			continue
		for prop in n.get_property_list():
			if String(prop.get("name", "")) == "evaluation":
				out.append([op, n])
				break
	out.sort_custom(func(a, b): return String(a[0]) < String(b[0]))
	return out


## A ramp with a bump, so a solver has slope to route across and something to move.
func _surface(p_seed: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for y in GH:
		for x in GW:
			var fx := float(x) / GW
			var fy := float(y) / GH
			g[y * GW + x] = 120.0 * (1.0 - fy) + 30.0 * sin(fx * 6.0 + p_seed) + p_seed
	return g


## One evaluation of a solver node against a surface, as the primary output grid.
##
## Unwired ports are filled the way `Pasture3DTerrainGraph._input_grids` fills them — a whole grid of the
## port's own unwired default, never null. Passing null instead made `[Dev/GD] Thermal Erosion` throw on
## its unwired hardness port, which is a fact about this gate and not about the node.
func _eval(p_node: Pasture3DGraphNode, p_surface: PackedFloat32Array) -> PackedFloat32Array:
	var inputs := [p_surface]
	for i in range(1, p_node.input_count()):
		var dv: float = p_node.input_unwired_default(i)
		inputs.append(Pasture3DGraphOps.zeros(GW * GH) if is_zero_approx(dv) else Pasture3DGraphOps.filled(GW * GH, dv))
	var out = p_node.eval_grid(inputs, GW, GH, null, Rect2(0, 0, 512, 512))
	return out if out is PackedFloat32Array else PackedFloat32Array()


func _same(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	return a.size() == b.size() and a == b


## A change this solver's output provably responds to, as a Callable applied to a node.
##
## The surface first, because that is what the cache KEY is made of. But DLA grows a massif from its own
## seed and ignores the input surface entirely, so for those the probe falls back to a parameter — which
## exercises `_dirty_since_bake` rather than the key, and is the half of the freeze the surface probe
## cannot reach. Returns an empty Callable when nothing moves this node at all, and [B] then says so
## rather than claiming a freeze it never observed.
func _probe(p_op: StringName, p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> Callable:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	n.set(&"evaluation", 0)
	var base := _eval(n, p_a)
	if base.is_empty():
		return Callable()
	if not _same(base, _eval(n, p_b)):
		return func(_node: Pasture3DGraphNode): pass # the surface swap alone is the probe
	for prop in n.get_property_list():
		var nm: String = String(prop.get("name", ""))
		if nm == "" or nm.begins_with("_") or nm == "evaluation" or nm == "seed":
			continue
		if int(prop.get("type", TYPE_NIL)) != TYPE_FLOAT or (int(prop.get("usage", 0)) & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var was := float(n.get(nm))
		var probe: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
		probe.set(&"evaluation", 0)
		probe.set(nm, was * 1.7 + 0.9)
		if is_equal_approx(float(probe.get(nm)), was):
			continue # the setter clamped it back; not a usable probe
		if not _same(base, _eval(probe, p_a)):
			var v := float(probe.get(nm))
			return func(node: Pasture3DGraphNode): node.set(nm, v)
	return Callable()


# --- A ------------------------------------------------------------------------------------------------
func _a_declared_once(p_solvers: Array) -> void:
	print("[A] the freeze protocol is declared in exactly one file")
	var dir := "res://addons/pasture_3d/graph/"
	var owner_file := "pasture3d_graph_solver_node.gd"
	var offenders := PackedStringArray()
	var scanned := 0
	for name in DirAccess.get_files_at(dir):
		if not name.ends_with(".gd") or name == owner_file:
			continue
		var src := FileAccess.get_file_as_string(dir + name)
		if src == "":
			continue
		scanned += 1
		for part in PROTOCOL:
			# A declaration, at column 0. A doc comment naming the mechanism is the record of why it moved
			# and must survive; an override of `blocks_native` on a NON-solver node is also legitimate.
			if src.contains("\n" + part) and src.contains("Evaluation"):
				# By file, not by file-and-part: twenty files times seven parts is a 140-item line nobody
				# reads, and the finding is "this file still has its own copy", which the name alone says.
				if not offenders.has(name):
					offenders.append(name)
				break
	_check(offenders.is_empty(), "%d graph files carry no copy of the protocol%s" % [scanned, "" if offenders.is_empty() else " — %d still do: " % offenders.size() + ", ".join(offenders)])

	var base := FileAccess.get_file_as_string(dir + owner_file)
	var missing: Array[String] = []
	for part in PROTOCOL:
		if not base.contains("\n" + part):
			missing.append(part)
	_check(missing.is_empty(), "and the one file that does carry it has all %d parts%s" % [PROTOCOL.size(), "" if missing.is_empty() else " — missing " + ", ".join(missing)])

	var inherited := 0
	for pair in p_solvers:
		if pair[1] is Pasture3DGraphSolverNode:
			inherited += 1
	_check(inherited == p_solvers.size(), "%d of %d solvers inherit it" % [inherited, p_solvers.size()])
	_check(p_solvers.size() >= MIN_SOLVERS, "the sweep found %d solvers (floor %d)" % [p_solvers.size(), MIN_SOLVERS])

	# CONTROL: the scan can find a declaration when one is really there.
	_check(base.contains("\nenum Evaluation"), "control: the scan does match the declaration it looks for")


# --- B ------------------------------------------------------------------------------------------------
func _b_frozen_serves_live_resolves(p_solvers: Array) -> void:
	print("\n[B] FROZEN holds its solve across a change LIVE responds to; Bake picks the change up")
	var a := _surface(0.0)
	var b := _surface(37.0) # a different surface, so a re-solve MUST produce different output
	var froze := 0
	var bad: Array[String] = []
	var inert: Array[String] = []
	for pair in p_solvers:
		var op: StringName = pair[0]
		# The probe is this op's own control. Without one, a FROZEN node returning the same grid twice
		# proves nothing — an inert node does that too — so [B] must not count it.
		if not _has_own_solve(pair[1]):
			continue # not a solver at all; [E] is where that is reported
		var probe := _probe(op, a, b)
		if not probe.is_valid():
			inert.append(String(op))
			continue
		froze += 1

		var f: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		f.set(&"evaluation", 1)
		var frozen_a := _eval(f, a)
		probe.call(f)
		if not _same(frozen_a, _eval(f, b)):
			bad.append("%s re-solved while FROZEN" % op)
		# And the freeze is not simply a stuck node: after Bake it picks the change up.
		f.clear_cache()
		if _same(_eval(f, b), frozen_a):
			bad.append("%s still served the old solve after Bake" % op)
	_check(bad.is_empty(), "%d solvers froze and re-baked correctly%s" % [froze, "" if bad.is_empty() else " — " + "; ".join(bad)])
	_check(froze >= MIN_SOLVERS, "%d of them have a change LIVE provably responds to (floor %d)%s"
			% [froze, MIN_SOLVERS, "" if inert.is_empty() else " — no probe found for: " + ", ".join(inert)])


# --- C ------------------------------------------------------------------------------------------------
func _c_stale_is_reported(p_solvers: Array) -> void:
	print("\n[C] a frozen solve whose input moved reports itself stale, and Bake clears it")
	var a := _surface(0.0)
	var b := _surface(37.0)
	var wrong: Array[String] = []
	var checked := 0
	for pair in p_solvers:
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[0])
		if not n.has_method("is_stale") or not _has_own_solve(n):
			continue # a node with no solve cannot go stale; [E] reports that, and reporting it here too
			         # would make one defect look like three
		n.set(&"evaluation", 1)
		_eval(n, a)
		if n.is_stale():
			wrong.append("%s was stale immediately after its first solve" % pair[0])
		_eval(n, b)
		checked += 1
		if not n.is_stale():
			wrong.append("%s served a solve made for another surface and did not say so" % pair[0])
		elif n.node_warnings().is_empty():
			wrong.append("%s is stale but warns about nothing" % pair[0])
		n.clear_cache()
		if n.is_stale():
			wrong.append("%s is still stale after Bake" % pair[0])
	_check(wrong.is_empty(), "%d solvers report staleness%s" % [checked, "" if wrong.is_empty() else " — " + "; ".join(wrong)])
	_check(checked >= MIN_SOLVERS, "the sweep reached %d solvers (floor %d)" % [checked, MIN_SOLVERS])


# --- D ------------------------------------------------------------------------------------------------
func _d_frozen_blocks_native(p_solvers: Array) -> void:
	print("\n[D] FROZEN takes the graph off the native path; LIVE leaves it on")
	# A cached solve is state the native program cannot see: it is a pure function of the graph and its
	# input surface, so it would silently ignore the freeze and re-solve. Nine of the twenty had no
	# `blocks_native()` at all, and answering wrong in EITHER direction is a bug — false when frozen
	# discards the user's bake, true when live costs native evaluation across the whole graph.
	var wrong: Array[String] = []
	for pair in p_solvers:
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[0])
		n.set(&"evaluation", 0)
		if n.blocks_native():
			wrong.append("%s blocks native while LIVE" % pair[0])
		n.set(&"evaluation", 1)
		if not n.blocks_native():
			wrong.append("%s does not block native while FROZEN" % pair[0])
	_check(wrong.is_empty(), "%d solvers answer both ways%s" % [p_solvers.size(), "" if wrong.is_empty() else " — " + "; ".join(wrong)])

	# CONTROL: a node with no freeze must not block native, or [D] is passing on a constant.
	var blend: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"blend")
	_check(blend != null and not blend.blocks_native(), "control: a node with no freeze never blocks native")


## True when this node's OWN script — or one between it and the solver base — defines an evaluation,
## rather than inheriting `Pasture3DGraphNode`'s passthrough.
##
## This reads the scripts rather than asking the object, because `Script.get_script_method_list()` reports
## INHERITED methods too: every node in the project answered "yes, I define eval_grid", which made the
## first version of this probe a constant true and [E] a criterion that could not fail.
func _has_own_solve(p_node: Pasture3DGraphNode) -> bool:
	var sc: Script = p_node.get_script()
	while sc != null and sc.get_global_name() != &"Pasture3DGraphNode":
		var src := FileAccess.get_file_as_string(sc.resource_path)
		if src.contains("\nfunc eval_grid(") or src.contains("\nfunc eval_grid_channels("):
			return true
		sc = sc.get_base_script()
	return false


# --- E ------------------------------------------------------------------------------------------------
func _e_the_freeze_is_attached_to_a_solve(p_solvers: Array) -> void:
	print("\n[E] a node that offers the freeze has a solve of its own to freeze")
	# The freeze is a promise in the inspector: an Evaluation group, a LIVE/FROZEN switch and a Bake
	# button. A node that shows all three and then inherits `Pasture3DGraphNode.eval_grid` — which returns
	# its first input unchanged — is not slow, it does NOTHING, and the freeze is decoration over a node
	# that never ran. That is invisible from the freeze's side, which is why it needs its own criterion:
	# every part of the protocol behaves perfectly on a node with nothing to protect.
	var hollow: Array[String] = []
	for pair in p_solvers:
		if not _has_own_solve(pair[1]):
			hollow.append(String(pair[0]))
	_check(hollow.is_empty(), "%d solvers implement an evaluation%s"
			% [p_solvers.size() - hollow.size(), "" if hollow.is_empty() else " — %d pass their input straight through: " % hollow.size() + ", ".join(hollow)])

	# CONTROL: the probe can tell the two apart, or [E] is reporting on a constant.
	var real: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"erosion")
	var passthrough: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	_check(_has_own_solve(real) and not _has_own_solve(passthrough),
			"control: the probe sees Erosion's solve and does not invent one for Output")

