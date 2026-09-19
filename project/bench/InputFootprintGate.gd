# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# InputFootprintGate — the Input node's second pin is the host brush's footprint: the mask its graph step
# composites through, feather and Modifier Margin included.
#
#   A  Kernel: the native Input op's channel 1 equals Pasture3DTerrainGraph.footprint_grid (the oracle) bit
#      for bit, on the footprint's own grid (where it is the footprint itself) and on a shifted, coarser
#      domain (the preview case). Controls: the shifted domain has cells outside the rect (0) and inside
#      (> 0); with no host footprint every cell is 1.0.
#   B  GDScript evaluator: Input.footprint -> Output agrees with native, and a new footprint is re-evaluated
#      rather than served from the node cache (control: the second answer differs from the first).
#   C  Bake, both raster routes: the footprint stamped on the graph is the bake grid's size, 1 in the middle,
#      0 at the grid corner, fractional in the feather. The routes agree to within the loop rim.
#   D  The reported bug: a Color Sink masked by the footprint paints inside the brush and NOT at a cell of
#      the solved rectangle the footprint excludes. Control: the same sink unmasked paints that cell.
#   E  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/InputFootprintGate.tscn
extends Node

const HALF := 20.0
const MARGIN := 8.0
const CRITERIA := ["A", "B", "C", "D"]
const RED := Color(1.0, 0.0, 0.0, 1.0)

var _fail := 0
var _seen := {}
var _uniq := 0


func _ready() -> void:
	print("=== InputFootprintGate: the Input node's footprint pin ===")
	_a_kernel()
	_b_gdscript()
	await _c_bake()
	await _d_sink()
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
		else:
			print("!! [%s] returned without reporting" % name)
	_check("E", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== INPUT FOOTPRINT %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


func _diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


## A graph whose Output is the Input node's footprint pin.
func _fp_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 1, 1, 0]]
	g.set_output(1)
	return g


func _ramp(p_gw: int, p_gh: int, p_seed: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_gw * p_gh)
	for i in a.size():
		a[i] = fposmod(float(i) * 0.0137 + p_seed, 1.0)
	return a


func _tap(p_g: Pasture3DTerrainGraph, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var c: Dictionary = p_g.compile_graph_program_multi([0])
	var r: Dictionary = Pasture3DUtil.graph_eval_grid_taps(c["program"], p_gw, p_gh, p_rect,
			Pasture3DGraphOps.zeros(p_gw * p_gh), PackedInt32Array([int(c["slot_of"][0])]), PackedInt32Array([1]))
	return r["fields"][0]


# --- A. kernel ----------------------------------------------------------------------------------------
func _a_kernel() -> void:
	print("[A] native Input channel 1 == footprint_grid")
	var g := _fp_graph()
	var fr := Rect2(10.0, 20.0, 64.0, 48.0)
	var fp := _ramp(64, 48, 0.0)
	g.set_host_footprint(fp, 64, 48, fr)
	var same := _tap(g, 64, 48, fr)
	var shifted_rect := Rect2(-5.0, 30.0, 70.0, 70.0)
	var shifted := _tap(g, 35, 35, shifted_rect)
	var oracle := Pasture3DTerrainGraph.footprint_grid(g.host_footprint, 35, 35, shifted_rect)
	_check("A", _diff(same, fp) == 0.0 and _diff(shifted, oracle) == 0.0,
			"own grid vs footprint %s; shifted domain vs oracle %s (want 0, 0)" % [str(_diff(same, fp)), str(_diff(shifted, oracle))])
	var zeros := 0
	var inside := 0
	for v in shifted:
		if v == 0.0:
			zeros += 1
		elif v > 0.0:
			inside += 1
	_control(zeros > 0 and inside > 0, "shifted domain: %d cells outside the rect, %d inside" % [zeros, inside])
	g.set_host_footprint(PackedFloat32Array(), 0, 0, Rect2())
	var none := _tap(g, 16, 16, fr)
	_control(_diff(none, Pasture3DGraphOps.filled(256, 1.0)) == 0.0, "no host footprint reads 1.0 everywhere")


# --- B. GDScript evaluator -----------------------------------------------------------------------------
func _b_gdscript() -> void:
	print("[B] the GDScript evaluator reads the same pin")
	var g := _fp_graph()
	var fr := Rect2(0.0, 0.0, 32.0, 32.0)
	g.set_host_footprint(_ramp(32, 32, 0.0), 32, 32, fr)
	var z := Pasture3DGraphOps.zeros(32 * 32)
	var lowers := g.native_supported()
	var nat := g.evaluate(32, 32, fr, null, z)
	g.force_gdscript_evaluation = true
	var gd1 := g.evaluate(32, 32, fr, null, z)
	g.set_host_footprint(_ramp(32, 32, 0.5), 32, 32, fr)
	var gd2 := g.evaluate(32, 32, fr, null, z)
	_check("B", lowers and _diff(nat, gd1) == 0.0 and _diff(gd2, _ramp(32, 32, 0.5)) == 0.0,
			"native lowers %s; native vs GDScript %s; second footprint vs GDScript %s (want 0, 0)"
			% [str(lowers), str(_diff(nat, gd1)), str(_diff(gd2, _ramp(32, 32, 0.5)))])
	_control(_diff(gd1, gd2) > 0.1, "a new footprint is re-evaluated, not served from the node cache (%s)" % str(_diff(gd1, gd2)))


# --- fixtures for C and D ------------------------------------------------------------------------------
func _terrain() -> Pasture3D:
	var t := Pasture3D.new()
	_uniq += 1
	t.name = "T%d" % _uniq
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	return t


func _mound(p_t: Pasture3D, p_graph: Pasture3DTerrainGraph, p_gd: bool) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	_uniq += 1
	m.name = "M%d" % _uniq
	add_child(m)
	m.terrain = p_t
	m.global_position = Vector3(64.0, 0.0, 64.0)
	m.height = 10.0
	m.modifier_margin = MARGIN
	m.force_gdscript_raster = p_gd
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	m.add_child(path)
	var mod := Pasture3DNodeGraph.new()
	mod.graph = p_graph
	m.modifiers = [mod] as Array[Pasture3DNode]
	return m


func _bake(p_m: Pasture3DMound) -> void:
	p_m._stamp_cache.clear()
	p_m._refresh_owner(p_m._layer_owner, false, [])
	await get_tree().process_frame


## Input -> Output, with a Color Sink whose mask is the footprint pin (or unwired).
func _sink_graph(p_masked: bool) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var sink := Pasture3DGraphNodeColorSink.new()
	sink.color = RED
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new(), sink]
	g.nodes = nodes
	var conns: Array = [[0, 0, 1, 0]]
	if p_masked:
		conns.append([0, 1, 2, 0])
	g.connections = conns
	g.set_output(1)
	return g


# --- C. bake -------------------------------------------------------------------------------------------
func _fp_stats(p_fp: Dictionary) -> Dictionary:
	var grid: PackedFloat32Array = p_fp.get("grid", PackedFloat32Array())
	var gw: int = int(p_fp.get("gw", 0))
	var gh: int = int(p_fp.get("gh", 0))
	var frac := 0
	for v in grid:
		if v > 0.01 and v < 0.99:
			frac += 1
	return {"ok_size": gw > 0 and grid.size() == gw * gh, "gw": gw, "gh": gh, "frac": frac,
			"mid": grid[(gh / 2) * gw + gw / 2] if grid.size() > 0 else -1.0,
			"corner": grid[0] if grid.size() > 0 else -1.0}


func _shape_ok(p_s: Dictionary) -> bool:
	return p_s["ok_size"] and p_s["mid"] == 1.0 and p_s["corner"] == 0.0 and p_s["frac"] > 0


func _c_bake() -> void:
	print("[C] a bake stamps the footprint, on both raster routes")
	var t1 := _terrain()
	var m1 := _mound(t1, _sink_graph(true), false)
	var native_route: bool = m1._native_raster("stamp_mound_loop") and m1.modifiers[0].graph.native_supported()
	await _bake(m1)
	var fn: Dictionary = m1.modifiers[0].graph.host_footprint
	var t2 := _terrain()
	var m2 := _mound(t2, _sink_graph(true), true)
	await _bake(m2)
	var fg: Dictionary = m2.modifiers[0].graph.host_footprint
	var sn := _fp_stats(fn)
	var sg := _fp_stats(fg)
	var differ := 0
	if sn["ok_size"] and sg["ok_size"] and sn["gw"] == sg["gw"] and sn["gh"] == sg["gh"]:
		for i in (fn["grid"] as PackedFloat32Array).size():
			if absf(fn["grid"][i] - fg["grid"][i]) > 1.0e-4:
				differ += 1
	else:
		differ = -1
	var rim: int = 2 * (int(sn["gw"]) + int(sn["gh"]))
	_check("C", native_route and _shape_ok(sn) and _shape_ok(sg) and differ >= 0 and differ <= rim,
			"native route %s; native %s; GDScript %s; cells differing %d (want <= rim %d)"
			% [str(native_route), str(sn), str(sg), differ, rim])
	for n in [m1, m2, t1, t2]:
		n.queue_free()


# --- D. the sink stays in the footprint ----------------------------------------------------------------
func _d_sink() -> void:
	print("[D] a Color Sink masked by the footprint stays inside the brush")
	var t := _terrain()
	var m := _mound(t, _sink_graph(true), false)
	await _bake(m)
	var fp: Dictionary = m.modifiers[0].graph.host_footprint
	var grid: PackedFloat32Array = fp.get("grid", PackedFloat32Array())
	var gw: int = int(fp.get("gw", 0))
	var gh: int = int(fp.get("gh", 0))
	var rect: Rect2 = fp.get("rect", Rect2())
	var out_cell := Vector3.INF
	var in_cell := Vector3.INF
	for iz in range(gh):
		for ix in range(gw):
			var p := Vector3(rect.position.x + (ix + 0.5) * rect.size.x / gw, 0.0,
					rect.position.y + (iz + 0.5) * rect.size.y / gh)
			if grid[iz * gw + ix] == 0.0 and out_cell == Vector3.INF:
				out_cell = p
			if grid[iz * gw + ix] == 1.0 and in_cell == Vector3.INF:
				in_cell = p
	var found := out_cell != Vector3.INF and in_cell != Vector3.INF
	var c_in: Color = t.data.get_color(in_cell) if found else Color.BLACK
	var c_out: Color = t.data.get_color(out_cell) if found else RED
	_check("D", found and c_in.is_equal_approx(RED) and not c_out.is_equal_approx(RED),
			"inside %s at %s (want red); excluded cell %s at %s (want not red)"
			% [str(c_in), str(in_cell), str(c_out), str(out_cell)])
	var t2 := _terrain()
	var m2 := _mound(t2, _sink_graph(false), false)
	await _bake(m2)
	var c_ctl: Color = t2.data.get_color(out_cell) if found else Color.BLACK
	_control(c_ctl.is_equal_approx(RED), "unmasked, the same cell is painted %s (want red)" % str(c_ctl))
	for n in [m, m2, t, t2]:
		n.queue_free()
