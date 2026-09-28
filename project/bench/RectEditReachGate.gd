# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RectEditReachGate — a point drag's dirty-rect bake must land where a full bake would (2026-09-27).
#
# The symptom (demo_massive_world): a Mound with no modifiers showed flat facets and steps in tile-aligned
# blocks along its ridge. A point drag rect-bakes the box of the moved span, padded by how far the paint
# reaches OUTWARD. An SDF brush also reaches INWARD: each cell reads its distance to the nearest edge, so a
# moved edge changes ground up to the ridge, and the rect bake left it at the previous shape.
#
# Every arm: full bake, move one point, rect bake (`_refresh_owner_rect`, the auto-refresh path of a drag),
# read the heights, then full bake the same curve and read them again. The full bake is the definition of
# the right answer, so the reading is the worst |rect - full| over the whole loop's window.
#
#   [C] uncapped SLOPE_ANGLE Mound (the default cone): agree. Control: `rect_ignores_edit_reach` disagrees
#   [D] uncapped FIXED_WIDTH Mound (dome normalised on the widest interior distance): same, same control
#   [R] CAPPED Mound, linear falloff 60 m (> the 2 m pad), on its own rectangle: agree. Control as above.
#       Witness: the clip leaves part of the footprint out, so the finite reach kept the rect win rather than
#       going whole; [C] reads the same witness enclosing the footprint, so it can tell the two apart
#   [W] CAPPED Mound (linear 40 m), point 0 moved: the closing span from the last point is in the box. Control:
#       `rect_no_closed_wrap` disagrees
#   [L] the reported configuration: a cone Mound inside a Pasture3DLayerBrush (Children Footprints). Same
#       control as [C]
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RectEditReachGate.tscn
extends Node

const CRITERIA := 5
const RS := 512
const CENTRE := Vector3(256, 0, 256)
const AGREE_M := 0.001
const DISAGREE_M := 1.0
# The demo Mound's outline, halved: a concave 12-point loop about 300 m across.
const LOOP := [Vector2(-86.5, -107.07), Vector2(-57.92, -185.88), Vector2(22.42, -170.23), Vector2(127.9, -141.99),
	Vector2(150.22, -57.92), Vector2(81.12, -18.58), Vector2(71.37, 88.59), Vector2(-28.27, 152.45),
	Vector2(-96.33, 168.65), Vector2(-102.38, 100.2), Vector2(-146.22, 60.17), Vector2(-95.82, -10.1)]

# [R]'s loop: a rectangle whose top edge (world z 300) has a midpoint. Nudging the midpoint outward gives the
# moved span a box only a few metres deep, snapped to the one tile row z[256..320], while the 60 m ramp changes
# cells down to z 240. Built for the purpose: on the demo loop the tile snap happened to cover the ramp.
const RECT := [Vector2(-150, -250), Vector2(150, -250), Vector2(150, 44), Vector2(0, 44), Vector2(-150, 44)]

var _loop: Array = LOOP
var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== RectEditReachGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	await _settle()
	_terrain.change_region_size(RS)
	_terrain.data.add_region_blank(Vector2i(0, 0), true)
	_terrain.data.ensure_layer_stack()
	for f in [_c, _d, _r, _w, _l]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== RECT EDIT REACH %s (%d failures, %d/%d criteria completed) ===" % [
			"PASS" if _fail == 0 and _ran == CRITERIA else "FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(1 if _fail > 0 or _ran != CRITERIA else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _mound(p_parent: Node, p_setup: Callable) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = "Mound"
	m.terrain = _terrain
	m.auto_refresh = false
	m.snap_to_surface = false
	var path := Path3D.new()
	path.name = "Loop1"
	var c := Curve3D.new()
	for p: Vector2 in _loop:
		c.add_point(Vector3(p.x, 0, p.y))
	c.closed = true
	path.curve = c
	m.add_child(path)
	p_setup.call(m)
	p_parent.add_child(m)
	m.position = CENTRE
	return m


## One arm. Returns [worst |rect - full| in metres, the rect bake's clip, the whole footprint].
func _arm(p_setup: Callable, p_idx: int, p_move: Vector3, p_control: String, p_in_layer: bool) -> Array:
	var host: Node = _terrain
	var lb: Pasture3DLayerBrush = null
	if p_in_layer:
		lb = Pasture3DLayerBrush.new()
		lb.name = "Layer"
		lb.terrain = _terrain
		lb.auto_refresh = false
		_terrain.add_child(lb)
		host = lb
	var m := _mound(host, p_setup)
	await _settle()
	if p_in_layer:
		lb.extent_mode = Pasture3DLayerBrush.ExtentMode.CHILDREN_FOOTPRINTS
	var owner: String = m._layer_owner
	m._refresh_owner(owner, false, [])
	if p_control != "":
		m.set(p_control, true)
	var path: Path3D = m.get_node("Loop1")
	var c := path.curve
	c.set_point_position(p_idx, c.get_point_position(p_idx) + p_move)
	m._refresh_owner_rect(owner, {path.get_instance_id(): true})
	var clip: AABB = m._last_rect_clip
	var rect := _heights()
	if p_control != "":
		m.set(p_control, false)
	m._refresh_owner(owner, false, [])
	var full := _heights()
	var footprint: AABB = m._spline_footprint_aabb(path)
	var worst := 0.0
	for i in rect.size():
		# A cell that is NaN in either reading is a broken fixture, not agreement: count it as the worst.
		var d := absf(full[i] - rect[i])
		worst = INF if is_nan(d) else maxf(worst, d)
		if is_inf(worst):
			break
	# Drop every row this arm created, so the next arm starts from bare ground.
	var stack = _terrain.data.get_layer_stack()
	for i in range(stack.get_layer_count() - 1, 0, -1):
		if String(stack.get_layer(i).get_owner_id()).begins_with(owner):
			_terrain.data.layer_remove(i)
	(lb if lb != null else m).free()
	_terrain.data.composite_region(Vector2i.ZERO, Rect2i(), false)
	print("    arm %s%s: region size %d, peak %.1f m, clip x[%.0f..%.0f] z[%.0f..%.0f], worst %.4f m" % [
			"control " if p_control != "" else "", "(layer)" if p_in_layer else "", _terrain.get_region_size(),
			_peak(full), clip.position.x, clip.end.x, clip.position.z, clip.end.z, worst])
	return [worst, clip, footprint]


func _peak(p_h: PackedFloat32Array) -> float:
	var mx := -INF
	for v in p_h:
		mx = maxf(mx, v)
	return mx


func _heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for z in range(32, RS - 32):
		for x in range(32, RS - 32):
			out.append(_terrain.data.get_height(Vector3(x, 0, z)))
	return out


func _pair(p_tag: String, p_setup: Callable, p_idx: int, p_move: Vector3, p_control: String,
		p_in_layer := false) -> Array:
	var fixed: Array = await _arm(p_setup, p_idx, p_move, "", p_in_layer)
	var broken: Array = await _arm(p_setup, p_idx, p_move, p_control, p_in_layer)
	_check("[%s] rect == full" % p_tag, fixed[0] <= AGREE_M, "worst %.4f m (<= %.3f)" % [fixed[0], AGREE_M])
	_check("[%s] control %s disagrees" % [p_tag, p_control], broken[0] >= DISAGREE_M,
			"worst %.2f m (>= %.1f)" % [broken[0], DISAGREE_M])
	return fixed


func _c() -> void:
	var fixed: Array = await _pair("C", func(_m): pass, 7, Vector3(0, 0, 30), "rect_ignores_edit_reach")
	# The other half of [R]'s witness: an INF reach takes the whole footprint, so here the clip encloses it.
	_check("[C] an unbounded reach clips the whole footprint", _encloses_xz(fixed[1], fixed[2]),
			"clip %s, footprint %s" % [_xz(fixed[1]), _xz(fixed[2])])
	_ran += 1


func _d() -> void:
	await _pair("D", func(m):
		m.flank_mode = Pasture3DMound.FlankMode.FIXED_WIDTH
		m.height = 20.0, 7, Vector3(0, 0, 30), "rect_ignores_edit_reach")
	_ran += 1


## A capped, fixed-width Mound with a LINEAR falloff of `p_falloff` metres. Linear, not the default
## smoothstep: a smoothstep is flat at the inner end of its run, so the cells a too-narrow box misses (just
## past it, deep in the ramp) barely move and the control cannot fail.
func _capped(p_falloff: float) -> Callable:
	return func(m: Pasture3DMound) -> void:
		m.flank_mode = Pasture3DMound.FlankMode.FIXED_WIDTH
		m.capped = true
		m.height = 20.0
		m.falloff_width = p_falloff
		var lin := Curve.new()
		lin.add_point(Vector2(0, 0), 0.0, 1.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
		lin.add_point(Vector2(1, 1), 1.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
		m.falloff_curve = lin


func _r() -> void:
	_loop = RECT
	var fixed: Array = await _pair("R", _capped(60.0), 3, Vector3(0, 0, 10), "rect_ignores_edit_reach")
	_loop = LOOP
	# A finite reach must not degenerate into the whole-footprint path: that would pass [R] and throw away
	# the rect bake's win. [C] shows the same reading enclosing the footprint when the reach is unbounded.
	_check("[R] a finite reach leaves part of the footprint out of the clip", not _encloses_xz(fixed[1], fixed[2]),
			"clip %s, footprint %s" % [_xz(fixed[1]), _xz(fixed[2])])
	_ran += 1


## [W]'s own falloff. At 60 m the reach alone happens to cover the closing span on the demo loop, and the
## control could no longer see a missing wrap.
func _w() -> void:
	await _pair("W", _capped(40.0), 0, Vector3(-25, 0, 0), "rect_no_closed_wrap")
	_ran += 1


func _encloses_xz(p_clip: AABB, p_fp: AABB) -> bool:
	return (p_clip.position.x <= p_fp.position.x and p_clip.end.x >= p_fp.end.x
			and p_clip.position.z <= p_fp.position.z and p_clip.end.z >= p_fp.end.z)


func _xz(p_box: AABB) -> String:
	return "x[%.0f..%.0f] z[%.0f..%.0f]" % [p_box.position.x, p_box.end.x, p_box.position.z, p_box.end.z]


func _l() -> void:
	await _pair("L", func(_m): pass, 7, Vector3(0, 0, 30), "rect_ignores_edit_reach", true)
	_ran += 1
