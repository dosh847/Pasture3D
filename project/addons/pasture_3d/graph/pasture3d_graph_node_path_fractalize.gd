# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathFractalize — midpoint displacement along a line.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. A coastline, a cliff edge, a ridge that should not read as
# drawn. Each iteration inserts a vertex at the middle of every edge and pushes it sideways.
#
# ---- SIGMA IS METRES, AT THE FIRST ITERATION ----
#
# HighMap's sigma is a fraction of the tile. Ours is the standard deviation of the FIRST iteration's
# displacement, in metres, and each subsequent iteration multiplies it by `persistence`. So the knob
# answers "how far off the drawn line may this wander", which is a question about the world, and the
# answer does not change when the brush footprint does — `saleve-measured-in-grid-fractions`.
#
# ---- THE SEED MUST BE STABLE, NOT MERELY RANDOM ----
#
# The same seed and the same input path must give the same output path on every bake and every machine,
# or a frozen graph's terrain moves under it and reads as cache corruption. So the generator is seeded
# once per evaluation and consumed in a FIXED ORDER — iteration by iteration, edge by edge, left to
# right. Anything that changes that order (parallelising the walk, an early-out that skips an edge)
# changes every displacement after it, which is why the loop below has no early-outs in it.
@tool
class_name Pasture3DGraphNodePathFractalize
extends Pasture3DGraphNodePathShape

## Which side of the line the displacement may go.
##
## Named `Bias` rather than `Orientation`: `Orientation` is a @GlobalScope enum in Godot (HORIZONTAL /
## VERTICAL), and a local one of that name shadows it in a way the parser reports only from the SUBCLASS,
## as a type mismatch against itself. The exported property keeps the spec's name.
enum Bias { BOTH, LEFT, RIGHT }

## BOTH is a coastline. LEFT and RIGHT are for the case that actually comes up: a cliff line where the
## rock only ever juts INTO the valley, or a levee that must not eat into the channel it protects.
## Left is the walking direction's left, which is the same convention as the road system's `t`
## (`road-sign-convention`) rather than a second one.
@export var orientation: Bias = Bias.BOTH:
	set(v):
		orientation = v
		emit_changed()

## How many times to subdivide. Each iteration roughly doubles the vertex count, so 8 on an already
## resampled path is a quarter of a million vertices — the cap is at 12 and `MAX_POINTS` catches the rest.
@export_range(0, 12, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 0, 12)
		emit_changed()

## Standard deviation of the first iteration's displacement, in metres. See the header. 0 is the identity.
@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var sigma: float = 4.0:
	set(v):
		sigma = maxf(v, 0.0)
		emit_changed()

## Amplitude multiplier per iteration. Below 1 each pass is finer than the last, which is what makes the
## result read as fractal rather than as noise; at 1 every scale is equally rough; above 1 the fine
## detail dominates and the line stops resembling the one that was drawn.
@export_range(0.0, 2.0, 0.001) var persistence: float = 0.5:
	set(v):
		persistence = maxf(v, 0.0)
		emit_changed()

## The seed. See the header for why it has to be stable and what breaks it.
@export var seed: int = 0:
	set(v):
		seed = v
		emit_changed()

## Hold the first and last vertices. Same reasoning as Path Smooth's: an endpoint is usually somewhere
## somebody else put it. Ignored on a closed path.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		emit_changed()

## Above this the node refuses and passes the input through, with a warning. See Path Resample.
const MAX_POINTS: int = 200000


func op() -> StringName:
	return &"path_fractalize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if iterations <= 0 or sigma <= 0.0:
		return
	var pts := ring_of(p_src)
	if pts.size() < 2:
		return
	# One generator for the whole evaluation, consumed in a fixed order. See the header.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var amp := sigma

	for _it in iterations:
		if pts.size() * 2 > MAX_POINTS:
			break
		var next := PackedVector2Array()
		# Reserved rather than grown: `append` on a PackedVector2Array reallocates, and this is the one
		# loop in the family that runs often enough for that to show up.
		next.resize(0)
		for i in range(pts.size() - 1):
			var a := pts[i]
			var b := pts[i + 1]
			var mid := (a + b) * 0.5
			var seg := b - a
			var len := seg.length()
			# The LEFT normal of the walking direction, per the road sign convention. A zero-length edge
			# has no direction, so it gets no displacement — and it still consumes its random draw, so
			# that a duplicated point does not shift every value after it.
			var nrm := Vector2(seg.y, -seg.x) / len if len > 0.0 else Vector2.ZERO
			var d := rng.randfn(0.0, 1.0)
			match orientation:
				Bias.LEFT:
					d = absf(d)
				Bias.RIGHT:
					d = -absf(d)
				_:
					pass
			next.append(a)
			next.append(mid + nrm * (d * amp))
		next.append(pts[pts.size() - 1])
		if pin_ends and not p_src.closed:
			next[0] = pts[0]
			next[next.size() - 1] = pts[pts.size() - 1]
		pts = next
		amp *= persistence

	if p_src.closed:
		# The ring's ends are the same vertex and were displaced as two different midpoint neighbours;
		# `unring` drops the duplicate, and this makes sure it is dropping an identical one.
		pts[pts.size() - 1] = pts[0]
	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if iterations <= 0 or sigma <= 0.0:
		out.append("Path Fractalize is the identity: iterations is %d and sigma %.2f m, so the path "
				% [iterations, sigma] + "passes through unchanged.")
	elif persistence > 1.0:
		out.append("Path Fractalize's persistence is %.2f, so each pass is rougher than the last and "
				% persistence + "the finest scale dominates. Below 1 is what reads as a coastline.")
	return out
