# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphParamGate — graph parameters (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §10, P6).
#
# A graph declares parameters, a Parameter node outputs one, and the HOST (Pasture3DNodeGraph) supplies the
# value. One graph therefore compiles to different programs for different hosts, and every key derived from
# the graph alone has to hash the values too. Each key is checked on its own:
#
#   [A] Two hosts sharing one graph with different values bake different terrain, each matching the same graph
#       with that value typed into a Const; an unset value reads the declared default; re-baking the first
#       host after the second still gives the first host's terrain (the stamp does not leak).
#       Control: two hosts with EQUAL values bake identically and key identically.
#   [B] Changing a value re-bakes its host (its `changed`, its modifier signature, its frozen cache) and the
#       native and GDScript rasterisers agree on the result.
#       Control: changing a value on a DIFFERENT host moves none of this host's keys and emits nothing on
#       this host or on the graph.
#   [C] A FROZEN solver downstream of a Parameter re-solves when that value changes, on the native route and
#       on the GDScript route.
#       Control: it serves its solve, not stale, when a value that does not feed it changes.
#   [D] The host's property list tracks a parameter added and one removed; the properties read the default,
#       read back what was set, and carry the declared type.
#   [E] A value for an id the graph does not declare is ignored (keys and program unchanged) and warned.
#       Control: a host without it has no such warning.
#   [F] The per-node inputs hash and the cell program carry the value (the two keys the bake does not reach
#       through the host).
#
# Every check goes through `_check`, which counts. The run fails unless EXPECTED_RAN checks reached their
# assert, so a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphParamGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE_1 := Vector3(200.0, 0.0, 160.0)
const SITE_2 := Vector3(330.0, 0.0, 160.0)
const HALF := 40.0
const PROBE_STRIDE := 3
const TOL := 1.0e-4
const EXPECTED_RAN := 46

var _fail := 0
var _ran := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== GraphParamGate: graph parameters supplied by the host (ports spec §10) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	_criterion_a()
	_criterion_b()
	_criterion_c()
	_criterion_d()
	_criterion_e()
	_criterion_f()
	print("\n    checks reached: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1
		print("    !! the number of checks that ran is not the expected count; a criterion stopped early or changed")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH PARAM PASS" if _fail == 0 else "GRAPH PARAM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	print("    %s %s" % ["ok" if p_ok else "!!", p_what])
	if not p_ok:
		_fail += 1


# ---- [A] ------------------------------------------------------------------------------------------------

func _criterion_a() -> void:
	print("[A] two hosts, one graph, different values")
	var m1 = _make_mound("ParamA1", SITE_1)
	var m2 = _make_mound("ParamA2", SITE_2)
	if m1 == null or m2 == null:
		return
	var p1 := _probes(SITE_1)
	var p2 := _probes(SITE_2)
	var g := _lift_graph(2.0)
	var h1 := _host(g); h1.set_param(&"lift", 3.0)
	var h2 := _host(g); h2.set_param(&"lift", 8.0)
	m1.modifiers = [h1] as Array[Pasture3DNode]
	m2.modifiers = [h2] as Array[Pasture3DNode]
	var s1 := _bake(m1, p1)
	var s2 := _bake(m2, p2)
	var s1_again := _bake(m1, p1)
	# The same graph with the value TYPED IN, on the same mound.
	m1.modifiers = [_host(_lift_twin(3.0))] as Array[Pasture3DNode]
	var t1 := _bake(m1, p1)
	m2.modifiers = [_host(_lift_twin(8.0))] as Array[Pasture3DNode]
	var t2 := _bake(m2, p2)
	m1.modifiers = [_host(_lift_twin(8.0))] as Array[Pasture3DNode]
	var t1_8 := _bake(m1, p1)
	_check(_all_finite(s1) and _all_finite(s2), "the probes read terrain")
	_check(_max_abs_diff(s1, t1) < TOL, "host 1 (lift 3) matches the graph with Const 3: %.6f m" % _max_abs_diff(s1, t1))
	_check(_max_abs_diff(s2, t2) < TOL, "host 2 (lift 8) matches the graph with Const 8: %.6f m" % _max_abs_diff(s2, t2))
	_check(_max_abs_diff(t1, t1_8) > 1.0, "lift 3 and lift 8 bake different terrain on one site: %.3f m apart" % _max_abs_diff(t1, t1_8))
	_check(_max_abs_diff(s1, s1_again) < TOL, "re-baking host 1 after host 2 still gives lift 3: %.6f m" % _max_abs_diff(s1, s1_again))
	_check(h1.graph_key() != h2.graph_key(), "the two hosts key differently")
	# Unset reads the declared default (2).
	var h0 := _host(g)
	m1.modifiers = [h0] as Array[Pasture3DNode]
	var s0 := _bake(m1, p1)
	m1.modifiers = [_host(_lift_twin(2.0))] as Array[Pasture3DNode]
	var t0 := _bake(m1, p1)
	_check(_max_abs_diff(s0, t0) < TOL, "an unset value reads the declared default: %.6f m" % _max_abs_diff(s0, t0))
	# CONTROL: equal values, two host objects.
	var ha := _host(g); ha.set_param(&"lift", 5.0)
	var hb := _host(g); hb.set_param(&"lift", 5.0)
	m1.modifiers = [ha] as Array[Pasture3DNode]
	var sa := _bake(m1, p1)
	m1.modifiers = [hb] as Array[Pasture3DNode]
	var sb := _bake(m1, p1)
	_check(_max_abs_diff(sa, sb) == 0.0, "control: equal values on two hosts bake identically: %.6f m" % _max_abs_diff(sa, sb))
	_check(ha.graph_key() == hb.graph_key() and ha.content_key() == hb.content_key(), "control: equal values key identically")
	m1.queue_free(); m2.queue_free()


# ---- [B] ------------------------------------------------------------------------------------------------

func _criterion_b() -> void:
	print("[B] a value change re-bakes its host, and only its host")
	var m1 = _make_mound("ParamB1", SITE_1)
	var m2 = _make_mound("ParamB2", SITE_2)
	if m1 == null or m2 == null:
		return
	var p1 := _probes(SITE_1)
	var g := _lift_graph(0.0)
	var h1 := _host(g); h1.set_param(&"lift", 4.0)
	var h2 := _host(g); h2.set_param(&"lift", 4.0)
	h1.evaluation = Pasture3DNode.Evaluation.FROZEN # the frozen cache is one of the keys under test
	m1.modifiers = [h1] as Array[Pasture3DNode]
	m2.modifiers = [h2] as Array[Pasture3DNode]
	_check(not m1._stack_forces_gdscript(), "the parameter graph runs on the native rasteriser")
	var before := _bake(m1, p1)
	var counts := {"h1": 0, "h2": 0, "g": 0}
	h1.changed.connect(func(): counts["h1"] += 1)
	h2.changed.connect(func(): counts["h2"] += 1)
	g.changed.connect(func(): counts["g"] += 1)
	var sig_before: Array = m1._modifier_signature()
	var key_before := h1.graph_key()

	# CONTROL first: another host's value.
	h2.set_param(&"lift", 9.0)
	_check(counts["h1"] == 0 and counts["g"] == 0, "control: host 2's edit emits nothing on host 1 (%d) or the graph (%d)" % [counts["h1"], counts["g"]])
	_check(m1._modifier_signature() == sig_before and h1.graph_key() == key_before, "control: host 1's signature and key are unchanged")
	_check(_max_abs_diff(before, _bake(m1, p1)) < TOL, "control: host 1 re-bakes to the same terrain")

	# The edit.
	h1.set_param(&"lift", 7.0)
	_check(counts["h1"] >= 1, "host 1's edit emits its changed (%d)" % counts["h1"])
	_check(counts["g"] == 0, "host 1's edit emits nothing on the shared graph (%d)" % counts["g"])
	_check(m1._modifier_signature() != sig_before, "host 1's modifier signature moved")
	_check(h1.graph_key() != key_before, "host 1's graph key moved")
	m1.force_gdscript_raster = false
	var native := _bake(m1, p1)
	m1.force_gdscript_raster = true
	var oracle := _bake(m1, p1)
	m1.force_gdscript_raster = false
	# The bare dome's own float-vs-double gap, measured and subtracted as GraphNativeBakeGate does.
	m1.modifiers = [] as Array[Pasture3DNode]
	var dome_n := _bake(m1, p1)
	m1.force_gdscript_raster = true
	var dome_o := _bake(m1, p1)
	m1.force_gdscript_raster = false
	var added := _max_abs_diff(native, oracle) - _max_abs_diff(dome_n, dome_o)
	_check(_max_abs_diff(native, before) > 2.0, "the FROZEN host re-baked with the new value: moved %.3f m" % _max_abs_diff(native, before))
	_check(added < TOL, "native and GDScript agree after the edit: the graph adds %.6f m" % added)
	m1.queue_free(); m2.queue_free()


# ---- [C] ------------------------------------------------------------------------------------------------

func _criterion_c() -> void:
	print("[C] a frozen solver downstream of a Parameter re-solves on its value")
	for route in ["native", "gdscript"]:
		var built := _solver_graph()
		var g: Pasture3DTerrainGraph = built["graph"]
		var solver: Pasture3DGraphNodeErosionThermal = built["solver"]
		g.force_gdscript_evaluation = route == "gdscript"
		var h := _host(g)
		h.set_param(&"talus", 20.0)
		h.set_param(&"offset", 0.0)
		var gw := 48
		var rect := Rect2(-24.0, -24.0, 48.0, 48.0)
		var surf := _bumpy(gw)
		h.stamp_params()
		g.evaluate(gw, gw, rect, null, surf)
		var key0 := solver._cache_key
		var dict0: Dictionary = solver._cache
		_check(not dict0.is_empty(), "%s: the frozen solver holds a solve" % route)
		# CONTROL: a value that does not feed the solver.
		h.set_param(&"offset", 1.5)
		h.stamp_params()
		var out_b := g.evaluate(gw, gw, rect, null, surf)
		_check(is_same(solver._cache, dict0) and solver._cache_key == key0 and not solver.is_stale(),
				"%s control: an unrelated value leaves the solve served, not stale" % route)
		_check(out_b.size() == gw * gw and absf(out_b[gw * 10 + 10] - (solver._cache[key0][0][gw * 10 + 10] + 1.5)) < TOL,
				"%s control: the unrelated value still reached the output" % route)
		# The value that feeds it.
		h.set_param(&"talus", 45.0)
		h.stamp_params()
		g.evaluate(gw, gw, rect, null, surf)
		_check(not is_same(solver._cache, dict0) and solver._cache_key != key0 and not solver.is_stale(),
				"%s: the feeding value re-solved the frozen solver (new key, not stale)" % route)


# ---- [D] ------------------------------------------------------------------------------------------------

func _criterion_d() -> void:
	print("[D] the host's property list tracks the declarations")
	var g := _lift_graph(2.0)
	var h := _host(g)
	var notified := [0]
	h.property_list_changed.connect(func(): notified[0] += 1)
	_check(_param_props(h) == ["parameters/lift"], "one declared parameter, one property: %s" % str(_param_props(h)))
	_check(is_equal_approx(float(h.get("parameters/lift")), 2.0), "the property reads the declared default")
	h.set("parameters/lift", 6.5)
	_check(is_equal_approx(float(h.get("parameters/lift")), 6.5) and h.param_overrides.has(&"lift"), "setting the property stores the value")
	var count := Pasture3DGraphParam.new()
	count.id = &"count"; count.type = Pasture3DGraphParam.Type.INT; count.default_value = 3.0
	count.range_min = 0.0; count.range_max = 10.0
	var list := g.parameters.duplicate()
	list.append(count)
	g.parameters = list
	_check(notified[0] >= 1, "adding a declaration notified the host's property list (%d)" % notified[0])
	_check(_param_props(h) == ["parameters/lift", "parameters/count"], "added: %s" % str(_param_props(h)))
	h.set("parameters/count", 4.6)
	_check(typeof(h.get("parameters/count")) == TYPE_INT and int(h.get("parameters/count")) == 5, "an INT parameter reads back as a rounded int")
	var info := {}
	for p in h.get_property_list():
		if p["name"] == "parameters/count":
			info = p
	_check(int(info.get("type", -1)) == TYPE_INT and int(info.get("hint", -1)) == PROPERTY_HINT_RANGE, "the INT property carries its type and range hint")
	var n0: int = notified[0]
	var only_count: Array[Pasture3DGraphParam] = [count]
	g.parameters = only_count
	_check(notified[0] > n0 and _param_props(h) == ["parameters/count"], "removed: %s" % str(_param_props(h)))
	_check(h.get("parameters/lift") == null, "the removed parameter is no longer a property")


# ---- [E] ------------------------------------------------------------------------------------------------

func _criterion_e() -> void:
	print("[E] a value for an undeclared id is ignored and warned")
	var g := _lift_graph(2.0)
	var clean := _host(g); clean.set_param(&"lift", 3.0)
	var ghost := _host(g); ghost.set_param(&"lift", 3.0); ghost.set_param(&"ghost", 99.0)
	_check(ghost.graph_key() == clean.graph_key(), "the undeclared value moves no key")
	ghost.stamp_params()
	var pg := g.compile_graph_program()
	clean.stamp_params()
	var pc := g.compile_graph_program()
	_check(str(pg) == str(pc), "the undeclared value moves no compiled program")
	_check(_has_line(ghost.modifier_warnings(null), "'ghost'"), "the host warns about 'ghost'")
	_check(not _has_line(clean.modifier_warnings(null), "does not declare"), "control: a host without it does not warn")
	# A declaration REMOVED under a stored value: the value stays stored and is now reported.
	var h := _host(g); h.set_param(&"lift", 4.0)
	g.parameters = [] as Array[Pasture3DGraphParam]
	_check(_has_line(h.modifier_warnings(null), "'lift'"), "a value whose declaration was removed is warned")


# ---- [F] ------------------------------------------------------------------------------------------------

func _criterion_f() -> void:
	print("[F] the per-node inputs hash and the cell program carry the value")
	var g := _lift_graph(2.0)
	var h := _host(g)
	var plan: Dictionary = g._fold_plan(g.output_index())
	var pi := 1 # the Parameter node in `_lift_graph`
	h.set_param(&"lift", 1.0); h.stamp_params()
	var k1 := g._compute_node_inputs_hash(pi, 8, 8, Rect2(0, 0, 8, 8), null, null, plan["inputs_of"], plan["input_ports_of"])
	h.set_param(&"lift", 2.0); h.stamp_params()
	var k2 := g._compute_node_inputs_hash(pi, 8, 8, Rect2(0, 0, 8, 8), null, null, plan["inputs_of"], plan["input_ports_of"])
	_check(k1 != k2, "the Parameter node's inputs hash moves with the value")
	h.set_param(&"lift", 1.0); h.stamp_params()
	var k3 := g._compute_node_inputs_hash(pi, 8, 8, Rect2(0, 0, 8, 8), null, null, plan["inputs_of"], plan["input_ports_of"])
	_check(k3 == k1, "control: the same value hashes the same")
	# Through the GDScript evaluator's per-node caches, two nodes downstream of the Parameter.
	g.force_gdscript_evaluation = true
	var surf := _bumpy(16)
	var rect := Rect2(0, 0, 16, 16)
	var e1 := g.evaluate(16, 16, rect, null, surf)
	h.set_param(&"lift", 4.0); h.stamp_params()
	var e4 := g.evaluate(16, 16, rect, null, surf)
	_check(e1.size() == 256 and e4.size() == 256 and absf((e4[37] - e1[37]) - 3.0) < TOL,
			"the GDScript evaluator's caches serve the new value, not the old: moved %.4f m (want 3)" % (e4[37] - e1[37]))
	# A cell-only graph: the Parameter is the result, named by index (an Output sink declines the cell compiler).
	var cg := Pasture3DTerrainGraph.create_empty()
	cg.parameters = [_decl(&"lift", 2.0)] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new(); pn.param_id = &"lift"
	cg.nodes = [pn] as Array[Pasture3DGraphNode]
	cg.output_node = 0
	var ch := _host(cg); ch.set_param(&"lift", 6.25); ch.stamp_params()
	var cp: Dictionary = cg.compile_cell_program()
	var params: PackedFloat32Array = cp.get("params", PackedFloat32Array())
	_check(params.size() > 0 and is_equal_approx(params[0], 6.25), "the cell program carries the host's value: %s" % str(params))
	var gp: Dictionary = cg.compile_graph_program()
	_check(not gp.is_empty(), "the Parameter node lowers to the native op table")


# ---- fixtures -------------------------------------------------------------------------------------------

func _decl(p_id: StringName, p_default: float) -> Pasture3DGraphParam:
	var d := Pasture3DGraphParam.new()
	d.id = p_id
	d.default_value = p_default
	d.range_min = -20.0
	d.range_max = 20.0
	return d


## Input + Parameter(lift) -> Output, declaring `lift` with default `p_default`.
func _lift_graph(p_default: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.parameters = [_decl(&"lift", p_default)] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new(); pn.param_id = &"lift"
	g.nodes = [Pasture3DGraphNodeInput.new(), pn, _blend_add(), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 2, 0); _wire(g, 1, 2, 1); _wire(g, 2, 3, 0)
	return g


## The same graph with the value typed into a Const.
func _lift_twin(p_value: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var c := Pasture3DGraphNodeConst.new(); c.value = p_value
	g.nodes = [Pasture3DGraphNodeInput.new(), c, _blend_add(), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 2, 0); _wire(g, 1, 2, 1); _wire(g, 2, 3, 0)
	return g


## Input -> Thermal(FROZEN, talus_angle <- Parameter talus) -> Blend ADD <- Parameter offset -> Output.
func _solver_graph() -> Dictionary:
	var g := Pasture3DTerrainGraph.create_empty()
	g.parameters = [_decl(&"talus", 30.0), _decl(&"offset", 0.0)] as Array[Pasture3DGraphParam]
	var th := Pasture3DGraphNodeErosionThermal.new()
	th.iterations = 6
	th.evaluation = Pasture3DGraphSolverNode.Evaluation.FROZEN
	var pa := Pasture3DGraphNodeParam.new(); pa.param_id = &"talus"
	var pb := Pasture3DGraphNodeParam.new(); pb.param_id = &"offset"
	g.nodes = [Pasture3DGraphNodeInput.new(), th, pa, _blend_add(), pb, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 1, 0)
	_wire(g, 2, 1, th.input_index_of(&"talus_angle"))
	_wire(g, 1, 3, 0); _wire(g, 4, 3, 1); _wire(g, 3, 5, 0)
	return {"graph": g, "solver": th}


func _wire(p_g: Pasture3DTerrainGraph, p_from: int, p_to: int, p_port: int) -> void:
	if not p_g.connect_ports(p_from, 0, p_to, p_port):
		_fail += 1
		print("    !! fixture wire %d -> %d:%d refused: %s" % [p_from, p_to, p_port, p_g.wire_problem(p_from, 0, p_to, p_port)])


func _host(p_g: Pasture3DTerrainGraph) -> Pasture3DNodeGraph:
	var m := Pasture3DNodeGraph.new()
	m.graph = p_g
	m.strength = 1.0
	m.feather_mode = Pasture3DNodeGraph.FeatherMode.OFF
	m.evaluation = Pasture3DNode.Evaluation.LIVE
	return m


func _blend_add() -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = Pasture3DGraphNodeBlend.Mode.ADD
	return n


func _bumpy(p_gw: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gw)
	for iz in range(p_gw):
		for ix in range(p_gw):
			out[iz * p_gw + ix] = 6.0 * sin(float(ix) * 0.7) * cos(float(iz) * 0.5) + (8.0 if (ix / 6 + iz / 6) % 2 == 0 else 0.0)
	return out


func _param_props(p_h: Object) -> Array:
	var out := []
	for p in p_h.get_property_list():
		if String(p["name"]).begins_with("parameters/"):
			out.append(String(p["name"]))
	return out


func _has_line(p_lines: PackedStringArray, p_needle: String) -> bool:
	for l in p_lines:
		if l.contains(p_needle):
			return true
	return false


func _make_mound(p_name: String, p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1; print("    !! no terrain at %s; the fixture is outside demo/data" % p_at); return null
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.height = 10.0
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
	return mound


func _probes(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF * 0.5
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_probes:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return p_vals.size() > 0
