# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushPointInputGate — the brush-side primitives behind the new spline-point click gestures:
# middle-click "send the selected point to the cursor", and Alt to seat a point on the ground when the
# brush's own Snap to Surface is off.
#
# WHAT THIS GATE CANNOT SEE. The gestures themselves live in `_forward_brush_input`, which needs a live
# EditorPlugin, a SubViewport and a real Camera3D to route an InputEventMouseButton. None of that exists
# headless, so the ROUTING (which button, which modifier, what passes through to the camera) is not
# covered here and has to be checked in the editor. What IS covered is every decision the routing then
# hands to the brush — and that is where the interesting bug was, because it lived BETWEEN the two halves
# (see [[component-gates-miss-wiring]]): the plugin seated a point on the ground and `editor_add_point`
# then silently reinterpolated the Y back onto the old crest line. Criterion C is that bug.
#
# The fixture is a constant-gradient ramp, h(x, z) = RAMP_K * x, so the ground height at any point is
# known in closed form and a seated Y can be asserted exactly rather than compared against itself.
#
# NOTHING IS SAVED and no demo data is loaded (see [[gate-data-directory-is-an-editor-risk]]).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushPointInputGate.tscn
extends Node

const VS := 1.0
const REGION := 64
const RAMP_K := 0.25
const CREST_Y := 40.0        # the authored spline sits far above the ground, so the two Ys cannot be confused
const OFFSET := 1.0          # surface_offset used throughout

var _fail := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== BrushPointInputGate: seating a point, and moving one ===\n")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = VS
	_terrain.region_size = REGION
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	for z in range(REGION):
		for x in range(REGION):
			_terrain.data.set_height(Vector3(float(x), 0.0, float(z)), RAMP_K * float(x))
	_terrain.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)

	_a_seat_honours_force_and_the_void()
	_b_move_is_one_edit_and_a_no_op_is_none()
	_c_a_seated_add_keeps_its_height()
	_d_the_snap_button_still_snaps()

	print("\n=== %s (%d failures) ===\n" % [
		"BRUSH POINT INPUT PASS" if _fail == 0 else "BRUSH POINT INPUT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("    %s %s — %s" % ["OK  " if p_ok else "!!  ", p_label, p_detail])
	if not p_ok:
		_fail += 1


## A Ridge (an OPEN brush, so `editor_add_point`'s crest-following branch is the one that matters) whose
## points sit at CREST_Y, far above the ramp. auto_refresh off: the gate is about the curve edits, and a
## bake per edit would only add time and a GPU path this has no opinion about.
func _ridge(p_snap: bool) -> Pasture3DRidge:
	var r := Pasture3DRidge.new()
	r.auto_refresh = false
	var p := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(10.0, CREST_Y, 32.0))
	c.add_point(Vector3(50.0, CREST_Y, 32.0))
	p.curve = c
	r.add_child(p)
	r.terrain = _terrain
	r.snap_to_surface = p_snap
	r.surface_offset = OFFSET
	add_child(r)
	return r


## Ground height the seat should produce at world x (the ramp, plus the brush's surface_offset).
func _expected_seat(p_x: float) -> float:
	return RAMP_K * p_x + OFFSET


# ---- A. the shared seat ------------------------------------------------------------------------------

func _a_seat_honours_force_and_the_void() -> void:
	print("[A] editor_seat_on_surface: the toggle, the force, and the point over nothing")
	var off := _ridge(false)
	var at := Vector3(20.0, CREST_Y, 32.0)
	# Toggle off, not forced: the point keeps the height it was given. This is the CONTROL for the whole
	# feature — if the seat fired unconditionally, Alt would be doing nothing and every check below would
	# still pass.
	_check("toggle off and unforced leaves Y alone", off.editor_seat_on_surface(at, false).is_equal_approx(at),
		"%.3f" % off.editor_seat_on_surface(at, false).y)
	var forced := off.editor_seat_on_surface(at, true)
	_check("forced seats onto the ramp", absf(forced.y - _expected_seat(20.0)) < 0.01,
		"expected %.3f, got %.3f" % [_expected_seat(20.0), forced.y])
	_check("forced moves Y only", absf(forced.x - at.x) < 1e-4 and absf(forced.z - at.z) < 1e-4,
		"(%.2f, %.2f)" % [forced.x, forced.z])
	off.queue_free()

	var on := _ridge(true)
	_check("toggle on seats without being forced",
		absf(on.editor_seat_on_surface(at, false).y - _expected_seat(20.0)) < 0.01,
		"%.3f" % on.editor_seat_on_surface(at, false).y)
	# Over the void there is no region and _base_height_below answers NaN. The point must keep the height
	# the user gave it, NOT dive to zero — and must not come back NaN either, which would poison the curve.
	var void_at := Vector3(-500.0, CREST_Y, -500.0)
	var seated_void := on.editor_seat_on_surface(void_at, true)
	_check("a point over the void keeps its height",
		seated_void.is_equal_approx(void_at) and is_finite(seated_void.y),
		"%.3f (finite=%s)" % [seated_void.y, is_finite(seated_void.y)])
	on.queue_free()


# ---- B. the move -------------------------------------------------------------------------------------

func _b_move_is_one_edit_and_a_no_op_is_none() -> void:
	print("\n[B] editor_move_point: one curve edit, and none at all when nothing moves")
	var r := _ridge(false)
	var path: Path3D = r._get_splines()[0]
	var counter := _ChangeCounter.new()
	path.curve.changed.connect(counter.bump)

	var target := Vector3(30.0, 7.5, 32.0)
	r.editor_move_point(path, 0, target)
	var got: Vector3 = path.to_global(path.curve.get_point_position(0))
	_check("the point lands on the target", got.is_equal_approx(target),
		"(%.2f, %.2f, %.2f)" % [got.x, got.y, got.z])
	# ONE emission. The dirty-rect repaint is driven by `changed`, so a two-mutation move would bake the
	# span twice for one gesture. Asserted rather than assumed because a future "set position then fix the
	# tangents" would be an easy and invisible regression.
	_check("exactly one curve `changed`", counter.n == 1, "%d emission(s)" % counter.n)

	# A move to where the point already is must not touch the curve: it would put an empty step in the
	# undo history that swallows a Ctrl-Z, and wake a repaint for no change.
	counter.n = 0
	r.editor_move_point(path, 0, target)
	_check("a no-op move emits nothing", counter.n == 0, "%d emission(s)" % counter.n)

	# Out-of-range indices are refused rather than crashing — the plugin can hand one over if the point
	# count moved between the selection and the click.
	counter.n = 0
	r.editor_move_point(path, 99, target)
	r.editor_move_point(path, -1, target)
	r.editor_move_point(null, 0, target)
	_check("a bad index is refused quietly", counter.n == 0, "%d emission(s)" % counter.n)
	r.queue_free()


# ---- C. the seated add — the wiring bug --------------------------------------------------------------

func _c_a_seated_add_keeps_its_height() -> void:
	print("\n[C] a seated add keeps the ground height instead of the crest line")
	# Snap OFF, so `editor_add_point`'s crest-following branch is live. The hit is seated on the ground at
	# x = 30, exactly what the plugin does when Alt is held.
	var r := _ridge(false)
	var path: Path3D = r._get_splines()[0]
	var hit := Vector3(30.0, 0.0, 32.0)
	var seat: Vector3 = r.editor_seat_on_surface(hit, true)
	r.editor_add_point(seat, true)
	_check("a point was inserted", path.curve.point_count == 3,
		"%d points" % path.curve.point_count)
	var added: Vector3 = path.to_global(path.curve.get_point_position(1))
	_check("it kept the seated height", absf(added.y - _expected_seat(30.0)) < 0.01,
		"expected %.3f, got %.3f (crest is %.1f)" % [_expected_seat(30.0), added.y, CREST_Y])
	r.queue_free()

	# THE CONTROL, and the bug this whole flag exists for. Same seated position, `p_seated` left false:
	# the crest interpolation overwrites the Y and the point flies back up to CREST_Y. If `editor_add_point`
	# ever stops honouring the flag, this is the criterion that goes red — the one above would keep passing
	# only if the interpolation happened to agree, which on a flat crest it never does.
	var r2 := _ridge(false)
	var path2: Path3D = r2._get_splines()[0]
	r2.editor_add_point(r2.editor_seat_on_surface(hit, true), false)
	var added2: Vector3 = path2.to_global(path2.curve.get_point_position(1))
	_check("CONTROL unseated, the crest line wins", absf(added2.y - CREST_Y) < 0.01,
		"expected %.1f, got %.3f" % [CREST_Y, added2.y])
	r2.queue_free()


# ---- D. the batch sites the seat refactor touched -----------------------------------------------------

func _d_the_snap_button_still_snaps() -> void:
	print("\n[D] the Snap Points button still snaps (the batch sites now share the seat)")
	var r := _ridge(false)   # toggle OFF: the button forces, so it must snap anyway
	var path: Path3D = r._get_splines()[0]
	r.snap_points_to_surface()
	var p0: Vector3 = path.to_global(path.curve.get_point_position(0))
	var p1: Vector3 = path.to_global(path.curve.get_point_position(1))
	_check("both points are on the ramp",
		absf(p0.y - _expected_seat(10.0)) < 0.01 and absf(p1.y - _expected_seat(50.0)) < 0.01,
		"x=10 → %.3f (want %.3f), x=50 → %.3f (want %.3f)"
			% [p0.y, _expected_seat(10.0), p1.y, _expected_seat(50.0)])
	# The two points sit at different ramp heights, so a seat that ignored position — returning a constant,
	# or the first point's height for both — passes nothing here.
	_check("CONTROL the two heights differ by the ramp", absf((p1.y - p0.y) - RAMP_K * 40.0) < 0.01,
		"Δ %.3f, expected %.3f" % [p1.y - p0.y, RAMP_K * 40.0])
	r.queue_free()


## Counts `changed` emissions. An object rather than a bound lambda so the connection keeps it alive.
class _ChangeCounter extends RefCounted:
	var n: int = 0

	func bump() -> void:
		n += 1
