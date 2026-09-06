# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathWidth — rewrite a path's widths without touching where it goes.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.3. The FIRST customer of the S4 path pre-pass (§8.2), and the
# node that makes the pre-pass worth having: before it, a PATH port could only be produced by a source,
# so PATH -> PATH was a wire shape nothing in the graph actually used.
#
# ---- WHY WIDTH IS A GRAPH NODE WHEN THE SPLINE ALREADY HAS ONE ----
#
# Pasture3DSpline has `half_width` and `width_along`, and for a hand-drawn line that is the right place
# for them: the width is part of what was drawn. This node is for the widths a graph DERIVES — a river
# that must widen downstream of a confluence, one spline read by two carves at two scales, or a preset
# whose shape is fixed and whose size is the knob the user is given. Editing the spline for any of those
# would change it for every other reader, because a path is shared by instance.
#
# ---- IT KEEPS THE ROAD PROFILE, AND THE RESHAPE FAMILY DOES NOT ----
#
# `moves_the_line()` is false here. A solved road's `alignment` and `sample_*` arrays describe a specific
# centreline, and every node in §7.4 moves that line and so has to drop them. This one does not touch the
# line at all, so a Road Grade downstream still has a profile to grade to.
#
# ---- IT MUST NOT MUTATE ITS INPUT ----
#
# The input path belongs to the node above and is handed unchanged to everyone else reading it. Writing
# `half_widths` into it would widen every OTHER consumer of that spline, from a node they are not wired
# to, and the symptom would appear on the untouched branch. So this keeps its own path instance and
# copies into it — kept rather than freshly allocated, because the geometry table dedups by instance id
# and a new instance per evaluation would cost the fanout it is supposed to have (§8.2).
#
# ---- WHY THE CURVE IS SAMPLED BY ARC LENGTH ----
#
# The same reason `Pasture3DSpline.width_along` is: sampled by VERTEX index, a taper would bunch up
# wherever the author happened to click more points, so redistributing points on an unchanged line would
# change the widths. x = 0 is the start of the line and x = 1 its end, in metres.
@tool
class_name Pasture3DGraphNodePathWidth
extends Pasture3DGraphNodePathShape

## SET replaces the path's widths outright; SCALE multiplies whatever it arrived with.
##
## Both exist because they answer different questions. SET is "this river is 12 m wide", which is what a
## preset's size knob wants and which works on a path carrying no widths at all. SCALE is "twice as wide
## as drawn", which preserves a taper the author put there by hand.
enum Mode { SET, SCALE }

@export var mode: Mode = Mode.SET:
	set(v):
		mode = v
		emit_changed()

## In SET, the half-width in metres. In SCALE, the multiplier — so the default 5.0 is a wide, obviously
## visible change rather than an accidental no-op, which is the safer default for a node whose failure
## mode is looking like it did nothing.
##
## HALF-width, not width, matching `Pasture3DGraphPath.half_widths` and `Pasture3DSpline.half_width`. The
## spec drafted this as `width`; a second unit for the same quantity one hop apart is how a road ends up
## twice the size it was asked for.
@export_range(0.0, 200.0, 0.01, "or_greater") var half_width: float = 5.0:
	set(v):
		half_width = maxf(v, 0.0)
		emit_changed()

## Optional multiplier sampled along ARC LENGTH, x = 0 at the start of the line and x = 1 at its end.
## Applied after `mode`, so it tapers a SET width and compounds with a SCALE one. Null = constant.
@export var along: Curve:
	set(v):
		if along != null and along.changed.is_connected(emit_changed):
			along.changed.disconnect(emit_changed)
		along = v
		if along != null and not along.changed.is_connected(emit_changed):
			along.changed.connect(emit_changed)
		emit_changed()

## The floor every result is clamped to. Not cosmetic: `t` in a path query is the across-distance divided
## by the half-width, so a zero here is a division by zero at every cell near that vertex, and a curve
## that dips to 0 at its ends is the most ordinary curve there is.
@export_range(0.001, 50.0, 0.001, "or_greater") var min_half_width: float = 0.1:
	set(v):
		min_half_width = maxf(v, 0.001)
		emit_changed()


func op() -> StringName:
	return &"path_width"


## The one node in the PATH family that leaves the centreline where it is. See the header.
func moves_the_line() -> bool:
	return false


## Rewrite the widths. See Pasture3DGraphNodePathShape.reshape — `p_out` already carries the input's
## points, heights and road profile, so this writes `half_widths` and nothing else.
func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	# Arc length per vertex, from the base helper, which explains why it is not the path's own `_cum`.
	var n := p_src.points.size()
	var cum := arc_lengths(p_src.points)
	var total: float = cum[n - 1]

	var hw := PackedFloat32Array()
	hw.resize(n)
	for i in n:
		var base: float = half_width
		if mode == Mode.SCALE:
			# An empty `half_widths` means 1.0 everywhere (the path resource says so), so SCALE over a
			# widthless path gives `half_width` metres — the same answer SET gives, which is the only
			# reading of "scale nothing" that is not a surprise.
			var was: float = 1.0
			if p_src.half_widths.size() > 0:
				was = p_src.half_widths[mini(i, p_src.half_widths.size() - 1)]
			base = was * half_width
		if along != null:
			var x: float = (cum[i] / total) if total > 0.0 else 0.0
			base *= maxf(along.sample_baked(clampf(x, 0.0, 1.0)), 0.0)
		hw[i] = maxf(base, min_half_width)
	p_out.half_widths = hw


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if mode == Mode.SCALE and is_equal_approx(half_width, 1.0) and along == null:
		out.append("Path Width is set to SCALE by 1.0 with no curve, so it does nothing. Switch to SET, "
				+ "or give it a multiplier.")
	return out
