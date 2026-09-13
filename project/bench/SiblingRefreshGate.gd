# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SiblingRefreshGate — the two redundancies a bake trace exposed in a road drag.
#
#   [A] A full layer bake drops the pending refresh of a layer-mate it already repainted.
#   [B] ...but NOT one re-armed during the bake (the corridor-outgrew second pass depends on that).
#   [C] A Curve3D content edit is not treated as a resource swap, and a real swap still rebinds.
#
# Scheduling is editor-only, so this asserts on the state a real `_refresh_owner` leaves behind and on the
# `_curve_swapped` decision — never on arms it made itself. The terrain is in memory; no data_directory.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/SiblingRefreshGate.tscn
extends Node

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== SiblingRefreshGate ===\n")
	_terrain = Pasture3D.new()
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	_a_covered_sibling_dropped()
	_b_rearmed_sibling_kept()
	_c_content_edit_is_not_a_swap()
	print("\n  criteria completed: %d (want 3)" % _ran)
	if _ran != 3:
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["SIBLING REFRESH PASS" if _fail == 0 else "SIBLING REFRESH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s: %s" % ["  " if p_ok else "!!", p_label, p_detail])


func _mound(p_name: String) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	add_child(m)
	m.terrain = _terrain
	return m


## Put a brush in the state a real scheduler leaves: a live timer, a dirty flag, and a bumped generation.
func _pend(p_m: Pasture3DMound) -> void:
	p_m._timer = get_tree().create_timer(60.0)
	p_m._timer.timeout.connect(p_m._on_refresh_timer)
	p_m._full_dirty = true
	p_m._arm_gen += 1


func _a_covered_sibling_dropped() -> void:
	print("[A] a pending layer-mate is dropped by a full layer bake")
	var a := _mound("A_bake")
	var b := _mound("A_mate")
	var other := _mound("A_other")
	other._layer_owner = "pasture3d_brush:SomewhereElse"
	var sibs := a._tools_on_owner(a._layer_owner)
	_check("fixture", sibs.has(b) and not sibs.has(other),
			"A's layer holds its mate (%s) and not the other-layer brush (%s)" % [sibs.has(b), sibs.has(other)])
	_pend(b)
	_pend(other)
	a._refresh_owner(a._layer_owner, false, [])
	_check("dropped", not is_instance_valid(b._timer) and not b._full_dirty,
			"mate timer live=%s full_dirty=%s (want false/false)" % [is_instance_valid(b._timer), b._full_dirty])
	# CONTROL: a brush on another layer was not repainted, so its refresh must survive — otherwise the drop
	# is just "cancel everything", which would pass the line above too.
	_check("control", is_instance_valid(other._timer) and other._full_dirty,
			"other-layer timer live=%s full_dirty=%s (want true/true)" % [is_instance_valid(other._timer), other._full_dirty])
	for m in [a, b, other]:
		m._cancel_refresh_timer()
		m.queue_free()
	_ran += 1


func _b_rearmed_sibling_kept() -> void:
	print("[B] a layer-mate re-armed DURING the bake keeps its refresh")
	var a := _mound("B_bake")
	var b := _mound("B_mate")
	_pend(b)
	# `baked` is emitted inside `_refresh_owner`, after the paint and before the drop — the same window in
	# which `_rebake_if_corridor_outgrew` re-arms a road.
	var rearmed := [false]
	var rearm := func() -> void:
		b._arm_gen += 1
		rearmed[0] = true
	a.baked.connect(rearm, CONNECT_ONE_SHOT)
	a._refresh_owner(a._layer_owner, false, [])
	_check("fixture", rearmed[0], "the mid-bake re-arm actually ran (%s)" % rearmed[0])
	_check("kept", is_instance_valid(b._timer) and b._full_dirty,
			"mate timer live=%s full_dirty=%s (want true/true)" % [is_instance_valid(b._timer), b._full_dirty])
	for m in [a, b]:
		m._cancel_refresh_timer()
		m.queue_free()
	_ran += 1


func _c_content_edit_is_not_a_swap() -> void:
	print("[C] a curve content edit is not a swap; a real swap still rebinds")
	var m := _mound("C_brush")
	var p := Path3D.new()
	p.curve = Curve3D.new()
	p.curve.add_point(Vector3.ZERO)
	p.curve.add_point(Vector3(10, 0, 0))
	m.add_child(p)
	m._connect_spline(p)
	# CONTROL: a path with no relay reads as swapped, so `false` below is a decision, not a constant.
	var loose := Path3D.new()
	loose.curve = Curve3D.new()
	_check("control", m._curve_swapped(loose), "an unbound path reads as swapped")
	p.curve.set_point_position(1, Vector3(12, 0, 0))
	_check("content edit", not m._curve_swapped(p), "moving a point is not a swap")
	var fresh := Curve3D.new()
	p.curve = fresh # emits curve_changed -> _on_path_curve_changed must still rebind
	var relay = m._spline_relays.get(p.get_instance_id())
	_check("swap rebinds", relay != null and relay.curve == fresh and not m._curve_swapped(p),
			"after assigning a new Curve3D the relay listens to it")
	loose.free()
	m.queue_free()
	_ran += 1
