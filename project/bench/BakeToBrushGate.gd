# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BakeToBrushGate — Bake to Brush re-solves one host of a shared graph modifier; Bake to All re-solves them all.
#
# A duplicated brush shares its modifier stack, so two Plows held one Graph modifier whose frozen cache had an
# entry per footprint. Bake to Brush dropped the whole cache and full-baked the layer, so every host
# re-solved. Entries now carry the host that solved them, Bake to Brush drops only its own and rect-bakes its
# own footprint, and Bake to All drops everything and bakes once per layer.
#
#   [A] hosts_of_graph finds both brushes sharing the modifier; Bake to All leads one per layer owner;
#       control: two hosts on different layers lead two
#   [B] drop_cache_for_host drops One's entry and keeps Two's; control: drop_cache_for_bake drops both
#   [C] One's own-footprint rect bake re-solves One and serves Two from its cache, and equals the full bake;
#       control: dropping every entry and full-baking re-solves Two as well
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BakeToBrushGate.tscn
extends Node

const CRITERIA := 3
const TOL := 1e-4
var RS := 64

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== BakeToBrushGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	RS = _terrain.region_size
	var mod := _graph_mod()
	var one := _mound("One", _square(18, 18, 8), mod)
	var two := _mound("Two", _square(34, 30, 8), mod)
	two._set_layer_owner(one._layer_owner)
	await _settle()
	one._refresh_owner(one._layer_owner, false, [])
	for f in [_a, _b, _c]:
		await f.call(mod, one, two)
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== BAKE TO BRUSH %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


## Input + Noise, FROZEN (the default), so each host's solve is filed in the modifier's cache.
func _graph_mod() -> Pasture3DNodeGraph:
	var fn := FastNoiseLite.new()
	fn.seed = 11
	fn.frequency = 0.06
	var gn := Pasture3DGraphNodeNoise.new()
	gn.noise = fn
	gn.amplitude = 4.0
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), gn, blend, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]), PackedInt32Array([2, 0, 3, 0])]
	var mg := Pasture3DNodeGraph.new()
	mg.graph = g
	mg.strength = 0.7
	return mg


func _mound(p_name: String, p_pts: Array, p_mod: Pasture3DNode) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.auto_refresh = false
	m.height = 4.0
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in p_pts:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = _terrain
	var mods: Array[Pasture3DNode] = [p_mod]
	m.modifiers = mods
	return m


func _square(cx: float, cz: float, h: float) -> Array:
	return [Vector3(cx - h, 0, cz - h), Vector3(cx + h, 0, cz - h), Vector3(cx + h, 0, cz + h), Vector3(cx - h, 0, cz + h)]


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(RS):
		for x in range(RS):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) != is_finite(p_b[i]):
			return INF
		if is_finite(p_a[i]):
			w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


## The cache entries filed by `p_host`.
func _entries(p_mod: Pasture3DNodeGraph, p_host: Node) -> Array:
	var out: Array = []
	for k in p_mod._cache:
		if int(p_mod._cache[k].get("host", 0)) == p_host.get_instance_id():
			out.append(p_mod._cache[k])
	return out


## Mark Two's entries, so a re-solve (which files a fresh dictionary) is told from a serve.
func _mark(p_mod: Pasture3DNodeGraph, p_host: Node) -> void:
	for e: Dictionary in _entries(p_mod, p_host):
		e["gate_mark"] = true


func _marked(p_mod: Pasture3DNodeGraph, p_host: Node) -> bool:
	var es := _entries(p_mod, p_host)
	return not es.is_empty() and es.all(func(e: Dictionary) -> bool: return e.has("gate_mark"))


func _a(mod: Pasture3DNodeGraph, one: Pasture3DMound, two: Pasture3DMound) -> void:
	_ran += 1
	var hosts := Pasture3DNodeGraph.hosts_of_graph(mod.graph, get_tree())
	var leads := Pasture3DNodeGraph.bake_all_leads(hosts)
	_check("A hosts and leads", hosts == [one, two] and leads == [one],
			"hosts %s (want [One, Two]); leads %s (want [One], one per layer)" % [hosts, leads])
	var other := two._layer_owner
	two._layer_owner = "pasture3d_brush:gate_other"
	var ctl := Pasture3DNodeGraph.bake_all_leads(hosts)
	two._layer_owner = other
	_check("A control", ctl.size() == 2, "hosts on two layers lead %d (want 2)" % ctl.size())


func _b(mod: Pasture3DNodeGraph, one: Pasture3DMound, two: Pasture3DMound) -> void:
	_ran += 1
	var n1 := _entries(mod, one).size()
	var n2 := _entries(mod, two).size()
	var dropped := mod.drop_cache_for_host(one)
	var left1 := _entries(mod, one).size()
	var left2 := _entries(mod, two).size()
	_check("B drops one host", n1 >= 1 and n2 >= 1 and dropped == n1 and left1 == 0 and left2 == n2,
			"before: One %d, Two %d entries; dropped %d; after: One %d (want 0), Two %d (want %d)" % [n1, n2, dropped, left1, left2, n2])
	# Restore both entries for the control, then drop everything.
	one._refresh_owner(one._layer_owner, false, [])
	mod.drop_cache_for_bake()
	_check("B control", _entries(mod, one).is_empty() and _entries(mod, two).is_empty(),
			"drop_cache_for_bake leaves One %d, Two %d entries (want 0, 0)" % [_entries(mod, one).size(), _entries(mod, two).size()])
	one._refresh_owner(one._layer_owner, false, [])


func _c(mod: Pasture3DNodeGraph, one: Pasture3DMound, two: Pasture3DMound) -> void:
	_ran += 1
	var full := _heights()
	_mark(mod, two)
	mod.drop_cache_for_host(one)
	var ids := {}
	for s in one._get_splines():
		ids[s.get_instance_id()] = true
	one._refresh_owner_rect(one._layer_owner, ids, false, [], true)
	var w := _worst(_heights(), full)
	var one_back := not _entries(mod, one).is_empty()
	var two_served := _marked(mod, two)
	_check("C own footprint only", one._last_rect_decision == "rect" and one_back and two_served and w <= TOL,
			"decision %s; One re-solved %s; Two served from cache %s; worst |rect - full| %.6f m (want <= %.4f)" % [
				one._last_rect_decision, one_back, two_served, w, TOL])
	mod.drop_cache_for_bake()
	one._refresh_owner(one._layer_owner, false, [])
	var two_resolved := not _entries(mod, two).is_empty() and not _marked(mod, two)
	_check("C control", two_resolved, "dropping every entry and full-baking re-solves Two: %s (want true)" % two_resolved)
