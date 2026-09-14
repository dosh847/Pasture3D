# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# JunctionDigestGate — the two reasons a road re-armed a full layer bake without a real change.
# PASTURE3D_BAKE_TRACE_FINDINGS_SPEC.md §2 (signed zero) and §3 (tolerance).
#
#   [A] `-0.0001` and `+0.0001` produce the same digest text, for a scalar field AND an arm-list element.
#   [B] the re-arm decision uses a tolerance against the LAST BAKE: 4 mm no, 20 mm yes, accumulated drift
#       fires exactly once, and structural changes always fire.
#
# Drives the static helpers `junction_digest()` and `schedule_junction_rebake()` are built from, so no
# network or terrain is needed and nothing touches project data.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/JunctionDigestGate.tscn
extends Node



var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== JunctionDigestGate ===\n")
	_a_signed_zero()
	_b_tolerance()
	print("\n  criteria completed: %d (want 2)" % _ran)
	if _ran != 2:
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["JUNCTION DIGEST PASS" if _fail == 0 else "JUNCTION DIGEST FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s: %s" % ["  " if p_ok else "!!", p_label, p_detail])


func _line(p_elev: float, p_z1: float, p_pin: float = 1.0) -> String:
	return Pasture3DRoadBrush._junction_line("J", false, 100.0, p_pin, 10.0, p_elev,
			PackedFloat32Array([0.5, p_z1]), PackedFloat32Array([0.0, 0.01]))


func _rec(p_elev: float, p_z1: float, p_pin: float = 1.0, p_banks := PackedFloat32Array([0.0, 0.01])) -> Dictionary:
	return {"J": Pasture3DRoadBrush._junction_record(false, 100.0, p_pin, 10.0, p_elev, PackedFloat32Array([0.5, p_z1]), p_banks)}


func _a_signed_zero() -> void:
	print("[A] signed zero does not change the digest")
	_check("scalar", _line(-0.0001, 0.0) == _line(0.0001, 0.0),
			"elevation -0.0001 vs +0.0001: %s | %s" % [_line(-0.0001, 0.0), _line(0.0001, 0.0)])
	_check("list element", _line(0.0, -0.0001) == _line(0.0, 0.0001),
			"arm z -0.0001 vs +0.0001 compare equal")
	_check("end-to-end", Pasture3DRoadBrush._junction_line("E", true, 5.0, 1.0, 2.0, -0.0001, PackedFloat32Array(), PackedFloat32Array())
			== Pasture3DRoadBrush._junction_line("E", true, 5.0, 1.0, 2.0, 0.0001, PackedFloat32Array(), PackedFloat32Array()),
			"the END_TO_END branch is normalised too")
	# CONTROLS: a digest that ignored these fields would pass every line above.
	_check("control scalar", _line(0.0, 0.0) != _line(0.002, 0.0), "elevation 0.000 vs 0.002 differ")
	_check("control list", _line(0.0, 0.0) != _line(0.0, 0.002), "arm z 0.000 vs 0.002 differ")
	var nan_line := _line(0.0, 0.0, NAN)
	_check("control nan", nan_line.contains("|nan|") and nan_line != _line(0.0, 0.0, 0.0),
			"a NaN pin prints nan and differs from 0.000")
	_ran += 1


func _b_tolerance() -> void:
	print("[B] re-arming uses a tolerance against the last bake")
	var base := _rec(0.0, 0.0)
	_check("4 mm", not Pasture3DRoadBrush.junction_values_differ(_rec(0.0, 0.004), base), "a 4 mm z change does not re-arm")
	_check("control 20 mm", Pasture3DRoadBrush.junction_values_differ(_rec(0.0, 0.020), base), "a 20 mm z change re-arms")
	_check("signed zero", not Pasture3DRoadBrush.junction_values_differ(_rec(-0.0001, 0.0), _rec(0.0001, 0.0)),
			"-0.0001 vs +0.0001 does not re-arm")

	# Accumulation: 3 mm per resolve, baseline advanced ONLY when a rebake fires. Must fire exactly once, at
	# step 4 (12 mm). A comparison against the previous resolve would never fire at all.
	var baked := _rec(0.0, 0.0)
	var fired_at := PackedInt32Array()
	for step in range(1, 6):
		var now := _rec(0.0, 0.003 * step)
		if Pasture3DRoadBrush.junction_values_differ(now, baked):
			fired_at.append(step)
			baked = now
	_check("accumulates", fired_at == PackedInt32Array([4]),
			"five 3 mm steps fired at %s (want [4])" % str(fired_at))
	# CONTROL for the line above: comparing against the previous step instead never fires.
	var prev := _rec(0.0, 0.0)
	var naive := 0
	for step in range(1, 6):
		var now := _rec(0.0, 0.003 * step)
		if Pasture3DRoadBrush.junction_values_differ(now, prev):
			naive += 1
		prev = now
	_check("control previous-resolve", naive == 0,
			"the same drift compared step-to-step fires %d time(s) — why the baseline is the last bake" % naive)

	var added := _rec(0.0, 0.0)
	added["K"] = Pasture3DRoadBrush._junction_record(true, 1.0, 1.0, 1.0, 0.0, PackedFloat32Array(), PackedFloat32Array())
	_check("junction added", Pasture3DRoadBrush.junction_values_differ(added, base), "a new junction always re-arms")
	_check("junction gone", Pasture3DRoadBrush.junction_values_differ({}, base), "a vanished junction always re-arms")
	_check("nan-ness", Pasture3DRoadBrush.junction_values_differ(_rec(0.0, 0.0, NAN), base), "a pin gaining NaN re-arms")
	_check("list reshaped", Pasture3DRoadBrush.junction_values_differ(_rec(0.0, 0.0, 1.0, PackedFloat32Array([0.0])), base),
			"an arm list changing length re-arms")
	_ran += 1
