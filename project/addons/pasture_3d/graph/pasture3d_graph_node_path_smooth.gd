# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathSmooth — take the hand out of a hand-drawn line.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. A line drawn with a mouse has a kink every few points, and a
# carve reads every one of them: a ridge crest wobbles, a river doubles back on itself in half a cell.
#
# ---- WINDOW IS IN VERTICES, AND THAT IS DELIBERATE HERE ----
#
# Everything else in this family is metric, for the reason §7.4 gives. A moving average is the exception,
# because it is defined on the SAMPLES: a window of "8 metres" on a path whose vertices are 40 m apart is
# a window of one vertex and does nothing, and the user has no way to see that from the inspector. The
# metric knob for this node is `Path Resample`'s step, which is what sets what a vertex is worth.
#
# ---- INERTIA IS NOT A SECOND INTENSITY ----
#
# `intensity` blends each smoothed vertex back toward where it was: it controls HOW FAR the smoothing
# moves a point. `inertia` blends each vertex toward the PREVIOUS OUTPUT vertex as the walk proceeds: it
# is a one-sided lag, so it removes high-frequency wobble without pulling a genuine bend flat. A window
# large enough to kill the wobble on its own also cuts every corner off the line, which on a river reads
# as somebody having straightened it.
@tool
class_name Pasture3DGraphNodePathSmooth
extends Pasture3DGraphNodePathShape

## Half-width of the moving average, in VERTICES — see the header for why this one is not metric. 0 makes
## the average a single sample, which is the identity, so the node reports itself as doing nothing.
@export_range(0, 64, 1) var window: int = 3:
	set(v):
		window = maxi(v, 0)
		emit_changed()

## How far toward the smoothed position each vertex moves. 0 is the identity, byte for byte — the control
## every criterion in PathShapeGate [A] leans on.
@export_range(0.0, 1.0, 0.001) var intensity: float = 1.0:
	set(v):
		intensity = clampf(v, 0.0, 1.0)
		emit_changed()

## One-sided lag toward the previous OUTPUT vertex. See the header. 0 is no lag.
@export_range(0.0, 0.95, 0.001) var inertia: float = 0.0:
	set(v):
		inertia = clampf(v, 0.0, 0.95)
		emit_changed()

## Hold the first and last vertices exactly where they are.
##
## On by default, and load-bearing rather than tidy: a river that ends at a lake and a road that ends at a
## junction both have an endpoint somebody else placed, and smoothing is allowed to move the line but not
## to move where it MEETS things. Ignored on a closed path, which has no ends.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		emit_changed()


## Three vertices, because a two-point line has no interior vertex and smoothing it is the identity by
## construction — passing it through says so rather than spending a walk to discover it.
func min_vertices() -> int:
	return 3


func op() -> StringName:
	return &"path_smooth"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if window <= 0 or intensity <= 0.0:
		return

	if not ClassDB.class_has_method("Pasture3DUtil", "path_smooth_solve"):
		push_error("Pasture3DGraphNodePathSmooth: Pasture3DUtil.path_smooth_solve is missing from GDExtension!")
		return

	var res: Dictionary = Pasture3DUtil.path_smooth_solve(
		p_src.points,
		p_src.half_widths,
		p_src.heights,
		p_src.closed,
		window,
		intensity,
		inertia,
		pin_ends
	)

	if res.is_empty():
		return

	p_out.points = res.get("points", PackedVector2Array())
	p_out.half_widths = res.get("half_widths", PackedFloat32Array())
	p_out.heights = res.get("heights", PackedFloat32Array())


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if window <= 0 or intensity <= 0.0:
		out.append("Path Smooth is the identity: window is %d and intensity %.2f, so the path passes "
				% [window, intensity] + "through unchanged.")
	return out
