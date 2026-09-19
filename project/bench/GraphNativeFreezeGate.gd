# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNativeFreezeGate — a FROZEN solver that declares its freeze key rides the native program.
#
# FROZEN used to drop the whole graph onto the GDScript evaluator, because the compiled program had nowhere
# to keep a solve. The program now carries a `frozen` table; the native evaluator rebuilds the key with the
# same recipe as `freeze_key`, serves or solves, and the host adopts the result. Criteria:
#   [P] a FROZEN opted-in graph lowers to native; a FROZEN solver that has not opted in does not (control).
#   [K] key parity: a GDScript solve is SERVED and not stale on the native route; one moved cell is stale.
#   [C] a native cold solve is adopted, then is a hit on the GDScript route; the node starts empty (control).
#   [W] a wired Const on a scalar port stales the freeze on both routes; LIVE moves with it (control).
#   [S] Erosion's cell on a non-square grid matches across routes; the old size.x/gw cell does not (control).
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const RECT_WIDE := Rect2(-64.0, -32.0, 128.0, 64.0) # dx = 4, dz = 2
const EPS := 1.0e-5
# Criteria that must reach their assertion on a full run: five sections, [K] and [C] once per opted-in op.
const FREEZE_OPS := [&"erosion", &"erosion_hydraulic", &"erosion_thermal", &"dla", &"hydraulic_saleve"]
const WANT := 1 + 5 * 2 + 1 + 1 # 5 == FREEZE_OPS.size(), which is not a constant expression

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphNativeFreezeGate: FROZEN solvers ride the native program ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_frozen"):
		print("!! graph_eval_grid_frozen is not bound; rebuild the extension")
		get_tree().quit(1)
		return
	# `-- --only=PKCWS` runs a subset, for isolating a section; the completion count only binds a full run.
	var only := "PKCWS"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	if only.contains("P"):
		_p_native_supported()
	for op in FREEZE_OPS:
		if only.contains("K"):
			_k_key_parity(op)
		if only.contains("C"):
			_c_cold_native_adopted(op)
	if only.contains("W"):
		_w_wired_scalar()
	if only.contains("S"):
		_s_cell_size()
	if only == "PKCWS" and _done != WANT:
		_fail += 1
		print("\n!! only %d of %d criteria reached their assertion" % [_done, WANT])
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NATIVE FREEZE PASS" if _fail == 0 else "GRAPH NATIVE FREEZE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_msg: String) -> void:
	_done += 1
	if not p_ok:
		_fail += 1
		print("      !! " + p_msg)


# ---- [P] ---------------------------------------------------------------------------------------------

func _p_native_supported() -> void:
	print("[P] FROZEN opted-in solvers lower to native; non-opted FROZEN solvers do not")
	var riders := 0
	var blocked := 0
	var bad := []
	for entry in Pasture3DGraphNodeRegistry.entries():
		var op: StringName = entry["op"] if entry.has("op") else &""
		if op == &"" or String(op).begins_with("dev_"):
			continue
		var probe: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if not (probe is Pasture3DGraphSolverNode):
			continue
		if not _graph_with(_make(op, false)).native_supported():
			continue # never native; says nothing about the freeze
		var frozen_native := _graph_with(_make(op, true)).native_supported()
		var rides: bool = probe.native_freeze_supported()
		if rides:
			riders += 1
		else:
			blocked += 1
		if frozen_native != rides:
			bad.append(op)
		print("    %-22s rides=%s FROZEN native=%s" % [op, rides, frozen_native])
	print("    riders=%d blocked (control)=%d" % [riders, blocked])
	_check(bad.is_empty() and riders >= 3 and blocked >= 1, "FROZEN native mismatch %s, or a dead side (riders=%d blocked=%d)" % [bad, riders, blocked])


# ---- [K] ---------------------------------------------------------------------------------------------

func _k_key_parity(p_op: StringName) -> void:
	print("\n[K] %s: a GDScript FROZEN solve is served, not stale, on the native route" % p_op)
	var node := _make(p_op, true)
	var g := _graph_with(node)
	var surf := _mound()
	g.force_gdscript_evaluation = true
	var r1 := g.evaluate(GW, GH, RECT, null, surf)
	var key_gd: int = node._cache_key
	g.force_gdscript_evaluation = false
	var native := g.native_supported()
	var r2 := g.evaluate(GW, GH, RECT, null, surf)
	var stale_same: bool = node._stale
	var cached := _cache_channel_0(node)
	var moved := surf.duplicate()
	moved[GW * (GH / 2) + GW / 2] += 5.0
	var r3 := g.evaluate(GW, GH, RECT, null, moved)
	var stale_moved: bool = node._stale
	# EVIDENCE OF SERVING, for a moved input that no longer matches the key.
	#
	# It used to be `r3 == r1`: a served solve was assumed to reproduce the frozen OUTPUT. That holds only
	# for a solver whose output is its cache. DLA's is not — its cache is the unit massif and amplitude and
	# the wired surface are applied after it (`serve_time_properties`), so a served DLA answers
	# `moved + amplitude * massif` and the moved cell shows up in the output by design. The criterion read
	# that as a re-solve and failed the op for doing exactly what its freeze promises.
	#
	# What "served" actually means is stated directly instead: the stored cache was neither re-solved nor
	# re-adopted (same key, same channel bytes), and the two routes answer the moved input identically —
	# which is the cross-route claim [K] owns, and is still `r3 == r1` for every solver that caches its
	# whole output.
	var cache_kept: bool = node._cache_key == key_gd and _max_abs_diff(cached, _cache_channel_0(node)) < EPS
	g.force_gdscript_evaluation = true
	var r3_gd := g.evaluate(GW, GH, RECT, null, moved)
	g.force_gdscript_evaluation = false
	var relief := _max_abs_diff(r1, surf)
	print("    native=%s solve moved the surface by %.4f | served diff=%.6f not stale=%s | moved: route diff=%.6f stale=%s cache kept=%s"
		% [native, relief, _max_abs_diff(r1, r2), not stale_same, _max_abs_diff(r3, r3_gd), stale_moved, cache_kept])
	_check(native and relief > EPS and _max_abs_diff(r1, r2) < EPS and not stale_same
			and _max_abs_diff(r3, r3_gd) < EPS and stale_moved and cache_kept,
		"%s: key parity across routes failed" % p_op)


## Channel 0 of whatever the freeze is currently holding, empty when it holds nothing. A solver caches an
## Array of channel grids; the single-output ones cache the grid itself.
func _cache_channel_0(p_node) -> PackedFloat32Array:
	if p_node._cache.is_empty():
		return PackedFloat32Array()
	var v = p_node._cache[p_node._cache_key]
	if v is Array:
		return v[0] if (v.size() > 0 and v[0] is PackedFloat32Array) else PackedFloat32Array()
	return v if v is PackedFloat32Array else PackedFloat32Array()


# ---- [C] ---------------------------------------------------------------------------------------------

func _c_cold_native_adopted(p_op: StringName) -> void:
	print("\n[C] %s: a native cold solve is adopted and is a GDScript hit" % p_op)
	var node := _make(p_op, true)
	var g := _graph_with(node)
	var surf := _mound()
	var empty_before: bool = node._cache.is_empty()
	var r1 := g.evaluate(GW, GH, RECT, null, surf)
	var adopted: bool = not node._cache.is_empty()
	var key_native: int = node._cache_key
	g.force_gdscript_evaluation = true
	var r2 := g.evaluate(GW, GH, RECT, null, surf)
	print("    empty before=%s adopted=%s | GDScript hit diff=%.6f not stale=%s key kept=%s"
		% [empty_before, adopted, _max_abs_diff(r1, r2), not node._stale, node._cache_key == key_native])
	_check(empty_before and adopted and _max_abs_diff(r1, r2) < EPS and not node._stale and node._cache_key == key_native,
		"%s: native cold solve was not adopted as the GDScript route's cache" % p_op)


# ---- [W] ---------------------------------------------------------------------------------------------

func _w_wired_scalar() -> void:
	print("\n[W] a wired Const on Erosion's erosion_rate stales the freeze on both routes")
	var surf := _mound()
	var out := {}
	for route in ["gdscript", "native"]:
		for frozen in [true, false]:
			var node := _make(&"erosion", frozen)
			var built := _graph_with_const(node, 2, 0.08)
			var g: Pasture3DTerrainGraph = built[0]
			var c: Pasture3DGraphNode = built[1]
			g.force_gdscript_evaluation = route == "gdscript"
			var ra := g.evaluate(GW, GH, RECT, null, surf)
			c.set("value", 0.5)
			var rb := g.evaluate(GW, GH, RECT, null, surf)
			out["%s_%s" % [route, frozen]] = {"stale": node._stale, "diff": _max_abs_diff(ra, rb)}
	for route in ["gdscript", "native"]:
		print("    %-8s FROZEN stale=%s served diff=%.6f | LIVE diff=%.4f (control)"
			% [route, out[route + "_true"]["stale"], out[route + "_true"]["diff"], out[route + "_false"]["diff"]])
	var ok := true
	for route in ["gdscript", "native"]:
		ok = ok and out[route + "_true"]["stale"] and out[route + "_true"]["diff"] < EPS and out[route + "_false"]["diff"] > 1.0e-3
	_check(ok, "a wired scalar did not stale the freeze on some route, or LIVE ignored the Const")


# ---- [S] ---------------------------------------------------------------------------------------------

func _s_cell_size() -> void:
	print("\n[S] Erosion on non-square cells: native and GDScript share sqrt(dx*dz)")
	var surf := _mound()
	var node := _make(&"erosion", false)
	var g := _graph_with(node)
	var rn := g.evaluate(GW, GH, RECT_WIDE, null, surf)
	g.force_gdscript_evaluation = true
	var rg := g.evaluate(GW, GH, RECT_WIDE, null, surf)
	# CONTROL: the old native cell, size.x / gw, solved directly.
	var params := {"iterations": node.iterations, "erosion_rate": node.erosion_rate, "area_exponent": node.area_exponent,
		"diffusion": node.hillslope_diffusion, "deposition": node.deposition}
	var old: Dictionary = Pasture3DUtil.erosion_solve_grid(surf, GW, GH, RECT_WIDE.size.x / GW, params, PackedFloat32Array())
	var parity := _max_abs_diff(rn, rg)
	var control := _max_abs_diff(rg, old.get("z", PackedFloat32Array()))
	print("    native vs GDScript=%.6f | GDScript vs old size.x/gw cell=%.4f (control, want >> parity)" % [parity, control])
	_check(parity < 1.0e-2 and control > 10.0 * maxf(parity, 1.0e-3), "non-square cell parity failed or the control could not tell the cells apart")


# ---- helpers -----------------------------------------------------------------------------------------

func _make(p_op: StringName, p_frozen: bool) -> Pasture3DGraphNode:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	n.set("evaluation", 1 if p_frozen else 0)
	return n


func _graph_with(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var i_n := g.add_node(p_node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_n, 0)
	g.connect_ports(i_n, 0, i_out, 0)
	return g


func _graph_with_const(p_node: Pasture3DGraphNode, p_port: int, p_value: float) -> Array:
	var g := _graph_with(p_node)
	var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c.set("value", p_value)
	var i_c := g.add_node(c)
	g.connect_ports(i_c, 0, g.nodes.find(p_node), p_port)
	return [g, c]


func _mound() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	var cx := float(GW - 1) * 0.5
	var cz := float(GH - 1) * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var ddx := (float(ix) - cx) / cx
			var ddz := (float(iz) - cz) / cx
			s[iz * GW + ix] = 90.0 * maxf(0.0, 1.0 - (ddx * ddx + ddz * ddz))
	return s


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
