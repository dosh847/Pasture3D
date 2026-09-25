# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RS — phase 1 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: stable texture-array slots and the
# sparse region map.
#
# The claim is about COST and IDENTITY. Loading one region must upload one layer per map type and recreate
# nothing, and every other region must keep its slot. So the criteria read Pasture3DData's upload counters
# and slot table, and each carries a control: a full rebuild must show up in the same counters, and a slot
# table compare must see a moved slot.
#
# WHAT THIS DOES NOT COVER: rendering. The headless renderer compiles no shaders and draws nothing, so
# "a region at (±100, ±100) renders" is proven here only as far as the data reaching the GPU (the map
# texel, the slot table, the array image). bench/RegionSlotRenderProbe draws it, in a window.
#
# Data lives in a per-gate user:// directory, wiped at start; the demo data is COPIED there for RS8.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionSlotGate.tscn
extends Node

const DIR := "user://region_slot_gate"
const DEMO_COPY := "user://region_slot_gate_demo"
const DEMO_SRC := "res://demo/data/DemoPasture"
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const C := Vector2i(0, 1)
const D := Vector2i(-3, 2)

var _fail := 0
## A criterion that errors abandons its function without counting a failure; the verdict needs all of them.
const GATES := 8
var _completed := 0
var _terrain


func _ready() -> void:
	print("\n=== Region slots (gate RS, streaming phase 1) ===\n")
	print("region_map_size = %d" % Pasture3DData.get_region_map_size())
	_wipe(DIR)
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [A, B, C]:
		d.add_region_blank(loc, false)
	d.update_maps()
	d.set_height(Vector3(10, 0, 10), 3.0)
	d.save_directory(DIR)

	_rs1_one_layer_per_load()
	_rs2_slots_are_stable()
	_rs3_capacity_grows_in_chunks()
	_rs4_far_locations()
	_rs5_map_matches_slot_table()
	_rs6_remove_and_reorder()
	_rs7_array_holds_the_region()
	_rs8_demo_data_loads()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION SLOTS PASS" if ok else "REGION SLOTS FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RS1: a load uploads one layer per map type and recreates nothing -----------------------------------
func _rs1_one_layer_per_load() -> void:
	print("[RS1] unload/load cost:")
	var d = _terrain.data
	d.reset_upload_stats()
	d.unload_region(A)
	var s: Dictionary = d.get_upload_stats()
	_check("unload: 0 layer uploads (got %d)" % s.layer_uploads, s.layer_uploads == 0)
	_check("unload: 0 array creates (got %d)" % s.array_creates, s.array_creates == 0)
	_check("unload: 1 region map upload (got %d)" % s.region_map_uploads, s.region_map_uploads == 1)
	d.reset_upload_stats()
	d.load_region(A, DIR)
	s = d.get_upload_stats()
	_check("load: 3 layer uploads, one per map type (got %d)" % s.layer_uploads, s.layer_uploads == 3)
	_check("load: 0 array creates (got %d)" % s.array_creates, s.array_creates == 0)
	_check("load: 1 region map upload (got %d)" % s.region_map_uploads, s.region_map_uploads == 1)
	# Control: a full rebuild is visible in the same counters.
	d.reset_upload_stats()
	d.update_maps(3, true, false) # TYPE_MAX, all regions
	s = d.get_upload_stats()
	_check("control: a full rebuild counts 3 array creates (got %d)" % s.array_creates, s.array_creates == 3)
	_completed += 1


# --- RS2: other regions keep their slots; a freed slot is reused lowest-first ----------------------------
func _rs2_slots_are_stable() -> void:
	print("[RS2] slots are stable:")
	var d = _terrain.data
	var slot_a: int = d.get_region_id(A)
	var slot_b: int = d.get_region_id(B)
	var slot_c: int = d.get_region_id(C)
	_check("three distinct slots", slot_a >= 0 and slot_b >= 0 and slot_c >= 0 and slot_a != slot_b and slot_b != slot_c and slot_a != slot_c)
	var lowest: int = mini(slot_a, mini(slot_b, slot_c))
	var victim: Vector2i = A if slot_a == lowest else (B if slot_b == lowest else C)
	var before: Array = d.get_slot_locations()
	d.unload_region(victim)
	for loc in [A, B, C]:
		if loc != victim:
			_check("%s keeps slot %d" % [loc, before.find(loc)], d.get_region_id(loc) == before.find(loc))
	_check("victim's slot is free", d.get_region_id(victim) == -1)
	d.add_region_blank(D)
	_check("new region takes the lowest free slot (%d)" % lowest, d.get_region_id(D) == lowest)
	# Control: the slot-table compare sees a slot that DID change.
	_check("control: the slot table differs at the reused slot", d.get_slot_locations()[lowest] != before[lowest])
	d.remove_regionl(D)
	d.save_directory(DIR)
	d.load_region(victim, DIR)
	_completed += 1


# --- RS3: capacity grows by SLOT_CHUNK, and only growth recreates the arrays -----------------------------
func _rs3_capacity_grows_in_chunks() -> void:
	print("[RS3] capacity grows in chunks:")
	var d = _terrain.data
	var cap: int = d.get_slot_capacity()
	_check("capacity is one chunk (%d)" % cap, cap == 16)
	var added: Array[Vector2i] = []
	var i := 0
	while d.get_region_count() < cap:
		var loc := Vector2i(5 + i % 8, -6 + i / 8)
		d.add_region_blank(loc, false)
		added.append(loc)
		i += 1
	d.update_maps(3, false, false)
	d.reset_upload_stats()
	d.add_region_blank(Vector2i(-8, -8))
	var s: Dictionary = d.get_upload_stats()
	_check("the 17th region grows capacity to 32 (got %d)" % d.get_slot_capacity(), d.get_slot_capacity() == 32)
	_check("growth recreates the 3 arrays (got %d)" % s.array_creates, s.array_creates == 3)
	d.reset_upload_stats()
	d.remove_regionl(Vector2i(-8, -8))
	s = d.get_upload_stats()
	_check("removal does not shrink or recreate (cap %d, creates %d)" % [d.get_slot_capacity(), s.array_creates], d.get_slot_capacity() == 32 and s.array_creates == 0)
	for loc in added:
		d.remove_regionl(loc, false)
	d.update_maps(3, false, false)
	d.save_directory(DIR)
	_completed += 1


# --- RS4: locations far beyond the old 32x32 map ---------------------------------------------------------
func _rs4_far_locations() -> void:
	print("[RS4] far locations (map size %d):" % Pasture3DData.get_region_map_size())
	var d = _terrain.data
	var half: int = Pasture3DData.get_region_map_size() / 2
	for loc in [Vector2i(100, 100), Vector2i(-100, -100), Vector2i(half - 1, -half)]:
		var r = d.add_region_blank(loc)
		_check("%s accepted" % loc, r != null and d.get_region_id(loc) >= 0)
		var world: Vector3 = Vector3(loc.x * 256 + 7, 0, loc.y * 256 + 9)
		d.set_height(world, 12.5)
		_check("%s height round-trips" % loc, is_equal_approx(d.get_height(world), 12.5))
	# Control: the edges of the map refuse.
	for loc in [Vector2i(half, 0), Vector2i(0, -half - 1), Vector2i(200, 200)]:
		_check("%s refused" % loc, d.add_region_blank(loc) == null)
	for loc in [Vector2i(100, 100), Vector2i(-100, -100), Vector2i(half - 1, -half)]:
		d.remove_regionl(loc, false)
	d.update_maps(3, false, false)
	_completed += 1


# --- RS5: the region map and the slot table agree texel for texel ----------------------------------------
func _rs5_map_matches_slot_table() -> void:
	print("[RS5] region map matches the slot table:")
	var d = _terrain.data
	_check("consistent after setup", _map_consistent())
	d.unload_region(B)
	_check("consistent after an unload (no stale texel)", _map_consistent())
	var idx: int = Pasture3DData.get_region_map_index(B)
	_check("unloaded location's texel is 0", d.get_region_map()[idx] == 0)
	d.load_region(B, DIR)
	_check("consistent after the reload", _map_consistent())
	# Control: the consistency check sees a corrupted texel.
	var m: PackedInt32Array = d.get_region_map()
	m[idx] = 0
	_check("control: a zeroed texel is detected", not _map_consistent(m))
	_completed += 1


# --- RS6: delete frees its slot; a reorder of region_locations moves nothing ------------------------------
func _rs6_remove_and_reorder() -> void:
	print("[RS6] remove frees, reorder moves nothing:")
	var d = _terrain.data
	var before: Array = d.get_slot_locations()
	var locs: Array = d.get_region_locations()
	locs.reverse()
	d.reset_upload_stats()
	d.set_region_locations(locs)
	var s: Dictionary = d.get_upload_stats()
	_check("reorder keeps every slot", d.get_slot_locations() == before)
	_check("reorder uploads no layers and creates nothing", s.layer_uploads == 0 and s.array_creates == 0)
	var slot_c: int = d.get_region_id(C)
	var locs_before: Array = d.get_region_locations()
	d.remove_regionl(C)
	_check("deleted region's slot is free", d.get_region_id(C) == -1 and d.get_slot_locations()[slot_c] != C)
	_check("map stays consistent", _map_consistent())
	# Undo of the delete, the way the editor does it (_apply_undo): un-mark, then restore region_locations.
	d.get_region(C).set_deleted(false)
	d.set_region_locations(locs_before)
	d.update_maps(3, false, false)
	_check("un-deleted region gets a slot back", d.get_region_id(C) >= 0)
	_completed += 1


# --- RS7: the array layer at a slot is that region's image ------------------------------------------------
func _rs7_array_holds_the_region() -> void:
	print("[RS7] the array at each slot holds its region:")
	var d = _terrain.data
	d.unload_region(A)
	d.add_region_blank(D) # takes A's freed slot
	var slot: int = d.get_region_id(D)
	_check("D's height map is the image at its slot", d.get_height_maps()[slot] == d.get_region(D).get_height_map())
	_check("B's height map is the image at its slot", d.get_height_maps()[d.get_region_id(B)] == d.get_region(B).get_height_map())
	# Control: the compare distinguishes regions.
	_check("control: B's image is not D's", d.get_region(B).get_height_map() != d.get_region(D).get_height_map())
	d.remove_regionl(D)
	d.load_region(A, DIR)
	_completed += 1


# --- RS8: the demo data (the old 32x32-era fixture) loads into slots unchanged ----------------------------
func _rs8_demo_data_loads() -> void:
	print("[RS8] demo data loads into slots:")
	_wipe(DEMO_COPY)
	var src := DirAccess.open(DEMO_SRC)
	for f in src.get_files():
		if f.ends_with(".res"):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(DEMO_SRC + "/" + f), ProjectSettings.globalize_path(DEMO_COPY + "/" + f))
	var t = ClassDB.instantiate("Pasture3D")
	add_child(t)
	t.data_directory = DEMO_COPY
	var d = t.data
	var locs: Array = d.get_region_locations()
	_check("demo regions loaded (%d)" % locs.size(), locs.size() > 0)
	var slots := {}
	for loc in locs:
		slots[d.get_region_id(loc)] = true
	_check("every region has its own slot", slots.size() == locs.size() and not slots.has(-1))
	_check("map consistent", _map_consistent(d.get_region_map(), d))
	var same := true
	for loc in locs:
		var r = ResourceLoader.load(DEMO_COPY + "/" + Pasture3DUtil.location_to_filename(loc), "", ResourceLoader.CACHE_MODE_IGNORE)
		if r == null:
			continue
		var world: Vector3 = Vector3(loc.x * t.region_size + 17, 0, loc.y * t.region_size + 23) * t.vertex_spacing
		var disk: float = r.get_height_map().get_pixel(17, 23).r
		if not is_equal_approx(d.get_height(world), disk) and not is_nan(d.get_height(world)):
			same = false
			print("    %s: %f vs disk %f" % [loc, d.get_height(world), disk])
	_check("heights read through the slots match the files", same)
	t.queue_free()
	_completed += 1


# --- helpers -------------------------------------------------------------------------------------------

func _map_consistent(p_map: PackedInt32Array = PackedInt32Array(), p_data = null) -> bool:
	var d = p_data if p_data else _terrain.data
	var m: PackedInt32Array = p_map if not p_map.is_empty() else d.get_region_map()
	var table: Array = d.get_slot_locations()
	var size: int = Pasture3DData.get_region_map_size()
	var seen := 0
	for i in m.size():
		if m[i] == 0:
			continue
		var slot: int = Pasture3DData.region_map_decode(m[i])
		var loc := Vector2i(i % size - size / 2, i / size - size / 2)
		if slot < 0 or slot >= table.size() or table[slot] != loc:
			return false
		seen += 1
	return seen == d.get_region_count()


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
