# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RepassSkipGate — the deferred driver skips pass 2 when every solve equals what pass 1 painted.
#
# Pass 1 of a Live run paints the graph's last answer rebased onto the edited surface. A graph whose output
# is its Input plus something fixed in the world (Input + Noise) solves to exactly that preview, so pass 2
# would clear and repaint the same ground (trace 2026-10-25: Mound6, 0.95 s, 0 of 2304 samples moved).
#
#   [A] Input + Noise, one corner dragged inside the box: the run ends after pass 1 (one skip) and the ground equals
#       the synchronous bake. Control: `repass_always`, which runs pass 2 and lands on the same ground
#   [B] Noise alone (absolute output, so the rebased preview is wrong after the edit): no skip, and the
#       ground still equals the synchronous bake. This is the control that the comparison can say no
#   [C] An identity graph (Input -> Output) is dropped from the stack: pass 1 queues no graph solve and the
#       ground equals the Mound with no modifiers. Control: `identity_is_active`, which queues one
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RepassSkipGate.tscn
extends Node

const CRITERIA := 3
const TOL := 1e-3

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== RepassSkipGate ===")
	await _a()
	await _b()
	await _c()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== REPASS SKIP %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _graph(p_with_input: bool) -> Pasture3DNodeGraph:
	var fn := FastNoiseLite.new()
	fn.seed = 11
	fn.frequency = 0.06
	var gn := Pasture3DGraphNodeNoise.new()
	gn.noise = fn
	gn.amplitude = 4.0
	var g := Pasture3DTerrainGraph.new()
	if p_with_input:
		var blend := Pasture3DGraphNodeBlend.new()
		blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
		var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), gn, blend,
				Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]),
				PackedInt32Array([2, 0, 3, 0])]
	else:
		var nodes: Array[Pasture3DGraphNode] = [gn, Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [PackedInt32Array([0, 0, 1, 0])]
	var mg := Pasture3DNodeGraph.new()
	mg.graph = g
	mg.strength = 0.7
	mg.evaluation = Pasture3DNode.Evaluation.LIVE
	return mg


## A fresh terrain and Mound carrying `p_mod`, its first Live answer already landed.
func _fixture(p_mod: Pasture3DNode) -> Dictionary:
	var t := Pasture3D.new()
	t.name = "Terrain"
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	var m := Pasture3DMound.new()
	m.name = "Skip"
	m.auto_refresh = false
	m.force_deferred_erosion = true
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(12, 0, 12), Vector3(48, 0, 12), Vector3(48, 0, 48), Vector3(12, 0, 48)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = t
	var mods: Array[Pasture3DNode] = [p_mod]
	m.modifiers = mods
	await _run(m)
	return {"t": t, "m": m}


func _drop(p_fx: Dictionary) -> void:
	var m: Pasture3DMound = p_fx["m"]
	remove_child(m)
	m.free()
	(p_fx["t"] as Node).queue_free()
	await get_tree().process_frame


func _run(p_m: Pasture3DMound) -> void:
	var box := [false]
	var drive := func() -> void:
		await p_m._bake_deferred(p_m._refresh_owner.bind(p_m._layer_owner, false, []), p_m._layer_owner, false)
		box[0] = true
	drive.call()
	while not box[0]:
		await get_tree().process_frame


func _heights(p_t: Pasture3D) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	for z in range(64):
		for x in range(64):
			h.append(p_t.data.get_height(Vector3(float(x), 0.0, float(z))))
	return h


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


## The edit, then one deferred run; returns the skips it took and its ground against the sync bake.
func _edit_and_run(p_m: Pasture3DMound, p_corner: Vector3) -> Dictionary:
	var t: Pasture3D = p_m.terrain
	# Inside the bounding box, so the extent (and the grid the preview was solved on) stays put.
	(p_m.get_child(0) as Path3D).curve.set_point_position(2, p_corner)
	var s0 := p_m.repass_skips
	await _run(p_m)
	var run := _heights(t)
	# Reference: the synchronous bake of the same scene (a Live graph solves inline outside a run).
	p_m.force_deferred_erosion = false
	p_m._refresh_owner(p_m._layer_owner, false, [])
	p_m.force_deferred_erosion = true
	var ref := _heights(t)
	return {"skips": p_m.repass_skips - s0, "worst": _worst(run, ref)}


func _a() -> void:
	var fx := await _fixture(_graph(true))
	var m: Pasture3DMound = fx["m"]
	var r := await _edit_and_run(m, Vector3(42, 0, 42))
	_check("A skips pass 2", int(r["skips"]) == 1 and float(r["worst"]) <= TOL,
			"%d skip(s) (want 1); worst |run - sync| %.6f m (want <= %.4f)" % [r["skips"], r["worst"], TOL])
	m.repass_always = true
	var c := await _edit_and_run(m, Vector3(36, 0, 36))
	m.repass_always = false
	_check("A control", int(c["skips"]) == 0 and float(c["worst"]) <= TOL,
			"repass_always: %d skip(s) (want 0); worst |run - sync| %.6f m" % [c["skips"], c["worst"]])
	await _drop(fx)
	_ran += 1


func _b() -> void:
	var fx := await _fixture(_graph(false))
	var m: Pasture3DMound = fx["m"]
	var r := await _edit_and_run(m, Vector3(42, 0, 42))
	_check("B absolute graph repaints", int(r["skips"]) == 0 and float(r["worst"]) <= TOL,
			"%d skip(s) (want 0); worst |run - sync| %.6f m (want <= %.4f)" % [r["skips"], r["worst"], TOL])
	await _drop(fx)
	_ran += 1


func _identity() -> Pasture3DNodeGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	var mg := Pasture3DNodeGraph.new()
	mg.graph = g
	mg.evaluation = Pasture3DNode.Evaluation.LIVE
	return mg


## Pass 1 of a deferred run and nothing after it; returns how many graph solves it queued.
func _pass1_queued(p_m: Pasture3DMound) -> int:
	var run: int = p_m._begin_deferred_run()
	p_m._pending_graph = []
	p_m._graph_defer = true
	p_m._refresh_owner(p_m._layer_owner, false, [])
	var n := p_m._pending_graph.size()
	p_m._pending_graph = []
	p_m._end_deferred_run(run)
	return n


func _c() -> void:
	var mg := _identity()
	var fx := await _fixture(mg)
	var m: Pasture3DMound = fx["m"]
	var t: Pasture3D = fx["t"]
	var queued := _pass1_queued(m)
	var with_graph := _heights(t)
	var none: Array[Pasture3DNode] = []
	m.modifiers = none
	m._refresh_owner(m._layer_owner, false, [])
	var bare := _heights(t)
	var mods: Array[Pasture3DNode] = [mg]
	m.modifiers = mods
	_check("C identity graph dropped", queued == 0 and _worst(with_graph, bare) == 0.0,
			"%d graph solve(s) queued (want 0); worst |identity - no modifiers| %.6f m (want 0)"
				% [queued, _worst(with_graph, bare)])
	mg.identity_is_active = true
	var ctl := _pass1_queued(m)
	mg.identity_is_active = false
	_check("C control", ctl == 1, "identity_is_active: %d graph solve(s) queued (want 1)" % ctl)
	await _drop(fx)
	_ran += 1
