# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RU — phase 0 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: unload_region, the region index, and
# the layer slice matched by uid.
#
# The claim under test is that unloading is LOSSLESS and is not DELETION. So every criterion compares what
# comes back from disk against what went out, and each one carries a control that shows the comparison
# could have failed: a byte flip the round-trip compare must see, a disk read taken before the unload that
# must NOT hold the dirty edit, a restore with fresh generations that must touch the region the guarded
# one skipped.
#
# WHAT THIS DOES NOT COVER: the C++ editor undo (Pasture3DEditor::_apply_undo) needs the editor plugin and
# cannot run headless. Its generation guard shares the rule tested here through restore_layer_tiles, which
# is what the GDScript undo paths (bake undo, layer Clear) now call.
#
# Data lives in a per-gate user:// directory, wiped at start. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionUnloadGate.tscn
extends Node

const DIR := "user://region_unload_gate"
const R0 := Vector2i(0, 0)
const R1 := Vector2i(1, 0)
const R2 := Vector2i(0, 1)
const ADD := 1 # Pasture3DLayer.BlendMode.ADD

## Probe points in R0 (region_size 256, vertex_spacing 1: world == pixel).
const P1 := Vector3(40.0, 0.0, 40.0) # L1 writes here
const P2 := Vector3(120.0, 0.0, 90.0) # L2 writes here
const P3 := Vector3(200.0, 0.0, 30.0) # L2 undo probe in R0
const P4 := Vector3(300.0, 0.0, 60.0) # L2 undo probe in R1

var _fail := 0
## A criterion that errors abandons its function without counting a failure; the verdict needs all of them.
const GATES := 7
var _completed := 0
var _terrain


func _ready() -> void:
	print("\n=== Region unload (gate RU, streaming phase 0) ===\n")
	_wipe_dir()
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [R0, R1, R2]:
		d.add_region_blank(loc, false)
	d.update_maps()
	# Base-only (single-layer, aliased) terrain first.
	d.set_height(Vector3(10, 0, 10), 3.0)
	d.set_height(Vector3(260, 0, 10), 4.0)
	d.save_directory(DIR)

	_ru1_single_layer_round_trip()
	_ru2_dirty_unload_auto_saves()
	_ru3_layered_round_trip()
	_ru4_layer_removed_while_unloaded()
	_ru5_undo_skips_reloaded_region()
	_ru6_remove_region_still_deletes()
	_ru7_index_persists_and_unconfigured_refuses()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION UNLOAD PASS" if ok else "REGION UNLOAD FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RU1: unload + reload of a Base-only region is byte-identical ---------------------------------------
func _ru1_single_layer_round_trip() -> void:
	print("[RU1] single-layer unload/reload round-trips byte-identical:")
	var d = _terrain.data
	var before := _region_bytes(R0)
	var gen0: int = d.get_region_generation(R0)
	_check("unload returns OK", d.unload_region(R0) == OK)
	_check("region is not loaded after unload", not d.is_region_loaded(R0) and d.get_region(R0) == null)
	_check("region left region_locations", not d.get_region_locations().has(R0))
	_check("unload bumped the generation", d.get_region_generation(R0) == gen0 + 1)
	_check("region file kept on disk", FileAccess.file_exists(_path(R0)))
	_check("reload returns OK", d.load_region(R0, DIR) == OK)
	var after := _region_bytes(R0)
	_check("height/control/color bytes identical", before == after)
	# Control: the compare must see a one-pixel change.
	var img: Image = d.get_region(R0).get_height_map()
	var old := img.get_pixel(5, 5)
	img.set_pixel(5, 5, Color(old.r + 1.0, 0, 0, 1))
	_check("control: compare detects a one-pixel change", _region_bytes(R0) != before)
	img.set_pixel(5, 5, old)
	_completed += 1


# --- RU2: unloading a dirty region saves it first ------------------------------------------------------
func _ru2_dirty_unload_auto_saves() -> void:
	print("[RU2] dirty unload auto-saves:")
	var d = _terrain.data
	d.set_height(Vector3(270, 0, 20), 42.0)
	_check("edit marks the region modified", d.get_region(R1).is_modified())
	# Control: the file on disk does NOT yet hold the edit, so anything that reads it later got it from
	# the unload's save and not from an earlier one.
	_check("control: disk copy lacks the edit before unload", not is_equal_approx(_disk_height(R1, Vector2i(14, 20)), 42.0))
	_check("unload returns OK", d.unload_region(R1) == OK)
	_check("disk copy holds the edit after unload", is_equal_approx(_disk_height(R1, Vector2i(14, 20)), 42.0))
	d.load_region(R1, DIR)
	_check("reloaded region holds the edit", is_equal_approx(d.get_height(Vector3(270, 0, 20)), 42.0))
	_check("reloaded region is not modified", not d.get_region(R1).is_modified())
	_completed += 1


# --- RU3: with overlay layers, region maps AND every layer's tiles round-trip ---------------------------
func _ru3_layered_round_trip() -> void:
	print("[RU3] layered unload/reload round-trips region and layer tiles:")
	var d = _terrain.data
	var l1: int = d.layer_add("L1", ADD)
	var l2: int = d.layer_add("L2", ADD)
	_check("two overlay layers added", l1 == 1 and l2 == 2)
	d.set_height_on_layer(l1, P1, 5.0)
	d.set_height_on_layer(l2, P2, 7.0)
	d.set_height_on_layer(l2, P4, 1.0) # R1 coverage too, for RU5
	d.update_maps()
	d.save_directory(DIR)
	var stack = d.get_layer_stack()
	var before_region := _region_bytes(R0)
	var before_layers := _layer_bytes(R0)
	_check("every layer covers R0 before unload", _covering_count(R0) == 3)
	_check("unload returns OK", d.unload_region(R0) == OK)
	_check("layer tiles evicted on unload", _covering_count(R0) == 0)
	_check("layer slice written", FileAccess.file_exists(DIR + "/" + Pasture3DUtil.location_to_layer_filename(R0)))
	_check("reload returns OK", d.load_region(R0, DIR) == OK)
	_check("region bytes identical", _region_bytes(R0) == before_region)
	_check("layer tile bytes identical", _layer_bytes(R0) == before_layers)
	# Control: the layer compare must see a changed tile.
	var t: Image = stack.get_layer(l2).get_tiles()[R0].values()[0]
	var c := t.get_pixel(0, 0)
	t.set_pixel(0, 0, Color(c.r + 1.0, c.g, 0, 1))
	_check("control: layer compare detects a changed tile", _layer_bytes(R0) != before_layers)
	t.set_pixel(0, 0, c)
	_completed += 1


# --- RU4: a layer removed while its region is unloaded ----------------------------------------------------
# The slice on disk still names L1. Matching by index would hand L1's tiles to L2 (now at index 1); matching
# by uid drops them. And the composite on disk still includes L1, so the load must recomposite.
func _ru4_layer_removed_while_unloaded() -> void:
	print("[RU4] layer removed while unloaded: uid match + recomposite on load:")
	var d = _terrain.data
	var base_p1: float = d.get_layer_height(0, P1)
	var base_p2: float = d.get_layer_height(0, P2)
	# Control: L1 contributes at P1 now.
	_check("control: P1 carries L1's +5 before", is_equal_approx(d.get_height(P1), base_p1 + 5.0))
	var sig_before: int = d.get_region_index().get_entry(R0).get("stack_signature", 0)
	_check("unload returns OK", d.unload_region(R0) == OK)
	d.layer_remove(1)
	_check("reload returns OK", d.load_region(R0, DIR) == OK)
	var stack = d.get_layer_stack()
	var l2 = stack.get_layer(1)
	_check("index 1 is L2", l2 != null and l2.get_layer_name() == "L2")
	_check("L2 got its own tiles back (P2 covered)", is_equal_approx(l2.get_weight(R0, Vector2i(120, 90)), 1.0))
	_check("L2 did not get L1's tiles (P1 uncovered)", is_zero_approx(l2.get_weight(R0, Vector2i(40, 40))))
	_check("recomposited: P1 no longer carries +5", is_equal_approx(d.get_height(P1), base_p1))
	_check("recomposited: P2 still carries +7", is_equal_approx(d.get_height(P2), base_p2 + 7.0))
	# The entry describes the FILE: the recomposite is in memory only, so the entry keeps the old signature
	# and the region is flagged for the save that will bring the file up to date.
	_check("recomposited region is modified", d.get_region(R0).is_modified())
	_check("entry still describes the file", d.get_region_index().get_entry(R0).get("stack_signature", 0) == sig_before)
	d.save_directory(DIR)
	_check("after save the entry follows the stack", d.get_region_index().get_entry(R0).get("stack_signature", 0) != sig_before)
	# Control: an unload/reload with no stack change does not recomposite, so nothing is left modified.
	d.unload_region(R0)
	d.load_region(R0, DIR)
	_check("control: unchanged stack reloads unmodified", not d.get_region(R0).is_modified())
	_completed += 1


# --- RU5: an undo snapshot skips a region unloaded and reloaded since ------------------------------------
func _ru5_undo_skips_reloaded_region() -> void:
	print("[RU5] restore_layer_tiles skips a region whose generation moved on:")
	var d = _terrain.data
	var l2 = d.get_layer_stack().get_layer(1)
	var snap := _copy_tiles(l2.get_tiles())
	var gens: Dictionary = d.get_region_generations()
	d.set_height_on_layer(1, P3, 11.0)
	d.set_height_on_layer(1, P4, 13.0)
	d.unload_region(R1)
	d.load_region(R1, DIR)
	_check("R1 edit survived its unload", is_equal_approx(d.get_layer_height(1, P4), 13.0))
	var changed: Array = d.restore_layer_tiles(1, snap, gens)
	_check("only R0 restored", changed.size() == 1 and changed.has(R0) and not changed.has(R1))
	_check("R0 edit reverted", is_zero_approx(l2.get_weight(R0, Vector2i(200, 30))))
	_check("R1 edit kept", is_equal_approx(d.get_layer_height(1, P4), 13.0))
	# Control: with generations taken now, the same snapshot does reach R1.
	var changed2: Array = d.restore_layer_tiles(1, snap, d.get_region_generations())
	_check("control: current generations restore R1", changed2.has(R1) and is_equal_approx(d.get_layer_height(1, P4), 1.0))
	_completed += 1


# --- RU6: remove_region still deletes; unload does not ----------------------------------------------------
func _ru6_remove_region_still_deletes() -> void:
	print("[RU6] remove_region deletes on save, unload does not:")
	var d = _terrain.data
	d.set_height_on_layer(1, Vector3(20, 0, 300), 2.0) # a slice for R2
	d.save_directory(DIR)
	_check("R2 slice exists before", FileAccess.file_exists(DIR + "/" + Pasture3DUtil.location_to_layer_filename(R2)))
	d.remove_regionl(R2)
	_check("unloading a region marked for deletion is refused", d.unload_region(R2) == ERR_BUSY)
	d.save_directory(DIR)
	_check("R2 region file deleted", not FileAccess.file_exists(_path(R2)))
	_check("R2 layer slice deleted", not FileAccess.file_exists(DIR + "/" + Pasture3DUtil.location_to_layer_filename(R2)))
	_check("R2 index entry erased", not d.get_region_index().has_entry(R2))
	# Control: an unloaded region's file stays.
	d.unload_region(R1)
	_check("control: unloaded R1 file kept", FileAccess.file_exists(_path(R1)))
	_check("control: unloaded R1 index entry kept", d.get_region_index().has_entry(R1))
	d.load_region(R1, DIR)
	_completed += 1


# --- RU7: the index is on disk; a data-dir-less terrain refuses to unload ---------------------------------
func _ru7_index_persists_and_unconfigured_refuses() -> void:
	print("[RU7] region index persists; no data directory refuses:")
	var d = _terrain.data
	d.save_directory(DIR)
	var path := DIR + "/pasture3d_region_index.res"
	_check("index file exists", FileAccess.file_exists(path))
	var idx = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("index loads", idx != null)
	if idx:
		var locs: Array = idx.get_locations()
		_check("index holds R0 and R1, not R2", locs.has(R0) and locs.has(R1) and not locs.has(R2))
		var e: Dictionary = idx.get_entry(R0)
		_check("R0 height_range matches the region", e.get("height_range") == d.get_region(R0).get_height_range())
		_check("R0 stack_signature recorded", int(e.get("stack_signature", 0)) != 0)
	# A fresh terrain reading the same directory sees the same index.
	var t2 = ClassDB.instantiate("Pasture3D")
	add_child(t2)
	t2.data_directory = DIR
	_check("fresh terrain loads the index", t2.data.get_region_index().has_entry(R0) and t2.data.get_region_index().has_entry(R1))
	_check("fresh terrain sees L2 at P2", is_equal_approx(t2.data.get_height(P2), d.get_height(P2)))
	t2.queue_free()
	# No data directory: unloading would destroy the region, so it must refuse and keep it.
	var t3 = ClassDB.instantiate("Pasture3D")
	add_child(t3)
	t3.data.add_region_blank(R0)
	_check("unload without a data directory refused", t3.data.unload_region(R0) == ERR_UNCONFIGURED)
	_check("and the region stays loaded", t3.data.is_region_loaded(R0))
	t3.queue_free()
	_completed += 1


# --- helpers -------------------------------------------------------------------------------------------

func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _path(p_loc: Vector2i) -> String:
	return DIR + "/" + Pasture3DUtil.location_to_filename(p_loc)


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)


func _region_bytes(p_loc: Vector2i) -> Array:
	var r = _terrain.data.get_region(p_loc)
	if r == null:
		return []
	return [r.get_height_map().get_data(), r.get_control_map().get_data(), r.get_color_map().get_data()]


## Every layer's tiles in one region, in stack order, as [name, coord, bytes] triples sorted by coord.
func _layer_bytes(p_loc: Vector2i) -> Array:
	var out := []
	var stack = _terrain.data.get_layer_stack()
	for i in stack.get_layer_count():
		var l = stack.get_layer(i)
		var tiles: Dictionary = l.get_tiles().get(p_loc, {})
		var coords := tiles.keys()
		coords.sort()
		for c in coords:
			out.append([l.get_layer_name(), c, (tiles[c] as Image).get_data()])
	return out


func _covering_count(p_loc: Vector2i) -> int:
	var n := 0
	var stack = _terrain.data.get_layer_stack()
	for i in stack.get_layer_count():
		if stack.get_layer(i).has_region(p_loc):
			n += 1
	return n


func _disk_height(p_loc: Vector2i, p_px: Vector2i) -> float:
	if not FileAccess.file_exists(_path(p_loc)):
		return NAN
	var r = ResourceLoader.load(_path(p_loc), "", ResourceLoader.CACHE_MODE_IGNORE)
	return r.get_height_map().get_pixelv(p_px).r if r else NAN


func _copy_tiles(p_tiles: Dictionary) -> Dictionary:
	var out := {}
	for loc in p_tiles:
		var inner := {}
		for c in p_tiles[loc]:
			inner[c] = (p_tiles[loc][c] as Image).duplicate()
		out[loc] = inner
	return out
