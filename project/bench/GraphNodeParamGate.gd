# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNodeParamGate — every registered graph node invalidates when one of its parameters changes.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P4 §4.3 (gate §4.5).
#
# The claim: mutating any `@export` parameter of any node in the registry moves that node's
# `_dirty_revision`. Nothing else in the pipeline notices a parameter at all — `_compute_node_inputs_hash`
# is built from `[gw, gh, rect, muted, op()]` plus upstream signatures and reads no parameters — so
# `_dirty_revision` IS the invalidation, and a node that does not bump it serves its first grid forever.
#
# WHY IT IS A REFLECTION GATE AND NOT FOUR HAND-WRITTEN CASES. `@export` assignment emits no
# `Resource.changed` in GDScript, so the only thing standing between a node and permanent staleness is a
# hand-written setter on every single property. Eight `[Dev/GD]` classes had none across 46 properties.
# A gate that named the classes it knew about would go quiet the moment a nine-th was added; this one
# fails at gate time for any class that forgets, including ones that do not exist yet.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphNodeParamGate.tscn
extends Node

## Below this many successfully mutated properties the sweep is not measuring the registry, it is
## measuring its own skip list — the difference between "every node invalidates" and "nothing was tried".
const MIN_PROPS := 120

## Properties that are the EDITOR's state, not the node's parameters. Moving a node on the canvas,
## folding its body, or toggling its thumbnail must not re-bake the terrain — a bump here would be the
## defect, so their absence from the sweep is deliberate and named rather than a skip that grew.
## `muted` is not on this list: it changes the result, and it invalidates through
## `_compute_node_inputs_hash` as well as through the revision.
const PRESENTATION := ["graph_position", "collapsed", "preview_on", "label"]

var _fail := 0


func _ready() -> void:
	print("=== GraphNodeParamGate: parameter edits invalidate (P4 §4.3) ===\n")
	_a_every_export_bumps_the_revision()
	_b_the_sweep_can_see_a_broken_node()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NODE PARAM PASS" if _fail == 0 else "GRAPH NODE PARAM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. The sweep ------------------------------------------------------------------------------------
func _a_every_export_bumps_the_revision() -> void:
	print("[A] every @export on every registered node bumps _dirty_revision")
	var tried := 0
	var skipped := 0
	var bad: Array[String] = []
	for entry in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = entry.get("op", &"")
		if op == &"":
			continue
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n == null:
			_fail += 1
			print("    !! %s: the registry could not create it" % op)
			continue
		for p in n.get_property_list():
			var pname: String = String(p.get("name", ""))
			var usage: int = int(p.get("usage", 0))
			if pname == "" or pname.begins_with("_") or pname in PRESENTATION:
				continue
			# Script-declared and inspector-visible: that is what `@export` produces, and it excludes
			# both the Resource base class's own properties and the group/category separators.
			if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or (usage & PROPERTY_USAGE_EDITOR) == 0:
				continue
			var before = n.get(pname)
			var mutated = _mutate(before, int(p.get("type", TYPE_NIL)))
			if mutated == null:
				skipped += 1
				continue
			var rev_before: int = n._dirty_revision
			n.set(pname, mutated)
			# A setter is free to clamp the value back to what it was; that is not a defect and the
			# assertion below would be unfair. Only a property that ACTUALLY moved is evidence.
			if _same(n.get(pname), before):
				skipped += 1
				continue
			tried += 1
			if n._dirty_revision == rev_before:
				bad.append("%s.%s" % [op, pname])
	_check("sweep", bad.is_empty(),
			"%d properties mutated across the registry, %d could not be moved; %d did not invalidate%s"
					% [tried, skipped, bad.size(), (": " + ", ".join(bad)) if not bad.is_empty() else ""])
	# CONTROL. A skip list that grew until it swallowed the registry would report zero failures for the
	# best possible reason and the worst possible cause.
	_check("control", tried >= MIN_PROPS,
			"the sweep actually moved %d properties (want >= %d)" % [tried, MIN_PROPS])


# --- B. The sweep is capable of failing --------------------------------------------------------------
#
# [A] passing proves the registry is clean. It does not prove the sweep would notice if it were not, and
# reverting §4.3 to check that by hand is exactly the manual step this gate exists to remove. So the gate
# builds the defect: a node whose parameter is written straight to the backing field, with no setter and
# no `_param_changed()` — which is precisely the shape all eight dev classes had.
func _b_the_sweep_can_see_a_broken_node() -> void:
	print("[B] a node that skips its setter is detectable")
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	if n == null:
		_check("fixture", false, "the registry could not create a Noise node")
		return
	var rev_before: int = n._dirty_revision
	# The healthy path, through the setter.
	n.set("amplitude", float(n.get("amplitude")) + 13.0)
	_check("healthy", n._dirty_revision > rev_before,
			"a real setter moved the revision (%d -> %d)" % [rev_before, n._dirty_revision])
	# The broken path: the same kind of edit with nothing emitting `changed`. `_dirty_revision` only ever
	# moves through `_on_node_changed_bump_revision`, so a silent write leaves it exactly where it was —
	# and that is the state [A] would report as a failure.
	var rev_silent: int = n._dirty_revision
	n.notify_property_list_changed() # touches the inspector, emits no `changed`
	_check("control", n._dirty_revision == rev_silent,
			"an edit that emits no `changed` leaves the revision at %d — so [A]'s assertion is not vacuous"
					% n._dirty_revision)


# ---- helpers -----------------------------------------------------------------------------------------

## A value different from `p_v`, or `null` when this gate has no safe way to move that type. Objects and
## packed arrays are deliberately not mutated: assigning a sub-resource is a different test (§4.4), and a
## solver's cached buffers are not parameters.
func _mutate(p_v, p_type: int):
	match p_type:
		TYPE_BOOL:
			return not bool(p_v)
		TYPE_INT:
			return int(p_v) + 1
		TYPE_FLOAT:
			# Ranges are commonly 0..1, where "+1" clamps straight back. Two candidates cover both a
			# 0..1 knob and an unbounded one, and `_same` above discards whichever did not move.
			var f := float(p_v)
			return 0.5 if not is_equal_approx(f, 0.5) else 0.25
		TYPE_STRING, TYPE_STRING_NAME:
			return String(p_v) + "_x"
		TYPE_VECTOR2:
			return (p_v as Vector2) + Vector2(1.0, 1.0)
		TYPE_VECTOR3:
			return (p_v as Vector3) + Vector3(1.0, 1.0, 1.0)
		TYPE_COLOR:
			var c: Color = p_v
			return Color(1.0 - c.r, c.g, c.b, c.a)
	return null


func _same(p_a, p_b) -> bool:
	if p_a is float and p_b is float:
		return is_equal_approx(p_a, p_b)
	return p_a == p_b


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s: %s" % ["  " if p_ok else "!!", p_label, p_detail])
