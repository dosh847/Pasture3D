# Gate RB — phase 4 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: bake scope and the neighbour rule.
#
# The claim under test is that WHICH regions a bake is started from does not change what it writes: a
# brush is baked atomically over its whole footprint, loading the neighbours it reaches, and the loaded
# set is handed back exactly as it was found. So every scope is compared against every other, and each
# comparison carries a control showing it could have failed: a clipped bake (neighbours not loaded) that
# must differ, an early release the release rule must catch, a closure that must shrink when the domain
# reader stops reading its domain.
#
# Fixture (region_size 256, vertex_spacing 1: world == pixel), all blank ground:
#   S  small mound wholly in R1 (x 310..360), created FIRST so its layer is lowest; overlaps A's footprint.
#   A  mound straddling R0 | R1 with craggy relief and LIVE erosion: the domain reader.
#   B  plain mound straddling R1 | R2.
#   R3 (0,1) is touched by nothing: the region outside every working set.
#
# WHAT THIS DOES NOT COVER: the editor's auto-refresh (`_can_auto_refresh` is editor-only, see
# headless-gates-cannot-see-scheduling); RB6 asserts the rule it calls instead.
#
# Data lives in a per-gate user:// directory, wiped at start. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionBakeScopeGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_bake_scope_gate"
const R0 := Vector2i(0, 0)
const R1 := Vector2i(1, 0)
const R2 := Vector2i(2, 0)
const R3 := Vector2i(0, 1)
const ALL := [R0, R1, R2, R3]
const HALF := 60.0

var _fail := 0
const GATES := 10
var _completed := 0
var _root: Node3D
var _terrain
var _s
var _a
var _b
var _a_erosion
## Directory contents after the pre-bake: every run restores these files first.
var _snapshot := {}


func _ready() -> void:
	print("\n=== Region bake scope (gate RB, streaming phase 4) ===\n")
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
	d.save_directory(DIR)

	_s = _make_mound("S", Vector3(335, 0, 128), 25.0, 20.0)
	_a = _make_mound("A", Vector3(256, 0, 128), HALF, 55.0)
	_a_erosion = _erosion(20, 0.09)
	var mods: Array[Pasture3DNode] = [_craggy(1.0), _a_erosion]
	_a.modifiers = mods
	_b = _make_mound("B", Vector3(512, 0, 128), HALF, 40.0)

	# Pre-bake with everything loaded, so every owner's layer exists, then snapshot the directory. The
	# brushes are then EDITED so each scoped bake has real work to do: a run that bakes nothing would
	# return the snapshot unchanged, and every scope would agree with every other for nothing.
	var pre := ScopedBake.new(_terrain)
	var pr: Dictionary = pre.bake(ScopedBake.Scope.ALL_LOADED)
	_check("pre-bake baked all three owners", (pr["owners"] as Array).size() == 3)
	d.save_directory(DIR)
	_snapshot = _read_dir()
	# slope_angle, not height: the default Mound is an uncapped cone whose peak comes from the geometry
	# (60 m x tan 30 deg = 34.64 m) and never reads `height`, so a height edit bakes the same bytes.
	_a.slope_angle = 38.0
	_b.slope_angle = 24.0
	_s.slope_angle = 33.0

	await _rb1_scopes_agree()
	_rb2_release_after_last_sharer()
	_rb3_outside_working_set_untouched()
	_rb4_loaded_set_restored()
	_rb5_closure()
	_rb6_live_rule()
	_rb7_locked_and_budget()
	_rb9_registry_scope()
	_rb10_graph_source_closure()
	_rb8_roads_settle()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION BAKE SCOPE PASS" if ok else "REGION BAKE SCOPE FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RB1: one brush over two regions bakes byte-identically under all three scopes ----------------------
var _runs := {}

func _rb1_scopes_agree() -> void:
	print("[RB1] the three scopes write identical bytes:")
	_runs["selected"] = _run(ScopedBake.Scope.SELECTED, [R1], [R3])
	_runs["all_loaded"] = _run(ScopedBake.Scope.ALL_LOADED, [], [R1, R3])
	_runs["all_regions"] = _run(ScopedBake.Scope.ALL_REGIONS, [], [R3])
	var ref: Dictionary = _runs["selected"]["bytes"]
	_check("selected baked every owner (S, A, B)", (_runs["selected"]["report"]["owners"] as Array).size() == 3)
	_check("all_loaded == selected", _runs["all_loaded"]["bytes"] == ref)
	_check("all_regions == selected", _runs["all_regions"]["bytes"] == ref)
	var snap := _snapshot_bytes()
	_check("the bake changed the working set (not the snapshot back)", ref != snap)
	# Control: the clipped bake §F forbids. Only R1 is loaded, so A's erosion solves over half its domain
	# and B's R2 half is never written. Compare R1 alone too: that is the region both runs DID write, so a
	# difference there is the clip and not just the unwritten neighbour.
	var clipped := _run(ScopedBake.Scope.SELECTED, [R1], [R3], {"debug_no_neighbours": true})
	_check("control: a clipped bake differs", clipped["bytes"] != ref)
	var d1 := _diff_count(clipped["bytes"].get(R1, []), ref.get(R1, []))
	print("    clipped vs full, R1 only: %d differing byte arrays" % d1)
	_check("control: the clipped bake differs INSIDE the region it wrote", d1 > 0)
	_completed += 1


# --- RB2: a region is not released while a brush it shares is pending -----------------------------------
func _rb2_release_after_last_sharer() -> void:
	print("[RB2] release waits for the last sharing owner:")
	var rep: Dictionary = _runs["selected"]["report"]
	var bad := _early_releases(rep)
	print("    events: %s" % [_fmt_events(rep["events"])])
	_check("R1 released (the bake loaded it)", (rep["released"] as Array).has(R1))
	_check("no region released before every owner sharing it baked", bad.is_empty())
	# Control: release on the first owner's completion. A and B (and S) share R1.
	var early := _run(ScopedBake.Scope.SELECTED, [R1], [R3], {"debug_release_early": true})
	var bad_e := _early_releases(early["report"])
	print("    control events: %s" % [_fmt_events(early["report"]["events"])])
	_check("control: an early release is caught (%s)" % [bad_e], not bad_e.is_empty())
	_completed += 1


# --- RB3: regions outside the working set stay byte-identical on disk -----------------------------------
func _rb3_outside_working_set_untouched() -> void:
	print("[RB3] files outside the working set are untouched:")
	for key in ["selected", "all_loaded", "all_regions"]:
		var changed: Array = _runs[key]["changed_files"]
		var working: Array = _runs[key]["report"]["regions_written"]
		var outside: Array = []
		var inside := 0
		for f: String in changed:
			var loc = _file_location(f)
			if loc == null:
				continue # the index and the stack file are not region data
			if working.has(loc):
				inside += 1
			else:
				outside.append(f)
		_check("%s: no changed file outside the working set %s" % [key, outside], outside.is_empty())
		# Control: the comparison sees a working-set file change, so "nothing outside changed" is not a
		# compare that cannot see changes.
		_check("control %s: working-set files did change (%d)" % [key, inside], inside > 0)
		_check("%s: R3 not in the working set" % key, not working.has(R3))
	_completed += 1


# --- RB4: the loaded set after the bake equals the loaded set before it ---------------------------------
func _rb4_loaded_set_restored() -> void:
	print("[RB4] the loaded set is handed back:")
	for key in ["selected", "all_loaded", "all_regions"]:
		var r: Dictionary = _runs[key]
		_check("%s: after %s == before %s" % [key, r["loaded_after"], r["loaded_before"]],
				_sorted(r["loaded_after"]) == _sorted(r["loaded_before"]))
		# Control: the bake did change the loaded set on its way through, so equality is a restore.
		_check("control %s: the bake loaded %s" % [key, r["report"]["loaded_for_bake"]],
				not (r["report"]["loaded_for_bake"] as Array).is_empty())
	_completed += 1


# --- RB5: input closure --------------------------------------------------------------------------------
func _rb5_closure() -> void:
	print("[RB5] a domain reader pulls in the lower owners feeding its domain:")
	_load_only(ALL)
	var sb := ScopedBake.new(_terrain)
	var p: Dictionary = sb.plan(ScopedBake.Scope.SELECTED, [R0])
	var via := _via(p)
	print("    plan for [R0]: %s" % [via])
	_check("A is a target owner", via.get(_a._layer_owner, "") == "target")
	_check("S (R1 only, under A) comes in by closure", via.get(_s._layer_owner, "") == "closure")
	_check("B (does not overlap A) stays out", not via.has(_b._layer_owner))
	# Control: with A's erosion off (craggy fractal does not grow), A reads pointwise and S drops out.
	_a_erosion.enabled = false
	var via_c := _via(sb.plan(ScopedBake.Scope.SELECTED, [R0]))
	_a_erosion.enabled = true
	print("    control plan: %s" % [via_c])
	_check("control: without the domain reader S is not pulled in", not via_c.has(_s._layer_owner))
	_completed += 1


# --- RB6: live editing is blocked on a brush reaching an unloaded region --------------------------------
func _rb6_live_rule() -> void:
	print("[RB6] a brush reaching an unloaded region does not run live:")
	_load_only([R1, R3])
	_check("A (R0 unloaded) reaches an unloaded region", _a.reaches_unloaded_region())
	_check("S (R1 only) does not", not _s.reaches_unloaded_region())
	_load_only(ALL)
	_check("control: A with everything loaded does not", not _a.reaches_unloaded_region())
	_completed += 1


# --- RB7: locked regions and the budget skip whole owners -----------------------------------------------
func _rb7_locked_and_budget() -> void:
	print("[RB7] locked and over-budget owners are skipped whole:")
	var d = _terrain.data
	var sb := ScopedBake.new(_terrain)
	# Unloaded lock: lock R2, unload it (the index records the lock), plan from the index.
	_load_only(ALL)
	d.set_region_locked(R2, true)
	d.unload_region(R2)
	var p: Dictionary = sb.plan(ScopedBake.Scope.ALL_REGIONS)
	_check("B skipped: R2 is locked while unloaded", (p["skipped_locked"] as Array).has(_b._layer_owner))
	_check("A and S still planned", _via(p).has(_a._layer_owner) and _via(p).has(_s._layer_owner))
	d.load_region(R2, DIR)
	_check("loaded lock is seen too", (sb.plan(ScopedBake.Scope.ALL_REGIONS)["skipped_locked"] as Array).has(_b._layer_owner))
	d.set_region_locked(R2, false)
	# Control: unlocked, nothing is skipped.
	_check("control: unlocked, nothing skipped", (sb.plan(ScopedBake.Scope.ALL_REGIONS)["skipped_locked"] as Array).is_empty())
	sb.budget_regions = 1
	var pb: Dictionary = sb.plan(ScopedBake.Scope.ALL_REGIONS)
	_check("budget 1: A and B (two regions each) skipped",
			(pb["skipped_budget"] as Array).has(_a._layer_owner) and (pb["skipped_budget"] as Array).has(_b._layer_owner))
	_check("budget 1: S (one region) planned", _via(pb).has(_s._layer_owner))
	sb.budget_regions = 64
	_check("control: budget 64 skips nothing", (sb.plan(ScopedBake.Scope.ALL_REGIONS)["skipped_budget"] as Array).is_empty())
	_completed += 1


# --- RB8: a road junction settles inside the bake, while the road's regions are held -------------------
#
# Its own terrain and directory: a hill (lowest layer) under a crossing of two roads, the EW road straddling
# R0 | R1. Only R0 is targeted and nothing starts loaded, so R1 is loaded by the bake and released by it.
const ROAD_DIR := "user://region_bake_scope_gate_roads"

func _rb8_roads_settle() -> void:
	print("[RB8] the junction fixed point runs inside the bake:")
	var fx := _road_fixture()
	var t = fx["terrain"]
	var net: Pasture3DRoadNetwork = fx["net"]
	var snap := _read_dir_at(ROAD_DIR)
	# Control FIRST, from a scene that has never resolved: without the settle the bake leaves the junction
	# for the deferred resolve, which runs after the regions are released.
	_road_reset(fx, snap)
	var sbc := ScopedBake.new(t)
	sbc.debug_no_road_settle = true
	var rc: Dictionary = sbc.bake(ScopedBake.Scope.SELECTED, [Vector2i(0, 0)])
	_road_load_all(t)
	var moved_c := _roads_moved(net)
	print("    control: turns %d, roads moved by a fresh resolve %s" % [rc["road_turns"], moved_c])
	_check("control: without the settle a fresh resolve moves pins", not moved_c.is_empty())

	_road_reset(fx, snap)
	var sb := ScopedBake.new(t)
	var r: Dictionary = sb.bake(ScopedBake.Scope.SELECTED, [Vector2i(0, 0)])
	var after: Array = t.data.get_region_locations().duplicate()
	print("    events: %s" % [_fmt_events(r["events"])])
	_check("the bake loaded R1 for the road and released it", (r["loaded_for_bake"] as Array).has(Vector2i(1, 0))
			and (r["released"] as Array).has(Vector2i(1, 0)))
	_check("loaded set restored (nothing)", after.is_empty())
	_check("the fixture had something to settle (>= 2 resolve turns: %d)" % r["road_turns"], int(r["road_turns"]) >= 2)
	_check("no road reported unsettled %s" % [r["roads_unsettled"]], (r["roads_unsettled"] as Array).is_empty())
	# R1 is released only after the last resolve: the hold outlives the owner's own bake.
	var last_resolve := -1
	var r1_release := -1
	for i in (r["events"] as Array).size():
		var e: Array = r["events"][i]
		if e[0] == "resolve":
			last_resolve = i
		elif e[0] == "release" and e[1] == Vector2i(1, 0):
			r1_release = i
	_check("R1 released after the last resolve", r1_release > last_resolve and last_resolve >= 0)
	_road_load_all(t)
	var moved := _roads_moved(net)
	_check("settled: a fresh resolve moves no pins %s" % [moved], moved.is_empty())
	t.queue_free()
	_completed += 1


# --- RB9: the brush registry's Bake All Brushes takes a scope ------------------------------------------
func _rb9_registry_scope() -> void:
	print("[RB9] Bake All Brushes over Selected [R0]:")
	var mgr := Pasture3DSimManager.new()
	mgr.name = "Sim"
	_root.add_child(mgr)
	mgr.terrain = _terrain
	var paths: Array[NodePath] = [mgr.get_path_to(_a)]
	mgr.eroding_brushes = paths
	mgr.bake_scope = 0
	var regions: Array[Vector2i] = [R0]
	mgr.bake_regions = regions
	var snap: Dictionary = _snapshot_bytes()
	_restore_snapshot()
	_load_only([R3])
	var rep: Dictionary = mgr.bake_all_brushes_now()
	var after: Array = _terrain.data.get_region_locations().duplicate()
	var baked: Array = []
	for e: Array in rep.get("events", []):
		if e[0] == "bake":
			baked.append(String(e[1]).get_slice(":", 1))
	print("    ok %s, baked %s, loaded %s, released %s" % [rep["ok"], baked, rep.get("loaded_for_bake"), rep.get("released")])
	_check("report ok with scope selected", bool(rep["ok"]) and rep.get("scope") == "selected")
	_check("A (registered) and S (closure) baked, B (unregistered) not",
			baked.has("A") and baked.has("S") and not baked.has("B"))
	_check("loaded set restored %s" % [after], after == [R3])
	_load_only([])
	_load_only(ALL)
	var got := {}
	for loc in ALL:
		got[loc] = _region_bytes(loc) + _layer_bytes(loc)
	var ref: Dictionary = _runs["selected"]["bytes"]
	_check("R0 matches the scoped bake's R0", got[R0] == ref[R0])
	# Control: B was not baked, so R2 still holds the snapshot, which the scoped bake did change.
	_check("control: R2 is the snapshot, not the scoped result", got[R2] == snap[R2] and snap[R2] != ref[R2])
	_root.remove_child(mgr)
	mgr.free()
	_completed += 1


# --- RB10: a graph source names an input by reference ---------------------------------------------------
func _rb10_graph_source_closure() -> void:
	print("[RB10] a graph's Shape Source pulls in the brush it names:")
	_load_only(ALL)
	# Both under the terrain node: `Pasture3DGraphSources` searches from the host's terrain ancestor, so a
	# brush beside the terrain (like A, B and S) is one the real resolver cannot name either.
	var g = _make_mound("G", Vector3(40, 0, 40), 15.0, 10.0)
	var h = _make_mound("H", Vector3(600, 0, 40), 15.0, 10.0)
	g.reparent(_terrain)
	h.reparent(_terrain)
	var src := Pasture3DGraphNodeShapeSource.new()
	src.shape_key = h.shape_key()
	var graph := Pasture3DTerrainGraph.new()
	graph.add_node(src)
	# An Output node, or the modifier is inactive (no output) and names nothing: correctly.
	graph.add_node(Pasture3DGraphNodeOutput.new())
	var gm := Pasture3DNodeGraph.new()
	gm.graph = graph
	var mods: Array[Pasture3DNode] = [gm]
	g.modifiers = mods
	var sb := ScopedBake.new(_terrain)
	sb.root_owners = [g._layer_owner]
	var via := _via(sb.plan(ScopedBake.Scope.SELECTED, [R0]))
	print("    plan: %s (H key %s)" % [via, h.shape_key()])
	_check("G is the target", via.get(g._layer_owner, "") == "target")
	_check("H (R2, no overlap with G) comes in because G's graph names it", via.get(h._layer_owner, "") == "closure")
	src.shape_key = ""
	var via_c := _via(sb.plan(ScopedBake.Scope.SELECTED, [R0]))
	_check("control: with the key cleared H stays out %s" % [via_c], not via_c.has(h._layer_owner))
	for n in [g, h]:
		_terrain.remove_child(n)
		n.free()
	_completed += 1


# ---- runs -----------------------------------------------------------------------------------------------

## Restore the snapshot, load `p_start`, bake, and measure. Returns {report, bytes (per region: region
## maps + every layer's tiles), changed_files, loaded_before, loaded_after}.
func _run(p_scope: int, p_targets: Array, p_start: Array, p_opts: Dictionary = {}) -> Dictionary:
	_restore_snapshot()
	_load_only(p_start)
	var before: Array = _terrain.data.get_region_locations().duplicate()
	var sb := ScopedBake.new(_terrain)
	for k in p_opts:
		sb.set(k, p_opts[k])
	var rep: Dictionary = sb.bake(p_scope, p_targets)
	var after: Array = _terrain.data.get_region_locations().duplicate()
	# Flush what stays loaded (a start region the bake wrote into) so the disk compare sees it.
	_load_only([])
	var changed: Array = []
	var now := _read_dir()
	for f in now:
		if not _snapshot.has(f) or _snapshot[f] != now[f]:
			changed.append(f)
	var bytes := {}
	_load_only(ALL)
	for loc in ALL:
		bytes[loc] = _region_bytes(loc) + _layer_bytes(loc)
	print("    %s%s: owners %d, loaded %s, released %s" % [rep["scope"], " " + str(p_opts) if not p_opts.is_empty() else "",
			(rep["owners"] as Array).size(), rep["loaded_for_bake"], rep["released"]])
	return {"report": rep, "bytes": bytes, "changed_files": changed, "loaded_before": before, "loaded_after": after}


## Every release must come after the bake of every owner the plan says shares that region.
func _early_releases(p_report: Dictionary) -> Array:
	var sb := ScopedBake.new(_terrain)
	var owners_of := {}
	_load_only(ALL)
	for od: Dictionary in sb.plan(ScopedBake.Scope.ALL_REGIONS)["owners"]:
		if not (p_report["owners"] as Array).has(od["owner"]):
			continue
		for r: Vector2i in od["regions"]:
			if not owners_of.has(r):
				owners_of[r] = []
			owners_of[r].append(od["owner"])
	var baked := {}
	var bad: Array = []
	for e: Array in p_report["events"]:
		if e[0] == "bake":
			baked[e[1]] = true
		elif e[0] == "release":
			for o in owners_of.get(e[1], []):
				if not baked.has(o):
					bad.append([e[1], o])
					break
	return bad


func _snapshot_bytes() -> Dictionary:
	_restore_snapshot()
	_load_only(ALL)
	var out := {}
	for loc in ALL:
		out[loc] = _region_bytes(loc) + _layer_bytes(loc)
	return out


func _restore_snapshot() -> void:
	# Unload WITHOUT keeping memory ahead of disk: a clean region unloads without a save, then the
	# snapshot's files go back underneath it.
	_load_only([])
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		if not _snapshot.has(f):
			da.remove(f)
	for f in _snapshot:
		var fa := FileAccess.open(DIR + "/" + f, FileAccess.WRITE)
		fa.store_buffer(_snapshot[f])
		fa.close()


func _load_only(p_locs: Array) -> void:
	var d = _terrain.data
	for loc: Vector2i in d.get_region_locations().duplicate():
		if not p_locs.has(loc):
			d.unload_region(loc, false)
	for loc: Vector2i in p_locs:
		if not d.is_region_loaded(loc):
			d.load_region(loc, DIR, false)
	d.update_maps()


# ---- road fixture ----

func _road_fixture() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ROAD_DIR)
	var da := DirAccess.open(ROAD_DIR)
	for f in da.get_files():
		da.remove(f)
	var t = ClassDB.instantiate("Pasture3D")
	_root.add_child(t)
	t.data_directory = ROAD_DIR
	for loc in [Vector2i(0, 0), Vector2i(1, 0)]:
		t.data.add_region_blank(loc, false)
	t.data.update_maps()
	var hill := Pasture3DMound.new()
	hill.name = "Hill"
	t.add_child(hill)
	hill.terrain = t
	hill.global_position = Vector3(256, 0, 128)
	hill.blend_mode = Pasture3DMound.BlendMode.ADD
	var hp := Path3D.new()
	var hc := Curve3D.new()
	for c in [Vector3(-50, 0, -50), Vector3(50, 0, -50), Vector3(50, 0, 50), Vector3(-50, 0, 50)]:
		hc.add_point(c)
	hc.closed = true
	hp.curve = hc
	hill.add_child(hp)
	var net := Pasture3DRoadNetwork.new()
	t.add_child(net)
	var rt := Pasture3DRoadType.new()
	rt.type_name = "cross"
	rt.lane_count = 2
	rt.lane_width = 3.5
	net.road_types = [rt]
	var roads: Array = []
	for spec in [[Vector3(150, 0, 128), Vector3(362, 0, 128), "EW"], [Vector3(230, 0, 20), Vector3(230, 0, 236), "NS"]]:
		var rb := Pasture3DRoadBrush.new()
		rb.name = String(spec[2])
		net.add_child(rb)
		rb.terrain = t
		rb.road_road_type = rt
		var path := Path3D.new()
		var curve := Curve3D.new()
		curve.add_point(spec[0])
		curve.add_point(spec[1])
		path.curve = curve
		rb.add_child(path)
		var rm := Pasture3DNodeRoad.new()
		rm.alignment_step = 2.0
		rb.modifiers = [rm]
		roads.append(rb)
	t.data.save_directory(ROAD_DIR)
	return {"terrain": t, "net": net, "roads": roads}


## Back to the saved directory, nothing loaded, and a network that has never resolved.
func _road_reset(p_fx: Dictionary, p_snap: Dictionary) -> void:
	var t = p_fx["terrain"]
	for loc: Vector2i in t.data.get_region_locations().duplicate():
		t.data.unload_region(loc, false)
	t.data.update_maps()
	var da := DirAccess.open(ROAD_DIR)
	for f in da.get_files():
		if not p_snap.has(f):
			da.remove(f)
	for f in p_snap:
		var fa := FileAccess.open(ROAD_DIR + "/" + f, FileAccess.WRITE)
		fa.store_buffer(p_snap[f])
		fa.close()
	var net: Pasture3DRoadNetwork = p_fx["net"]
	var empty: Array[Pasture3DRoadJunction] = []
	net.junctions = empty
	for rb in p_fx["roads"]:
		rb._last_junction_values = {}
		rb.last_junction_digest = ""
		for m in rb.modifiers:
			if m is Pasture3DNodeRoad:
				m.clear_cache()


func _road_load_all(p_t) -> void:
	for loc in [Vector2i(0, 0), Vector2i(1, 0)]:
		if not p_t.data.is_region_loaded(loc):
			p_t.data.load_region(loc, ROAD_DIR, false)
	p_t.data.update_maps()


## Resolve once with live refreshes suppressed and return the roads whose pins moved beyond tolerance
## against what they were last baked with. Written here rather than borrowed from the scoped bake, so the
## check does not share the code it checks.
func _roads_moved(p_net: Pasture3DRoadNetwork) -> Array:
	var base := {}
	for b in p_net.road_brushes():
		base[b] = [b._last_junction_values.duplicate(), b.last_junction_digest]
		b._suspend_auto = true
	p_net.resolve_junctions()
	var out: Array = []
	for b in base:
		b._suspend_auto = false
		var vals: Dictionary = b.junction_values()
		if (base[b][0] as Dictionary).is_empty() and not vals.is_empty() and b.junction_digest() == base[b][1]:
			continue
		if Pasture3DRoadBrush.junction_values_differ(vals, base[b][0]):
			out.append(String(b.name))
	return out


func _read_dir_at(p_dir: String) -> Dictionary:
	var out := {}
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		out[f] = FileAccess.get_file_as_bytes(p_dir + "/" + f)
	return out


# ---- fixture --------------------------------------------------------------------------------------------

func _craggy(p_strength: float) -> Pasture3DNodeRelief:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 22.0
	mat.seed = 5
	var m := Pasture3DNodeRelief.new()
	m.label = "Shape"
	m.material = mat
	m.strength = p_strength
	return m


## LIVE: the gate measures the solver's domain, not a frozen cache (see BrushErosionGate._erosion).
func _erosion(p_iterations: int, p_rate: float) -> Pasture3DNodeErosion:
	var m := Pasture3DNodeErosion.new()
	m.evaluation = Pasture3DNode.Evaluation.LIVE
	m.label = "Erosion"
	m.iterations = p_iterations
	m.erosion_rate = p_rate
	m.hillslope_diffusion = 0.02
	return m


func _make_mound(p_name: String, p_at: Vector3, p_half: float, p_height: float):
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.height = p_height
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
	# Its own layer: by default every Mound shares the one "Mounds" layer, and the gate needs three owners.
	mound.add_new_layer()
	return mound


# ---- helpers --------------------------------------------------------------------------------------------

func _via(p_plan: Dictionary) -> Dictionary:
	var out := {}
	for od: Dictionary in p_plan["owners"]:
		out[od["owner"]] = od["via"]
	return out


## A file name's region location, or null for a file that is not per-region (the index, the stack).
func _file_location(p_file: String):
	var re := RegEx.create_from_string("([_-])(\\d{2})([_-])(\\d{2})\\.res$")
	var m := re.search(p_file)
	if m == null:
		return null
	var x := int(m.get_string(2)) * (-1 if m.get_string(1) == "-" else 1)
	var z := int(m.get_string(4)) * (-1 if m.get_string(3) == "-" else 1)
	return Vector2i(x, z)


func _read_dir() -> Dictionary:
	var out := {}
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		out[f] = FileAccess.get_file_as_bytes(DIR + "/" + f)
	return out


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


func _diff_count(p_a: Array, p_b: Array) -> int:
	var n := absi(p_a.size() - p_b.size())
	for i in mini(p_a.size(), p_b.size()):
		if p_a[i] != p_b[i]:
			n += 1
	return n


func _sorted(p_a: Array) -> Array:
	var out := p_a.duplicate()
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out


func _fmt_events(p_events: Array) -> String:
	var parts: PackedStringArray = []
	for e: Array in p_events:
		parts.append("%s %s" % [e[0], String(e[1]).get_slice(":", 1) if e[1] is String else str(e[1])])
	return ", ".join(parts)


func _check(p_label: String, p_ok: bool) -> void:
	print("    %s %s" % ["ok " if p_ok else "FAIL", p_label])
	if not p_ok:
		_fail += 1
