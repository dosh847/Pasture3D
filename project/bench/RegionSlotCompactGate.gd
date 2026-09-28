# Gate SC — phase 2 of PASTURE3D_BAKE_MEMORY_SPEC.md (M2): slot capacity shrinks when regions go away.
#
# Before M2 the texture arrays kept their peak capacity, every free slot a full-size placeholder: an
# All-regions bake left 3 GB of arrays with nothing loaded. Now `_sync_slots` compacts a pool once less than
# half of it is used, by half a chunk or more, and the region map follows the moved slots.
#   [S1] 64 loaded, 60 unloaded one at a time (as a bake releases them): capacity drops to 16, and the arrays
#        are recreated a handful of times, not once per chunk. Control: 20 unloaded (44 left) keeps 64.
#   [S2] after compaction, every loaded region's region-map texel names a slot whose array image IS that
#        region's own map, for all three map types, and the regions did move. Control: the same check
#        against a neighbour's slot fails, so it can tell regions apart.
#   [S3] a streamer that leaves a dense area drops the capacity. Control: moving within the area keeps it.
#
# WHAT THIS DOES NOT COVER: drawing. The headless renderer has no texture arrays to read back, so S2 checks
# the images `_build_array` uploads and the texel the shader decodes, not pixels.
#
# Data lives in user://region_slot_compact_gate, wiped at start. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionSlotCompactGate.tscn
extends Node

const DIR := "user://region_slot_compact_gate"
const TYPE_PATH := DIR + "/compact_type.tres"
const RS := 64
const GRID := 8 # 8 x 8 = 64 regions
const LONE := Vector2i(40, 0) # far from the block, for S3

var _fail := 0
const GATES := 3
var _completed := 0
var _t
var _st


func _ready() -> void:
	print("\n=== Region slot compaction (gate SC, bake memory phase 2) ===\n")
	_wipe(DIR)
	await _build_fixture()
	await _s1_s2_shrink_and_follow()
	await _s3_streamer()
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION SLOT COMPACT PASS" if ok else "REGION SLOT COMPACT FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- S1 and S2 --------------------------------------------------------------------------------------------
func _s1_s2_shrink_and_follow() -> void:
	print("[S1] unloading 60 of 64 shrinks the capacity:")
	_t = _new_terrain(true)
	await _frames(2)
	var d = _t.data
	_check("fixture: 64 loaded, capacity 64 (got %d, %d)" % [d.get_region_count(), d.get_slot_capacity()],
		d.get_region_count() == 64 and d.get_slot_capacity() == 64)
	# Keep the four in the HIGHEST slots, so compaction has to move every one of them.
	var slots_before: Array = d.get_slot_locations()
	var keep: Array = []
	for s in range(slots_before.size() - 1, -1, -1):
		if keep.size() < 4 and slots_before[s] != null and slots_before[s] is Vector2i and d.is_region_loaded(slots_before[s]):
			keep.append(slots_before[s])
	var slot_of_before := {}
	for loc in keep:
		slot_of_before[loc] = _slot_of(d, loc)
	d.reset_upload_stats()
	for loc: Vector2i in d.get_region_locations().duplicate():
		if not keep.has(loc):
			d.unload_region(loc) # update per region, as the scoped bake's release does
	var s: Dictionary = d.get_upload_stats()
	print("    after: %d loaded, capacity %d, arrays created %d" % [d.get_region_count(), d.get_slot_capacity(), s.array_creates])
	_check("capacity is 16", d.get_slot_capacity() == 16)
	_check("the arrays were recreated a few times, not per chunk (%d creates, at most 2 shrinks x 3 maps)" % s.array_creates,
		s.array_creates > 0 and s.array_creates <= 6)

	print("[S2] the region map follows the moved slots:")
	var moved := 0
	var own_ok := true
	var other_ok := true
	for i in keep.size():
		var loc: Vector2i = keep[i]
		var slot := _slot_of(d, loc)
		if slot != int(slot_of_before[loc]):
			moved += 1
		var r = d.get_region(loc)
		for t in 3:
			var maps: Array = d.get_maps(t)
			if slot < 0 or slot >= maps.size() or maps[slot] != r.get_maps()[t]:
				own_ok = false
		# Control: a neighbour's slot holds a different image.
		var other_slot := _slot_of(d, keep[(i + 1) % keep.size()])
		if d.get_height_maps()[other_slot] == r.get_height_map():
			other_ok = false
	print("    kept %s; slots before %s, after %s" % [keep, slot_of_before.values(), keep.map(func(l): return _slot_of(d, l))])
	_check("every kept region moved slot (%d of %d)" % [moved, keep.size()], moved == keep.size())
	_check("each region's texel names a slot holding its own height, control and colour maps", own_ok)
	_check("control: a neighbour's slot does not hold this region's map", other_ok)
	# The slot bookkeeping after the move, not just the tables built from it: unload a moved region and load
	# another. A slot index the move left stale frees the wrong slot, and the table stops matching.
	d.unload_region(keep[0])
	d.load_region(Vector2i(0, 0), DIR)
	var loaded: Array = d.get_region_locations()
	var table: Array = []
	var cap: int = d.get_slot_capacity()
	for s2 in cap:
		var at: Vector2i = d.get_slot_locations()[s2]
		if at != Vector2i.ZERO or d.is_region_loaded(Vector2i.ZERO) and _slot_of(d, Vector2i.ZERO) == s2:
			table.append(at)
	var all_own := true
	for loc in loaded:
		var sl := _slot_of(d, loc)
		if sl < 0 or d.get_height_maps()[sl] != d.get_region(loc).get_height_map():
			all_own = false
	table.sort()
	loaded.sort()
	print("    after unloading %s and loading (0, 0): slot table %s, loaded %s" % [keep[0], table, loaded])
	_check("the slot table holds exactly the loaded regions", table == loaded)
	_check("every loaded region's texel names its own map", all_own)
	_t.queue_free()
	await _frames(2)

	# S1 control: 20 unloaded, 44 left, is more than half: no shrink, no recreate.
	_t = _new_terrain(true)
	await _frames(2)
	d = _t.data
	d.reset_upload_stats()
	var n := 0
	for loc: Vector2i in d.get_region_locations().duplicate():
		if n < 20 and loc != LONE:
			d.unload_region(loc)
			n += 1
	s = d.get_upload_stats()
	_check("control: %d left keeps capacity 64 (got %d) and recreates nothing (%d)" % [d.get_region_count(), d.get_slot_capacity(), s.array_creates],
		d.get_slot_capacity() == 64 and s.array_creates == 0)
	_t.queue_free()
	await _frames(2)
	_completed += 2


# --- S3 ---------------------------------------------------------------------------------------------------
func _s3_streamer() -> void:
	print("[S3] a streamer leaving a dense area drops the capacity:")
	_t = _new_terrain(false)
	await _frames(1)
	var src := Node3D.new()
	add_child(src)
	src.global_position = Vector3(GRID * RS * 0.5, 50, GRID * RS * 0.5)
	_st = ClassDB.instantiate("Pasture3DStreamer")
	var srcs: Array[Node3D] = [src]
	_st.sources = srcs
	_t.add_child(_st)
	await _until_idle()
	var d = _t.data
	var dense_cap: int = d.get_slot_capacity()
	print("    in the block: %d loaded, capacity %d" % [d.get_region_count(), dense_cap])
	_check("fixture: the block streamed in (%d loaded)" % d.get_region_count(), d.get_region_count() >= 40)
	# Control: move within the block; the loaded count barely changes, so the capacity must stay.
	src.global_position += Vector3(RS * 0.5, 0, 0)
	await _until_idle()
	_check("control: moving within the block keeps capacity %d (got %d)" % [dense_cap, d.get_slot_capacity()],
		d.get_slot_capacity() == dense_cap)
	src.global_position = Vector3(LONE.x * RS + RS * 0.5, 50, RS * 0.5)
	await _until_idle()
	print("    at the lone region: %d loaded, capacity %d" % [d.get_region_count(), d.get_slot_capacity()])
	_check("the lone region loaded, the block did not stay", d.is_region_loaded(LONE) and d.get_region_count() <= 4)
	_check("capacity dropped to 16 (got %d)" % d.get_slot_capacity(), d.get_slot_capacity() == 16)
	_t.queue_free()
	src.queue_free()
	await _frames(2)
	_completed += 1


# ---- fixture ---------------------------------------------------------------------------------------------

## An 8 x 8 block of 64 m regions, each a distinct flat height, plus LONE far away, all of a type whose load
## radius covers the whole block from its centre.
func _build_fixture() -> void:
	var std = load("res://addons/pasture_3d/region_types/standard.tres")
	var ty = std.duplicate()
	ty.type_name = "CompactTest"
	ty.load_radius = 400.0
	ty.unload_radius = 450.0
	ty.priority = 0
	ResourceSaver.save(ty, TYPE_PATH)
	var b = _new_terrain(true)
	await _frames(2)
	b.change_region_size(RS)
	var d = b.data
	var tyr = d.load_region_type(TYPE_PATH)
	var locs: Array = [LONE]
	for j in GRID:
		for i in GRID:
			locs.append(Vector2i(i, j))
	# 65 regions: the block is 64 and LONE makes one more, so drop one block corner to keep 64.
	locs.erase(Vector2i(GRID - 1, GRID - 1))
	for loc in locs:
		var r = d.add_region_blank(loc, false)
		r.get_height_map().fill(Color(_height_of(loc), 0, 0, 1))
	d.update_maps()
	for loc in locs:
		d.set_region_type(loc, tyr, false)
	d.calc_height_range(true)
	d.update_maps()
	d.save_directory(DIR)
	b.queue_free()
	await _frames(2)


static func _height_of(p_loc: Vector2i) -> float:
	return 10.0 + p_loc.x + 100.0 * p_loc.y


func _new_terrain(p_load_all: bool):
	var t = ClassDB.instantiate("Pasture3D")
	t.region_loading = Pasture3D.REGION_LOADING_ALL if p_load_all else Pasture3D.REGION_LOADING_STREAMED
	add_child(t)
	t.data_directory = DIR
	return t


static func _slot_of(p_d, p_loc: Vector2i) -> int:
	return Pasture3DData.region_map_decode(p_d.get_region_map()[Pasture3DData.get_region_map_index(p_loc)])


func _until_idle() -> void:
	await _frames(2)
	for i in 900:
		if _st.is_idle():
			return
		await get_tree().process_frame
	_check("streamer went idle within 900 frames", false)


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)


func _check(p_label: String, p_ok: bool) -> void:
	print("    %s %s" % ["ok " if p_ok else "FAIL", p_label])
	if not p_ok:
		_fail += 1
