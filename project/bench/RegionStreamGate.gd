# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate ST — phase 6 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: streaming and multi-source collision (§H).
#
# The spec's proof: "Two sources far apart both keep ground collision; hysteresis doesn't thrash; the
# main-thread upload stays within budget." Around that, what else streaming has to get right: the game starts
# with nothing loaded, a streamed region is its file, a game never writes its data, and collision follows a
# region that loads or unloads under a patch that did not move.
#
# Fixture: region size 64, spacing 1. Regions (0..7, 0) and (30, 0), region (i, 0) flat at height 10 + i, all
# of a test type (load 40 m, unload 100 m). Built and saved by one terrain, then streamed by a second with
# region_loading Streamed. DYNAMIC_GAME collision, radius 32.
#
# Headless (a running scene, so not the editor: DYNAMIC_GAME builds). user:// data, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionStreamGate.tscn
extends Node

const DIR := "user://region_stream_gate"
const TYPE_PATH := DIR + "/stream_type.tres"
const RS := 64
const ROW := [0, 1, 2, 3, 4, 5, 6, 7, 30]
const GATES := 7

var _fail := 0
var _completed := 0
var _t # the streamed terrain
var _st # its Pasture3DStreamer
var _type
var _s1: Node3D
var _s2: Node3D
var _events := []


func _ready() -> void:
	print("\n=== Region streaming and multi-source collision (gate ST, streaming phase 6) ===\n")
	_wipe(DIR)
	await _build_fixture()
	var md5_before := _md5s()

	await _st1_starts_empty_and_streams_in()
	await _st2_streamed_region_is_its_file()
	await _st3_two_sources_both_collide()
	await _st4_hysteresis()
	await _st5_upload_budget()
	await _st6_collision_follows_loads()
	await _st7_never_writes(md5_before)

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION STREAM PASS" if ok else "REGION STREAM FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _build_fixture() -> void:
	var std = load("res://addons/pasture_3d/region_types/standard.tres")
	var t = std.duplicate()
	t.type_name = "StreamTest"
	t.load_radius = 40.0
	t.unload_radius = 100.0
	t.priority = 0
	ResourceSaver.save(t, TYPE_PATH)
	var b = _new_terrain(true)
	await _frames(2)
	b.change_region_size(RS)
	var d = b.data
	_type = d.load_region_type(TYPE_PATH)
	for x in ROW:
		var r = d.add_region_blank(Vector2i(x, 0), false)
		r.get_height_map().fill(Color(10 + x, 0, 0, 1))
	d.update_maps()
	for x in ROW:
		d.set_region_type(Vector2i(x, 0), _type, false)
	d.calc_height_range(true)
	d.update_maps()
	d.save_directory(DIR)
	b.queue_free()
	await _frames(2)


func _new_terrain(p_load_all: bool):
	var t = ClassDB.instantiate("Pasture3D")
	t.region_loading = Pasture3D.REGION_LOADING_ALL if p_load_all else Pasture3D.REGION_LOADING_STREAMED
	t.collision_radius = 32
	t.collision_shape_size = 16
	add_child(t)
	t.data_directory = DIR
	return t


func _st1_starts_empty_and_streams_in() -> void:
	print("[ST1] a streamed game starts with only the index, and loads what its source is near:")
	# Control: the same data with region_loading All loads every region at start.
	var all = _new_terrain(true)
	await _frames(1)
	var all_count: int = all.data.get_region_count()
	all.queue_free()
	_t = _new_terrain(false)
	await _frames(1)
	_check("control: region_loading All loads all %d at start (got %d)" % [ROW.size(), all_count], all_count == ROW.size())
	_check("the region size (%d) came from the index, not the default" % _t.get_region_size(), _t.get_region_size() == RS)
	_check("control: a terrain with no data has the default size (%d)" % ClassDB.instantiate("Pasture3D").get_region_size(),
		ClassDB.instantiate("Pasture3D").get_region_size() != RS)
	_check("streamed: 0 loaded, %d indexed" % _t.data.get_region_index().get_locations().size(),
		_t.data.get_region_count() == 0 and _t.data.get_region_index().get_locations().size() == ROW.size())
	_s1 = _source("S1", Vector3(100, 50, 32)) # in region 1; regions 0 and 2 are 36 and 28 m away
	_st = ClassDB.instantiate("Pasture3DStreamer")
	_st.sources = _nodes([_s1])
	for sig in ["region_loaded", "region_unloaded", "region_kept"]:
		_st.connect(sig, func(loc): _events.append([sig, loc]))
	_st.streaming_idle.connect(func(): _events.append(["idle", null]))
	_t.add_child(_st)
	await _until_idle()
	_check("loaded {0,1,2} (got %s)" % [_loaded()], _same(_loaded(), [0, 1, 2]))
	_check("region_loaded fired 3 times, then streaming_idle",
		_count("region_loaded") == 3 and _count("idle") >= 1 and _events.back()[0] == "idle")
	var s: Dictionary = _st.get_stats()
	_check("3 reads, all threaded (%s)" % [s], s["requests"] == 3 and s["threaded_requests"] == 3)
	_completed += 1


func _st2_streamed_region_is_its_file() -> void:
	print("[ST2] a streamed region is exactly its file:")
	var d = _t.data
	var ok := true
	for x in [0, 1, 2]:
		var h: float = d.get_height(Vector3(x * RS + 20.5, 0, 20.5))
		if not is_equal_approx(h, 10.0 + x):
			ok = false
			print("    region %d height %.3f" % [x, h])
	_check("heights 10, 11, 12 over regions 0, 1, 2", ok)
	# Control: a byte comparison against the file, through a synchronous load of the same file.
	var ref = ResourceLoader.load(DIR + "/pasture3d_01_00.res", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("region 1's height map equals a synchronous load's",
		d.get_region(Vector2i(1, 0)).get_height_map().get_data() == ref.get_height_map().get_data())
	_check("control: region 0's does not", d.get_region(Vector2i(0, 0)).get_height_map().get_data() != ref.get_height_map().get_data())
	_check("streamed regions are clean (not modified)", not d.get_region(Vector2i(1, 0)).is_modified())
	_completed += 1


func _st3_two_sources_both_collide() -> void:
	print("[ST3] two sources far apart both keep ground collision:")
	_s2 = _source("S2", Vector3(1950, 50, 32)) # region 30, 1.85 km from S1
	_st.sources = _nodes([_s1, _s2])
	await _until_idle()
	await _physics(3)
	_check("region 30 streamed in for S2 (%s)" % [_loaded()], _same(_loaded(), [0, 1, 2, 30]))
	var h1 := _ray(_s1.global_position)
	var h2 := _ray(_s2.global_position)
	var c: Dictionary = _t.collision.get_stats()
	_check("ground under S1 at %s, under S2 at %s (%d targets, %d/%d shapes)" % [h1, h2, c["targets"], c["active"], c["pool"]],
		is_equal_approx(h1, 11.0) and is_equal_approx(h2, 40.0) and c["targets"] == 2)
	# Control: without the streamer feeding its sources, collision follows one target (none set: the origin).
	_st.feed_collision = false
	await _physics(3)
	var h2c := _ray(_s2.global_position)
	_check("control: feed_collision off, nothing under S2 (%s)" % h2c, is_nan(h2c))
	_st.feed_collision = true
	await _physics(3)
	_check("  and back on, S2 has ground again", is_equal_approx(_ray(_s2.global_position), 40.0))
	_completed += 1


func _st4_hysteresis() -> void:
	print("[ST4] a source moving inside the band between load and unload radius does not thrash:")
	# S1 between x = 100 and 150: region 0 at 36..86 m (loaded, under unload 100), region 3 at 92..42 m
	# (unloaded, never under load 40).
	var n := await _oscillate(100.0, 150.0)
	_check("oscillating 100 <-> 150: %d loads/unloads" % n, n == 0)
	# Control: no hysteresis (unload radius = load radius) and region 0 unloads and reloads every swing.
	_type.unload_radius = 40.0
	var nc := await _oscillate(100.0, 150.0)
	_type.unload_radius = 100.0
	_check("control: unload radius 40 thrashes (%d loads/unloads)" % nc, nc >= 4)
	_s1.global_position = Vector3(100, 50, 32)
	await _until_idle()
	_completed += 1


func _st5_upload_budget() -> void:
	print("[ST5] the main thread adopts within its per-frame budget:")
	# Reads synchronous here, so every region is ready in the same frame and only the budget spreads them.
	_st.threaded = false
	_st.max_pending_loads = 16
	var runs := {}
	for cfg in [[1, 1000.0], [16, 1000.0], [16, 0.0]]:
		_s1.global_position = Vector3(100, 50, 5000) # out of range of everything: all release
		_st.sources = _nodes([_s1])
		await _until_idle()
		_type.load_radius = 400.0
		_type.unload_radius = 500.0
		_st.max_adopts_per_frame = cfg[0]
		_st.adopt_budget_msec = cfg[1]
		_st.reset_stats()
		_s1.global_position = Vector3(256, 50, 32) # every row region within 400 m
		await _until_idle()
		var s: Dictionary = _st.get_stats()
		runs[cfg] = s
		_type.load_radius = 40.0
		_type.unload_radius = 100.0
		print("    max_adopts %d, budget %.0f ms: adopted %d, at most %d in a frame, frames %d" %
			[cfg[0], cfg[1], s["adopted"], s["max_adopts_in_frame"], s["frames"]])
	var one: Dictionary = runs[[1, 1000.0]]
	var many: Dictionary = runs[[16, 1000.0]]
	var timed: Dictionary = runs[[16, 0.0]]
	_check("max 1 per frame: 8 adopted, never more than 1 in a frame", one["adopted"] == 8 and one["max_adopts_in_frame"] == 1)
	_check("control: max 16 adopts more than 1 in a frame (%d)" % many["max_adopts_in_frame"],
		many["adopted"] == 8 and many["max_adopts_in_frame"] > 1)
	_check("a 0 ms budget stops the frame after one adopt, whatever the count (%d)" % timed["max_adopts_in_frame"],
		timed["adopted"] == 8 and timed["max_adopts_in_frame"] == 1)
	_st.threaded = true
	_st.max_pending_loads = 4
	_st.max_adopts_per_frame = 1
	_st.adopt_budget_msec = 4.0
	_s1.global_position = Vector3(100, 50, 32)
	await _until_idle()
	_completed += 1


func _st6_collision_follows_loads() -> void:
	print("[ST6] collision follows a region loaded or released under a patch that did not move:")
	var d = _t.data
	_st.enabled = false
	var s3 := _source("S3", Vector3(5 * RS + 32, 50, 32)) # over region 5, which is not loaded
	_t.set_collision_targets(_nodes([_s1, s3]))
	await _physics(3)
	_check("control: nothing under S3 while region 5 is unloaded (%s)" % _ray(s3.global_position), is_nan(_ray(s3.global_position)))
	var body_before: RID = _t.collision.get_rid()
	d.load_region(Vector2i(5, 0), DIR)
	await _physics(3)
	_check("region 5 loaded, S3 has ground at %s" % _ray(s3.global_position), is_equal_approx(_ray(s3.global_position), 15.0))
	_check("  the collision body was not rebuilt for it (same RID)", _t.collision.get_rid() == body_before)
	d.release_region(Vector2i(5, 0))
	await _physics(3)
	_check("region 5 released, nothing under S3 again", is_nan(_ray(s3.global_position)))
	# Control: a rebuild (what every region-map change used to trigger) replaces the body.
	_t.collision.build()
	_check("control: build() gives the body a new RID", _t.collision.get_rid() != body_before)
	await _physics(2)
	s3.queue_free()
	_st.enabled = true
	await _until_idle()
	_completed += 1


func _st7_never_writes(p_md5_before: Dictionary) -> void:
	print("[ST7] streaming never writes, and keeps a region whose changes are not on disk:")
	var d = _t.data
	_check("every region file is unchanged after all the streaming", _md5s() == p_md5_before)
	# Runtime deformation of region 1, then its source leaves.
	var r = d.get_region(Vector2i(1, 0))
	r.get_height_map().set_pixel(3, 3, Color(99, 0, 0, 1))
	r.set_modified(true)
	_events.clear()
	_s1.global_position = Vector3(100, 50, 5000)
	await _until_idle()
	_check("region 1 kept loaded, and reported once (%s)" % [_loaded()],
		_loaded().has(1) and _count("region_kept") == 1 and not _loaded().has(0))
	_check("  its file is unchanged", _md5s() == p_md5_before)
	# Control: the editor's unload of the same region saves it first, and the file changes.
	d.unload_region(Vector2i(1, 0))
	_check("control: unload_region writes it", _md5s()["pasture3d_01_00.res"] != p_md5_before["pasture3d_01_00.res"])
	_completed += 1


# --- helpers -----------------------------------------------------------------------------------

func _nodes(p_list: Array) -> Array[Node3D]:
	var out: Array[Node3D] = []
	out.assign(p_list)
	return out


func _source(p_name: String, p_pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = p_name
	add_child(n)
	n.global_position = p_pos
	return n


func _oscillate(p_a: float, p_b: float) -> int:
	_events.clear()
	for i in 12:
		_s1.global_position = Vector3(p_a if i % 2 == 0 else p_b, 50, 32)
		for f in 8:
			await get_tree().process_frame
	await _until_idle()
	return _count("region_loaded") + _count("region_unloaded")


func _until_idle() -> void:
	# At least two frames (a move needs a tick to be seen), then until the streamer says idle.
	await _frames(2)
	for i in 600:
		if _st.is_idle():
			return
		await get_tree().process_frame
	_check("streamer went idle within 600 frames", false)


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame


func _ray(p_at: Vector3) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(p_at.x, 500, p_at.z), Vector3(p_at.x, -500, p_at.z))
	var hit := space.intersect_ray(q)
	return hit["position"].y if hit else NAN


func _loaded() -> Array:
	var xs := []
	for loc in _t.data.get_region_locations():
		if _t.data.is_region_loaded(loc):
			xs.append(loc.x)
	xs.sort()
	return xs


func _count(p_kind: String) -> int:
	var n := 0
	for e in _events:
		if e[0] == p_kind:
			n += 1
	return n


func _md5s() -> Dictionary:
	var out := {}
	for f in DirAccess.get_files_at(DIR):
		if f.begins_with("pasture3d_") and f.ends_with(".res") and not f.begins_with("pasture3d_layers") \
				and f != "pasture3d_region_index.res":
			out[f] = FileAccess.get_md5(DIR + "/" + f)
	return out


func _same(p_a: Array, p_b: Array) -> bool:
	var a := p_a.duplicate()
	var b := p_b.duplicate()
	a.sort()
	b.sort()
	return a == b


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
