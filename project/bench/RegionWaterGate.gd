# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RW — phase 4b of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: the water terrain check (§I).
#
# The spec's proofs: the ocean is hidden over an unloaded region and shown beyond the world edge (control: an
# unencoded "unloaded" value shows water); a below-sea-level cave floor under dry land shows no water; a
# seabed hole keeps water. The large-lake half of 4b is gated separately.
#
# Headless, so this measures Pasture3DData::get_water_terrain_state / is_water_hidden, the CPU mirror of
# water_terrain.gdshaderinc. That the shader agrees with the mirror is RegionWaterRenderProbe's job
# (windowed); this gate fixes what the mirror must say.
#
# Fixture (region size 256, vertex spacing 1, water level 0, land margin 2):
#   A (0,0) dry land at +20, with a hole at (100, 100): the cave
#   B (1,0) seabed at -20, with a hole at (356, 100): the flooded pit
#   C (2,0) seabed at -20, saved and then unloaded: unknown
#   D (0,1) ratio 4 (coarse), land only where its own pixel x is in [8, 16)
#
# Data lives in a per-gate user:// directory, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionWaterGate.tscn
extends Node

const DIR := "user://region_water_gate"
const RS := 256
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const C := Vector2i(2, 0)
const D := Vector2i(0, 1)
const LEVEL := 0.0
const MARGIN := 2.0
const UNLOADED := -(1 << 21) # Pasture3DData::REGION_MAP_UNLOADED, restated so the gate does not share it
const CAVE := Vector2(100, 100)
const PIT := Vector2(356, 100)

var _fail := 0
const GATES := 6
var _completed := 0
var _terrain


func _ready() -> void:
	print("\n=== Region water terrain check (gate RW, streaming phase 4b) ===\n")
	_wipe(DIR)
	var coarse := Pasture3DRegionType.new()
	coarse.type_name = "Coarse4"
	coarse.texel_ratio = 4
	ResourceSaver.save(coarse, DIR + "/coarse4.tres")
	coarse = ResourceLoader.load(DIR + "/coarse4.tres", "", ResourceLoader.CACHE_MODE_REPLACE)

	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [A, B, C, D]:
		d.add_region_blank(loc, false)
	d.update_maps()
	_fill(A, 20.0)
	_fill(B, -20.0)
	_fill(C, -20.0)
	d.set_region_type(D, coarse, false)
	var dimg: Image = d.get_region(D).get_height_map()
	for y in dimg.get_height():
		for x in dimg.get_width():
			dimg.set_pixel(x, y, Color(15.0 if x >= 8 and x < 16 else -15.0, 0, 0, 1))
	d.get_region(D).set_modified(true)
	d.get_region(D).calc_height_range()
	d.update_maps(3, true, false)
	d.set_control_hole(Vector3(CAVE.x, 0, CAVE.y), true)
	d.set_control_hole(Vector3(PIT.x, 0, PIT.y), true)
	d.save_directory(DIR)
	d.unload_region(C, false)
	d.update_maps()

	_rw1_encoding()
	_rw2_unknown_is_not_nothing()
	_rw3_cave_under_dry_land()
	_rw4_seabed_hole_keeps_water()
	_rw5_reach_of_a_removed_vertex()
	_rw6_coarse_lattice_texel()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION WATER PASS" if ok else "REGION WATER FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _rw1_encoding() -> void:
	print("[RW1] an indexed region that is not loaded is encoded, and every decoder reads it as none:")
	var d = _terrain.data
	var v := _map_value(C)
	_check("C encodes as unloaded (got %d)" % v, v == UNLOADED)
	_check("region_map_decode(unloaded) is -1", Pasture3DData.region_map_decode(UNLOADED) == -1)
	_check("get_region_id(C) is -1", d.get_region_id(C) == -1)
	_check("C is not in the active locations", not d.get_region_locations().has(C))
	for loc in [A, B, D]:
		_check("%s still decodes to a slot (%d)" % [loc, _map_value(loc)], d.get_region_id(loc) >= 0)
	_check("a location nobody indexed is 0", _map_value(Vector2i(5, 5)) == 0)
	# Control: the index is what makes C "unknown". Without its entry the same location is nothing.
	var entry: Dictionary = _without_entry(C)
	_check("control: C unindexed encodes as 0 (got %d)" % _map_value(C), _map_value(C) == 0)
	_restore_entry(C, entry)
	_check("restored: C unloaded again", _map_value(C) == UNLOADED)
	# Loading it back gives it a slot; unloading it again returns it to unknown.
	d.load_region(C, DIR, true)
	_check("loaded: C has a slot", d.get_region_id(C) >= 0 and _map_value(C) > 0)
	d.unload_region(C, true)
	_check("unloaded again: unknown", _map_value(C) == UNLOADED)
	_completed += 1


func _rw2_unknown_is_not_nothing() -> void:
	print("[RW2] water is hidden over an unloaded region and shown beyond the world:")
	var d = _terrain.data
	var over_c := Vector2(640, 128)
	var beyond := Vector2(-3000, 128)
	var off_map := Vector2(RS * 1000, 128) # past the region map itself
	_check("over C: state 1, hidden", d.get_water_terrain_state(over_c, LEVEL, MARGIN) == 1
			and d.is_water_hidden(over_c, LEVEL, MARGIN, 0.0))
	_check("beyond the world: state 0, shown", d.get_water_terrain_state(beyond, LEVEL, MARGIN) == 0
			and not d.is_water_hidden(beyond, LEVEL, MARGIN, 0.0))
	_check("past the region map: state 0, shown", d.get_water_terrain_state(off_map, LEVEL, MARGIN) == 0
			and not d.is_water_hidden(off_map, LEVEL, MARGIN, 0.0))
	_check("over B's seabed: state 3, shown", d.get_water_terrain_state(Vector2(400, 200), LEVEL, MARGIN) == 3)
	# Control: an unencoded "unloaded" is 0, and 0 is open sea: water floods the unknown island.
	var entry: Dictionary = _without_entry(C)
	var st := int(d.get_water_terrain_state(over_c, LEVEL, MARGIN))
	_check("control: with C unencoded the water is shown (state %d)" % st, st == 0
			and not d.is_water_hidden(over_c, LEVEL, MARGIN, 0.0))
	_restore_entry(C, entry)
	_completed += 1


func _rw3_cave_under_dry_land() -> void:
	print("[RW3] a cave through dry land shows no water:")
	var d = _terrain.data
	var hole: bool = d.get_control_hole(Vector3(CAVE.x, 0, CAVE.y))
	_check("the fixture has a hole at the cave", hole)
	_check("cave: state 2 (land), hidden", d.get_water_terrain_state(CAVE, LEVEL, MARGIN) == 2
			and d.is_water_hidden(CAVE, LEVEL, MARGIN, 5.0))
	# Control: the height decides, not the hole. With the land margin above the land, the same spot is water.
	_check("control: margin 30 shows water at the cave", d.get_water_terrain_state(CAVE, LEVEL, 30.0) == 3)
	_completed += 1


func _rw4_seabed_hole_keeps_water() -> void:
	print("[RW4] a hole in the seabed keeps its water:")
	var d = _terrain.data
	_check("the fixture has a hole at the pit", d.get_control_hole(Vector3(PIT.x, 0, PIT.y)))
	_check("pit: state 3, shown", d.get_water_terrain_state(PIT, LEVEL, MARGIN) == 3
			and not d.is_water_hidden(PIT, LEVEL, MARGIN, 5.0))
	# Control: the stored height is read under the hole. Water below that seabed is hidden there.
	_check("control: water at -30 is under the pit's stored floor", d.get_water_terrain_state(PIT, -30.0, MARGIN) == 2)
	_completed += 1


func _rw5_reach_of_a_removed_vertex() -> void:
	print("[RW5] a vertex is removed only when its triangles' whole reach is hidden:")
	var d = _terrain.data
	var near_shore := Vector2(250, 128) # 6 m inside A; B's sea starts at x = 256
	_check("deep inland (x 200, reach 10): hidden", d.is_water_hidden(Vector2(200, 128), LEVEL, MARGIN, 10.0))
	_check("near the shore with reach 10: kept", not d.is_water_hidden(near_shore, LEVEL, MARGIN, 10.0))
	# Control: the centre alone is land; testing only it would remove triangles that reach the sea.
	_check("control: the centre alone says hidden", d.is_water_hidden(near_shore, LEVEL, MARGIN, 0.0))
	# Unknown counts as hidden, but no region is open sea: past x = 768 there is none, so a reach into it keeps
	# the vertex.
	_check("C's far edge reaching the open sea: kept", not d.is_water_hidden(Vector2(765, 128), LEVEL, MARGIN, 10.0))
	_check("inside C: hidden", d.is_water_hidden(Vector2(640, 128), LEVEL, MARGIN, 10.0))
	_completed += 1


func _rw6_coarse_lattice_texel() -> void:
	print("[RW6] a coarse region is read at its own lattice texel:")
	var d = _terrain.data
	# D is ratio 4: local x 40 is its pixel 10 (land), local x 10 is its pixel 2 (sea).
	var land_pt := Vector2(40, 256 + 20)
	var sea_pt := Vector2(10, 256 + 20)
	_check("D is coarse", d.get_region(D).get_texel_ratio() == 4)
	_check("local x 40 (pixel 10): land", d.get_water_terrain_state(land_pt, LEVEL, MARGIN) == 2)
	_check("local x 10 (pixel 2): sea", d.get_water_terrain_state(sea_pt, LEVEL, MARGIN) == 3)
	# Control: the fixture separates the two plausible reads. Reading pixel = local (no shift) gives the
	# opposite answer at both points, so a missing shift cannot pass.
	var img: Image = d.get_region(D).get_height_map()
	var unshifted_land := img.get_pixel(40, 20).r >= LEVEL + MARGIN
	var unshifted_sea := img.get_pixel(10, 20).r < LEVEL + MARGIN
	_check("control: an unshifted read disagrees at both points", not unshifted_land and not unshifted_sea)
	# The lattice edge: pixel 15 is land and pixel 16 is sea, at local x 63 and 64.
	_check("local x 63 (pixel 15): land", d.get_water_terrain_state(Vector2(63, 356), LEVEL, MARGIN) == 2)
	_check("local x 64 (pixel 16): sea", d.get_water_terrain_state(Vector2(64, 356), LEVEL, MARGIN) == 3)
	_completed += 1


# ---- helpers ----

func _map_value(p_loc: Vector2i) -> int:
	var d = _terrain.data
	return d.get_region_map()[Pasture3DData.get_region_map_index(p_loc)]


func _without_entry(p_loc: Vector2i) -> Dictionary:
	var index = _terrain.data.get_region_index()
	var entries: Dictionary = index.get_entries().duplicate()
	var entry: Dictionary = entries[p_loc]
	entries.erase(p_loc)
	index.set_entries(entries)
	_terrain.data.update_maps(3, true, false)
	return entry


func _restore_entry(p_loc: Vector2i, p_entry: Dictionary) -> void:
	var index = _terrain.data.get_region_index()
	var entries: Dictionary = index.get_entries().duplicate()
	entries[p_loc] = p_entry
	index.set_entries(entries)
	_terrain.data.update_maps(3, true, false)


func _fill(p_loc: Vector2i, p_h: float) -> void:
	var r = _terrain.data.get_region(p_loc)
	r.get_height_map().fill(Color(p_h, 0, 0, 1))
	r.set_modified(true)
	r.calc_height_range()


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
