# LayerMemberBlendGate — a later member of a REPLACE layer fades in over what the row already holds.
#
# Each member solves from the ground below the layer and writes absolute heights, so a later member's feather
# only blended toward the GROUND. Where it overlapped an earlier member, that member's result ended on a cliff
# at the rim: measured at 21-30 m along Plow5's edge on demo_island. The rule now is
#     new = own + (1 - weight) * (row - ground)
# so the earlier member's change fades out exactly as this one fades in, and where nothing is under the brush
# the write is the historical one, to the bit.
#
# The fixture is a tall plateau (A) with a low plateau (B) wholly on top of it, on non-zero ground: a build that
# took a blank row cell as height 0 would be GROUND metres out everywhere it did not overlap.
#
#   [A] B's rim is continuous; control: the step the old rule leaves, built from solo bakes of the same brushes
#   [B] B's interior is B's own result; control: A alone is far from it
#   [C] a cell off B keeps A's result; control: B alone is far from it
#   [D] rect bakes of B there and back return the line and A's ramp; control: B's new position moves the line
#   [E] with no overlap B is exactly B alone; control: B alone moves the line
#   [F] a Modifier Margin band blends too; control: the band really is written
#   [G] the GDScript route matches native, and a stamp-cache replay matches its first bake; control: a poisoned
#       cache moves the terrain, so the replay really ran
#   [H] rect bakes there and back on the GDScript route return the line and A's ramp. A is repainted for B's box
#       and that route computes its whole grid; outside the box the row is not cleared, so an unclipped A fades
#       in over itself, and only where its weight is below 1, which is why the ramp is read. Control: B's new
#       position moves the line
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerMemberBlendGate.tscn
extends Node

const CRITERIA := 8
const RS := 256
const GROUND := 5.0
const GROUND_OWNER := "gate:ground"
const A_SPEC := [20.0, 20.0, 220.0, 236.0, 12.0, 20.0]
const B_SPEC := [110.0, 88.0, 190.0, 168.0, 3.0, 10.0]
const A_APART_SPEC := [20.0, 20.0, 80.0, 236.0, 12.0, 20.0]
const MAX_STEP := 2.5
const LINE_Z := 128.0
const OFF_B := Vector3(60.0, 0.0, LINE_Z)
const B_CENTRE := Vector3(150.0, 0.0, LINE_Z)
const A_RAMP := Vector3(30.0, 0.0, LINE_Z) # half way up A's flank, well outside any box B's rect bakes clear

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== LayerMemberBlendGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	_terrain.data.create_owned_layer_typed(GROUND_OWNER, "Ground", 1, Pasture3DTerrainBrush.PASTURE_3D_MAPTYPE_HEIGHT)
	_set_ground(GROUND)
	await _overlap_criteria()
	await _f_margin()
	await _g_gdscript_route()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== LAYER MEMBER BLEND %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _overlap_criteria() -> void:
	var nodes := await _build([A_SPEC])
	var a_line := _line()
	var a_centre := _height(B_CENTRE)
	var a_off := _height(OFF_B)
	await _clear(nodes)
	nodes = await _build([B_SPEC])
	var b_line := _line()
	var b_centre := _height(B_CENTRE)
	var b_off := _height(OFF_B)
	await _clear(nodes)
	nodes = await _build([A_SPEC, B_SPEC])
	var line := _line()
	var old_step := _old_rule_step(a_line, b_line)
	var step := _largest_step(line)
	_check("A rim is continuous", old_step > 8.0 and step < MAX_STEP,
			"largest step across B's rim %.3f m (want < %.1f); control, the old rule's step %.3f m (want > 8)" % [step, MAX_STEP, old_step])
	_ran += 1
	var centre := _height(B_CENTRE)
	_check("B interior is B's result", absf(centre - b_centre) < 0.001 and absf(a_centre - b_centre) > 5.0,
			"%.4f m, B alone %.4f m; control, A alone %.4f m" % [centre, b_centre, a_centre])
	_ran += 1
	var off := _height(OFF_B)
	_check("C off B is A's result", absf(off - a_off) < 0.001 and absf(b_off - a_off) > 5.0,
			"%.4f m, A alone %.4f m; control, B alone %.4f m" % [off, a_off, b_off])
	_ran += 1
	var b_node: Pasture3DTerrainBrush = nodes[1]
	var spline: Path3D = b_node._get_splines()[0]
	var sid := spline.get_instance_id()
	var home := spline.position
	var moved := 0.0
	var ramp := _height(A_RAMP)
	for i in range(3):
		for target in [Vector3(-12.0, 0.0, 0.0), home]:
			spline.position = target
			b_node._dirty_splines = {sid: true}
			b_node._refresh_owner_rect(b_node._layer_owner, {sid: true}, true)
			await _settle()
			if target != home:
				moved = maxf(moved, _largest_gap(_line(), line))
	var drift := _largest_gap(_line(), line)
	# A rect bake composites only its box, so outside it the terrain still shows the row's last composite.
	_terrain.data.composite_area(AABB(Vector3(-4.0, -1000.0, -4.0), Vector3(RS + 8.0, 2000.0, RS + 8.0)), false)
	var ramp_drift := absf(_height(A_RAMP) - ramp)
	_check("D rect bakes there and back return the line", drift < 0.01 and ramp_drift < 0.01 and moved > 1.0,
			"3 round trips left up to %.4f m, A's ramp %.4f m (want < 0.01); control, moving B changed it by %.3f m" % [drift, ramp_drift, moved])
	_ran += 1
	await _clear(nodes)
	nodes = await _build([A_APART_SPEC, B_SPEC])
	var gap := _largest_gap(_line(), b_line)
	var b_rise := b_centre - GROUND
	_check("E no overlap writes exactly B alone", gap == 0.0 and b_rise > 2.0,
			"largest difference %.6f m (want exactly 0); control, B alone rises %.3f m" % [gap, b_rise])
	_ran += 1
	await _clear(nodes)


func _f_margin() -> void:
	var nodes := await _build([A_SPEC], 10.0)
	var a_line := _line()
	await _clear(nodes)
	nodes = await _build([A_SPEC, B_SPEC], 10.0)
	var line := _line()
	var step := _largest_step(line)
	var band := 0.0
	for i in range(10, 20): # x = 100..109: B's band, outside its outline
		band = maxf(band, absf(line[i] - a_line[i]))
	_check("F a margin band is continuous too", step < MAX_STEP and band > 0.01,
			"largest step with a 10 m margin %.3f m (want < %.1f); control, B moved its band by %.3f m" % [step, MAX_STEP, band])
	_ran += 1
	await _clear(nodes)


func _g_gdscript_route() -> void:
	var nodes := await _build([A_SPEC, B_SPEC])
	var native := _line()
	await _clear(nodes)
	nodes = await _build([A_SPEC, B_SPEC], 0.0, true)
	var gd := _line()
	var parity := _largest_gap(native, gd)
	# Only the scheduled refresh clears these; without it a headless bake never reaches the stamp cache.
	for m in nodes:
		m._dirty_splines = {}
	_bake(nodes[-1])
	await _settle()
	var replay_gap := _largest_gap(_line(), gd)
	var b_node: Pasture3DTerrainBrush = nodes[1]
	var sid: int = b_node._get_splines()[0].get_instance_id()
	var poisoned := -INF
	if b_node._stamp_cache.has(sid):
		var before := _height(B_CENTRE)
		var vals: PackedFloat32Array = b_node._stamp_cache[sid]["vals"]
		for i in vals.size():
			vals[i] += 1.0
		b_node._stamp_cache[sid]["vals"] = vals
		_bake(nodes[-1])
		await _settle()
		poisoned = _height(B_CENTRE) - before
	_check("G the GDScript route and its cache agree", parity < 0.05 and replay_gap < 0.001 and absf(poisoned - 1.0) < 0.01,
			"native vs GDScript %.4f m (want < 0.05); replay vs first bake %.5f m (want < 0.001); control, a cache raised 1 m moved B by %.3f m" % [parity, replay_gap, poisoned])
	_ran += 1
	await _clear(nodes)
	nodes = await _build([A_SPEC, B_SPEC], 0.0, true)
	var start := _line()
	b_node = nodes[1]
	var spline: Path3D = b_node._get_splines()[0]
	sid = spline.get_instance_id()
	var home := spline.position
	var moved := 0.0
	var ramp := _height(A_RAMP)
	for i in range(3):
		for target in [Vector3(-12.0, 0.0, 0.0), home]:
			spline.position = target
			b_node._dirty_splines = {sid: true}
			b_node._refresh_owner_rect(b_node._layer_owner, {sid: true}, true)
			await _settle()
			if target != home:
				moved = maxf(moved, _largest_gap(_line(), start))
	var drift := _largest_gap(_line(), start)
	# A rect bake composites only its box, so outside it the terrain still shows the row's last composite.
	_terrain.data.composite_area(AABB(Vector3(-4.0, -1000.0, -4.0), Vector3(RS + 8.0, 2000.0, RS + 8.0)), false)
	var ramp_drift := absf(_height(A_RAMP) - ramp)
	_check("H GDScript rect bakes there and back return the line", drift < 0.01 and ramp_drift < 0.01 and moved > 1.0,
			"3 round trips left up to %.4f m, A's ramp %.4f m (want < 0.01); control, moving B changed it by %.3f m" % [drift, ramp_drift, moved])
	_ran += 1
	await _clear(nodes)


## One Layer brush with a member per spec, [x0, z0, x1, z1, height, falloff]. Baking one member repaints them all.
func _build(p_specs: Array, p_margin: float = 0.0, p_gdscript: bool = false) -> Array:
	var lb := Pasture3DLayerBrush.new()
	lb.name = "BlendLayer"
	lb.terrain = _terrain
	lb.auto_refresh = false
	_terrain.add_child(lb)
	var out := []
	for s in p_specs:
		var m := Pasture3DMound.new()
		m.name = "Member%d" % out.size()
		m.terrain = _terrain
		m.auto_refresh = false
		m.flank_mode = Pasture3DMound.FlankMode.FIXED_WIDTH
		m.capped = true
		m.height = s[4]
		m.falloff_width = s[5]
		m.relative_to_terrain = true
		m.force_gdscript_raster = p_gdscript
		if p_margin > 0.0:
			var fn := FastNoiseLite.new()
			fn.seed = 7
			fn.frequency = 0.05
			var nz := Pasture3DNodeNoise.new()
			nz.noise = fn
			nz.strength = 0.5
			var mods: Array[Pasture3DNode] = [nz]
			m.modifiers = mods
			m.modifier_margin = p_margin
		var path := Path3D.new()
		path.name = "Area"
		var c := Curve3D.new()
		for p in [Vector3(s[0], 0, s[1]), Vector3(s[2], 0, s[1]), Vector3(s[2], 0, s[3]), Vector3(s[0], 0, s[3])]:
			c.add_point(p)
		c.closed = true
		path.curve = c
		m.add_child(path)
		lb.add_child(m)
		out.append(m)
	lb.adopt_members()
	lb.bake_base()
	_bake(out[-1])
	await _settle()
	return out


func _bake(p_member: Pasture3DTerrainBrush) -> void:
	p_member._refresh_owner(p_member._layer_owner, false, [])


func _clear(p_nodes: Array) -> void:
	var lb: Pasture3DLayerBrush = p_nodes[0].get_parent()
	var owners: Array = [p_nodes[0]._layer_owner, lb.base_owner_id(), lb.layer_owner_id()]
	for n in p_nodes:
		n.free()
	lb.free()
	for o in owners:
		var row := _row(o)
		if row > 0:
			_terrain.data.layer_remove(row)
	_set_ground(GROUND)
	await _settle()


## Heights along B's near edge: x = 90..150, plateau A throughout, B's rim at x = 110, B's top from x = 120.
func _line() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for x in range(90, 151):
		out.append(_height(Vector3(float(x), 0.0, LINE_Z)))
	return out


## What overwriting would give: B's value wherever B alone moved the ground, A's elsewhere. A fixture with no
## cliff to fix reports a small number here.
func _old_rule_step(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(1, p_a.size()):
		var here: float = p_b[i] if absf(p_b[i] - GROUND) > 0.0001 else p_a[i]
		var there: float = p_b[i - 1] if absf(p_b[i - 1] - GROUND) > 0.0001 else p_a[i - 1]
		worst = maxf(worst, absf(here - there))
	return worst


func _largest_step(p_line: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(1, p_line.size()):
		worst = maxf(worst, absf(p_line[i] - p_line[i - 1]))
	return worst


func _largest_gap(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in p_a.size():
		worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _height(p_pos: Vector3) -> float:
	return _terrain.data.get_height(p_pos)


func _row(p_owner: String) -> int:
	return _terrain.data.get_layer_stack().find_layer_by_owner(p_owner)


func _set_ground(p_h: float) -> void:
	var patch := PackedFloat32Array()
	patch.resize(RS * RS)
	patch.fill(p_h)
	_terrain.data.stamp_grid(_row(GROUND_OWNER), patch, 0.0, 0.0, 1.0, RS, RS, 0)
	_terrain.data.composite_region(Vector2i.ZERO, Rect2i(), false)


func _settle() -> void:
	for i in range(3):
		await get_tree().process_frame


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1
