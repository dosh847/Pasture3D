# Gate C — phase 5 of PASTURE3D_BAKE_MEMORY_SPEC.md (M5): a shared layer is baked in chunks.
#
# By default every Mound shares one layer, one owner, and an owner was atomic: on a large world the bake
# loaded the whole world for it, or skipped it over the budget. Now an owner that reads no domain and needs
# regions the bake has to load is split into connected components of footprint overlap, each baked through
# `_refresh_owner(..., p_only)` and loaded/released like an owner. Under test:
#   [C1] the chunked bake's heights equal the whole-owner bake's, byte for byte, through the scoped bake and
#        through the manager's Bake All. Control: splitting one tool per chunk, ignoring overlaps, differs.
#        Bake All takes the owner's undo pair once, not per chunk, and its "after" is the owner's final state
#        on the regions loaded before the bake (two of them are, for this).
#   [C2] peak loaded is the largest chunk's region count. Control: the unsplit bake loads every region the
#        owner needs.
#   [C3] a shared owner that reads its domain (erosion) is not split, and over the budget it is skipped and
#        named in the manager's warning. Controls: the same layer without erosion is split and not skipped;
#        a bake with every region loaded splits nothing.
#
# Fixture (region_size 128, 4 x 4 regions, every Mound on the default shared layer): an isolated small
# Mound in 8 regions, and a CLUSTER of three Mounds whose footprints overlap in a chain across regions
# (1,1) (2,1) (1,2) (2,2). The Mounds are edited after the pre-bake, so the bake has real work.
#
# Data lives in user://region_bake_chunk_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionBakeChunkGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_bake_chunk_gate"
const RS := 128.0
const N := 4
const ISOLATED := [Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 2), Vector2i(3, 3), Vector2i(0, 3),
	Vector2i(1, 3), Vector2i(3, 2), Vector2i(0, 1)]

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _brushes: Array = []
var _loaded_now := 0
var _peak := 0


func _ready() -> void:
	print("\n=== Region bake chunks (gate C, bake memory phase 5) ===\n")
	await _c1_c2()
	await _c3()
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION BAKE CHUNK PASS" if ok else "REGION BAKE CHUNK FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- C1, C2 -----------------------------------------------------------------------------------------------
func _c1_c2() -> void:
	var whole: Dictionary = await _bake("whole")
	var chunked: Dictionary = await _bake("chunked")
	var by_tool: Dictionary = await _bake("by_tool")
	var mgr: Dictionary = await _bake("manager")
	print("[C1] chunks bake the same bytes as the whole owner:")
	var diff := _differing(chunked["heights"], whole["heights"])
	var mdiff := _differing(mgr["heights"], whole["heights"])
	var tdiff := _differing(by_tool["heights"], whole["heights"])
	var moved := _differing(whole["heights"], whole["pre"])
	print("    split %s; differing from the whole-owner bake: chunked %s, manager %s, one-tool-per-chunk %s"
		% [chunked["split"], diff, mdiff, tdiff])
	_check("witness: the bake changed regions (changed %d of %d)" % [moved.size(), N * N], moved.size() > 0)
	_check("the owner was split, the cluster in one chunk (%d chunks for %d tools)" % [
		int(chunked["split"].values()[0]) if not chunked["split"].is_empty() else 0, int(chunked["tools"])],
		chunked["split"].size() == 1 and int(chunked["split"].values()[0]) == ISOLATED.size() + 1)
	_check("control: the whole-owner bake was not split", whole["split"].is_empty())
	_check("chunked == whole on every region, byte for byte", diff.is_empty() and chunked["heights"].size() == N * N)
	_check("through Bake All too", mdiff.is_empty() and mgr["split"].size() == 1)
	_check("control: one tool per chunk, overlaps ignored, differs", not tdiff.is_empty())
	print("    Bake All: %d snapshots for %d chunks; after == final on the pinned regions: %s; before == pre: %s"
		% [mgr["snapshots"], int(mgr["split"].values()[0]) if not mgr["split"].is_empty() else 0,
		mgr["after_ok"], mgr["before_ok"]])
	_check("one undo pair for the split owner", int(mgr["snapshots"]) == 2)
	_check("its after snapshot is the owner's final state, its before the pre-bake one (and both hold tiles)",
		bool(mgr["after_ok"]) and bool(mgr["before_ok"]))
	_completed += 1
	print("[C2] the peak is the largest chunk:")
	print("    peak loaded: chunked %d (largest chunk %d regions), whole %d (owner needs %d), of %d" % [
		chunked["peak"], chunked["widest"], whole["peak"], whole["widest"], N * N])
	_check("chunked peak equals the largest chunk", int(chunked["peak"]) == int(chunked["widest"]))
	_check("control: the whole owner loads every region it needs, more than any chunk",
		int(whole["peak"]) == int(whole["widest"]) and int(whole["peak"]) > int(chunked["widest"]))
	_completed += 1


# --- C3 ---------------------------------------------------------------------------------------------------
func _c3() -> void:
	print("[C3] a shared owner that reads its domain is not split, and is named over the budget:")
	var eroded: Dictionary = await _bake("eroded")
	var plain: Dictionary = await _bake("budget")
	var loaded: Dictionary = await _bake("all_loaded")
	var owner := String(eroded.get("owner", ""))
	print("    eroded: split %s, skipped %s; plain: split %s, skipped %s; all loaded: split %s" % [
		eroded["split"], eroded["skipped"], plain["split"], plain["skipped"], loaded["split"]])
	_check("the eroded owner is not split", eroded["split"].is_empty())
	_check("it is skipped over the budget", (eroded["skipped"] as Array).has(owner))
	_check("the warning names it", _has(eroded["warnings"], owner) and _has(eroded["warnings"], "cannot be split"))
	_check("control: without erosion it is split, not skipped, and not warned about",
		not plain["split"].is_empty() and (plain["skipped"] as Array).is_empty() and not _has(plain["warnings"], owner))
	_check("control: with every region loaded nothing is split (and the bake ran)",
		loaded["split"].is_empty() and int(loaded["baked"]) > 0)
	_completed += 1


# ---- one bake --------------------------------------------------------------------------------------------

func _bake(p_mode: String) -> Dictionary:
	await _build(p_mode == "eroded")
	var d = _terrain.data
	if p_mode == "all_loaded":
		for j in N:
			for i in N:
				d.load_region(Vector2i(i, j), DIR, false)
		d.update_maps()
	elif p_mode == "manager":
		# Pinned: one under an isolated Mound's chunk, one under the cluster's.
		d.load_region(Vector2i(0, 0), DIR, false)
		d.load_region(Vector2i(2, 2), DIR, false)
		d.update_maps()
	_loaded_now = 0
	_peak = 0
	d.region_loaded.connect(_on_loaded)
	d.region_unloaded.connect(_on_unloaded)
	var out := {"pre": _pre.duplicate(), "warnings": PackedStringArray(), "skipped": [], "baked": 0, "widest": 0}
	if p_mode in ["manager", "eroded", "budget"]:
		var mgr := Pasture3DSimManager.new()
		mgr.name = "Sim"
		_root.add_child(mgr)
		mgr.terrain = _terrain
		var paths: Array[NodePath] = []
		for b in _brushes:
			paths.append(mgr.get_path_to(b))
		mgr.eroding_brushes = paths
		mgr.bake_scope = 2
		mgr.bake_budget_regions = 0 if p_mode == "manager" else 4
		var rep: Dictionary = mgr.bake_all_brushes_now()
		out["split"] = rep.get("split", {})
		out["skipped"] = rep.get("skipped_budget", [])
		out["warnings"] = mgr._registry_warnings()
		out["owner"] = _brushes[0]._layer_owner
		out["snapshots"] = rep.get("snapshots", -1)
		if p_mode == "manager":
			var owner: String = out["owner"]
			var undo: Dictionary = rep["undo"]
			var after: Dictionary = undo["after"].get(owner, {})
			var before: Dictionary = undo["before"].get(owner, {})
			var final: Dictionary = mgr._snapshot_owner(owner)
			var pinned: Array[Vector2i] = [Vector2i(0, 0), Vector2i(2, 2)]
			var baked := {}
			for loc in pinned:
				baked[loc] = d.get_region(loc).get_height_map().get_data()
			out["after_ok"] = not _snap_bytes(after, owner).is_empty() \
					and _snap_bytes(after, owner) == _snap_bytes(final, owner)
			mgr._restore_owner(owner, before)
			var pre_ok := true
			for loc in pinned:
				pre_ok = pre_ok and d.get_region(loc).get_height_map().get_data() == _pre[loc] \
						and _pre[loc] != baked[loc]
			out["before_ok"] = not before.is_empty() and pre_ok
			mgr._restore_owner(owner, after)
			for loc in pinned:
				out["after_ok"] = out["after_ok"] and d.get_region(loc).get_height_map().get_data() == baked[loc]
	else:
		var sb := ScopedBake.new(_terrain)
		sb.budget_regions = 0
		sb.debug_no_chunks = p_mode == "whole"
		sb.debug_chunk_by_tool = p_mode == "by_tool"
		var scope: int = ScopedBake.Scope.ALL_LOADED if p_mode == "all_loaded" else ScopedBake.Scope.ALL_REGIONS
		var plan: Dictionary = sb.plan(scope)
		for od: Dictionary in plan["owners"]:
			out["widest"] = maxi(int(out["widest"]), (od["regions"] as Array).size())
		var rep: Dictionary = sb.bake(scope)
		out["split"] = rep.get("split", {})
		for e: Array in rep["events"]:
			if e[0] == "bake":
				out["baked"] = int(out["baked"]) + 1
	d.region_loaded.disconnect(_on_loaded)
	d.region_unloaded.disconnect(_on_unloaded)
	out["peak"] = _peak
	out["tools"] = _brushes.size()
	var heights := {}
	for j in N:
		for i in N:
			var loc := Vector2i(i, j)
			if not d.is_region_loaded(loc):
				d.load_region(loc, DIR, false)
			heights[loc] = d.get_region(loc).get_height_map().get_data()
	out["heights"] = heights
	print("  %s: split %s, peak %d" % [p_mode, out["split"], _peak])
	await _teardown()
	return out


# ---- fixture ---------------------------------------------------------------------------------------------

var _pre := {}


func _build(p_eroded: bool) -> void:
	_wipe_dir()
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.change_region_size(int(RS))
	_terrain.data_directory = DIR
	var d = _terrain.data
	for j in N:
		for i in N:
			d.add_region_blank(Vector2i(i, j), false)
	d.update_maps()
	_brushes.clear()
	for k in ISOLATED.size():
		var r: Vector2i = ISOLATED[k]
		_brushes.append(_mound("I_%d" % k, Vector3((r.x + 0.5) * RS, 0, (r.y + 0.5) * RS), RS * 0.2))
	# The cluster: each footprint overlaps the next, across region boundaries.
	for p in [Vector2(1.6, 1.5), Vector2(2.0, 1.5), Vector2(2.2, 1.9)]:
		_brushes.append(_mound("C_%s" % p, Vector3(p.x * RS, 0, p.y * RS), RS * 0.28))
	if p_eroded:
		for b in _brushes:
			var e := Pasture3DNodeErosion.new()
			e.label = "Erosion"
			e.iterations = 2
			e.erosion_rate = 0.05
			var mods: Array[Pasture3DNode] = [e]
			b.modifiers = mods
	var pre := ScopedBake.new(_terrain)
	pre.budget_regions = 0
	pre.bake(ScopedBake.Scope.ALL_LOADED)
	d.save_directory(DIR)
	_pre.clear()
	for loc: Vector2i in d.get_region_locations():
		_pre[loc] = d.get_region(loc).get_height_map().get_data()
	for loc: Vector2i in d.get_region_locations().duplicate():
		d.unload_region(loc, false)
	d.update_maps()
	for b in _brushes:
		b.slope_angle = b.slope_angle + 6.0
	await get_tree().process_frame


## A Mound on the default shared layer (no add_new_layer).
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
	return mound


func _teardown() -> void:
	_root.queue_free()
	_root = null
	_terrain = null
	_brushes.clear()
	await get_tree().process_frame
	await get_tree().process_frame


static func _differing(p_a: Dictionary, p_b: Dictionary) -> Array:
	var out: Array = []
	for loc in p_a:
		if p_a[loc] != p_b.get(loc):
			out.append(loc)
	return out


## An owner snapshot's tiles as bytes, {loc: {coord: data}}: tiles are Images, which compare by reference.
static func _snap_bytes(p_snap: Dictionary, p_owner: String) -> Dictionary:
	var out := {}
	var tiles: Dictionary = p_snap.get(p_owner, {})
	for loc in tiles:
		var inner := {}
		for coord in tiles[loc]:
			var img: Image = tiles[loc][coord]
			inner[coord] = img.get_data() if img else PackedByteArray()
		out[loc] = inner
	return out


static func _has(p_w: PackedStringArray, p_needle: String) -> bool:
	for s in p_w:
		if s.contains(p_needle):
			return true
	return false


func _on_loaded(_p_loc: Vector2i) -> void:
	_loaded_now += 1
	_peak = maxi(_peak, _loaded_now)


func _on_unloaded(_p_loc: Vector2i) -> void:
	_loaded_now -= 1


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)


func _check(p_label: String, p_ok: bool) -> void:
	print("    %s %s" % ["ok " if p_ok else "FAIL", p_label])
	if not p_ok:
		_fail += 1
