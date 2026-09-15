# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushFixesGate — the Layer brush review fixes (2026-09-15).
#
#   [D] a member deleted from under a Layer (removed, kept for undo, not freed) lifts its height and leaves the
#       other member alone; undo puts the bake back exactly; control: with delete detection off the height stays
#   [F] Children Footprints: the base solved over a deleted member's footprint goes, the base over the member
#       that stays does not change; control: detection off leaves the base over the deleted footprint
#   [C] rebuild_layer (the dock's Clear on a pair) wipes stray cells from BOTH rows and equals the clean bake;
#       control: a plain bake_layer keeps them
#   [R] a rect bake whose base moved re-seats a snapped mate on the ground below the Layer even when the mate's
#       `_layer_id` is stale, with a layer above adding 5 m; control: `reseat_keeps_layer_id` climbs onto it
#   [U] a duplicated Layer arrives with the original's uid, claims its own, makes its own pair and adopts its
#       copied member; the original keeps its rows and member (the dock's Duplicate relies on all of it)
#
# Not covered: the Layers dock's button handlers, which need EditorInterface and so a windowed editor run.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushFixesGate.tscn
extends Node

const CRITERIA := 5
var RS := 64

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== LayerBrushFixesGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	RS = _terrain.region_size
	for f in [_d, _f, _c, _r, _u]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER BRUSH FIXES %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	for i in range(3):
		await get_tree().process_frame


func _layer(p_name: String, p_noise: bool) -> Pasture3DLayerBrush:
	var lb := Pasture3DLayerBrush.new()
	lb.name = p_name
	lb.terrain = _terrain
	lb.auto_refresh = false
	if p_noise:
		var fn := FastNoiseLite.new()
		fn.seed = 7
		fn.frequency = 0.08
		var nz := Pasture3DNodeNoise.new()
		nz.noise = fn
		nz.strength = 4.0
		var mods: Array[Pasture3DNode] = [nz]
		lb.modifiers = mods
	_terrain.add_child(lb)
	return lb


func _mound(p_parent: Node, p_name: String, p_pts: Array) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	m.height = 3.0
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in p_pts:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	p_parent.add_child(m)
	return m


func _square(cx: float, cz: float, h: float) -> Array:
	return [Vector3(cx - h, 0, cz - h), Vector3(cx + h, 0, cz - h), Vector3(cx + h, 0, cz + h), Vector3(cx - h, 0, cz + h)]


func _row(p_owner: String) -> int:
	return _terrain.data.get_layer_stack().find_layer_by_owner(p_owner)


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(RS):
		for x in range(RS):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


## The base row's contribution per cell: (below main) - (below base).
func _base_delta(lb: Pasture3DLayerBrush) -> PackedFloat32Array:
	var above: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.layer_owner_id()), 0.0, 0.0, 1.0, RS, RS)
	var under: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.base_owner_id()), 0.0, 0.0, 1.0, RS, RS)
	var out := PackedFloat32Array()
	out.resize(RS * RS)
	for i in range(RS * RS):
		out[i] = above[i] - under[i]
	return out


## Cells in the XZ box [x0, x1) x [z0, x1) where `p_grid` is at least `p_eps` from zero.
func _nonzero_in(p_grid: PackedFloat32Array, p_box: Rect2i, p_eps: float = 0.001) -> int:
	var n := 0
	for z in range(p_box.position.y, p_box.end.y):
		for x in range(p_box.position.x, p_box.end.x):
			if absf(p_grid[z * RS + x]) >= p_eps:
				n += 1
	return n


func _same_in(p_a: PackedFloat32Array, p_b: PackedFloat32Array, p_box: Rect2i) -> bool:
	for z in range(p_box.position.y, p_box.end.y):
		for x in range(p_box.position.x, p_box.end.x):
			if p_a[z * RS + x] != p_b[z * RS + x]:
				return false
	return true


func _drop(p_nodes: Array) -> void:
	for n in p_nodes:
		if is_instance_valid(n):
			n.free()


const BOX_A := Rect2i(8, 8, 17, 17)    # Mound A at (16, 16) half 6, plus 2 cells
const BOX_B := Rect2i(40, 40, 17, 17)  # Mound B at (48, 48) half 6, plus 2 cells


func _d() -> void:
	var lb := _layer("Del", false)
	var a := _mound(lb, "A", _square(16, 16, 6))
	var b := _mound(lb, "B", _square(48, 48, 6))
	await _settle()
	lb.detect_delete_headless = true
	lb.bake_layer()
	var baked := _heights()
	var a_before := _nonzero_in(baked, BOX_A)
	lb.remove_child(a)
	await _settle()
	var gone := _heights()
	var a_after := _nonzero_in(gone, BOX_A)
	var b_kept := _same_in(baked, gone, BOX_B)
	_check("D delete lifts", a_before > 0 and a_after == 0 and b_kept,
			"A cells %d -> %d, B unchanged %s" % [a_before, a_after, b_kept])
	lb.add_child(a)
	await _settle()
	_check("D undo", _heights() == baked, "re-adding A restores the bake exactly: %s" % (_heights() == baked))
	lb.detect_delete_headless = false
	lb.remove_child(a)
	await _settle()
	var ctl := _nonzero_in(_heights(), BOX_A)
	_check("D control", ctl > 0, "with delete detection off, A leaves %d cells" % ctl)
	_drop([lb, a])
	await _settle()
	_ran += 1


func _f() -> void:
	var lb := _layer("DelBase", true)
	var a := _mound(lb, "A", _square(16, 16, 6))
	var b := _mound(lb, "B", _square(48, 48, 6))
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.modifier_margin = 2.0
	lb.detect_delete_headless = true
	lb._base_key = ""
	lb.bake_layer()
	var before := _base_delta(lb)
	var a_before := _nonzero_in(before, BOX_A)
	lb.remove_child(a)
	await _settle()
	var after := _base_delta(lb)
	var a_after := _nonzero_in(after, BOX_A)
	var b_kept := _same_in(before, after, BOX_B)
	_check("F base follows", a_before > 0 and a_after == 0 and b_kept,
			"base cells over A %d -> %d, base over B unchanged %s" % [a_before, a_after, b_kept])
	lb.add_child(a)
	await _settle()
	lb.detect_delete_headless = false
	lb.remove_child(a)
	await _settle()
	var ctl := _nonzero_in(_base_delta(lb), BOX_A)
	_check("F control", ctl > 0, "with delete detection off, the base keeps %d cells over A" % ctl)
	_drop([lb, a])
	await _settle()
	_ran += 1


func _c() -> void:
	var lb := _layer("Clear", true)
	var m := _mound(lb, "Kid", _square(32, 32, 4))
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.modifier_margin = 2.0
	lb._base_key = ""
	lb.bake_layer()
	var clean := _heights()
	var d: Pasture3DData = _terrain.data
	var patch := PackedFloat32Array()
	patch.resize(16)
	patch.fill(7.0)
	# Stray cells on both rows, away from the member: the orphaned footprint the dock's Clear exists to drop.
	d.stamp_grid(_row(lb.layer_owner_id()), patch, 2.0, 2.0, 1.0, 4, 4, 0)
	d.stamp_grid(_row(lb.base_owner_id()), patch, 58.0, 2.0, 1.0, 4, 4, 0)
	d.composite_region(Vector2i.ZERO, Rect2i(), false)
	var dirty := _heights()
	var stray := dirty[3 * RS + 3] != clean[3 * RS + 3] and dirty[3 * RS + 59] != clean[3 * RS + 59]
	lb.bake_layer()
	var plain := _heights()
	_check("C control", stray and plain != clean, "stray cells on both rows %s; a plain bake keeps them %s" % [stray, plain != clean])
	lb.rebuild_layer()
	var rebuilt := _heights()
	_check("C rebuild", rebuilt == clean, "rebuild equals the clean bake %s (main stray %.2f, base stray %.2f)" % [
			rebuilt == clean, rebuilt[3 * RS + 3], rebuilt[3 * RS + 59]])
	_drop([lb])
	await _settle()
	_ran += 1


func _r() -> void:
	var lb := _layer("Reseat", true)
	var m := _mound(lb, "Mover", _square(18, 18, 5))
	var s := _mound(lb, "Snapped", _square(44, 44, 6))
	s.snap_to_surface = true
	s.surface_offset = 0.0
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.modifier_margin = 4.0
	# A layer ABOVE the pair adding 5 m: what a mate reading the full composite climbs onto.
	var d: Pasture3DData = _terrain.data
	var above := d.create_owned_layer_typed("gate:above", "Above", 1, Pasture3DTerrainBrush.PASTURE_3D_MAPTYPE_HEIGHT)
	var main_row := _row(lb.layer_owner_id())
	if above < main_row:
		d.layer_move(above, d.get_layer_stack().get_layer_count() - 1)
	above = _row("gate:above")
	var patch := PackedFloat32Array()
	patch.resize(RS * RS)
	patch.fill(5.0)
	d.stamp_grid(above, patch, 0.0, 0.0, 1.0, RS, RS, 0)
	lb._base_key = ""
	lb.bake_layer()
	var nz := lb.modifiers[0] as Pasture3DNodeNoise
	var sp: Path3D = m._get_splines()[0]
	var results := []
	for keep in [false, true]:
		m.reseat_keeps_layer_id = keep
		s._layer_id = -1 # a mate that has not baked this session
		nz.noise.seed += 1
		lb._base_key = ""
		sp.curve.set_point_position(1, sp.curve.get_point_position(1) + Vector3(1, 0, 0))
		m._refresh_owner_rect(m._layer_owner, {sp.get_instance_id(): true}, false, [], false)
		var reached := false
		for c: AABB in m._last_rect_clips:
			for fp: AABB in s._own_footprints():
				if c.position.x < fp.end.x and fp.position.x < c.end.x and c.position.z < fp.end.z and fp.position.z < c.end.z:
					reached = true
		main_row = _row(lb.layer_owner_id())
		var ssp: Path3D = s._get_splines()[0]
		var worst := 0.0
		for i in range(ssp.curve.point_count):
			var w := ssp.global_transform * ssp.curve.get_point_position(i)
			worst = maxf(worst, absf(w.y - d.get_height_below(main_row, w)))
		results.append([reached, worst, m._last_rect_decision])
	m.reseat_keeps_layer_id = false
	_check("R re-seat", results[0][2] == "rect" and results[0][0] and results[0][1] < 0.01,
			"decision %s, mate inside the rect %s, worst point off the ground below the Layer %.4f m" % [results[0][2], results[0][0], results[0][1]])
	_check("R control", results[1][0] and results[1][1] > 1.0,
			"stale _layer_id: mate inside the rect %s, climbs %.4f m" % [results[1][0], results[1][1]])
	d.layer_remove(_row("gate:above"))
	_drop([lb])
	await _settle()
	_ran += 1


func _u() -> void:
	var lb := _layer("Orig", false)
	var kid := _mound(lb, "Kid", _square(32, 32, 6))
	await _settle()
	lb.bake_layer()
	var dup := lb.duplicate() as Pasture3DLayerBrush
	var carried := dup._layer_uid == lb._layer_uid
	_terrain.add_child(dup, true)
	await _settle()
	var dkid: Node = null
	for c in dup.get_children():
		if c is Pasture3DMound:
			dkid = c
	var own_uid := dup._layer_uid != lb._layer_uid
	var own_rows := _row(dup.layer_owner_id()) >= 0 and _row(dup.base_owner_id()) >= 0
	var orig_rows := _row(lb.layer_owner_id()) >= 0 and _row(lb.base_owner_id()) >= 0
	var adopted: bool = dkid != null and dkid._layer_owner == dup.layer_owner_id()
	var orig_kept := kid._layer_owner == lb.layer_owner_id()
	_check("U duplicate", own_uid and own_rows and orig_rows and adopted and orig_kept,
			"own uid %s, own pair %s, original pair %s, copied member adopted %s, original member kept %s" % [
			own_uid, own_rows, orig_rows, adopted, orig_kept])
	_check("U control", carried, "the copy arrives carrying the original's uid: %s" % carried)
	_drop([lb, dup])
	await _settle()
	_ran += 1
