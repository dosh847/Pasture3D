# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadMesher — TIER MID (§10): the chunked ribbon mesh. Where tier FAR says what the surface is
# made of, this gives it a surface of its own — close enough to see the camber, far enough that a chunk
# is still a chunk.
#
# ---- THE RIBBON SITS ON GROUND THAT IS ALREADY THE RIGHT SHAPE ----
#
# P1/P2 graded the terrain to the road's own profile, so this ribbon is not draped, projected or fought
# against the heightmap: both are `Pasture3DRoadGrader.surface_height` of the same arc length, which is
# why that function lives in the grader and neither of them owns a copy. A millimetre of disagreement
# would z-fight along the entire road and read as a rendering bug rather than as arithmetic.
#
# ---- A KERNEL, NOT A HOST ----
#
# Nothing here is a Node, touches a Terrain, or allocates a mesh resource. It turns a run into vertex
# arrays, and the chunk host does the hosting — the same split as the grader and the paint kernel, and
# for the same reason: every claim §10 makes about chunking is a claim about NUMBERS (where the cuts
# fall, whether two chunks share their seam vertices exactly, what an LOD drops), and numbers can be
# gated without a viewport deciding whether the road looked right.
#
# ---- THE THREE RULES §10 SETS, AND WHERE EACH IS ENFORCED ----
#
#   "chunks are cut on arc length, snapped to region boundaries"  ->  `chunk_spans`
#   "never chunk across an intersection"                          ->  `chunk_spans`, via skip ranges
#   "seams land on shared vertices so no crack can open"          ->  `ring`, which is a function of
#                                                                     ARC LENGTH ALONE
#
# The third is the one that is easy to get wrong and impossible to see until it cracks. A ring is
# generated from `s` and nothing else — not from the chunk, not from the vertex index within the chunk,
# not from an accumulated step. Two chunks meeting at `s` therefore compute the same floats from the
# same inputs, and are equal bit for bit rather than equal to within a tolerance. A mesher that walked
# `s += step` per chunk would produce seams that agree to six decimal places and crack anyway.
@tool
class_name Pasture3DRoadMesher
extends RefCounted

## Cross-section detail, coarsening with distance. §10: "shoulder and camber collapse first,
## carriageway last" — the carriageway edges are in every level, because a road that narrows as it
## recedes is a road that visibly changes width as you drive at it.
enum Cross {
	FULL,      ## shoulders, both carriageway edges, and the crown vertex down the centre
	NO_CROWN,  ## shoulders and carriageway edges; the camber flattens
	NO_SHOULDER,  ## carriageway edges only
}

## Longitudinal spacing doubles per LOD level, so level `n` samples every `ds * 2^n` metres.
const LOD_LEVELS: int = 4

## How far the ribbon is lifted above the surface the grader carved, metres.
##
## NOT a fudge, and not tunable away to zero. The ground under the road was graded to the road's own
## profile (P1/P2), so the ribbon and the terrain are the SAME surface — which means the depth test
## between them is decided by float precision, and at distance the terrain's own clipmap moves its
## vertices anyway. Coplanar is the one thing this ribbon must never be: it z-fights up close and
## disappears entirely wherever the terrain rounds upward.
##
## 2 cm: below what a camera can see at any driving distance, above what depth precision loses.
const DEPTH_LIFT: float = 0.02

## Arc lengths closer together than this are the same cut. Region boundaries and junction footprints
## land near each other constantly — a road entering a junction just inside a region edge would
## otherwise produce a chunk a few centimetres long, which costs a draw call to draw nothing.
const CUT_EPSILON: float = 0.5


## The cross-section detail for an LOD level.
static func cross_for_lod(p_lod: int) -> Cross:
	if p_lod <= 0:
		return Cross.FULL
	if p_lod == 1:
		return Cross.NO_CROWN
	return Cross.NO_SHOULDER


## Longitudinal sample spacing at an LOD level, metres.
static func step_for_lod(p_ds: float, p_lod: int) -> float:
	return maxf(p_ds, 0.01) * pow(2.0, float(clampi(p_lod, 0, LOD_LEVELS - 1)))


## The signed across-distances of one cross-section, left to right.
##
## Left to right and NOT outward from the centre, so the triangle strip between two rings is a simple
## zip of equal-length arrays. Every level keeps ±half — see `Cross`.
## The signed across-distances of one cross-section, left to right.
##
## Left to right and NOT outward from the centre, so the triangle strip between two rings is a simple
## zip of equal-length arrays. Every level keeps ±half — see `Cross`.
static func cross_offsets(p_half: float, p_shoulder: float, p_cross: Cross,
		p_left_kerb: int = 0, p_right_kerb: int = 0, p_kerb_width: float = 0.8) -> PackedFloat32Array:
	var half := maxf(p_half, 0.01)
	var shoulder := maxf(p_shoulder, 0.0)
	var kw := maxf(p_kerb_width, 0.1)
	if p_cross == Cross.NO_SHOULDER:
		return PackedFloat32Array([-half, half])

	var left_offsets := PackedFloat32Array()
	if p_left_kerb > 0:
		left_offsets.append(-(half + kw))
		left_offsets.append(-(half + kw * 0.7))
		left_offsets.append(-(half + kw * 0.2))
	else:
		left_offsets.append(-(half + shoulder))

	var right_offsets := PackedFloat32Array()
	if p_right_kerb > 0:
		right_offsets.append(half + kw * 0.2)
		right_offsets.append(half + kw * 0.7)
		right_offsets.append(half + kw)
	else:
		right_offsets.append(half + shoulder)

	var out := PackedFloat32Array()
	out.append_array(left_offsets)
	out.append(-half)
	if p_cross == Cross.FULL:
		out.append(0.0)
	out.append(half)
	out.append_array(right_offsets)
	return out


## Height displacement above the road surface for a kerb at normalized lateral position `p_xi` in [0, 1]
## (0 at carriageway edge, 1 at outer toe) and arc length `p_s`.
static func kerb_displacement(p_kerb_type: int, p_xi: float, p_s: float,
		p_height: float, p_pitch: float, p_depth: float) -> float:
	if p_kerb_type <= 0 or p_xi <= 0.0 or p_xi >= 1.0:
		return 0.0
	match p_kerb_type:
		Pasture3DRoadType.KerbType.FIA_BEVEL:
			var bevel := p_xi / 0.2 if p_xi < 0.2 else (1.0 if p_xi <= 0.7 else (1.0 - p_xi) / 0.3)
			return p_height * bevel
		Pasture3DRoadType.KerbType.SAWTOOTH:
			var bevel := p_xi / 0.2 if p_xi < 0.2 else (1.0 if p_xi <= 0.7 else (1.0 - p_xi) / 0.3)
			var pitch := p_pitch if p_pitch > 0.01 else 0.4
			var x := p_s / pitch
			var saw := 2.0 * (x - floorf(0.5 + x))
			return (p_height + p_depth * saw) * bevel
		Pasture3DRoadType.KerbType.FLAT_SLAB:
			var slab_h := minf(p_height, 0.01)
			var bevel := p_xi / 0.2 if p_xi < 0.2 else (1.0 if p_xi <= 0.7 else (1.0 - p_xi) / 0.3)
			return slab_h * bevel
		Pasture3DRoadType.KerbType.DRAIN_GUTTER:
			return -4.0 * p_height * p_xi * (1.0 - p_xi)
		_:
			return 0.0


## One cross-section of the ribbon at arc length `p_s`, in world space.
##
## A PURE FUNCTION OF ARC LENGTH — this is the seam contract. Nothing about which chunk asked, which
## vertex index it is, or how far the caller has walked enters the arithmetic, so two chunks meeting at
## `p_s` produce identical floats and share their seam exactly. Everything else in this file exists to
## make sure the boundary arc lengths are the same number on both sides; this makes the same number
## produce the same vertex.
static func ring(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_s: float, p_offsets: PackedFloat32Array,
		p_crown: float, p_lift: float = 0.0,
		p_half_width: float = 4.0, p_crown_mode: int = 0, p_max_bank: float = 0.0,
		p_left_kerb: int = 0, p_right_kerb: int = 0,
		p_kerb_width: float = 0.8, p_kerb_height: float = 0.08,
		p_kerb_rumble_pitch: float = 0.4, p_kerb_rumble_depth: float = 0.02) -> PackedVector3Array:
	var out := PackedVector3Array()
	if p_alignment == null or p_plan.size() < 2:
		return out
	var at := Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, p_s)
	var tangent := Pasture3DRoadGrader.plan_tangent_at(p_plan, p_cum, p_s)
	# Positive across-distance is the driver's RIGHT (§5.1). In the (x, z) plane that is (-t.y, t.x) —
	# see the sign-convention note in Pasture3DRoadLanes, and do not re-derive it here.
	var across := Vector2(-tangent.y, tangent.x)
	var centre: float = p_alignment.height_at(p_s)
	var si := p_alignment.index_at(p_s)
	var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
	var half := maxf(p_half_width, 0.01)
	var kw := maxf(p_kerb_width, 0.01)
	for u in p_offsets:
		var xz := at + across * u
		var base_y := Pasture3DRoadGrader.surface_height(centre, bank, p_crown, u, half, p_crown_mode, p_max_bank)
		var dy := 0.0
		if u < -half and p_left_kerb > 0:
			var xi := clampf((-u - half) / kw, 0.0, 1.0)
			dy = kerb_displacement(p_left_kerb, xi, p_s, p_kerb_height, p_kerb_rumble_pitch, p_kerb_rumble_depth)
		elif u > half and p_right_kerb > 0:
			var xi := clampf((u - half) / kw, 0.0, 1.0)
			dy = kerb_displacement(p_right_kerb, xi, p_s, p_kerb_height, p_kerb_rumble_pitch, p_kerb_rumble_depth)
		# The lift is a CONSTANT added to the profile, never a scale on it: the ribbon must be the same
		# shape as the ground, sitting above it, or the camber and the banking would drift apart from the
		# terrain they were graded into.
		out.append(Vector3(xz.x, base_y + dy + p_lift, xz.y))
	return out


## The arc lengths at which the ribbon must be cut, ascending, always including 0 and the run's length.
##
## Two rules, both from §10, and they are combined here rather than applied in sequence because a cut is
## a cut whatever put it there:
##
##   * REGION BOUNDARIES. A chunk that ends where a terrain region ends has the same lifetime as that
##     region, so one visibility test serves both and the road streams for free with the terrain it is
##     cut into. This is what §4.2 decoupled chunks from spline intervals FOR.
##   * JUNCTION FOOTPRINTS. Never chunk across an intersection: the junction owns the surface inside its
##     footprint, and a ribbon running through it would be a second road surface fighting the first.
##
## `p_skips` is an array of `[from, to]` arc-length pairs — the footprints, which the brush already
## computes as the trim-back it grades around.
static func cut_points(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_region_size: float,
		p_skips: Array = [], p_extra_cuts: PackedFloat32Array = PackedFloat32Array()) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if p_plan.size() < 2 or p_cum.size() < p_plan.size():
		return out
	var total: float = p_cum[p_cum.size() - 1]
	out.append(0.0)
	out.append(total)
	for pair in p_skips:
		if pair is Array and pair.size() >= 2:
			out.append(clampf(float(pair[0]), 0.0, total))
			out.append(clampf(float(pair[1]), 0.0, total))
	for cut in p_extra_cuts:
		out.append(clampf(cut, 0.0, total))
	if p_region_size > 0.0:
		for i in range(1, p_plan.size()):
			_boundaries_between(out, p_plan[i - 1], p_plan[i], p_cum[i - 1], p_cum[i], p_region_size)
	out.sort()
	# Collapse cuts that are the same cut. Without this a road entering a junction just inside a region
	# edge produces a chunk a few centimetres long: a draw call, a mesh resource and a seam, to draw
	# nothing.
	var merged := PackedFloat32Array()
	for s in out:
		if merged.is_empty() or s - merged[merged.size() - 1] > CUT_EPSILON:
			merged.append(s)
	if merged.size() > 1 and total - merged[merged.size() - 1] <= CUT_EPSILON:
		merged[merged.size() - 1] = total
	return merged


## Arc lengths where the segment `p_a` → `p_b` crosses a region grid line, appended to `p_into`.
##
## Both axes: a road running diagonally crosses X boundaries and Z boundaries at different places and
## needs a cut at each, because it enters a new region at whichever comes first.
static func _boundaries_between(p_into: PackedFloat32Array, p_a: Vector2, p_b: Vector2,
		p_s_a: float, p_s_b: float, p_size: float) -> void:
	var span := p_s_b - p_s_a
	if span <= 1e-6:
		return
	for axis in 2:
		var a: float = p_a.x if axis == 0 else p_a.y
		var b: float = p_b.x if axis == 0 else p_b.y
		if is_equal_approx(a, b):
			continue
		var lo := int(floor(minf(a, b) / p_size)) + 1
		var hi := int(floor(maxf(a, b) / p_size))
		for k in range(lo, hi + 1):
			var line := float(k) * p_size
			p_into.append(p_s_a + span * ((line - a) / (b - a)))


## The spans to build chunks for: consecutive cut points, minus anything inside a junction footprint.
##
## Returns an array of `[from, to]`. A span whose midpoint falls in a skip range is dropped entirely
## rather than shortened — the footprint is not the mesher's to render, and a chunk that stopped at its
## edge would still have started inside it.
static func chunk_spans(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_region_size: float,
		p_skips: Array = [], p_extra_cuts: PackedFloat32Array = PackedFloat32Array()) -> Array:
	var cuts := cut_points(p_plan, p_cum, p_region_size, p_skips, p_extra_cuts)
	var out: Array = []
	for i in range(1, cuts.size()):
		var from: float = cuts[i - 1]
		var to: float = cuts[i]
		if to - from <= CUT_EPSILON:
			continue
		var mid := (from + to) * 0.5
		var skipped := false
		for pair in p_skips:
			if pair is Array and pair.size() >= 2 and mid >= float(pair[0]) and mid <= float(pair[1]):
				skipped = true
				break
		if not skipped:
			out.append([from, to])
	return out


## Build one chunk's surface arrays over `[p_from, p_to]` at LOD `p_lod`.
##
## Returns a Godot `ArrayMesh` surface array (`Mesh.ARRAY_MAX` long) ready for `add_surface_from_arrays`,
## or an empty Array when there is nothing to build. Positions, normals, UVs and indices only — a
## resource is the host's business.
##
## THE ENDS ARE ALWAYS SAMPLED EXACTLY. The longitudinal walk is by index from the start, and the final
## ring is `p_to` itself rather than wherever the walk happened to stop. That is the other half of the
## seam contract: `ring` guarantees the same `s` gives the same vertex, and this guarantees the two
## chunks are asked about the same `s`.
## `p_force_gdscript` skips the native delegation and runs the body below, for the same reason the
## alignment solver has one: this file is the reference the native mesher was written against, and once
## `ClassDB.class_has_method` started answering yes the body became unreachable in any session with the
## extension loaded. A parity gate that calls `build_chunk` twice compares the native path to itself.
static func build_chunk(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_half: float,
		p_shoulder: float, p_crown: float, p_lod: int = 0,
		p_lift: float = DEPTH_LIFT, p_force_gdscript: bool = false,
		p_crown_mode: int = 0, p_max_bank: float = 0.0,
		p_left_kerb: int = 0, p_right_kerb: int = 0,
		p_kerb_width: float = 0.8, p_kerb_height: float = 0.08,
		p_kerb_rumble_pitch: float = 0.4, p_kerb_rumble_depth: float = 0.02) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_to - p_from <= 1e-4:
		return []
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_chunk"):
		return Pasture3DUtil.road_mesh_build_chunk(p_plan, p_cum, p_alignment.ds,
				p_alignment.z, p_alignment.bank, p_from, p_to, p_half, p_shoulder,
				p_crown, p_lod, p_lift, p_alignment.s0, p_crown_mode, p_max_bank,
				p_left_kerb, p_right_kerb, p_kerb_width, p_kerb_height,
				p_kerb_rumble_pitch, p_kerb_rumble_depth)

	var offsets := cross_offsets(p_half, p_shoulder, cross_for_lod(p_lod),
			p_left_kerb, p_right_kerb, p_kerb_width)
	var across_count := offsets.size()
	if across_count < 2:
		return []
	var step := step_for_lod(p_alignment.ds, p_lod)
	if p_lod == 0 and (p_left_kerb == Pasture3DRoadType.KerbType.SAWTOOTH or p_right_kerb == Pasture3DRoadType.KerbType.SAWTOOTH):
		var min_rumble_step := maxf(p_kerb_rumble_pitch * 0.5, 0.05)
		step = minf(step, min_rumble_step)
	var rows := maxi(int(ceil((p_to - p_from) / step)), 1) + 1

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half := maxf(p_half, 0.01)

	for r in rows:
		# The last row is `p_to` itself, not `p_from + r * step`. Rounding the final ring to the nearest
		# sample is exactly how a seam opens.
		var s: float = p_to if r == rows - 1 else minf(p_from + float(r) * step, p_to)
		var line := ring(p_plan, p_cum, p_alignment, s, offsets, p_crown, p_lift, half,
				p_crown_mode, p_max_bank, p_left_kerb, p_right_kerb,
				p_kerb_width, p_kerb_height, p_kerb_rumble_pitch, p_kerb_rumble_depth)
		if line.size() != across_count:
			return []
		for c in across_count:
			verts.append(line[c])
			# V IN METRES, not normalised over the chunk. Normalising would make the texture repeat once
			# per chunk, so the road markings would change scale at every region boundary and stretch
			# wherever a junction made a chunk short.
			uvs.append(Vector2(offsets[c] / half * 0.5 + 0.5, s))
			normals.append(Vector3.UP)

	# Swallowtail mitring & degenerate quad suppression (Tier C):
	# Detect inner edge velocity inversion and clamp backwards movement to apex.
	for r in range(rows - 1):
		var s: float = minf(p_from + float(r) * step, p_to)
		var tang := Pasture3DRoadGrader.plan_tangent_at(p_plan, p_cum, s)
		for c in across_count:
			var i0 := r * across_count + c
			var i2 := i0 + across_count
			var v0 := verts[i0]
			var v2 := verts[i2]
			var delta_xz := Vector2(v2.x - v0.x, v2.z - v0.z)
			if delta_xz.dot(tang) < 0.0:
				verts[i2].x = v0.x
				verts[i2].z = v0.z

	for r in range(rows - 1):
		for c in range(across_count - 1):
			var i0 := r * across_count + c
			var i1 := i0 + 1
			var i2 := i0 + across_count
			var i3 := i2 + 1

			var v0 := verts[i0]
			var v1 := verts[i1]
			var v2 := verts[i2]
			var v3 := verts[i3]

			# GODOT'S FRONT FACE IS CLOCKWISE AS SEEN FROM THE FRONT, which is the opposite of the
			# right-hand rule. For a surface that must be visible from ABOVE, the triangle has to look
			# clockwise looking down — so its geometric (b-a) x (c-a) points DOWN, not up.
			var cross1 := (v2.x - v0.x) * (v1.z - v0.z) - (v2.z - v0.z) * (v1.x - v0.x)
			var has_tri1 := false
			if cross1 > 1e-6:
				indices.append_array(PackedInt32Array([i0, i2, i1]))
				has_tri1 = true

			var cross2 := (v2.x - v1.x) * (v3.z - v1.z) - (v2.z - v1.z) * (v3.x - v1.x)
			var has_tri2 := false
			if cross2 > 1e-6:
				indices.append_array(PackedInt32Array([i1, i2, i3]))
				has_tri2 = true

			if not has_tri1 and not has_tri2:
				var alt1 := (v3.x - v0.x) * (v1.z - v0.z) - (v3.z - v0.z) * (v1.x - v0.x)
				var alt2 := (v2.x - v0.x) * (v3.z - v0.z) - (v2.z - v0.z) * (v3.x - v0.x)
				if alt1 > 1e-6:
					indices.append_array(PackedInt32Array([i0, i3, i1]))
				if alt2 > 1e-6:
					indices.append_array(PackedInt32Array([i0, i2, i3]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## The junction apron: the disc of surface inside a junction footprint, as a triangle fan.
##
## ---- WHY IT FOLLOWS THE MAJOR ROAD RATHER THAN BEING FLAT ----
##
## The ground inside a footprint is not flat and is not at the junction's `elevation`. The grader lets
## the MAJOR road pave straight through (only minor approaches are skipped), so the ground in there is
## the major road's own surface — crowned, banked, climbing. An apron laid flat at `elevation` would sit
## up to a crown above the carriageway edges and cut into the middle: a visible saucer at every
## crossroads.
##
## So every fan vertex is projected onto the major road's plan and given exactly the height the grader
## gave that cell, through the same `surface_height`. The apron and the ground are the same surface for
## the same reason the ribbon and the ground are.
##
## Returns a surface array, or an empty Array when there is nothing to build.
static func build_apron(p_center: Vector2, p_radius: float, p_plan: PackedVector2Array,
		p_cum: PackedFloat32Array, p_alignment: Pasture3DRoadAlignment, p_crown: float,
		p_segments: int = 24, p_lift: float = DEPTH_LIFT,
		p_force_gdscript: bool = false) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_radius <= 0.01:
		return []
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_apron"):
		return Pasture3DUtil.road_mesh_build_apron(p_center, p_radius, p_plan, p_cum,
				p_alignment.ds, p_alignment.z, p_alignment.bank, p_crown, p_segments, p_lift,
				p_alignment.s0)
	var segments := maxi(p_segments, 3)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	verts.append(_apron_point(p_center, p_plan, p_cum, p_alignment, p_crown, p_lift))
	uvs.append(Vector2(0.5, 0.5))
	normals.append(Vector3.UP)
	for i in segments:
		var a := TAU * float(i) / float(segments)
		var at := p_center + Vector2(cos(a), sin(a)) * p_radius
		verts.append(_apron_point(at, p_plan, p_cum, p_alignment, p_crown, p_lift))
		uvs.append(Vector2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5))
		normals.append(Vector3.UP)
	for i in segments:
		# (centre, ring i, ring i+1) with the angle INCREASING is clockwise seen from above, which is
		# Godot's front face — the same convention as the ribbon, and wrong the same way if reversed.
		indices.append_array(PackedInt32Array([0, 1 + i, 1 + (i + 1) % segments]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## Terminal apron generator: extrudes a smooth, rounded transition bevel ramp at road ends (P9b).
## Blends downward from (s_end, z_road, t_road) to meet the terrain ground flush with a cubic Hermite curve.
static func build_terminus_apron(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_s_end: float, p_half: float,
		p_shoulder: float, p_crown: float, p_is_start: bool = false,
		p_apron_length: float = 2.5, p_apron_drop: float = 0.08,
		p_rings_count: int = 4, p_lift: float = 0.0,
		p_crown_mode: int = 0, p_max_bank: float = 0.0,
		p_roundness: float = 0.5, p_force_gdscript: bool = false) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_cum.size() < p_plan.size() or p_alignment.z.is_empty():
		return []
	if p_apron_length <= 1e-4 or p_rings_count < 2:
		return []

	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_terminus_apron"):
		return Pasture3DUtil.road_mesh_build_terminus_apron(p_plan, p_cum,
				p_alignment.ds, p_alignment.z, p_alignment.bank,
				p_s_end, p_half, p_shoulder, p_crown,
				p_is_start, p_apron_length, p_apron_drop,
				p_rings_count, p_lift, p_alignment.s0,
				p_crown_mode, p_max_bank, p_roundness)

	var total_s: float = p_cum[p_cum.size() - 1]
	var s: float = clampf(p_s_end, 0.0, total_s)
	var at := Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, s)
	var tangent := Pasture3DRoadGrader.plan_tangent_at(p_plan, p_cum, s)
	var across := Vector2(-tangent.y, tangent.x)
	var t_ext: Vector2 = -tangent if p_is_start else tangent

	var centre_0: float = p_alignment.height_at(s)
	var si := p_alignment.index_at(s)
	var bank_0: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0

	var delta_s := minf(maxf(p_alignment.ds, 0.5), 1.0)
	var m0: float = 0.0
	if p_is_start:
		var g := (p_alignment.height_at(minf(s + delta_s, total_s)) - centre_0) / delta_s
		m0 = -g
	else:
		var g := (centre_0 - p_alignment.height_at(maxf(s - delta_s, 0.0))) / delta_s
		m0 = g

	var half := maxf(p_half, 0.01)
	var shoulder := maxf(p_shoulder, 0.0)
	var w_total := half + shoulder
	var offsets := PackedFloat32Array([-w_total, -half, 0.0, half, w_total])
	var across_count := offsets.size()
	var rows := maxi(p_rings_count, 2)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var total_verts := rows * across_count
	verts.resize(total_verts)
	normals.resize(total_verts)
	uvs.resize(total_verts)

	var vi := 0
	var L := p_apron_length
	for r in rows:
		var tau := float(r) / float(rows - 1)
		var x := tau * L
		var xz_c := at + t_ext * x

		# Cubic Hermite basis functions
		var tau2 := tau * tau
		var tau3 := tau2 * tau
		var h0 := 2.0 * tau3 - 3.0 * tau2 + 1.0
		var h1 := -2.0 * tau3 + 3.0 * tau2
		var h2 := tau3 - 2.0 * tau2 + tau
		var h3 := tau3 - tau2

		var fillet := 1.0 - sqrt(maxf(0.0, 1.0 - tau2))
		var width_scale := maxf(0.0, 1.0 - (p_roundness / w_total) * fillet) if w_total > 1e-4 else 1.0

		for c in across_count:
			var u := offsets[c]
			var u_scaled := u * width_scale
			var xz := xz_c + across * u_scaled

			var y0 := Pasture3DRoadGrader.surface_height(centre_0, bank_0, p_crown, u, half, p_crown_mode, p_max_bank)
			var y1 := y0 + m0 * L - p_apron_drop
			var m1 := 0.0
			var y := h0 * y0 + h1 * y1 + h2 * (L * m0) + h3 * (L * m1) + p_lift

			verts[vi] = Vector3(xz.x, y, xz.y)
			var v_coord := s - x if p_is_start else s + x
			uvs[vi] = Vector2(u / half * 0.5 + 0.5, v_coord)
			normals[vi] = Vector3.UP
			vi += 1

	for r in range(rows - 1):
		for c in range(across_count - 1):
			var i0 := r * across_count + c
			var i1 := i0 + 1
			var i2 := i0 + across_count
			var i3 := i2 + 1
			if p_is_start:
				indices.append_array(PackedInt32Array([i0, i1, i2, i1, i3, i2]))
			else:
				indices.append_array(PackedInt32Array([i0, i2, i1, i1, i2, i3]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## One apron vertex: world XZ `p_at`, lifted onto the major road's graded surface.
## The height of the junction surface at one world XZ point — the same sample `build_footprint` takes
## for every boundary vertex, exposed so junction PAINT can sit on the surface rather than beside it.
##
## Paint and surface have to come from one sampler. A stop bar built at the road's flat solved elevation
## and a footprint built on the crowned, banked surface disagree by the crown, which is several times
## MARKING_LIFT — so the bar would sink into the road it is painted on wherever the road is not flat.
static func surface_height(p_at: Vector2, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_crown: float) -> float:
	if p_alignment == null or p_plan.size() < 2:
		return NAN
	return _apron_point(p_at, p_plan, p_cum, p_alignment, p_crown, 0.0).y


static func _apron_point(p_at: Vector2, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_crown: float, p_lift: float) -> Vector3:
	var hit := Pasture3DRoadGrader.nearest_on_plan(p_plan, p_cum, p_at)
	var d: float = hit[0]
	var s: float = hit[1]
	var side: float = hit[2]
	var si := p_alignment.index_at(s)
	var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
	var y := Pasture3DRoadGrader.surface_height(p_alignment.height_at(s), bank, p_crown, d * side)
	return Vector3(p_at.x, y + p_lift, p_at.y)


## Area-weighted vertex normals.
##
## Computed rather than assumed UP: a banked corner and a steep climb are both real surface tilts the
## alignment solved for, and lighting a superelevated corner as though it were flat throws away the one
## visual cue that says the road is banked at all.
static func _recompute_normals(p_verts: PackedVector3Array, p_indices: PackedInt32Array,
		p_normals: PackedVector3Array) -> void:
	for i in p_normals.size():
		p_normals[i] = Vector3.ZERO
	var tri := 0
	while tri + 2 < p_indices.size():
		var a := p_indices[tri]
		var b := p_indices[tri + 1]
		var c := p_indices[tri + 2]
		# Negated, because the winding above is Godot's and not the right-hand rule's: the geometric cross
		# of a front-facing triangle points AWAY from the side you see it from. A shading normal has to
		# point AT the viewer, so it is the opposite of the winding that makes the face visible.
		#
		# Not normalised: the cross product's length is twice the triangle's area, which weights big
		# triangles more than slivers and is what stops a decimated LOD shading differently.
		var n := -(p_verts[b] - p_verts[a]).cross(p_verts[c] - p_verts[a])
		p_normals[a] += n
		p_normals[b] += n
		p_normals[c] += n
		tri += 3
	for i in p_normals.size():
		var n := p_normals[i]
		p_normals[i] = n.normalized() if n.length_squared() > 1e-12 else Vector3.UP


# ---- THE JUNCTION FOOTPRINT (P9a-0) -----------------------------------------------------------------
#
# See PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md 2.2. `build_apron` lays a DISC over the
# footprint; this lays the polygon the arms actually bound. An arm's cut end is a flat, full-width face,
# a disc and a chord meet at two points, and no radius fixes that: grow the disc to catch an arm's
# corners and it grows equally in the directions where no road runs.
#
# ---- THE CORNER BETWEEN TWO ARMS IS REFLEX, AND THAT IS THE WHOLE GEOMETRY ----
#
# Take a square crossroads of half-width w. Each road is trimmed back to w, so the pavement is a PLUS
# shape, and the vertex where two arms meet — at (w, w) — is a corner of the GAP between them, not of
# the pavement. It is reflex as seen from inside.
#
# Rounding it is therefore a kerb return, and a kerb return ADDS pavement: the arc tangent to both road
# edges is centred out in the gap at (w+r, w+r) and bulges back toward the junction, filling the flare a
# vehicle turns through. Rounding it the other way — cutting the corner off, which is what "fillet"
# suggests — would eat the pavement exactly where a turning vehicle needs it.
#
# The consequence is the one thing to keep hold of: the tangent points sit at `r / tan(phi/2)` from the
# vertex ALONG EACH ROAD, so a fillet only fits if the arms are trimmed back that much further than the
# point where their edges cross. `fillet_allowance` is that distance, and the solver adds it to the
# trim-back — which is why a corner radius makes an intersection bigger rather than rounder in place.
#
# ---- WHY A FAN FROM THE CENTRE TRIANGULATES IT ----
#
# The boundary is generated arm by arm in angular order, every vertex lies outward of the centre along
# its own arm's direction, and the fillets bulge outward rather than crossing it. So the polygon is
# star-shaped about `p_center` by construction and a fan is valid — no ear-clipping, no library, and no
# way for a degenerate arm to produce a self-intersecting mesh rather than an empty one.

## Angles this close to straight are not a corner: `1 / tan(phi/2)` diverges as the arms become
## collinear, and two roads leaving at 2 degrees to each other have no kerb return between them.
const FILLET_MIN_ANGLE: float = 0.05

## Points along each fillet arc. Six is enough that a 10 m kerb return is smooth at the size an
## intersection is actually viewed from, and the whole polygon stays a few dozen vertices.
const FILLET_SEGMENTS: int = 6


## How much further back an arm must be trimmed for a corner radius of `p_radius` to fit between two
## arms whose outward directions differ by `p_phi` radians.
##
## Returns 0 for a radius of 0 and for an angle too shallow to be a corner. This is the number that makes
## `corner_radius` cost something: the solver adds it to the trim-back, so a bigger kerb return opens a
## bigger hole for the polygon to fill rather than rounding the one already there.
static func fillet_allowance(p_radius: float, p_phi: float) -> float:
	if p_radius <= 0.0 or p_phi < FILLET_MIN_ANGLE or p_phi > PI - FILLET_MIN_ANGLE:
		return 0.0
	return p_radius / tan(p_phi * 0.5)


static func _segment_intersection(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> Array:
	var d12 := p2 - p1
	var d34 := p4 - p3
	var den := d12.cross(d34)
	if absf(den) < 1e-9:
		return []
	var d13 := p3 - p1
	var t := d13.cross(d34) / den
	var u := d13.cross(d12) / den
	if t >= -1e-4 and t <= 1.0 + 1e-4 and u >= -1e-4 and u <= 1.0 + 1e-4:
		return [p1 + d12 * clampf(t, 0.0, 1.0)]
	return []


## The world-XZ boundary of a junction footprint, counter-clockwise.
##
## `p_arms` is one Dictionary per ARM — not per road. A road that crosses the junction contributes two,
## one either side; a road that ends at it contributes one. Each carries:
##   dir   Vector2 — unit, pointing OUT of the junction along that arm
##   trim  float   — distance from `p_center` at which that arm's cut face sits
##   half  float   — that arm's half-width
##
## Returns an empty array for fewer than two usable arms, which is the same answer `build_apron` gives
## for a zero radius: nothing to build rather than something degenerate.
static func plan_footprint(p_center: Vector2, p_arms: Array, p_corner_radius: float = 0.0,
		p_segments: int = FILLET_SEGMENTS) -> PackedVector2Array:
	var arms := _ordered_arms(p_arms)
	var out := PackedVector2Array()
	if arms.size() < 2:
		return out
	if arms.size() == 2:
		var d0: Vector2 = arms[0]["dir"]
		var d1: Vector2 = arms[1]["dir"]
		if d0.dot(d1) < -0.99:
			var t0: float = float(arms[0].get("trim", 0.0))
			var t1: float = float(arms[1].get("trim", 0.0))
			var h0: float = float(arms[0].get("half", 0.0))
			var h1: float = float(arms[1].get("half", 0.0))
			if t0 <= 1e-3 and t1 <= 1e-3 and absf(h0 - h1) <= 0.01:
				return PackedVector2Array()

	var n_arms := arms.size()
	var faces: Array = []
	for i in n_arms:
		var a: Dictionary = arms[i]
		var da: Vector2 = a["dir"]
		var na := Vector2(-da.y, da.x)
		var c_pt: Vector2 = a.get("center", p_center + da * float(a["trim"]))
		var cw_pt: Vector2 = c_pt - na * float(a["half"])
		var ccw_pt: Vector2 = c_pt + na * float(a["half"])
		faces.append({
			"cw": cw_pt, "center": c_pt, "ccw": ccw_pt, "dir": da,
			"half": float(a["half"]), "trim": float(a["trim"]),
			"carriageway_half": float(a.get("carriageway_half", a["half"])),
			"shoulder_width": float(a.get("shoulder_width", 0.0))
		})

	# Detect and mitre overlapping adjacent cut faces to prevent inverted self-intersections
	for i in n_arms:
		var curr_f: Dictionary = faces[i]
		var next_f: Dictionary = faces[(i + 1) % n_arms]
		var hit := _segment_intersection(curr_f["cw"], curr_f["ccw"], next_f["cw"], next_f["ccw"])
		if not hit.is_empty():
			var x_pt: Vector2 = hit[0]
			curr_f["ccw"] = x_pt
			next_f["cw"] = x_pt
			var chord: Vector2 = curr_f["ccw"] - curr_f["cw"]
			var len2: float = chord.length_squared()
			if len2 > 1e-6:
				var t: float = clampf((Vector2(curr_f["center"]) - Vector2(curr_f["cw"])).dot(chord) / len2, 0.05, 0.95)
				curr_f["center"] = Vector2(curr_f["cw"]) + chord * t
			var next_chord: Vector2 = next_f["ccw"] - next_f["cw"]
			var nlen2: float = next_chord.length_squared()
			if nlen2 > 1e-6:
				var t: float = clampf((Vector2(next_f["center"]) - Vector2(next_f["cw"])).dot(next_chord) / nlen2, 0.05, 0.95)
				next_f["center"] = Vector2(next_f["cw"]) + next_chord * t

	for i in n_arms:
		var a: Dictionary = faces[i]
		var b: Dictionary = faces[(i + 1) % n_arms]
		var c_half: float = float(a.get("carriageway_half", a["half"]))
		var tot_half: float = float(a["half"])
		var c_pt: Vector2 = a["center"]
		var da: Vector2 = a["dir"]
		var na := Vector2(-da.y, da.x)

		_push(out, a["cw"])
		# Intermediate carriageway edge on CW side if shoulders present
		if c_half < tot_half - 1e-3 and a["cw"].distance_to(a["ccw"]) > 1e-3:
			var left_cw := c_pt - na * c_half
			var v_cw: Vector2 = a["cw"]
			var v_cnt: Vector2 = a["center"]
			var seg := v_cnt - v_cw
			var seg_len2 := seg.length_squared()
			if seg_len2 > 1e-4:
				var t := (left_cw - v_cw).dot(seg) / seg_len2
				if t > 0.05 and t < 0.95:
					_push(out, v_cw + seg * t)

		# The centerline crown vertex, strictly preserved to meet crowned approach ribbons
		_push(out, a["center"])

		# Intermediate carriageway edge on CCW side if shoulders present
		if c_half < tot_half - 1e-3 and a["cw"].distance_to(a["ccw"]) > 1e-3:
			var right_ccw := c_pt + na * c_half
			var v_cnt: Vector2 = a["center"]
			var v_ccw: Vector2 = a["ccw"]
			var seg := v_ccw - v_cnt
			var seg_len2 := seg.length_squared()
			if seg_len2 > 1e-4:
				var t := (right_ccw - v_cnt).dot(seg) / seg_len2
				if t > 0.05 and t < 0.95:
					_push(out, v_cnt + seg * t)

		_push(out, a["ccw"])
		var a_ccw: Vector2 = a["ccw"]
		var b_cw: Vector2 = b["cw"]
		if a_ccw.distance_to(b_cw) > 1e-4:
			_append_fillet(out, a_ccw, a["dir"], b_cw, b["dir"], p_corner_radius, p_segments)

	# The walk closes on itself, so the final fillet can land back on the first vertex.
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= 1e-4:
		out.remove_at(out.size() - 1)

	if not _is_simple(out):
		var hull := Geometry2D.convex_hull(out)
		if hull.size() > 1 and hull[0].distance_to(hull[hull.size() - 1]) <= 1e-4:
			hull.remove_at(hull.size() - 1)
		if not Geometry2D.is_polygon_clockwise(hull):
			return hull
		else:
			hull.reverse()
			return hull
	return out


## Subdivide any polygon edge longer than `p_max_segment_len` into collinear sub-segments.
## This prevents unconstrained Delaunay triangulation from skipping long boundary edges or indenting
## into interior grid vertices on multi-road or acute junctions with large trim-backs.
static func densify_polygon(p_poly: PackedVector2Array, p_max_segment_len: float) -> PackedVector2Array:
	if p_poly.size() < 2 or p_max_segment_len <= 1e-4:
		return p_poly
	var out := PackedVector2Array()
	var n := p_poly.size()
	for i in n:
		var p0 := p_poly[i]
		var p1 := p_poly[(i + 1) % n]
		out.append(p0)
		var d := p0.distance_to(p1)
		if d > p_max_segment_len:
			var subs := int(ceil(d / p_max_segment_len))
			for s in range(1, subs):
				out.append(p0.lerp(p1, float(s) / float(subs)))
	return out


## True when no two non-adjacent edges of the ring cross. Adjacent edges share an endpoint by
## construction, and two arms meeting exactly at a square corner share a vertex, so only a STRICT
## interior crossing counts.
static func _is_simple(p_ring: PackedVector2Array) -> bool:
	var n := p_ring.size()
	if n < 4:
		return true
	for i in n:
		for j in range(i + 1, n):
			if (j + 1) % n == i or (i + 1) % n == j:
				continue
			var a0 := p_ring[i]
			var a1 := p_ring[(i + 1) % n]
			var b0 := p_ring[j]
			var b1 := p_ring[(j + 1) % n]
			var r := a1 - a0
			var sg := b1 - b0
			var denom := r.cross(sg)
			if absf(denom) < 1e-12:
				continue
			var qp := b0 - a0
			var t := qp.cross(sg) / denom
			var u := qp.cross(r) / denom
			if t > 1e-6 and t < 1.0 - 1e-6 and u > 1e-6 and u < 1.0 - 1e-6:
				return false
	return true


## The arms, normalised and sorted by the angle of their outward direction. Anything degenerate is
## dropped here rather than guarded against at every use.
static func _ordered_arms(p_arms: Array) -> Array:
	var out: Array = []
	for a in p_arms:
		if not (a is Dictionary) or not a.has("dir"):
			continue
		var d: Vector2 = a["dir"]
		if not d.is_finite() or d.length_squared() < 1e-12:
			continue
		d = d.normalized()
		var d_entry := {
			"dir": d,
			"trim": maxf(float(a.get("trim", 0.0)), 0.0),
			"half": maxf(float(a.get("half", 0.01)), 0.01),
			"ang": d.angle(),
		}
		if a.has("center"):
			d_entry["center"] = a["center"]
		if a.has("carriageway_half"):
			d_entry["carriageway_half"] = a["carriageway_half"]
		if a.has("shoulder_width"):
			d_entry["shoulder_width"] = a["shoulder_width"]
		if a.has("sign"):
			d_entry["sign"] = a["sign"]
		out.append(d_entry)
	out.sort_custom(func(x, y): return float(x["ang"]) < float(y["ang"]))
	return out


## Append the boundary strictly BETWEEN one arm's counter-clockwise corner and the next arm's clockwise
## corner: the kerb return, or the bare vertex where their edges cross when no radius fits.
static func _append_fillet(p_out: PackedVector2Array, p_from: Vector2, p_from_dir: Vector2,
		p_to: Vector2, p_to_dir: Vector2, p_radius: float, p_segments: int) -> void:
	var hit := _ray_intersect(p_from, p_from_dir, p_to, p_to_dir)
	if hit.is_empty():
		return # parallel arms: the two cut faces face each other and there is no corner between them
	var c: Vector2 = hit[0]
	var phi := acos(clampf(p_from_dir.dot(p_to_dir), -1.0, 1.0))
	if phi < FILLET_MIN_ANGLE or phi > PI - FILLET_MIN_ANGLE:
		_push(p_out, c)
		return
	# How far each cut face already sits beyond the vertex, along its own road. This is what the
	# solver's fillet allowance buys, and with an allowance of zero it is zero: the arms meet at a
	# square corner and no arc fits, which is the correct answer rather than a failure.
	var s_a := (p_from - c).dot(p_from_dir)
	var s_b := (p_to - c).dot(p_to_dir)
	if s_a <= 1e-4 or s_b <= 1e-4:
		return
	var room := maxf(minf(s_a, s_b), 0.0)
	var half_phi := phi * 0.5
	# CLAMPED TO WHAT FITS, never emitted as a reversed arc: an arc longer than the cut faces allow
	# would run back past them and cross the boundary it belongs to.
	var tan_d := minf(p_radius / tan(half_phi), room)
	var r_eff := tan_d * tan(half_phi)
	if r_eff <= 1e-4:
		_push(p_out, c)
		return
	var t_a := c + p_from_dir * tan_d
	var t_b := c + p_to_dir * tan_d
	# The centre sits out in the GAP between the arms, on the bisector — the kerb return bulges back
	# toward the junction and adds the flare, rather than cutting the corner away.
	var o := c + (p_from_dir + p_to_dir).normalized() * (r_eff / sin(half_phi))
	var ang_a := (t_a - o).angle()
	var ang_b := (t_b - o).angle()
	# The sweep is pi - phi, always under pi, so the short way round is always the right way and no
	# winding flag is needed.
	var sweep := wrapf(ang_b - ang_a, -PI, PI)
	_push(p_out, t_a)
	for k in range(1, p_segments):
		var ang := ang_a + sweep * (float(k) / float(p_segments))
		_push(p_out, o + Vector2(cos(ang), sin(ang)) * r_eff)
	_push(p_out, t_b)


## Where two rays' lines cross, as `[point]`, or empty when they are parallel.
static func _ray_intersect(p_a: Vector2, p_da: Vector2, p_b: Vector2, p_db: Vector2) -> Array:
	var denom := p_da.cross(p_db)
	if absf(denom) < 1e-9:
		return []
	return [p_a + p_da * ((p_b - p_a).cross(p_db) / denom)]


## Append unless it repeats the point already there. Consecutive duplicates are normal — a square corner
## is two corners at the same place — and a zero-area triangle in the fan is a degenerate normal.
static func _push(p_out: PackedVector2Array, p_at: Vector2) -> void:
	if p_out.is_empty() or p_out[p_out.size() - 1].distance_to(p_at) > 1e-4:
		p_out.append(p_at)


## The height of every boundary vertex, taken from the ARMS rather than from any one road.
##
## ---- WHY NOT FROM THE MAJOR ROAD ----
##
## `build_footprint` used to drape the polygon on the major road's alignment, which is the disc's old
## behaviour kept. It has a fault that only shows when two roads are the SAME TYPE: they tie on priority,
## the solver breaks the tie with `major_index`, and `major_index` is the order the solver walked — scene
## order. So which road's crown and grade the intersection took was decided by the scene tree, and
## reordering the nodes swapped it. Reported as "one is overriding the other".
##
## The arms already carry the answer. Every boundary vertex lies on some arm's CUT FACE, and that face is
## the last cross-section of a ribbon that stops there — so the vertex's height is that ribbon's own
## height at that across-offset, and the polygon meets each ribbon exactly by construction rather than by
## a tolerance. Priority keeps what priority is for: it sets the junction's ELEVATION, the height the
## whole thing sits at. It stops deciding the SHAPE.
##
## `p_arm_faces` is one Dictionary per arm, as `Pasture3DRoadJunction.footprint_arms()` gives them plus
## the three numbers a cross-section needs: `dir`, `trim`, `half`, `z` (that road's centreline height at
## its cut face), `bank`, `crown`.
##
## A vertex on a FILLET lies on no cut face at all — it is the kerb return between two arms — so the
## blend is over every arm, weighted by inverse square distance to its cut face. On a cut face that
## distance is zero and the arm owns the vertex outright, which is what makes the join exact.
## Evaluate the connecting road ribbon's actual cross-section elevation at lateral offset `p_u` (in road coordinates).
## The road ribbon mesh connects canonical cross-section vertices:
## [ -(carriageway_half + shoulder), -carriageway_half, 0.0, carriageway_half, carriageway_half + shoulder ]
## with planar quads. Between those vertices, the physical road ribbon is linear.
## Sampling this exact piecewise-linear chord profile guarantees zero vertical discrepancy along the seam.
static func ribbon_cross_section_height(p_z: float, p_bank: float, p_crown: float, p_u: float,
		p_carriageway_half: float, p_shoulder_width: float = 0.0,
		p_crown_mode: int = 0, p_max_bank: float = 0.0) -> float:
	var c_half := maxf(p_carriageway_half, 0.01)
	var shoulder := maxf(p_shoulder_width, 0.0)

	var y_center := Pasture3DRoadGrader.surface_height(p_z, p_bank, p_crown, 0.0, c_half, p_crown_mode, p_max_bank)
	if p_u >= 0.0:
		var y_cw := Pasture3DRoadGrader.surface_height(p_z, p_bank, p_crown, c_half, c_half, p_crown_mode, p_max_bank)
		if p_u <= c_half:
			return lerpf(y_center, y_cw, p_u / c_half)
		var y_sh := Pasture3DRoadGrader.surface_height(p_z, p_bank, p_crown, c_half + shoulder, c_half, p_crown_mode, p_max_bank)
		if shoulder > 1e-4 and p_u <= c_half + shoulder:
			return lerpf(y_cw, y_sh, (p_u - c_half) / shoulder)
		return y_sh + p_bank * (p_u - (c_half + shoulder))
	else:
		var y_cw := Pasture3DRoadGrader.surface_height(p_z, p_bank, p_crown, -c_half, c_half, p_crown_mode, p_max_bank)
		if p_u >= -c_half:
			return lerpf(y_center, y_cw, -p_u / c_half)
		var y_sh := Pasture3DRoadGrader.surface_height(p_z, p_bank, p_crown, -(c_half + shoulder), c_half, p_crown_mode, p_max_bank)
		if shoulder > 1e-4 and p_u >= -(c_half + shoulder):
			return lerpf(y_cw, y_sh, (-p_u - c_half) / shoulder)
		return y_sh + p_bank * (p_u + (c_half + shoulder))


static func footprint_boundary_heights(p_center: Vector2, p_boundary: PackedVector2Array,
		p_arm_faces: Array, p_fallback: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_boundary.size())
	if p_arm_faces.is_empty():
		out.fill(p_fallback)
		return out
	for i in p_boundary.size():
		var pt := p_boundary[i]
		var sum := 0.0
		var wsum := 0.0
		var exact := NAN
		for face: Dictionary in p_arm_faces:
			var dir: Vector2 = face.get("dir", Vector2.ZERO)
			var n := Vector2(-dir.y, dir.x)
			var trim: float = float(face.get("trim", 0.0))
			var c: Vector2 = face.get("center", p_center + dir * trim)
			var delta := pt - c
			var along: float = delta.dot(dir)
			var across: float = delta.dot(n)
			var half: float = maxf(float(face.get("half", 4.0)), 0.01)
			var carriageway_half: float = maxf(float(face.get("carriageway_half", half)), 0.01)
			var shoulder_width: float = float(face.get("shoulder_width", maxf(half - carriageway_half, 0.0)))
			var crown_mode: int = int(face.get("crown_mode", 0))
			var max_bank: float = float(face.get("max_bank", 0.0))
			var arm_sign: float = float(face.get("sign", 1.0))
			var u_road := across * arm_sign
			var d_along: float = along
			var over: float = maxf(absf(across) - half, 0.0)
			var d2: float = d_along * d_along + over * over
			if d2 <= 1e-8:
				exact = ribbon_cross_section_height(float(face.get("z", p_fallback)), float(face.get("bank", 0.0)),
						float(face.get("crown", 0.0)), u_road, carriageway_half, shoulder_width, crown_mode, max_bank)
				break
			var z := Pasture3DRoadGrader.surface_height(float(face.get("z", p_fallback)), float(face.get("bank", 0.0)),
					float(face.get("crown", 0.0)), u_road, carriageway_half, crown_mode, max_bank)
			var w := 1.0 / (d2 * d2)
			sum += z * w
			wsum += w
		out[i] = exact if not is_nan(exact) else (sum / wsum if wsum > 0.0 else p_fallback)
	return out


## Evaluate transfinite interpolation (bivariate Coons patch) surface height at point `p_at` in world XZ.
## Each arm face imposes elevation, cross-fall, crown, and longitudinal grade along its cut face segment.
## Blending uses inverse-quartic distance weighting (p=4), ensuring zero normal derivative of weights
## at each approach boundary: the surface meets approach ribbons with exact C¹ continuity.
static func coons_patch_height_at(p_at: Vector2, p_center: Vector2, p_arm_faces: Array,
		p_fallback: float) -> float:
	if p_arm_faces.is_empty():
		return p_fallback

	var sum := 0.0
	var wsum := 0.0
	var exact_h := NAN

	for face: Dictionary in p_arm_faces:
		var dir: Vector2 = face.get("dir", Vector2.ZERO)
		var n := Vector2(-dir.y, dir.x)
		var trim: float = float(face.get("trim", 0.0))
		var c: Vector2 = face.get("center", p_center + dir * trim)
		var delta := p_at - c
		var along: float = delta.dot(dir)
		var across: float = delta.dot(n)
		var half: float = maxf(float(face.get("half", 4.0)), 0.01)
		var carriageway_half: float = maxf(float(face.get("carriageway_half", half)), 0.01)
		var shoulder_width: float = float(face.get("shoulder_width", maxf(half - carriageway_half, 0.0)))
		var crown_mode: int = int(face.get("crown_mode", 0))
		var max_bank: float = float(face.get("max_bank", 0.0))
		var arm_sign: float = float(face.get("sign", 1.0))
		var z: float = float(face.get("z", p_fallback))
		var bank: float = float(face.get("bank", 0.0))
		var crown: float = float(face.get("crown", 0.0))
		var grade: float = float(face.get("grade", 0.0))

		# Distance to cut face segment
		var d_along := along
		var over := maxf(absf(across) - half, 0.0)
		var d2 := d_along * d_along + over * over

		# On cut face segment: exact match with connecting road ribbon cross section
		if d2 <= 1e-8:
			exact_h = ribbon_cross_section_height(z, bank, crown, across * arm_sign, carriageway_half, shoulder_width, crown_mode, max_bank)
			break

		# Hermite surface prediction from this arm for interior blending:
		# Uses canonical smooth profile to guarantee C¹ continuity without creases across diagonal crossing trajectories
		var u_road := across * arm_sign
		var h_profile := Pasture3DRoadGrader.surface_height(z, bank, crown, u_road, carriageway_half, crown_mode, max_bank)
		var h_pred := h_profile + grade * along

		var w := 1.0 / (d2 * d2)
		sum += h_pred * w
		wsum += w

	if not is_nan(exact_h):
		return exact_h
	return sum / wsum if wsum > 0.0 else p_fallback


## The junction surface at one point, interpolated over the SAME triangle fan the mesh is built from
## (or the transfinite Coons patch when `p_arm_faces` is provided).
##
## Not a second definition of the surface: the mesh is `(centre, boundary[i], boundary[i+1])` and so is
## this, so the terrain the junction grades and the polygon it draws are one surface read twice. Any
## other interpolation — a plane fit, an inverse-distance blend — would agree with the mesh only to a
## tolerance, and a tolerance between ground and mesh is the road surface showing through the terrain.
##
## Returns `p_center_h` for a point outside the fan, which is the answer a caller wants when it is
## rasterising a bounding box and asking about cells it will then reject.
static func footprint_height_at(p_at: Vector2, p_center: Vector2, p_boundary: PackedVector2Array,
		p_heights: PackedFloat32Array, p_center_h: float, p_arm_faces: Array = []) -> float:
	if not p_arm_faces.is_empty():
		return coons_patch_height_at(p_at, p_center, p_arm_faces, p_center_h)
	var n := p_boundary.size()
	if n < 3 or p_heights.size() != n:
		return p_center_h
	for i in n:
		var a := p_boundary[i]
		var b := p_boundary[(i + 1) % n]
		var bary := _barycentric(p_at, p_center, a, b)
		if bary.is_empty():
			continue
		return p_center_h * bary[0] + p_heights[i] * bary[1] + p_heights[(i + 1) % n] * bary[2]
	return p_center_h


## Where a footprint's batter starts, as `[distance_to_the_polygon, height_to_start_from]`.
##
## A road batter runs from the edge of formation at `Pasture3DRoadGrader.surface_height`; the junction's
## runs from the edge of its polygon, and that edge already HAS a height per vertex -- the arm-blended
## one `footprint_boundary_heights` solved. So nothing is derived here, and the batter cannot start at a
## different height from the one the mesh is drawn at.
##
## ---- WHY THE HEIGHT IS BLENDED AND THE DISTANCE IS NOT ----
##
## Taking the height at the NEAREST point is the obvious reading, and it puts a seam in the ground. Far
## from a polygon the nearest feature is a CORNER, and which corner it is flips along the bisector
## between them; two corners of a junction on a slope differ in height, so the batter jumped across that
## line. Measured on a crossing in a cutting: neighbouring cells one metre apart started their batters
## from 28.08 m and 32.48 m, and the 2.93 m wall between them ran diagonally out from the intersection --
## a nearest-feature Voronoi seam, drawn in earth.
##
## So the height is an inverse-square blend over every EDGE, the same idiom -- and for the same reason --
## that `footprint_boundary_heights` blends the arms: at the kerb the nearest edge's weight runs away
## with it, so the join stays exact, and far out the corners average instead of competing.
##
## The DISTANCE stays the true nearest one. It is what the batter's run is measured along, and blending
## that would move the toe rather than smooth it.
static func footprint_edge_at(p_at: Vector2, p_boundary: PackedVector2Array,
		p_heights: PackedFloat32Array) -> Array:
	var n := p_boundary.size()
	if n < 3 or p_heights.size() != n:
		return []
	var best := INF
	var sum := 0.0
	var wsum := 0.0
	for i in n:
		var a := p_boundary[i]
		var b := p_boundary[(i + 1) % n]
		var ab := b - a
		var len2 := ab.length_squared()
		var t: float = 0.0 if len2 <= 0.0 else clampf((p_at - a).dot(ab) / len2, 0.0, 1.0)
		var h: float = lerpf(p_heights[i], p_heights[(i + 1) % n], t)
		var d2 := p_at.distance_squared_to(a + ab * t)
		best = minf(best, d2)
		# Exactly on an edge: that edge IS the answer, and dividing by its zero distance is not.
		if d2 <= 1e-8:
			return [sqrt(best), h]
		sum += h / d2
		wsum += 1.0 / d2
	if wsum <= 0.0:
		return []
	return [sqrt(best), sum / wsum]


## `[u, v, w]` for a point inside triangle `abc`, or empty when it is outside. A shared edge belongs to
## both triangles — the epsilon is inclusive — so a point exactly on a fan spoke gets an answer rather
## than falling through every triangle and landing on the centre height.
static func _barycentric(p_at: Vector2, p_a: Vector2, p_b: Vector2, p_c: Vector2) -> Array:
	var v0 := p_b - p_a
	var v1 := p_c - p_a
	var v2 := p_at - p_a
	var den := v0.cross(v1)
	if absf(den) < 1e-12:
		return []
	var v := v2.cross(v1) / den
	var w := v0.cross(v2) / den
	if v < -1e-6 or w < -1e-6 or v + w > 1.0 + 1e-6:
		return []
	return [1.0 - v - w, v, w]


static func _is_point_on_boundary(p: Vector2, poly: PackedVector2Array, tol: float = 1e-3) -> bool:
	var n := poly.size()
	var tol_sq := tol * tol
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var ab := b - a
		var l2 := ab.length_squared()
		if l2 <= 1e-8:
			if p.distance_squared_to(a) <= tol_sq:
				return true
			continue
		var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var proj := a + ab * t
		if p.distance_squared_to(proj) <= tol_sq:
			return true
	return false


static func _is_point_in_or_on_poly(p: Vector2, poly: PackedVector2Array, tol: float = 1e-3) -> bool:
	if Geometry2D.is_point_in_polygon(p, poly) or _is_point_on_boundary(p, poly, tol):
		return true
	# Robust fallbacks for ray-vertex collinearity edge cases in Godot point-in-polygon
	const EPS: float = 1e-4
	return Geometry2D.is_point_in_polygon(p + Vector2(0.0, EPS), poly) \
		or Geometry2D.is_point_in_polygon(p - Vector2(0.0, EPS), poly) \
		or Geometry2D.is_point_in_polygon(p + Vector2(EPS, 0.0), poly) \
		or Geometry2D.is_point_in_polygon(p - Vector2(EPS, 0.0), poly)


## The junction surface: `p_boundary` as a triangle fan about `p_center`, at the heights the ARMS give.
##
## The heights arrive as an argument rather than being sampled here, because the ground the junction
## grades has to be the same surface — `footprint_height_at` interpolates over this exact fan, so the
## polygon and the terrain under it are one definition read twice rather than two that agree to a
## tolerance. It also takes the last road-specific thing out of this kernel: the disc it replaced sampled
## the MAJOR road's alignment, which made the intersection's shape depend on scene order whenever two
## roads tied on priority.
## Build a C¹-continuous transfinite Coons patch surface with a uniform interior grid triangulation.
## Unlike the radial triangle fan (which causes suspension spoke creases), this discretizes the interior
## into a regular grid bounded by `p_boundary`, ensuring smooth vehicle dynamics in all crossing directions.
static func build_coons_patch(p_center: Vector2, p_boundary: PackedVector2Array, p_arm_faces: Array,
		p_center_h: float, p_grid_step: float = 1.0, p_lift: float = DEPTH_LIFT) -> Array:
	if p_boundary.size() < 3 or p_arm_faces.is_empty():
		return []

	var aabb_min := Vector2(INF, INF)
	var aabb_max := Vector2(-INF, -INF)
	for p in p_boundary:
		aabb_min.x = minf(aabb_min.x, p.x)
		aabb_min.y = minf(aabb_min.y, p.y)
		aabb_max.x = maxf(aabb_max.x, p.x)
		aabb_max.y = maxf(aabb_max.y, p.y)

	var step := maxf(p_grid_step, 0.5)
	var grid_pts := PackedVector2Array()
	var x := aabb_min.x + step * 0.5
	while x < aabb_max.x:
		var y := aabb_min.y + step * 0.5
		while y < aabb_max.y:
			var pt := Vector2(x, y)
			if Geometry2D.is_point_in_polygon(pt, p_boundary):
				var min_d := INF
				for i in p_boundary.size():
					var a: Vector2 = p_boundary[i]
					var b: Vector2 = p_boundary[(i + 1) % p_boundary.size()]
					var ab := b - a
					var t := clampf((pt - a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
					min_d = minf(min_d, pt.distance_to(a + ab * t))
				if min_d > step * 0.4:
					grid_pts.append(pt)
			y += step
		x += step

	var all_pts := PackedVector2Array()
	all_pts.append_array(p_boundary)
	all_pts.append_array(grid_pts)

	var raw_tris := Geometry2D.triangulate_delaunay(all_pts)
	var kept_indices := PackedInt32Array()

	for t in range(0, raw_tris.size(), 3):
		var i0 := raw_tris[t]
		var i1 := raw_tris[t + 1]
		var i2 := raw_tris[t + 2]
		var p0 := all_pts[i0]
		var p1 := all_pts[i1]
		var p2 := all_pts[i2]
		var centroid := (p0 + p1 + p2) / 3.0
		if Geometry2D.is_point_in_polygon(centroid, p_boundary):
			var m01 := (p0 + p1) * 0.5
			var m12 := (p1 + p2) * 0.5
			var m20 := (p2 + p0) * 0.5
			if _is_point_in_or_on_poly(m01, p_boundary) and _is_point_in_or_on_poly(m12, p_boundary) and _is_point_in_or_on_poly(m20, p_boundary):
				# Front-face winding: clockwise seen from above (cross.y < 0 in Godot 3D)
				var v0 := Vector3(p0.x, 0.0, p0.y)
				var v1 := Vector3(p1.x, 0.0, p1.y)
				var v2 := Vector3(p2.x, 0.0, p2.y)
				if (v1 - v0).cross(v2 - v0).y > 0.0:
					kept_indices.append(i0)
					kept_indices.append(i2)
					kept_indices.append(i1)
				else:
					kept_indices.append(i0)
					kept_indices.append(i1)
					kept_indices.append(i2)

	var extent := 0.0
	for p in p_boundary:
		extent = maxf(extent, p_center.distance_to(p))
	extent = maxf(extent, 0.01)

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()

	for p in all_pts:
		var h := coons_patch_height_at(p, p_center, p_arm_faces, p_center_h)
		verts.append(Vector3(p.x, h + p_lift, p.y))
		var d := (p - p_center) / extent
		uvs.append(Vector2(0.5 + d.x * 0.5, 0.5 + d.y * 0.5))
		normals.append(Vector3.UP)

	_recompute_normals(verts, kept_indices, normals)

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = kept_indices
	return out


## The junction surface: `p_boundary` as a triangle fan about `p_center` (or C¹ transfinite Coons
## patch when `p_arm_faces` is provided).
##
## When `p_arm_faces` is provided, `build_coons_patch` is invoked to produce a regular grid interior
## triangulation with smooth C¹ continuous elevation and slope blending, eliminating radial spoke ridges.
## When omitted or empty, the legacy triangle fan is constructed for backward compatibility.
static func build_footprint(p_center: Vector2, p_boundary: PackedVector2Array,
		p_heights: PackedFloat32Array, p_center_h: float, p_lift: float = DEPTH_LIFT,
		p_arm_faces: Array = [], p_grid_step: float = 1.0) -> Array:
	if not p_arm_faces.is_empty():
		return build_coons_patch(p_center, p_boundary, p_arm_faces, p_center_h, p_grid_step, p_lift)
	if p_boundary.size() < 3 or p_heights.size() != p_boundary.size():
		return []
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# UVs are radial about the centre, normalised by the furthest boundary point, so the surface takes a
	# texture the same way the disc did and a material written for one works on the other.
	var extent := 0.0
	for at in p_boundary:
		extent = maxf(extent, p_center.distance_to(at))
	extent = maxf(extent, 0.01)

	verts.append(Vector3(p_center.x, p_center_h + p_lift, p_center.y))
	uvs.append(Vector2(0.5, 0.5))
	normals.append(Vector3.UP)
	for i in p_boundary.size():
		var at := p_boundary[i]
		verts.append(Vector3(at.x, p_heights[i] + p_lift, at.y))
		var d := (at - p_center) / extent
		uvs.append(Vector2(0.5 + d.x * 0.5, 0.5 + d.y * 0.5))
		normals.append(Vector3.UP)
	var n := p_boundary.size()
	for i in n:
		# (centre, ring i, ring i+1) with the boundary running counter-clockwise is clockwise seen from
		# above, which is Godot's front face — the same convention as the ribbon and the disc, and
		# invisible from every normal camera angle if reversed.
		indices.append_array(PackedInt32Array([0, 1 + i, 1 + (i + 1) % n]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out
