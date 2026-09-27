# Gate F — phase 6 of PASTURE3D_BAKE_MEMORY_SPEC.md (M6): a released brush spills its frozen caches.
#
# A FROZEN modifier keeps its last solve in memory whatever is loaded, and it is state, not a cache: it is
# served on every rebake until the user presses Bake. A scoped bake that releases every region a brush
# touches now spills that brush's caches to disk, and the next rebake that asks reads them back. Under test:
#   [F1] after spilling and reading back, a rebake of the brush, with its surface changed under the frozen
#        erosion, is byte-identical to one that never spilled, and serves the same stale solve. Control:
#        dropping the cache instead of spilling it re-solves and differs.
#   [F2] after the bake, the released brush holds 0 bytes of cache and its file is on disk; the report's
#        spilled bytes are what the unspilled run holds. Controls: the pre-M6 bake (debug_no_spill) holds
#        them; a brush over a region loaded before the bake is never spilled, even when its other region is
#        released.
#   [F3] the spill's edges: an explicit Bake (clear_cache) deletes the file and serves nothing; reading back
#        deletes the file; a freed modifier deletes its file; a cache holding an Object is not spilled; the
#        orphan sweep deletes another process's old files and never this one's. Control: a spilled
#        modifier that is not cleared still serves its entry.
#
# Fixture (region_size 128, 3 x 1 regions, both Mounds on the shared layer, each with Frozen erosion): E0
# inside region (0,0), E1 inside region (2,0), E2 across the (1,0)/(2,0) boundary. Region (2,0) is loaded
# before the bake, so it is pinned: E2 loses region (1,0) but keeps (2,0), and must not spill.
#
# Data lives in user://region_frozen_spill_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionFrozenSpillGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_frozen_spill_gate"
const SPILL := "user://region_frozen_spill_gate_spill"
const RS := 128.0

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _e0
var _e1
var _e2


func _ready() -> void:
	print("\n=== Region frozen spill (gate F, bake memory phase 6) ===\n")
	var spill: Dictionary = await _run("spill")
	var kept: Dictionary = await _run("no_spill")
	var dropped: Dictionary = await _run("drop")
	_f1(spill, kept, dropped)
	_f2(spill, kept)
	await _f3()
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION FROZEN SPILL PASS" if ok else "REGION FROZEN SPILL FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _f1(p_spill: Dictionary, p_kept: Dictionary, p_dropped: Dictionary) -> void:
	print("[F1] a spilled cache read back rebakes the same bytes:")
	print("    rebake stale: spill %s, kept %s, dropped %s; heights spill == kept %s, dropped == kept %s; moved %s"
		% [p_spill["stale"], p_kept["stale"], p_dropped["stale"], p_spill["heights"] == p_kept["heights"],
		p_dropped["heights"] == p_kept["heights"], p_kept["heights"] != p_kept["baked"]])
	_check("witness: the edit changed the rebake (heights moved)", p_kept["heights"] != p_kept["baked"])
	_check("the spilled run rebakes byte-identical to the never-spilled one", p_spill["heights"] == p_kept["heights"])
	_check("both serve the frozen solve as stale", bool(p_spill["stale"]) and bool(p_kept["stale"]))
	_check("the read-back consumed the file", not bool(p_spill["spilled_after"]) and not bool(p_spill["file_after"]))
	_check("control: dropping instead of spilling re-solves and differs",
		p_dropped["heights"] != p_kept["heights"] and not bool(p_dropped["stale"]))
	_completed += 1


func _f2(p_spill: Dictionary, p_kept: Dictionary) -> void:
	print("[F2] a released brush holds no cache after the bake:")
	print("    E0 in memory: spill %d B, kept %d B; spilled %s (%d B reported, file %s); E1 (pinned): spill %d B, kept %d B"
		% [p_spill["e0_bytes"], p_kept["e0_bytes"], p_spill["spilled"], p_spill["spilled_bytes"], p_spill["file"],
		p_spill["e1_bytes"], p_kept["e1_bytes"]])
	_check("E0 holds 0 bytes and is spilled, with its file on disk",
		int(p_spill["e0_bytes"]) == 0 and bool(p_spill["e0_spilled"]) and bool(p_spill["file"]))
	_check("the report names E0 alone and its bytes are what the unspilled run holds",
		p_spill["spilled"] == ["E0"] and int(p_spill["spilled_bytes"]) == int(p_kept["e0_bytes"]))
	_check("control: without the spill E0 holds its cache", int(p_kept["e0_bytes"]) > 0 and not bool(p_kept["e0_spilled"]))
	_check("control: E1, over a region loaded before the bake, is not spilled",
		int(p_spill["e1_bytes"]) > 0 and int(p_spill["e1_bytes"]) == int(p_kept["e1_bytes"]))
	print("    E2 (regions 1 and 2, region 1 released %s): spill %d B, kept %d B" % [
		(p_spill["released"] as Array).has(Vector2i(1, 0)), p_spill["e2_bytes"], p_kept["e2_bytes"]])
	_check("E2, whose other region was released, is not spilled either",
		(p_spill["released"] as Array).has(Vector2i(1, 0)) and int(p_spill["e2_bytes"]) > 0
		and int(p_spill["e2_bytes"]) == int(p_kept["e2_bytes"]))
	_completed += 1


func _f3() -> void:
	print("[F3] the spill's edges:")
	DirAccess.make_dir_recursive_absolute(SPILL)
	# An erosion entry carries all five grids; the other modifiers read only `grid`.
	var g3 := PackedFloat32Array([1.0, 2.0, 3.0])
	var entry := {"key": 7, "grid": g3, "flow": g3, "ero": g3, "dep": g3, "wet": g3}
	# Read back.
	var a := Pasture3DNodeErosion.new()
	a.store_cache("0,0,1,3", entry.duplicate(true))
	var bytes := a.spill_cache(SPILL)
	var path_a: String = a._spill_path
	var served := a.cache_for("0,0,1,3")
	_check("control: a spilled cache that is not cleared serves its entry, and the read-back deletes the file",
		bytes == 60 and not path_a.is_empty() and served.get("key", 0) == 7 and not FileAccess.file_exists(path_a))
	# The explicit Bake.
	var b := Pasture3DNodeErosion.new()
	b.store_cache("0,0,1,3", entry.duplicate(true))
	b.spill_cache(SPILL)
	var path_b: String = b._spill_path
	var existed := FileAccess.file_exists(path_b)
	b.clear_cache()
	_check("Bake (clear_cache) deletes the file and serves nothing",
		existed and not FileAccess.file_exists(path_b) and not b.is_spilled() and b.cache_for("0,0,1,3").is_empty())
	# Every modifier with a frozen cache follows the rule, not only erosion.
	var all_ok := true
	for m in [Pasture3DNodeRelief.new(), Pasture3DNodeGraph.new(), Pasture3DNodeRoad.new()]:
		m.store_cache("0,0,1,3", entry.duplicate(true))
		var got: bool = m.spill_cache(SPILL) > 0 and m.cache_bytes() == 0 and m.has_method("cache_for") \
				and (m.cache_for("0,0,1,3") as Dictionary).get("key", 0) == 7 and not m.is_spilled()
		all_ok = all_ok and got
	_check("relief, graph and road caches spill and read back too", all_ok)
	# Freed while spilled.
	var c := Pasture3DNodeErosion.new()
	c.store_cache("0,0,1,3", entry.duplicate(true))
	c.spill_cache(SPILL)
	var path_c: String = c._spill_path
	var had := FileAccess.file_exists(path_c)
	c = null
	_check("a freed spilled modifier deletes its file", had and not FileAccess.file_exists(path_c))
	# An Object in the cache.
	var d := Pasture3DNodeErosion.new()
	var obj_entry := entry.duplicate(true)
	obj_entry["obj"] = Curve.new()
	d.store_cache("0,0,1,3", obj_entry)
	_check("a cache holding an Object is not spilled and stays in memory",
		d.spill_cache(SPILL) == 0 and not d.is_spilled() and d.cache_bytes() == 60)
	# The orphan sweep.
	var other := SPILL.path_join("999999999_1.spill")
	var own := SPILL.path_join("%d_1.spill" % OS.get_process_id())
	for p in [other, own]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_8(1)
		f.close()
	var young := Pasture3DNode.sweep_spills(SPILL, 3600)
	var old := Pasture3DNode.sweep_spills(SPILL, -1)
	_check("the sweep deletes another process's old file, never a young one or this process's",
		young == 0 and old == 1 and not FileAccess.file_exists(other) and FileAccess.file_exists(own))
	DirAccess.remove_absolute(own)
	_completed += 1


# ---- one run ---------------------------------------------------------------------------------------------

func _run(p_mode: String) -> Dictionary:
	await _build()
	var d = _terrain.data
	d.load_region(Vector2i(2, 0), DIR, false) # pinned: E1 is never released
	d.update_maps()
	for b in [_e0, _e1, _e2]:
		for m in b.modifiers:
			m.clear_cache()
	var sb := ScopedBake.new(_terrain)
	sb.budget_regions = 0
	sb.spill_dir = SPILL
	sb.debug_no_spill = p_mode == "no_spill"
	sb.debug_drop_frozen = p_mode == "drop"
	var rep: Dictionary = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	var m0 = _e0.modifiers[0]
	var m1 = _e1.modifiers[0]
	var out := {"spilled": rep.get("spilled", []), "spilled_bytes": rep.get("spilled_bytes", 0),
			"e0_bytes": m0.cache_bytes(), "e0_spilled": m0.is_spilled(), "e1_bytes": m1.cache_bytes(),
			"e2_bytes": _e2.modifiers[0].cache_bytes(), "released": rep.get("released", []),
			"file": m0.is_spilled() and FileAccess.file_exists(m0._spill_path)}
	var spill_path: String = m0._spill_path
	# Rebake E0 with its surface changed under the frozen erosion, with its region loaded.
	d.load_region(Vector2i(0, 0), DIR, false)
	d.load_region(Vector2i(1, 0), DIR, false)
	d.update_maps()
	out["baked"] = d.get_region(Vector2i(0, 0)).get_height_map().get_data()
	_e0.slope_angle = _e0.slope_angle + 8.0
	_e0._refresh_owner(_e0._layer_owner, false, [])
	out["heights"] = d.get_region(Vector2i(0, 0)).get_height_map().get_data()
	out["stale"] = m0._stale
	out["spilled_after"] = m0.is_spilled()
	out["file_after"] = not spill_path.is_empty() and FileAccess.file_exists(spill_path)
	print("  %s: spilled %s (%d B), E0 %d B in memory, rebake stale %s" % [p_mode, out["spilled"],
		out["spilled_bytes"], out["e0_bytes"], out["stale"]])
	await _teardown()
	return out


# ---- fixture ---------------------------------------------------------------------------------------------

func _build() -> void:
	_wipe(DIR)
	_wipe(SPILL)
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.change_region_size(int(RS))
	_terrain.data_directory = DIR
	var d = _terrain.data
	for i in 3:
		d.add_region_blank(Vector2i(i, 0), false)
	d.update_maps()
	_e0 = _mound("E0", Vector3(0.5 * RS, 0, 0.5 * RS), RS * 0.2)
	_e1 = _mound("E1", Vector3(2.5 * RS, 0, 0.5 * RS), RS * 0.2)
	_e2 = _mound("E2", Vector3(2.0 * RS, 0, 0.5 * RS), RS * 0.1)
	var pre := ScopedBake.new(_terrain)
	pre.budget_regions = 0
	pre.bake(ScopedBake.Scope.ALL_LOADED)
	d.save_directory(DIR)
	for loc: Vector2i in d.get_region_locations().duplicate():
		d.unload_region(loc, false)
	d.update_maps()
	await get_tree().process_frame


func _mound(p_name: String, p_at: Vector3, p_half: float):
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	var e := Pasture3DNodeErosion.new()
	e.label = "Erosion"
	e.iterations = 4
	e.erosion_rate = 0.05
	var mods: Array[Pasture3DNode] = [e]
	mound.modifiers = mods
	return mound


func _teardown() -> void:
	_root.queue_free()
	_root = null
	_terrain = null
	_e0 = null
	_e1 = null
	_e2 = null
	await get_tree().process_frame
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
