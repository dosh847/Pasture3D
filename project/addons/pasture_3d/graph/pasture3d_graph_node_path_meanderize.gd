# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathMeanderize — make a drawn line meander like a river.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. The river node, and the single biggest difference between a
# drawn river and a believable one: real channels do not go anywhere directly, and a straight line reads
# as a canal no matter what cross-section is carved along it.
#
# ---- WHAT IT ACTUALLY DOES, AND WHY NOT JUST NOISE ----
#
# Fractalize already offsets a line by noise, and the result looks like a wobbly line, not a river. The
# difference is that a meander AMPLIFIES ITS OWN CURVATURE: water cuts the outside of a bend and deposits
# on the inside, so wherever the line already turns, it turns harder next year. So each iteration pushes
# every vertex along its own normal by an amount proportional to the local curvature there, subdivides,
# and repeats. Noise is added on top and is a garnish; `ratio` is the node.
#
# ---- THE SIGN IS THE ENTIRE ALGORITHM ----
#
# Curvature is signed by the cross product of the incoming and outgoing segments, and pushing OUTWARD
# means displacing along the normal in the direction the bend already leans. Getting that sign backwards
# does not produce a mirrored river: it produces a line that straightens itself, iteration by iteration,
# converging on the chord between the endpoints. That failure is silent at one iteration and total at six,
# which is why PathShapeGate measures total length rather than eyeballing a shape — a meandering line is
# LONGER than the line it came from, and a straightened one is shorter.
#
# ---- REMOVE LOOPS ----
#
# Amplifying curvature is a positive feedback, so a tight enough bend eventually crosses itself. A path
# that self-intersects is not wrong to the query — nearest-segment still answers — but a river that flows
# through itself carves a bed twice and reads as a mistake. `remove_loops` excises the vertices between
# any two crossing segments, which is the standard cut and is why the two are one node rather than two.
@tool
class_name Pasture3DGraphNodePathMeanderize
extends Pasture3DGraphNodePathShape

## Wavelength of the meander bends in metres. Controls the physical distance along the river between
## successive loops.
@export_range(10.0, 2000.0, 1.0, "or_greater", "suffix:m") var wavelength: float = 150.0:
	set(v):
		wavelength = maxf(v, 1.0)
		_param_changed()

## Base amplitude of the meander swings in metres. Controls how far perpendicular the loops swing out.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var amplitude: float = 25.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()

## How hard each iteration pushes a bend outward, as a fraction of the local segment length. The useful
## range is small: 0.3 over six iterations is already a floodplain river. 0 is the identity.
@export_range(0.0, 2.0, 0.001) var ratio: float = 0.4:
	set(v):
		ratio = maxf(v, 0.0)
		_param_changed()

## Random displacement added on top, as a fraction of the local segment length. A garnish — see the
## header. It is what stops every bend being the same bend, and it cannot make a straight line meander.
@export_range(0.0, 1.0, 0.001) var noise_ratio: float = 0.1:
	set(v):
		noise_ratio = maxf(v, 0.0)
		_param_changed()

## The seed. Stable, for the reason Path Fractalize's header gives at length: the generator is seeded once
## and consumed in a fixed order, and anything that reorders the walk moves the terrain under a frozen
## graph.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## How many times to amplify. Each iteration multiplies the vertex count by `edge_divisions`, so this and
## that knob together are the cost.
@export_range(1, 10, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 1, 10)
		_param_changed()

## How many vertices each edge becomes per iteration. Two is the minimum that can bend at all; more gives
## a smoother bend for the same number of iterations, at a cost that multiplies rather than adds.
@export_range(2, 8, 1) var edge_divisions: int = 2:
	set(v):
		edge_divisions = clampi(v, 2, 8)
		_param_changed()

## Cut out any loop the amplification produces. See the header.
@export var remove_loops: bool = true:
	set(v):
		remove_loops = v
		_param_changed()

## Hold the first and last vertices — a river's mouth and source are placed, not derived. Ignored when
## the path is closed.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		_param_changed()

## Above this the node stops iterating and keeps what it has, rather than passing the input through: a
## meander that got most of the way there is still a meander, unlike a half-resampled path.
const MAX_POINTS: int = 200000


func min_vertices() -> int:
	return 2


func op() -> StringName:
	return &"path_meanderize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if ratio <= 0.0 and noise_ratio <= 0.0:
		return
	var pts := ring_of(p_src)
	if pts.size() < 2:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# Sinuous macro-wave generation: establishes physical wavelength and amplitude along arc length.
	var eff_amp := amplitude * (ratio + noise_ratio)
	if eff_amp > 0.0:
		var max_seg_len := maxf(wavelength / 8.0, 5.0)
		pts = _subdivide_long_edges(pts, max_seg_len, p_src.closed)
		var n := pts.size()
		var s_arr := arc_lengths(pts, p_src.closed)
		var total_len := s_arr[s_arr.size() - 1]

		if total_len > 1.0e-4 and n >= 2:
			var wl := wavelength
			if p_src.closed:
				var m := maxi(1, int(roundf(total_len / wl)))
				wl = total_len / float(m)

			var phi_0 := float(posmod(seed * 2654435761, 628318)) / 100000.0
			var new_pts := pts.duplicate()

			for i in range(n):
				var is_end := (i == 0 or i == n - 1)
				if is_end and not p_src.closed and pin_ends:
					continue

				var s := s_arr[i]
				var u := (TAU * s) / wl
				var swing := sin(u + phi_0)
				var harmonic := 0.3 * sin(2.0 * u + phi_0 * 1.7)
				var noise_val := _noise1d(s / (wl * 0.5), seed + 101)
				var disp := eff_amp * (swing + harmonic + noise_ratio * noise_val)

				if not p_src.closed and pin_ends:
					var taper_len := minf(wl * 0.75, total_len * 0.35)
					if taper_len > 0.0:
						var d0 := clampf(s / taper_len, 0.0, 1.0)
						var d1 := clampf((total_len - s) / taper_len, 0.0, 1.0)
						var env := (d0 * d0 * (3.0 - 2.0 * d0)) * (d1 * d1 * (3.0 - 2.0 * d1))
						disp *= env

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

	for _it in iterations:
		if pts.size() * edge_divisions > MAX_POINTS:
			break
		pts = _subdivide(pts, p_src.closed)
		pts = _amplify(pts, p_src.closed, rng)
		if remove_loops:
			pts = _cut_loops(pts, p_src.closed)
		if pts.size() < 3:
			break

	if p_src.closed and pts.size() >= 2:
		pts[pts.size() - 1] = pts[0]
	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


## Split every edge into `edge_divisions` pieces. Straight subdivision: the bending is `_amplify`'s job,
## and doing both in one pass would make the displacement depend on how many pieces an edge became.
func _subdivide(p_pts: PackedVector2Array, _p_closed: bool) -> PackedVector2Array:
	var n := p_pts.size()
	var target_count := (n - 1) * edge_divisions + 1
	var out := PackedVector2Array()
	out.resize(target_count)
	var idx := 0
	for i in range(n - 1):
		var a := p_pts[i]
		var b := p_pts[i + 1]
		for k in edge_divisions:
			out[idx] = a.lerp(b, float(k) / float(edge_divisions))
			idx += 1
	out[idx] = p_pts[n - 1]
	return out


## Push every vertex outward along its own normal, proportionally to the curvature there.
func _amplify(p_pts: PackedVector2Array, p_closed: bool, p_rng: RandomNumberGenerator) -> PackedVector2Array:
	var n := p_pts.size()
	var out := p_pts.duplicate()
	for i in range(n):
		var is_end := (i == 0 or i == n - 1)
		# The random draw is taken for EVERY vertex including the pinned ends, before any decision to skip
		# it. Consuming the stream unconditionally is what keeps the seed stable when `pin_ends` changes:
		# otherwise turning it off would reroll every bend in the river, not just its two ends.
		var jitter := p_rng.randfn(0.0, 1.0)
		if is_end and not p_closed:
			if pin_ends:
				continue
			# Unpinned endpoint: curvature turn is zero, displace by noise along normal of single adjacent edge.
			var seg := (p_pts[1] - p_pts[0]) if i == 0 else (p_pts[n - 1] - p_pts[n - 2])
			var seg_len := seg.length()
			if seg_len > 0.0:
				var nrm := Vector2(seg.y, -seg.x) / seg_len
				out[i] = p_pts[i] + nrm * (seg_len * noise_ratio * jitter)
			continue
		var prev := p_pts[posmod(i - 1, n - 1) if p_closed else maxi(i - 1, 0)]
		var next := p_pts[posmod(i + 1, n - 1) if p_closed else mini(i + 1, n - 1)]
		var v0 := p_pts[i] - prev
		var v1 := next - p_pts[i]
		var l0 := v0.length()
		var l1 := v1.length()
		if l0 <= 0.0 or l1 <= 0.0:
			continue
		var chord := (l0 + l1) * 0.5
		# The LEFT normal of the average direction, and the SIGNED turn. `cross` is positive when the line
		# turns one way and negative the other, so multiplying by it displaces outward on both — see the
		# header for what the wrong sign does.
		var dir := (v0 / l0 + v1 / l1).normalized()
		if dir == Vector2.ZERO:
			continue
		var nrm := Vector2(dir.y, -dir.x)
		var turn: float = (v0 / l0).cross(v1 / l1)
		out[i] = p_pts[i] + nrm * (chord * (ratio * turn + noise_ratio * jitter))
	if p_closed and n >= 2:
		out[n - 1] = out[0]
	return out


## Excise the vertices between any two non-adjacent segments that cross, replacing them with the crossing
## point. One forward pass over a bucket-indexed segment set.
##
## ---- WHY THIS IS INDEXED AND THE REST OF THE FAMILY IS NOT ----
##
## Everything else here is a walk over a few hundred vertices, where an index would cost more than it
## saves. This is the one O(n²) question in the family, asked on the one node whose vertex count is
## MULTIPLIED rather than added to: six iterations at three divisions turns a 70-point line into 51 000,
## and the naive pairwise scan is 2.6 billion segment tests per cut attempt. The first version of this
## function was that scan, and it did not fail the gate — it hung it.
##
## So segments go into a uniform bucket index, the same shape `Pasture3DGraphPath` builds for its own
## queries, and each segment only tests the ones sharing a cell.
##
## ---- ONE PASS, LARGEST LOOP FIRST ----
##
## Where segment `i` crosses several later segments, the LAST of them is taken, so the biggest loop is
## excised in one cut and the small ones inside it go with it. On a closed ring, candidate cuts are
## checked against the seam: if a seam-spanning loop is shorter than the forward sub-path, the seam loop
## is excised, keeping the main polygon body rather than collapsing into a triangular remnant.
func _cut_loops(p_pts: PackedVector2Array, p_closed: bool) -> PackedVector2Array:
	var n := p_pts.size()
	if n < 4:
		return p_pts
	var segs := n - 1
	# Cell size from the MEAN segment length: the index exists to bound how many segments share a cell,
	# and a cell a few segments wide does that whatever scale the path is drawn at. A fixed metric size
	# would be one bucket for a 20 m creek and a hundred thousand for a continental river.
	var total := 0.0
	for i in segs:
		total += p_pts[i].distance_to(p_pts[i + 1])
	var cell: float = maxf(total / float(segs) * 4.0, 0.001)

	var buckets := {}
	for i in segs:
		for c in _cells_of(p_pts[i], p_pts[i + 1], cell):
			if not buckets.has(c):
				buckets[c] = PackedInt32Array()
			buckets[c].append(i)

	var out := PackedVector2Array()
	var i := 0
	var seen := {}
	while i < segs:
		out.append(p_pts[i])
		var best_j := -1
		var best_x := Vector2.ZERO
		seen.clear()
		for c in _cells_of(p_pts[i], p_pts[i + 1], cell):
			for j in buckets.get(c, PackedInt32Array()):
				# `i + 2` skips the adjacent segment, which shares an endpoint and so always "crosses".
				if j <= i + 1 or seen.has(j):
					continue
				seen[j] = true
				if p_closed and i == 0 and j == segs - 1:
					continue # the seam pair, adjacent around the ring
				var x = Geometry2D.segment_intersects_segment(p_pts[i], p_pts[i + 1],
						p_pts[j], p_pts[j + 1])
				if x != null and j > best_j:
					best_j = j
					best_x = x
		if best_j >= 0:
			if p_closed:
				var c_fwd: int = best_j - i
				var c_wrap: int = segs - c_fwd
				if c_wrap < c_fwd:
					# The loop wrapping across the seam is shorter.
					# Excise the seam loop, keeping the main polygon body between i + 1 and best_j.
					var closed_out := PackedVector2Array()
					closed_out.append(best_x)
					for k in range(i + 1, best_j + 1):
						closed_out.append(p_pts[k])
					closed_out.append(best_x)
					return closed_out
			out.append(best_x)
			i = best_j + 1
		else:
			i += 1
	out.append(p_pts[n - 1])
	return out


## The index cells a segment's line touches (supercover line grid traversal).
## Only indexes cells the segment physically intersects, bounding bucket occupancy to O(K) instead of O(K^2).
static func _cells_of(p_a: Vector2, p_b: Vector2, p_cell: float) -> Array[Vector2i]:
	var x0 := int(floor(p_a.x / p_cell))
	var y0 := int(floor(p_a.y / p_cell))
	var x1 := int(floor(p_b.x / p_cell))
	var y1 := int(floor(p_b.y / p_cell))

	if x0 == x1 and y0 == y1:
		return [Vector2i(x0, y0)]

	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var sx := 1 if x1 >= x0 else -1
	var sy := 1 if y1 >= y0 else -1

	var x := x0
	var y := y0
	var err := dx - dy
	var out: Array[Vector2i] = []

	while true:
		out.append(Vector2i(x, y))
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		elif e2 < dx:
			err += dx
			y += sy
	return out


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
	if ratio <= 0.0 and noise_ratio <= 0.0:
		out.append("Path Meanderize is the identity: both ratio and noise ratio are 0, so the path "
				+ "passes through unchanged.")
	elif ratio <= 0.0:
		out.append("Path Meanderize's ratio is 0, so it is only adding noise — it cannot make a "
				+ "straight line meander, because it amplifies curvature that is already there.")
	return out
