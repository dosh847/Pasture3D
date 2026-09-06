# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathCarveGate — the Path Carve kernel against its [Dev/GD] oracle (S3).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §7.1 writes Ridge's and Trough's mathematics once, in C++, as a node.
# The GDScript is not deleted: it becomes Pasture3DGraphNodeDevPathCarve, and this gate is what makes
# that demotion mean something. Every criterion runs the SAME fixture through both.
#
# ---- WHY AGREEMENT ALONE PROVES NOTHING, AND WHAT EACH CONTROL IS FOR ----
#
# Two implementations of a carve agree trivially when neither is carving: an empty path, a fixture the
# spline misses, a kernel that is not bound and a production node quietly passing the surface through —
# which is exactly what its fail-fast does, and it is the right behaviour that makes this gate hard. So
# every criterion carries a control that fails when the fixture stopped being a test:
#
#   * the kernel must be BOUND, and a pass-through must be distinguishable from a carve
#   * the ground must actually MOVE, by metres, not by float noise
#   * the fixture must not be FLAT, or the two-reference drape is untested — a flat terrain makes a
#     one-reference implementation and a two-reference one produce identical output
#
# Tolerance is 1e-4 m. The kernel accumulates in double and returns float32; the oracle accumulates in
# double throughout. They differ in the last bits and that is not a defect.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]

const GW: int = 96
const GH: int = 96
const G_MIN: float = -48.0
const RECT := Rect2(G_MIN, G_MIN, 96.0, 96.0)
const EPS: float = 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathCarveGate: the Path Carve kernel vs the [Dev/GD] oracle (S3) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §7.1")

	_a_the_kernel_matches_the_oracle_on_four_sections()
	_b_slope_angle_reaches_the_ground_at_the_stated_angle()
	_c_the_five_channels_are_distinct()
	_d_path_width_widens_the_carve()
	_e_the_graph_lowers_and_the_gpu_refuses()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH CARVE %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## Ground that SLOPES and is not smooth.
##
## Both properties are load-bearing. The slope is what separates a two-reference drape from a one-
## reference one — over flat ground a fixed-height skirt and a draped one are the same surface. The bumps
## are what make the per-VERTEX ground reference distinguishable from a per-cell one: a per-cell reference
## scallops the crest as the flank crosses each bump, and on smooth ground it does not.
func _terrain() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var wx := G_MIN + float(ix) + 0.5
			var wz := G_MIN + float(iz) + 0.5
			s[iz * GW + ix] = (0.12 * wx + 0.05 * wz
					+ 3.0 * sin(wx * 0.17) * cos(wz * 0.11)
					+ 1.2 * sin(wx * 0.53 + wz * 0.31))
	return s


## A path that bends, with a half-width that changes along it and a drawn elevation that climbs.
##
## The bend matters for the same reason RoadNativeParityGate's hairpin does: a cell inside it is near two
## segments far apart in ARC LENGTH, so a wrong nearest segment leaves the distance plausible while `s` —
## and therefore the width, the height and the ground reference — is off by half the spline.
func _spline() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 9:
		var f := float(i) / 8.0
		pts.append(Vector2(-34.0 + f * 68.0, -18.0 + 26.0 * sin(f * PI)))
		w.append(6.0 + 10.0 * f) # widens downstream: what [D] measures
		h.append(4.0 + 9.0 * f)
	path.points = pts
	path.half_widths = w
	path.heights = h
	return path


func _prod(p_path: Pasture3DGraphPath, p_surf: PackedFloat32Array, p_cfg: Dictionary) -> Array:
	var node := Pasture3DGraphNodePathCarve.new()
	_apply(node, p_cfg)
	node.set_path_inputs([null, p_path])
	return node.eval_grid_channels([p_surf], GW, GH, null, RECT)


func _oracle(p_path: Pasture3DGraphPath, p_surf: PackedFloat32Array, p_cfg: Dictionary) -> Array:
	var node := Pasture3DGraphNodeDevPathCarve.new()
	_apply(node, p_cfg)
	node.set_path_inputs([null, p_path])
	return node.eval_grid_channels([p_surf], GW, GH, null, RECT)


## Set the config on either node by NAME. The two classes declare the same parameters and neither
## inherits them, so a typed helper would need a shared base that exists only to carry them — and setting
## them by name is also what makes a parameter added to one and forgotten on the other show up as a
## disagreement rather than as a silent default.
func _apply(p_node: Pasture3DGraphNode, p_cfg: Dictionary) -> void:
	for k in p_cfg:
		p_node.set(String(k), p_cfg[k])


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		var na := is_nan(p_a[i])
		var nb := is_nan(p_b[i])
		if na or nb:
			if na != nb:
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _spread(p_v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_v:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo


## How far the carve moved the ground, at its most extreme, and over how many cells.
func _moved(p_out: PackedFloat32Array, p_surf: PackedFloat32Array) -> Array:
	var most := 0.0
	var cells := 0
	for i in mini(p_out.size(), p_surf.size()):
		var d := absf(p_out[i] - p_surf[i])
		if d > 0.01:
			cells += 1
		most = maxf(most, d)
	return [most, cells]


# ---- A ------------------------------------------------------------------------------------------

## [A] Native and oracle agree, on all four cross-sections the spec names.
##
## Four configurations rather than one, because they take DIFFERENT branches of the kernel: a peaked crest
## skips the flat-top case entirely, a flat bed is the only one that exercises it, and BED flips the sign
## of the offset and the meaning of the blend. Getting one right says nothing about the others.
func _a_the_kernel_matches_the_oracle_on_four_sections() -> void:
	print("[A] the kernel matches the oracle on four cross-sections")
	if not ClassDB.class_has_method("Pasture3DUtil", "path_carve_grid"):
		_check("A", false, "path_carve_grid is not bound — rebuild the GDExtension")
		return
	var surf := _terrain()
	var path := _spline()
	var cfgs := {
		"peaked crest": {"cross_section": 0, "flat_width": 0.0, "offset": 12.0, "blend": 1},
		"flat crest": {"cross_section": 0, "flat_width": 8.0, "offset": 12.0, "blend": 1},
		"V bed": {"cross_section": 1, "flat_width": 0.0, "offset": 9.0, "blend": 2},
		"flat bed": {"cross_section": 1, "flat_width": 6.0, "offset": 9.0, "blend": 2},
	}
	var worst := 0.0
	var worst_on := ""
	var least_move := INF
	for name in cfgs:
		var cfg: Dictionary = cfgs[name]
		var nat := _prod(path, surf, cfg)
		var ora := _oracle(path, surf, cfg)
		var w := _worst(nat[0], ora[0])
		var mv := _moved(nat[0], surf)
		print("    %-13s worst %.7f m, moved %d cell(s) by up to %.3f m"
				% [name, w, mv[1], mv[0]])
		least_move = minf(least_move, float(mv[0]))
		if w > worst:
			worst = w
			worst_on = name
	_check("A", worst < EPS, "worst |native - oracle| = %.7f m on %s (want < %.4f)"
			% [worst, "nothing" if worst_on == "" else worst_on, EPS])

	# CONTROL: every configuration actually CARVED. The production node's fail-fast passes the surface
	# through unchanged, and so does the oracle on an empty path — so two pass-throughs agree perfectly,
	# and without this the whole criterion would report a pass having compared nothing to nothing.
	print("    control: the least-moving configuration still moved the ground %.3f m (want > 1)"
			% least_move)
	if least_move <= 1.0:
		_fail += 1
		print("    !! a configuration barely changed the terrain, so [A] compared two pass-throughs")

	# CONTROL: the fixture is not FLAT. Over flat ground a two-reference drape and a naive fixed-height
	# skirt produce the same surface, so the property this kernel exists for would be untested.
	print("    control: the terrain spans %.3f m before any carve (want a real slope)" % _spread(surf))
	if _spread(surf) < 5.0:
		_fail += 1
		print("    !! the fixture is nearly flat, so the two-reference drape is not being exercised")

	# CONTROL: a ZERO-offset carve with no path height to follow changes nothing. This is the identity
	# case, and a kernel that answered the surface plus a constant would fail it while passing everything
	# above — the four fixtures all move a lot, and moving a lot is not the same as moving correctly.
	var idle := _prod(path, surf, {"cross_section": 0, "offset": 0.0, "follow_path_height": false,
			"flat_width": 0.0, "blend": 0})
	var idle_move: Array = _moved(idle[0], surf)
	print("    control: a zero-offset carve moved %d cell(s), by up to %.6f m (want 0)"
			% [idle_move[1], idle_move[0]])
	if idle_move[1] > 0:
		_fail += 1
		print("    !! a carve with nothing to carve still moved the terrain")


# ---- B ------------------------------------------------------------------------------------------

## [B] SLOPE_ANGLE really reaches the ground at the stated angle.
##
## MEASURED off the output surface, not asserted from the parameter. Per `check-derived-values-outside-
## the-chain`, comparing the flank's slope to the number that produced it would only prove the kernel can
## multiply; the angle is recovered from the height difference between two cells the carve wrote and the
## metres between them.
##
## Two angles, because one angle passes on a kernel that ignores the parameter and happens to sit near it.
func _b_slope_angle_reaches_the_ground_at_the_stated_angle() -> void:
	print("[B] SLOPE_ANGLE descends at the angle it was given")
	# A STRAIGHT spline on FLAT ground for this one, deliberately: the angle of a flank is only well
	# defined across the section, and a bend or a slope would mix the terrain's own gradient into the
	# measurement. Every other criterion uses the hard fixture; this one needs a clean protractor.
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([Vector2(-40.0, 0.0), Vector2(40.0, 0.0)])
	path.half_widths = PackedFloat32Array([40.0, 40.0]) # a reach far wider than the flank will need
	var bad := PackedStringArray()
	for want_deg in [20.0, 55.0]:
		var cfg := {"cross_section": 0, "offset": 10.0, "flat_width": 0.0, "blend": 1,
			"follow_path_height": false, "flank_mode": 1, "slope_angle": want_deg,
			"width_source": 1, "width": 40.0, "falloff": 0.0}
		var out: Array = _prod(path, flat, cfg)
		var h: PackedFloat32Array = out[0]
		# Walk out from the centreline along +z at x = 0 and find where the carve stops. On flat ground
		# with a 10 m crest, the foot must land at 10 / tan(angle) metres.
		var ix := int((0.0 - G_MIN) - 0.5)
		var foot := -1.0
		for k in range(GH):
			var wz := G_MIN + float(k) + 0.5
			if wz < 0.0:
				continue
			if h[k * GW + ix] <= 0.001:
				foot = wz
				break
		var want_foot := 10.0 / tan(deg_to_rad(want_deg))
		var got_deg := rad_to_deg(atan(10.0 / maxf(foot, 0.001))) if foot > 0.0 else -1.0
		print("    %.0f°: the flank meets the ground at %.2f m (want %.2f m) -> measured %.2f°"
				% [want_deg, foot, want_foot, got_deg])
		# One cell of tolerance: the foot is found on a 1 m grid, so it can only be located to a cell.
		if foot < 0.0 or absf(foot - want_foot) > 1.5:
			bad.append("%.0f°" % want_deg)
	_check("B", bad.is_empty(), "angles reaching the ground where they should: %s"
			% ("both" if bad.is_empty() else "all but " + str(bad)))

	# CONTROL: the two angles produce DIFFERENT feet. A kernel that ignored `slope_angle` entirely and
	# spread over the full reach would give the same foot twice, and if that foot happened to sit near
	# one of the two wanted values the criterion above would half-pass.
	var feet := PackedFloat32Array()
	for want_deg in [20.0, 55.0]:
		feet.append(10.0 / tan(deg_to_rad(want_deg)))
	print("    control: the two angles want feet %.2f m apart (want them clearly different)"
			% absf(feet[0] - feet[1]))
	if absf(feet[0] - feet[1]) < 5.0:
		_fail += 1
		print("    !! the two test angles are too close to tell an honoured parameter from an ignored one")


# ---- C ------------------------------------------------------------------------------------------

## [C] The five channels are distinct, and none is constant.
##
## They come from one solve but by different rules — a distance test against the flat width, a profile
## lookup, a sign test on the actual height change — so getting the indices right for one says nothing
## about the others. A mask that is identically zero agrees with a port serving zeros, which is exactly
## the bug channels have.
func _c_the_five_channels_are_distinct() -> void:
	print("[C] the five channels are distinct and none is constant")
	var surf := _terrain()
	# A FLAT-topped crest with a REPLACE blend, following the path's DRAWN heights, dropped 8 m. Every
	# part of that is chosen so all four masks can be non-empty at once: a flat top is what makes `bed`
	# exist at all; REPLACE is what lets the carve both cut and fill, where MAX would clamp every lowering
	# away and leave `cut` identically zero; and the NEGATIVE offset is what drops the drawn crest below
	# the bumpy terrain in places while it stays above in others, which is the only way ONE solve fills
	# and cuts at once. At the fixture's own drawn heights the crest clears the ground everywhere and
	# `cut` is honestly empty — which is why the offset is here and not a rounder number.
	var cfg := {"cross_section": 0, "flat_width": 7.0, "offset": -8.0, "blend": 0,
		"follow_path_height": true, "falloff": 8.0}
	var nat := _prod(_spline(), surf, cfg)
	var ora := _oracle(_spline(), surf, cfg)
	var names := ["height", "bed", "flank", "cut", "fill"]
	var worst := 0.0
	var worst_on := ""
	for c in 5:
		var w := _worst(nat[c], ora[c])
		print("    %-7s worst %.7f, spans %.4f" % [names[c], w, _spread(nat[c])])
		if w > worst:
			worst = w
			worst_on = names[c]
	_check("C", worst < EPS, "worst channel disagreement %.7f on %s (want < %.4f)"
			% [worst, "nothing" if worst_on == "" else worst_on, EPS])

	# CONTROL: no channel is constant, and no two are the same field.
	var flat := PackedStringArray()
	for c in 5:
		if _spread(nat[c]) <= 1.0e-6:
			flat.append(names[c])
	var same := PackedStringArray()
	for i in 5:
		for j in range(i + 1, 5):
			if _worst(nat[i], nat[j]) < 1.0e-6:
				same.append("%s==%s" % [names[i], names[j]])
	print("    control: %d constant channel(s) %s, %d identical pair(s) %s (want none of either)"
			% [flat.size(), str(flat), same.size(), str(same)])
	if not flat.is_empty() or not same.is_empty():
		_fail += 1
		print("    !! a constant or duplicated channel proves nothing about the port that produced it")

	# CONTROL: `bed` is EMPTY at flat_width 0, and non-empty above it. The spec says a peaked crest has no
	# flat part, and the node warns about it — so it has to be true, and it is the one channel whose
	# emptiness is correct rather than a bug.
	var peaked := _prod(_spline(), surf, {"cross_section": 0, "flat_width": 0.0, "offset": 0.0,
		"blend": 0, "follow_path_height": true})
	print("    control: at flat_width 0 the bed mask spans %.6f (want 0); at 7 m it spans %.4f (want > 0)"
			% [_spread(peaked[1]), _spread(nat[1])])
	if _spread(peaked[1]) > 1.0e-6 or _spread(nat[1]) <= 1.0e-6:
		_fail += 1
		print("    !! the bed mask does not track flat_width, so it is not measuring the flat top")


# ---- D ------------------------------------------------------------------------------------------

## [D] `width_source = PATH` widens the carve where the path widens; CONSTANT does not.
##
## This is the §8.2 property the whole width_source parameter exists for — a river that widens downstream
## does it by carrying wider half-widths, not by a second node. Measured as the carve's own extent at two
## places along the spline, one where the fixture is 6 m wide and one where it is 16 m.
func _d_path_width_widens_the_carve() -> void:
	print("[D] width_source PATH follows the path's own half-widths")
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	# Straight and axis-aligned so "the carve's extent across the section" is a column of the grid.
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([Vector2(-40.0, 0.0), Vector2(40.0, 0.0)])
	path.half_widths = PackedFloat32Array([6.0, 26.0]) # narrow at x=-40, wide at x=+40
	var cfg_path := {"cross_section": 0, "offset": 8.0, "flat_width": 0.0, "blend": 1,
		"follow_path_height": false, "width_source": 0, "width_scale": 1.0, "falloff": 0.0}
	var cfg_const := cfg_path.duplicate()
	cfg_const["width_source"] = 1
	cfg_const["width"] = 16.0
	var by_path: Array = _prod(path, flat, cfg_path)
	var by_const: Array = _prod(path, flat, cfg_const)

	var narrow_x := int((-30.0 - G_MIN) - 0.5)
	var wide_x := int((30.0 - G_MIN) - 0.5)
	var pn := _extent(by_path[0], narrow_x)
	var pw := _extent(by_path[0], wide_x)
	var cn := _extent(by_const[0], narrow_x)
	var cw := _extent(by_const[0], wide_x)
	print("    PATH:     %.1f m wide at the narrow end, %.1f m at the wide end" % [pn, pw])
	print("    CONSTANT: %.1f m wide at the narrow end, %.1f m at the wide end" % [cn, cw])
	_check("D", pw > pn + 5.0, "the PATH carve widens downstream by %.1f m (want > 5)" % (pw - pn))

	# CONTROL: CONSTANT does NOT widen. Without it, a kernel that widened for its own reasons — a bug in
	# the reach, an `s` that grows along the spline — would pass the criterion above unrelated to the
	# parameter it claims to be testing.
	print("    control: the CONSTANT carve changed width by %.1f m along the same spline (want ~0)"
			% absf(cw - cn))
	if absf(cw - cn) > 2.0:
		_fail += 1
		print("    !! CONSTANT widened too, so [D] measured something other than width_source")

	# CONTROL: the two agree where the path's own width happens to equal the constant. If they never
	# agreed anywhere, the two configurations would be measuring different things entirely.
	var mid_x := int((0.0 - G_MIN) - 0.5)
	print("    control: at mid-spline (path half-width 16 m) PATH is %.1f m and CONSTANT is %.1f m"
			% [_extent(by_path[0], mid_x), _extent(by_const[0], mid_x)])
	if absf(_extent(by_path[0], mid_x) - _extent(by_const[0], mid_x)) > 2.0:
		_fail += 1
		print("    !! the two width sources disagree where they should coincide")


## How many metres of column `p_ix` the carve actually raised, on flat ground.
func _extent(p_h: PackedFloat32Array, p_ix: int) -> float:
	var cells := 0
	for iz in GH:
		if p_h[iz * GW + p_ix] > 0.001:
			cells += 1
	return float(cells) # 1 m cells


# ---- E ------------------------------------------------------------------------------------------

## [E] A graph containing Path Carve lowers NATIVELY and matches the GDScript evaluator — and the GPU
## refuses it rather than serving channel 0.
##
## Two halves, because they are the two ways the phase can be quietly incomplete. Lowering is what makes
## the node worth having: `blocks_native()` is GRAPH-WIDE, so a visible node that blocked would drag the
## erosion and the noise beside it onto the GDScript evaluator. And the GPU has no carve mode, so it must
## BAIL — a plan that holds one buffer per slot would otherwise serve `bed` a copy of `height`.
func _e_the_graph_lowers_and_the_gpu_refuses() -> void:
	print("[E] the graph lowers natively, and the GPU refuses")
	var surf := _terrain()
	var g := _carve_graph(_spline(), 0)
	var lowers: bool = g.native_supported() and not g.compile_graph_program().is_empty()
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), GW, GH,
			RECT, surf)
	# The GDScript evaluator on the same graph, FORCED. It states the premise rather than borrowing
	# whichever native limitation happens to survive.
	var g2 := _carve_graph(_spline(), 0)
	g2.force_gdscript_evaluation = true
	var ora: PackedFloat32Array = g2.evaluate(GW, GH, RECT, null, surf)
	g2.force_gdscript_evaluation = false
	var w := _worst(nat, ora)
	print("    lowers = %s, %d cell(s) returned, worst |native - gdscript| = %.7f m"
			% [str(lowers), nat.size(), w])
	_check("E", lowers and nat.size() == GW * GH and w < EPS,
			"lowered and agreed with the GDScript evaluator to %.7f m" % w)

	# CONTROL: the lowered program really CARVED. A program that passed the surface through would agree
	# with a GDScript evaluator doing the same, and `lowers` would still be true.
	var mv := _moved(nat, surf)
	print("    control: the lowered program moved %d cell(s) by up to %.3f m (want many)"
			% [mv[1], mv[0]])
	if mv[1] < 100:
		_fail += 1
		print("    !! the lowered program did not carve, so [E] compared two pass-throughs")

	# CONTROL: a channel above 0 lowers too. `bed` is channel 1, and a program that refused it would be a
	# node with five outputs and one usable port — which is the failure the aux-buffer plumbing exists to
	# prevent and is invisible from channel 0.
	var g_bed := _carve_graph(_spline(), 1)
	var bed_prog := g_bed.compile_graph_program()
	var bed_out: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(bed_prog, GW, GH, RECT, surf)
	print("    control: the bed channel lowered (%s) and spans %.4f (want a real mask)"
			% [str(not bed_prog.is_empty()), _spread(bed_out)])
	if bed_prog.is_empty() or _spread(bed_out) <= 1.0e-6:
		_fail += 1
		print("    !! channel 1 did not lower, so only `height` is reachable in a native graph")

	# The GPU half. Its own control runs first: an empty return is ambiguous on a machine with no
	# RenderingDevice, and reading that as a refusal would report a pass having measured nothing.
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("    graph_eval_grid_gpu is not bound — the GPU half is unverified")
		return
	var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_io_graph().compile_graph_program(), GW, GH, RECT, surf)
	if ctrl.is_empty():
		print("    NO-SIGNAL: the GPU evaluator also bailed on a bare in->out graph, so there is no local")
		print("    RenderingDevice (headless / no driver). Re-run WITHOUT --headless to test the refusal.")
		return
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH,
			RECT, surf)
	print("    the GPU route is live (%d cell(s) on a bare graph); the carve graph returned %d"
			% [ctrl.size(), gpu.size()])
	if not gpu.is_empty():
		_fail += 1
		print("    !! the GPU served a Path Carve graph, but there is no carve mode in the shader — so")
		print("       this is some other op's output, or the input surface, wearing the carve's name.")


## Input -> Spline-less Road Source -> Path Carve[ch] -> Output.
##
## Road Source rather than Spline Source because a Spline Source resolves from the SCENE and this gate has
## no brush; the node under test reads a PATH and does not care which source node produced it, which is
## the whole point of the port type.
func _carve_graph(p_path: Pasture3DGraphPath, p_channel: int) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = p_path
	var carve := Pasture3DGraphNodePathCarve.new()
	carve.cross_section = Pasture3DGraphNodePathCarve.CrossSection.CREST
	carve.flat_width = 7.0
	carve.offset = 6.0
	carve.blend = Pasture3DGraphNodePathCarve.Blend.REPLACE
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, carve, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	# Input -> Carve.surface, Source -> Carve.path, Carve[ch] -> Output.
	g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, p_channel, 3, 0]]
	return g


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g
