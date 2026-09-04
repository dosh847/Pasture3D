# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSlotWidgetGate — an inline port widget takes its range from the property, and never narrows it.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P6 §6.5.
#
# `_append_slot_inline_widget` used to be 542 lines of 91 near-identical SpinBox blocks, each restating a
# min/max/step the node had already declared as an `@export_range`. Measured across the 41 pairs that
# could be compared automatically, 37 had drifted. Sixteen were the destructive kind: the node declares
# `or_greater`, the widget clamped, and because the box writes its value back on interaction a graph
# authored beyond the widget's cap was silently rewritten down to it. Warp's `frequency` is
# `@export_range(0.0001, 0.5, 0.0005, "or_greater")` and the widget stopped at 0.1, so 0.3 displayed as
# 0.1 and became 0.1.
#
#   [A] every property the widget table names exists on its node
#   [B] the built box matches the property's own hint, `or_greater` included
#   [C] a value beyond the soft range survives the round trip — the data loss itself
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSlotWidgetGate.tscn
extends Node

var _fail := 0
var _ed: Pasture3DGraphEditor = null
var _row: HBoxContainer = null


func _ready() -> void:
	print("=== GraphSlotWidgetGate: inline widgets read the property's own range (P6 §6.5) ===\n")
	_ed = Pasture3DGraphEditor.new()
	_row = HBoxContainer.new()
	add_child(_row)
	_a_table_names_real_properties()
	_b_the_box_matches_the_hint()
	_c_a_soft_range_is_not_narrowed()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SLOT WIDGET PASS" if _fail == 0 else "GRAPH SLOT WIDGET FAIL", _fail])
	_ed.free() # it never entered the tree, so nothing else will free it
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


## Build one widget in isolation and hand back the SpinBox, or null.
func _spin(p_node: Pasture3DGraphNode, p_prop: StringName) -> SpinBox:
	for c in _row.get_children():
		c.queue_free()
		_row.remove_child(c)
	_ed._spin_from_hint(_row, p_node, p_prop)
	for c in _row.get_children():
		if c is SpinBox:
			return c
	return null


func _hint_of(p_node: Pasture3DGraphNode, p_prop: StringName) -> String:
	for prop in p_node.get_property_list():
		if StringName(prop.get("name", &"")) == p_prop and int(prop.get("hint", 0)) == PROPERTY_HINT_RANGE:
			return String(prop.get("hint_string", ""))
	return ""


# --- A ------------------------------------------------------------------------------------------------
func _a_table_names_real_properties() -> void:
	print("[A] every property the widget table names exists on its node")
	var missing: Array[String] = []
	var named := 0
	for op in Pasture3DGraphEditor.SLOT_SPINS:
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n == null:
			missing.append("%s: the registry cannot create it" % op)
			continue
		var have := {}
		for prop in n.get_property_list():
			have[StringName(prop.get("name", &""))] = true
		for port in Pasture3DGraphEditor.SLOT_SPINS[op]:
			for prop_name in Pasture3DGraphEditor.SLOT_SPINS[op][port]:
				named += 1
				if not have.has(prop_name):
					missing.append("%s port %d -> %s" % [op, port, prop_name])
	_check(missing.is_empty(), "%d table entries name a real property%s" % [named, "" if missing.is_empty() else " — " + "; ".join(missing)])
	_check(named >= 80, "the table covers %d slots (the old code had 91 boxes)" % named)


# --- B ------------------------------------------------------------------------------------------------
func _b_the_box_matches_the_hint() -> void:
	print("\n[B] the built box carries the property's own min / max / step / or_greater")
	var wrong: Array[String] = []
	var built := 0
	var soft := 0
	for op in Pasture3DGraphEditor.SLOT_SPINS:
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n == null:
			continue
		for port in Pasture3DGraphEditor.SLOT_SPINS[op]:
			for prop_name in Pasture3DGraphEditor.SLOT_SPINS[op][port]:
				var hint := _hint_of(n, prop_name)
				if hint == "":
					continue # no declared range; [B] has nothing to compare and _spin_from_hint says so
				var bits := hint.split(",")
				var sb := _spin(n, prop_name)
				built += 1
				if sb == null:
					wrong.append("%s.%s built no box" % [op, prop_name])
					continue
				if absf(sb.min_value - bits[0].to_float()) > 1e-9 or absf(sb.max_value - bits[1].to_float()) > 1e-9:
					wrong.append("%s.%s is %s..%s, the node says %s..%s" % [op, prop_name, sb.min_value, sb.max_value, bits[0], bits[1]])
				if hint.contains("or_greater"):
					soft += 1
					if not sb.allow_greater:
						wrong.append("%s.%s is or_greater but the box clamps at %s" % [op, prop_name, sb.max_value])
	_check(wrong.is_empty(), "%d boxes match their property%s" % [built, "" if wrong.is_empty() else " — " + "; ".join(wrong)])
	_check(soft > 0, "%d of them are or_greater, so the clamp check ran at all" % soft)

	# CONTROL. The comparison must be able to fail: a box built from a DIFFERENT property's hint should
	# not match. Crater's `rim_width` (0.02..0.95) against `amplitude` proves the check discriminates.
	var crater: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"crater")
	var rim := _spin(crater, &"rim_width")
	var amp_hint := _hint_of(crater, &"amplitude")
	_check(rim != null and (amp_hint == "" or absf(rim.max_value - amp_hint.split(",")[1].to_float()) > 1e-9),
			"control: two properties' hints are distinguishable by this comparison")


# --- C ------------------------------------------------------------------------------------------------
func _c_a_soft_range_is_not_narrowed() -> void:
	print("\n[C] a value beyond the soft range survives being shown and written back")
	var warp: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"warp")
	_check(warp != null, "the Warp node exists")
	if warp == null:
		return
	var hint := _hint_of(warp, &"frequency")
	_check(hint.contains("or_greater"), "warp.frequency is declared or_greater (%s)" % hint)

	# 0.3 is the spec's own example: inside the declared 0.0001..0.5 and far outside the 0.1 the old
	# widget hardcoded.
	warp.set(&"frequency", 0.3)
	_check(absf(float(warp.get(&"frequency")) - 0.3) < 1e-6, "the node holds 0.3 (%s)" % warp.get(&"frequency"))

	var sb := _spin(warp, &"frequency")
	if sb == null:
		_check(false, "the box was built")
		return
	# Tolerance is ONE STEP, not epsilon. A SpinBox snaps to its step grid, and the step here is the
	# node's own 0.0005 — 0.3 lands on 0.3001. That rounding is the node's declared precision and is the
	# thing being honoured; the bug was the box moving the value by 0.2, which is 400 steps.
	var step := 0.0005
	_check(absf(sb.value - 0.3) <= step, "the box DISPLAYS 0.3 within one step (%s)" % sb.value)
	# The write-back is what destroyed the value: the box emits its own value on interaction.
	sb.value_changed.emit(sb.value)
	_check(absf(float(warp.get(&"frequency")) - 0.3) <= step,
			"and writing it back leaves 0.3 within one step (%s)" % warp.get(&"frequency"))

	# CONTROL. A box with the OLD hardcoded 0.1 cap does destroy it — so [C] is measuring the clamp and
	# not simply the absence of a write-back.
	var clamped := SpinBox.new()
	clamped.min_value = 0.0001
	clamped.max_value = 0.1
	clamped.step = 0.001
	clamped.value_changed.connect(func(v: float): warp.set(&"frequency", v))
	_row.add_child(clamped)
	clamped.value = 0.3
	clamped.value_changed.emit(clamped.value)
	_check(absf(float(warp.get(&"frequency")) - 0.3) > 0.1,
			"control: the old hardcoded 0.1 cap does rewrite it, and by far more than a step (to %s)" % warp.get(&"frequency"))
