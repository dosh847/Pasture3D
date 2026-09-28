# Gate I — phase 3 of PASTURE3D_BAKE_MEMORY_SPEC.md (M3): a scoped bake writes the region index once, and the
# layer manifest only when it changed.
#
# The index and the manifest describe the whole world, and unload_region used to write both at every
# release: O(n²) bytes over an All-regions bake. Now the scoped bake's releases update the index in memory and
# `finish` writes it once; the manifest is written only when its content differs from the file this data last
# wrote. Under test, through ScopedBake.bake (the path Bake All takes):
#   [I1] a bake that releases 3 regions writes the index once. Control: `debug_index_per_unload` (the pre-M3
#        behaviour) writes it once per release.
#   [M]  the same bake, stack unchanged, writes the manifest 0 times. Controls: a renamed layer before an
#        unload writes it, and the new name is on disk; a deleted manifest file is written again.
#   [I2] a crash after the last release (`debug_skip_index_write`: the index file keeps its pre-bake entries)
#        loses nothing. Reloaded, every region is there with its type and ratio, in the editor path and the
#        index-only (game) path, and its heights equal those of the same bake with the index written. The
#        stack changed while R1..R3 were unloaded, so their stale entries carry an old stack signature and
#        the reload recomposites them from the manifest and slices. Witnesses: the index on disk is stale
#        (its signature for R1 differs from the written run's), and the heights differ from the pre-bake ones.
#
# Fixture (region_size 256): blank ground in R0..R3 along x, a custom region type on R1..R3, and three
# registered Mounds on their own layers straddling R0|R1, R1|R2 and R2|R3. Only R0 is loaded at the bake.
#
# Data lives in user://region_index_batch_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionIndexBatchGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_index_batch_gate"
const TYPE_PATH := "user://region_index_batch_type.tres"
const INDEX_FILE := DIR + "/pasture3d_region_index.res"
const MANIFEST_FILE := DIR + "/pasture3d_layers.res"
const R0 := Vector2i(0, 0)
const R1 := Vector2i(1, 0)
const R2 := Vector2i(2, 0)
const R3 := Vector2i(3, 0)
const ALL := [R0, R1, R2, R3]
const TYPED := [R1, R2, R3]
const HALF := 60.0

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _mounds: Array = []


func _ready() -> void:
	print("\n=== Region index batching (gate I, bake memory phase 3) ===\n")
	var ty = load("res://addons/pasture_3d/region_types/standard.tres").duplicate()
	ty.type_name = "IndexTest"
	ResourceSaver.save(ty, TYPE_PATH)
	await _i1_index_once()
	await _m_manifest_when_changed()
	await _i2_crash()
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION INDEX BATCH PASS" if ok else "REGION INDEX BATCH FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- I1 ---------------------------------------------------------------------------------------------------
func _i1_index_once() -> void:
	print("[I1] a bake writes the index once:")
	await _build()
	var d = _terrain.data
	var sb := ScopedBake.new(_terrain)
	d.reset_upload_stats()
	var rep: Dictionary = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	var s: Dictionary = d.get_upload_stats()
	print("    released %s; index writes %d" % [rep["released"], s.index_writes])
	_check("fixture: the bake loaded and released R1..R3", (rep["released"] as Array).size() == 3)
	_check("the index was written once", int(s.index_writes) == 1)
	_check("the loaded set is handed back (only R0)", d.get_region_locations() == [R0])
	await _teardown()
	await _build()
	d = _terrain.data
	sb = ScopedBake.new(_terrain)
	sb.debug_index_per_unload = true
	d.reset_upload_stats()
	rep = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	s = d.get_upload_stats()
	_check("control: per-unload writes it once per release (%d for %d)" % [s.index_writes, (rep["released"] as Array).size()],
		int(s.index_writes) == (rep["released"] as Array).size() and int(s.index_writes) > 1)
	await _teardown()
	_completed += 1


# --- M ----------------------------------------------------------------------------------------------------
func _m_manifest_when_changed() -> void:
	print("[M] the manifest is written only when it changed:")
	await _build()
	var d = _terrain.data
	var sb := ScopedBake.new(_terrain)
	d.reset_upload_stats()
	var rep: Dictionary = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	var s: Dictionary = d.get_upload_stats()
	print("    bake: manifest writes %d, skips %d" % [s.manifest_writes, s.manifest_skips])
	_check("an unchanged stack costs no manifest write", int(s.manifest_writes) == 0)
	_check("witness: the releases did reach the manifest check (%d skips)" % s.manifest_skips,
		int(s.manifest_skips) >= (rep["released"] as Array).size())
	# Control: rename a layer, then unload a region; the manifest must be written and carry the new name.
	d.load_region(R1, DIR)
	var stack = d.get_layer_stack()
	var layer = stack.get_layer(stack.get_layer_count() - 1)
	layer.set_layer_name("renamed_by_gate")
	d.reset_upload_stats()
	d.unload_region(R1)
	s = d.get_upload_stats()
	_check("control: a renamed layer writes the manifest (%d)" % s.manifest_writes, int(s.manifest_writes) == 1)
	var disk = ResourceLoader.load(MANIFEST_FILE, "", ResourceLoader.CACHE_MODE_IGNORE)
	var names := []
	for l in disk.get_layers():
		names.append(l.get_layer_name())
	_check("the new name is on disk", names.has("renamed_by_gate"))
	# Control: the file went; the next unload writes it again even though the content did not change.
	DirAccess.remove_absolute(MANIFEST_FILE)
	d.load_region(R1, DIR)
	d.reset_upload_stats()
	d.unload_region(R1)
	s = d.get_upload_stats()
	_check("control: a deleted manifest is written again", int(s.manifest_writes) == 1 and FileAccess.file_exists(MANIFEST_FILE))
	await _teardown()
	_completed += 1


# --- I2 ---------------------------------------------------------------------------------------------------
func _i2_crash() -> void:
	print("[I2] a crash before the index write loses nothing:")
	# Reference: the same bake with the index written.
	await _build(true)
	var sb := ScopedBake.new(_terrain)
	sb.bake(ScopedBake.Scope.ALL_REGIONS)
	var pre: Dictionary = _pre_heights
	var ref_mem_sig = _terrain.data.get_region_index().get_entry(R1).get("stack_signature")
	await _teardown()
	_check("control: with the index written, R1's signature on disk is the one the bake recorded",
		ref_mem_sig != null and _disk_entry(R1).get("stack_signature") == ref_mem_sig)
	var ref := await _reload_heights(true)
	# The crash: every region saved, the index never written, the terrain gone without a save.
	await _build(true)
	sb = ScopedBake.new(_terrain)
	sb.debug_skip_index_write = true
	var rep: Dictionary = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	# What the skipped write would have saved: this run's own in-memory entry. (Layer uids are random per
	# build, so a signature from another run says nothing.)
	var mem_sig = _terrain.data.get_region_index().get_entry(R1).get("stack_signature")
	await _teardown()
	var stale_sig = _disk_entry(R1).get("stack_signature")
	# What the bake saved, read straight from the region files before anything reloads (or recomposites) them.
	var saved := {}
	for loc in ALL:
		var f = ResourceLoader.load(DIR + "/pasture3d_%02d_%02d.res" % [loc.x, loc.y], "", ResourceLoader.CACHE_MODE_IGNORE)
		saved[loc] = f.get_height_map().get_data() if f != null else PackedByteArray()
	print("    released %s; R1's signature on disk %s, in memory at the crash %s" % [rep["released"], stale_sig, mem_sig])
	_check("witness: the index on disk is stale (R1's stack signature is not the one the bake recorded)",
		stale_sig != null and mem_sig != null and stale_sig != mem_sig)
	var got := await _reload_heights(true)
	var same := true
	var as_saved := true
	var changed := false
	for loc in ALL:
		if got.get(loc) != ref.get(loc):
			same = false
			print("    %s differs from the written run" % [loc])
		if got.get(loc) != saved.get(loc):
			as_saved = false
			print("    %s differs from its saved file" % [loc])
		if loc in TYPED and got.get(loc) != pre.get(loc):
			changed = true
	_check("editor path: every region reloads", got.size() == ALL.size())
	_check("editor path: heights equal the run whose index was written", same)
	_check("editor path: heights equal what the bake saved (the recomposite reproduces the file)", as_saved)
	_check("witness: the bake changed R1..R3 (so the compare can fail)", changed)
	_check("editor path: types and ratios are intact", _types_ok)
	# The game path: nothing loaded, the index is all there is.
	var t = ClassDB.instantiate("Pasture3D")
	t.region_loading = Pasture3D.REGION_LOADING_STREAMED
	add_child(t)
	t.data_directory = DIR
	await _frames(2)
	var idx = t.data.get_region_index()
	var ok := true
	for loc in ALL:
		if not idx.has_entry(loc):
			ok = false
			continue
		var e: Dictionary = idx.get_entry(loc)
		var want := TYPE_PATH if loc in TYPED else ""
		if String(e.get("type_path", "")) != want or int(e.get("texel_ratio", 1)) != 1:
			ok = false
			print("    index-only %s: %s" % [loc, e])
	_check("index-only path: every region indexed with its type and ratio (loaded %d)" % t.data.get_region_count(),
		ok and t.data.get_region_count() == 0)
	t.queue_free()
	await _frames(2)
	_completed += 1


# ---- fixture ---------------------------------------------------------------------------------------------

var _pre_heights := {}
var _types_ok := false


## Fresh terrain, pre-baked with everything loaded and saved, then reduced to R0, with the brushes edited so
## the bake has real work. `p_stack_change` also changes a layer's opacity while R1..R3 are unloaded, so
## their index entries carry a stack signature the bake supersedes.
func _build(p_stack_change: bool = false) -> void:
	_wipe_dir()
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in ALL:
		d.add_region_blank(loc, false)
	d.update_maps()
	var tyr = d.load_region_type(TYPE_PATH)
	for loc in TYPED:
		d.set_region_type(loc, tyr, false)
	d.update_maps()
	_mounds = [_make_mound("A", Vector3(256, 0, 128)), _make_mound("B", Vector3(512, 0, 128)),
		_make_mound("C", Vector3(768, 0, 128))]
	var pre := ScopedBake.new(_terrain)
	pre.bake(ScopedBake.Scope.ALL_LOADED)
	d.save_directory(DIR)
	_pre_heights.clear()
	for loc in ALL:
		_pre_heights[loc] = d.get_region(loc).get_height_map().get_data()
	for loc: Vector2i in ALL:
		if loc != R0:
			d.unload_region(loc, false)
	d.update_maps()
	if p_stack_change:
		var stack = d.get_layer_stack()
		stack.get_layer(stack.get_layer_count() - 1).set_opacity(0.6)
	# slope_angle, not height: the default Mound is an uncapped cone whose peak never reads `height`.
	_mounds[0].slope_angle = 38.0
	_mounds[1].slope_angle = 24.0
	_mounds[2].slope_angle = 30.0
	await get_tree().process_frame


## Reload DIR with every region loaded; {loc: height bytes}. Sets _types_ok from the loaded regions.
func _reload_heights(_p_all: bool) -> Dictionary:
	var t = ClassDB.instantiate("Pasture3D")
	t.region_loading = Pasture3D.REGION_LOADING_ALL
	add_child(t)
	t.data_directory = DIR
	await _frames(2)
	var d = t.data
	var out := {}
	_types_ok = true
	for loc in ALL:
		if not d.is_region_loaded(loc):
			d.load_region(loc, DIR)
	for loc in ALL:
		var r = d.get_region(loc)
		if r == null:
			_types_ok = false
			continue
		out[loc] = r.get_height_map().get_data()
		var want := TYPE_PATH if loc in TYPED else ""
		if String(r.get_type_path()) != want or r.get_texel_ratio() != 1:
			_types_ok = false
			print("    %s: type %s ratio %d" % [loc, r.get_type_path(), r.get_texel_ratio()])
	t.queue_free()
	await _frames(2)
	return out


func _disk_entry(p_loc: Vector2i) -> Dictionary:
	var idx = ResourceLoader.load(INDEX_FILE, "", ResourceLoader.CACHE_MODE_IGNORE)
	return idx.get_entry(p_loc) if idx != null and idx.has_entry(p_loc) else {}


func _teardown() -> void:
	_root.queue_free()
	_root = null
	_terrain = null
	_mounds = []
	await _frames(2)


func _make_mound(p_name: String, p_at: Vector3):
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	mound.add_new_layer()
	return mound


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)


func _check(p_label: String, p_ok: bool) -> void:
	print("    %s %s" % ["ok " if p_ok else "FAIL", p_label])
	if not p_ok:
		_fail += 1
