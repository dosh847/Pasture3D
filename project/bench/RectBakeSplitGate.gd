# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RectBakeSplitGate — a rect bake asked to regrade far-apart areas bakes each on its own, and a spline refresh
# that changed nothing bakes nothing.
#
# Trace 2026-09-13 (user's game project): a LakeRoad2 spill box and a junction box a kilometre apart were merged
# into one AABB, 385-411 ms against 91 ms for the junction alone; and a second gizmo commit of an already-baked
# drag found no moved point, which `_spline_dirty_aabb` reads as "whole spline" — a 1035 ms, 1 km x 2 km bake.
#
#   [A] CONTROL  the two boxes are far apart: their merged AABB is more than RECT_MERGE_SLACK times their areas
#   [B]          far boxes clear two disjoint clips, each covering its box
#   [C]          heights inside both boxes after the split bake match a bake of their merged AABB
#   [D]          overlapping boxes still clear ONE clip
#   [E]          a refresh of a spline unchanged since its last bake is skipped; control: after a nudge it bakes
#   [F]          "unchanged" means unchanged since the last bake of ANY kind: a curve put back through a full bake
#                to the shape a rect bake last cached still bakes
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RectBakeSplitGate.tscn
extends Node

const MOVER := "Road2"
const HALF := 20.0
const TOL := 0.0005

var _fail := 0
var _ran := 0
var _scene: Node
var _net: Pasture3DRoadNetwork
var _mover: Pasture3DRoadBrush
var _owner: String


func _ready() -> void:
	print("=== RectBakeSplitGate ===")
	if await _setup():
		_run()
	if _ran != 6:
		_check("completed", false, "%d of 6 criteria ran" % _ran)
	print("=== RECT BAKE SPLIT %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _setup() -> bool:
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		_check("setup", false, "demo_road_network.tscn did not load")
		return false
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().process_frame
	_net = _scene.find_child("Pasture3DRoadNetwork", true, false)
	for b in _net.road_brushes() if _net != null else []:
		if b != null and b.name == MOVER:
			_mover = b
	if _mover == null or _mover._get_splines().is_empty():
		_check("setup", false, "%s with a spline not found" % MOVER)
		return false
	_owner = _mover._layer_owner
	_mover._refresh_owner(_owner, false, [])
	_net.resolve_junctions()
	_mover._refresh_owner(_owner, false, [])
	return true


func _box_at(p: Vector2) -> AABB:
	return AABB(Vector3(p.x - HALF, -1.0, p.y - HALF), Vector3(HALF * 2.0, 2.0, HALF * 2.0))


func _inside(p_box: AABB, p_clip: AABB) -> bool:
	return p_clip.position.x <= p_box.position.x and p_clip.end.x >= p_box.end.x \
			and p_clip.position.z <= p_box.position.z and p_clip.end.z >= p_box.end.z


func _heights(p_boxes: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for bx: AABB in p_boxes:
		for i in 9:
			for k in 9:
				var x := bx.position.x + bx.size.x * float(i) / 8.0
				var z := bx.position.z + bx.size.z * float(k) / 8.0
				out.append(_mover.terrain.data.get_height(Vector3(x, 0.0, z)))
	return out


func _run() -> void:
	var plan := _mover._plan_points()
	var a := _box_at(plan[0])
	var b := _box_at(plan[plan.size() - 1])
	var tile: float = _mover._layer_tile_world(_mover._layer_id)
	var sa := _mover._snap_aabb_to_tiles(a, tile)
	var sb := _mover._snap_aabb_to_tiles(b, tile)
	var m := sa.merge(sb)
	var ratio := (m.size.x * m.size.z) / maxf(sa.size.x * sa.size.z + sb.size.x * sb.size.z, 1.0)

	# [A]
	_ran += 1
	_check("[A] control: boxes far apart", ratio > Pasture3DTerrainBrush.RECT_MERGE_SLACK and a.intersection(b).size == Vector3.ZERO,
			"plan ends (%.0f,%.0f) and (%.0f,%.0f); merged AABB %.1fx their tile areas" % [plan[0].x, plan[0].y,
			plan[plan.size() - 1].x, plan[plan.size() - 1].y, ratio])

	# [C] reference first: one bake of the merged AABB.
	_mover._refresh_owner_rect(_owner, {}, false, [a.merge(b)])
	var merged_clips := _mover._last_rect_clips.size()
	var ref := _heights([a, b])

	# [B]
	_mover._refresh_owner_rect(_owner, {}, false, [a, b])
	var clips: Array = _mover._last_rect_clips.duplicate()
	var split := _heights([a, b])
	var disjoint := clips.size() == 2 and not (clips[0] as AABB).intersects(clips[1])
	var covered := clips.size() == 2 and ((_inside(a, clips[0]) and _inside(b, clips[1])) or (_inside(a, clips[1]) and _inside(b, clips[0])))
	_ran += 1
	_check("[B] far boxes bake apart", _mover._last_rect_decision == "rect" and disjoint and covered,
			"%d clip(s) (merged AABB gave %d); disjoint %s; each covers its box %s" % [clips.size(), merged_clips, disjoint, covered])

	# [C]
	var worst := 0.0
	var n := 0
	for i in mini(ref.size(), split.size()):
		if is_nan(ref[i]) and is_nan(split[i]):
			continue
		n += 1
		var d := absf(ref[i] - split[i])
		worst = d if not (d <= worst) else worst
	_ran += 1
	_check("[C] same heights as the merged bake", n > 0 and ref.size() == split.size() and worst <= TOL,
			"%d sample(s) compared; worst %.5f m" % [n, worst])

	# [D]
	var near := AABB(a.position + Vector3(HALF, 0.0, 0.0), a.size)
	_mover._refresh_owner_rect(_owner, {}, false, [a, near])
	_ran += 1
	_check("[D] overlapping boxes bake once", _mover._last_rect_clips.size() == 1 and _inside(a.merge(near), _mover._last_rect_clips[0]),
			"%d clip(s)" % _mover._last_rect_clips.size())

	# [E]
	var sp: Path3D = _mover._get_splines()[0]
	var sid := sp.get_instance_id()
	var orig := sp.curve.get_point_position(1)
	sp.curve.set_point_position(1, orig + Vector3(0.5, 0.0, 0.5))
	_mover._refresh_owner_rect(_owner, {sid: true}, false)
	var first := _mover._last_rect_decision
	_mover._refresh_owner_rect(_owner, {sid: true}, false)
	var again := _mover._last_rect_decision
	sp.curve.set_point_position(1, orig)
	_mover._refresh_owner_rect(_owner, {sid: true}, false)
	var back := _mover._last_rect_decision
	_ran += 1
	_check("[E] unchanged spline refresh skipped", first == "rect" and again == "skip" and back == "rect",
			"nudge -> %s; same curve again -> %s; nudge back -> %s" % [first, again, back])

	# [F] The skip must key on what the terrain reflects. Rect-bake the nudge, put the curve back through a FULL
	# bake, then nudge again: the curve equals the one the last RECT bake cached, but not the one baked.
	sp.curve.set_point_position(1, orig + Vector3(0.5, 0.0, 0.5))
	_mover._refresh_owner_rect(_owner, {sid: true}, false)
	sp.curve.set_point_position(1, orig)
	_mover._refresh_owner(_owner, false, [])
	sp.curve.set_point_position(1, orig + Vector3(0.5, 0.0, 0.5))
	_mover._refresh_owner_rect(_owner, {sid: true}, false)
	var after_full := _mover._last_rect_decision
	sp.curve.set_point_position(1, orig)
	_mover._refresh_owner(_owner, false, [])
	_ran += 1
	_check("[F] a full bake re-baselines the skip", after_full == "rect",
			"nudge -> rect, back via full bake, same nudge again -> %s" % after_full)
