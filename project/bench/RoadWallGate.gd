# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadWallGate — Pasture3DRoadWall, one criterion per control (PASTURE3D_ROAD_WALL_SPEC.md §7, 2026-09-29).
#
# The fixture for [A]-[I] is a straight road along +x at z = 0 and height 40, on a plane rising toward +z.
# The grader's positive side is +z there, so side +1 CUTS uphill and side -1 FILLS downhill. The formation
# edge is 4.5 m out (3.5 m half width, 1 m shoulder), crown 0, so the edge sits at 40.
#
#   [A] placement: a ROAD_SIDE wall leaves the ground at road level in front of its step and the raw hillside
#       behind it, the step within one cell of edge + x_s; BATTER_TOP runs the batter up to the trigger.
#       Control: no wall grades a 1:1 batter through both probes
#   [B] trigger_height: no wall where the plain batter's catch height (4.5 m) is under the trigger, a wall
#       where it is over. Control: the lower trigger builds one
#   [C] max_height: a wall capped at 2 m holds 2 m, and the batter above it runs at `beyond_batter`. Control:
#       uncapped, the same ground needs more than 4 m
#   [D] offset / thickness: the step moves out by the change in offset + thickness, and the ground in front
#       of the moved wall is road level. Control: the first wall's ground there is the raw hillside
#   [E] top_mode: FOLLOW_ROAD one height per run, STEPPED more than one level and all multiples of
#       step_height (a 40 m sine over 10 m blocks has two block maxima), FOLLOW_GROUND varies with the ground. Control: the ground varies the need by 2 m, which FOLLOW_GROUND shows
#   [F] min_length / gap_bridge: a 4 m gap is walled over under a 6 m bridge and left open under a 2 m one; a
#       5 m run is dropped under a 6 m minimum and kept under 3 m. Controls are the opposite settings
#   [G] end_treatment: TAPER ramps alpha from 0 at the run's ends to 1 over end_taper_length; SQUARE is 1 to
#       the end. Control: the two differ at the end
#   [H] parity: native `grade` and GDScript `grade_reference` agree with a wall plan carrying both modes,
#       tapers, a gap, toe and hinge. Control: the plan moves the grade by more than 0.5 m
#   [I] fill wall: the shelf stays at road level out to the step and the raw valley lies below it. Control:
#       no wall runs the fill batter out over the valley
#   [J] mesh, through the brush on a real terrain: cut and fill walls build a mesh with collision, the cut
#       face at edge + offset, the fill face past the step, and the baked terrain holds the step (road level
#       in front of it, raw hillside behind). The
#       terrain signature ignores the material and sees max_height. Control: no walls, no node, and the
#       batter graded where the ditch was
#   [K] override resolution: segment beats modifier beats type, and a disabled wall resolves to none.
#       Control: the type alone resolves to its wall
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadWallGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K"]
const L := 200
const Z0 := -40
const GH := 81
const SLOPE := 0.5
const ROAD := 40.0

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadWallGate ===")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_grade_grid"):
		_check("H", false, "road_grade_grid is not bound -- rebuild the GDExtension")
	else:
		_a()
		_b()
		_c()
		_d()
		_e()
		_f()
		_g()
		_h()
		_i()
		await _j()
	_k()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD WALL %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not _seen.has(p_name):
		_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


# ---- fixture -----------------------------------------------------------------------------------------

func _wall(p_set: Dictionary = {}) -> Pasture3DRoadWall:
	var w := Pasture3DRoadWall.new()
	for k in p_set:
		w.set(k, p_set[k])
	return w


func _plane(p: Vector2) -> float:
	return ROAD + SLOPE * p.y


## The plan, alignment, profile and wall plan for one arm. `p_opts`: hinge, suppress (sample range).
func _setup(p_cut: Pasture3DRoadWall, p_fill: Pasture3DRoadWall, p_ground: Callable,
		p_opts: Dictionary = {}) -> Dictionary:
	var plan := PackedVector2Array([Vector2(0.0, 0.0), Vector2(float(L), 0.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var n := L + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	a.s0 = 0.0
	var z := PackedFloat32Array()
	z.resize(n)
	z.fill(ROAD)
	a.z = z
	a.bank = Pasture3DRoadGrader._zeros(n)
	var half := PackedFloat32Array()
	half.resize(n)
	half.fill(3.5)
	var shoulder := PackedFloat32Array()
	shoulder.resize(n)
	shoulder.fill(1.0)
	var verge := PackedFloat32Array()
	verge.resize(n)
	verge.fill(3.0)
	var suppress := PackedByteArray()
	suppress.resize(n)
	suppress.fill(0)
	var walls: Array = []
	var cut_idx := PackedInt32Array()
	var fill_idx := PackedInt32Array()
	cut_idx.resize(n)
	fill_idx.resize(n)
	cut_idx.fill(Pasture3DRoadBrush._wall_slot(walls, p_cut if Pasture3DRoadWall.active(p_cut) else null))
	fill_idx.fill(Pasture3DRoadBrush._wall_slot(walls, p_fill if Pasture3DRoadWall.active(p_fill) else null))
	var prof := {
		"half": half, "shoulder": shoulder, "verge": verge, "suppress": suppress,
		"skip": PackedByteArray(), "walls": walls, "cut_wall_idx": cut_idx, "fill_wall_idx": fill_idx,
		"crown": 0.0, "cut_batter": 1.0, "fill_batter": 0.6,
		"hinge_rounding": float(p_opts.get("hinge", 0.0)),
	}
	var sampler := func(p_pts: PackedVector2Array) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		for q in p_pts:
			out.append(p_ground.call(q))
		return out
	a.wall_plan = Pasture3DRoadGrader.build_wall_plan(plan, cum, a, prof, {"crown_mode": 0, "max_bank": 0.0},
			sampler, 1.0)
	return {"plan": plan, "align": a, "prof": prof, "ground": p_ground}


## The wall record at sample `p_i`, side `p_side`, as stored. Empty when the plan has none.
func _rec(p_fx: Dictionary, p_i: int, p_side: int) -> PackedFloat32Array:
	var wp: PackedFloat32Array = p_fx["align"].wall_plan
	if wp.is_empty():
		return PackedFloat32Array()
	var a := (p_i * 2 + (0 if p_side < 0 else 1)) * Pasture3DRoadGrader.WALL_STRIDE
	return wp.slice(a, a + Pasture3DRoadGrader.WALL_STRIDE)


func _mode(p_fx: Dictionary, p_i: int, p_side: int) -> int:
	var r := _rec(p_fx, p_i, p_side)
	return int(r[0]) if not r.is_empty() else 0


## The graded grid, x 0..L by z Z0..-Z0 at 1 m. `p_opts`: toe, hinge, reference.
func _grade(p_fx: Dictionary, p_opts: Dictionary = {}) -> PackedFloat32Array:
	var gw := L + 1
	var ground := PackedFloat32Array()
	ground.resize(gw * GH)
	var fn: Callable = p_fx["ground"]
	for iz in GH:
		for ix in gw:
			ground[iz * gw + ix] = fn.call(Vector2(float(ix), float(Z0 + iz)))
	var prof: Dictionary = p_fx["prof"]
	var opts := {
		"crown": 0.0, "cut_batter": 1.0, "fill_batter": 0.6,
		"toe_rounding": float(p_opts.get("toe", 0.0)), "hinge_rounding": float(p_opts.get("hinge", 0.0)),
		"wall_plan": p_fx["align"].wall_plan,
	}
	var r: Dictionary
	if bool(p_opts.get("reference", false)):
		r = Pasture3DRoadGrader.grade_reference(ground, gw, GH, 0.0, float(Z0), 1.0, p_fx["plan"], p_fx["align"],
				prof["half"], prof["shoulder"], prof["verge"], prof["suppress"], opts)
	else:
		r = Pasture3DRoadGrader.grade(ground, gw, GH, 0.0, float(Z0), 1.0, p_fx["plan"], p_fx["align"],
				prof["half"], prof["shoulder"], prof["verge"], prof["suppress"], opts)
	return r["height"]


func _h_at(p_h: PackedFloat32Array, p_x: int, p_z: int) -> float:
	return p_h[(p_z - Z0) * (L + 1) + p_x]


## The first z outward from the edge on side `p_side` where the ground leaves road level by more than 1 m.
func _step_z(p_h: PackedFloat32Array, p_x: int, p_side: int) -> int:
	for d in range(5, 30):
		if absf(_h_at(p_h, p_x, d * p_side) - ROAD) > 1.0:
			return d
	return -1


# ---- criteria ----------------------------------------------------------------------------------------

func _a() -> void:
	print("[A] placement")
	var plane := _plane
	var rs := _grade(_setup(_wall(), null, plane))
	var bt := _grade(_setup(_wall({"placement": Pasture3DRoadWall.Placement.BATTER_TOP}), null, plane))
	var none := _grade(_setup(null, null, plane))
	var step := _step_z(rs, 100, 1)
	# Edge 4.5 + x_s 1.1 = 5.6: the first whole cell past the step is 6.
	var rs_ok := absf(_h_at(rs, 100, 5) - ROAD) < 0.02 and absf(_h_at(rs, 100, 7) - _plane(Vector2(100, 7))) < 0.02 \
			and absf(float(step) - 5.6) <= 1.0
	# BATTER_TOP at trigger 2 on 1:1: the batter up to 2 m, 2 m out (z 6.5), raw hillside past it.
	var bt_ok := absf(_h_at(bt, 100, 5) - 40.5) < 0.02 and absf(_h_at(bt, 100, 6) - 41.5) < 0.02 \
			and absf(_h_at(bt, 100, 7) - 43.5) < 0.02
	var ctl_ok := absf(_h_at(none, 100, 5) - 40.5) < 0.02 and absf(_h_at(none, 100, 7) - 42.5) < 0.02
	_check("A", rs_ok and bt_ok and ctl_ok,
			"ROAD_SIDE front %.2f (want 40.00), behind %.2f (want raw 43.50), step at z %d (want within 1 of 5.6); BATTER_TOP %.2f/%.2f/%.2f (want 40.50/41.50/43.50); control: no wall %.2f/%.2f (want 40.50/42.50)"
			% [_h_at(rs, 100, 5), _h_at(rs, 100, 7), step, _h_at(bt, 100, 5), _h_at(bt, 100, 6),
			_h_at(bt, 100, 7), _h_at(none, 100, 5), _h_at(none, 100, 7)])


func _b() -> void:
	print("[B] trigger_height")
	var hi := _setup(_wall({"trigger_height": 5.0}), null, _plane)
	var lo := _setup(_wall({"trigger_height": 4.0}), null, _plane)
	var g_hi := _grade(hi)
	_check("B", _mode(hi, 100, 1) == 0 and absf(_h_at(g_hi, 100, 7) - 42.5) < 0.02 and _mode(lo, 100, 1) == 1,
			"catch height 4.5 m: trigger 5 builds mode %d (want 0) and grades the plain batter %.2f (want 42.50); control: trigger 4 builds mode %d (want 1)"
			% [_mode(hi, 100, 1), _h_at(g_hi, 100, 7), _mode(lo, 100, 1)])


func _c() -> void:
	print("[C] max_height")
	var steep := func(p: Vector2) -> float: return ROAD + 0.8 * p.y
	var capped := _setup(_wall({"max_height": 2.0, "beyond_batter": 1.5}), null, steep)
	var free := _setup(_wall({"max_height": 6.0}), null, steep)
	var g := _grade(capped)
	var w := _rec(capped, 100, 1)[2]
	var w_free := _rec(free, 100, 1)[2]
	# Behind the 2 m step at x_s 1.1 the batter climbs at 1.5 until it meets the 0.8 hillside, 4.6 m out.
	var slope := (_h_at(g, 100, 9) - _h_at(g, 100, 7)) / 2.0
	var at6 := _h_at(g, 100, 6)
	_check("C", absf(w - 2.0) < 1e-6 and absf(slope - 1.5) < 0.01 and absf(at6 - 42.6) < 0.02 and w_free > 4.0,
			"capped W %.3f (want 2), batter behind at %.3f (want 1.5), %.2f at 1.5 m (want 42.60); control: uncapped W %.2f (want > 4)"
			% [w, slope, at6, w_free])


func _d() -> void:
	print("[D] offset / thickness")
	var near := _setup(_wall({"offset": 0.5, "thickness": 0.6}), null, _plane)
	var far := _setup(_wall({"offset": 2.5, "thickness": 1.0}), null, _plane)
	var g_near := _grade(near)
	var g_far := _grade(far)
	var s_near := _step_z(g_near, 100, 1)
	var s_far := _step_z(g_far, 100, 1)
	var moved := s_far - s_near
	_check("D", absf(_rec(far, 100, 1)[5] - 3.5) < 1e-6 and moved >= 1 and moved <= 3
			and absf(_h_at(g_far, 100, 7) - ROAD) < 0.02 and absf(_h_at(g_near, 100, 7) - 43.5) < 0.02,
			"x_s %.2f (want 3.5), step moved %d cell(s) (want 2 +- 1), ground in front of the moved wall %.2f (want 40.00); control: the near wall's ground there is raw %.2f (want 43.50)"
			% [_rec(far, 100, 1)[5], moved, _h_at(g_far, 100, 7), _h_at(g_near, 100, 7)])


func _bumpy(p: Vector2) -> float:
	if p.y <= 0.0:
		return _plane(p)
	return _plane(p) + 1.0 + sin(p.x * TAU / 40.0)


func _spread(p_fx: Dictionary, p_a: int, p_b: int) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in range(p_a, p_b):
		var w := _rec(p_fx, i, 1)[2]
		lo = minf(lo, w)
		hi = maxf(hi, w)
	return Vector2(lo, hi)


func _e() -> void:
	print("[E] top_mode")
	var road := _setup(_wall({"top_mode": Pasture3DRoadWall.TopMode.FOLLOW_ROAD}), null, _bumpy)
	var stepped := _setup(_wall({"top_mode": Pasture3DRoadWall.TopMode.STEPPED, "step_length": 10.0,
			"step_height": 0.5}), null, _bumpy)
	var ground := _setup(_wall({"top_mode": Pasture3DRoadWall.TopMode.FOLLOW_GROUND, "top_smoothing": 4.0}),
			null, _bumpy)
	var r := _spread(road, 10, 190)
	var gr := _spread(ground, 10, 190)
	var multiples := true
	var levels := {}
	for i in range(10, 190):
		var w := _rec(stepped, i, 1)[2]
		levels[snappedf(w, 0.001)] = true
		if absf(w / 0.5 - roundf(w / 0.5)) > 1e-4:
			multiples = false
	_check("E", r.y - r.x < 1e-5 and r.x > 4.7 and multiples and levels.size() >= 2 and gr.y - gr.x > 1.0,
			"FOLLOW_ROAD %.3f..%.3f (want one height, > 4.7); STEPPED %d level(s), all multiples of 0.5: %s; control: FOLLOW_GROUND %.2f..%.2f (want a spread > 1)"
			% [r.x, r.y, levels.size(), multiples, gr.x, gr.y])


func _f() -> void:
	print("[F] min_length / gap_bridge")
	# A 4-sample gap (100..103) where the cut side is flat.
	var gap := func(p: Vector2) -> float:
		if p.y > 0.0 and p.x > 99.5 and p.x < 103.5:
			return ROAD
		return _plane(p)
	# Only a 5-sample stretch (150..154) of hillside on the cut side.
	var short := func(p: Vector2) -> float:
		if p.y > 0.0 and not (p.x > 149.5 and p.x < 154.5):
			return ROAD
		return _plane(p)
	var bridged := _setup(_wall({"gap_bridge": 6.0}), null, gap)
	var open := _setup(_wall({"gap_bridge": 2.0}), null, gap)
	var dropped := _setup(_wall({"min_length": 6.0}), null, short)
	var kept := _setup(_wall({"min_length": 3.0}), null, short)
	_check("F", _mode(bridged, 101, 1) == 1 and _mode(open, 101, 1) == 0 and _mode(dropped, 152, 1) == 0
			and _mode(kept, 152, 1) == 1 and _mode(open, 98, 1) == 1,
			"4 m gap under bridge 6: mode %d (want 1), under 2: %d (want 0, with the run beside it %d); 5 m run under min 6: %d (want 0), under 3: %d (want 1)"
			% [_mode(bridged, 101, 1), _mode(open, 101, 1), _mode(open, 98, 1), _mode(dropped, 152, 1),
			_mode(kept, 152, 1)])


func _g() -> void:
	print("[G] end_treatment")
	var taper := _setup(_wall({"end_treatment": Pasture3DRoadWall.EndTreatment.TAPER, "end_taper_length": 4.0}),
			null, _plane)
	var square := _setup(_wall({"end_treatment": Pasture3DRoadWall.EndTreatment.SQUARE}), null, _plane)
	var a0 := _rec(taper, 0, 1)[3]
	var a2 := _rec(taper, 2, 1)[3]
	var a100 := _rec(taper, 100, 1)[3]
	var a_end := _rec(taper, L, 1)[3]
	var s0 := _rec(square, 0, 1)[3]
	_check("G", a0 == 0.0 and absf(a2 - 0.5) < 1e-6 and a100 == 1.0 and a_end == 0.0 and s0 == 1.0,
			"TAPER alpha %.3f / %.3f / %.3f / %.3f at 0 / 2 / 100 / end (want 0 / 0.5 / 1 / 0); control: SQUARE %.3f at 0 (want 1)"
			% [a0, a2, a100, a_end, s0])


func _h() -> void:
	print("[H] native grader vs grade_reference with a wall plan")
	var gapped := func(p: Vector2) -> float:
		if p.y > 0.0 and p.x > 119.5 and p.x < 121.5:
			return ROAD
		return _bumpy(p)
	var fx := _setup(_wall({"top_mode": Pasture3DRoadWall.TopMode.FOLLOW_GROUND, "gap_bridge": 0.0,
			"min_length": 0.0, "end_taper_length": 6.0}),
			_wall({"placement": Pasture3DRoadWall.Placement.BATTER_TOP, "trigger_height": 3.0}), gapped,
			{"hinge": 1.0})
	var opts := {"toe": 1.5, "hinge": 1.0}
	var nat := _grade(fx, opts)
	opts["reference"] = true
	var orc := _grade(fx, opts)
	var plain_fx := _setup(null, null, gapped, {"hinge": 1.0})
	var plain := _grade(plain_fx, {"toe": 1.5, "hinge": 1.0})
	var worst := 0.0
	var moved := 0.0
	for i in nat.size():
		worst = maxf(worst, absf(nat[i] - orc[i]))
		moved = maxf(moved, absf(nat[i] - plain[i]))
	var modes := {}
	for i in L + 1:
		modes[_mode(fx, i, 1)] = true
		modes[_mode(fx, i, -1)] = true
	_check("H", worst < 1e-4 and moved > 0.5 and modes.has(0) and modes.has(1) and modes.has(2),
			"worst %.7f m (want < 1e-4) over modes %s; control: the walls move the grade by %.2f m (want > 0.5)"
			% [worst, modes.keys(), moved])


func _i() -> void:
	print("[I] fill wall")
	var fx := _setup(null, _wall(), _plane)
	var g := _grade(fx)
	var none := _grade(_setup(null, null, _plane))
	var w := _rec(fx, 100, -1)[2]
	_check("I", absf(w - 2.8) < 1e-4 and absf(_h_at(g, 100, -5) - ROAD) < 0.02
			and absf(_h_at(g, 100, -7) - 36.5) < 0.02 and absf(_h_at(none, 100, -7) - 38.5) < 0.02,
			"W %.3f (want 2.8), shelf %.2f (want 40.00), below the wall %.2f (want raw 36.50); control: no wall %.2f (want the batter 38.50)"
			% [w, _h_at(g, 100, -5), _h_at(g, 100, -7), _h_at(none, 100, -7)])


# ---- [J] through the brush, into the terrain and the wall mesh --------------------------------------

const RS := 256
const ZC := 128.0


func _j() -> void:
	print("[J] mesh and terrain through the brush")
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
	for row in RS:
		img.fill_rect(Rect2i(0, row, RS, 1), Color(ROAD + SLOPE * (float(row) - ZC), 0, 0, 1))
	r.set_modified(true)
	r.calc_height_range()
	d.update_maps()
	d.calc_height_range(true)
	d.ensure_layer_stack()
	var net := Pasture3DRoadNetwork.new()
	net.name = "RoadNetwork"
	terrain.add_child(net)

	var on := await _hill_road(terrain, net, true)
	var off := await _hill_road(terrain, net, false)
	print("    walls on : %d quads, %d collision faces, cut face z %.2f, fill face z %.2f, ditch %.2f, behind %.2f"
			% [on["quads"], on["faces"], on["cut_face"], on["fill_face"], on["ditch"], on["behind"]])
	print("    walls off: node %s, ditch %.2f" % [off["node"], off["ditch"]])
	var w := _wall()
	var t0 := w.terrain_signature()
	var m0 := w.mesh_signature()
	w.material = StandardMaterial3D.new()
	var mat_ok := w.terrain_signature() == t0 and w.mesh_signature() != m0
	w.max_height = 3.0
	var h_ok := w.terrain_signature() != t0
	# The brush's formation edge is half_width() (lanes + shoulder, 4.5) plus the shoulder again: 5.5. Cut
	# face at edge + offset 0.5, less the 0.05 coping overhang; fill face at edge + x_s 1.1 + band 1.5 +
	# overhang 0.05. The ditch probe (6.0) lies between the edge and the step on a grid row: 6.5 would blend
	# in the row past the 6.6 step. The other probe (8) is behind the wall.
	_check("J", on["node"] and on["quads"] > 0 and on["faces"] > 0
			and absf(on["cut_face"] - (ZC + 5.95)) < 0.3 and absf(on["fill_face"] - (ZC - 8.15)) < 0.3
			and absf(on["ditch"] - ROAD) < 0.1 and absf(on["behind"] - (ROAD + SLOPE * 8.0)) < 0.1
			and mat_ok and h_ok and not off["node"] and off["ditch"] > ROAD + 0.3,
			"mesh, collision, faces where the plan puts them, the step in the baked terrain; material outside the terrain signature: %s, max_height inside it: %s; control: no walls, no node, and the batter %.2f in the ditch"
			% [mat_ok, h_ok, off["ditch"]])
	terrain.queue_free()


func _hill_road(p_terrain: Pasture3D, p_net: Pasture3DRoadNetwork, p_walls: bool) -> Dictionary:
	var t := Pasture3DRoadType.new()
	t.lane_width = 3.5
	t.shoulder_width = 1.0
	t.crown = 0.0
	t.cut_batter = 1.0
	t.fill_batter = 0.6
	if p_walls:
		t.cut_wall = _wall()
		t.fill_wall = _wall()
	var road := Pasture3DRoadBrush.new()
	road.name = "Hill"
	road.terrain = p_terrain
	road.road_road_type = t
	road.log_bake_timing = false
	road.snap_to_surface = false
	p_net.add_child(road)
	var path := Path3D.new()
	path.name = "Spline"
	var c := Curve3D.new()
	for i in 6:
		c.add_point(Vector3(30.0 + 40.0 * float(i), ROAD, ZC))
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	await get_tree().process_frame
	await get_tree().process_frame
	road._refresh_owner(road._layer_owner, false, [])
	var host := Pasture3DRoadChunkHost.new()
	add_child(host)
	host.rebuild(road)
	var walls := host.get_node_or_null("RetainingWalls") as MeshInstance3D
	var out := {"quads": host.wall_quads, "faces": host.wall_collision_faces, "node": walls != null,
			"cut_face": INF, "fill_face": INF}
	if walls != null and walls.mesh != null:
		for si in walls.mesh.get_surface_count():
			var arr: Array = walls.mesh.surface_get_arrays(si)
			for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				if v.x < 90.0 or v.x > 190.0:
					continue # away from the run ends
				if v.z > ZC:
					out["cut_face"] = minf(out["cut_face"], v.z)
				else:
					out["fill_face"] = minf(out["fill_face"], v.z)
	# The ditch in front of the cut wall, and the hillside behind it, averaged along the middle.
	var ditch := 0.0
	var behind := 0.0
	var k := 0
	for x in range(100, 181, 10):
		ditch += p_terrain.data.get_height(Vector3(x, 0, ZC + 6.0))
		behind += p_terrain.data.get_height(Vector3(x, 0, ZC + 8.0))
		k += 1
	out["ditch"] = ditch / float(k)
	out["behind"] = behind / float(k)
	host.queue_free()
	p_terrain.data.clear_layer_in_area(road._layer_id, AABB(Vector3(-2000, -1000, -2000), Vector3(4000, 2000, 4000)))
	road.get_parent().remove_child(road)
	road.free()
	await get_tree().process_frame
	return out


func _k() -> void:
	print("[K] override resolution")
	var type_w := _wall()
	var mod_w := _wall()
	var seg_w := _wall()
	var off_w := _wall({"enabled": false})
	var t := Pasture3DRoadType.new()
	t.cut_wall = type_w
	var mod := Pasture3DNodeRoad.new()
	mod.cut_wall_override = mod_w
	var seg := Pasture3DRoadSegment.new()
	seg.cut_wall = seg_w
	var all := Pasture3DRoadBrush._resolved_wall(seg, mod, t, true)
	var no_seg := Pasture3DRoadBrush._resolved_wall(null, mod, t, true)
	var type_only := Pasture3DRoadBrush._resolved_wall(null, null, t, true)
	mod.cut_wall_override = off_w
	var switched := Pasture3DRoadBrush._resolved_wall(null, mod, t, true)
	var fill_none := Pasture3DRoadBrush._resolved_wall(seg, null, t, false)
	_check("K", all == seg_w and no_seg == mod_w and switched == null and fill_none == null and type_only == type_w,
			"segment wins: %s, modifier next: %s, disabled override switches it off: %s, no fill wall anywhere: %s; control: the type alone resolves to its wall: %s"
			% [all == seg_w, no_seg == mod_w, switched == null, fill_none == null, type_only == type_w])
