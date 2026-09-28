# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadOffTerrainGate — a road whose plan leaves the loaded regions still solves, sizes and paints (2026-09-27).
#
# The symptom (RoadMoundInteractionGate): every rebake box on a road point add, remove or move was NaN. The
# road overhung the regions, so `get_height_below_along_plan` sampled NaN ground there; the solver's cut/fill
# balance shifts the WHOLE profile by a mean over every sample, so every `z` went NaN, and through
# `deepest_structure` -> `corridor_half_width` -> `_padding` so did every box and the footprint itself. The
# road painted nothing anywhere. The fix fills the ground's gaps before the solve (`_fill_ground_gaps`).
#
# The fixture overhangs on BOTH ends and has an INTERIOR gap: regions at x 0..512 (ground 20 m) and x
# 768..1024 (ground 30 m) with nothing between, and the road runs x -150..1150 along z 128.
#
#   [W] witness: the raw ground under the plan has NaN at both ends and in the interior gap. Without it every
#       other criterion could pass on a road that never left the terrain
#   [F] `_fill_ground_gaps`: interior gap linear by index, ends hold the nearest sample, all-NaN reads 0.0,
#       a gap-free array comes back unchanged. Control: the raw input is not finite
#   [N] native route (`stamp_road_line`), full bake: every `z` finite, `_padding` and the footprint finite, a
#       one-point move's dirty box finite, and the carriageway painted (cross-slope witness) on both regions.
#       Control: `ground_gaps_unfilled` gives NaN z and no paint (its boxes stay finite: `deepest_structure`
#       skips non-finite offsets, the second guard)
#   [G] the same on the GDScript route (`force_gdscript_raster`, via `grade_surface`), same control. That
#       route used to read 0.0 for no-data ground rather than NaN, which is a different wrong answer
#   [P] the profile sits on the ground it has: `z` within 0.5 m of 20 m and of 30 m in the middle of each
#       region. Control: the same plan solved with the gaps read as 0.0 (the GDScript route's old answer)
#       drags the profile off at least one of them
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadOffTerrainGate.tscn
extends Node

const CRITERIA := 5
const RS := 256
const Z_ROAD := 128.0
const X0 := -150.0
const X1 := 1150.0
const H_WEST := 20.0
const H_EAST := 30.0
const ON_M := 0.5
# The ground rises across the road, so a carriageway cell PROBE_OFF metres off the centreline sits well below
# the untouched ground there: that difference is the witness that the road painted, since along the
# centreline itself the road and the ground agree.
const CROSS_SLOPE := 0.2
const PROBE_OFF := 3.0
const PAINTED_BELOW_M := 0.3

var _fail := 0
var _ran := 0
var _terrain: Pasture3D
var _net: Pasture3DRoadNetwork


func _ready() -> void:
	print("=== RoadOffTerrainGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	await _settle()
	_terrain.change_region_size(RS)
	var d := _terrain.data
	for loc in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(3, 0)]:
		d.add_region_blank(loc, false)
		var r = d.get_region(loc)
		var img: Image = r.get_height_map()
		var h := H_WEST if loc.x < 2 else H_EAST
		for row in RS:
			img.fill_rect(Rect2i(0, row, RS, 1), Color(h + CROSS_SLOPE * (float(row) - Z_ROAD), 0, 0, 1))
		r.set_modified(true)
		r.calc_height_range()
	d.update_maps()
	d.calc_height_range(true)
	d.ensure_layer_stack()
	_net = Pasture3DRoadNetwork.new()
	_net.name = "RoadNetwork"
	_terrain.add_child(_net)

	for f in [_w, _f, _n, _g, _p]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== ROAD OFF TERRAIN %s (%d failures, %d/%d criteria completed) ===" % [
			"PASS" if _fail == 0 and _ran == CRITERIA else "FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(1 if _fail > 0 or _ran != CRITERIA else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _road(p_name: String) -> Pasture3DRoadBrush:
	var t := Pasture3DRoadType.new()
	t.lane_width = 3.5
	t.shoulder_width = 1.0
	t.max_grade = 0.08
	var road := Pasture3DRoadBrush.new()
	road.name = p_name
	road.terrain = _terrain
	road.road_road_type = t
	road.log_bake_timing = false
	_net.add_child(road)
	var path := Path3D.new()
	path.name = "Spline"
	var c := Curve3D.new()
	for i in 11:
		c.add_point(Vector3(lerpf(X0, X1, float(i) / 10.0), 0.0, Z_ROAD))
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	return road


func _free_road(p_road: Pasture3DRoadBrush) -> void:
	_terrain.data.clear_layer_in_area(p_road._layer_id, AABB(Vector3(-2000, -1000, -2000), Vector3(4000, 2000, 4000)))
	p_road.get_parent().remove_child(p_road)
	p_road.free()


func _path(p_road: Pasture3DRoadBrush) -> Path3D:
	return p_road.get_node("Spline") as Path3D


func _aabb_finite(p_box: AABB) -> bool:
	return p_box.position.is_finite() and p_box.size.is_finite()


func _nan_count(p_a: PackedFloat32Array) -> int:
	var k := 0
	for v in p_a:
		if not is_finite(v):
			k += 1
	return k


## Everything [N]/[G] read off one baked road: the profile, the sizes, a move's box, and the paint.
func _bake_and_read(p_gdscript: bool, p_unfilled: bool) -> Dictionary:
	var road := _road("Road")
	road.force_gdscript_raster = p_gdscript
	road.ground_gaps_unfilled = p_unfilled
	await _settle()
	road._refresh_owner(road._layer_owner, false, [])
	var out := {}
	var al: Pasture3DRoadAlignment = road.road_modifier().last_alignment
	out["z_nan"] = _nan_count(al.z) if al != null else -1
	out["z_n"] = al.z.size() if al != null else 0
	out["pad"] = road._padding()
	var fp: AABB = road._spline_footprint_aabb(_path(road))
	out["fp"] = _aabb_finite(fp)
	var c := _path(road).curve
	c.set_point_position(3, c.get_point_position(3) + Vector3(0, 0, 6))
	out["box"] = _aabb_finite(road._spline_dirty_aabb(_path(road), PackedInt32Array([3])))
	# Painted: a carriageway cell off the centreline reads below the cross-sloped ground it replaced, on each
	# loaded stretch (clear of the region edges).
	var painted := 0
	var probes := 0
	for x in range(16, 1016, 8):
		if x > 496 and x < 784:
			continue
		probes += 1
		var ground := (H_WEST if x < 512 else H_EAST) + CROSS_SLOPE * PROBE_OFF
		var h := _terrain.data.get_height(Vector3(x, 0, Z_ROAD + PROBE_OFF))
		if is_finite(h) and h < ground - PAINTED_BELOW_M:
			painted += 1
	out["painted"] = painted
	out["probes"] = probes
	if al != null:
		out["z_west"] = al.height_at(256.0 - X0)
		out["z_east"] = al.height_at(896.0 - X0)
	_free_road(road)
	return out


func _route_ok(p_r: Dictionary) -> bool:
	return p_r["z_n"] > 0 and p_r["z_nan"] == 0 and is_finite(p_r["pad"]) and p_r["fp"] and p_r["box"] \
			and p_r["painted"] == p_r["probes"]


## The boxes are NOT part of the control: `deepest_structure` now skips non-finite offsets, so a NaN profile
## no longer reaches `_padding`. That guard is why the control arm's boxes read finite.
func _route_broken(p_r: Dictionary) -> bool:
	return p_r["z_nan"] > 0 and p_r["painted"] == 0


func _describe(p_r: Dictionary) -> String:
	return "z NaN %d/%d, pad %.2f, footprint finite %s, move box finite %s, painted %d/%d" % [
			p_r["z_nan"], p_r["z_n"], p_r["pad"], p_r["fp"], p_r["box"], p_r["painted"], p_r["probes"]]


func _raw_ground() -> PackedFloat32Array:
	var road := _road("Probe")
	await _settle()
	road._refresh_owner(road._layer_owner, false, [])
	var plan: PackedVector2Array = road._plan_points()
	var cum: PackedFloat32Array = road._plan_cum()
	var n_s := int(ceil(float(cum[cum.size() - 1]))) + 1
	var g: PackedFloat32Array = _terrain.data.get_height_below_along_plan(road._layer_id, plan, cum, 1.0, n_s)
	_free_road(road)
	return g


func _w() -> void:
	var g := await _raw_ground()
	var west := not is_finite(g[0])
	var east := not is_finite(g[g.size() - 1])
	var mid := not is_finite(g[int(640.0 - X0)])
	var on := is_finite(g[int(256.0 - X0)]) and is_finite(g[int(896.0 - X0)])
	_check("[W] plan leaves the terrain", west and east and mid and on,
			"NaN at start %s, end %s, interior gap %s; ground on both regions %s (%d of %d samples NaN)"
			% [west, east, mid, on, _nan_count(g), g.size()])
	_ran += 1


func _f() -> void:
	var src := PackedFloat32Array([NAN, NAN, 10.0, NAN, NAN, NAN, 18.0, NAN])
	var got := Pasture3DRoadBrush._fill_ground_gaps(src)
	var want := PackedFloat32Array([10.0, 10.0, 10.0, 12.0, 14.0, 16.0, 18.0, 18.0])
	var err := 0.0
	for i in want.size():
		err = maxf(err, absf(got[i] - want[i])) if is_finite(got[i]) else INF
	var all_nan := Pasture3DRoadBrush._fill_ground_gaps(PackedFloat32Array([NAN, NAN, NAN]))
	var zeros := all_nan == PackedFloat32Array([0.0, 0.0, 0.0])
	var clean := PackedFloat32Array([1.0, 2.5, -3.0])
	var same := Pasture3DRoadBrush._fill_ground_gaps(clean) == clean
	var control := _nan_count(src) > 0
	_check("[F] fill ground gaps", err < 1e-5 and zeros and same and control,
			"worst error %.6f, all-NaN -> zeros %s, gap-free unchanged %s; control: input has NaN %s"
			% [err, zeros, same, control])
	_ran += 1


func _route(p_label: String, p_gdscript: bool) -> void:
	var r := await _bake_and_read(p_gdscript, false)
	var c := await _bake_and_read(p_gdscript, true)
	_check(p_label, _route_ok(r) and _route_broken(c), "%s | control (unfilled): %s" % [_describe(r), _describe(c)])
	_ran += 1


func _n() -> void:
	await _route("[N] native route", false)


func _g() -> void:
	await _route("[G] GDScript route", true)


func _p() -> void:
	var r := await _bake_and_read(false, false)
	var dw := absf(float(r.get("z_west", NAN)) - H_WEST)
	var de := absf(float(r.get("z_east", NAN)) - H_EAST)
	# Control: the old GDScript-route answer for no-data ground, 0.0, solved over the same plan.
	var g := await _raw_ground()
	var zeroed := g.duplicate()
	for i in zeroed.size():
		if not is_finite(zeroed[i]):
			zeroed[i] = 0.0
	var road := _road("Control")
	await _settle()
	var plan: PackedVector2Array = road._plan_points()
	var cum: PackedFloat32Array = road._plan_cum()
	var pts: PackedVector2Array = road._resample_plan(plan, cum, 1.0, g.size())
	_free_road(road)
	var al := Pasture3DRoadAlignmentSolver.solve_with_plan(pts, zeroed, 1.0, 0.08, 16.67, 0.06, {})
	var cw := absf(al.height_at(256.0 - X0) - H_WEST)
	var ce := absf(al.height_at(896.0 - X0) - H_EAST)
	_check("[P] profile on its ground", dw < ON_M and de < ON_M and maxf(cw, ce) > ON_M,
			"|z - ground| west %.3f, east %.3f (< %.1f) | control (gaps read 0.0): west %.3f, east %.3f"
			% [dw, de, ON_M, cw, ce])
	_ran += 1
