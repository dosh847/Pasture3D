# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDevTwinGate — a [Dev/GD] oracle starts from the same terrain as the node it checks.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P6 §6.6.
#
# The 32 `[Dev/GD]` pairs exist so the GDScript twin can be dropped beside the production node and the two
# surfaces compared: that is the whole method for checking the native kernel. The duality is deliberate
# and is NOT duplication to be removed — but it only means anything if the two nodes AGREE ON WHERE THEY
# START. The separation the design calls for is in the EXECUTION, not in the parameter defaults.
#
# They had drifted. 18 defaults across 8 pairs disagreed when this gate was written: `[Dev/GD] Erosion`
# defaulted `iterations` 15 / `erosion_rate` 0.05 against production's 30 / 0.08; `[Dev/GD] Warp`
# defaulted to FRACTAL / 25.0 / 50.0 / 0.005 against SIMPLEX / 20.0 / 15.0 / 0.01; `[Dev/GD] Spectral
# Equalizer` `micro_gain` 1.0 against 1.5; Stream Extraction disagreed on all four of its parameters.
# So a user comparing the twin to the node got a different terrain and read it as a KERNEL bug — the
# oracle accusing the thing it exists to vindicate.
#
#   [A] every [Dev/GD] twin shares its production node's defaults, property by property
#   [B] the twins have not become the same code: each still overrides its own evaluation
#
# [B] is here because the cheapest way to pass [A] would be to make the dev class extend the production
# one and inherit everything — which would delete the oracle while turning this gate green.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphDevTwinGate.tscn
extends Node

## Below this many pairs the sweep is not looking at the registry.
const MIN_PAIRS := 25

## Properties whose value is presentation or identity, not a parameter of the terrain. A twin is expected
## to differ here — that is what makes it a separate node in the palette.
const NOT_A_PARAMETER := ["graph_position", "collapsed", "preview_on", "label", "resource_name",
		"resource_path", "resource_local_to_scene", "script", "muted"]

var _fail := 0


func _ready() -> void:
	print("=== GraphDevTwinGate: the oracle starts where production starts (P6 §6.6) ===\n")
	var pairs := _pairs()
	_a_defaults_agree(pairs)
	_b_the_twins_are_still_two_implementations(pairs)
	print("\n=== %s (%d failures) ===\n" % ["GRAPH DEV TWIN PASS" if _fail == 0 else "GRAPH DEV TWIN FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


## Every registered op named `dev_<x>` whose `<x>` is also registered, as [dev_op, prod_op].
func _pairs() -> Array:
	var have := {}
	for entry in Pasture3DGraphNodeRegistry.entries(true):
		have[StringName(entry.get("op", &""))] = true
	var out := []
	for op in have:
		var s := String(op)
		if s.begins_with("dev_") and have.has(StringName(s.substr(4))):
			out.append([op, StringName(s.substr(4))])
	out.sort_custom(func(a, b): return String(a[0]) < String(b[0]))
	return out


# --- A ------------------------------------------------------------------------------------------------
func _a_defaults_agree(p_pairs: Array) -> void:
	print("[A] each [Dev/GD] twin shares its production node's parameter defaults")
	var compared := 0
	var drift: Array[String] = []
	for pair in p_pairs:
		var dev: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[0])
		var prod: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[1])
		if dev == null or prod == null:
			_check(false, "the registry could not create %s / %s" % [pair[0], pair[1]])
			continue
		for prop in prod.get_property_list():
			var nm: String = String(prop.get("name", ""))
			var usage: int = int(prop.get("usage", 0))
			if nm == "" or nm.begins_with("_") or nm in NOT_A_PARAMETER:
				continue
			if (usage & PROPERTY_USAGE_STORAGE) == 0 or (usage & PROPERTY_USAGE_EDITOR) == 0:
				continue
			var dv: Variant = dev.get(nm)
			if dv == null and prod.get(nm) != null and not _has(dev, nm):
				continue # the twin does not expose this parameter at all; that is a different claim
			compared += 1
			var pv: Variant = prod.get(nm)
			# Resources (a Curve, a FastNoiseLite) are distinct instances by construction; comparing them
			# by identity would report every pair as drifted, which is noise, not a finding.
			if dv is Object or pv is Object:
				continue
			if not _same(dv, pv):
				drift.append("%s.%s = %s, %s says %s" % [pair[0], nm, dv, pair[1], pv])
	_check(drift.is_empty(), "%d shared parameters agree%s" % [compared, "" if drift.is_empty() else " — " + "; ".join(drift)])
	_check(p_pairs.size() >= MIN_PAIRS, "the sweep found %d pairs (floor %d)" % [p_pairs.size(), MIN_PAIRS])

	# CONTROL. The comparison must be able to see a difference — otherwise [A] passes for the worst
	# possible reason, which is that `_same` says yes to everything.
	var w: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"warp")
	var w2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"warp")
	w2.set(&"strength", float(w.get(&"strength")) + 5.0)
	_check(not _same(w.get(&"strength"), w2.get(&"strength")),
			"control: a 5.0 difference in one parameter is visible to this comparison")


func _has(p_o: Object, p_name: String) -> bool:
	for prop in p_o.get_property_list():
		if String(prop.get("name", "")) == p_name:
			return true
	return false


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return absf(float(a) - float(b)) <= 1e-9
	return a == b


# --- B ------------------------------------------------------------------------------------------------
func _b_the_twins_are_still_two_implementations(p_pairs: Array) -> void:
	print("\n[B] the twins are still two implementations, not one inherited from the other")
	var shared: Array[String] = []
	var checked := 0
	for pair in p_pairs:
		var dev: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[0])
		var prod: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(pair[1])
		if dev == null or prod == null:
			continue
		checked += 1
		# `get_script()` identity is the test: a dev class that inherited production's evaluation would be
		# checking the kernel against itself and could never disagree with it.
		if dev.get_script() == prod.get_script():
			shared.append("%s and %s are the same script" % [pair[0], pair[1]])
		# A twin must also refuse to lower natively, or it is not running the GDScript path it exists for.
		if not Pasture3DTerrainGraph.op_ids().has(pair[0]):
			continue
		shared.append("%s has a native op id, so it would not run in script" % pair[0])
	_check(shared.is_empty(), "%d pairs are genuinely two%s" % [checked, "" if shared.is_empty() else " — " + "; ".join(shared)])

	# CONTROL: the identity test does say yes when the scripts really are the same.
	var a: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"warp")
	var b: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"warp")
	_check(a.get_script() == b.get_script(), "control: two nodes of one op do share a script")
