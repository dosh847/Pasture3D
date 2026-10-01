# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSectionGate — a segment overrides its road for its own stretch, and eases into it
# (PASTURE3D_ROAD_SEGMENT_SECTIONS_SPEC.md, 2026-09-30).
#
# Unit arms, no terrain:
#   [B] blend: across a 20 m transition a continuous value is the midpoint at the boundary, the two levels'
#       values 10 m either side, and monotone between. Control: transition 0 is a step
#   [C] clamp: a transition longer than a stretch is clamped to half of each adjacent stretch, and never
#       overshoots the segment's value. Control: a long segment keeps the full half-transition
#   [S] solver: a per-sample max_grade lets the profile climb a 0.2 ramp inside the segment and holds 0.04
#       outside it; native and GDScript agree. Control: the road's scalar max_grade alone cannot climb it
#   [Q] sample: `sample()`'s one walk agrees with `blend_at` / `level_at` at every sample, over overlapping,
#       abutting, short and transition-free segments. Control: the same reads half a sample later disagree
#
# Brush arms: a straight road along +x at z = ZC and height ROAD on a plane rising toward +z (the cut
# side). Plan points every 40 m from x = 30, so s = x - 30; the segment picks points 2..4, s 80..160.
# Type A: 2 lanes of 3 m, shoulder 1 -> half 4, ribbon edge 5. Type B: 2 lanes of 5 m -> half 6, edge 7.
#   [W] widths: sections, grading_profile, graph_path and the corridor/formation widths read B inside the
#       segment and A outside. Control: a segment naming no type leaves the road A everywhere
#   [G] grading: the baked ground 6 m out is road level inside the segment (B's formation) and batter
#       outside it (A's). Control: the untyped segment grades batter there too
#   [F] protect: the formation another road refuses to regrade is B's 7 m inside the segment and A's 5 m
#       outside it. Control: formation_half_width() is 7, the width the whole road used to protect
#   [M] ribbon: the mesh's edge is 7 m in the segment, 5 m outside, 6 m at the boundary, and the segment's
#       chunks carry B's material. Control: the untyped segment's ribbon is 5 m in the same place
#   [D] draped: a TERRAIN_DRAPED-typed segment leaves no ribbon on its stretch, the ribbon still stands up to
#       it, and sinks toward the boundary. Control: [M]'s ribbon
#   [P] paint: the segment's stretch paints B's texture, the road A's, and the transition both. Control:
#       the untyped segment paints A alone
#   [J] junction runs: half width and priority read the stretch's. Control: the untyped segment's run
#   [K] caches: an in-place edit to the segment's type moves the alignment digest (max_grade), the ribbon
#       digest (lane_width) and the paint signature (surface_layer_id). Controls: fields none of them read
#       move nothing
#
# Bake arms, each on its own terrain:
#   [A] banked crown: on a Bezier arc banked to its cap -- which takes the brush's own vertex curvature --
#       the native route and the GDScript route both grade the carriageway to the crown the ribbon draws,
#       faded out by the bank. Control: the unfaded crown is more than 5 cm away at the same cells
#   [R] ribbon after the ground moves: a Mound slid under the road moves its alignment, and the ribbon is
#       rebuilt to it although no road input changed. Control: a rebuild with nothing changed skips
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RoadSectionGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["B", "C", "S", "Q", "W", "G", "F", "M", "D", "P", "J", "K", "A", "R"]
const RS := 256
const ZC := 128.0
const ROAD := 40.0
const SLOPE := 0.5
const X0 := 30.0

var _fail := 0
var _seen: Dictionary = {}


## Records every cover the paint hands out, instead of writing a layer: which texture went where.
class PaintRecBrush extends Pasture3DRoadBrush:
	var painted: Array = []

	func paint_layer_id() -> int:
		return 0

	func _paint_cover(p_layer_id: int, p_cover: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float,
			p_min_z: float, p_vs: float, p_texture: int) -> int:
		var xs := PackedFloat32Array()
		for i in p_cover.size():
			if p_cover[i] >= Pasture3DRoadPaint.MIN_COVERAGE:
				xs.append(Pasture3DRoadPaint.cell_position(i, p_gw, p_min_x, p_min_z, p_vs).x)
		painted.append({"texture": p_texture, "xs": xs})
		return xs.size()


func _ready() -> void:
	print("=== RoadSectionGate ===")
	_b()
	_c()
	_s()
	_q()
	await _brush_arms()
	await _a()
	await _r()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== ROAD SECTION %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


## Half the protected run across column `p_x`, in cells: (count - 1) / 2.
func _protected_half(p_mask: PackedByteArray, p_gw: int, p_gh: int, p_x: int) -> float:
	if p_mask.size() != p_gw * p_gh:
		return -1.0
	var count := 0
	for z in p_gh:
		if p_mask[z * p_gw + p_x] != 0:
			count += 1
	return maxf(float(count - 1) * 0.5, 0.0)


# ---- unit arms ---------------------------------------------------------------------------------------

func _b() -> void:
	print("[B] blend across a transition")
	var lv := [{"half": 3.0}, {"half": 5.0}]
	var sec := Pasture3DRoadSections.build(lv, [[100.0, 200.0, 20.0]], 300.0)
	var at := [sec.number_at(&"half", 89.0), sec.number_at(&"half", 90.0), sec.number_at(&"half", 100.0),
			sec.number_at(&"half", 110.0), sec.number_at(&"half", 111.0)]
	var mono := true
	var prev := -INF
	for k in 41:
		var v := sec.number_at(&"half", 90.0 + 0.5 * float(k))
		mono = mono and v >= prev - 1e-6
		prev = v
	# The far end mirrors it.
	var far := sec.number_at(&"half", 200.0)
	var step := Pasture3DRoadSections.build(lv, [[100.0, 200.0, 0.0]], 300.0)
	var c0 := step.number_at(&"half", 99.9)
	var c1 := step.number_at(&"half", 100.0)
	print("    at 89/90/100/110/111: %s; far boundary %.3f; monotone %s; step 99.9 -> %.3f, 100 -> %.3f"
			% [str(at), far, mono, c0, c1])
	_check("B", absf(at[0] - 3.0) < 1e-5 and absf(at[1] - 3.0) < 1e-5 and absf(at[2] - 4.0) < 1e-5
			and absf(at[3] - 5.0) < 1e-5 and absf(at[4] - 5.0) < 1e-5 and mono and absf(far - 4.0) < 1e-5
			and absf(c0 - 3.0) < 1e-5 and absf(c1 - 5.0) < 1e-5,
			"midpoint at the boundary, the levels' values 10 m out, monotone; control: transition 0 steps 3 -> 5")


func _c() -> void:
	print("[C] a transition is clamped to its stretches")
	var lv := [{"half": 3.0}, {"half": 5.0}]
	var short := Pasture3DRoadSections.build(lv, [[100.0, 108.0, 20.0]], 300.0)
	var peak := -INF
	for k in 81:
		peak = maxf(peak, short.number_at(&"half", 80.0 + 0.5 * float(k)))
	var long := Pasture3DRoadSections.build(lv, [[100.0, 200.0, 20.0]], 300.0)
	print("    8 m segment: half-transitions %s, peak %.3f, at 96 %.3f; 100 m segment: %s"
			% [str(short.half_at), peak, short.number_at(&"half", 96.0), str(long.half_at)])
	_check("C", short.half_at.size() == 3 and absf(short.half_at[1] - 4.0) < 1e-5
			and absf(short.half_at[2] - 4.0) < 1e-5 and peak <= 5.0 + 1e-5 and peak > 4.99
			and absf(short.number_at(&"half", 96.0) - 3.0) < 1e-5
			and long.half_at.size() == 3 and absf(long.half_at[1] - 10.0) < 1e-5,
			"clamped to 4 m each side, reaching 5 at the middle and no further; control: a long segment keeps 10 m")


func _s() -> void:
	print("[S] a per-sample max_grade reaches the solver")
	var n := 401
	var plan := PackedVector2Array([Vector2(0, 0), Vector2(float(n - 1), 0)])
	var ground := PackedFloat32Array()
	ground.resize(n)
	var grade_s := PackedFloat32Array()
	grade_s.resize(n)
	for i in n:
		ground[i] = clampf((float(i) - 150.0) * 0.2, 0.0, 20.0)
		grade_s[i] = 0.3 if i >= 100 and i < 300 else 0.04
	var opts := {"pins": {}, "max_grade_s": grade_s}
	var nat := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, 1.0, 0.04, 16.67, 0.06, opts)
	var gd := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, 1.0, 0.04, 16.67, 0.06, opts, true)
	var ctl := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, 1.0, 0.04, 16.67, 0.06, {"pins": {}})
	var inside := _max_grade(nat.z, 160, 240)
	var outside := maxf(_max_grade(nat.z, 1, 100), _max_grade(nat.z, 301, n))
	var ctl_inside := _max_grade(ctl.z, 160, 240)
	var ctl_all := _max_grade(ctl.z, 1, n)
	var par := 0.0
	for i in n:
		par = maxf(par, absf(nat.z[i] - gd.z[i]))
	print("    segment: steepest %.3f inside, %.4f outside; native vs GDScript %.6f m; control: scalar only %.4f inside, %.4f anywhere"
			% [inside, outside, par, ctl_inside, ctl_all])
	_check("S", inside > 0.12 and inside <= 0.3 + 1e-3 and outside <= 0.04 + 1e-3 and par < 1e-3
			and ctl_all <= 0.04 + 1e-3,
			"the segment climbs the ramp, the road does not, both routes agree; control: the scalar holds 0.04")


func _q() -> void:
	print("[Q] sample() walks the stretches as blend_at and level_at read them")
	var lv := [{"half": 3.0}, {"half": 5.0}, {"half": 7.0}, {"half": 2.0}, {"half": 9.0}]
	# Overlapping (2 over 1), abutting (3 against 2's end), short with a long transition (4), and one
	# with no transition at all (3).
	var ranges := [[40.0, 140.0, 20.0], [100.0, 180.0, 12.0], [180.0, 200.0, 0.0], [230.0, 236.0, 30.0]]
	var sec := Pasture3DRoadSections.build(lv, ranges, 300.0)
	var ds := 0.25
	var n := 1201
	var smp := sec.sample(ds, n)
	var la: PackedInt32Array = smp["from"]
	var lb: PackedInt32Array = smp["to"]
	var w: PackedFloat32Array = smp["weight"]
	var own: PackedInt32Array = smp["owner"]
	var bad := 0
	var blended := 0
	var late := 0
	for i in n:
		var at := float(i) * ds
		var b := sec.blend_at(at)
		if la[i] != b[0] or lb[i] != b[1] or absf(w[i] - float(b[2])) > 1e-6 or own[i] != sec.level_at(at):
			bad += 1
		if w[i] > 0.0:
			blended += 1
		var c := sec.blend_at(at + 0.5 * ds)
		if absf(w[i] - float(c[2])) > 1e-6 or own[i] != sec.level_at(at + 0.5 * ds):
			late += 1
	print("    %d stretch(es) %s, %d sample(s), %d blended; disagreements %d; control: half a sample late %d"
			% [sec.level.size(), str(sec.level), n, blended, bad, late])
	_check("Q", bad == 0 and blended > 50 and sec.level.size() >= 6 and late > 50,
			"the walk is blend_at and level_at at every sample; control: offset reads disagree")


func _max_grade(p_z: PackedFloat32Array, p_from: int, p_to: int) -> float:
	var g := 0.0
	for i in range(maxi(p_from, 1), mini(p_to, p_z.size())):
		g = maxf(g, absf(p_z[i] - p_z[i - 1]))
	return g


# ---- brush arms --------------------------------------------------------------------------------------

func _type(p_lane_width: float, p_texture: int, p_priority: int) -> Pasture3DRoadType:
	var t := Pasture3DRoadType.new()
	t.lane_count = 2
	t.lane_width = p_lane_width
	t.shoulder_width = 1.0
	t.crown = 0.0
	t.cut_batter = 1.0
	t.fill_batter = 1.0
	t.surface_layer_id = p_texture
	t.priority = p_priority
	t.surface_material = StandardMaterial3D.new()
	return t


## A baked road with one segment over s 80..160, set up by `p_seg`; returns the brush, its modifier and
## the rebuilt chunk host.
func _road(p_terrain: Pasture3D, p_net: Pasture3DRoadNetwork, p_road_type: Pasture3DRoadType,
		p_seg: Pasture3DRoadSegment) -> Dictionary:
	var road := PaintRecBrush.new()
	road.name = "Sectioned"
	road.terrain = p_terrain
	road.road_road_type = p_road_type
	road.log_bake_timing = false
	road.snap_to_surface = false
	p_net.add_child(road)
	var path := Path3D.new()
	path.name = "Spline"
	var c := Curve3D.new()
	for i in 6:
		c.add_point(Vector3(X0 + 40.0 * float(i), ROAD, ZC))
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	p_seg.from_point = 2
	p_seg.to_point = 4
	var segs: Array[Pasture3DRoadSegment] = [p_seg]
	road.segments = segs
	await get_tree().process_frame
	await get_tree().process_frame
	road._refresh_owner(road._layer_owner, false, [])
	var host := Pasture3DRoadChunkHost.new()
	add_child(host)
	host.rebuild(road)
	return {"brush": road, "mod": mod, "host": host}


func _drop(p_terrain: Pasture3D, p_fx: Dictionary) -> void:
	var road: Pasture3DRoadBrush = p_fx["brush"]
	(p_fx["host"] as Node).queue_free()
	p_terrain.data.clear_layer_in_area(road._layer_id, AABB(Vector3(-2000, -1000, -2000), Vector3(4000, 2000, 4000)))
	road.get_parent().remove_child(road)
	road.free()
	await get_tree().process_frame


## The ribbon's widest reach from the centreline among LOD0 vertices within `p_tol` of x, and whether any
## vertex lies there at all (-1 when none).
func _ribbon_edge(p_host: Node, p_x0: float, p_x1: float) -> float:
	var edge := -1.0
	for ch in p_host.get_children():
		var mi := ch as MeshInstance3D
		if mi == null or not String(mi.name).begins_with("Chunk_") or mi.mesh == null:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
			if v.x >= p_x0 and v.x <= p_x1:
				edge = maxf(edge, absf(v.z - ZC))
	return edge


## The material of the chunk whose span covers `p_x`.
func _chunk_material(p_host: Node, p_x: float) -> Material:
	for ch in p_host.get_children():
		var mi := ch as MeshInstance3D
		if mi == null or not String(mi.name).begins_with("Chunk_") or mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		if p_x >= aabb.position.x and p_x <= aabb.end.x:
			return mi.mesh.surface_get_material(0)
	return null


func _ground(p_terrain: Pasture3D, p_s0: float, p_s1: float, p_off: float) -> float:
	var sum := 0.0
	var k := 0
	var s := p_s0
	while s <= p_s1 + 1e-3:
		sum += p_terrain.data.get_height(Vector3(X0 + s, 0.0, ZC + p_off))
		k += 1
		s += 10.0
	return sum / float(k)


func _brush_arms() -> void:
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

	var ta := _type(3.0, 3, 1)
	var tb := _type(5.0, 7, 4)

	# ---- the control: the same segment naming no type. Dropped before the typed road bakes, or each
	# reads the other's cut off the shared layer. --------------------------------------------------
	var plain := Pasture3DRoadSegment.new()
	var cfx := await _road(terrain, net, ta, plain)
	var ctl := _measure(terrain, cfx)
	await _drop(terrain, cfx)

	# ---- the typed segment -----------------------------------------------------------------------
	var seg := Pasture3DRoadSegment.new()
	seg.road_type = tb
	var fx := await _road(terrain, net, ta, seg)
	var brush: PaintRecBrush = fx["brush"]
	var mod: Pasture3DNodeRoad = fx["mod"]
	var host: Pasture3DRoadChunkHost = fx["host"]
	var got := _measure(terrain, fx)

	# [W]
	print("[W] widths read the stretch")
	print("    typed: sections %.2f / %.2f, profile %.2f / %.2f, graph_path %.2f / %.2f, corridor %.2f, formation %.2f"
			% [got["sec_in"], got["sec_out"], got["prof_in"], got["prof_out"], got["gp_in"], got["gp_out"],
			got["corridor"], got["formation"]])
	print("    control: sections %.2f / %.2f, profile %.2f, corridor %.2f, formation %.2f"
			% [ctl["sec_in"], ctl["sec_out"], ctl["prof_in"], ctl["corridor"], ctl["formation"]])
	_check("W", absf(got["sec_in"] - 6.0) < 1e-4 and absf(got["sec_out"] - 4.0) < 1e-4
			and absf(got["prof_in"] - 6.0) < 1e-3 and absf(got["prof_out"] - 4.0) < 1e-3
			and absf(got["gp_in"] - 6.0) < 0.05 and absf(got["gp_out"] - 4.0) < 0.05
			and got["gp_section"] and got["corridor"] > ctl["corridor"] + 1.5
			and absf(got["formation"] - 7.0) < 1e-4 and absf(ctl["formation"] - 5.0) < 1e-4
			and absf(ctl["sec_in"] - 4.0) < 1e-4 and absf(ctl["prof_in"] - 4.0) < 1e-3,
			"B's half 6 inside, A's 4 outside, in every reader; control: the untyped segment is 4 throughout")

	# [G]
	print("[G] the ground is graded to the stretch's formation")
	print("    6 m out: %.2f inside the segment, %.2f outside; control inside %.2f"
			% [got["g_in"], got["g_out"], ctl["g_in"]])
	_check("G", absf(got["g_in"] - ROAD) < 0.15 and got["g_out"] > ROAD + 0.5 and ctl["g_in"] > ROAD + 0.5,
			"road level on B's formation, batter beyond A's; control: batter at the same place")

	# [F]
	print("[F] the protected formation follows the stretch")
	var f_gw := 251
	var f_gh := 41
	var f_min_z := ZC - 20.0
	var f_mask := brush._formation_mask(f_gw, f_gh, 0.0, f_min_z, 1.0, true)
	var f_in := _protected_half(f_mask, f_gw, f_gh, int(X0 + 120.0))
	var f_out := _protected_half(f_mask, f_gw, f_gh, int(X0 + 40.0))
	var f_widest := brush.formation_half_width()
	print("    protected half-extent %.1f inside the segment, %.1f outside; formation_half_width %.2f"
			% [f_in, f_out, f_widest])
	_check("F", absf(f_in - 7.0) <= 1.0 and absf(f_out - 5.0) <= 1.0 and f_widest > f_out + 1.5,
			"B's 7 m inside, A's 5 m outside; control: the widest formation is 7, which used to cover both")

	# [M]
	print("[M] the ribbon follows the stretch")
	print("    edge %.2f inside, %.2f outside, %.2f at the boundary; segment material is B's: %s, road's is A's: %s; control inside %.2f"
			% [got["m_in"], got["m_out"], got["m_edge"], got["mat_in"] == tb.surface_material,
			got["mat_out"] == ta.surface_material, ctl["m_in"]])
	_check("M", absf(got["m_in"] - 7.0) < 0.1 and absf(got["m_out"] - 5.0) < 0.1
			and absf(got["m_edge"] - 6.0) < 0.35 and got["mat_in"] == tb.surface_material
			and got["mat_out"] == ta.surface_material and absf(ctl["m_in"] - 5.0) < 0.1,
			"7 m edge in B's stretch, 5 m in A's, between at the boundary, each with its own material; control: 5 m")

	# [P]
	print("[P] the paint follows the stretch")
	print("    typed: texture 7 on %d cell(s) in the segment and %d outside it, texture 3 on %d outside and %d inside, %d/%d of each in the transitions"
			% [got["p7_in"], got["p7_out"], got["p3_out"], got["p3_in"], got["p3_tr"], got["p7_tr"]])
	print("    control: textures %s" % str(ctl["p_textures"]))
	_check("P", got["p7_in"] > 50 and got["p7_out"] == 0 and got["p3_out"] > 50 and got["p3_in"] == 0
			and got["p3_tr"] > 0 and got["p7_tr"] > 0 and ctl["p_textures"] == [3],
			"B's texture on its stretch, A's on the road's, dithered across each transition; control: A alone")

	# [J]
	print("[J] junction runs read the stretch")
	print("    half width %.2f in / %.2f out, priority %d in / %d out; control %.2f / %d"
			% [got["j_half_in"], got["j_half_out"], got["j_prio_in"], got["j_prio_out"], ctl["j_half_in"],
			ctl["j_prio_in"]])
	_check("J", absf(got["j_half_in"] - 6.0) < 1e-4 and absf(got["j_half_out"] - 4.0) < 1e-4
			and got["j_prio_in"] == 4 and got["j_prio_out"] == 1
			and absf(ctl["j_half_in"] - 4.0) < 1e-4 and ctl["j_prio_in"] == 1,
			"B's half width and priority inside, A's outside; control: A's inside too")

	# [K] -- edits in place on the typed fixture, the same instance throughout.
	print("[K] in-place edits to the segment's type reach every cache")
	host.rebuild(brush)
	host.rebuild(brush)
	var skip0 := not host.last_rebuilt
	var a0 := brush.alignment_digest(mod)
	tb.surface_material = StandardMaterial3D.new()
	var a_mat := brush.alignment_digest(mod)
	tb.max_grade = 0.2
	var a1 := brush.alignment_digest(mod)
	# The material is a ribbon input and max_grade an alignment one: settle both before the controls.
	host.rebuild(brush)
	tb.surface_id = &"gravel"
	host.rebuild(brush)
	var skip_sid := not host.last_rebuilt
	tb.lane_width = 5.5
	host.rebuild(brush)
	var rebuilt := host.last_rebuilt
	var wider := _ribbon_edge(host, X0 + 100.0, X0 + 140.0)
	var p0 := brush.paint_signature()
	tb.kerb_width = tb.kerb_width + 0.1
	var p_kerb := brush.paint_signature()
	tb.surface_layer_id = 9
	var p1 := brush.paint_signature()
	print("    alignment digest: material edit %s, max_grade edit %s"
			% ["moved" if a_mat != a0 else "held", "moved" if a1 != a_mat else "held"])
	print("    ribbon: unchanged skipped %s, surface_id skipped %s, lane_width rebuilt %s (edge %.2f, want 7.50)"
			% [skip0, skip_sid, rebuilt, wider])
	print("    paint: kerb_width %s, surface_layer_id %s"
			% ["moved" if p_kerb != p0 else "held", "moved" if p1 != p_kerb else "held"])
	_check("K", a_mat == a0 and a1 != a_mat and skip0 and skip_sid and rebuilt and absf(wider - 7.5) < 0.1
			and p0 != 0 and p_kerb == p0 and p1 != p_kerb,
			"max_grade, lane_width and surface_layer_id each move their cache; material, surface_id and kerb_width move none")
	await _drop(terrain, fx)

	# [D]
	print("[D] a draped stretch has no ribbon")
	var td := _type(3.0, 3, 1)
	td.surface_mode = Pasture3DRoadType.SurfaceMode.TERRAIN_DRAPED
	var typed_drape := Pasture3DRoadSegment.new()
	typed_drape.road_type = td
	var tfx := await _road(terrain, net, ta, typed_drape)
	var t_in := _ribbon_edge(tfx["host"], X0 + 95.0, X0 + 145.0)
	var t_out := _ribbon_edge(tfx["host"], X0 + 20.0, X0 + 60.0)
	var t_edge := _ribbon_edge(tfx["host"], X0 + 76.0, X0 + 84.0)
	var dsec: Pasture3DRoadSections = (tfx["brush"] as Pasture3DRoadBrush).sections()
	var n := int((tfx["mod"] as Pasture3DNodeRoad).last_alignment.count())
	var rs := (tfx["brush"] as Pasture3DRoadBrush).ribbon_section(dsec, 1.0, n, 0.1)
	var sink: PackedFloat32Array = rs.get("sink", PackedFloat32Array())
	await _drop(terrain, tfx)
	var sink_ok := sink.size() > 90 and absf(sink[80] - 0.1) < 1e-4 and sink[70] < 1e-4 and sink[40] == 0.0 \
			and sink[76] > 0.0 and sink[76] < 0.1
	print("    TERRAIN_DRAPED segment: ribbon %.2f in it, %.2f outside, %.2f up to its boundary; sink at s 40/70/76/80: %s; control [M]: %.2f"
			% [t_in, t_out, t_edge, str([sink[40], sink[70], sink[76], sink[80]]) if sink.size() > 80 else "none",
			got["m_in"]])
	_check("D", t_in < 0.0 and t_out > 4.9 and t_edge > 4.9 and sink_ok and got["m_in"] > 0.0,
			"no ribbon on the draped stretch, the road's up to it, sunk toward the boundary; control: [M] has one")

	terrain.queue_free()


func _flat_terrain(p_h: float) -> Pasture3D:
	var terrain := Pasture3D.new()
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	await get_tree().process_frame
	terrain.change_region_size(RS)
	var d := terrain.data
	d.add_region_blank(Vector2i(0, 0), false)
	var r = d.get_region(Vector2i(0, 0))
	(r.get_height_map() as Image).fill(Color(p_h, 0, 0, 1))
	r.set_modified(true)
	r.calc_height_range()
	d.update_maps()
	d.calc_height_range(true)
	d.ensure_layer_stack()
	return terrain


## A half-circle road of radius 70 about the region centre, banked to the cap all round, baked by the
## native route or the GDScript one; returns the heights at three metres either side of the centreline
## across the middle of the arc, and what the faded and unfaded crown put there.
func _arc_bake(p_gdscript: bool) -> Dictionary:
	var terrain: Pasture3D = await _flat_terrain(ROAD)
	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := _type(3.0, 3, 1)
	t.crown = 0.05
	t.crown_mode = 0
	t.design_speed = 25.0
	t.max_superelevation = 0.06
	var road := Pasture3DRoadBrush.new()
	road.terrain = terrain
	road.road_road_type = t
	road.log_bake_timing = false
	road.snap_to_surface = false
	road.force_gdscript_raster = p_gdscript
	net.add_child(road)
	var path := Path3D.new()
	var c := Curve3D.new()
	# 24 Bezier segments with circular handles, as an author draws an arc. Banking it to the cap needs the
	# brush to hand the solver `plan_curvature_along`: the resampled plan's triples banked this to 0.009.
	var handle := 4.0 / 3.0 * tan(PI / 24.0 / 4.0) * 70.0
	for i in 25:
		var a := PI * float(i) / 24.0
		var tan_dir := Vector3(-sin(a), 0.0, cos(a)) * handle
		c.add_point(Vector3(128.0 + cos(a) * 70.0, ROAD, 128.0 + sin(a) * 70.0), -tan_dir, tan_dir)
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	await get_tree().process_frame
	await get_tree().process_frame
	var native := road._native_raster("stamp_road_line") and road._road_native_is_complete()
	road._refresh_owner(road._layer_owner, false, [])
	var al: Pasture3DRoadAlignment = mod.last_alignment
	var plan := road._plan_points()
	var cum := road._plan_cum()
	var total: float = cum[cum.size() - 1]
	var hw := t.half_width(2)
	var got := PackedFloat32Array()
	var faded := PackedFloat32Array()
	var unfaded := PackedFloat32Array()
	var peak_bank := 0.0
	for k in plan.size() - 1:
		var sm := (cum[k] + cum[k + 1]) * 0.5
		if sm < total * 0.35 or sm > total * 0.65:
			continue
		var a := plan[k]
		var b := plan[k + 1]
		var mid := (a + b) * 0.5
		var dir := (b - a).normalized()
		var z := al.height_at(sm)
		var bank: float = al.bank[clampi(int(round((sm - al.s0) / al.ds)), 0, al.count() - 1)]
		peak_bank = maxf(peak_bank, absf(bank))
		for off: float in [-3.0, 3.0]:
			var q := mid + Vector2(-dir.y, dir.x) * off
			var cross := (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)
			var u := 3.0 * signf(cross)
			got.append(terrain.data.get_height(Vector3(q.x, 0.0, q.y)))
			faded.append(Pasture3DRoadGrader.surface_height(z, bank, t.crown, u, hw, 0, t.max_superelevation))
			unfaded.append(Pasture3DRoadGrader.surface_height(z, bank, t.crown, u, hw, 0, 0.0))
	terrain.queue_free()
	await get_tree().process_frame
	return {"native": native, "got": got, "faded": faded, "unfaded": unfaded, "bank": peak_bank}


func _a() -> void:
	print("[A] the banked crown is the same on both routes")
	var nat := await _arc_bake(false)
	var gd := await _arc_bake(true)
	var err_nat := 0.0
	var err_gd := 0.0
	var sep := INF
	var got_n: PackedFloat32Array = nat["got"]
	for i in got_n.size():
		err_nat = maxf(err_nat, absf(got_n[i] - nat["faded"][i]))
		sep = minf(sep, absf(nat["faded"][i] - nat["unfaded"][i]))
	var got_g: PackedFloat32Array = gd["got"]
	for i in got_g.size():
		err_gd = maxf(err_gd, absf(got_g[i] - gd["faded"][i]))
	print("    routes: native %s, gdscript %s; %d cell(s), peak bank %.4f; off the faded crown: native %.4f m, gdscript %.4f m; control: faded vs unfaded at least %.4f m"
			% [nat["native"], not gd["native"], got_n.size(), nat["bank"], err_nat, err_gd, sep])
	_check("A", nat["native"] and not gd["native"] and got_n.size() >= 8 and got_g.size() == got_n.size()
			and nat["bank"] > 0.039 and err_nat < 0.02 and err_gd < 0.02 and sep > 0.05,
			"both routes grade the crown the bank has faded; control: the unfaded crown is measurably elsewhere")


## The mean height of every ribbon vertex.
func _ribbon_y(p_host: Node) -> float:
	var sum := 0.0
	var k := 0
	for ch in p_host.get_children():
		var mi := ch as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for v: Vector3 in mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			sum += v.y
			k += 1
	return sum / float(maxi(k, 1))


func _r() -> void:
	print("[R] the ribbon follows a ground change no road input saw")
	var terrain: Pasture3D = await _flat_terrain(ROAD)
	var mound := Pasture3DMound.new()
	mound.terrain = terrain
	mound.log_bake_timing = false
	add_child(mound)
	var mp := Path3D.new()
	var mc := Curve3D.new()
	for i in 8:
		var rad := float(i) * TAU / 8.0
		mc.add_point(Vector3(130.0 + cos(rad) * 40.0, 0.0, ZC + 60.0 + sin(rad) * 40.0))
	mp.curve = mc
	mound.add_child(mp)
	await get_tree().process_frame
	mound._refresh_owner(mound._layer_owner, false, [])
	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var road := Pasture3DRoadBrush.new()
	road.terrain = terrain
	road.road_road_type = _type(3.0, 3, 1)
	road.log_bake_timing = false
	road.snap_to_surface = false
	net.add_child(road)
	var path := Path3D.new()
	var c := Curve3D.new()
	for i in 6:
		c.add_point(Vector3(X0 + 40.0 * float(i), ROAD, ZC))
	path.curve = c
	road.add_child(path)
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	road.modifiers = [mod]
	await get_tree().process_frame
	await get_tree().process_frame
	road._refresh_owner(road._layer_owner, false, [])
	var host := road.ensure_chunk_host()
	host.rebuild(road)
	host.rebuild(road)
	var idle_skipped := not host.last_rebuilt
	var z0 := mod.last_alignment.height_at(100.0)
	var y0 := _ribbon_y(host)
	# Slide the mound under the road: the road's own inputs do not change, only the ground below it.
	for i in mc.point_count:
		mc.set_point_position(i, mc.get_point_position(i) - Vector3(0, 0, 60.0))
	mound._refresh_owner(mound._layer_owner, false, [])
	road._refresh_owner(road._layer_owner, false, [])
	var z1 := mod.last_alignment.height_at(100.0)
	host.rebuild(road)
	var rebuilt := host.last_rebuilt
	var y1 := _ribbon_y(host)
	print("    alignment at s 100: %.2f -> %.2f; ribbon rebuilt %s, mean y %.2f -> %.2f; control: unchanged rebuild skipped %s"
			% [z0, z1, rebuilt, y0, y1, idle_skipped])
	_check("R", z1 > z0 + 1.0 and rebuilt and y1 > y0 + 0.5 and idle_skipped,
			"the moved alignment rebuilds the ribbon; control: an unchanged road skips")
	mound.queue_free()
	terrain.queue_free()
	await get_tree().process_frame


## Everything the criteria read from one baked fixture.
func _measure(p_terrain: Pasture3D, p_fx: Dictionary) -> Dictionary:
	var brush: PaintRecBrush = p_fx["brush"]
	var mod: Pasture3DNodeRoad = p_fx["mod"]
	var host: Node = p_fx["host"]
	var out := {}
	var sec := brush.sections(mod)
	out["sec_in"] = sec.number_at(&"half", 120.0)
	out["sec_out"] = sec.number_at(&"half", 40.0)
	var prof := brush.grading_profile(mod, 1.0, 201)
	out["prof_in"] = (prof["half"] as PackedFloat32Array)[120]
	out["prof_out"] = (prof["half"] as PackedFloat32Array)[40]
	var gp := brush.graph_path()
	out["gp_in"] = NAN
	out["gp_out"] = NAN
	for i in gp.points.size():
		var x: float = gp.points[i].x
		if absf(x - (X0 + 120.0)) < 3.0:
			out["gp_in"] = gp.half_widths[i]
		elif absf(x - (X0 + 40.0)) < 3.0:
			out["gp_out"] = gp.half_widths[i]
	out["gp_section"] = not gp.sample_section.is_empty()
	out["corridor"] = brush.corridor_half_width()
	out["formation"] = brush.formation_half_width()
	out["g_in"] = _ground(p_terrain, 100.0, 140.0, 6.0)
	out["g_out"] = _ground(p_terrain, 20.0, 60.0, 6.0)
	out["m_in"] = _ribbon_edge(host, X0 + 100.0, X0 + 140.0)
	out["m_out"] = _ribbon_edge(host, X0 + 20.0, X0 + 60.0)
	out["m_edge"] = _ribbon_edge(host, X0 + 79.6, X0 + 80.4)
	out["mat_in"] = _chunk_material(host, X0 + 120.0)
	out["mat_out"] = _chunk_material(host, X0 + 40.0)
	brush.painted.clear()
	brush.paint_surface()
	var textures: Array = []
	for k in ["p7_in", "p7_out", "p3_in", "p3_out", "p3_tr", "p7_tr"]:
		out[k] = 0
	for rec: Dictionary in brush.painted:
		var tid: int = rec["texture"]
		if not textures.has(tid):
			textures.append(tid)
		for x: float in rec["xs"]:
			var s := x - X0
			var tag := "tr" if (absf(s - 80.0) < 5.0 or absf(s - 160.0) < 5.0) else (
					"in" if s > 85.0 and s < 155.0 else ("out" if s > 5.0 and s < 75.0 else ""))
			if tag == "" or (tid != 3 and tid != 7):
				continue
			out["p%d_%s" % [tid, tag]] += 1
	textures.sort()
	out["p_textures"] = textures
	var run := brush.build_run()
	out["j_half_in"] = float(Pasture3DRoadJunctionSolver._run_at(run, "half_width", 120.0, -1.0))
	out["j_half_out"] = float(Pasture3DRoadJunctionSolver._run_at(run, "half_width", 40.0, -1.0))
	out["j_prio_in"] = int(Pasture3DRoadJunctionSolver._run_at(run, "priority", 120.0, -1))
	out["j_prio_out"] = int(Pasture3DRoadJunctionSolver._run_at(run, "priority", 40.0, -1))
	return out
