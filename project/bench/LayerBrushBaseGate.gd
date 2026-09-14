# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushBaseGate — phase 3 of PASTURE3D_LAYER_BRUSH_SPEC.md: the Layer's base stage.
#
#   [A] empty stack: the base row holds 0 cells; control: holding every cell holds some
#   [G] extent Whole Terrain == region union, Footprints == outlines ⊕ margin snapped to tiles; the first member
#       flips Whole Terrain to Footprints, a second member / removal / load don't; control: flip on load
#   [H] Footprints profile: no base cell moves beyond outline ⊕ margin, none at a thin diagonal's AABB corner,
#       and the feather falls over several cells; control: AABB profile moves the corner, steps in one cell
#   [I] Whole Terrain: a member height edit re-solves 0 times. Footprints: an outline move re-solves once and the
#       result equals a fresh full bake; control: marking the key fresh first leaves the stale base (differs)
#   [K] the key changes on stack, mode, outline and lower-layer edits, not on a member height edit;
#       control: keyed without the below digest, the lower edit is missed
#   [P] a snapped member's points sit on ground + base; control: the read past the base row differs
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushBaseGate.tscn
extends Node

const CRITERIA := 6
var RS := 64

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== LayerBrushBaseGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	# The terrain may enforce a larger region than asked for; measure over the one it made.
	RS = _terrain.region_size
	for f in [_a, _g, _h, _i, _k, _p]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER BRUSH BASE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
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


## The base row's contribution per cell over the region: (below main) - (below base).
func _base_delta(lb: Pasture3DLayerBrush) -> PackedFloat32Array:
	var above: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.layer_owner_id()), 0.0, 0.0, 1.0, RS, RS)
	var under: PackedFloat32Array = _terrain.data.composite_height_below(_row(lb.base_owner_id()), 0.0, 0.0, 1.0, RS, RS)
	var out := PackedFloat32Array()
	out.resize(RS * RS)
	for i in range(RS * RS):
		out[i] = above[i] - under[i]
	return out


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(RS):
		for x in range(RS):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


func _drop(p_nodes: Array) -> void:
	for n in p_nodes:
		if is_instance_valid(n):
			n.free()


func _a() -> void:
	var lb := _layer("Empty", false)
	var m := _mound(lb, "Kid", _square(32, 32, 8))
	await _settle()
	m._refresh_owner(m._layer_owner, false, [])
	var held := lb.base_cell_count
	var dec := lb.last_base_decision
	lb.hold_every_cell = true
	lb._base_key = ""
	lb.bake_base()
	_check("A empty base", held == 0 and dec == "clear", "held %d (%s)" % [held, dec])
	# With no stack there is nothing to hold even so; the control needs a stack that moves nothing.
	var fn := FastNoiseLite.new()
	var nz := Pasture3DNodeNoise.new()
	nz.noise = fn
	nz.strength = 0.00001
	var mods: Array[Pasture3DNode] = [nz]
	lb.modifiers = mods
	lb.hold_every_cell = false
	lb.bake_base()
	var quiet := lb.base_cell_count
	lb.hold_every_cell = true
	lb._base_key = ""
	lb.bake_base()
	_check("A control", quiet == 0 and lb.base_cell_count > 0, "zero-strength stack holds %d; hold-every-cell holds %d" % [quiet, lb.base_cell_count])
	_drop([lb])
	await _settle()
	_ran += 1


func _g() -> void:
	var lb := _layer("Extent", false)
	await _settle()
	var row := _row(lb.base_owner_id())
	var wt := lb._base_extent(row)
	_check("G whole terrain", wt.position == Vector3.ZERO and wt.size == Vector3(RS, 0, RS), str(wt))
	var m1 := _mound(lb, "One", _square(20, 20, 5))
	await _settle()
	var flipped := lb.extent_mode == Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.modifier_margin = 3.0
	var want := lb._snap_aabb_to_tiles(m1._own_footprints()[0].grow(3.0), lb._layer_tile_world(row))
	var fp := lb._base_extent(row)
	_check("G footprints", flipped and fp.position.x == want.position.x and fp.end.x == want.end.x and fp.end.z == want.end.z,
			"flipped %s, %s vs %s" % [flipped, fp, want])
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	var m2 := _mound(lb, "Two", _square(44, 44, 5))
	await _settle()
	var second := lb.extent_mode
	m1.free()
	m2.free()
	await _settle()
	var removal := lb.extent_mode
	# Load: a member already bound to the Layer when both enter the tree.
	var loaded := Pasture3DLayerBrush.new()
	loaded.name = "Loaded"
	loaded.terrain = _terrain
	var kid := _mound(loaded, "Kid", _square(20, 20, 5))
	kid._layer_owner = loaded.layer_owner_id()
	_terrain.add_child(loaded)
	await _settle()
	var load_mode := loaded.extent_mode
	var ctl := Pasture3DLayerBrush.new()
	ctl.name = "LoadedCtl"
	ctl.terrain = _terrain
	ctl.flip_on_load = true
	var kid2 := _mound(ctl, "Kid", _square(20, 20, 5))
	kid2._layer_owner = ctl.layer_owner_id()
	_terrain.add_child(ctl)
	await _settle()
	var wt_mode := Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	_check("G no flip", second == wt_mode and removal == wt_mode and load_mode == wt_mode,
			"second %d, removal %d, load %d" % [second, removal, load_mode])
	_check("G control", ctl.extent_mode != wt_mode, "flip on load gives mode %d" % ctl.extent_mode)
	_drop([lb, loaded, ctl])
	await _settle()
	_ran += 1


const THIN := [Vector2(12, 14), Vector2(14, 12), Vector2(52, 50), Vector2(50, 52)]


func _dist_outside(p: Vector2) -> float:
	if Geometry2D.is_point_in_polygon(p, PackedVector2Array(THIN)):
		return 0.0
	var best := INF
	for i in range(4):
		var q := Geometry2D.get_closest_point_to_segment(p, THIN[i], THIN[(i + 1) % 4])
		best = minf(best, p.distance_to(q))
	return best


func _h() -> void:
	var lb := _layer("Thin", true)
	var pts: Array = []
	for v in THIN:
		pts.append(Vector3(v.x, 0, v.y))
	var m := _mound(lb, "Diag", pts)
	await _settle()
	lb.modifier_margin = 8.0
	var r := _h_measure(lb)
	_check("H outline", r[0] == 0 and r[1] == 0 and r[3] > 0, "moved beyond margin %d, at AABB corner %d, moved inside %d" % [r[0], r[1], r[3]])
	_check("H feather", r[2] >= 4,"profile falls over %d cells along the edge normal" % r[2])
	lb.profile_from_aabbs = true
	lb._base_key = ""
	var c := _h_measure(lb)
	_check("H control", c[1] > 0 and c[2] < 3, "AABB profile: corner moved %d, falls over %d cells" % [c[1], c[2]])
	_drop([lb])
	await _settle()
	_ran += 1


## [moved beyond margin, moved at the AABB corner, feather cells, moved total]
func _h_measure(lb: Pasture3DLayerBrush) -> Array:
	lb._base_key = ""
	lb.bake_base()
	var d := _base_delta(lb)
	var beyond := 0
	var corner := 0
	var moved := 0
	for z in range(RS):
		for x in range(RS):
			if absf(d[z * RS + x]) < 0.001:
				continue
			moved += 1
			if _dist_outside(Vector2(x, z)) > 8.0 + 1.5:
				beyond += 1
			if Vector2(x, z).distance_to(Vector2(13, 51)) <= 2.0:
				corner += 1
	# Along the normal of the long edge (14,12)->(52,50), outward to +x -z, from its midpoint.
	var inp := lb._base_inputs()
	var prof := lb._base_profile(inp)
	var n := Vector2(1, -1).normalized()
	var mid := Vector2(33, 31)
	var falling := 0
	var prev := 2.0
	for k in range(0, 14):
		var p := mid + n * float(k)
		var ix := roundi(p.x - float(inp["min_x"]))
		var iz := roundi(p.y - float(inp["min_z"]))
		var v := prof[iz * int(inp["gw"]) + ix]
		if v > prev + 1e-6:
			return [beyond, corner, 0, moved]
		if v < prev - 1e-6 and v > 0.0 and v < 1.0:
			falling += 1
		prev = v
	return [beyond, corner, falling, moved]


func _i() -> void:
	var lb := _layer("Rects", true)
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	var m := _mound(lb, "Kid", _square(32, 32, 6))
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	lb.bake_layer()
	var before := _heights()
	var c0 := lb.base_solve_count
	# A member edit that moves its outline (§6.3: in Whole Terrain the base is skipped for it too). The
	# Mound's `height` alone did not move its paint in this fixture, so it would have measured nothing.
	var sp: Path3D = m._get_splines()[0]
	var fp: AABB = m._own_footprints()[0]
	sp.curve.set_point_position(1, sp.curve.get_point_position(1) + Vector3(3, 0, 0))
	fp = fp.merge(m._own_footprints()[0]).grow(1.0)
	m._refresh_owner(m._layer_owner, false, [])
	var after := _heights()
	var outside := 0
	for z in range(RS):
		for x in range(RS):
			if after[z * RS + x] != before[z * RS + x] and not fp.has_point(Vector3(x, fp.position.y + fp.size.y * 0.5, z)):
				outside += 1
	_check("I whole terrain", lb.base_solve_count == c0 and outside == 0 and after != before,
			"re-solves %d, cells changed outside the member %d" % [lb.base_solve_count - c0, outside])

	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	lb.modifier_margin = 4.0
	lb.bake_layer()
	var c1 := lb.base_solve_count
	sp.curve.set_point_position(1, sp.curve.get_point_position(1) + Vector3(6, 0, 0))
	m._refresh_owner_rect(m._layer_owner, {sp.get_instance_id(): true}, false, [], false)
	var edited := _heights()
	var solves := lb.base_solve_count - c1
	lb._base_key = ""
	lb.bake_layer()
	var fresh := _heights()
	_check("I footprints", solves == 1 and edited == fresh, "re-solves %d, equals a fresh full bake %s" % [solves, edited == fresh])
	# Control: the key says fresh, so the rect bake keeps the pre-edit base.
	sp.curve.set_point_position(1, sp.curve.get_point_position(1) - Vector3(6, 0, 0))
	lb._base_key = lb._base_inputs()["key"]
	m._refresh_owner_rect(m._layer_owner, {sp.get_instance_id(): true}, false, [], false)
	var stale := _heights()
	lb._base_key = ""
	lb.bake_layer()
	_check("I control", stale != _heights(), "stage 2 over the pre-edit base differs from a fresh bake")
	_drop([lb])
	await _settle()
	_ran += 1


func _k() -> void:
	var lb := _layer("Keys", true)
	var m := _mound(lb, "Kid", _square(32, 32, 6))
	await _settle()
	lb.modifier_margin = 4.0
	lb.bake_layer()
	var k0: String = lb._base_inputs()["key"]
	var fails := PackedStringArray()
	m.height = 9.0
	if lb._base_inputs()["key"] != k0:
		fails.append("member height changed it")
	lb.modifiers[0].strength = 5.0
	if lb._base_inputs()["key"] == k0:
		fails.append("stack")
	lb.modifiers[0].strength = 4.0
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	if lb._base_inputs()["key"] == k0:
		fails.append("mode")
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	var sp: Path3D = m._get_splines()[0]
	sp.curve.set_point_position(0, sp.curve.get_point_position(0) + Vector3(-2, 0, 0))
	if lb._base_inputs()["key"] == k0:
		fails.append("outline")
	sp.curve.set_point_position(0, sp.curve.get_point_position(0) + Vector3(2, 0, 0))
	var back: String = lb._base_inputs()["key"]
	# A lower edit: a plain row moved beneath the pair, written through stamp_grid.
	var d: Pasture3DData = _terrain.data
	var low := d.create_owned_layer_typed("gate:lower", "Lower", 0, Pasture3DTerrainBrush.PASTURE_3D_MAPTYPE_HEIGHT)
	# Directly beneath the base row: rows earlier criteria left behind would otherwise REPLACE over the edit.
	d.layer_move(low, _row(lb.base_owner_id()))
	low = _row("gate:lower")
	var patch := PackedFloat32Array()
	patch.resize(16)
	patch.fill(6.0)
	d.stamp_grid(low, patch, 30.0, 30.0, 1.0, 4, 4, 0)
	print("    probe: lower row %d, base row %d, below-base at (31,31) %.3f, layer cells %s" % [low,
			_row(lb.base_owner_id()), d.get_height_below(_row(lb.base_owner_id()), Vector3(31, 0, 31)),
			d.get_layer_stack().get_layer(low).get_region_locations()])
	var lower: String = lb._base_inputs()["key"]
	if lower == back:
		fails.append("lower-layer edit")
	_check("K key", fails.is_empty() and back == k0, "missed: %s; restored key matches %s" % [", ".join(fails), back == k0])
	lb.key_without_below = true
	var no_below_a: String = lb._base_inputs()["key"]
	patch.fill(2.0)
	d.stamp_grid(low, patch, 30.0, 30.0, 1.0, 4, 4, 0)
	var no_below_b: String = lb._base_inputs()["key"]
	_check("K control", no_below_a == no_below_b, "without the below digest the lower edit is missed: %s" % (no_below_a == no_below_b))
	_drop([lb])
	await _settle()
	_ran += 1


func _p() -> void:
	var lb := _layer("Reads", true)
	var m := _mound(lb, "Snap", _square(32, 32, 10))
	m.snap_to_surface = true
	m.surface_offset = 0.0
	await _settle()
	lb.extent_mode = Pasture3DLayerBrush.ExtentMode.WHOLE_TERRAIN
	lb.bake_layer()
	var sp: Path3D = m._get_splines()[0]
	var main_row := _row(lb.layer_owner_id())
	var base_row := _row(lb.base_owner_id())
	var worst := 0.0
	var ctl := 0.0
	for i in range(sp.curve.point_count):
		var w := sp.global_transform * sp.curve.get_point_position(i)
		worst = maxf(worst, absf(w.y - _terrain.data.get_height_below(main_row, w)))
		ctl = maxf(ctl, absf(w.y - _terrain.data.get_height_below(base_row, w)))
	_check("P snap on base", worst < 0.01, "worst point vs ground + base %.4f m (held %d cells)" % [worst, lb.base_cell_count])
	_check("P control", ctl > 0.05, "the read past the base row is off by %.4f m" % ctl)
	_drop([lb])
	await _settle()
	_ran += 1
