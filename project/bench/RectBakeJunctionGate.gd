# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RectBakeJunctionGate — does a partial (rect) road bake leave another road's junction ground the way a full
# layer bake of the SAME edit would?
#
# Trace 2026-09-13: the ground at Road+Road1@96,-1 read 0.719, then -0.029 right after a Road2 rect bake
# that repainted 4 of 7 roads, then 0.718 after a full bake repainted all 7. Each flip re-armed two roads.
# Suspected: the rect bake clears whole tiles on the layer but repaints only mates whose SPLINE footprint
# meets the box, so earthwork reaching into the box from outside is erased. This gate measures that rather
# than assuming it.
#
#   [A] For each control point of the moved road in turn: every junction not involving that road that lies
#       inside the cleared box has the same ground after the rect bake as after a full bake of the same curve,
#       within 5 cm.
#
# The reference is the full bake at the same curve, not the pre-edit ground: moving a point may legitimately
# move nearby batters, but the partial and the full bake of one input must agree.
#
# Two ways this could measure nothing, both reported as NOT COVERED and counted as failures:
#   - no foreign junction ever lies inside a cleared box;
#   - the ground reads NaN (no terrain data loaded). The first version of this gate redirected
#     data_directory to an empty folder, every height came back NaN, NaN "matched" NaN, and it passed.
#
# Uses the demo road network like RoadInteractivePerfGate and keeps the scene's own terrain data, which a
# headless run never saves — check `git status` after running anyway.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RectBakeJunctionGate.tscn
extends Node

const MOVER := "Road2"
const TOL := 0.05
const NUDGE := Vector3(0.5, 0.0, 0.5)

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== RectBakeJunctionGate: partial vs full bake at foreign junctions ===\n")
	await _a_rect_matches_full()
	print("\n  criteria completed: %d (want 1)" % _ran)
	if _ran != 1:
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["RECT BAKE JUNCTION PASS" if _fail == 0 else "RECT BAKE JUNCTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _not_covered(p_why: String) -> void:
	_fail += 1
	print("    !! NOT COVERED: %s" % p_why)


func _a_rect_matches_full() -> void:
	print("[A] rect bake leaves foreign junction ground equal to a full bake of the same edit")
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		_not_covered("demo_road_network.tscn did not load")
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	await get_tree().process_frame
	var net: Pasture3DRoadNetwork = scene.find_child("Pasture3DRoadNetwork", true, false)
	var terrain: Pasture3D = scene.find_child("Pasture3D", true, false)
	if net == null or terrain == null:
		_not_covered("no road network or terrain in the demo scene")
		return

	var mover: Pasture3DRoadBrush = null
	for b in net.road_brushes():
		if b != null and b.name == MOVER:
			mover = b
	if mover == null or mover._get_splines().is_empty():
		_not_covered("%s with a spline not found" % MOVER)
		return
	var owner: String = mover._layer_owner

	# A settled layer: bake, resolve pins, bake again with them. Headless, the resolve's rebake requests are
	# no-ops (the schedulers are editor-only), so the second bake is explicit.
	mover._refresh_owner(owner, false, [])
	net.resolve_junctions()
	mover._refresh_owner(owner, false, [])

	var key := mover.road_key()
	var foreign: Array = []
	for j in net.junctions:
		if not j.road_keys.has(key):
			foreign.append(j)
	if foreign.is_empty():
		_not_covered("no junction without %s" % MOVER)
		scene.queue_free()
		return
	var base := _heights(terrain, foreign)
	var nan_count := 0
	for h in base:
		if is_nan(h):
			nan_count += 1
	print("    %d foreign junction(s); ground readable at %d" % [foreign.size(), foreign.size() - nan_count])
	if nan_count == foreign.size():
		_not_covered("ground is NaN at every foreign junction — no terrain data loaded")
		scene.queue_free()
		return

	var sp: Path3D = mover._get_splines()[0]
	var inside := 0
	var bad := 0
	for i in sp.curve.point_count:
		var orig := sp.curve.get_point_position(i)
		sp.curve.set_point_position(i, orig + NUDGE)
		Pasture3DBakeTrace.start(false)
		mover._refresh_owner_rect(owner, {sp.get_instance_id(): true})
		var mark := ""
		for ev in Pasture3DBakeTrace.events():
			if ev["type"] == "mark" and String(ev["text"]).contains("rect bake"):
				mark = String(ev["text"])
		Pasture3DBakeTrace.stop()
		var clip: AABB = mover._last_rect_clip
		var after_rect := _heights(terrain, foreign)
		mover._refresh_owner(owner, false, [])
		var after_full := _heights(terrain, foreign)
		# Restore and re-settle, so the next point starts from the unedited layer.
		sp.curve.set_point_position(i, orig)
		mover._refresh_owner(owner, false, [])

		var rows := PackedStringArray()
		for k in foreign.size():
			var c: Vector2 = foreign[k].center
			if clip.size == Vector3.ZERO or c.x < clip.position.x or c.x > clip.end.x 					or c.y < clip.position.z or c.y > clip.end.z:
				continue
			var r: float = after_rect[k]
			var f: float = after_full[k]
			if is_nan(r) or is_nan(f):
				rows.append("       ?? %-24s rect %8.3f  full %8.3f  (NaN: not measured)" % [foreign[k].id, r, f])
				continue
			inside += 1
			var off := absf(r - f) > TOL
			if off:
				bad += 1
			rows.append("       %s %-24s rect %8.3f  full %8.3f  |d| %.3f" % ["!!" if off else "  ",
					foreign[k].id, r, f, absf(r - f)])
		print("    point %d: %s" % [i, mark.get_slice(": ", 1) if mark != "" else "(no rect bake mark)"])
		for row in rows:
			print(row)

	if inside == 0:
		_not_covered("no measurable foreign junction fell inside any cleared box")
	elif bad > 0:
		_fail += 1
		print("    !! %d of %d measured junction/edit pair(s) differ from the full bake by > %.2f m" % [bad, inside, TOL])
	else:
		print("    all %d measured junction/edit pair(s) match the full bake" % inside)
	scene.queue_free()
	_ran += 1


func _heights(p_terrain: Pasture3D, p_juncs: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for j in p_juncs:
		out.append(p_terrain.data.get_height(Vector3(j.center.x, 0.0, j.center.y)))
	return out
