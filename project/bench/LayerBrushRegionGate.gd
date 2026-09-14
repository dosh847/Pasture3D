# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushRegionGate — phase 3b of PASTURE3D_LAYER_BRUSH_SPEC.md: Whole Region mode.
#
#   [M] 2 of 4 regions selected: the base moves only within selection ⊕ margin; across the edge shared with an
#       unselected region the feather is monotone and 0 at the margin; a reordered selection keys the same; the
#       first member does not flip Whole Region. Controls: key on the unsorted list; flip from any mode
#   [N] a member outside selection ⊕ margin (but inside the tile-snapped extent) bakes bitwise equal to the same
#       member under an empty stack. Control: profile 1 over the whole extent grid
#   [O] removing a selected region drops it and re-solves the base; re-adding it (the REGION tool's undo)
#       re-selects it; painting the selection never changes region_locations. Control: no dropped restore
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushRegionGate.tscn
extends Node

const CRITERIA := 3

var _fail := 0
var _ran := 0
var _terrain: Pasture3D
var RS := 256


func _ready() -> void:
	print("=== LayerBrushRegionGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = 256
	add_child(_terrain)
	RS = _terrain.region_size
	for loc in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		_terrain.data.add_region_blank(loc, true)
	_terrain.data.ensure_layer_stack()
	for f in [_m, _n, _o]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER BRUSH REGION %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _noise() -> Array[Pasture3DNode]:
	var fn := FastNoiseLite.new()
	fn.seed = 3
	fn.frequency = 0.05
	var nz := Pasture3DNodeNoise.new()
	nz.noise = fn
	nz.strength = 4.0
	var mods: Array[Pasture3DNode] = [nz]
	return mods


func _layer(p_name: String, p_sel: Array[Vector2i], p_margin: float) -> Pasture3DLayerBrush:
	var lb := Pasture3DLayerBrush.new()
	lb.name = p_name
	lb.terrain = _terrain
	lb.auto_refresh = false
	lb.modifiers = _noise()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_REGION
	lb.modifier_margin = p_margin
	lb.selected_regions = p_sel
	_terrain.add_child(lb)
	return lb


func _mound(p_parent: Node, p_name: String, cx: float, cz: float, h: float) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in [Vector3(cx - h, 0, cz - h), Vector3(cx + h, 0, cz - h), Vector3(cx + h, 0, cz + h), Vector3(cx - h, 0, cz + h)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	p_parent.add_child(m)
	return m


func _row(p_owner: String) -> int:
	return _terrain.data.get_layer_stack().find_layer_by_owner(p_owner)


func _dist_to_selection(p: Vector2, p_sel: Array) -> float:
	var d := INF
	for loc: Vector2i in p_sel:
		var dx := maxf(maxf(loc.x * RS - p.x, p.x - (loc.x * RS + RS - 1)), 0.0)
		var dz := maxf(maxf(loc.y * RS - p.y, p.y - (loc.y * RS + RS - 1)), 0.0)
		d = minf(d, sqrt(dx * dx + dz * dz))
	return d


func _m() -> void:
	var margin := 16.0
	var sel: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 0)]
	var lb := _layer("Regions", sel, margin)
	await _settle()
	lb.bake_base()
	var w := RS * 2
	var above: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.layer_owner_id()), 0.0, 0.0, 1.0, w, w)
	var under: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.base_owner_id()), 0.0, 0.0, 1.0, w, w)
	var beyond := 0
	var moved := 0
	for z in range(w):
		for x in range(w):
			var i := z * w + x
			if is_nan(above[i]) or absf(above[i] - under[i]) < 0.001:
				continue
			moved += 1
			if _dist_to_selection(Vector2(x, z), lb.selected_regions) > margin + 1.0:
				beyond += 1
	_check("M extent", moved > 0 and beyond == 0 and lb.last_base_decision == "solve", "moved %d, beyond selection ⊕ margin %d" % [moved, beyond])

	# Across the (0,0) | (0,1) edge at z = RS, which is unselected on the far side.
	var inp := lb._base_inputs()
	var prof := lb._base_profile(inp)
	var monotone := true
	var zero_at := true
	var inside_band := false
	var prev := 2.0
	for z in range(RS - 4, RS + int(margin) + 6):
		var v := prof[(z - int(inp["min_z"])) * int(inp["gw"]) + (128 - int(inp["min_x"]))]
		monotone = monotone and v <= prev + 1e-9
		prev = v
		var d := float(z - (RS - 1))
		if d >= margin:
			zero_at = zero_at and v == 0.0
		elif d > 0.0 and v > 0.0 and v < 1.0:
			inside_band = true
	_check("M feather", monotone and zero_at and inside_band, "monotone %s, 0 at the margin %s, feathered %s" % [monotone, zero_at, inside_band])

	var k1: String = inp["key"]
	var fwd: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	lb.selected_regions = fwd
	var k2: String = lb._base_inputs()["key"]
	lb.key_unsorted_selection = true
	var rev: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 0)]
	lb.selected_regions = rev
	# The setter returns early on an unchanged sorted list, so record the raw order the way it would.
	lb._selection_raw = rev
	var c1: String = lb._base_inputs()["key"]
	lb._selection_raw = fwd
	var c2: String = lb._base_inputs()["key"]
	_check("M reorder key", k1 == k2, "reordered selection keys the same: %s" % (k1 == k2))
	_check("M reorder control", c1 != c2, "keyed on the unsorted list, the order changes the key: %s" % (c1 != c2))

	var kid := _mound(lb, "Kid", 100, 100, 10)
	await _settle()
	var mode_after := lb.extent_mode
	var ctl := _layer("RegionsCtl", sel, margin)
	ctl.flip_any_mode = true
	await _settle()
	var kid2 := _mound(ctl, "Kid", 100, 100, 10)
	await _settle()
	_check("M no flip", mode_after == Pasture3DLayerBrush.ExtentMode.WHOLE_REGION, "mode after first member %d" % mode_after)
	_check("M flip control", ctl.extent_mode != Pasture3DLayerBrush.ExtentMode.WHOLE_REGION, "flip from any mode gives %d" % ctl.extent_mode)
	lb.free()
	ctl.free()
	await _settle()
	_ran += 1


## Heights over a box, as one array.
func _heights(x0: int, z0: int, x1: int, z1: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(z0, z1):
		for x in range(x0, x1):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


func _n() -> void:
	var sel: Array[Vector2i] = [Vector2i(0, 0)]
	var margin := 8.0
	var lb := _layer("Outside", sel, margin)
	# Selection [0,256) ⊕ 8 snaps to a 64 m tile at 320: a member at x 290..310 is outside the margin, inside the grid.
	var m := _mound(lb, "Far", 300, 100, 10)
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_REGION
	var row := _row(lb.base_owner_id())
	var ext := lb._base_extent(row)
	m._refresh_owner(m._layer_owner, false, [])
	var with_stack := _heights(284, 84, 316, 116)
	var held := lb.base_cell_count
	lb.profile_full_extent = true
	lb._base_key = ""
	m._refresh_owner(m._layer_owner, false, [])
	var full_profile := _heights(284, 84, 316, 116)
	lb.profile_full_extent = false
	var empty: Array[Pasture3DNode] = []
	lb.modifiers = empty
	lb._base_key = ""
	m._refresh_owner(m._layer_owner, false, [])
	var no_stack := _heights(284, 84, 316, 116)
	_check("N outside member", ext.end.x > 310.0 and held > 0 and with_stack == no_stack,
			"extent ends at %.0f, base held %d, bitwise equal to the empty stack %s" % [ext.end.x, held, with_stack == no_stack])
	_check("N control", full_profile != no_stack, "profile 1 over the extent grid changes the member: %s" % (full_profile != no_stack))
	lb.free()
	await _settle()
	_ran += 1


func _o() -> void:
	var sel: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1)]
	var lb := _layer("Lifecycle", sel, 8.0)
	await _settle()
	lb.bake_base()
	var solves := lb.base_solve_count
	var d: Pasture3DData = _terrain.data
	var regions_before := d.region_locations.size()
	var painted := lb.painted_selection([Vector2i(1, 0)], true)
	lb.selected_regions = painted
	var unpainted := lb.painted_selection([Vector2i(1, 0)], false)
	lb.selected_regions = unpainted
	var tool_regions_ok := d.region_locations.size() == regions_before and lb.selected_regions == sel

	d.remove_regionl(Vector2i(1, 1), true)
	var dropped := not lb.selected_regions.has(Vector2i(1, 1)) and lb._dropped_regions.has(Vector2i(1, 1))
	lb.bake_base()
	var resolved := lb.base_solve_count == solves + 1
	d.add_region_blank(Vector2i(1, 1), true)
	var reselected := lb.selected_regions.has(Vector2i(1, 1)) and lb._dropped_regions.is_empty()
	_check("O lifecycle", dropped and resolved and reselected and tool_regions_ok,
			"dropped %s, re-solved %s, re-selected %s, painting leaves %d regions %s" % [dropped, resolved, reselected, regions_before, tool_regions_ok])

	lb.no_dropped_restore = true
	d.remove_regionl(Vector2i(1, 1), true)
	d.add_region_blank(Vector2i(1, 1), true)
	_check("O control", not lb.selected_regions.has(Vector2i(1, 1)), "without the restore the region stays unselected: %s" % (not lb.selected_regions.has(Vector2i(1, 1))))
	lb.free()
	await _settle()
	_ran += 1
