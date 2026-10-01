# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadLeftoverGate — what a road leaves behind when it moves or is deleted (2026-10-01).
#
# Two roads along +x over ground waving 3 m along x, which their grade limit cannot follow, so each cuts
# and fills: the graded height at XMID is measurably off the ground. Both on the default "Roads" height
# layer and the network's paint layer. Road A at z = ZA, road B at z = ZB.
#   [P] moved paint: road A moved from ZA to ZM, re-baked and re-painted, leaves no paint at ZA and is
#       painted at ZM; B is still painted. Control: ZA was painted before the move
#   [D] deleted: road A removed from the tree the way the editor deletes (kept, not freed) lifts its fill
#       and its paint, and B keeps both. Control: before the delete A's fill and paint are there
#   [W] legacy leftovers: road C deleted with nothing tracking it (no delete check, its paint record lost
#       as on a reload) leaves fill and paint; `wipe_road_layers` then a re-bake of B removes them and B
#       comes back. Control: the leftovers are there before the wipe
#       (Bake All Roads is wipe + `bake_road`, whose `refresh()` is editor-only, so B is re-baked directly.)
#
# Undo of a delete re-bakes through `refresh()`, which is editor-only, so it is not covered here.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadLeftoverGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["P", "D", "W"]
const RS := 256
const ROAD := 0.0
const WAVE := 3.0
const ZA := 40.0
const ZB := 128.0
const ZM := 215.0
const XMID := 128.0

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadLeftoverGate ===")
	await _run()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD LEFTOVER %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _road(p_terrain: Pasture3D, p_net: Pasture3DRoadNetwork, p_t: Pasture3DRoadType, p_name: String,
		p_z: float) -> Pasture3DRoadBrush:
	var road := Pasture3DRoadBrush.new()
	road.name = p_name
	road.terrain = p_terrain
	road.road_road_type = p_t
	road.log_bake_timing = false
	road.snap_to_surface = false
	p_net.add_child(road)
	var path := Path3D.new()
	path.name = "Spline"
	var c := Curve3D.new()
	for i in 5:
		c.add_point(Vector3(48.0 + 40.0 * float(i), ROAD, p_z))
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	return road


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


## How far the terrain at (XMID, p_z) is off the ground the fixture laid: what a road's grading moved.
func _h(p_terrain: Pasture3D, p_z: float) -> float:
	return absf(p_terrain.data.get_height(Vector3(XMID, 0.0, p_z)) - _ground(XMID))


func _ground(p_x: float) -> float:
	return WAVE * sin(TAU * p_x / 40.0)


func _painted(p_terrain: Pasture3D, p_z: float, p_blank: int) -> bool:
	return p_terrain.data.get_control(Vector3(XMID, 0.0, p_z)) != p_blank


func _run() -> void:
	var terrain := Pasture3D.new()
	terrain.name = "Terrain"
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	await get_tree().process_frame
	terrain.change_region_size(RS)
	var d := terrain.data
	d.add_region_blank(Vector2i(0, 0), false)
	var r = d.get_region(Vector2i(0, 0))
	var img: Image = r.get_height_map()
	for col in RS:
		img.fill_rect(Rect2i(col, 0, 1, RS), Color(_ground(float(col)), 0, 0, 1))
	r.set_modified(true)
	r.calc_height_range()
	d.update_maps()
	d.calc_height_range(true)
	d.ensure_layer_stack()
	var net := Pasture3DRoadNetwork.new()
	net.name = "RoadNetwork"
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.lane_count = 2
	t.lane_width = 3.0
	t.shoulder_width = 1.0
	t.fill_batter = 1.0
	t.cut_batter = 1.0
	t.surface_layer_id = 3
	net.road_types = [t]
	var a := _road(terrain, net, t, "A", ZA)
	var b := _road(terrain, net, t, "B", ZB)
	await _frames(2)
	var blank: int = d.get_control(Vector3(XMID, 0.0, 250.0))
	a._refresh_owner(a._layer_owner, false, [])
	net.paint_roads()
	await _frames(2)

	# [P]
	print("[P] a moved road leaves no paint behind")
	var was_painted := _painted(terrain, ZA, blank)
	var path: Path3D = a.get_child(0) as Path3D
	for i in path.curve.point_count:
		var p := path.curve.get_point_position(i)
		path.curve.set_point_position(i, Vector3(p.x, p.y, ZM))
	await _frames(2)
	a._refresh_owner(a._layer_owner, false, [])
	net.paint_roads()
	await _frames(2)
	var old_painted := _painted(terrain, ZA, blank)
	var new_painted := _painted(terrain, ZM, blank)
	var b_painted := _painted(terrain, ZB, blank)
	print("    before the move ZA painted %s; after: ZA %s, ZM %s, B %s" % [was_painted, old_painted,
			new_painted, b_painted])
	_check("P", was_painted and not old_painted and new_painted and b_painted,
			"the old carriageway is cleared, the new one and B painted; control: the old one was painted")

	# [D]
	print("[D] a deleted road lifts its fill and its paint")
	var a_h0 := _h(terrain, ZM)
	var a_p0 := _painted(terrain, ZM, blank)
	a.detect_brush_delete_headless = true
	net.remove_child(a) # what the editor's delete does: the node is kept for undo
	await _frames(6)
	var a_h1 := _h(terrain, ZM)
	var a_p1 := _painted(terrain, ZM, blank)
	var b_h1 := _h(terrain, ZB)
	var b_p1 := _painted(terrain, ZB, blank)
	print("    A before: graded %.2f m off the ground, painted %s; after: %.2f m, painted %s; B after: %.2f m, painted %s"
			% [a_h0, a_p0, a_h1, a_p1, b_h1, b_p1])
	_check("D", a_h0 > 0.5 and a_p0 and a_h1 < 0.05 and not a_p1 and b_h1 > 0.5 and b_p1,
			"A's fill and paint are gone, B keeps both; control: A had both before the delete")
	a.free()

	# [W]
	print("[W] a from-scratch bake removes leftovers nothing tracks")
	var c := _road(terrain, net, t, "C", ZA)
	await _frames(2)
	c._refresh_owner(c._layer_owner, false, [])
	net.paint_roads()
	await _frames(2)
	var c_key := c.road_key()
	net.remove_child(c) # no delete check: the old behaviour
	net._painted.erase(c_key)
	c.free()
	await _frames(2)
	var c_h0 := _h(terrain, ZA)
	var c_p0 := _painted(terrain, ZA, blank)
	net.wipe_road_layers()
	b._refresh_owner(b._layer_owner, false, [])
	net.paint_roads()
	await _frames(2)
	var c_h1 := _h(terrain, ZA)
	var c_p1 := _painted(terrain, ZA, blank)
	var b_h2 := _h(terrain, ZB)
	var b_p2 := _painted(terrain, ZB, blank)
	print("    leftover before: %.2f m, painted %s; after: %.2f m, painted %s; B after: %.2f m, painted %s"
			% [c_h0, c_p0, c_h1, c_p1, b_h2, b_p2])
	_check("W", c_h0 > 0.5 and c_p0 and c_h1 < 0.05 and not c_p1 and b_h2 > 0.5 and b_p2,
			"the untracked fill and paint are gone and B is rebuilt; control: they were there before")
	terrain.queue_free()
	await _frames(1)
