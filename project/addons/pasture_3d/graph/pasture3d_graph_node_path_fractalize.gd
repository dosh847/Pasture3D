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
		_param_changed()

## Feature wavelength in metres of the largest fractal noise scale. Controls the physical distance
## along the path between major fractal features.
@export_range(1.0, 2000.0, 0.5, "or_greater", "suffix:m") var wavelength: float = 50.0:
	set(v):
		wavelength = maxf(v, 0.1)
		_param_changed()

## Frequency multiplier per octave.
@export_range(1.0, 4.0, 0.01) var lacunarity: float = 2.0:
	set(v):
		lacunarity = maxf(v, 1.0)
		_param_changed()

## How many octaves of fractal noise to evaluate.
@export_range(0, 12, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 0, 12)
		_param_changed()

## Standard deviation of the first iteration's displacement, in metres. See the header. 0 is the identity.
@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var sigma: float = 4.0:
	set(v):
		sigma = maxf(v, 0.0)
		_param_changed()

## Amplitude multiplier per iteration. Below 1 each pass is finer than the last, which is what makes the
## result read as fractal rather than as noise; at 1 every scale is equally rough; above 1 the fine
## detail dominates and the line stops resembling the one that was drawn.
@export_range(0.0, 2.0, 0.001) var persistence: float = 0.5:
	set(v):
		persistence = maxf(v, 0.0)
		_param_changed()

## The seed. See the header for why it has to be stable and what breaks it.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## Hold the first and last vertices. Same reasoning as Path Smooth's: an endpoint is usually somewhere
## somebody else put it. Ignored on a closed path.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		_param_changed()

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

	# Subdivide edges that are coarser than half the finest octave wavelength to prevent Nyquist aliasing.
	var finest_wl := wavelength / pow(lacunarity, float(iterations - 1))
	var max_seg_len := clampf(finest_wl * 0.5, 2.0, 50.0)
	pts = _subdivide_long_edges(pts, max_seg_len, p_src.closed)

	var n := pts.size()
	if n < 2:
		return

	var s_arr := arc_lengths(pts, p_src.closed)
	var total_len := s_arr[s_arr.size() - 1]
	if total_len <= 1.0e-5:
		return

	var new_pts := pts.duplicate()

	for i in range(n):
		var is_end := (i == 0 or i == n - 1)
		if is_end and not p_src.closed and pin_ends:
			continue

		var s := s_arr[i]
		var disp := 0.0
		var amp := sigma

		for o in iterations:
			var wl := wavelength / pow(lacunarity, float(o))
			var period := -1
			if p_src.closed:
				var m := maxi(1, int(roundf(total_len / wl)))
				wl = total_len / float(m)
				period = m
			var octave_seed := seed + o * 1013
			disp += amp * _noise1d(s / wl, octave_seed, period)
			amp *= persistence

		match orientation:
			Bias.LEFT:
				disp = absf(disp)
			Bias.RIGHT:
				disp = -absf(disp)
			_:
				pass

		if not p_src.closed and pin_ends:
			var taper_len := minf(wavelength * 0.75, total_len * 0.25)
			if taper_len > 0.0:
				var d0 := clampf(s / taper_len, 0.0, 1.0)
				var d1 := clampf((total_len - s) / taper_len, 0.0, 1.0)
				disp *= (d0 * d0 * (3.0 - 2.0 * d0)) * (d1 * d1 * (3.0 - 2.0 * d1))

		var prev_pt := pts[posmod(i - 1, n - 1) if p_src.closed else maxi(i - 1, 0)]
		var next_pt := pts[posmod(i + 1, n - 1) if p_src.closed else mini(i + 1, n - 1)]
		var seg := next_pt - prev_pt
		var seg_len := seg.length()
		if seg_len > 0.0:
			var nrm := Vector2(seg.y, -seg.x) / seg_len
			new_pts[i] = pts[i] + nrm * disp

	if p_src.closed and n >= 2:
		new_pts[n - 1] = new_pts[0]

	pts = new_pts
	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


func _subdivide_long_edges(p_pts: PackedVector2Array, p_max_len: float, p_closed: bool) -> PackedVector2Array:
	var n := p_pts.size()
	if n < 2 or p_max_len <= 0.0:
		return p_pts
	var out := PackedVector2Array()
	for i in range(n - 1):
		var a := p_pts[i]
		var b := p_pts[i + 1]
		var d := (b - a).length()
		out.append(a)
		if d > p_max_len:
			var steps := clampi(int(ceilf(d / p_max_len)), 1, 32)
			for k in range(1, steps):
				out.append(a.lerp(b, float(k) / float(steps)))
	out.append(p_pts[n - 1])
	if p_closed and out.size() >= 2:
		out[out.size() - 1] = out[0]
	return out


static func _noise1d(t: float, p_seed: int, p_closed_period: int = -1) -> float:
	var i := floori(t)
	var f := t - float(i)
	var u := f * f * (3.0 - 2.0 * f)
	var i0 := i
	var i1 := i + 1
	if p_closed_period > 0:
		i0 = posmod(i0, p_closed_period)
		i1 = posmod(i1, p_closed_period)
	var v0 := _hash1d(i0, p_seed)
	var v1 := _hash1d(i1, p_seed)
	return lerpf(v0, v1, u)


static func _hash1d(k: int, p_seed: int) -> float:
	var x := (k * 73856093) ^ (p_seed * 19349663) ^ 0x9e3779b9
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = (x >> 16) ^ x
	return float((x & 0x7fffffff) % 2001 - 1000) / 1000.0


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if iterations <= 0 or sigma <= 0.0:
		out.append("Path Fractalize is the identity: iterations is %d and sigma %.2f m, so the path "
				% [iterations, sigma] + "passes through unchanged.")
	elif persistence > 1.0:
		out.append("Path Fractalize's persistence is %.2f, so each pass is rougher than the last and "
				% persistence + "the finest scale dominates. Below 1 is what reads as a coastline.")
	return out
