# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushGate — phase 1 of PASTURE3D_LAYER_BRUSH_SPEC.md: identity and membership, no stack.
#
#   [A] a Layer brush makes its base row directly beneath its main row, both named after the node;
#       control: a plain brush's layer is not under the Layer brush prefix
#   [C] renaming the node renames both rows; members keep the same owner (uid, not name)
#   [D] a child brush is assigned the main row; a road brush child is not; control: a sibling outside keeps its own
#   [E] assigning a member elsewhere is refused and recorded; control: the same call on a non-member succeeds
#   [F] assigning a non-member to the Layer's row is refused
#   [J] moving a brush out of the Layer gives it a free layer; moving it in joins, neither is an error
#   [Q] a duplicated Layer brush takes a fresh uid and its own rows
#   [R] unit moves carry the pair together, and their inverse restores the exact order; delete removes both
#       rows and re-entering restores the same objects
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushGate.tscn
extends Node

const CRITERIA := 8

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== LayerBrushGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = 64
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	for f in [_a, _c, _d, _e, _f, _j, _q, _r]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER BRUSH %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _stack() -> Pasture3DLayerStack:
	return _terrain.data.get_layer_stack()


func _idx(p_owner: String) -> int:
	return _stack().find_layer_by_owner(p_owner)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _layer_brush(p_name: String) -> Pasture3DLayerBrush:
	var lb := Pasture3DLayerBrush.new()
	lb.name = p_name
	lb.terrain = _terrain
	_terrain.add_child(lb)
	return lb


func _mound(p_parent: Node, p_name: String) -> Pasture3DTerrainBrush:
	var m: Pasture3DTerrainBrush = Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	p_parent.add_child(m)
	return m


func _a() -> void:
	var lb := _layer_brush("Hills")
	var plain := _mound(_terrain, "Plain")
	await _settle()
	var b := _idx(lb.base_owner_id())
	var m := _idx(lb.layer_owner_id())
	var names_ok := b >= 0 and m >= 0 and _stack().get_layer(b).get_layer_name() == "Hills" \
			and _stack().get_layer(m).get_layer_name() == "Hills"
	_check("A rows", b >= 0 and m == b + 1 and names_ok, "base %d main %d" % [b, m])
	_check("A control", not plain._layer_owner.begins_with(Pasture3DTerrainBrush.LAYER_BRUSH_OWNER_PREFIX),
			"plain owner %s" % plain._layer_owner)
	plain.free()
	lb.free()
	_ran += 1


func _c() -> void:
	var lb := _layer_brush("Before")
	var kid := _mound(lb, "Kid")
	await _settle()
	var owner := kid._layer_owner
	lb.name = "After"
	await _settle()
	var ok := _stack().get_layer(_idx(lb.base_owner_id())).get_layer_name() == "After" \
			and _stack().get_layer(_idx(lb.layer_owner_id())).get_layer_name() == "After"
	_check("C rename", ok and kid._layer_owner == owner, "rows renamed %s, owner kept %s" % [ok, kid._layer_owner == owner])
	lb.free()
	_ran += 1


func _d() -> void:
	var lb := _layer_brush("Group")
	var kid := _mound(lb, "Kid")
	var road := Pasture3DRoadBrush.new()
	road.name = "Road"
	road.terrain = _terrain
	road.auto_refresh = false
	lb.add_child(road)
	var outside := _mound(_terrain, "Outside")
	await _settle()
	_check("D member", kid._layer_owner == lb.layer_owner_id(), kid._layer_owner)
	_check("D road not member", road._layer_owner != lb.layer_owner_id() and lb.member_count() == 1,
			"road %s, members %d" % [road._layer_owner, lb.member_count()])
	_check("D control", outside._layer_owner != lb.layer_owner_id(), outside._layer_owner)
	outside.free()
	lb.free()
	_ran += 1


func _e() -> void:
	var lb := _layer_brush("Strict")
	var kid := _mound(lb, "Kid")
	var free := _mound(_terrain, "Free")
	await _settle()
	var target := Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX + "Elsewhere"
	kid._set_layer_owner(target)
	_check("E refused", kid._layer_owner == lb.layer_owner_id() and lb.violations().size() == 1,
			"owner %s, violations %d" % [kid._layer_owner, lb.violations().size()])
	free._set_layer_owner(target)
	_check("E control", free._layer_owner == target, free._layer_owner)
	free.free()
	lb.free()
	_ran += 1


func _f() -> void:
	var lb := _layer_brush("Closed")
	var stranger := _mound(_terrain, "Stranger")
	await _settle()
	var before := stranger._layer_owner
	stranger._set_layer_owner(lb.layer_owner_id())
	_check("F refused", stranger._layer_owner == before and lb.violations().size() == 1,
			"owner %s, violations %d" % [stranger._layer_owner, lb.violations().size()])
	stranger.free()
	lb.free()
	_ran += 1


func _j() -> void:
	var lb := _layer_brush("Moves")
	var kid := _mound(lb, "Kid")
	var other := _mound(_terrain, "Other")
	await _settle()
	kid.reparent(_terrain)
	other.reparent(lb)
	await _settle()
	var out_ok := kid._layer_owner.begins_with(Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX)
	var in_ok := other._layer_owner == lb.layer_owner_id()
	_check("J tree moves", out_ok and in_ok and lb.violations().is_empty(),
			"out %s in %s violations %d" % [kid._layer_owner, other._layer_owner, lb.violations().size()])
	kid.free()
	lb.free()
	_ran += 1


func _q() -> void:
	var lb := _layer_brush("Orig")
	_mound(lb, "Kid")
	await _settle()
	var dup: Pasture3DLayerBrush = lb.duplicate()
	dup.name = "Copy"
	_terrain.add_child(dup)
	await _settle()
	var kid2: Pasture3DTerrainBrush = dup.get_node("Kid")
	var ok := dup._layer_uid != lb._layer_uid and _idx(dup.layer_owner_id()) >= 0 \
			and _idx(dup.base_owner_id()) == _idx(dup.layer_owner_id()) - 1 \
			and kid2._layer_owner == dup.layer_owner_id()
	_check("Q duplicate", ok, "uids %s/%s, copy kid %s" % [lb._layer_uid, dup._layer_uid, kid2._layer_owner])
	dup.free()
	lb.free()
	_ran += 1


func _r() -> void:
	# Fresh stack order: Base, X, pair(P), Y.
	var d := _terrain.data
	var x: int = d.layer_add_typed("X", Pasture3DLayer.REPLACE, 0)
	var lb := _layer_brush("P")
	await _settle()
	var y: int = d.layer_add_typed("Y", Pasture3DLayer.REPLACE, 0)
	var st := _stack()
	var start: Array = st.get_layers().duplicate()
	var p := _idx(lb.layer_owner_id())
	# DOWN past X: two steps (base, then main), so a forward replay of the inverses is distinguishable.
	var steps := Pasture3DLayerBrush.unit_move_steps(st, p, -1)
	Pasture3DLayerBrush.apply_steps(d, steps)
	var up_ok := _idx(lb.base_owner_id()) == x and _idx(lb.layer_owner_id()) == x + 1 \
			and st.get_layer(x + 2).get_layer_name() == "X"
	Pasture3DLayerBrush.apply_steps(d, steps, true)
	var restored := st.get_layers() == start
	# Control: replaying the inverse FORWARD must not restore (else the reverse order is untested).
	Pasture3DLayerBrush.apply_steps(d, steps)
	for s in steps:
		d.layer_move(int(s[1]), int(s[0]))
	var forward_differs := st.get_layers() != start
	st.set_layers(start.duplicate())
	_check("R pair move", up_ok and restored and forward_differs and steps.size() > 1,
			"moved %s restored %s control %s steps %d" % [up_ok, restored, forward_differs, steps.size()])

	var base_obj := st.get_layer(_idx(lb.base_owner_id()))
	var count := st.get_layer_count()
	lb.detect_delete_headless = true
	_terrain.remove_child(lb)
	await _settle()
	var gone := _idx(lb.base_owner_id()) < 0 and _idx(lb.layer_owner_id()) < 0 and st.get_layer_count() == count - 2
	_terrain.add_child(lb)
	await _settle()
	var back := st.get_layers() == start and st.get_layer(_idx(lb.base_owner_id())) == base_obj
	_check("R delete/undo", gone and back, "removed %s restored %s" % [gone, back])
	lb.free()
	_ran += 1
