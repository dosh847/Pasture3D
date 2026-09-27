# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Probe — what an "All regions" bake holds in memory (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md, the
# memory investigation after the phase table). A MEASUREMENT, not a pass/fail gate: it prints numbers. Its
# witnesses and controls still fail it, so a run that measured nothing cannot read as a clean result.
#
# Two fixtures, N x N regions, every region unloaded when the bake starts:
#   F1  the default layering: one Mound per region, all on the shared "Mounds" layer, so ONE owner
#   F2  one layer per brush: a Mound straddling each right and each lower region boundary, created in a
#       shuffled order (layer order = creation order, spatially arbitrary)
#   F3  one Mound per region, each on its own layer, each with a Frozen erosion modifier, so it fills the
#       erosion cache F1 and F2 cannot (their witness). A modifier stack still takes the native
#       stamp_mound_loop route, which never fills the stamp cache: only GDScript fallbacks do.
#
# The bake is the real one: a Pasture3DSimManager with every brush registered, scope All Regions,
# `bake_all_brushes_now`. So the undo snapshots measured are the ones Bake All keeps, not the probe's own.
# `--unfiltered` sets `debug_unfiltered_undo`, the pre-M1 snapshots (PASTURE3D_BAKE_MEMORY_SPEC.md U3).
# `--index-per-unload` sets `debug_index_per_unload`, the pre-M3 index writes (I3).
#
# Measured on each:
#   [P] peak loaded regions during the bake. Also the peak the SAME refcount rule would reach under an
#       order that keeps only the constraint that matters (an owner after every LOWER owner it shares a
#       region with), chosen greedily; computed from the plan by a simulator. Witness: the simulator
#       reproduces the measured peak for the order the bake actually used.
#   [F] whether a released region and its layer tiles are freed: weakrefs taken at load, counted alive
#       after the bake. Control: one region deliberately held must count as alive.
#   [S] what stays after the bake: slot capacity, stamp-cache bytes on the brushes, and the bytes Bake
#       All's undo snapshots hold, split into regions that were loaded for the bake (which a restore skips
#       by generation) and the rest. MEMORY_STATIC deltas; the peak is sampled at every region load and
#       unload, where the working set changes.
#
# Headless. Writes only under user://region_bake_memory_probe.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionBakeMemoryProbe.tscn
#      [-- --n=6 --size=256 --fixtures=F1,F2,F3 --unfiltered]   (the large-world run: --n=16 --size=1024)
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")
const DIR := "user://region_bake_memory_probe"
var N := 6
var RS := 256.0
var _fixtures: Array = ["F1", "F2", "F3"]
var _unfiltered := false
var _index_per_unload := false

var _fail := 0
var _done := 0
var CRITERIA := 0
var _root: Node3D
var _terrain
var _loaded_now := 0
var _peak_loaded := 0
var _peak_mem := 0
var _alive_refs: Array = [] # [loc, WeakRef]


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			N = int(a.substr(4))
		elif a.begins_with("--size="):
			RS = float(a.substr(7))
		elif a.begins_with("--fixtures="):
			_fixtures = Array(a.substr(11).split(","))
		elif a == "--unfiltered":
			_unfiltered = true
		elif a == "--index-per-unload":
			_index_per_unload = true
	CRITERIA = _fixtures.size() * 3 + (1 if _fixtures.has("F3") else 0)
	print("\n=== Region bake memory probe (N = %d, region %d m, %s%s) ===" % [N, int(RS), ",".join(_fixtures),
		(", UNFILTERED undo (pre-M1)" if _unfiltered else "") + (", index per unload (pre-M3)" if _index_per_unload else "")])
	for fixture in _fixtures:
		await _run_fixture(fixture)
	print("process static peak (Godot allocator, whole run): %.1f MB" % (OS.get_static_memory_peak_usage() / 1048576.0))
	var ok := _fail == 0 and _done == CRITERIA
	print("\n=== REGION BAKE MEMORY PROBE %s (%d failures, %d/%d criteria completed) ===" % [
		"DONE" if ok else "FAIL", _fail, _done, CRITERIA])
	get_tree().quit(0 if ok else 1)


func _run_fixture(p_fixture: String) -> void:
	print("\n---- %s ----" % p_fixture)
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
	var brushes: Array = _make_brushes(p_fixture)
	# Every owner's layer exists and is on disk; then start from nothing loaded.
	var pre := ScopedBake.new(_terrain)
	pre.budget_regions = 0 # the shared-layer owner of F1 is the whole world, far over the default 64
	pre.bake(ScopedBake.Scope.ALL_LOADED)
	d.save_directory(DIR)
	for loc: Vector2i in d.get_region_locations().duplicate():
		d.unload_region(loc, false)
	d.update_maps()
	for b in brushes:
		b.slope_angle = b.slope_angle + 3.0 # real work for the bake
	await get_tree().process_frame

	var sb := ScopedBake.new(_terrain)
	sb.budget_regions = 0 # measure, never skip
	var t_plan := Time.get_ticks_usec()
	var plan: Dictionary = sb.plan(ScopedBake.Scope.ALL_REGIONS)
	t_plan = Time.get_ticks_usec() - t_plan
	print("plan %.2f s, %d dependency edges (the bake plans again; this is its cost)" % [t_plan / 1e6, int(plan.get("edges", 0))])
	var owners: Array = plan["owners"]
	var widest := 0
	for od: Dictionary in owners:
		widest = maxi(widest, (od["regions"] as Array).size())
	print("owners %d, working set %d regions, widest owner %d regions, layers %d" % [
		owners.size(), (plan["working_set"] as Array).size(), widest, d.get_layer_stack().get_layer_count()])

	# ---- the bake: Bake All Brushes, every brush registered, scope All Regions ----
	var mgr := Pasture3DSimManager.new()
	mgr.name = "Sim"
	_root.add_child(mgr)
	mgr.terrain = _terrain
	var paths: Array[NodePath] = []
	for b in brushes:
		paths.append(mgr.get_path_to(b))
	mgr.eroding_brushes = paths
	mgr.bake_scope = 2
	mgr.bake_budget_regions = 0
	mgr.debug_unfiltered_undo = _unfiltered
	mgr.debug_index_per_unload = _index_per_unload
	d.reset_upload_stats()
	_loaded_now = 0
	_peak_loaded = 0
	_alive_refs.clear()
	d.region_loaded.connect(_on_loaded)
	d.region_unloaded.connect(_on_unloaded)
	var mem0 := _mem()
	_peak_mem = mem0
	var cap0: int = d.get_slot_capacity()
	var t_bake := Time.get_ticks_usec()
	var rep: Dictionary = mgr.bake_all_brushes_now()
	t_bake = Time.get_ticks_usec() - t_bake
	var ws: Dictionary = d.get_upload_stats()
	print("bake %.1f s, of which releasing (save + unload) %.1f s, %d owners baked; index writes %d, manifest writes %d (%d skipped)"
		% [t_bake / 1e6, int(rep.get("release_usec", 0)) / 1e6, int(rep.get("owners", 0)), int(ws.index_writes),
			int(ws.manifest_writes), int(ws.manifest_skips)])
	var before: Dictionary = rep["undo"]["before"]
	var after: Dictionary = rep["undo"]["after"]
	var order: Array = []
	for e: Array in rep.get("events", []):
		if e[0] == "bake" and not order.has(e[1]):
			order.append(e[1])
	d.region_loaded.disconnect(_on_loaded)
	d.region_unloaded.disconnect(_on_unloaded)
	await get_tree().process_frame
	await get_tree().process_frame
	var mem_after := _mem()
	if order.size() != owners.size():
		_fail += 1
		print("!! Bake All baked %d owners of the %d planned; the rest of this fixture measures a different bake"
			% [order.size(), owners.size()])

	# ---- [P] peak working set ----
	print("[P] peak loaded regions:")
	var sim_used := _simulate_peak(owners, order)
	var greedy := _greedy_order(owners)
	var sim_greedy := _simulate_peak(owners, greedy)
	print("    measured %d of %d (loaded_for_bake %d, released %d)" % [_peak_loaded, N * N,
		(rep["loaded_for_bake"] as Array).size(), (rep["released"] as Array).size()])
	print("    simulated, the order used: %d   (witness: must equal measured)" % sim_used)
	print("    simulated, overlap-constrained greedy order: %d   (lower bound: widest owner %d)" % [sim_greedy, widest])
	if sim_used != _peak_loaded:
		_fail += 1
		print("    !! the simulator does not reproduce the bake; its other numbers mean nothing")
	if _peak_loaded == 0:
		_fail += 1
		print("    !! nothing was loaded; the fixture did not start unloaded")
	_done += 1

	# ---- [F] released regions freed ----
	print("[F] released regions and their layer tiles are freed:")
	var alive := 0
	for e: Array in _alive_refs:
		if (e[1] as WeakRef).get_ref() != null:
			alive += 1
	print("    weakrefs taken at load: %d, still alive after the bake: %d" % [_alive_refs.size(), alive])
	# Control: hold one region and its tiles, release it, and the count must see it.
	var ctrl_loc := Vector2i(0, 0)
	d.load_region(ctrl_loc, DIR, false)
	var held = d.get_region(ctrl_loc)
	var ctrl_ref: WeakRef = weakref(held)
	d.unload_region(ctrl_loc, false)
	d.update_maps()
	var ctrl_alive: bool = ctrl_ref.get_ref() != null
	held = null
	var ctrl_freed: bool = ctrl_ref.get_ref() == null
	print("    control: a region held by a variable is alive after unload %s, freed once dropped %s" % [
		str(ctrl_alive), str(ctrl_freed)])
	if not ctrl_alive or not ctrl_freed:
		_fail += 1
		print("    !! the weakref count cannot see retention; [F] measures nothing")
	_done += 1

	# ---- [S] what stays after the bake ----
	print("[S] what the bake leaves behind:")
	var loaded_for := {}
	for r in rep["loaded_for_bake"]:
		loaded_for[r] = true
	var snap := _snapshot_bytes(before, loaded_for)
	var snap2 := _snapshot_bytes(after, loaded_for)
	var stamp := 0
	var stamp_entries := 0
	var ero := 0
	for b in brushes:
		stamp_entries += b._stamp_cache.size()
		for k in b._stamp_cache:
			stamp += (b._stamp_cache[k]["vals"] as PackedFloat32Array).size() * 4
		for m in b.modifiers:
			if m != null and m.has_method("cache_bytes"):
				ero += m.cache_bytes()
	var region_bytes := _region_bytes_estimate()
	print("    slot capacity %d before the bake (setup had all loaded), %d after with %d regions loaded" % [
		cap0, d.get_slot_capacity(), d.get_region_count()])
	print("    undo snapshots: before %s, after %s (MB: total / of regions loaded for the bake)" % [
		_mb2(snap), _mb2(snap2)])
	# A modifier-free Mound takes the native stamp_mound_loop route, which never fills the stamp cache, so
	# 0 entries is the route, not a finding (a modifier stack is native too).
	print("    stamp caches on brushes: %.2f MB in %d entries; frozen erosion caches: %.2f MB" % [
		stamp / 1048576.0, stamp_entries, ero / 1048576.0])
	print("    GPU arrays at that capacity (height + control + colour, no mips): %.1f MB" % (
		d.get_slot_capacity() * RS * RS * 12.0 / 1048576.0))
	if p_fixture == "F3":
		if ero == 0:
			_fail += 1
			print("    !! F3 filled no erosion cache; the witness for the brush-cache measure failed")
		_done += 1
	print("    one region's own maps ~%.2f MB; the whole world's %.2f MB" % [region_bytes / 1048576.0,
		region_bytes * N * N / 1048576.0])
	print("    MEMORY_STATIC: start %.1f MB, peak %.1f MB (sampled at loads and unloads), after bake %.1f MB (%+.1f%%)"
		% [mem0 / 1048576.0, _peak_mem / 1048576.0, mem_after / 1048576.0, 100.0 * (mem_after - mem0) / mem0])
	before.clear()
	after.clear()
	for b in brushes:
		b._stamp_cache.clear()
	await get_tree().process_frame
	for b in brushes:
		for m in b.modifiers:
			if m != null and m.has_method("clear_cache"):
				m.clear_cache()
	await get_tree().process_frame
	var mem_dropped := _mem()
	print("    after dropping the snapshots and brush caches: %.1f MB (%.1f MB freed)" % [
		mem_dropped / 1048576.0, (mem_after - mem_dropped) / 1048576.0])
	if _unfiltered and snap[0] == 0:
		_fail += 1
		print("    !! the unfiltered snapshots are empty; the owners painted nothing")
	if not _unfiltered and snap[1] != 0:
		_fail += 1
		print("    !! M1: the snapshots hold regions the bake loaded")
	_done += 1
	_time_writes(d)

	_root.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _make_brushes(p_fixture: String) -> Array:
	var out: Array = []
	if p_fixture == "F1":
		for j in N:
			for i in N:
				out.append(_mound("M_%d_%d" % [i, j], Vector3((i + 0.5) * RS, 0, (j + 0.5) * RS), RS * 0.23, false))
		return out
	if p_fixture == "F3":
		for j in N:
			for i in N:
				var m = _mound("E_%d_%d" % [i, j], Vector3((i + 0.5) * RS, 0, (j + 0.5) * RS), RS * 0.23, true)
				var e := Pasture3DNodeErosion.new()
				e.label = "Erosion"
				e.iterations = 4
				e.erosion_rate = 0.05
				var mods: Array[Pasture3DNode] = [e]
				m.modifiers = mods
				out.append(m)
		return out
	var spots: Array = []
	for j in N:
		for i in N:
			if i < N - 1:
				spots.append(Vector3((i + 1) * RS, 0, (j + 0.5) * RS))
			if j < N - 1:
				spots.append(Vector3((i + 0.5) * RS, 0, (j + 1) * RS))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in range(spots.size() - 1, 0, -1): # Fisher-Yates, seeded
		var s := rng.randi_range(0, k)
		var t = spots[k]
		spots[k] = spots[s]
		spots[s] = t
	for k in spots.size():
		out.append(_mound("S_%d" % k, spots[k], RS * 0.16, true))
	return out


func _mound(p_name: String, p_at: Vector3, p_half: float, p_own_layer: bool):
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
	if p_own_layer:
		mound.add_new_layer()
	return mound


## The scoped bake's refcount rule, replayed over an order: an owner loads its regions, and a region is
## released once every owner touching it has baked. Returns the peak number loaded at once.
static func _simulate_peak(p_owners: Array, p_order: Array) -> int:
	var by_name := {}
	var refs := {}
	for od: Dictionary in p_owners:
		by_name[od["key"]] = od
		for r in od["regions"]:
			refs[r] = int(refs.get(r, 0)) + 1
	var loaded := {}
	var peak := 0
	for name in p_order:
		var od: Dictionary = by_name[name]
		for r in od["regions"]:
			loaded[r] = true
		peak = maxi(peak, loaded.size())
		for r in od["regions"]:
			refs[r] = int(refs[r]) - 1
			if int(refs[r]) <= 0:
				loaded.erase(r)
	return peak


## An order that keeps only the constraint that matters: an owner bakes after every LOWER owner it shares
## a region with. Greedy among the ready owners: fewest new loads, then most releases.
static func _greedy_order(p_owners: Array) -> Array:
	var preds := {}
	for a: Dictionary in p_owners:
		var ps := {}
		for b: Dictionary in p_owners:
			if int(b["order"]) < int(a["order"]) and _share(a["regions"], b["regions"]):
				ps[b["key"]] = true
		preds[a["key"]] = ps
	var refs := {}
	for od: Dictionary in p_owners:
		for r in od["regions"]:
			refs[r] = int(refs.get(r, 0)) + 1
	var done := {}
	var loaded := {}
	var order: Array = []
	while order.size() < p_owners.size():
		var best: Dictionary = {}
		var best_score: Array = [INF, INF]
		for od: Dictionary in p_owners:
			if done.has(od["key"]):
				continue
			var ready := true
			for p in preds[od["key"]]:
				if not done.has(p):
					ready = false
					break
			if not ready:
				continue
			var fresh := 0
			var frees := 0
			for r in od["regions"]:
				if not loaded.has(r):
					fresh += 1
				if int(refs[r]) == 1:
					frees += 1
			var score: Array = [float(fresh), float(-frees)]
			if score[0] < best_score[0] or (score[0] == best_score[0] and score[1] < best_score[1]):
				best_score = score
				best = od
		done[best["key"]] = true
		order.append(best["key"])
		for r in best["regions"]:
			loaded[r] = true
			refs[r] = int(refs[r]) - 1
			if int(refs[r]) <= 0:
				loaded.erase(r)
	return order


static func _share(p_a: Array, p_b: Array) -> bool:
	for r in p_a:
		if p_b.has(r):
			return true
	return false


func _on_loaded(p_loc: Vector2i) -> void:
	_loaded_now += 1
	_peak_loaded = maxi(_peak_loaded, _loaded_now)
	_peak_mem = maxi(_peak_mem, _mem())
	var d = _terrain.data
	_alive_refs.append([p_loc, weakref(d.get_region(p_loc))])
	var stack = d.get_layer_stack()
	if stack != null:
		for i in stack.get_layer_count():
			var tiles: Dictionary = stack.get_layer(i).get_tiles()
			if tiles.has(p_loc):
				for coord in tiles[p_loc]:
					if tiles[p_loc][coord] != null:
						_alive_refs.append([p_loc, weakref(tiles[p_loc][coord])])


func _on_unloaded(_p_loc: Vector2i) -> void:
	_loaded_now -= 1
	_peak_mem = maxi(_peak_mem, _mem())


## [total bytes, bytes in regions loaded for the bake] over a {owner: {layer_owner: {loc: {coord: Image}}}}.
static func _snapshot_bytes(p_snaps: Dictionary, p_loaded_for: Dictionary) -> Array:
	var total := 0
	var dead := 0
	for owner in p_snaps:
		var snap: Dictionary = p_snaps[owner]
		for layer_owner in snap:
			var tiles = snap[layer_owner]
			if not (tiles is Dictionary):
				continue
			for loc in tiles:
				if not (tiles[loc] is Dictionary):
					continue
				for coord in tiles[loc]:
					var img: Image = tiles[loc][coord]
					if img == null:
						continue
					var n: int = img.get_data().size()
					total += n
					if p_loaded_for.has(loc):
						dead += n
	return [total, dead]


func _region_bytes_estimate() -> int:
	var d = _terrain.data
	d.load_region(Vector2i(1, 1), DIR, false)
	var r = d.get_region(Vector2i(1, 1))
	var n := 0
	for img in [r.get_height_map(), r.get_control_map(), r.get_color_map()]:
		if img != null:
			n += img.get_data().size()
	d.unload_region(Vector2i(1, 1), false)
	return n


static func _mb2(p: Array) -> String:
	return "%.2f / %.2f" % [p[0] / 1048576.0, p[1] / 1048576.0]


static func _mem() -> int:
	return int(Performance.get_monitor(Performance.MEMORY_STATIC))


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)


## [W] What one index write and one manifest write cost on this world (PASTURE3D_BAKE_MEMORY_SPEC.md I3), so
## the per-release writes M3 removed can be priced: the index timed directly, the manifest as the difference
## between an unload that writes it (a layer renamed first) and one that skips it. Medians of 5.
func _time_writes(d) -> void:
	var t_index: Array = []
	for i in 5:
		var t0 := Time.get_ticks_usec()
		d.write_region_index()
		t_index.append(Time.get_ticks_usec() - t0)
	var loc := Vector2i(0, 0)
	var stack = d.get_layer_stack()
	var t_skip: Array = []
	var t_write: Array = []
	for i in 5:
		for renamed in [false, true]:
			d.load_region(loc, _terrain.data_directory)
			if renamed and stack != null and stack.get_layer_count() > 1:
				stack.get_layer(1).set_layer_name("probe_%d" % i)
			var t0 := Time.get_ticks_usec()
			d.unload_region(loc)
			(t_write if renamed else t_skip).append(Time.get_ticks_usec() - t0)
	t_index.sort()
	t_skip.sort()
	t_write.sort()
	print("[W] one index write %.1f ms; one manifest write %.1f ms (unload %.1f ms with it, %.1f ms without)"
		% [t_index[2] / 1000.0, (t_write[2] - t_skip[2]) / 1000.0, t_write[2] / 1000.0, t_skip[2] / 1000.0])
