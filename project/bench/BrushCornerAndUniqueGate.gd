# BrushCornerAndUniqueGate — the three brush usability changes, each with a control that fails.
#
# 1. corner_radius fillets the baked outline. Controls: the authored curve must be unchanged (the
#    fillet is on a copy); a radius far larger than the loop must clamp rather than folding the loop
#    inside out; a point the user already smoothed must keep its own shape; and the result must not
#    depend on how finely the curve tessellates, since the fillet acts on control points and the
#    polygon that reaches the rasteriser is a decimated bake of them.
# 2. corner_radius and the Make Splines Unique button are context-aware, INCLUDING on the subclasses
#    that define their own _validate_property. Control: a brush with no loop SDF (Ridge) must hide
#    corner_radius, and an unshared brush must hide the button — a gate that only checks the shown case
#    passes just as happily against a _validate_property that was never called.
# 1c. crease_smoothing blurs the distance field. Controls: it must MOVE the medial-axis crease; it must
#    leave a straight run and the rim EXACTLY where they are (the blur is the identity on a linear
#    field, and that is the whole safety argument, so it has to be measured rather than asserted); it
#    must be independent of the decimation step; and 0 must be the original field bit for bit.
# 3. A zero-length tangent's grab stub scales with its segment. Control: a SHORT segment must keep the
#    old stub exactly, so the change is confined to the span where the handle was unpickable.
#
# Every criterion increments a completion counter as well as a failure counter: a criterion that throws
# before it asserts increments neither failures nor completions, and 0 failures out of 0 criteria is not
# a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushCornerAndUniqueGate.tscn
extends Node

const Handles: Script = preload("res://addons/pasture_3d/src/brush_handles.gd")

## Grid the SDF is sampled over. Big enough that a 40 m square loop sits well inside it.
const GW := 80
const GH := 80
const VS := 1.0
const X0 := -40.0
const Z0 := -40.0
const EPS := 1.0e-4

var _fail := 0
var _done := 0


func _ready() -> void:
	print("\n=== BrushCornerAndUniqueGate ===\n")
	_check_fillet()
	_check_crease_smoothing()
	_check_property_visibility()
	_check_make_unique()
	_check_tangent_stub()
	var ok := _fail == 0 and _done == 5
	print("\n=== %s (%d failures, %d/5 criteria completed) ===\n"
		% ["BRUSH CORNER + UNIQUE PASS" if ok else "BRUSH CORNER + UNIQUE FAIL", _fail, _done])
	get_tree().quit(0 if ok else 1)


func _bad(p_msg: String) -> void:
	_fail += 1
	print("    !! %s" % p_msg)


## A 40 m axis-aligned square centred on the origin, one point per metre along each edge so the polygon
## resembles the decimated bake of a real brush curve rather than four long segments.
func _square_poly(step: float = 1.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r := 20.0
	var x := -r
	while x < r:
		out.append(Vector2(x, -r))
		x += step
	var z := -r
	while z < r:
		out.append(Vector2(r, z))
		z += step
	x = r
	while x > -r:
		out.append(Vector2(x, r))
		x -= step
	z = r
	while z > -r:
		out.append(Vector2(-r, z))
		z -= step
	return out


func _cell(p_x: float, p_z: float) -> int:
	return int(round((p_z - Z0) / VS)) * GW + int(round((p_x - X0) / VS))


func _check_fillet() -> void:
	print("[1] corner_radius fillets the baked outline without touching the authored curve:")
	var mound := Pasture3DMound.new()
	add_child(mound)
	var path := Path3D.new()
	mound.add_child(path)
	var c := Curve3D.new()
	c.closed = true
	var r := 20.0
	for v in [Vector3(-r, 0, -r), Vector3(r, 0, -r), Vector3(r, 0, r), Vector3(-r, 0, r)]:
		c.add_point(v)
	path.curve = c

	mound.corner_radius = 0.0
	var square := mound._baked_world_points(path)
	mound.corner_radius = 5.0
	var filleted := mound._baked_world_points(path)

	# The authored curve must be untouched: the gizmo, undo and the saved scene all read it.
	print("    authored point count after filleting: %d (want 4)" % path.curve.point_count)
	if path.curve.point_count != 4:
		_bad("the fillet mutated the user's curve instead of baking a copy")
	if not path.curve.get_point_position(1).is_equal_approx(Vector3(r, 0.0, -r)):
		_bad("the fillet moved an authored point")

	# EVERY corner must be cut, not just a convenient one. Index 0 is the case that matters: on a closed
	# ring its previous neighbour is the LAST point, and any wrap bug shows up there and nowhere else.
	var corners := [Vector3(-r, 0, -r), Vector3(r, 0, -r), Vector3(r, 0, r), Vector3(-r, 0, r)]
	for ci in range(corners.size()):
		var vtx: Vector3 = corners[ci]
		var near_sharp := INF
		for p in square:
			near_sharp = minf(near_sharp, p.distance_to(vtx))
		var near_round := INF
		for p in filleted:
			near_round = minf(near_round, p.distance_to(vtx))
		print("    corner %d closest baked point: sharp %.4f  filleted %.4f" % [ci, near_sharp, near_round])
		if near_round <= near_sharp + 0.1:
			_bad("corner %d was left sharp" % ci)

	# A closed loop authored with a DUPLICATED WRAP POINT (last == first) is what `_make_starter_curve`
	# builds and what every mound in the demo scene therefore has. The duplicate makes a zero-length
	# neighbour segment at both ends, so a fillet that bails on degenerate neighbours leaves exactly one
	# corner sharp — the shared start/end — and adding more points never fixes it.
	var dup := Curve3D.new()
	dup.closed = true
	for v in corners:
		dup.add_point(v)
	dup.add_point(corners[0]) # the wrap duplicate
	path.curve = dup
	mound.corner_radius = 5.0
	var dup_baked := mound._baked_world_points(path)
	for ci in range(corners.size()):
		var vtx2: Vector3 = corners[ci]
		var nearest := INF
		for q in dup_baked:
			nearest = minf(nearest, q.distance_to(vtx2))
		print("    duplicated-wrap loop, corner %d closest baked point: %.4f (want > 1.0)" % [ci, nearest])
		if nearest <= 1.0:
			_bad("corner %d left sharp on a loop with a duplicated wrap point" % ci)
	path.curve = c

	# Control: a radius far larger than the loop must clamp, not fold the loop inside out. Every baked
	# point stays within the original square's bounds.
	mound.corner_radius = 500.0
	var huge := mound._baked_world_points(path)
	var escaped := false
	for p in huge:
		if absf(p.x) > r + 0.01 or absf(p.z) > r + 0.01:
			escaped = true
	print("    radius 500 on a 40 m loop, any point outside the original square: %s (want false)" % escaped)
	if escaped:
		_bad("an over-large radius pushed the outline outside the loop it was rounding")
	if huge.size() < 8:
		_bad("the over-large radius collapsed the loop")

	# Control: a point the user has already shaped keeps ITS curvature. A fillet radius is a default for
	# untouched corners, not permission to overwrite hand-authored tangents.
	var c2 := Curve3D.new()
	c2.closed = true
	for v in [Vector3(-r, 0, -r), Vector3(r, 0, -r), Vector3(r, 0, r), Vector3(-r, 0, r)]:
		c2.add_point(v)
	c2.set_point_in(2, Vector3(0, 0, -8))
	c2.set_point_out(2, Vector3(0, 0, 8))
	path.curve = c2
	mound.corner_radius = 0.0
	var hand_sharp := mound._baked_world_points(path)
	mound.corner_radius = 5.0
	var hand_round := mound._baked_world_points(path)
	var moved := 0.0
	for i in range(mini(hand_sharp.size(), hand_round.size())):
		moved = maxf(moved, hand_sharp[i].distance_to(hand_round[i]))
	# Point 2 is smoothed by hand; points 0/1/3 are still corners and MUST move, so this control is
	# about the smoothed point specifically -- checked by asking the filleted curve for its tangents.
	var filleted_curve := mound._filleted_curve(c2, 5.0)
	var kept := false
	for i in range(filleted_curve.point_count):
		if filleted_curve.get_point_position(i).is_equal_approx(Vector3(r, 0.0, r)) \
				and filleted_curve.get_point_out(i).is_equal_approx(Vector3(0, 0, 8)):
			kept = true
	print("    hand-smoothed corner kept its own tangents: %s (want true)" % kept)
	if not kept:
		_bad("the fillet overwrote a point the user had already shaped")

	# Control: tessellation independence. The fillet acts on control points, so halving the bake
	# interval must refine the same arc rather than produce a different shape.
	path.curve = c
	mound.corner_radius = 5.0
	c.bake_interval = 0.2
	var fine := mound._baked_world_points(path)
	c.bake_interval = 0.1
	var finer := mound._baked_world_points(path)
	var worst_gap := 0.0
	for q in finer:
		var best := INF
		for w in fine:
			best = minf(best, q.distance_to(w))
		worst_gap = maxf(worst_gap, best)
	print("    bake interval halved, worst point-to-outline gap: %.4f m (want < 0.2)" % worst_gap)
	if worst_gap > 0.2:
		_bad("the filleted outline changed shape when the tessellation changed")

	mound.free()
	_done += 1


func _check_crease_smoothing() -> void:
	print("[1c] crease_smoothing softens the medial axis and moves nothing else:")
	var mound := Pasture3DMound.new()
	var poly := _square_poly()
	var res_sharp: Array = mound._signed_distance_field(poly, X0, Z0, VS, GW, GH)
	var sharp: PackedFloat32Array = res_sharp[0]
	var res_soft: Array = mound._blur_field(sharp, GW, GH, 6.0, VS)
	var soft: PackedFloat32Array = res_soft[0]

	# The crease: inside, on the diagonal in from the +X/+Z corner, where the two edges are equidistant.
	var crease := _cell(14.0, 14.0)
	print("    crease cell: sharp %.4f  smoothed %.4f  (delta %.4f)"
		% [sharp[crease], soft[crease], soft[crease] - sharp[crease]])
	if absf(soft[crease] - sharp[crease]) <= EPS:
		_bad("crease_smoothing changed nothing on the medial axis")
	elif soft[crease] >= sharp[crease]:
		_bad("smoothing raised the crease; averaging a ridge must lower it")

	# Control A: a straight run, measured at a radius whose kernel does NOT reach a corner. The field is
	# linear across a straight edge and a symmetric blur is the identity on a linear function — that is
	# the whole safety argument, so it gets measured rather than asserted.
	#
	# The radius is 2 m here, not the 6 m above, and the difference is the point: at sigma 6 on a 40 m
	# square the three box passes reach ~18 cells, so every probe on an edge sees a corner and the field
	# is genuinely NOT linear over the kernel's support. Inertness is a claim about straight runs away
	# from corners, and a probe inside a corner's reach cannot test it. At sigma 2 the reach is 5 cells
	# and the nearest corner is 14 m off, so any residual here is the operator's, not the fixture's.
	var near: PackedFloat32Array = mound._blur_field(sharp, GW, GH, 2.0, VS)[0]
	for probe in [[0.0, 26.0], [0.0, 14.0], [-6.0, 20.0]]:
		var c := _cell(probe[0], probe[1])
		var d := absf(near[c] - sharp[c])
		print("    straight-run cell (%.0f, %.0f): sharp %.4f  smoothed %.4f  (moved %.6f)"
			% [probe[0], probe[1], sharp[c], near[c], d])
		if d > 1.0e-4:
			_bad("smoothing moved a straight run, where the field is linear and a blur must be inert")

	# Control A1: EXACT inertness on a globally linear field, borders included. The safety argument is
	# "a symmetric kernel is the identity on a linear function", and that is only true if the samples the
	# kernel reads off the end of the grid continue the line. Clamp-to-edge does not: it replicates the
	# end value, which biases every cell within the kernel's reach of the border — and since the field
	# outside a loop falls away linearly, that bias lands as a step along the whole stamped rectangle.
	var ramp := PackedFloat32Array()
	ramp.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			ramp[iz * GW + ix] = float(ix) * 0.7 - float(iz) * 0.3
	var ramp_blur: PackedFloat32Array = mound._blur_field(ramp, GW, GH, 6.0, VS)[0]
	var worst_lin := 0.0
	var worst_at := 0
	for i in range(GW * GH):
		var e := absf(ramp_blur[i] - ramp[i])
		if e > worst_lin:
			worst_lin = e
			worst_at = i
	print("    linear ramp, worst cell error %.6f at (%d, %d) (want ~0 everywhere)"
		% [worst_lin, worst_at % GW, worst_at / GW])
	if worst_lin > 1.0e-3:
		_bad("the blur is not the identity on a linear field at the grid border")

	# Control A3: the blur must not depend on HOW MUCH GRID it is handed. A blur is not a local operator,
	# so a cell within the kernel's reach of the grid edge is averaged against samples that were never
	# rasterised — and the grid is only as big as the footprint. Without `_crease_blur_reach()` folded
	# into `_total_padding()` this fails by 9.67 m at 34 m of smoothing, worst at the stamped rectangle's
	# corner, which is the hard edge that shows in the viewport.
	#
	# The comparison is restricted to the region the brush actually WRITES to (the loop plus its falloff):
	# cells beyond that are outside the stamp, and requiring them to agree would just demand an infinite
	# grid. Getting that restriction wrong is what makes this control look unfixable.
	var pr := 20.0 # the fixture loop's half-width
	for sigma in [4.0, 12.0, 34.0]:
		mound.crease_smoothing = sigma
		var pad: float = 4.0 + mound._crease_blur_reach()
		var tn := int(round(2.0 * (pr + pad) / VS)) + 1
		var t0 := -pr - pad
		var slack := 120.0
		var sn := int(round(slack / VS))
		var wn := tn + 2 * sn
		var w0 := t0 - slack
		var tight: PackedFloat32Array = mound._blur_field(
			mound._signed_distance_field(poly, t0, t0, VS, tn, tn)[0], tn, tn, sigma, VS)[0]
		var wide: PackedFloat32Array = mound._blur_field(
			mound._signed_distance_field(poly, w0, w0, VS, wn, wn)[0], wn, wn, sigma, VS)[0]
		var worst_g := 0.0
		for iz in range(tn):
			if absf(t0 + float(iz) * VS) > pr + 4.0:
				continue
			for ix in range(tn):
				if absf(t0 + float(ix) * VS) > pr + 4.0:
					continue
				worst_g = maxf(worst_g, absf(tight[iz * tn + ix] - wide[(iz + sn) * wn + (ix + sn)]))
		print("    smoothing %.0f m: reach %.0f m, tight grid %d vs wide %d, worst difference %.6f"
			% [sigma, mound._crease_blur_reach(), tn, wn, worst_g])
		if worst_g > 1.0e-3:
			_bad("the blurred field depends on the grid extent at %.0f m — the footprint is too small" % sigma)
	mound.crease_smoothing = 0.0

	# Control A2: the residual is the FIXTURE's, so it must shrink as the kernel stops reaching corners.
	# Without this, "we picked a radius where it passes" and "the operator is inert" look identical.
	var c_probe := _cell(0.0, 14.0)
	var wide := absf(soft[c_probe] - sharp[c_probe])
	var tight := absf(near[c_probe] - sharp[c_probe])
	print("    same probe, sigma 6 moved %.6f vs sigma 2 moved %.6f (want the wider one larger)"
		% [wide, tight])
	if wide <= tight:
		_bad("the straight-run residual does not track the kernel's reach — it is not a corner effect")

	# Control B: the decimation step must not matter.
	var fine: PackedFloat32Array = mound._signed_distance_field(_square_poly(0.5), X0, Z0, VS, GW, GH)[0]
	var soft_fine: PackedFloat32Array = mound._blur_field(fine, GW, GH, 6.0, VS)[0]
	print("    half-step polygon, crease moved: %.6f (want ~0)" % absf(soft_fine[crease] - soft[crease]))
	if absf(soft_fine[crease] - soft[crease]) > 1.0e-3:
		_bad("the result depends on the decimation step")

	# Control C: 0 metres is the original field, bit for bit, and max_inside comes back unchanged.
	var zero: Array = mound._blur_field(sharp, GW, GH, 0.0, VS)
	var worst := 0.0
	for i in range(GW * GH):
		worst = maxf(worst, absf((zero[0] as PackedFloat32Array)[i] - sharp[i]))
	print("    crease_smoothing 0 vs original, worst cell delta: %.8f" % worst)
	if worst > 0.0:
		_bad("crease_smoothing 0 is not the original field")
	if absf(float(zero[1]) - float(res_sharp[1])) > EPS:
		_bad("max_inside changed at radius 0")

	# max_inside must be RECOMPUTED, not carried: a smoothed field peaks lower and the dome divides by it.
	print("    max_inside: sharp %.4f  smoothed %.4f (want smoothed lower)" % [float(res_sharp[1]), float(res_soft[1])])
	if float(res_soft[1]) >= float(res_sharp[1]):
		_bad("max_inside was carried over instead of recomputed from the smoothed field")

	# Cost must not scale with the radius: three box passes, so a 60 m radius does the same work as 6 m.
	var t0 := Time.get_ticks_usec()
	mound._blur_field(sharp, GW, GH, 6.0, VS)
	var t_small := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	mound._blur_field(sharp, GW, GH, 60.0, VS)
	var t_big := Time.get_ticks_usec() - t0
	print("    blur cost: 6 m %d us, 60 m %d us (want the same order)" % [t_small, t_big])
	if t_big > t_small * 4 + 2000:
		_bad("cost grows with the radius — the passes are not O(1) per cell")

	mound.free()
	_done += 1


func _has_editor_usage(p_obj: Object, p_name: String) -> bool:
	for p in p_obj.get_property_list():
		if p.name == p_name:
			return (int(p.usage) & PROPERTY_USAGE_EDITOR) != 0
	return false


func _check_property_visibility() -> void:
	print("[2] corner_radius / crease_smoothing shown only where there is a loop field:")
	var mound := Pasture3DMound.new()
	var splat := Pasture3DSplat.new()
	var plow := Pasture3DPlow.new()
	var ridge := Pasture3DRidge.new()
	# Mound and Splat both define their OWN _validate_property; if either stopped chaining super() this
	# is the criterion that notices.
	for pair in [["Mound", mound], ["Splat", splat], ["Plow", plow]]:
		for prop in ["corner_radius", "crease_smoothing"]:
			var vis := _has_editor_usage(pair[1], prop)
			print("    %s %s visible: %s (want true)" % [pair[0], prop, vis])
			if not vis:
				_bad("%s hides %s — check that its _validate_property chains super()" % [pair[0], prop])
	# Control: Ridge is a polyline brush and goes through _exact_polyline_field, which has no loop.
	for prop in ["corner_radius", "crease_smoothing"]:
		var ridge_vis := _has_editor_usage(ridge, prop)
		print("    Ridge %s visible: %s (want false)" % [prop, ridge_vis])
		if ridge_vis:
			_bad("Ridge shows %s but never rasterises a loop SDF" % prop)
	mound.free()
	splat.free()
	plow.free()
	ridge.free()
	_done += 1


func _check_make_unique() -> void:
	print("[3] Make Splines Unique appears with the warning and does the job:")
	var root := Node3D.new()
	add_child(root)
	var a := Pasture3DMound.new()
	var b := Pasture3DMound.new()
	a.name = "MoundA"
	b.name = "MoundB"
	root.add_child(a)
	root.add_child(b)
	var pa := a._new_spline()
	# The duplication trap this whole feature is about: the Path3D is copied, the Curve3D is not.
	var pb := Path3D.new()
	pb.name = "Loop1"
	pb.curve = pa.curve
	b.add_child(pb)

	# Control: a brush that shares nothing must not offer the button.
	var lone := Pasture3DMound.new()
	root.add_child(lone)
	lone._new_spline()
	var lone_vis := _has_editor_usage(lone, "_make_unique_btn")
	print("    unshared brush shows button: %s (want false)" % lone_vis)
	if lone_vis:
		_bad("the button is offered on a brush with nothing to make unique")

	var shared_vis := _has_editor_usage(b, "_make_unique_btn")
	print("    sharing brush shows button: %s (want true)" % shared_vis)
	if not shared_vis:
		_bad("the button is hidden while the shared-curve warning is up")
	if b._shared_curve_spline_names().is_empty():
		_bad("the fixture did not actually share a curve — the rest of this criterion is vacuous")

	var before: Curve3D = pb.curve
	b.make_splines_unique()
	print("    after press: same Curve3D instance: %s (want false)" % (pb.curve == before))
	if pb.curve == before:
		_bad("make_splines_unique left the shared Curve3D in place")
	if pa.curve != before:
		_bad("make_splines_unique replaced the OTHER brush's curve too")
	if pb.curve != null and pb.curve.point_count != before.point_count:
		_bad("the private copy lost points — duplicate(true) is not deep-copying")
	if not b._shared_curve_spline_names().is_empty():
		_bad("the brush still reports a shared curve after being made unique")

	root.free()
	_done += 1


func _check_tangent_stub() -> void:
	print("[4] a zero tangent's grab stub scales with its segment:")
	var h = Handles.new()
	var brush := Pasture3DRidge.new()
	add_child(brush)
	var path := Path3D.new()
	brush.add_child(path)

	# Long segment: the case the flat 3 m stub made unpickable.
	var c := Curve3D.new()
	c.add_point(Vector3.ZERO)
	c.add_point(Vector3(0.0, 0.0, 400.0))
	path.curve = c
	var long_stub: float = h._stub_offset(brush, path, 0, 2).length()
	print("    400 m segment stub: %.3f m (want 100.0)" % long_stub)
	if absf(long_stub - 100.0) > 1.0e-3:
		_bad("a long segment's stub did not scale with it")
	if long_stub <= Handles.TANGENT_STUB + EPS:
		_bad("the stub is still at (or below) the flat minimum on a 400 m segment")

	# Control: a short segment must keep EXACTLY the old behaviour, min(3, l * 0.4).
	var c2 := Curve3D.new()
	c2.add_point(Vector3.ZERO)
	c2.add_point(Vector3(0.0, 0.0, 5.0))
	path.curve = c2
	var short_stub: float = h._stub_offset(brush, path, 0, 2).length()
	var want: float = minf(Handles.TANGENT_STUB, 5.0 * 0.4)
	print("    5 m segment stub: %.3f m (want %.3f, the pre-change value)" % [short_stub, want])
	if absf(short_stub - want) > 1.0e-3:
		_bad("a short segment's stub moved — the change was supposed to be confined to long spans")

	brush.free()
	_done += 1
