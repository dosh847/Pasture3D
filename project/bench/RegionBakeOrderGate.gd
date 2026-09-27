# Gate O — phase 4 of PASTURE3D_BAKE_MEMORY_SPEC.md (M4): owners bake in a dependency order, not layer order.
#
# A region touched by owners in several layers used to stay loaded from the first of them to the last. Now
# `plan()` builds the DAG of real constraints (a lower owner before a higher one whose footprint box it
# overlaps) and schedules greedily. Under test:
#   [O1] the order respects every edge a brute-force overlap scan over the brushes' own footprints finds
#        (the gate's own scan, all pairs, not the plan's bucketing). Control: ordering by first region alone
#        breaks at least one of those edges, so the edges are real.
#   [O2] every region's heights after the scheduled bake equal those after the layer-major bake, byte for
#        byte. Control: the reverse order (every edge broken) differs, so the compare can fail.
#   [O3] the scheduled bake's peak loaded regions is below the layer-major one. Both are reported.
#
# Fixture (region_size 128, 4 x 4 regions, all unloaded at the bake): a small Mound straddling each
# interior region boundary, WIDE Mounds on region corners overlapping them, and Mounds with a Frozen erosion
# modifier (domain readers) over the wide ones. Every Mound is on its own layer, the layers created in a
# seeded shuffled order. The brushes are edited after the pre-bake, so an erosion solve that runs before
# the layer below it re-bakes reads the old ground: that is what makes a broken edge visible.
#
# Data lives in user://region_bake_order_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionBakeOrderGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_bake_order_gate"
const RS := 128.0
const N := 4

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _brushes: Array = []
var _loaded_now := 0
var _peak := 0


func _ready() -> void:
	print("\n=== Region bake order (gate O, bake memory phase 4) ===\n")
	var dag: Dictionary = await _run("dag")
	var major: Dictionary = await _run("major")
	var rev: Dictionary = await _run("reverse")
	_o1(dag)
	_o2(dag, major, rev)
	_o3(dag, major)
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION BAKE ORDER PASS" if ok else "REGION BAKE ORDER FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- O1 ---------------------------------------------------------------------------------------------------
func _o1(p_dag: Dictionary) -> void:
	print("[O1] the order respects every dependency edge:")
	var owners: Array = p_dag["plan"]
	var edges: Array = p_dag["edges"]
	var pos := {}
	for i in owners.size():
		pos[owners[i]["owner"]] = i
	var broken := 0
	for e: Array in edges:
		if int(pos[e[0]]) > int(pos[e[1]]):
			broken += 1
	print("    %d owners, %d edges by brute force (the plan counted %d), %d broken" % [owners.size(),
		edges.size(), int(p_dag["plan_edges"]), broken])
	_check("fixture: the brushes have dependency edges", edges.size() >= 4)
	_check("the plan's DAG has exactly the brute-force edges", int(p_dag["plan_edges"]) == edges.size())
	_check("no edge is broken", broken == 0)
	# Control: order by first region alone.
	var by_region: Array = owners.duplicate()
	by_region.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: Vector2i = a["regions"][0]
		var rb: Vector2i = b["regions"][0]
		return ra.y < rb.y or (ra.y == rb.y and ra.x < rb.x))
	var rpos := {}
	for i in by_region.size():
		rpos[by_region[i]["owner"]] = i
	var rbroken := 0
	for e: Array in edges:
		if int(rpos[e[0]]) > int(rpos[e[1]]):
			rbroken += 1
	_check("control: ordering by first region alone breaks %d edge(s)" % rbroken, rbroken > 0)
	_completed += 1


# --- O2 ---------------------------------------------------------------------------------------------------
func _o2(p_dag: Dictionary, p_major: Dictionary, p_rev: Dictionary) -> void:
	print("[O2] the scheduled order bakes the same bytes as layer order:")
	var diff := _differing(p_dag["heights"], p_major["heights"])
	var rdiff := _differing(p_rev["heights"], p_major["heights"])
	var moved := _differing(p_major["heights"], p_major["pre"])
	print("    regions differing: scheduled %s, reverse %s; changed by the bake %d of %d" % [diff, rdiff,
		moved.size(), N * N])
	_check("witness: the bake changed regions (so the compare can fail)", moved.size() > 0)
	_check("scheduled == layer-major on every region, byte for byte", diff.is_empty() and
		(p_dag["heights"] as Dictionary).size() == N * N)
	_check("control: the reverse order differs", not rdiff.is_empty())
	_check("witness: the orders really differ (scheduled is not layer-major)",
		p_dag["order"] != p_major["order"])
	_completed += 1


# --- O3 ---------------------------------------------------------------------------------------------------
func _o3(p_dag: Dictionary, p_major: Dictionary) -> void:
	print("[O3] the scheduled order holds fewer regions at once:")
	print("    peak loaded: scheduled %d, layer-major %d, of %d" % [p_dag["peak"], p_major["peak"], N * N])
	_check("both bakes loaded regions", int(p_dag["peak"]) > 0 and int(p_major["peak"]) > 0)
	_check("scheduled peak is below layer-major", int(p_dag["peak"]) < int(p_major["peak"]))
	_completed += 1


# ---- one bake --------------------------------------------------------------------------------------------

## Build the fixture, bake it in `p_mode`, and return {plan, plan_edges, edges, order, peak, heights, pre}.
func _run(p_mode: String) -> Dictionary:
	await _build()
	var d = _terrain.data
	var sb := ScopedBake.new(_terrain)
	sb.budget_regions = 0
	sb.debug_layer_major = p_mode == "major"
	sb.debug_reverse_order = p_mode == "reverse"
	var plan: Dictionary = sb.plan(ScopedBake.Scope.ALL_REGIONS)
	var edges := _brute_edges(plan["owners"])
	_loaded_now = 0
	_peak = 0
	d.region_loaded.connect(_on_loaded)
	d.region_unloaded.connect(_on_unloaded)
	var rep: Dictionary = sb.bake(ScopedBake.Scope.ALL_REGIONS)
	d.region_loaded.disconnect(_on_loaded)
	d.region_unloaded.disconnect(_on_unloaded)
	var order: Array = []
	for e: Array in rep["events"]:
		if e[0] == "bake":
			order.append(e[1])
	var pre := _pre.duplicate()
	var heights := {}
	for j in N:
		for i in N:
			var loc := Vector2i(i, j)
			d.load_region(loc, DIR, false)
			heights[loc] = d.get_region(loc).get_height_map().get_data()
	print("  %s: %d owners, %d baked, peak %d" % [p_mode, (plan["owners"] as Array).size(), order.size(), _peak])
	var out := {"plan": plan["owners"], "plan_edges": plan.get("edges", 0), "edges": edges, "order": order,
		"peak": _peak, "heights": heights, "pre": pre}
	await _teardown()
	return out


## Every pair of planned owners whose brushes' own footprints overlap, lower layer first. All pairs.
func _brute_edges(p_owners: Array) -> Array:
	var boxes := {}
	for od: Dictionary in p_owners:
		var bs: Array = []
		for b in od["brushes"]:
			bs.append_array(b._own_footprints())
		boxes[od["owner"]] = bs
	var out: Array = []
	for a: Dictionary in p_owners:
		for b: Dictionary in p_owners:
			if int(a["order"]) >= int(b["order"]):
				continue
			var hit := false
			for x: AABB in boxes[a["owner"]]:
				for y: AABB in boxes[b["owner"]]:
					var ix := minf(x.end.x, y.end.x) - maxf(x.position.x, y.position.x)
					var iz := minf(x.end.z, y.end.z) - maxf(x.position.z, y.position.z)
					if ix > 0.0 and iz > 0.0:
						hit = true
			if hit:
				out.append([a["owner"], b["owner"]])
	return out


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
