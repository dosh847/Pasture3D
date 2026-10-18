# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerOutsideBrushGate — a Leveler with an OUTSIDE feather, inside a brush graph that reads the brush's
# own outline, builds its wall on the terrain BEYOND the outline, at the wall's own profile.
#
# The bug: the brush wrote only inside its outline (plus `modifier_margin`), so the outward wall was solved
# and then cropped at the rim. The fix: the graph reports `outward_reach()`, the brush widens its footprint
# by it, and the graph composites at 1 across that band so the brush's own ramp does not taper it again.
#
#   R  REACH: probes 3/6/9 m outside the rim are raised; a probe past feather + 3 m is untouched. CONTROL:
#      the same probes under an INSIDE feather read no rise (the probes can see a cropped wall).
#   T  NO TAPER: on the native route the probe heights follow base + (level - base) * (1 - smoothstep(d/F)),
#      with the rim cell at the level. CONTROL: the same heights against a profile tapered once more (w²)
#      must miss, so the tolerance can tell one taper from two.
#   P  PARITY: the GDScript raster matches the native one at every probe.
#   M  the brush's effective margin is the feather with modifier_margin 0, and 0 under INSIDE.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/LevelerOutsideBrushGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE := Vector3(200.0, 0.0, 160.0)
const HALF := 30.0
const FEATHER := 12.0
const LIFT := 15.0
const CRITERIA := 4

var _fail := 0
var _ran := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== LevelerOutsideBrushGate: an OUTSIDE wall is written past the brush outline ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	_run()
	if _ran != CRITERIA:
		_fail += 1
		print("\n!! only %d of %d criteria completed" % [_ran, CRITERIA])
	print("\n=== %s (%d failures, %d/%d criteria ran) ===\n" % [
		"LEVELER OUTSIDE BRUSH PASS" if _fail == 0 else "LEVELER OUTSIDE BRUSH FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(0 if _fail == 0 else 1)


func _run() -> void:
	if not is_finite(_height(SITE)):
		print("!! no terrain at %s; the fixture is outside demo/data" % SITE)
		return
	var mound: Pasture3DMound = _make_mound()
	# Probes on the +X midline, measured from the rim. The rim is the straight edge x = SITE.x + HALF, so
	# the signed distance is exact there and no corner rounding is involved.
	var rim_x := SITE.x + HALF
	var ds: Array[float] = [-1.0, 3.0, 6.0, 9.0, FEATHER + 3.0]
	var probes: Array[Vector3] = []
	for d in ds:
		probes.append(Vector3(snappedf(rim_x + d, _vs), 0.0, snappedf(SITE.z, _vs)))
	var none: Array[Pasture3DNode] = []
	mound.modifiers = none
	var base := _bake(mound, probes)
	var target := -INF
	for b in base:
		target = maxf(target, b)
	target += LIFT # above every probe, so the default MAX blend keeps the whole wall

	var gmod := _graph_mod(target)
	var lev := gmod.graph.nodes[1] as Pasture3DGraphNodeLevelerBase
	mound.modifiers = [gmod] as Array[Pasture3DNode]

	# [M]
	print("[M] the brush widens its footprint by the wall")
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.INSIDE
	var m_in: float = mound._effective_modifier_margin()
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE
	var m_out: float = mound._effective_modifier_margin()
	print("    effective margin: INSIDE %.2f m, OUTSIDE %.2f m (want 0 and %.1f)" % [m_in, m_out, FEATHER])
	if absf(m_in) > 1e-6 or absf(m_out - FEATHER) > 1e-6:
		_fail += 1
		print("    !! the margin does not follow the Leveler's outward reach")
	_ran += 1

	mound.force_gdscript_raster = false
	var native := _bake(mound, probes)
	mound.force_gdscript_raster = true
	var oracle := _bake(mound, probes)
	mound.force_gdscript_raster = false
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.INSIDE
	var inside := _bake(mound, probes)
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE

	# [R]
	print("[R] the wall reaches past the rim, and stops at the feather")
	for i in ds.size():
		print("    d %+5.1f m: base %.3f  OUTSIDE %+.3f  INSIDE %+.3f" % [ds[i], base[i],
				native[i] - base[i], inside[i] - base[i]])
	var reach_ok := true
	for i in [1, 2, 3]:
		if not (native[i] - base[i] > 0.5):
			reach_ok = false
	if not (native[1] > native[2] and native[2] > native[3]):
		reach_ok = false
	if absf(native[4] - base[4]) > 1e-3:
		reach_ok = false
		print("    !! ground past the feather moved")
	if not reach_ok:
		_fail += 1
		print("    !! the outward wall is missing, cropped or not falling away from the rim")
	var ctrl_rise := 0.0
	for i in [1, 2, 3]:
		ctrl_rise = maxf(ctrl_rise, absf(inside[i] - base[i]))
	print("    control: INSIDE wall moves the outside probes by at most %.4f m (want < 0.01)" % ctrl_rise)
	if ctrl_rise >= 0.01:
		_fail += 1
		print("    !! control dead: the probes cannot tell a cropped wall from a reaching one")
	_ran += 1

	# [T]
	print("[T] the wall follows its own profile, tapered once")
	var tol := 0.08 * LIFT
	var worst := 0.0
	var worst_sq := 0.0
	for i in [1, 2, 3]:
		var x := clampf(ds[i] / FEATHER, 0.0, 1.0)
		var w := 1.0 - x * x * (3.0 - 2.0 * x)
		worst = maxf(worst, absf(native[i] - (base[i] + (target - base[i]) * w)))
		worst_sq = maxf(worst_sq, absf(native[i] - (base[i] + (target - base[i]) * w * w)))
	var rim_err := absf(native[0] - target)
	print("    rim cell vs level: %.4f m; wall vs profile: worst %.3f m (tol %.2f)" % [rim_err, worst, tol])
	print("    control: wall vs a twice-tapered profile: worst %.3f m (want > tol)" % worst_sq)
	if rim_err > 0.01 or worst > tol:
		_fail += 1
		print("    !! the wall is tapered, offset or not at the level at the rim")
	if worst_sq <= tol:
		_fail += 1
		print("    !! control dead: the tolerance cannot tell one taper from two")
	_ran += 1

	# [P]
	print("[P] GDScript raster matches native")
	var gap := 0.0
	for i in ds.size():
		gap = maxf(gap, absf(native[i] - oracle[i]))
	print("    worst native vs GDScript: %.6f m (want < 1e-3)" % gap)
	if gap >= 1e-3:
		_fail += 1
		print("    !! the two rasterisers build different walls")
	_ran += 1


func _graph_mod(p_target: float) -> Pasture3DNodeGraph:
	var lev := Pasture3DGraphNodeLeveler.new()
	lev.mode = Pasture3DGraphNodeLevelerBase.Mode.LEVEL_AT_HEIGHT
	lev.target_height = p_target
	lev.feather_side = Pasture3DGraphNodeLevelerBase.FeatherSide.OUTSIDE
	lev.feather = FEATHER
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), lev, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	var m := Pasture3DNodeGraph.new()
	m.graph = g
	m.strength = 1.0
	m.evaluation = Pasture3DNode.Evaluation.LIVE
	return m


func _make_mound():
	var mound := Pasture3DMound.new()
	mound.name = "LevelerOutside"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = SITE
	mound.height = 0.0
	mound.modifier_margin = 0.0
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_probes:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
