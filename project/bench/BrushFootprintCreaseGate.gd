# BrushFootprintCreaseGate — crease_smoothing rounds the crease the FOOTPRINT makes, measured on baked
# terrain rather than on the profile table that produces it.
#
# WHY THIS EXISTS ALONGSIDE BrushCornerAndUniqueGate [1d]. That criterion calls `_crease_profile_table`
# itself and asserts on what came back. It proves the table is right and says NOTHING about whether a bake
# ever consults it — the mound could ignore the table entirely and [1d] would still pass. This gate sets a
# property, bakes, and reads heights back out of the terrain.
#
# THE PROBE POSITION IS THE WHOLE ARGUMENT. `crease_smoothing` has two halves: it blurs the distance field
# (the medial axis) and, since this change, it blurs the profile against distance (the footprint rim). Both
# are driven by the one property, so they cannot be separated by switching something off — they are
# separated by WHERE you measure. The probes sit on a STRAIGHT RUN just outside the rim, 60 m from the
# nearest corner, because across a straight edge the distance field is linear and a symmetric blur is the
# identity on a linear function. Criterion C measures that inertness on THIS fixture's own geometry rather
# than borrowing the claim from [1c], so a probe accidentally placed within a corner's reach fails C
# instead of quietly making B meaningless.
#
# Criteria:
#   A  THE FLOOR: every probe reads real terrain, and at 0 m of smoothing the brush stops at its outline —
#      the outside probes are still bare ground. Without A, B could be measuring a brush that always wrote
#      out there, and "it moved" would mean nothing.
#   B  THE HEADLINE: with smoothing on, those outside probes carry brush height. The foot rounds out onto
#      the ground instead of ending on a hard line.
#   C  THE CONTROL that makes B mean what it says: at these same probes the blurred field equals the sharp
#      field, so the medial-axis half is inert here and what B measured is the footprint half.
#   D  the plateau does not move: a symmetric kernel is the identity where the shape is already flat.
#   E  the rounded foot lands INSIDE the padding: past `_crease_blur_reach` the ground is untouched.
#
# Every criterion increments a completion counter as well as a failure counter: a criterion that throws
# before it asserts increments neither, and 0 failures out of 0 criteria is not a pass.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushFootprintCreaseGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const SITE := Vector3(300.0, 0.0, 300.0)
## Half-extent of the square loop, metres. Corners sit at (±HALF, ±HALF), so a probe at x = 0 is HALF
## metres from the nearest one — that distance is what criterion C is about.
const HALF := 60.0
const FALLOFF := 15.0
const HEIGHT := 30.0
const SMOOTH := 12.0
## "Moved" and "did not move", metres. The rim lift is metres of a 30 m mound; the inert cases are exact
## in principle and get a float32 tolerance rather than an equality.
const MOVED := 0.05
const INERT := 1.0e-4
## "Did not move" for the PLATEAU specifically, and why it is not `INERT`. A and E probe cells that
## nothing wrote, so they are exact. The plateau is a value that went THROUGH the blur's running sums,
## and carries that kernel's float32 drift: BrushCornerAndUniqueGate [1c] measures the same drift as
## 2.3e-5 on a unit field and allows 1e-3 for it. Scaled by the mound's height that is sub-millimetre,
## while a plateau the kernel really bit would move by METRES — so this still fails by three orders of
## magnitude if the smoothing ever stops being the identity on a flat top.
const PLATEAU_INERT := HEIGHT * 1.0e-4

var _fail := 0
var _done := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== BrushFootprintCreaseGate: the footprint's own crease, measured on baked ground ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_run()

	if _done != 5:
		_fail += 1
		print("\n    !! only %d of 5 criteria completed" % _done)
	print("\n=== %s (%d failures) ===\n"
		% ["FOOTPRINT CREASE PASS" if _fail == 0 else "FOOTPRINT CREASE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _bad(p_msg: String) -> void:
	_fail += 1
	print("    !! %s" % p_msg)


func _run() -> void:
	# Probes on the +Z straight run, 1..4 m OUTSIDE the outline. Nothing should reach them without the
	# footprint half of the smoothing.
	var outside: Array[Vector3] = []
	for k in [1.0, 2.0, 3.0, 4.0]:
		outside.append(Vector3(SITE.x, 0.0, SITE.z + HALF + k))
	var centre := Vector3(SITE.x, 0.0, SITE.z)

	var mound = _make_mound()
	if mound == null:
		return
	# The reach is a property of the RADIUS and the spacing, so it is known before any bake — but only
	# while the radius is actually set. Reading it off the fixture in the 0 m state criterion A needs
	# reported a 0 m reach and put E's probe 3 m outside the loop: inside the very foot E exists to bound,
	# where it duly measured the foot and called it a failure. So the radius goes on, the reach comes off
	# it, and the fixture goes back to 0 m for A.
	mound.crease_smoothing = SMOOTH
	var reach: float = mound._crease_blur_reach()
	mound.crease_smoothing = 0.0
	var far := Vector3(SITE.x, 0.0, SITE.z + HALF + reach + 3.0)
	if not is_finite(_height(far)):
		_bad("the far probe is outside demo/data; criterion E cannot answer")
		return
	var bare_out := _heights(outside)
	var bare_centre := _height(centre)
	var bare_far := _height(far)

	# ---- A: the floor ------------------------------------------------------------------------------
	print("[A] every probe reads terrain, and at 0 m the brush stops at its outline:")
	mound.crease_smoothing = 0.0
	_bake(mound)
	var sharp_out := _heights(outside)
	var sharp_centre := _height(centre)
	if not _all_finite(bare_out) or not is_finite(bare_centre) or not is_finite(sharp_centre):
		_bad("a probe read no terrain; the fixture is outside demo/data")
		return
	print("    plateau: bare %.3f m -> baked %.3f m (the brush is really stamping)"
		% [bare_centre, sharp_centre])
	if absf(sharp_centre - bare_centre) < 1.0:
		_bad("the mound did not raise its own plateau — nothing below is measuring a bake")
		return
	var worst_sharp := _worst(bare_out, sharp_out)
	print("    outside probes at 0 m smoothing, worst move from bare ground: %.6f m (want 0)" % worst_sharp)
	if worst_sharp > INERT:
		_bad("the un-smoothed brush already writes outside its outline — B would measure nothing new")
		return
	_done += 1

	# ---- B: the headline ---------------------------------------------------------------------------
	print("\n[B] with smoothing on, the foot rounds out past the outline:")
	mound.crease_smoothing = SMOOTH
	_bake(mound)
	var soft_out := _heights(outside)
	var lifted := true
	for i in range(outside.size()):
		var d := soft_out[i] - bare_out[i]
		print("    %.0f m outside: bare %.3f m -> %.3f m (lifted %.4f m)"
			% [outside[i].z - SITE.z - HALF, bare_out[i], soft_out[i], d])
		if d <= MOVED:
			lifted = false
	if not lifted:
		_bad("the rim still ends at the outline — the footprint crease was not smoothed")
	_done += 1

	# ---- C: the control ----------------------------------------------------------------------------
	# The distance field at these probes, blurred and sharp. If the field half moves them, B measured the
	# medial-axis blur and not the footprint at all.
	print("\n[C] the field half is inert at these probes, so B is the footprint half:")
	var worst_field := _field_shift(outside)
	print("    worst |blurred - sharp| distance field at the probes: %.6f m (want ~0)" % worst_field)
	if worst_field > 1.0e-3:
		_bad("the blurred field moves at these probes — they are within a corner's reach and B is confounded")
	_done += 1

	# ---- D: the plateau ----------------------------------------------------------------------------
	print("\n[D] the plateau does not move (the kernel is the identity where the shape is flat):")
	var soft_centre := _height(centre)
	print("    plateau: sharp %.6f m  smoothed %.6f m (moved %.6f)"
		% [sharp_centre, soft_centre, absf(soft_centre - sharp_centre)])
	if absf(soft_centre - sharp_centre) > PLATEAU_INERT:
		_bad("smoothing moved the plateau, where a symmetric kernel must be the identity")
	_done += 1

	# ---- E: the foot lands inside the padding ------------------------------------------------------
	print("\n[E] past the kernel's reach the ground is untouched:")
	var soft_far := _height(far)
	print("    reach %.0f m; probe %.0f m outside: bare %.6f m -> %.6f m (moved %.6f)"
		% [reach, reach + 3.0, bare_far, soft_far, absf(soft_far - bare_far)])
	if absf(soft_far - bare_far) > INERT:
		_bad("the foot reaches past _crease_blur_reach — the footprint is not padded for what it writes")
	_done += 1


# ---- fixture ------------------------------------------------------------------------------------------


func _make_mound():
	var reach := HALF + SMOOTH * 4.0
	for c in [Vector3(-reach, 0, -reach), Vector3(reach, 0, -reach), Vector3(reach, 0, reach),
			Vector3(-reach, 0, reach), Vector3.ZERO]:
		if not is_finite(_height(SITE + c)):
			_bad("no terrain at %s; the fixture is outside demo/data" % (SITE + c))
			return null
	var mound := Pasture3DMound.new()
	mound.name = "FootprintCrease"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = SITE
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

	# A capped mound with a falloff narrower than its half-width: a flat top (criterion D) and a rim that
	# is a hard join at 0 m of smoothing (criteria A and B). No modifier stack — this gate is about the
	# brush's own shape, and a stack would put other things between the property and the ground.
	mound.height = HEIGHT
	mound.capped = true
	mound.falloff_width = FALLOFF
	mound.corner_radius = 0.0
	mound.relative_to_terrain = true
	mound.crease_smoothing = 0.0
	return mound


func _bake(p_mound) -> void:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])


## The loop's distance field at `p_at`, sharp and blurred, worst absolute difference. The same polygon the
## brush stamps, sampled on its own grid — criterion C's measurement.
func _field_shift(p_at: Array[Vector3]) -> float:
	var gw := int(round((HALF * 4.0) / _vs)) + 1
	var min_x := SITE.x - HALF * 2.0
	var min_z := SITE.z - HALF * 2.0
	var poly := PackedVector2Array()
	var step := _vs
	var x := -HALF
	while x < HALF:
		poly.append(Vector2(SITE.x + x, SITE.z - HALF))
		x += step
	var z := -HALF
	while z < HALF:
		poly.append(Vector2(SITE.x + HALF, SITE.z + z))
		z += step
	x = HALF
	while x > -HALF:
		poly.append(Vector2(SITE.x + x, SITE.z + HALF))
		x -= step
	z = HALF
	while z > -HALF:
		poly.append(Vector2(SITE.x - HALF, SITE.z + z))
		z -= step
	var probe := Pasture3DMound.new()
	probe.crease_smoothing = SMOOTH
	var sharp: PackedFloat32Array = probe._signed_distance_field(poly, min_x, min_z, _vs, gw, gw)[0]
	var soft: PackedFloat32Array = probe._blur_field(sharp, gw, gw, SMOOTH, _vs)[0]
	var worst := 0.0
	for p in p_at:
		var ix := int(round((p.x - min_x) / _vs))
		var iz := int(round((p.z - min_z) / _vs))
		if ix < 0 or iz < 0 or ix >= gw or iz >= gw:
			continue
		worst = maxf(worst, absf(soft[iz * gw + ix] - sharp[iz * gw + ix]))
	probe.free()
	return worst


# ---- measurement --------------------------------------------------------------------------------------


func _heights(p_at: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_at:
		out.append(_height(p))
	return out


func _worst(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return true


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
