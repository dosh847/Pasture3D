extends Node
## Pasture3D.base_height: the height of unsculpted ground (Pasture3DData::set_base_height).
##
## Criteria, each with a control that must fail:
##   [N] A new region starts at the base height, all of it. Control: the same check on a base-0 terrain.
##   [S] Changing it moves a single-layer terrain (Base aliases the region map) by the difference,
##       sculpted cells included. Control: the same expectations before the change.
##   [U] With layers above, it moves the Base and re-blends: ADD rides the ground, MAX keeps its height
##       where it wins, and a change back restores every cell exactly. Control: the MAX cell expected to move.
##   [L] A region unloaded during a change catches up when it loads, and loads once more without a second
##       shift. Control: its file on disk still holds the old heights, so the move happened at load.
##   [F] A new Pasture3D opening the saved directory at the same base reads it unchanged; at base 0 it moves
##       it back up. Control: the base-0 terrain expected to read the saved heights.
## Runs headless:
##   Godot --headless --path project res://bench/BaseHeightGate.tscn

const DIR := "user://base_height_gate"
const RS := 64
const CRITERIA := 5

var _failures := 0
var _completed := 0


func _ready() -> void:
	print("=== BaseHeightGate ===")
	_wipe_dir()
	_criterion_n()
	_criterion_s()
	_criterion_u()
	await _criterion_l()
	_criterion_f()
	if _completed != CRITERIA:
		_fail("only %d of %d criteria ran to the end" % [_completed, CRITERIA])
	print("=== BASE HEIGHT %s (%d failures, %d/%d criteria) ===" % [
		"PASS" if _failures == 0 else "FAIL", _failures, _completed, CRITERIA])
	get_tree().quit(0 if _failures == 0 else 1)


func _fail(p_msg: String) -> void:
	_failures += 1
	printerr("  FAIL ", p_msg)


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["ok  " if p_ok else "FAIL", p_msg])
	if not p_ok:
		_failures += 1


func _terrain(p_base: float, p_dir := "") -> Node:
	var t = ClassDB.instantiate("Pasture3D")
	t.base_height = p_base # Before the tree, as a scene sets it
	if p_dir != "":
		t.data_directory = p_dir
	add_child(t)
	if p_dir == "":
		t.change_region_size(RS)
	return t


func _h(p_t: Node, p_x: float, p_z: float) -> float:
	return p_t.data.get_height(Vector3(p_x, 0.0, p_z))


## Min and max of a region's height map.
func _range(p_t: Node, p_loc: Vector2i) -> Vector2:
	var img: Image = p_t.data.get_region(p_loc).get_height_map()
	var lo := INF
	var hi := -INF
	for y in img.get_height():
		for x in img.get_width():
			var v := img.get_pixel(x, y).r
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return Vector2(lo, hi)


func _criterion_n() -> void:
	print("[N] a new region starts at the base height")
	var t = _terrain(-30.0)
	t.data.add_region_blank(Vector2i(0, 0))
	var r := _range(t, Vector2i(0, 0))
	_check(r == Vector2(-30, -30), "every cell at -30 (range %s)" % r)
	_check(is_equal_approx(_h(t, 10, 10), -30.0), "get_height answers -30 (%s)" % _h(t, 10, 10))
	t.free()
	var c = _terrain(0.0)
	c.data.add_region_blank(Vector2i(0, 0))
	_check(_range(c, Vector2i(0, 0)) != Vector2(-30, -30), "CONTROL a base-0 terrain's new region is not at -30")
	c.free()
	_completed += 1


func _criterion_s() -> void:
	print("[S] a single-layer terrain moves by the difference")
	var t = _terrain(0.0)
	t.data.add_region_blank(Vector2i(0, 0))
	t.data.set_height(Vector3(10, 0, 10), 7.0)
	_check(t.data.get_layer_stack_size() <= 1, "WITNESS one layer: the Base aliases the map (%d)" % t.data.get_layer_stack_size())
	var expect := func() -> bool: return is_equal_approx(_h(t, 10, 10), -23.0) and is_equal_approx(_h(t, 30, 30), -30.0)
	_check(not expect.call(), "CONTROL before the change the sculpt reads 7 and the ground 0")
	t.base_height = -30.0
	_check(expect.call(), "after: sculpt -23, ground -30 (%s, %s)" % [_h(t, 10, 10), _h(t, 30, 30)])
	_check(t.data.get_region(Vector2i(0, 0)).is_modified(), "the region is marked to save")
	_check(t.data.get_height_range().x <= -30.0, "the height range follows (%s)" % t.data.get_height_range())
	t.free()
	_completed += 1


func _criterion_u() -> void:
	print("[U] layers above re-blend over the moved Base")
	var t = _terrain(0.0)
	var d = t.data
	d.add_region_blank(Vector2i(0, 0))
	var max_id: int = d.create_owned_layer("gate:max", "Max", Pasture3DLayer.MAX)
	var add_id: int = d.create_owned_layer("gate:add", "Add", Pasture3DLayer.ADD)
	d.set_height_on_layer(max_id, Vector3(20, 0, 20), 5.0)
	d.add_height_on_layer(add_id, Vector3(40, 0, 40), 2.0)
	var before := [_h(t, 20, 20), _h(t, 40, 40), _h(t, 50, 10)]
	_check(before == [5.0, 2.0, 0.0], "WITNESS max 5, add +2, ground 0 (%s)" % [before])
	t.base_height = -30.0
	_check(is_equal_approx(_h(t, 50, 10), -30.0), "the ground moves to -30 (%s)" % _h(t, 50, 10))
	_check(is_equal_approx(_h(t, 40, 40), -28.0), "ADD rides it: -28 (%s)" % _h(t, 40, 40))
	_check(is_equal_approx(_h(t, 20, 20), 5.0), "MAX keeps 5 where it wins (%s)" % _h(t, 20, 20))
	_check(not is_equal_approx(_h(t, 20, 20), -25.0), "CONTROL the MAX cell did not move with the ground")
	t.base_height = 0.0
	var back := [_h(t, 20, 20), _h(t, 40, 40), _h(t, 50, 10)]
	_check(back == before, "back to 0 restores every cell exactly (%s)" % [back])
	t.free()
	_completed += 1


func _criterion_l() -> void:
	print("[L] an unloaded region catches up when it loads")
	_wipe_dir()
	var t = _terrain(0.0)
	t.data_directory = DIR
	var d = t.data
	d.add_region_blank(Vector2i(0, 0), false)
	d.add_region_blank(Vector2i(1, 0), false)
	d.update_maps()
	d.set_height(Vector3(RS + 10, 0, 10), 4.0)
	d.save_directory(DIR)
	d.unload_region(Vector2i(1, 0), true)
	t.base_height = -30.0
	_check(is_equal_approx(_h(t, 10, 10), -30.0), "the loaded region moved now (%s)" % _h(t, 10, 10))
	var file: Pasture3DRegion = ResourceLoader.load(DIR + "/pasture3d_01_00.res", "",
			ResourceLoader.CACHE_MODE_IGNORE)
	_check(file != null and is_equal_approx(file.get_height_map().get_pixel(10, 10).r, 4.0),
		"CONTROL the unloaded region's file still holds 4")
	d.load_region(Vector2i(1, 0), DIR, true)
	_check(is_equal_approx(_h(t, RS + 10, 10), -26.0) and is_equal_approx(_h(t, RS + 30, 30), -30.0),
		"it loads moved: sculpt -26, ground -30 (%s, %s)" % [_h(t, RS + 10, 10), _h(t, RS + 30, 30)])
	d.save_directory(DIR)
	d.unload_region(Vector2i(1, 0), true)
	d.load_region(Vector2i(1, 0), DIR, true)
	_check(is_equal_approx(_h(t, RS + 10, 10), -26.0), "saved and reloaded, it is not moved twice (%s)" % _h(t, RS + 10, 10))
	t.free()
	await get_tree().process_frame
	_completed += 1


func _criterion_f() -> void:
	print("[F] a new Pasture3D opens the saved directory")
	var same = _terrain(-30.0, DIR)
	_check(is_equal_approx(_h(same, RS + 10, 10), -26.0) and is_equal_approx(_h(same, 10, 10), -30.0),
		"at the same base it reads unchanged (%s, %s)" % [_h(same, RS + 10, 10), _h(same, 10, 10)])
	same.free()
	var zero = _terrain(0.0, DIR)
	_check(is_equal_approx(_h(zero, RS + 10, 10), 4.0) and is_equal_approx(_h(zero, 10, 10), 0.0),
		"at base 0 it moves back up (%s, %s)" % [_h(zero, RS + 10, 10), _h(zero, 10, 10)])
	_check(not is_equal_approx(_h(zero, RS + 10, 10), -26.0), "CONTROL base 0 does not read the saved -26")
	zero.free()
	_completed += 1


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)
