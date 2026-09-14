# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushDriverGate — phase 4 of PASTURE3D_LAYER_BRUSH_SPEC.md: the Layer is the run owner.
#
#   [L] Bake All over a Frozen-erosion Layer, deferred: caches cleared, the base committed once, and the
#       children baked after it, in that order (work-order log). Control: children before the base commit
#   [S] A deferred run with a Live erosion on the Layer and on a child: the child's result equals the
#       synchronous bake over the NEW base, bitwise. Control: children collect their solves first
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushDriverGate.tscn
extends Node

const CRITERIA := 2

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== LayerBrushDriverGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	_terrain.data.add_region_blank(Vector2i(0, 0), true)
	_terrain.data.ensure_layer_stack()
	for f in [_l, _s]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER BRUSH DRIVER %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _noise(p_seed: int) -> Pasture3DNodeNoise:
	var fn := FastNoiseLite.new()
	fn.seed = p_seed
	fn.frequency = 0.08
	var nz := Pasture3DNodeNoise.new()
	nz.noise = fn
	nz.strength = 4.0
	return nz


func _erosion(p_eval: Pasture3DNode.Evaluation) -> Pasture3DNodeErosion:
	var e := Pasture3DNodeErosion.new()
	e.evaluation = p_eval
	e.iterations = 8
	return e


func _layer(p_name: String, p_mods: Array) -> Pasture3DLayerBrush:
	var lb := Pasture3DLayerBrush.new()
	lb.name = p_name
	lb.terrain = _terrain
	lb.auto_refresh = false
	lb.force_deferred_erosion = true
	var mods: Array[Pasture3DNode] = []
	for m in p_mods:
		mods.append(m)
	lb.modifiers = mods
	lb.modifier_margin = 8.0
	_terrain.add_child(lb)
	return lb


func _mound(p_parent: Node, p_name: String, p_mods: Array) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	m.force_deferred_erosion = true
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in [Vector3(16, 0, 16), Vector3(48, 0, 16), Vector3(48, 0, 48), Vector3(16, 0, 48)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	var mods: Array[Pasture3DNode] = []
	for x in p_mods:
		mods.append(x)
	m.modifiers = mods
	p_parent.add_child(m)
	return m


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(8, 56):
		for x in range(8, 56):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


## Order check over a log: "clear" first, one "base_commit", and every child entry after it.
func _ordered(p_log: Array[String]) -> Dictionary:
	var clear := p_log.find("clear")
	var commit := p_log.find("base_commit")
	var commits := p_log.count("base_commit")
	var first_child := -1
	var children := 0
	for i in range(p_log.size()):
		if p_log[i].begins_with("child:"):
			children += 1
			if first_child < 0:
				first_child = i
	return {"ok": commits == 1 and first_child > commit and commit >= 0 and clear < commit,
			"clear": clear, "commit": commit, "commits": commits, "first_child": first_child,
			"children": children, "solves": p_log.count("base_solve")}


func _l() -> void:
	var lb := _layer("Frozen", [_noise(3), _erosion(Pasture3DNode.Evaluation.FROZEN)])
	var kid := _mound(lb, "Kid", [])
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.bake_layer()
	var mgr := Pasture3DSimManager.new()
	mgr.name = "Manager"
	add_child(mgr)
	mgr.terrain = _terrain
	var listed: Array[NodePath] = [mgr.get_path_to(lb)]
	mgr.eroding_brushes = listed

	lb.work_log.clear()
	await mgr.bake_all_brushes()
	var rep: Dictionary = mgr.last_bake_report
	var o := _ordered(lb.work_log)
	_check("L order", bool(o["ok"]) and o["clear"] == 0 and int(rep.get("cleared", 0)) >= 1 and int(o["solves"]) >= 2,
			"log %s; cleared %d caches, %d base solve passes (deferred wants >= 2)" % [lb.work_log, int(rep.get("cleared", 0)), o["solves"]])

	lb.children_before_base = true
	lb.work_log.clear()
	await mgr.bake_all_brushes()
	var c := _ordered(lb.work_log)
	_check("L control", not bool(c["ok"]) and int(c["first_child"]) >= 0, "children before the base commit: log %s" % [lb.work_log])
	mgr.free()
	lb.free()
	await _settle()
	_ran += 1


func _s() -> void:
	var nz := _noise(1)
	var lb := _layer("Live", [nz, _erosion(Pasture3DNode.Evaluation.LIVE)])
	var kid := _mound(lb, "Kid", [_erosion(Pasture3DNode.Evaluation.LIVE)])
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS

	# Reference: the synchronous bake over the new base (Live solves inline outside a run).
	nz.noise.seed = 2
	lb._base_key = ""
	lb.bake_layer()
	var ref := _heights()
	nz.noise.seed = 1
	lb._base_key = ""
	lb.bake_layer()
	var old := _heights()

	nz.noise.seed = 2
	lb._base_key = ""
	lb.work_log.clear()
	await lb.bake_layer_run()
	var run := _heights()
	var o := _ordered(lb.work_log)
	_check("S this run's base", run == ref and ref != old and int(o["solves"]) >= 2 and int(o["children"]) >= 2 and int(o["first_child"]) > int(o["commit"]),
			"bitwise equal to the sync bake %s, base moved %s, log %s" % [run == ref, ref != old, lb.work_log])

	nz.noise.seed = 1
	lb._base_key = ""
	lb.bake_layer()
	nz.noise.seed = 2
	lb._base_key = ""
	lb.children_before_base = true
	await lb.bake_layer_run()
	lb.children_before_base = false
	var ctl := _heights()
	_check("S control", ctl != ref, "children solving before the base commit differ from the sync bake: %s" % (ctl != ref))
	lb.free()
	await _settle()
	_ran += 1
