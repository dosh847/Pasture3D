# Gate B — phase 7 of PASTURE3D_BAKE_MEMORY_SPEC.md (M7): a byte budget with back-pressure.
#
# `budget_regions` skips an owner too big on its own; nothing limited how much was loaded at once. Now the
# scheduler keeps the estimated bytes of the planned regions it holds under `memory_budget_mb`: owners that
# fit go first, and when none does it releases regions early (saving them) and loads them again when needed.
# Under test:
#   [B1] with a budget every owner fits in, the bake's gauge never exceeds it, back-pressure happened, and the
#        gauge's peak equals the scheduler's simulated peak. Control: no budget peaks above it. With a budget
#        smaller than some owners, exactly those owners are reported over budget, and the manager warns.
#   [B2] heights are byte-identical with and without the budget, through the scoped bake and Bake All, and
#        with the tiny budget. Control: releasing early WITHOUT saving loses the edits and differs.
#   [B3] reported: loads and wall time with the budget against without (reloads cost I/O). Witness: the
#        budgeted bake loaded more.
#
# Fixture: RegionBakeOrderGate's (4 x 4 regions of 128 m, all unloaded at the bake, overlapping Mounds on
# shuffled layers, two eroded Mounds on top).
#
# Data lives in user://region_bake_budget_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionBakeBudgetGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_bake_budget_gate"
const RS := 128.0
const N := 4
const MB := 1048576.0

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _brushes: Array = []
var _loaded_now := 0
var _peak := 0


func _ready() -> void:
	print("\n=== Region bake budget (gate B, bake memory phase 7) ===\n")
	# The budget: 1.25 x the largest owner's estimated bytes, so every owner fits but the schedule cannot keep
	# its unbudgeted working set. The tiny one: one byte over the biggest two-region owner (a region's cost
	# carries every overlapping layer's tiles), so the small Mounds fit and the four-region wide and eroded do not.
	await _build()
	var sb := ScopedBake.new(_terrain)
	sb.budget_regions = 0
	var p: Dictionary = sb.plan(ScopedBake.Scope.ALL_REGIONS)
	var costs: Dictionary = p["costs"]
	var widest := 0
	var pair := 0
	var owner_bytes := {}
	for od: Dictionary in p["owners"]:
		var b := 0
		for r: Vector2i in od["regions"]:
			b += int(costs[r])
		owner_bytes[od["key"]] = b
		if (od["regions"] as Array).size() <= 2:
			pair = maxi(pair, b)
		widest = maxi(widest, b)
	await _teardown()
	var budget := widest * 1.25 / MB
	var tiny := (pair + 1) / MB
	print("  largest owner %.3f MB; budget %.3f MB, tiny %.3f MB" % [widest / MB, budget, tiny])
	var none: Dictionary = await _run("none", 0.0)
	var fit: Dictionary = await _run("fit", budget)
	var small: Dictionary = await _run("tiny", tiny)
	var unsaved: Dictionary = await _run("unsaved", budget)
	var mgr_none: Dictionary = await _run("mgr_none", 0.0)
	var mgr_fit: Dictionary = await _run("mgr_fit", budget)
	_b1(none, fit, small, owner_bytes, budget, tiny)
	_b2(none, fit, small, unsaved, mgr_none, mgr_fit)
	_b3(none, fit)
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION BAKE BUDGET PASS" if ok else "REGION BAKE BUDGET FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- B1 ---------------------------------------------------------------------------------------------------
func _b1(p_none: Dictionary, p_fit: Dictionary, p_tiny: Dictionary, p_owner_bytes: Dictionary, p_budget: float,
		p_tiny_mb: float) -> void:
	print("[B1] the gauge stays under the budget:")
	var bb := int(p_budget * MB)
	print("    gauge peak: none %.3f MB, fit %.3f MB (simulated %.3f), budget %.3f MB; evicted %d; over budget %s"
		% [int(p_none["peak_bytes"]) / MB, int(p_fit["peak_bytes"]) / MB, int(p_fit["sim_peak_bytes"]) / MB,
		p_budget, (p_fit["evicted"] as Array).size(), p_fit["over_budget"]])
	_check("the budgeted gauge never exceeds the budget, and no owner was over it",
		int(p_fit["peak_bytes"]) > 0 and int(p_fit["peak_bytes"]) <= bb and (p_fit["over_budget"] as Array).is_empty())
	_check("back-pressure happened (regions released early)", not (p_fit["evicted"] as Array).is_empty())
	_check("the gauge's peak is the scheduler's simulated peak",
		int(p_fit["peak_bytes"]) == int(p_fit["sim_peak_bytes"]))
	_check("control: without a budget the gauge peaks above it", int(p_none["peak_bytes"]) > bb)
	var tb := int(p_tiny_mb * MB)
	var want: Array = []
	for k in p_owner_bytes:
		if int(p_owner_bytes[k]) > tb:
			want.append(String(k))
	var got: Array = []
	for k in p_tiny["over_budget"]:
		got.append(String(k))
	want.sort()
	got.sort()
	print("    tiny budget: %d of %d owner(s) bigger than it, %d reported over it" % [want.size(),
		p_owner_bytes.size(), got.size()])
	_check("with the tiny budget, exactly the owners bigger than it are reported over budget",
		not want.is_empty() and want.size() < p_owner_bytes.size() and got == want)
	var mgr := Pasture3DSimManager.new()
	mgr.bake_memory_budget_mb = 1.0
	mgr.last_bake_report = {"over_budget": ["layer#3"]}
	var w := mgr._registry_warnings()
	var warned := _has(w, "memory budget") and _has(w, "layer#3")
	mgr.last_bake_report = {"over_budget": []}
	var quiet := not _has(mgr._registry_warnings(), "memory budget")
	mgr.free()
	_check("the manager warns about owners over the budget (control: and not when none was)", warned and quiet)
	_completed += 1


# --- B2 ---------------------------------------------------------------------------------------------------
func _b2(p_none: Dictionary, p_fit: Dictionary, p_tiny: Dictionary, p_unsaved: Dictionary, p_mgr_none: Dictionary,
		p_mgr_fit: Dictionary) -> void:
	print("[B2] the budget does not change the bytes:")
	var d_fit := _differing(p_fit["heights"], p_none["heights"])
	var d_tiny := _differing(p_tiny["heights"], p_none["heights"])
	var d_mgr := _differing(p_mgr_fit["heights"], p_mgr_none["heights"])
	var d_uns := _differing(p_unsaved["heights"], p_none["heights"])
	var moved := _differing(p_none["heights"], p_none["pre"])
	print("    differing from no budget: fit %s, tiny %s, Bake All %s (evicted %d),"
		% [d_fit, d_tiny, d_mgr, (p_mgr_fit["evicted"] as Array).size()])
	print("    unsaved control %d region(s) (evicted %d); changed by the bake %d of %d" % [d_uns.size(),
		(p_unsaved["evicted"] as Array).size(), moved.size(), N * N])
	_check("witness: the bake changed regions (so the compare can fail)", moved.size() > 0)
	_check("budgeted == unbudgeted on all 16 regions, byte for byte",
		d_fit.is_empty() and (p_fit["heights"] as Dictionary).size() == N * N)
	_check("with the tiny budget too", d_tiny.is_empty())
	_check("through Bake All too, which also released early",
		d_mgr.is_empty() and not (p_mgr_fit["evicted"] as Array).is_empty())
	_check("control: releasing early without saving differs", not d_uns.is_empty())
	_completed += 1


# --- B3 ---------------------------------------------------------------------------------------------------
func _b3(p_none: Dictionary, p_fit: Dictionary) -> void:
	print("[B3] what the budget costs:")
	print("    loads: none %d, fit %d; wall: none %.2f s, fit %.2f s; save + unload: none %.2f s, fit %.2f s"
		% [(p_none["loaded"] as Array).size(), (p_fit["loaded"] as Array).size(), int(p_none["usec"]) / 1e6,
		int(p_fit["usec"]) / 1e6, int(p_none["release_usec"]) / 1e6, int(p_fit["release_usec"]) / 1e6])
	print("    peak loaded regions: none %d, fit %d" % [p_none["peak"], p_fit["peak"]])
	_check("witness: the budgeted bake loaded more (its early releases were loaded again)",
		(p_fit["loaded"] as Array).size() > (p_none["loaded"] as Array).size())
	_completed += 1


# ---- one bake --------------------------------------------------------------------------------------------

## Build the fixture, bake it with `p_budget_mb`, and return the report's gauge keys, heights and timings.
func _run(p_mode: String, p_budget_mb: float) -> Dictionary:
	await _build()
	var d = _terrain.data
	_loaded_now = 0
	_peak = 0
	d.region_loaded.connect(_on_loaded)
	d.region_unloaded.connect(_on_unloaded)
	var out := {"pre": _pre.duplicate()}
	var t0 := Time.get_ticks_usec()
	var rep: Dictionary
	if p_mode.begins_with("mgr_"):
		var mgr := Pasture3DSimManager.new()
		mgr.name = "Sim"
		_root.add_child(mgr)
		mgr.terrain = _terrain
		var paths: Array[NodePath] = []
		for b in _brushes:
			paths.append(mgr.get_path_to(b))
		mgr.eroding_brushes = paths
		mgr.bake_scope = 2
		mgr.bake_budget_regions = 0
		mgr.bake_memory_budget_mb = p_budget_mb
		rep = mgr.bake_all_brushes_now()
	else:
		var sb := ScopedBake.new(_terrain)
		sb.budget_regions = 0
		sb.memory_budget_mb = p_budget_mb
		sb.debug_evict_unsaved = p_mode == "unsaved"
		rep = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	out["usec"] = Time.get_ticks_usec() - t0
	d.region_loaded.disconnect(_on_loaded)
	d.region_unloaded.disconnect(_on_unloaded)
	out["peak"] = _peak
	for k in ["peak_bytes", "sim_peak_bytes", "evicted", "over_budget", "release_usec"]:
		out[k] = rep.get(k, 0)
	out["loaded"] = rep.get("loaded_for_bake", [])
	var heights := {}
	for j in N:
		for i in N:
			var loc := Vector2i(i, j)
			if not d.is_region_loaded(loc):
				d.load_region(loc, DIR, false)
			heights[loc] = d.get_region(loc).get_height_map().get_data()
	out["heights"] = heights
	print("  %s: ok %s, budget %.3f MB, gauge peak %.3f MB, evicted %d, over budget %d, loads %d, peak loaded %d"
		% [p_mode, rep.get("ok"), p_budget_mb, int(out["peak_bytes"]) / MB, (out["evicted"] as Array).size(),
		(out["over_budget"] as Array).size(), (out["loaded"] as Array).size(), _peak])
	await _teardown()
	return out


static func _has(p_w: PackedStringArray, p_needle: String) -> bool:
	for s in p_w:
		if s.contains(p_needle):
			return true
	return false


# ---- fixture ---------------------------------------------------------------------------------------------

var _pre := {}


func _build() -> void:
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
	# [kind, position]; created in a seeded shuffled order, so layer order is spatially arbitrary.
	var specs: Array = []
	for j in N:
		for i in N:
			if i < N - 1:
				specs.append(["small", Vector3((i + 1) * RS, 0, (j + 0.5) * RS)])
			if j < N - 1:
				specs.append(["small", Vector3((i + 0.5) * RS, 0, (j + 1) * RS)])
	for c in [Vector2i(1, 1), Vector2i(3, 1), Vector2i(1, 3), Vector2i(3, 3), Vector2i(2, 2)]:
		specs.append(["wide", Vector3(c.x * RS, 0, c.y * RS)])
	for c in [Vector2(1.2, 1.2), Vector2(2.8, 2.8)]:
		specs.append(["eroded", Vector3(c.x * RS, 0, c.y * RS)])
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in range(specs.size() - 1, 0, -1):
		var s := rng.randi_range(0, k)
		var t = specs[k]
		specs[k] = specs[s]
		specs[s] = t
	# The eroded Mounds are domain readers: put them last, above everything they overlap, so their edges
	# point the way the closure reads.
	specs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] != "eroded" and b[0] == "eroded")
	_brushes.clear()
	for k in specs.size():
		var kind: String = specs[k][0]
		var half := RS * (0.16 if kind == "small" else (0.4 if kind == "wide" else 0.3))
		var m = _mound("%s_%d" % [kind, k], specs[k][1], half)
		if kind == "eroded":
			var e := Pasture3DNodeErosion.new()
			e.label = "Erosion"
			e.iterations = 4
			e.erosion_rate = 0.05
			var mods: Array[Pasture3DNode] = [e]
			m.modifiers = mods
		_brushes.append(m)
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
		b.slope_angle = b.slope_angle + 6.0 # real work, and a changed ground under every reader
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
	mound.add_new_layer()
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
